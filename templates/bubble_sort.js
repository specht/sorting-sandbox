import { Colors, SortingAlgorithm } from "sorting-sandbox";

export default class BubbleSort extends SortingAlgorithm {
  name = "Bubble Sort";
  color = Colors.green;

  sort(list, scratch) {
    const length = list.length;
    for (let i = 0; i < length; i++) {
      for (let j = 0; j < length - 1; j++) {
        if (list[j].greaterThan(list[j + 1])) list.swap(j, j + 1);
      }
    }
  }
}
