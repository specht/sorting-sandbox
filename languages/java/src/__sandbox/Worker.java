package __sandbox;

import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PrintStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import sandbox.sorting.Element;
import sandbox.sorting.Elements;
import sandbox.sorting.Probe;
import sandbox.sorting.SortingAlgorithm;

/**
 * Worker process for one Java sorting algorithm (one revision of one file). Started by the host
 * as
 *
 * <pre>java -cp RUNTIME __sandbox.Worker WORKER_DIRECTORY CLASS_NAME</pre>
 *
 * where the directory holds the classes compiled by the daemon: {@code benchmark/} from the
 * student's source and {@code visual/} from the copy with checkpoints. It speaks the protocol of
 * the Dart worker (lib/worker_core.dart), one JSON object per line: visualStart, advance and run;
 * replies hello, frame, console, complete, runError, runResult and error.
 *
 * <p>Student code is synchronous, so a checkpoint simply blocks on reading stdin until the host
 * grants more budget. Stop kills the process.
 */
public final class Worker {
    private static final int MAX_PRINTS = 200;
    private static final int MAX_PRINT_CHARACTERS = 65536;

    private static PrintStream protocol;
    private static BufferedReader input;
    private static Console console;

    private final File directory;
    private final String className;
    private final Map<String, Object> loaded = new LinkedHashMap<>();

    private Worker(File directory, String className) {
        this.directory = directory;
        this.className = className;
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("usage: __sandbox.Worker WORKER_DIRECTORY CLASS_NAME");
            System.exit(64);
        }
        protocol = new PrintStream(new FileOutputStream(FileDescriptor.out), false, StandardCharsets.UTF_8);
        input = new BufferedReader(
                new InputStreamReader(new FileInputStream(FileDescriptor.in), StandardCharsets.UTF_8));
        System.setIn(new ByteArrayInputStream(new byte[0]));
        console = new Console();
        System.setOut(new PrintStream(console, true, StandardCharsets.UTF_8));

