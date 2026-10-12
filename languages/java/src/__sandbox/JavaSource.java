package __sandbox;

import com.sun.source.tree.BlockTree;
import com.sun.source.tree.CaseTree;
import com.sun.source.tree.CatchTree;
import com.sun.source.tree.ClassTree;
import com.sun.source.tree.CompilationUnitTree;
import com.sun.source.tree.DoWhileLoopTree;
import com.sun.source.tree.EnhancedForLoopTree;
import com.sun.source.tree.ExpressionTree;
import com.sun.source.tree.ForLoopTree;
import com.sun.source.tree.IdentifierTree;
import com.sun.source.tree.IfTree;
import com.sun.source.tree.LabeledStatementTree;
import com.sun.source.tree.LiteralTree;
import com.sun.source.tree.MemberSelectTree;
import com.sun.source.tree.MethodTree;
import com.sun.source.tree.StatementTree;
import com.sun.source.tree.SwitchTree;
import com.sun.source.tree.SynchronizedTree;
import com.sun.source.tree.Tree;
import com.sun.source.tree.TryTree;
import com.sun.source.tree.VariableTree;
import com.sun.source.tree.WhileLoopTree;
import com.sun.source.util.JavacTask;
import com.sun.source.util.SourcePositions;
import com.sun.source.util.Trees;
import java.io.File;
import java.net.URI;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import javax.lang.model.element.Modifier;
import javax.tools.Diagnostic;
import javax.tools.DiagnosticCollector;
import javax.tools.JavaCompiler;
import javax.tools.JavaFileObject;
import javax.tools.SimpleJavaFileObject;
import javax.tools.StandardJavaFileManager;
import javax.tools.ToolProvider;

/**
 * Parser-based checks and the two compiled forms of a Java algorithm, built with the JDK's own
 * compiler API (no other dependencies):
 *
 * <ul>
 *   <li>{@code benchmark/}: the student's source, compiled unchanged (as {@code algorithm.java});
 *   <li>{@code visual/}: a copy with {@code __sandbox.Checkpoint.at(line, "i", i, …);} before
 *       every statement of every method (as {@code visual.java}).
 * </ul>
 *
 * <p>Insertions never contain line breaks, so the line numbers of both are the student's.
 */
final class JavaSource {
    static final Map<String, String> PALETTE = new LinkedHashMap<>();

    static {
        String[][] colors = {
            {"RED", "#F44336"}, {"PINK", "#E91E63"}, {"PURPLE", "#9C27B0"}, {"DEEP_PURPLE", "#673AB7"},
            {"INDIGO", "#3F51B5"}, {"BLUE", "#2196F3"}, {"LIGHT_BLUE", "#03A9F4"}, {"CYAN", "#00BCD4"},
            {"TEAL", "#009688"}, {"GREEN", "#4CAF50"}, {"LIGHT_GREEN", "#8BC34A"}, {"LIME", "#CDDC39"},
            {"YELLOW", "#FFEB3B"}, {"AMBER", "#FFC107"}, {"ORANGE", "#FF9800"},
            {"DEEP_ORANGE", "#FF5722"}, {"BROWN", "#795548"}, {"BLUE_GREY", "#607D8B"},
        };
        for (String[] color : colors) PALETTE.put(color[0], color[1]);
    }

    private static final Pattern HEX = Pattern.compile("^#[0-9a-fA-F]{6}$");
    private static final JavaCompiler COMPILER = ToolProvider.getSystemJavaCompiler();

    /** An in-memory source; any class name is allowed in any file name. */
    static final class Source extends SimpleJavaFileObject {
        final String content;

        Source(String name, String content) {
            super(URI.create("string:///" + name), Kind.SOURCE);
            this.content = content;
        }

        @Override
        public CharSequence getCharContent(boolean ignoreEncodingErrors) {
            return content;
        }

        @Override
        public boolean isNameCompatible(String simpleName, Kind kind) {
            return kind == Kind.SOURCE;
        }
    }

    static final class Problem extends RuntimeException {
        private static final long serialVersionUID = 1L;
        final transient Tree tree;
        final Integer length;

        Problem(Tree tree, String message, Integer length) {
            super(message);
            this.tree = tree;
            this.length = length;
        }
    }

    /** A parsed file: the tree plus what is needed to turn positions into lines. */
    static final class Parsed {
        final String content;
        final CompilationUnitTree unit;
        final SourcePositions positions;
        final List<Map<String, Object>> errors;

        Parsed(String content, CompilationUnitTree unit, SourcePositions positions,
                List<Map<String, Object>> errors) {
            this.content = content;
            this.unit = unit;
            this.positions = positions;
            this.errors = errors;
        }

        long start(Tree tree) {
            return positions.getStartPosition(unit, tree);
        }

        long end(Tree tree) {
            return positions.getEndPosition(unit, tree);
        }

