"""The deliberately tiny API students program against (Python version).

It mirrors the Dart package `sorting_sandbox_api`: students move and compare
`Element` objects inside `Elements` lists. Every read, write and comparison is
counted, and every element secretly remembers its original position, so the
sandbox can test stability without any bookkeeping in student code.

    from sorting_sandbox import SortingAlgorithm, Elements, Colors

    class BubbleSort(SortingAlgorithm):
        name = "Bubble Sort"
        color = Colors.GREEN

        def sort(self, elements: Elements, scratch: Elements) -> None:
            ...
"""

__all__ = ["Colors", "Element", "Elements", "SortingAlgorithm"]


class Colors:
    """Named colors for `color = Colors.GREEN`; any '#RRGGBB' string works too."""

    RED = "#F44336"
    PINK = "#E91E63"
    PURPLE = "#9C27B0"
    DEEP_PURPLE = "#673AB7"
    INDIGO = "#3F51B5"
    BLUE = "#2196F3"
    LIGHT_BLUE = "#03A9F4"
    CYAN = "#00BCD4"
    TEAL = "#009688"
    GREEN = "#4CAF50"
    LIGHT_GREEN = "#8BC34A"
    LIME = "#CDDC39"
    YELLOW = "#FFEB3B"
    AMBER = "#FFC107"
    ORANGE = "#FF9800"
    DEEP_ORANGE = "#FF5722"
    BROWN = "#795548"
    BLUE_GREY = "#607D8B"


class SortingAlgorithm:
    """Base class of one sorting algorithm.

    Subclasses set `name` and `color` as plain class attributes and implement
    `sort(self, elements, scratch)`. `author` is optional; when omitted, the
    sandbox uses the student's folder name.
    """

    name: str = ""
    color: str = Colors.BLUE
    author = None

    def sort(self, elements, scratch):
        raise NotImplementedError("Implement sort(self, elements, scratch).")


class Element:
    """One sortable item. Its value is hidden; compare it with another Element.

    `a < b`, `a <= b`, `a > b`, `a >= b`, `a == b` and `a != b` each count as
    one comparison.
    """

    __slots__ = ("_Element__key", "_Element__origin", "_Element__probe")

    def __init__(self, key, origin, probe):
        self.__key = key
        self.__origin = origin
        self.__probe = probe

    def __not_comparable(self, other):
        return TypeError(
            "An Element can only be compared with another Element, "
            f"not with {type(other).__name__}."
        )

    def __lt__(self, other):
        if other.__class__ is not Element:
            raise self.__not_comparable(other)
        self.__probe.comparisons += 1
        return self.__key < other.__key

    def __le__(self, other):
        if other.__class__ is not Element:
            raise self.__not_comparable(other)
        self.__probe.comparisons += 1
        return self.__key <= other.__key

    def __gt__(self, other):
        if other.__class__ is not Element:
            raise self.__not_comparable(other)
        self.__probe.comparisons += 1
        return self.__key > other.__key

    def __ge__(self, other):
        if other.__class__ is not Element:
            raise self.__not_comparable(other)
        self.__probe.comparisons += 1
        return self.__key >= other.__key

    def __eq__(self, other):
        if other.__class__ is not Element:
            return False
        self.__probe.comparisons += 1
        return self.__key == other.__key

    def __ne__(self, other):
        return not self.__eq__(other)

    # Equal Elements need equal hashes, but the hash must not reveal the key.
    def __hash__(self):
        return 0

    def __repr__(self):
        return "Element"


class Elements:
    """A list of Elements with a fixed length.

        len(elements)            number of elements
        elements[i]              read an element (one read)
        elements[i] = element    write an element (one write)
        elements.swap(i, j)      two reads and two writes
    """

    __slots__ = ("_Elements__label", "_Elements__items", "_Elements__probe")

    def __init__(self, probe, label, values, origins):
        if len(values) != len(origins):
            raise ValueError("values and origins must have equal length")
        self.__probe = probe
        self.__label = label
        self.__items = [Element(v, o, probe) for v, o in zip(values, origins)]

    def __len__(self):
        return len(self.__items)

    @property
    def length(self):
        """The same as len(elements)."""
        return len(self.__items)

    def __index(self, index):
        if isinstance(index, slice):
            raise TypeError(
                "Slices are not supported: read and write one element at a time."
            )
        if isinstance(index, bool) or not isinstance(index, int):
            raise TypeError(
                f"Indices must be integers, not {type(index).__name__}."
            )
        length = len(self.__items)
        if index < 0 or index >= length:
            valid = "the list is empty" if length == 0 else f"valid: 0 … {length - 1}"
            raise IndexError(f"Index {index} is out of range ({valid}).")
        return index

    def __getitem__(self, index):
        items = self.__items
        if type(index) is not int or not 0 <= index < len(items):
            index = self.__index(index)
        value = items[index]
        self.__probe.read(self.__label, index)
        return value

    def __setitem__(self, index, value):
        items = self.__items
        if type(index) is not int or not 0 <= index < len(items):
            index = self.__index(index)
        if value.__class__ is not Element:
            raise TypeError(
                f"Only Elements can be stored, not {type(value).__name__}."
            )
        items[index] = value
        self.__probe.write(self.__label, index)

    def swap(self, a, b):
        """Convenience only: exactly two reads and two writes."""
        temp = self[b]
        self[b] = self[a]
        self[a] = temp

    def __iter__(self):
        for index in range(len(self.__items)):
            yield self[index]

    def __repr__(self):
        return f"Elements({len(self.__items)})"


# ---------------------------------------------------------------- sandbox
# Used by the worker only. Students never need these.


def _keys(elements):
    return [item._Element__key for item in elements._Elements__items]


def _origins(elements):
    return [item._Element__origin for item in elements._Elements__items]


def _key(element):
    return element._Element__key
