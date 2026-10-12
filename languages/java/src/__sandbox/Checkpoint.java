package __sandbox;

/**
 * Called by the visual copy of a Java algorithm before every statement:
 *
 * <pre>__sandbox.Checkpoint.at(12, "i", i, "j", j); for (…) …</pre>
 *
 * <p>The call is inserted on the statement's own line, so line numbers stay the student's. In
 * benchmark runs no copy with checkpoints is loaded at all.
 */
public final class Checkpoint {
    private Checkpoint() {}

    static volatile Worker.VisualSession session;

    public static void at(int line, Object... namesAndValues) {
        Worker.VisualSession current = session;
        if (current != null) current.reached(line, namesAndValues);
    }
}
