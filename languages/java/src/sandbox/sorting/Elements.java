package sandbox.sorting;

import java.util.Iterator;
import java.util.NoSuchElementException;

/**
 * A list of Elements with a fixed length.
 *
 * <pre>
 *   list.length           number of elements
 *   list.get(i)           read an element (one read)
 *   list.set(i, element)  write an element (one write)
 *   list.swap(i, j)       two reads and two writes
 * </pre>
 */
public final class Elements implements Iterable<Element> {
    /** The number of elements; it never changes. */
    public final int length;

    final Element[] items;
    final String label;
    final Probe probe;

    Elements(Probe probe, String label, int[] values, int[] origins) {
        this.probe = probe;
        this.label = label;
        this.length = values.length;
        this.items = new Element[values.length];
        for (int i = 0; i < values.length; i++) {
            items[i] = new Element(values[i], origins[i], probe);
        }
    }

    private int index(int index) {
        if (index < 0 || index >= length) {
            String valid = length == 0 ? "the list is empty" : "valid: 0 … " + (length - 1);
            throw new IndexOutOfBoundsException(
                    "Index " + index + " is out of range (" + valid + ").");
        }
        return index;
    }

    public Element get(int index) {
        Element value = items[index(index)];
        probe.read(label, index);
        return value;
    }

    public void set(int index, Element value) {
        index(index);
        if (value == null) {
            throw new NullPointerException("Only Elements can be stored, not null.");
        }
        items[index] = value;
        probe.write(label, index);
    }

    /** Convenience only: exactly two reads and two writes. */
    public void swap(int a, int b) {
        Element temp = get(b);
        set(b, get(a));
        set(a, temp);
    }

    /** Reads every element in order (one read each). */
    @Override
    public Iterator<Element> iterator() {
        return new Iterator<>() {
            private int next = 0;

            @Override
            public boolean hasNext() {
                return next < length;
            }

            @Override
            public Element next() {
                if (next >= length) throw new NoSuchElementException();
                return get(next++);
            }
        };
    }

    @Override
    public String toString() {
        return "Elements(" + length + ")";
    }
}
