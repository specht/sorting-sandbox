package __sandbox;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Keeps the Java compiler and formatter loaded between edits. One JSON request and one JSON reply
 * per line, the same protocol as tool/instrument_daemon.dart:
 *
 * <pre>
 *   {"id": 1, "op": "inspect",    "path": "...", "content": "..."}
 *   {"id": 2, "op": "instrument", "path": "...", "content": "...", "out": "DIR"}
 *   {"id": 3, "op": "format",     "path": "...", "content": "..."}
 * </pre>
 *
 * <p>{@code inspect} is parser-only (every save). {@code instrument} is the build: it compiles the
 * student's source into {@code out/benchmark} and the copy with checkpoints into {@code
 * out/visual}. This process never runs student code.
 *
 * <p>Started as {@code java … -cp RUNTIME:google-java-format.jar __sandbox.Daemon RUNTIME}.
 */
public final class Daemon {
    private final String runtimeClasspath;
    private Object formatter;

    private Daemon(String runtimeClasspath) {
        this.runtimeClasspath = runtimeClasspath;
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: __sandbox.Daemon RUNTIME_CLASSES");
            System.exit(64);
        }
        PrintStream out = new PrintStream(new FileOutputStream(FileDescriptor.out), false, StandardCharsets.UTF_8);
        System.setOut(System.err); // Nothing but replies on the protocol channel.
        Daemon daemon = new Daemon(args[0]);
        out.print(Json.write(Worker.message("type", "ready", "pid", ProcessHandle.current().pid())) + "\n");
        out.flush();
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        for (String line; (line = in.readLine()) != null; ) {
            if (line.isBlank()) continue;
            Object id = null;
            Map<String, Object> reply = new LinkedHashMap<>();
            try {
                Object parsed = Json.parse(line);
                if (!(parsed instanceof Map<?, ?> request) || !(request.get("id") instanceof Long)) {
                    throw new IllegalArgumentException("Invalid request.");
                }
                id = request.get("id");
                reply.putAll(daemon.handle(request));
            } catch (Throwable error) {
                reply.put("ok", false);
                reply.put("error", String.valueOf(error.getMessage() != null ? error.getMessage() : error));
            }
            Map<String, Object> answer = new LinkedHashMap<>();
            answer.put("id", id);
            answer.putAll(reply);
            out.print(Json.write(answer) + "\n");
            out.flush();
        }
    }

    private Map<String, Object> handle(Map<?, ?> request) throws Exception {
        Object op = request.get("op");
        if (!(request.get("content") instanceof String content) || !(request.get("path") instanceof String)) {
            throw new IllegalArgumentException("Invalid request.");
        }
        if ("inspect".equals(op)) return JavaSource.inspect(JavaSource.parse(content));
        if ("instrument".equals(op)) {
            if (!(request.get("out") instanceof String out)) throw new IllegalArgumentException("Missing output directory.");
            return instrument(content, new File(out));
        }
        if ("format".equals(op)) return format(content);
        throw new IllegalArgumentException("Unknown operation: " + op);
    }

    private Map<String, Object> instrument(String content, File out) {
        JavaSource.Parsed parsed = JavaSource.parse(content);
        Map<String, Object> result = JavaSource.inspect(parsed);
        if (!Boolean.TRUE.equals(result.get("ok"))) {
            result.put("error", "Fix the marked problem in your Java source and save again.");
            return result;
        }
        List<Map<String, Object>> errors = JavaSource.compile("algorithm.java", content,
                new File(out, "benchmark"), runtimeClasspath);
        if (!errors.isEmpty()) {
            return failure(result, "Fix the errors in your Java source and save again.", errors);
        }
        List<Map<String, Object>> visual = JavaSource.compile("visual.java", JavaSource.visual(parsed),
                new File(out, "visual"), runtimeClasspath);
        if (!visual.isEmpty()) {
            return failure(result, "Your code is valid Java, but the step-by-step visualizer cannot "
                    + "transform the marked line(s) yet. Try writing them more simply.", visual);
        }
        return result;
    }

    private static Map<String, Object> failure(Map<String, Object> inspected, String message,
            List<Map<String, Object>> diagnostics) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("ok", false);
        result.put("meta", inspected.get("meta"));
        result.put("error", message);
        result.put("diagnostics", diagnostics);
        return result;
    }

    // ------------------------------------------------------------------- formatting

    private static final Pattern POSITION = Pattern.compile("^(\\d+):(\\d+): (?:error: )?(.*)$", Pattern.DOTALL);

    /** google-java-format in AOSP style (four spaces), loaded by reflection. */
    private Map<String, Object> format(String content) {
        Map<String, Object> result = new LinkedHashMap<>();
        try {
            if (formatter == null) {
                String base = "com.google.googlejavaformat.java.";
                Class<?> options = Class.forName(base + "JavaFormatterOptions");
                Class<?> builderType = Class.forName(base + "JavaFormatterOptions$Builder");
                Class<?> style = Class.forName(base + "JavaFormatterOptions$Style");
                Object builder = options.getMethod("builder").invoke(null);
                @SuppressWarnings({"unchecked", "rawtypes"})
                Object aosp = Enum.valueOf((Class) style, "AOSP");
                builderType.getMethod("style", style).invoke(builder, aosp);
                Object built = builderType.getMethod("build").invoke(builder);
                formatter = Class.forName(base + "Formatter").getConstructor(options).newInstance(built);
            }
            Method formatSource = formatter.getClass().getMethod("formatSource", String.class);
            result.put("ok", true);
            result.put("content", formatSource.invoke(formatter, content));
        } catch (InvocationTargetException error) {
            Throwable cause = error.getCause() != null ? error.getCause() : error;
            String message = String.valueOf(cause.getMessage());
            Matcher matcher = POSITION.matcher(message.strip());
            if (matcher.matches()) message = "line " + matcher.group(1) + ": " + matcher.group(3);
            int newline = message.indexOf('\n');
            if (newline > 0) message = message.substring(0, newline);
            result.put("ok", false);
            result.put("error", "Java could not format this draft: " + message);
        } catch (ReflectiveOperationException | LinkageError error) {
            result.put("ok", false);
            result.put("error", "The Java formatter is not available: " + error);
        }
        return result;
    }
}
