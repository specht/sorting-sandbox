package sandbox.sorting;

/**
 * Base class of one sorting algorithm.
 *
 * <p>Subclasses declare {@code String name = "…";} and {@code String color = Colors.GREEN;}
 * (optionally {@code String author = "…";}) and implement {@link #sort}. When the author is
 * omitted, the sandbox uses the student's folder name.
 */
public abstract class SortingAlgorithm {
    /**
     * Sorts {@code list} in ascending order. {@code scratch} is a temporary list of the same
     * length that may be used, for example for Merge Sort.
     */
    public abstract void sort(Elements list, Elements scratch);
}