        Worker worker = new Worker(new File(args[0]), args[1]);
        // Deep recursion (e.g. Quicksort on sorted input) needs a large stack.
        Thread thread = new Thread(null, worker::serve, "student", 512L * 1024 * 1024);
        thread.start();
        thread.join();
        protocol.flush();
        // A suspended visual run must not keep the process alive.
        Runtime.getRuntime().halt(0);
    }

    static synchronized void post(Map<String, Object> message) {
        String encoded;
        try {
            encoded = Json.write(message);
        } catch (RuntimeException error) {
            encoded = Json.write(Map.of("type", "error",
                    "message", "Could not encode a worker message: " + error));
        }
        protocol.print(encoded);
        protocol.print('\n');
        protocol.flush();
    }

    static Map<String, Object> message(Object... pairs) {
        Map<String, Object> result = new LinkedHashMap<>();
        for (int i = 0; i + 1 < pairs.length; i += 2) result.put((String) pairs[i], pairs[i + 1]);
        return result;
    }

    // ---------------------------------------------------------------- student code

    /** The constructor of the student's class from benchmark/ or visual/, or a failure map. */
    private Object load(String variant) {
        return loaded.computeIfAbsent(variant, name -> {
            try {
                URL url = new File(directory, name).toURI().toURL();
                URLClassLoader loader = new URLClassLoader(new URL[] {url}, Worker.class.getClassLoader());
                Class<?> cls = Class.forName(className, true, loader);
                if (!SortingAlgorithm.class.isAssignableFrom(cls)) {
                    throw new IllegalStateException(className + " does not extend SortingAlgorithm.");
                }
                Constructor<?> constructor = cls.getDeclaredConstructor();
                constructor.setAccessible(true);
                return constructor;
            } catch (Throwable error) {
                return failure(unwrap(error), 0);
            }
        });
    }

    private static Throwable unwrap(Throwable error) {
        while ((error instanceof InvocationTargetException || error instanceof ExceptionInInitializerError)
                && error.getCause() != null) {
            error = error.getCause();
        }
        return error;
    }

    private static SortingAlgorithm create(Constructor<?> constructor) throws Throwable {
        try {
            return (SortingAlgorithm) constructor.newInstance();
        } catch (InvocationTargetException error) {
            throw unwrap(error);
        }
    }

    // ------------------------------------------------------------------- failures

    /** An exception as {kind, message, line?, stack?} in the student's own lines. */
    static Map<String, Object> failure(Throwable error, int fallbackLine) {
        Integer firstLine = null;
        List<String> frames = new ArrayList<>();
        for (StackTraceElement frame : error.getStackTrace()) {
            String file = frame.getFileName();
            if (!"algorithm.java".equals(file) && !"visual.java".equals(file)) continue;
            if (frame.getLineNumber() <= 0) continue;
            if (firstLine == null) firstLine = frame.getLineNumber();
            if (frames.size() < 8) {
                String owner = frame.getClassName();
                owner = owner.substring(owner.lastIndexOf('.') + 1);
                frames.add(owner + "." + frame.getMethodName() + " · line " + frame.getLineNumber());
            }
        }
        String text = error.getMessage();
        String message = error.getClass().getSimpleName()
                + (text == null || text.isEmpty() ? "" : ": " + text);
        if (message.length() > 1500) message = message.substring(0, 1500) + "…";
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("kind", error instanceof StackOverflowError ? "stackOverflow" : "runtime");
        result.put("message", message);
        if (firstLine != null) {
            result.put("line", firstLine);
        } else if (fallbackLine > 0) {
            result.put("line", fallbackLine);
        }
        if (!frames.isEmpty()) result.put("stack", frames);
        return result;
    }

    // ---------------------------------------------------------------- single sorts

    private Map<String, Object> runCase(int[] values) {
        Object loadedClass = load("benchmark");
        if (!(loadedClass instanceof Constructor<?> constructor)) {
            return message("error", loadedClass);
        }
        Probe probe = new Probe(false);
        Elements[] lists = lists(probe, values);
        console.sink = null;
        try {
            create(constructor).sort(lists[0], lists[1]);
        } catch (Throwable error) {
            return message("error", failure(error, 0));
        }
        return message("keys", Probe.keys(lists[0]), "origins", Probe.origins(lists[0]),
                "metrics", probe.metrics());
    }

    static Elements[] lists(Probe probe, int[] values) {
        int n = values.length;
        int[] origins = new int[n];
        int[] scratchOrigins = new int[n];
        for (int i = 0; i < n; i++) {
            origins[i] = i;
            scratchOrigins[i] = -1 - i;
        }
        return new Elements[] {
            Probe.elements(probe, "list", values, origins),
            Probe.elements(probe, "scratch", new int[n], scratchOrigins),
        };
    }

    // ----------------------------------------------------------------- visual runs

    static final class VisualSession {
        final String requestId;
        final Probe probe = new Probe(true);
        Elements list;
        Elements scratch;
        int budget = 0;
        int line = 0;
        int checkpoint = -1;
        Object[] locals = new Object[0];
        int printed = 0;
        int characters = 0;
        boolean truncated = false;

        VisualSession(String requestId) {
            this.requestId = requestId;
        }

        void reached(int line, Object[] namesAndValues) {
            checkpoint++;
            this.line = line;
            locals = namesAndValues;
            if (budget > 0) {
                budget--;
                if (budget > 0) {
                    // A coarse animation frame skips many checkpoints; memory highlighting
                    // describes only the final step, as in Dart.
                    probe.discardMarkers();
                    return;
                }
            }
            emit(false);
            await();
        }

        void await() {
            while (budget <= 0) {
                String raw;
                try {
                    raw = input.readLine();
                } catch (IOException error) {
                    raw = null;
                }
                if (raw == null) {
                    protocol.flush();
                    Runtime.getRuntime().halt(0);
                }
                Object parsed;
                try {
                    parsed = Json.parse(raw);
                } catch (RuntimeException error) {
                    post(message("type", "error", "message", "Invalid worker request."));
                    continue;
                }
                if (!(parsed instanceof Map<?, ?> request)) continue;
                if ("advance".equals(request.get("type"))) {
                    Object amount = request.get("budget");
                    long value = amount instanceof Number number ? number.longValue() : 1;
                    if (value > 0) budget += (int) Math.min(value, Integer.MAX_VALUE - budget);
                } else {
                    post(message("type", "error", "requestId", String.valueOf(request.get("requestId")),
                            "message", "This worker is busy with a visual run."));
                }
            }
        }

        void emit(boolean done) {
            Map<String, Object> visible = new LinkedHashMap<>();
            for (int i = 0; i + 1 < locals.length; i += 2) {
                Object value = debugValue(locals[i + 1]);
                visible.put(String.valueOf(locals[i]), value);
            }
            post(message("type", "frame", "requestId", requestId, "done", done, "line", line,
                    "checkpoint", checkpoint, "locals", visible,
                    "numbers", list == null ? new int[0] : Probe.keys(list),
                    "scratch", scratch == null ? new int[0] : Probe.keys(scratch),
                    "metrics", probe.metrics(), "reads", probe.takeReads(), "writes", probe.takeWrites()));
        }

        void print(String text) {
            String kind = "stdout";
            if (printed < MAX_PRINTS && characters + text.length() <= MAX_PRINT_CHARACTERS) {
                printed++;
                characters += text.length();
            } else if (!truncated) {
                truncated = true;
                kind = "warning";
                text = "Further print output was truncated.";
            } else {
                return;
            }
            Map<String, Object> message = message("type", "console", "requestId", requestId,
                    "kind", kind, "text", text, "checkpoint", checkpoint);
            if (line > 0) message.put("line", line);
            post(message);
        }

        void run(Object loadedClass, int[] values) {
            Elements[] lists = lists(probe, values);
            list = lists[0];
            scratch = lists[1];
            if (!(loadedClass instanceof Constructor<?> constructor)) {
                post(message("type", "runError", "requestId", requestId, "checkpoint", checkpoint,
                        "error", loadedClass));
                return;
            }
            Checkpoint.session = this;
            console.sink = this;
            try {
                create(constructor).sort(list, scratch);
            } catch (Throwable error) {
                console.flushLine();
                console.sink = null;
                emit(false);
                post(message("type", "runError", "requestId", requestId, "checkpoint", checkpoint,
                        "error", failure(error, line)));
                return;
            } finally {
                Checkpoint.session = null;
            }
            console.flushLine();
            console.sink = null;
            emit(true);
            post(message("type", "complete", "requestId", requestId));
        }
    }

    static Object debugValue(Object value) {
        if (value == null || value instanceof Boolean) return value;
        if (value instanceof Integer || value instanceof Long || value instanceof Short
                || value instanceof Byte) {
            return value;
        }
        if (value instanceof Double || value instanceof Float) {
            double number = ((Number) value).doubleValue();
            return Double.isFinite(number) ? number : String.valueOf(number);
        }
        if (value instanceof Character c) return String.valueOf(c);
        if (value instanceof String text) return shorten(text);
        if (value instanceof Element element) return Probe.key(element);
        if (value instanceof Elements elements) return "Elements(" + elements.length + ")";
        if (value.getClass().isArray()) {
            return value.getClass().getComponentType().getSimpleName() + "[" + java.lang.reflect.Array.getLength(value) + "]";
        }
        if (value instanceof Collection<?> collection) {
            return value.getClass().getSimpleName() + "(" + collection.size() + ")";
        }
        try {
            return shorten(String.valueOf(value));
        } catch (RuntimeException error) {
            return value.getClass().getSimpleName();
        }
    }

    static String shorten(String text) {
        return text.length() <= 48 ? text : text.substring(0, 45) + "…";
    }

    /** System.out of student code: whole lines become console messages of the visual run. */
    static final class Console extends OutputStream {
        volatile VisualSession sink;
        private final ByteArrayOutputStream line = new ByteArrayOutputStream();

        @Override
        public synchronized void write(int b) {
            if (sink == null) return;
            if (b == '\n') {
                flushLine();
            } else {
                line.write(b);
            }
        }

        @Override
        public synchronized void write(byte[] bytes, int offset, int length) {
            if (sink == null) return;
            for (int i = offset; i < offset + length; i++) write(bytes[i]);
        }

        synchronized void flushLine() {
            VisualSession target = sink;
            if (target != null && line.size() > 0) {
                String text = line.toString(StandardCharsets.UTF_8);
                if (text.endsWith("\r")) text = text.substring(0, text.length() - 1);
                target.print(text);
            }
            line.reset();
        }
    }

    // ------------------------------------------------------------------------ main

    private void serve() {
        boolean visualUsed = false;
        post(message("type", "hello", "pid", ProcessHandle.current().pid()));
        for (;;) {
            String raw;
            try {
                raw = input.readLine();
            } catch (IOException error) {
                return;
            }
            if (raw == null) return;
            if (raw.isBlank()) continue;
            Object parsed;
            try {
                parsed = Json.parse(raw);
            } catch (RuntimeException error) {
                post(message("type", "error", "message", "Invalid worker request."));
                continue;
            }
            if (!(parsed instanceof Map<?, ?> request)) continue;
            Object type = request.get("type");
            Object rawId = request.get("requestId");
            String requestId = rawId == null ? "" : String.valueOf(rawId);
            try {
                if ("run".equals(type)) {
                    Map<String, Object> reply = message("type", "runResult", "requestId", requestId);
                    reply.putAll(runCase(ints(request.get("values"))));
                    post(reply);
                } else if ("visualStart".equals(type)) {
                    if (visualUsed) throw new IllegalStateException("This worker has already run a visual algorithm.");
                    visualUsed = true;
                    new VisualSession(requestId).run(load("visual"), ints(request.get("values")));
                } else if (!"advance".equals(type)) {
                    post(message("type", "error", "requestId", requestId, "message", "Unknown worker message: " + type));
                }
            } catch (Throwable error) {
                post(message("type", "error", "requestId", requestId, "message", String.valueOf(error),
                        "error", failure(error, 0)));
            }
        }
    }

    private static int[] ints(Object raw) {
        if (!(raw instanceof List<?> list)) return new int[0];
        int[] result = new int[list.size()];
        int count = 0;
        for (Object value : list) {
            if (value instanceof Number number) result[count++] = number.intValue();
        }
        return java.util.Arrays.copyOf(result, count);
    }
}
