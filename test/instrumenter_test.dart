import '../tool/instrumenter.dart';
import 'harness.dart';

const bubble = r'''
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

const merge = r'''
import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

class Merge extends SortingAlgorithm {
  get name => 'Merge';
  get color => '#123456';

  void sort(Elements list, Elements scratch) => mergeSort(list, scratch, 0, list.length);

  void mergeSort(Elements list, Elements scratch, int left, int right) {
    if (right - left < 2) return;
    int middle = (left + right) ~/ 2;
    mergeSort(list, scratch, left, middle);
    this.mergeSort(list, scratch, middle, right);
    late int unused;
    final int alsoUnused;
    int? maybe;
    while (middle > right) middle--;
    print([1, 2].map((x) => helper(x)).length);
  }

  int helper(int x) => x + 1;

  @override
  String toString() => 'Merge';
}

int twice(int x) => x * 2;
''';

void main() {
  final instrumenter = VisualInstrumenter();

  test('bubble sort gets async checkpoints and visible loop variables', () {
    final result = instrumenter.instrument(bubble, path: 'bubble.dart');
    expect(result.errors, const <String>[]);
    expectContains(result.source, 'Future<void> sort');
    expectContains(result.source, ') async {');
    expectContains(result.source, "__sandbox.sandboxCheckpoint(11, {'j': j, 'i': i, 'length': length})");
    expectContains(result.source, "as __sandbox;");
    // list.swap must not be awaited, even though it is a method call.
    expectContains(result.source, 'list.swap(j, j + 1)');
  });

  test('line numbers of the student file are preserved', () {
    for (final source in [bubble, merge]) {
      final result = instrumenter.instrument(source, path: 'x.dart');
      expect(result.errors, const <String>[]);
      expect(result.source.split('\n').length, source.split('\n').length);
    }
    final lines = instrumenter.instrument(bubble, path: 'b.dart').source.split('\n');
    expectContains(lines[10], 'if (list[j] > list[j + 1]) list.swap(j, j + 1);');
    expectContains(lines[7], 'int length = list.length;');
  });

  test('local helpers are awaited; closures, getters and toString are not', () {
    final result = instrumenter.instrument(merge, path: 'merge.dart');
    expect(result.errors, const <String>[]);
    final source = result.source;
    expectContains(source, '(await mergeSort(list, scratch, left, middle))');
    expectContains(source, '(await this.mergeSort(list, scratch, middle, right))');
    expectContains(source, 'async => (await mergeSort(list, scratch, 0, list.length))');
    expectContains(source, 'Future<int> helper(int x) async');
    expectContains(source, 'Future<int> twice(int x) async');
    expectContains(source, "String toString() => 'Merge';");
    expectContains(source, 'get name =>');
    // Inside the closure there is no await (closures stay synchronous).
    expectContains(source, '.map((x) => helper(x))');
    // A loop body without braces still gets a checkpoint.
    expectContains(source, 'while (middle > right) {await __sandbox.sandboxCheckpoint(');
  });

  test('checkpoints never read unassigned locals', () {
    final source = instrumenter.instrument(merge, path: 'merge.dart').source;
    final lastCheckpoint = source
        .split('\n')
        .lastWhere((line) => line.contains('print('));
    expectContains(lastCheckpoint, "'maybe': maybe");
    expect(lastCheckpoint.contains("'unused'"), isFalse);
    expect(lastCheckpoint.contains("'alsoUnused'"), isFalse);
  });

  test('a syntax error is reported instead of transformed', () {
    final result = instrumenter.instrument('class X {', path: 'broken.dart');
    expect(result.errors.isNotEmpty, isTrue);
  });
}
