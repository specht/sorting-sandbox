import 'package:flutter_test/flutter_test.dart';

import '../tool/instrumenter.dart';

void main() {
  test('bubble sort gets async checkpoints and visible loop variables', () {
    const source = r'''
import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

class Bubble extends SortingAlgorithm {
  get name => 'Bubble';
  get color => '#123456';

  void sort(Elements list, Elements scratch) {
    int length = list.length;
    for (int i = 0; i < length; i++) {
      for (int j = 0; j < length - i - 1; j++) {
        if (list[j] > list[j + 1]) list.swap(j, j + 1);
      }
    }
  }
}
''';

    final result = VisualInstrumenter().instrument(source, path: 'bubble.dart');
    expect(result.errors, isEmpty);
    expect(result.source, contains('Future<void> sort'));
    expect(result.source, contains('sandboxCheckpoint'));
    expect(result.source, contains("'i': i"));
    expect(result.source, contains("'j': j"));
  });
}
