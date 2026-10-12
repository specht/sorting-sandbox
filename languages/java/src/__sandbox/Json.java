package __sandbox;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Just enough JSON for the host protocol: no dependencies in the sandbox runtime. */
public final class Json {
    private Json() {}

    // ------------------------------------------------------------------ writing

    public static String write(Object value) {
        StringBuilder out = new StringBuilder();
        write(value, out);
        return out.toString();
    }

    private static void write(Object value, StringBuilder out) {
        if (value == null) {
            out.append("null");
        } else if (value instanceof String text) {
            string(text, out);
        } else if (value instanceof Boolean) {
            out.append(value);
        } else if (value instanceof Double || value instanceof Float) {
            double number = ((Number) value).doubleValue();
            if (Double.isFinite(number)) {
                out.append(number == Math.rint(number) && Math.abs(number) < 1e15
                        ? Long.toString((long) number) + ".0"
                        : Double.toString(number));
            } else {
                string(Double.toString(number), out);
            }
        } else if (value instanceof Number) {
            out.append(value);
        } else if (value instanceof Map<?, ?> map) {
            out.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!first) out.append(',');
                first = false;
                string(String.valueOf(entry.getKey()), out);
                out.append(':');
                write(entry.getValue(), out);
            }
            out.append('}');
        } else if (value instanceof Iterable<?> list) {
            out.append('[');
            boolean first = true;
            for (Object item : list) {
                if (!first) out.append(',');
                first = false;
                write(item, out);
            }
            out.append(']');
        } else if (value instanceof int[] array) {
            out.append('[');
            for (int i = 0; i < array.length; i++) {
                if (i > 0) out.append(',');
                out.append(array[i]);
            }
            out.append(']');
        } else {
            string(value.toString(), out);
        }
    }

    private static void string(String text, StringBuilder out) {
        out.append('"');
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                default -> {
                    if (c < 0x20 || c == 0x2028 || c == 0x2029) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
                }
            }
        }
        out.append('"');
    }

    // ------------------------------------------------------------------ reading

    /** Parses one JSON value; numbers become Long or Double. */
    public static Object parse(String text) {
        Parser parser = new Parser(text);
        parser.space();
        Object value = parser.value();
        parser.space();
        if (parser.at < text.length()) throw parser.error("trailing characters");
        return value;
    }

    private static final class Parser {
        final String text;
        int at = 0;

        Parser(String text) {
            this.text = text;
        }

        IllegalArgumentException error(String message) {
            return new IllegalArgumentException("Invalid JSON at " + at + ": " + message);
        }

        void space() {
            while (at < text.length() && Character.isWhitespace(text.charAt(at))) at++;
        }

        char peek() {
            if (at >= text.length()) throw error("unexpected end");
            return text.charAt(at);
        }

        void expect(char c) {
            if (peek() != c) throw error("expected " + c);
            at++;
        }

        Object value() {
            char c = peek();
            switch (c) {
                case '{': return object();
                case '[': return array();
                case '"': return string();
                case 't': literal("true"); return Boolean.TRUE;
                case 'f': literal("false"); return Boolean.FALSE;
                case 'n': literal("null"); return null;
                default: return number();
            }
        }

        void literal(String word) {
            if (!text.startsWith(word, at)) throw error("expected " + word);
            at += word.length();
        }

        Map<String, Object> object() {
            Map<String, Object> result = new LinkedHashMap<>();
            expect('{');
            space();
            if (peek() == '}') {
                at++;
                return result;
            }
            for (;;) {
                space();
                String key = string();
                space();
                expect(':');
                space();
                result.put(key, value());
                space();
                if (peek() == ',') {
                    at++;
                    continue;
                }
                expect('}');
                return result;
            }
        }

        List<Object> array() {
            List<Object> result = new ArrayList<>();
            expect('[');
            space();
            if (peek() == ']') {
                at++;
                return result;
            }
            for (;;) {
                space();
                result.add(value());
                space();
                if (peek() == ',') {
                    at++;
                    continue;
                }
                expect(']');
                return result;
            }
        }

        String string() {
            expect('"');
            StringBuilder out = new StringBuilder();
            for (;;) {
                char c = peek();
                at++;
                if (c == '"') return out.toString();
                if (c != '\\') {
                    out.append(c);
                    continue;
                }
                char escape = peek();
                at++;
                switch (escape) {
                    case 'n' -> out.append('\n');
                    case 'r' -> out.append('\r');
                    case 't' -> out.append('\t');
                    case 'b' -> out.append('\b');
                    case 'f' -> out.append('\f');
                    case 'u' -> {
                        if (at + 4 > text.length()) throw error("bad escape");
                        out.append((char) Integer.parseInt(text.substring(at, at + 4), 16));
                        at += 4;
                    }
                    default -> out.append(escape);
                }
            }
        }

        Object number() {
            int start = at;
            while (at < text.length() && "+-0123456789.eE".indexOf(text.charAt(at)) >= 0) at++;
            String token = text.substring(start, at);
            if (token.isEmpty()) throw error("unexpected character");
            if (token.contains(".") || token.contains("e") || token.contains("E")) {
                return Double.parseDouble(token);
            }
            return Long.parseLong(token);
        }
    }
}
