package __sandbox;

import java.io.File;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * google-java-format in AOSP style (four spaces), loaded by reflection from one of the vendored
 * jars. Releases up to 1.28.0 format on every JDK from 17; later ones need JDK 21 but follow newer
 * JDKs. So the newest jar whose minimum JDK this JVM meets is used, and if it cannot start here
 * (a missing compiler class), the next older one.
 */
final class JavaFormatter {
    private static final Pattern VERSION = Pattern.compile("google-java-format-(\\d+)\\.(\\d+)\\.(\\d+)");
    private static final Pattern POSITION = Pattern.compile("^(\\d+):(\\d+): (?:error: )?(.*)$", Pattern.DOTALL);

    private final List<File> candidates = new ArrayList<>();
    private Object formatter;
    private Method formatSource;

    JavaFormatter(List<String> jars) {
        int jdk = Runtime.version().feature();
        List<File> files = new ArrayList<>();
        for (String jar : jars) files.add(new File(jar));
        files.sort(Comparator.comparingLong(JavaFormatter::version).reversed());
        for (File file : files) {
            if (minimumJdk(file) <= jdk) candidates.add(file);
        }
    }

    /** 1.28.0 → 1_028_000 (0 for an unknown name). */
    static long version(File jar) {
        Matcher matcher = VERSION.matcher(jar.getName());
        if (!matcher.find()) return 0;
        return Long.parseLong(matcher.group(1)) * 1_000_000 + Long.parseLong(matcher.group(2)) * 1_000
                + Long.parseLong(matcher.group(3));
    }

    static int minimumJdk(File jar) {
        return version(jar) >= 1_029_000 ? 21 : 17;
    }

    /** {ok, content} or {ok: false, error}. */
    Map<String, Object> format(String content) {
        Map<String, Object> result = new LinkedHashMap<>();
        while (true) {
            try {
                if (formatter == null) load();
                result.put("ok", true);
                result.put("content", formatSource.invoke(formatter, content));
                return result;
            } catch (InvocationTargetException error) {
                Throwable cause = error.getCause() != null ? error.getCause() : error;
                if (cause instanceof LinkageError && next()) continue; // Needs a newer JDK.
                String message = String.valueOf(cause.getMessage());
                Matcher matcher = POSITION.matcher(message.strip());
                if (matcher.matches()) message = "line " + matcher.group(1) + ": " + matcher.group(3);
                int newline = message.indexOf('\n');
                if (newline > 0) message = message.substring(0, newline);
                result.put("ok", false);
                result.put("error", "Java could not format this draft: " + message);
                return result;
            } catch (ReflectiveOperationException | LinkageError error) {
                if (next()) continue;
                result.put("ok", false);
                result.put("error", "The Java formatter is not available on Java "
                        + Runtime.version().feature() + ": " + error);
                return result;
            }
        }
    }

    /** Drops the current formatter; false when no other one is left. */
    private boolean next() {
        formatter = null;
        formatSource = null;
        if (!candidates.isEmpty()) candidates.remove(0);
        return !candidates.isEmpty();
    }

    private void load() throws ReflectiveOperationException {
        if (candidates.isEmpty()) throw new ClassNotFoundException("no google-java-format jar for this JDK");
        URL url;
        try {
            url = candidates.get(0).toURI().toURL();
        } catch (java.net.MalformedURLException error) {
            throw new ClassNotFoundException(error.toString());
        }
        ClassLoader loader = new URLClassLoader(new URL[] {url}, JavaFormatter.class.getClassLoader());
        String base = "com.google.googlejavaformat.java.";
        Class<?> options = Class.forName(base + "JavaFormatterOptions", true, loader);
        Class<?> builderType = Class.forName(base + "JavaFormatterOptions$Builder", true, loader);
        Class<?> style = Class.forName(base + "JavaFormatterOptions$Style", true, loader);
        Object builder = options.getMethod("builder").invoke(null);
        @SuppressWarnings({"unchecked", "rawtypes"})
        Object aosp = Enum.valueOf((Class) style, "AOSP");
        builderType.getMethod("style", style).invoke(builder, aosp);
        Object built = builderType.getMethod("build").invoke(builder);
        Object created = Class.forName(base + "Formatter", true, loader).getConstructor(options).newInstance(built);
        formatSource = created.getClass().getMethod("formatSource", String.class);
        formatter = created;
    }
}
