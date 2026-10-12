// End-to-end: parser daemon → instrumentation → kernel compilation → worker
// processes speaking the same protocol the browser uses through the host.
//
//   dart run test/smoke_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../tool/build.dart';
import '../tool/catalog.dart';
import 'package:sorting_sandbox/judge.dart';

import '../tool/host.dart' show WorkerProcess, judgeInWorker;
import '../tool/instrument_client.dart';
import '../tool/languages.dart';
import 'harness.dart';

final instrumenter = InstrumentClient();
final builder = WorkerBuilder(instrumenter);
var _unique = DateTime.now().microsecondsSinceEpoch;

/// A distinct comment defeats the worker cache, so every run really compiles.
List<int> source(String text) => utf8.encode('$text\n// smoke ${_unique++}\n');
List<int> pythonSource(String text) => utf8.encode('$text\n# smoke ${_unique++}\n');

/// Tests of a language are skipped (with a note) where its toolchain is missing.
Future<bool> available(Future<Object?> Function() toolchain) async {
  try {
    await toolchain();
    return true;
  } on ToolchainMissing catch (missing) {
    stdout.writeln('    (skipped: ${missing.message})');
    return false;
  }
}

Future<bool> pythonAvailable() => available(pythonToolchain.command);

/// Builds a template of [language] and runs it like the host does: a visual
/// run to the end, Check and a small Analyze, all judged by lib/judge.dart.
Future<void> templateEndToEnd(Language language) async {
  final template = File('templates/bubble_sort${language.extension}').readAsStringSync();
  final built = await builder.build(
      utf8.encode('$template\n${language == Language.python ? '#' : '//'} smoke ${_unique++}\n'),
      subject: 'smoke/bubble-${language.id}',
      language: language);
  expect(built.meta.name, 'Bubble Sort');
  expect(built.language, language);
  final run = await runVisual(built, [3, 1, 2]);
  expect(run.error, null);
  expect(run.frames.last['numbers'], [1, 2, 3]);
  expect((run.frames.last['metrics'] as Map)['comparisons'], 6,
      reason: 'the same count as the Dart template');
  final check = await judgeInWorker(built, checkCases, timeout: const Duration(seconds: 60));
  expect(check['correct'], isTrue);
  expect((check['stability'] as Map)['stable'], isTrue);
  final analysis = await judgeInWorker(
      built,
      (run) => analyzeCases(run, [
            [4, 3, 2, 1],
            [2, 1],
          ]),
      timeout: const Duration(seconds: 60));
  expect(analysis['correct'], isTrue);
  expect((analysis['benchmarks'] as List).length, 2);
}

const pythonHeader = 'from sorting_sandbox import Colors, Elements, SortingAlgorithm\n\n\n';

const header = "import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';\n";

/// Runs a visual algorithm to the end in single steps.
Future<({List<Map<String, dynamic>> frames, List<Map<String, dynamic>> console,
    Map<String, dynamic>? error})> runVisual(BuiltAlgorithm built, List<int> values) async {
  final worker = await WorkerProcess.launch(await built.launchCommand());
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

Future<BuildFailure> expectFailure(List<int> bytes,
    {Language language = Language.dart}) async {
  try {
    await builder.build(bytes, subject: 'smoke', language: language);
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
    final check = await judgeInWorker(built, checkCases,
        timeout: const Duration(seconds: 30));
    expect(check['correct'], isTrue);
    expect((check['stability'] as Map)['stable'], isTrue);

    final analysis = await judgeInWorker(
        built,
        (run) => analyzeCases(run, [
              [4, 3, 2, 1],
              [2, 1],
            ]),
        timeout: const Duration(seconds: 30));
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
    final check = await judgeInWorker(built, checkCases,
        timeout: const Duration(seconds: 30));
    expect(check['correct'], isTrue);
  });

  test('a Python algorithm builds, runs step by step and is judged by the host', () async {
    if (!await pythonAvailable()) return;
    final built = await builder.build(
        pythonSource(File('templates/bubble_sort.py').readAsStringSync()),
        subject: 'smoke/bubble-python',
        language: Language.python);
    expect(built.meta.name, 'Bubble Sort');
    expect(built.meta.color, '#4CAF50');
    expect(built.language, Language.python);
    final run = await runVisual(built, [3, 1, 2]);
    expect(run.error, null);
    expect(run.frames.last['numbers'], [1, 2, 3]);
    expect((run.frames.last['metrics'] as Map)['comparisons'], 6,
        reason: 'the same count as the Dart template');
    final check = await judgeInWorker(built, checkCases,
        timeout: const Duration(seconds: 60));
    expect(check['correct'], isTrue);
    expect((check['stability'] as Map)['stable'], isTrue);
    final analysis = await judgeInWorker(
        built,
        (run) => analyzeCases(run, [
              [4, 3, 2, 1],
              [2, 1],
            ]),
        timeout: const Duration(seconds: 60));
    expect(analysis['correct'], isTrue);
    expect((analysis['benchmarks'] as List).length, 2);
  });

  test('Python problems come back with the line of the student file', () async {
    if (!await pythonAvailable()) return;
    final syntax = await expectFailure(
        pythonSource('${pythonHeader}class Broken(SortingAlgorithm)\n    name = "B"\n'),
        language: Language.python);
    expect(syntax.diagnostics.first['line'], 4);
    final typo = await expectFailure(pythonSource('''${pythonHeader}class Typo(SortingAlgorithm):
    name = "Typo"
    color = Colors.RED

    def sort(self, elements, scratch):
        elements.swap(0, lenght)
'''), language: Language.python);
    expect(typo.diagnostics.first['line'], 9);
    expectContains(typo.diagnostics.first['message'].toString(), 'lenght');

    final built = await builder.build(pythonSource('''${pythonHeader}class OffByOne(SortingAlgorithm):
    name = "Off by one"
    color = Colors.RED

    def sort(self, elements, scratch):
        print("start")
        for i in range(len(elements) + 1):
            if elements[i] > elements[0]:
                elements.swap(i, 0)
'''), subject: 'smoke/off-by-one-python', language: Language.python);
    final run = await runVisual(built, [2, 1]);
    expect(run.console.first['text'], 'start');
    expect(run.console.first['line'], 9);
    final error = run.error!['error'] as Map;
    expect(error['line'], 11);
    expectContains(error['message'].toString(), 'IndexError');
    final check = await judgeInWorker(built, checkCases,
        timeout: const Duration(seconds: 60));
    expect(check['correct'], isFalse);
  });

  test('Python drafts are formatted by the vendored formatter', () async {
    if (!await pythonAvailable()) return;
    final reply = await builder.python.format('x.py', 'x=[1,2 ,3]\n');
    expect(reply['ok'], isTrue);
    expect(reply['content'], 'x = [1, 2, 3]\n');
  });

  test('a JavaScript algorithm builds, runs step by step and is judged by the host', () async {
    if (!await available(nodeToolchain.command)) return;
    await templateEndToEnd(Language.javascript);
    final failure = await expectFailure(utf8.encode(File('templates/bubble_sort.js')
        .readAsStringSync()
        .replaceFirst('const length = list.length;', 'const length = list.lenght + missing;')),
        language: Language.javascript);
    expect(failure.diagnostics.first['line'], 8);
    expectContains(failure.diagnostics.first['message'].toString(), 'missing');
    final reply = await builder.javascript.format('x.js', 'function f(){return 1}\n');
    expect(reply['content'], 'function f() {\n  return 1\n}\n');
  });

  test('a Java algorithm builds, runs step by step and is judged by the host', () async {
    if (!await available(javaToolchain.tools)) return;
    await templateEndToEnd(Language.java);
    final failure = await expectFailure(utf8.encode(File('templates/bubble_sort.java')
        .readAsStringSync()
        .replaceFirst('int length = list.length;', 'int length = list.lenght;')),
        language: Language.java);
    expect(failure.diagnostics.first['line'], 8);
    expectContains(failure.diagnostics.first['message'].toString(), 'lenght');
    final reply = await builder.java.format('x.java', 'class A{void f(){}}\n');
    expect(reply['content'], 'class A {\n    void f() {}\n}\n');
  });

  test('every algorithm of a real class repository is found', () async {
    final root = Directory.systemTemp.createTempSync('sorting-sandbox-catalog');
    final files = [
      'anna/insertionsort.dart', 'inuh_kang/quickSortHoare.dart',
      'klara_sort.dart/bubble_klara.dart', 'liu.kashiwabara/bubblesort.dart',
      'Ovilli/insertion-sort.dart', 'sebastian.marhoff/MgSort.dart',
      'Simon-Cat/QuickestSort.dart', 'HiTears/merge_sort_try.dart',
      'anna/quick_sort.py', 'bob/merge_sort.py', 'carl/heap_sort.js', 'dora/HeapSort.java',
    ];
    for (final file in files) {
      File('${root.path}/$file')
        ..createSync(recursive: true)
        ..writeAsStringSync(File('templates/bubble_sort.dart').readAsStringSync());
    }
    for (final ignored in ['README.md', 'pubspec.yaml', '.dart_tool/x/y.dart', 'top_level.dart',
        'top_level.py', 'anna/.venv/lib/x.py', 'anna/__pycache__/x.py', 'anna/notes.txt',
        'carl/node_modules/x/index.js', 'carl/data.json']) {
      File('${root.path}/$ignored')
        ..createSync(recursive: true)
        ..writeAsStringSync('// not an algorithm');
    }
    final catalog = Catalog(
      repoPath: root.path,
      builder: builder,
      instrumenter: instrumenter,
      onChanged: () {},
    );
    catalog.scan();
    final ids = catalog.files.keys.toSet();
    expect(ids, {
      for (final file in files)
        file.endsWith('.dart') ? file.substring(0, file.length - '.dart'.length) : file,
    });
    expect(catalog['liu.kashiwabara/bubblesort']!.student, 'liu.kashiwabara');
    expect(catalog['anna/quick_sort.py']!.language, Language.python);
    expect(catalog['anna/quick_sort.py']!.toJson()['language'], 'python');
    expect(catalog['anna/quick_sort.py']!.displayName, 'Quick Sort');
    expect(catalog['carl/heap_sort.js']!.language, Language.javascript);
    expect(catalog['dora/HeapSort.java']!.language, Language.java);
    await Future<void>.delayed(const Duration(seconds: 2));
    root.deleteSync(recursive: true);
  });

  test('cleanup', () {
    builder.dispose();
    Timer(const Duration(milliseconds: 200), () => exit(exitCode));
  });
}