        int line(Tree tree) {
            return (int) unit.getLineMap().getLineNumber(start(tree));
        }

        Map<String, Object> diagnostic(Tree tree, String message, Integer length) {
            if (tree == null) return JavaSource.diagnostic(1, 1, 1, message);
            long start = start(tree);
            long end = end(tree);
            int line = (int) unit.getLineMap().getLineNumber(start);
            int column = (int) unit.getLineMap().getColumnNumber(start);
            int span = length != null ? length
                    : end > start && unit.getLineMap().getLineNumber(end) == line ? (int) (end - start) : 5;
            return JavaSource.diagnostic(line, column, span, message);
        }
    }

    static Map<String, Object> diagnostic(long line, long column, long length, String message) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("line", Math.max(1, line));
        result.put("column", Math.max(1, column));
        result.put("length", Math.max(1, Math.min(40, length)));
        result.put("message", message);
        result.put("severity", "error");
        return result;
    }

    static List<Map<String, Object>> errors(DiagnosticCollector<JavaFileObject> collector) {
        List<Map<String, Object>> result = new ArrayList<>();
        for (Diagnostic<? extends JavaFileObject> d : collector.getDiagnostics()) {
            if (d.getKind() != Diagnostic.Kind.ERROR) continue;
            long length = d.getEndPosition() > d.getStartPosition() && d.getStartPosition() >= 0
                    ? d.getEndPosition() - d.getStartPosition() : 1;
            // "cannot find symbol\n  symbol: method swapp(int,int)\n  location: …"
            String[] lines = d.getMessage(Locale.ENGLISH).split("\n");
            String message = lines[0].strip();
            for (int i = 1; i < lines.length; i++) {
                String detail = lines[i].strip();
                if (detail.startsWith("symbol:")) message += ": " + detail.substring(7).strip();
            }
            result.add(diagnostic(d.getLineNumber(), d.getColumnNumber(), length, message));
            if (result.size() >= 30) break;
        }
        return result;
    }

    static Parsed parse(String content) {
        DiagnosticCollector<JavaFileObject> collector = new DiagnosticCollector<>();
        JavacTask task = (JavacTask) COMPILER.getTask(null, null, collector,
                List.of("-proc:none"), null,
                List.of(new Source("algorithm.java", content)));
        try {
            CompilationUnitTree unit = task.parse().iterator().next();
            return new Parsed(content, unit, Trees.instance(task).getSourcePositions(), errors(collector));
        } catch (java.io.IOException error) {
            throw new IllegalStateException(error);
        }
    }

    // ------------------------------------------------------------------ the contract

    private static boolean isAlgorithm(ClassTree cls) {
        Tree extended = cls.getExtendsClause();
        if (extended == null) return false;
        String name = extended.toString();
        return name.equals("SortingAlgorithm") || name.endsWith(".SortingAlgorithm");
    }

    private static String literal(ExpressionTree value) {
        if (value instanceof LiteralTree literal && literal.getValue() instanceof String text) return text;
        return null;
    }

    private static String color(ExpressionTree value) {
        String text = literal(value);
        if (text != null) return HEX.matcher(text).matches() ? text : null;
        if (value instanceof MemberSelectTree select
                && select.getExpression() instanceof IdentifierTree owner
                && owner.getName().contentEquals("Colors")) {
            return PALETTE.get(select.getIdentifier().toString());
        }
        return null;
    }

    private static VariableTree field(ClassTree cls, String name) {
        for (Tree member : cls.getMembers()) {
            if (member instanceof VariableTree variable && variable.getName().contentEquals(name)
                    && !variable.getModifiers().getFlags().contains(Modifier.STATIC)) {
                return variable;
            }
        }
        return null;
    }

    /** The metadata of the one algorithm class; throws Problem. */
    static Map<String, Object> contract(Parsed parsed) {
        if (parsed.unit.getPackageName() != null) {
            throw new Problem(parsed.unit.getPackage(),
                    "Remove the package line: algorithms live in the default package.", null);
        }
        List<ClassTree> classes = new ArrayList<>();
        for (Tree declaration : parsed.unit.getTypeDecls()) {
            if (declaration instanceof ClassTree cls && isAlgorithm(cls)) classes.add(cls);
        }
        if (classes.isEmpty()) {
            throw new Problem(null, "No class extending SortingAlgorithm found. Start with: "
                    + "class MySort extends SortingAlgorithm { … }", null);
        }
        if (classes.size() > 1) {
            throw new Problem(classes.get(1),
                    "One file must contain exactly one class that extends SortingAlgorithm.", 5);
        }
        ClassTree cls = classes.get(0);
        if (cls.getModifiers().getFlags().contains(Modifier.ABSTRACT)) {
            throw new Problem(cls, "The algorithm class must not be abstract.", 5);
        }

        MethodTree sort = null;
        boolean anyConstructor = false;
        boolean noArgumentConstructor = false;
        for (Tree member : cls.getMembers()) {
            if (!(member instanceof MethodTree method)) continue;
            if (method.getName().contentEquals("<init>")) {
                anyConstructor = true;
                if (method.getParameters().isEmpty()) noArgumentConstructor = true;
            } else if (method.getName().contentEquals("sort")) {
                sort = method;
            }
        }
        if (sort == null) {
            throw new Problem(cls, "Missing method: public void sort(Elements list, Elements scratch) { … }", 5);
        }
        if (sort.getParameters().size() != 2) {
            throw new Problem(sort, "sort must take exactly two parameters: "
                    + "public void sort(Elements list, Elements scratch).", 4);
        }
        if (anyConstructor && !noArgumentConstructor) {
            throw new Problem(cls, "The sandbox cannot create " + cls.getSimpleName()
                    + "(): the class needs a constructor without parameters.", 5);
        }

        VariableTree name = field(cls, "name");
        String nameText = name == null ? null : literal(name.getInitializer());
        if (nameText == null || nameText.isBlank()) {
            throw new Problem(name != null ? name : cls,
                    "Give the algorithm a literal name, e.g. String name = \"Bubble Sort\";",
                    name != null ? null : 5);
        }
        VariableTree author = field(cls, "author");
        String authorText = null;
        if (author != null) {
            authorText = literal(author.getInitializer());
            if (authorText == null || authorText.isBlank()) {
                throw new Problem(author, "Use a literal author, e.g. String author = \"Anna\"; or remove it.", null);
            }
        }
        VariableTree color = field(cls, "color");
        String colorText = color == null || color.getInitializer() == null ? null : color(color.getInitializer());
        if (colorText == null) {
            throw new Problem(color != null ? color : cls,
                    "Choose a color: String color = Colors.GREEN; or a hex color such as \"#4CAF50\".",
                    color != null ? null : 5);
        }
        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("name", nameText.strip());
        meta.put("color", colorText.toUpperCase(Locale.ROOT));
        meta.put("className", cls.getSimpleName().toString());
        if (authorText != null) meta.put("author", authorText.strip());
        return meta;
    }

    /** {ok, meta?, diagnostics} from the parser and the contract. */
    static Map<String, Object> inspect(Parsed parsed) {
        Map<String, Object> result = new LinkedHashMap<>();
        if (!parsed.errors.isEmpty()) {
            result.put("ok", false);
            result.put("diagnostics", parsed.errors);
            return result;
        }
        try {
            Map<String, Object> meta = contract(parsed);
            result.put("ok", true);
            result.put("meta", meta);
            result.put("diagnostics", List.of());
        } catch (Problem problem) {
            result.put("ok", false);
            result.put("diagnostics", List.of(parsed.diagnostic(problem.tree, problem.getMessage(), problem.length)));
        }
        return result;
    }

    // --------------------------------------------------------------------- compiling

    /** Compiles [content] as [fileName] into [out]; returns the errors (empty on success). */
    static List<Map<String, Object>> compile(String fileName, String content, File out, String classpath) {
        out.mkdirs();
        DiagnosticCollector<JavaFileObject> collector = new DiagnosticCollector<>();
        try (StandardJavaFileManager files = COMPILER.getStandardFileManager(collector, Locale.ENGLISH, null)) {
            boolean ok = COMPILER.getTask(null, files, collector,
                    List.of("-proc:none", "-g", "-nowarn", "-Xlint:none", "-encoding", "UTF-8",
                            "-classpath", classpath, "-d", out.getPath()),
                    null, List.of(new Source(fileName, content))).call();
            List<Map<String, Object>> errors = errors(collector);
            if (!ok && errors.isEmpty()) errors.add(diagnostic(1, 1, 1, "Java could not compile this file."));
            return errors;
        } catch (java.io.IOException error) {
            throw new IllegalStateException(error);
        }
    }

    // --------------------------------------------------------------- the visual copy

    private record Edit(long at, String text) {}

    /** The visual copy: a checkpoint before every statement of every method. */
    static String visual(Parsed parsed) {
        List<Edit> edits = new ArrayList<>();
        new Instrumenter(parsed, edits).unit();
        edits.sort((a, b) -> Long.compare(b.at, a.at));
        StringBuilder out = new StringBuilder(parsed.content);
        for (Edit edit : edits) out.insert((int) edit.at, edit.text);
        return out.toString();
    }

    /**
     * Walks method bodies with the variables that are definitely assigned at each statement:
     * parameters, loop and catch variables, and local variables declared WITH an initializer
     * earlier in an enclosing block. Lambdas, anonymous and local classes are not entered; their
     * code runs without checkpoints.
     */
    private static final class Instrumenter {
        final Parsed parsed;
        final List<Edit> edits;

        Instrumenter(Parsed parsed, List<Edit> edits) {
            this.parsed = parsed;
            this.edits = edits;
        }

        void unit() {
            for (Tree declaration : parsed.unit.getTypeDecls()) {
                if (declaration instanceof ClassTree cls) type(cls);
            }
        }

        void type(ClassTree cls) {
            for (Tree member : cls.getMembers()) {
                if (member instanceof ClassTree nested) {
                    type(nested);
                } else if (member instanceof MethodTree method && method.getBody() != null
                        && !method.getName().contentEquals("<init>")) {
                    List<String> visible = new ArrayList<>();
                    for (VariableTree parameter : method.getParameters()) {
                        visible.add(parameter.getName().toString());
                    }
                    block(method.getBody(), visible);
                }
            }
        }

        void checkpoint(StatementTree statement, List<String> visible) {
            edits.add(new Edit(parsed.start(statement), call(statement, visible)));
        }

        String call(StatementTree statement, List<String> visible) {
            StringBuilder text = new StringBuilder("__sandbox.Checkpoint.at(").append(parsed.line(statement));
            for (String name : visible) text.append(", \"").append(name).append("\", ").append(name);
            return text.append("); ").toString();
        }

        void block(BlockTree block, List<String> visible) {
            statements(block.getStatements(), visible);
        }

        void statements(List<? extends StatementTree> statements, List<String> visible) {
            List<String> local = new ArrayList<>(visible);
            long previous = -1;
            for (StatementTree statement : statements) {
                // `int i = 0, j = 1;` is two declarations that start at the same position.
                long start = parsed.start(statement);
                if (start != previous) checkpoint(statement, local);
                previous = start;
                statement(statement, local);
                if (statement instanceof VariableTree variable && variable.getInitializer() != null) {
                    local.remove(variable.getName().toString());
                    local.add(variable.getName().toString());
                }
            }
        }

        /** A statement where only one is allowed: braces around it and its checkpoint. */
        void single(StatementTree statement, List<String> visible) {
            if (statement == null) return;
            if (statement instanceof BlockTree block) {
                block(block, visible);
                return;
            }
            edits.add(new Edit(parsed.start(statement), "{ " + call(statement, visible)));
            edits.add(new Edit(parsed.end(statement), " }"));
            statement(statement, visible);
        }

        void statement(StatementTree statement, List<String> visible) {
            if (statement instanceof BlockTree block) {
                block(block, visible);
            } else if (statement instanceof IfTree branch) {
                single(branch.getThenStatement(), visible);
                single(branch.getElseStatement(), visible);
            } else if (statement instanceof ForLoopTree loop) {
                List<String> inner = new ArrayList<>(visible);
                for (StatementTree initializer : loop.getInitializer()) {
                    if (initializer instanceof VariableTree variable && variable.getInitializer() != null) {
                        inner.add(variable.getName().toString());
                    }
                }
                single(loop.getStatement(), inner);
            } else if (statement instanceof EnhancedForLoopTree loop) {
                List<String> inner = new ArrayList<>(visible);
                inner.add(loop.getVariable().getName().toString());
                single(loop.getStatement(), inner);
            } else if (statement instanceof WhileLoopTree loop) {
                single(loop.getStatement(), visible);
            } else if (statement instanceof DoWhileLoopTree loop) {
                single(loop.getStatement(), visible);
            } else if (statement instanceof LabeledStatementTree labeled) {
                statement(labeled.getStatement(), visible);
            } else if (statement instanceof SwitchTree choice) {
                for (CaseTree branch : choice.getCases()) {
                    if (branch.getCaseKind() == CaseTree.CaseKind.STATEMENT) {
                        // Variables of earlier case groups are in scope but may be unassigned.
                        statements(branch.getStatements(), visible);
                    } else if (branch.getBody() instanceof BlockTree body) {
                        block(body, visible);
                    }
                }
            } else if (statement instanceof TryTree attempt) {
                List<String> inner = new ArrayList<>(visible);
                for (Tree resource : attempt.getResources()) {
                    if (resource instanceof VariableTree variable) inner.add(variable.getName().toString());
                }
                block(attempt.getBlock(), inner);
                for (CatchTree handler : attempt.getCatches()) {
                    List<String> caught = new ArrayList<>(visible);
                    caught.add(handler.getParameter().getName().toString());
                    block(handler.getBlock(), caught);
                }
                if (attempt.getFinallyBlock() != null) block(attempt.getFinallyBlock(), visible);
            } else if (statement instanceof SynchronizedTree synchronizedBlock) {
                block(synchronizedBlock.getBlock(), visible);
            }
            // Expression statements, declarations, return, throw, break, continue, yield, local
            // classes: no statements of their own to instrument.
        }
    }
}
