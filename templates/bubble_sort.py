from sorting_sandbox import Colors, Elements, SortingAlgorithm


class BubbleSort(SortingAlgorithm):
    name = "Bubble Sort"
    color = Colors.GREEN

    def sort(self, elements: Elements, scratch: Elements) -> None:
        length = len(elements)
        for i in range(length):
            for j in range(length - 1):
                if elements[j] > elements[j + 1]:
                    elements.swap(j, j + 1)
