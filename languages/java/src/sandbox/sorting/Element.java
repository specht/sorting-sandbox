package sandbox.sorting;

/**
 * One sortable item. Its value is hidden; compare it with another Element.
 *
 * <p>{@code a.lessThan(b)}, {@code a.lessOrEqual(b)}, {@code a.greaterThan(b)}, {@code
 * a.greaterOrEqual(b)} and {@code a.equalTo(b)} (also {@code a.equals(b)}) each count as one
 * comparison.
 */
public final class Element {
    final int key;
    final int origin;
    final Probe probe;

    Element(int key, int origin, Probe probe) {
        this.key = key;
        this.origin = origin;
        this.probe = probe;
    }

    private int keyOf(Element other) {
        if (other == null) {
            throw new NullPointerException("An Element cannot be compared with null.");
        }
        probe.comparisons++;
        return other.key;
    }

    public boolean lessThan(Element other) {
        return key < keyOf(other);
    }

    public boolean lessOrEqual(Element other) {
        return key <= keyOf(other);
    }

    public boolean greaterThan(Element other) {
        return key > keyOf(other);
    }

    public boolean greaterOrEqual(Element other) {
        return key >= keyOf(other);
    }

    public boolean equalTo(Element other) {
        return key == keyOf(other);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof Element element && equalTo(element);
    }

    /** Equal Elements need equal hash codes, but the hash must not reveal the key. */
    @Override
    public int hashCode() {
        return 0;
    }

    @Override
    public String toString() {
        return "Element";
    }
}
