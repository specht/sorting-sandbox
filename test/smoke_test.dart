// End-to-end: parser daemon → instrumentation → kernel compilation → worker
// processes speaking the same protocol the browser uses through the host.
//
//   dart run test/smoke_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../tool/build.dart';
import '../tool/host.dart' show WorkerProcess, requestOnce;
import '../tool/instrument_client.dart';
import 'harness.dart';

final instrumenter = InstrumentClient();
final builder = WorkerBuilder(instrumenter);
var _unique = DateTime.now().microsecondsSinceEpoch;

/// A distinct comment defeats the worker cache, so every run really compiles.
List<int> source(String text) => utf8.encode('$text\n// smoke ${_unique++}\n');

const header = "import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';\n";

/// Runs a visual algorithm to the end in single steps.
Future<({List<Map<String, dynamic>> frames, List<Map<String, dynamic>> console,
    Map<String, dynamic>? error})> runVisual(BuiltAlgorithm built, List<int> values) async {
  final worker = await WorkerProcess.start(built.kernelPath);
  final frames = <Map<String, dynamic>>[];
  final console = <Map<String, dynamic>>[];
  final done = Completer<Map<String, dynamic>?>();
  worker.onMessage = (message) {
    switch (message['type']) {
      case 'frame':
        frames.add(message);
        if (message['done'] != true) {
          worker.send({'type': 'advance', 'requestId': 'r', 'budget': 1});
        }
      case 'console':
        console.add(message);
      case 'complete':
        if (!done.isCompleted) done.complete(null);
      case 'runError':
      case 'error':
        if (!done.isCompleted) done.complete(message);
    }
  };
  worker.onExit = (reason) {
    if (!done.isCompleted) done.completeError(StateError('worker exited: $reason'));
  };
  worker.send({'type': 'visualStart', 'requestId': 'r', 'values': values});
  try {
    final error = await done.future.timeout(const Duration(seconds: 30));
    return (frames: frames, console: console, error: error);
  } finally {
    worker.kill();
  }
}

Future<BuildFailure> expectFailure(List<int> bytes) async {
  try {
    await builder.build(bytes, subject: 'smoke');
  } on BuildFailure catch (failure) {
    return failure;
  }
  throw StateError('The build should have failed.');
}

void main() {
  test('the Bubble Sort template compiles, runs step by step and sorts', () async {
    final built = await builder.build(
        source(File('templates/bubble_sort.dart').readAsStringSync()),
        subject: 'smoke/bubble');
    expect(built.meta.name, 'Bubble Sort');
    final run = await runVisual(built, [3, 1, 2]);
    expect(run.error, null);
    final last = run.frames.last;
    expect(last['done'], isTrue);
    expect(last['numbers'], [1, 2, 3]);
    final lines = run.frames.map((frame) => frame['line']).toSet();
    expect(lines.contains(11), isTrue, reason: 'the if line of the template');
    final locals = run.frames[3]['locals'] as Map;
    expect(locals.containsKey('i'), isTrue);
    final metrics = last['metrics'] as Map;
    expect(metrics['comparisons'], 6);
  });

  test('check and analysis run in their own worker processes', () async {
    final built = await builder.build(
        source(File('templates/bubble_sort.dart').readAsStringSync()),
        subject: 'smoke/bubble-check');
    final check = await requestOnce(built, {'type': 'check', 'requestId': 'c'},
        reply: 'checkResult', timeout: const Duration(seconds: 30));
    expect(check['correct'], isTrue);
    expect((check['stability'] as Map)['stable'], isTrue);

    final analysis = await requestOnce(built, {
      'type': 'analyze',
      'requestId': 'a',
      'cases': [
        [4, 3, 2, 1],
        [2, 1],
      ],
    }, reply: 'analysisResult', timeout: const Duration(seconds: 30));
    expect(analysis['correct'], isTrue);
    expect((analysis['benchmarks'] as List).length, 2);
  });

  test('syntax errors come back with the line of the student file', () async {
    final failure = await expectFailure(source('''${header}
class Broken extends SortingAlgorithm {
  get name => 'Broken'
  get color => Colors.red;
  void sort(Elements list, Elements scratch) {}
}'''));
    expect(failure.diagnostics.isNotEmpty, isTrue);
    expect(failure.diagnostics.first['line'], 4);
  });

  test('type errors are mapped to the student line by the analyzer', () async {
    final failure = await expectFailure(source('''${header}
class Typo extends SortingAlgorithm {
  get name => 'Typo';
  get color => Colors.red;

  void sort(Elements list, Elements scratch) {
    list.swapp(0, 1);
  }
}'''));
    expect(failure.diagnostics.isNotEmpty, isTrue, reason: failure.message);
    expect(failure.diagnostics.first['line'], 8);
    expectContains(failure.diagnostics.first['message'].toString(), 'swapp');
  });

  test('runtime errors and print output carry source lines', () async {
    final built = await builder.build(source('''${header}
class OffByOne extends SortingAlgorithm {
  get name => 'Off by one';
  get color => Colors.red;

  void sort(Elements list, Elements scratch) {
    print('start');
    for (int i = 0; i <= list.length; i++) {
      if (list[i] > list[0]) list.swap(i, 0);
    }
  }
}'''), subject: 'smoke/off-by-one');
    final run = await runVisual(built, [2, 1]);
    expect(run.console.first['text'], 'start');
    expect(run.console.first['line'], 8);
    final error = run.error!['error'] as Map;
    expect(error['line'], 10);
    expectContains(error['message'].toString(), 'RangeError');
  });

  test('helpers and recursion work in the visual copy', () async {
    final built = await builder.build(source('''${header}
class Merge extends SortingAlgorithm {
  get name => 'Merge Sort';
  get color => Colors.orange;

  void sort(Elements list, Elements scratch) => mergeSort(list, scratch, 0, list.length);

  void mergeSort(Elements list, Elements scratch, int left, int right) {
    if (right - left < 2) return;
    int middle = (left + right) ~/ 2;
    mergeSort(list, scratch, left, middle);
    mergeSort(list, scratch, middle, right);
    int i = left, j = middle;
    for (int k = left; k < right; k++) {
      if (i < middle && (j >= right || list[i] <= list[j])) {
        scratch[k] = list[i++];
      } else {
        scratch[k] = list[j++];
      }
    }
    for (int k = left; k < right; k++) list[k] = scratch[k];
  }
}'''), subject: 'smoke/merge');
    final run = await runVisual(built, [5, 2, 4, 1, 3]);
    expect(run.error, null);
    expect(run.frames.last['numbers'], [1, 2, 3, 4, 5]);
    final check = await requestOnce(built, {'type': 'check', 'requestId': 'c'},
        reply: 'checkResult', timeout: const Duration(seconds: 30));
    expect(check['correct'], isTrue);
  });

  test('cleanup', () {
    instrumenter.dispose();
    Timer(const Duration(milliseconds: 200), () => exit(exitCode));
  });
}
