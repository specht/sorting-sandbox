// Java worker, instrumenter and daemon tests: real processes, the host's protocol.
//
//   java test/JavaWorkerTest.java
//
// Compiles the sandbox runtime (languages/java/src) into a temporary directory first, exactly
// as the host does, then talks to the daemon and to worker processes.
import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.function.Predicate;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import javax.tools.ToolProvider;

public class JavaWorkerTest {
    static final Path ROOT = Path.of(".").toAbsolutePath().normalize();
    static final String HEADER = "import sandbox.sorting.*;\n\n";
    static final List<String> EXPORTS = List.of(
            "--add-exports=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.code=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED",
            "--add-exports=jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED");
    static Path runtime;
    static Path scratch;
    static String javaCommand;
    static Daemon daemon;
    static int passed = 0;
    static int next = 0;

    interface Body {
        void run() throws Exception;
    }

    static void test(String name, Body body) throws Exception {
        body.run();
        passed++;
        System.out.println("  ✓ " + name);
    }

    static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    static void equal(Object actual, Object expected, String what) {
        if (!String.valueOf(actual).equals(String.valueOf(expected))) {
            throw new AssertionError(what + ": expected " + expected + " but was " + actual);
        }
    }

    // ------------------------------------------------------------ tiny JSON reader

    /** Extracts "key":value (a number, a quoted string, [ints] or a boolean) from one line. */
    static String field(String json, String key) {
        Matcher m = Pattern.compile("\"" + Pattern.quote(key) + "\":(\"(?:[^\"\\\\]|\\\\.)*\"|\\[[^\\]]*\\]|[-0-9.]+|true|false|null)").matcher(json);
        if (!m.find()) return null;
        String value = m.group(1);
        return value.startsWith("\"") ? value.substring(1, value.length() - 1) : value;
    }

    static String metrics(String json) {
        return json.replaceAll(".*\"metrics\":(\\{[^}]*\\}).*", "$1");
    }

