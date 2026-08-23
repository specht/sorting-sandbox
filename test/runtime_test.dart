import 'package:flutter_test/flutter_test.dart';
import 'package:sorting_sandbox/sandbox_worker_runtime.dart';
import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

class StableInsertion extends SortingAlgorithm {
  @override
  String get name => 'Insertion';
  @override
  String get color => '#000000';

  void sort(Elements list, Elements scratch) {
    for (var i = 1; i < list.length; i++) {
      final value = list[i];
      var j = i - 1;
      while (j >= 0 && list[j] > value) {
        list[j + 1] = list[j];
        j--;
      }
      list[j + 1] = value;
    }
  }
}

class UnstableSelection extends SortingAlgorithm {
  @override
  String get name => 'Selection';
  @override
  String get color => '#000000';

  void sort(Elements list, Elements scratch) {
    for (var i = 0; i < list.length; i++) {
      var min = i;
      for (var j = i + 1; j < list.length; j++) {
        if (list[j] < list[min]) min = j;
      }
      if (min != i) list.swap(i, min);
    }
  }
}

void main() {
  test('hidden origins detect stability without student annotations', () {
    final stable = runSyncAlgorithm(StableInsertion(), [2, 2, 1]);
    final unstable = runSyncAlgorithm(UnstableSelection(), [2, 2, 1]);
    expect(stable.sorted, isTrue);
    expect(stable.stable, isTrue);
    expect(unstable.sorted, isTrue);
    expect(unstable.stable, isFalse);
  });
}
