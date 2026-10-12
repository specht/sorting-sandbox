import sandbox.sorting.*;

class BubbleSort extends SortingAlgorithm {
    String name = "Bubble Sort";
    String color = Colors.GREEN;

    public void sort(Elements list, Elements scratch) {
        int length = list.length;
        for (int i = 0; i < length; i++) {
            for (int j = 0; j < length - 1; j++) {
                if (list.get(j).greaterThan(list.get(j + 1))) list.swap(j, j + 1);
            }
        }
    }
}