    static String quote(String text) {
        StringBuilder out = new StringBuilder("\"");
        for (char c : text.toCharArray()) {
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\n' -> out.append("\\n");
                default -> out.append(c);
            }
        }
        return out.append('"').toString();
    }

    // ------------------------------------------------------------------- processes

    static final class Daemon {
        final Process process;
        final BufferedReader out;
        final Writer in;
        int id = 0;

        Daemon() throws IOException {
            List<String> command = new ArrayList<>(List.of(javaCommand));
            command.addAll(EXPORTS);
            command.addAll(List.of("-cp", runtime.toString(), "__sandbox.Daemon", runtime.toString(),
                    ROOT.resolve("vendor/java/google-java-format-1.35.0-all-deps.jar").toString(),
                    ROOT.resolve("vendor/java/google-java-format-1.28.0-all-deps.jar").toString()));
            process = new ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.DISCARD).start();
            out = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8));
            in = new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8);
            String ready = out.readLine();
            check(ready != null && ready.contains("\"ready\""), "daemon ready: " + ready);
        }

        String request(String op, String content, Path outDirectory) throws IOException {
            id++;
            in.write("{\"id\":" + id + ",\"op\":\"" + op + "\",\"path\":\"x.java\",\"content\":" + quote(content)
                    + (outDirectory == null ? "" : ",\"out\":" + quote(outDirectory.toString())) + "}\n");
            in.flush();
            String reply = out.readLine();
            check(reply != null && reply.startsWith("{\"id\":" + id + ","), "reply " + reply);
            return reply;
        }
    }

    /** Builds [source] with the daemon into a fresh worker directory. */
    static Path build(String source) throws IOException {
        Path directory = scratch.resolve("w" + next++);
        String reply = daemon.request("instrument", source, directory);
        check(reply.contains("\"ok\":true"), "build failed: " + reply);
        return directory;
    }

    static List<String> talk(String source, String className, List<String> requests, int budget, int replies)
            throws IOException {
        Path directory = build(source);
        Process process = new ProcessBuilder(javaCommand, "-cp", runtime.toString(), "__sandbox.Worker",
                directory.toString(), className).redirectError(ProcessBuilder.Redirect.DISCARD).start();
        BufferedReader out = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8));
        Writer in = new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8);
        List<String> result = new ArrayList<>();
        try {
            check(out.readLine().contains("\"hello\""), "hello");
            for (String request : requests) in.write(request + "\n");
            in.flush();
            int open = replies;
            while (open > 0) {
                String line = out.readLine();
                if (line == null) break;
                result.add(line);
                String type = field(line, "type");
                if ("frame".equals(type) && "false".equals(field(line, "done"))) {
                    in.write("{\"type\":\"advance\",\"requestId\":\"v\",\"budget\":" + budget + "}\n");
                    in.flush();
                }
                if (Stream.of("runResult", "complete", "runError", "error").anyMatch(Predicate.isEqual(type))) open--;
            }
        } finally {
            process.destroyForcibly();
        }
        return result;
    }

    static String run(String source, String className, String values) throws IOException {
        List<String> replies = talk(source, className,
                List.of("{\"type\":\"run\",\"requestId\":\"r\",\"values\":" + values + "}"), 1, 1);
        return replies.stream().filter(line -> line.contains("\"runResult\"")).findFirst().orElseThrow();
    }

    static List<String> visual(String source, String className, String values, int budget) throws IOException {
        return talk(source, className,
                List.of("{\"type\":\"visualStart\",\"requestId\":\"v\",\"values\":" + values + "}"), budget, 1);
    }

    static List<String> frames(List<String> replies) {
        return replies.stream().filter(line -> line.contains("\"type\":\"frame\"")).toList();
    }

    static String algorithm(String className, String body, String extra) {
        return HEADER + "class " + className + " extends SortingAlgorithm {\n"
                + "    String name = \"" + className + "\";\n"
                + "    String color = Colors.RED;\n\n"
                + "    public void sort(Elements list, Elements scratch) {\n" + body + "\n    }\n" + extra + "}\n";
    }

    public static void main(String[] args) throws Exception {
        System.setOut(new java.io.PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.out), true,
                StandardCharsets.UTF_8));
        javaCommand = Path.of(System.getProperty("java.home"), "bin", "java").toString();
        scratch = Files.createTempDirectory("java-worker-test");
        runtime = scratch.resolve("runtime");
        List<String> sources;
        try (Stream<Path> files = Files.walk(ROOT.resolve("languages/java/src"))) {
            sources = files.filter(p -> p.toString().endsWith(".java")).map(Path::toString).toList();
        }
        List<String> javacArgs = new ArrayList<>(List.of("--release", "17", "-encoding", "UTF-8", "-d", runtime.toString()));
        javacArgs.addAll(sources);
        check(ToolProvider.getSystemJavaCompiler().run(null, null, null, javacArgs.toArray(String[]::new)) == 0,
                "the runtime compiles with --release 17");
        daemon = new Daemon();
        String template = Files.readString(ROOT.resolve("templates/bubble_sort.java"));

        test("the template runs step by step, sorts and counts like Dart", () -> {
            List<String> replies = visual(template, "BubbleSort", "[3,1,2]", 1);
            List<String> frames = frames(replies);
            String last = frames.get(frames.size() - 1);
            equal(field(last, "done"), true, "done");
            equal(field(last, "numbers"), "[1,2,3]", "numbers");
            equal(field(frames.get(0), "line"), 8, "first line");
            check(frames.stream().anyMatch(f -> "11".equals(field(f, "line"))), "the if line");
            check(frames.get(3).contains("\"i\":0"), "i in " + frames.get(3));
            check(frames.get(3).contains("\"list\":\"Elements(3)\""), "list");
            equal(field(last, "comparisons"), 6, "comparisons");
            check(replies.stream().anyMatch(line -> line.contains("\"complete\"")), "complete");
        });

        test("runs report keys, hidden origins and counts", () -> {
            String result = run(template, "BubbleSort", "[2,2,1]");
            equal(field(result, "keys"), "[1,2,2]", "keys");
            equal(field(result, "origins"), "[2,0,1]", "origins");
            List<String> both = talk(template, "BubbleSort", List.of(
                    "{\"type\":\"run\",\"requestId\":\"a\",\"values\":[]}",
                    "{\"type\":\"run\",\"requestId\":\"b\",\"values\":[5,4,3,2,1]}"), 1, 2);
            equal(field(both.get(0), "keys"), "[]", "empty");
            equal(field(both.get(1), "keys"), "[1,2,3,4,5]", "five");
        });

        test("swap counts exactly like a manual swap", () -> {
            String manual = run(algorithm("Manual",
                    "        Element temp = list.get(1);\n        list.set(1, list.get(0));\n        list.set(0, temp);", ""),
                    "Manual", "[2,1]");
            String swapped = run(algorithm("Swapped", "        list.swap(0, 1);", ""), "Swapped", "[2,1]");
            equal(metrics(manual), metrics(swapped), "metrics");
            equal(field(manual, "reads"), 2, "reads");
            equal(field(manual, "writes"), 2, "writes");
        });

        test("element locals show their hidden key", () -> {
            List<String> frames = frames(visual(algorithm("Peek",
                    "        Element first = list.get(0);\n        Element again = first;", ""), "Peek", "[42,7]", 1));
            check(frames.get(frames.size() - 1).contains("\"first\":42"), frames.get(frames.size() - 1));
        });

        String offByOne = algorithm("OffByOne", String.join("\n",
                "        System.out.println(\"start \" + 1);",
                "        for (int i = 0; i <= list.length; i++) {",
                "            if (list.get(i).greaterThan(list.get(0))) list.swap(i, 0);",
                "        }"), "");

        test("runtime errors and console output carry source lines", () -> {
            List<String> replies = visual(offByOne, "OffByOne", "[2,1]", 1);
            String console = replies.stream().filter(l -> l.contains("\"console\"")).findFirst().orElseThrow();
            equal(field(console, "text"), "start 1", "text");
            equal(field(console, "line"), 8, "console line");
            String error = replies.stream().filter(l -> l.contains("\"runError\"")).findFirst().orElseThrow();
            equal(field(error, "line"), 10, "error line");
            check(error.contains("IndexOutOfBoundsException: Index 2 is out of range"), error);
            String result = run(offByOne, "OffByOne", "[2,1]");
            equal(field(result, "line"), 10, "benchmark line");
            check(result.contains("OffByOne.sort · line 10"), result);
        });

        test("helpers, recursion and scratch work in the visual copy", () -> {
            String merge = HEADER + "class Merge extends SortingAlgorithm {\n"
                    + "    String name = \"Merge Sort\";\n"
                    + "    String color = Colors.ORANGE;\n\n"
                    + "    public void sort(Elements list, Elements scratch) {\n"
                    + "        mergeSort(list, scratch, 0, list.length);\n"
                    + "    }\n\n"
                    + "    void mergeSort(Elements list, Elements scratch, int left, int right) {\n"
                    + "        if (right - left < 2) return;\n"
                    + "        int middle = (left + right) / 2;\n"
                    + "        mergeSort(list, scratch, left, middle);\n"
                    + "        mergeSort(list, scratch, middle, right);\n"
                    + "        int i = left, j = middle;\n"
                    + "        for (int k = left; k < right; k++) {\n"
                    + "            if (i < middle && (j >= right || list.get(i).lessOrEqual(list.get(j)))) scratch.set(k, list.get(i++));\n"
                    + "            else scratch.set(k, list.get(j++));\n"
                    + "        }\n"
                    + "        for (int k = left; k < right; k++) list.set(k, scratch.get(k));\n"
                    + "    }\n"
                    + "}\n";
            List<String> frames = frames(visual(merge, "Merge", "[5,2,4,1,3]", 1));
            equal(field(frames.get(frames.size() - 1), "numbers"), "[1,2,3,4,5]", "numbers");
            check(frames.stream().anyMatch(f -> "12".equals(field(f, "line"))), "helper lines are traced");
            check(frames.stream().anyMatch(f -> f.contains("\"middle\":")), "middle is shown");
            StringBuilder values = new StringBuilder("[");
            for (int v = 300; v >= 1; v--) values.append(v).append(v > 1 ? "," : "]");
            String result = run(merge, "Merge", values.toString());
            check(result.contains("\"keys\":[1,2,3,"), result.substring(0, 80));
        });

        test("unusual statement positions keep their meaning and lines", () -> {
            String body = String.join("\n",
                    "        outer:",
                    "        for (int i = 0; i < list.length; i++) {",
                    "            for (int j = 0; j < list.length; j++) { if (j > i) continue outer; }",
                    "        }",
                    "        int n = 0;",
                    "        if (n == 1) n = 10; else if (n == 0) n = 20; else n = 30;",
                    "        switch (n) { case 20: int inner = n; n = inner + 1; break; default: n = -1; }",
                    "        do n++; while (n < 25);",
                    "        while (n < 30) n++;",
                    "        for (int value : new int[] {1, 2}) n += value;",
                    "        try { list.get(99); } catch (IndexOutOfBoundsException problem) { n = problem.getMessage().isEmpty() ? -1 : n; }",
                    "        switch (n) { case 33 -> n += 0; default -> { n = -1; } }",
                    "        int unassigned;",
                    "        unassigned = n;",
                    "        System.out.println(unassigned);",
                    "        if (list.length > 1 && list.get(0).greaterThan(list.get(1))) list.swap(0, 1);");
            List<String> replies = visual(algorithm("Shapes", body, ""), "Shapes", "[2,1]", 1);
            String console = replies.stream().filter(l -> l.contains("\"console\"")).findFirst().orElseThrow();
            equal(field(console, "text"), "33", "result");
            List<String> frames = frames(replies);
            equal(field(frames.get(frames.size() - 1), "numbers"), "[1,2]", "sorted");
            for (int line = 8; line <= 23; line++) {
                if (line == 9 || line == 11) continue; // the loop line and the closing brace
                final String expected = String.valueOf(line);
                check(frames.stream().anyMatch(f -> expected.equals(field(f, "line"))), "line " + line);
            }
        });

        test("deep recursion works and endless recursion is a stack overflow", () -> {
            String deep = algorithm("Deep", "        down(list.length);",
                    "\n    int down(int n) {\n        return n == 0 ? 0 : down(n - 1);\n    }\n");
            StringBuilder zeros = new StringBuilder("[0");
            for (int i = 1; i < 3000; i++) zeros.append(",0");
            check(run(deep, "Deep", zeros.append("]").toString()).contains("\"keys\":[0,0"), "deep");
            String endless = algorithm("Endless", "        down(1);",
                    "\n    int down(int n) {\n        return down(n - 1);\n    }\n");
            equal(field(run(endless, "Endless", "[1]"), "kind"), "stackOverflow", "kind");
        });

        test("stability is visible through origins", () -> {
            String selection = algorithm("Selection", String.join("\n",
                    "        for (int i = 0; i < list.length; i++) {",
                    "            int smallest = i;",
                    "            for (int j = i + 1; j < list.length; j++) if (list.get(j).lessThan(list.get(smallest))) smallest = j;",
                    "            if (smallest != i) list.swap(i, smallest);",
                    "        }"), "");
            String result = run(selection, "Selection", "[2,2,1]");
            equal(field(result, "keys"), "[1,2,2]", "keys");
            equal(field(result, "origins"), "[2,1,0]", "origins");
        });

        test("the contract: metadata and its problems", () -> {
            check(daemon.request("inspect", template, null).contains(
                    "\"meta\":{\"name\":\"Bubble Sort\",\"color\":\"#4CAF50\",\"className\":\"BubbleSort\"}"), "template");
            String base = algorithm("A", "", "");
            check(daemon.request("inspect", base.replace("Colors.RED", "\"#12abef\""), null).contains("#12ABEF"), "hex");
            check(daemon.request("inspect", base.replace("    String name = \"A\";\n",
                    "    String name = \"A\";\n    String author = \"Anna\";\n"), null).contains("\"author\":\"Anna\""), "author");
            String[][] cases = {
                {base.replace("public void sort(Elements list, Elements scratch) {", "public void sort(Elements list, Elements scratch {"), "expected", "7"},
                {HEADER + "class X {}\n", "No class extending SortingAlgorithm", null},
                {base + "class B extends SortingAlgorithm { public void sort(Elements a, Elements b) {} }\n", "exactly one class", null},
                {"package x;\n" + base, "Remove the package line", "1"},
                {base.replace("    String name = \"A\";\n", ""), "literal name", null},
                {base.replace("String name = \"A\";", "String name = \"A\" + 1;"), "literal name", null},
                {base.replace("Colors.RED", "Colors.MAUVE"), "color", null},
                {base.replace("public void sort(Elements list, Elements scratch)", "public void sorted(Elements list, Elements scratch)"), "Missing method", null},
                {base.replace("public void sort(Elements list, Elements scratch)", "public void sort(Elements list)"), "exactly two", null},
                {algorithm("A", "", "    A(int size) {}\n"), "constructor without parameters", null},
            };
            for (String[] c : cases) {
                String reply = daemon.request("inspect", c[0], null);
                check(reply.contains("\"ok\":false"), "should fail: " + c[1]);
                check(reply.contains(c[1]), c[1] + " in " + reply);
                if (c[2] != null) equal(field(reply, "line"), c[2], c[1] + " line");
            }
        });

        test("compile errors come back with the line of the student file", () -> {
            String typo = algorithm("Typo", "        list.swapp(0, 1);", "");
            String reply = daemon.request("instrument", typo, scratch.resolve("typo"));
            check(reply.contains("\"ok\":false"), reply);
            equal(field(reply, "line"), 8, "line");
            check(reply.contains("swapp"), reply);
            String wrongType = algorithm("WrongType", "        int x = list.get(0);", "");
            String types = daemon.request("instrument", wrongType, scratch.resolve("types"));
            equal(field(types, "line"), 8, "type error line");
            String empty = Files.readString(ROOT.resolve("templates/empty.java.tmpl"))
                    .replace("@@CLASS@@", "QuickSort").replace("@@NAME@@", "Quick Sort");
            check(daemon.request("instrument", empty, scratch.resolve("empty")).contains("\"name\":\"Quick Sort\""), "empty template");
        });

        test("the daemon formats with google-java-format (four spaces)", () -> {
            String reply = daemon.request("format", "class A{void f(){int x=1;if(x>0){x++;}}}\n", null);
            equal(field(reply, "content"), "class A {\\n    void f() {\\n        int x = 1;\\n        if (x > 0) {\\n            x++;\\n        }\\n    }\\n}\\n", "formatted");
            String broken = daemon.request("format", "class A { void f() { int x = } }\n", null);
            check(broken.contains("\"ok\":false") && broken.contains("line 1"), broken);
        });

        daemon.process.getOutputStream().close();
        daemon.process.waitFor();
        try (Stream<Path> files = Files.walk(scratch)) {
            files.sorted(Comparator.reverseOrder()).map(Path::toFile).forEach(File::delete);
        }
        System.out.println(passed + " Java worker tests passed.");
        System.exit(0);
    }
}
