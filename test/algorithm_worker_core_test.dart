import 'package:flutter_test/flutter_test.dart';
import 'package:sorting_sandbox/algorithm_worker_core.dart';
import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

void main() {
  test('platform-neutral worker core runs benchmark requests', () async {
    final messages = <Map<String, Object?>>[];
    final core = AlgorithmWorkerCore(
      post: messages.add,
      createVisualAlgorithm: (_) => _InsertionSort(),
      createBenchmarkAlgorithm: (_) => _InsertionSort(),
    );

    await core.handle({
      'type': 'benchmark',
      'requestId': 'test-1',
      'algorithmId': 'insertion',
      'values': [4, 1, 3, 2],
    });

    expect(messages, hasLength(1));
    expect(messages.single['type'], 'benchmarkResult');
    expect(messages.single['requestId'], 'test-1');
    final result = (messages.single['result'] as Map).cast<String, dynamic>();
    expect(result['sorted'], isTrue);
    expect(result['keys'], [1, 2, 3, 4]);
  });
}

class _InsertionSort extends SortingAlgorithm {
  @override
  String get name => 'Insertion Sort';

  @override
  String get color => Colors.blue;

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
