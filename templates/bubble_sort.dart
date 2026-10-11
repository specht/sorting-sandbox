import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

class BubbleSort extends SortingAlgorithm {
  get name => 'Bubble Sort';
  get color => Colors.green;

  void sort(Elements list, Elements scratch) {
    int length = list.length;
    for (int i = 0; i < length; i++) {
      for (int j = 0; j < length - 1; j++) {
        if (list[j] > list[j + 1]) list.swap(j, j + 1);
      }
    }
  }
}
