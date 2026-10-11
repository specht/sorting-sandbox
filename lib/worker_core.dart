import 'dart:async';
import 'dart:math';

import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

import 'sandbox_worker_runtime.dart';

typedef AlgorithmFactory = SortingAlgorithm Function();

/// The message protocol of one disposable worker process.
///
/// Requests (from the host):
///   visualStart {requestId, values}   run the generated async copy; frames
///                                     are emitted whenever the budget is used up
///   advance     {requestId, budget}   grant more checkpoints to the visual run
///   analyze     {requestId, cases}    correctness, stability and benchmarks
///   check       {requestId}           detailed correctness report
/// Replies: frame, complete, runError, console, analysisResult, checkResult,
/// error.
class WorkerCore {
  WorkerCore({
    required this.post,
    required this.createVisual,
    required this.createBenchmark,
  });

  final void Function(Map<String, Object?> message) post;
  final AlgorithmFactory createVisual;
  final AlgorithmFactory createBenchmark;

  CheckpointSession? _visual;
  bool _visualUsed = false;

  Future<void> handle(Map<String, dynamic> message) async {
    final type = message['type'];
    final requestId = message['requestId']?.toString() ?? '';
    try {
      switch (type) {
        case 'visualStart':
          await _visualStart(requestId, message);
        case 'advance':
          _visual?.addBudget(_toInt(message['budget'], 1));
        case 'analyze':
          {
            final raw = message['cases'];
            final cases = <List<int>>[
              if (raw is List)
                for (final entry in raw) _intList(entry),
            ];
            final analysis =
                silently(() => analyzeAlgorithm(createBenchmark, cases));
            post({'type': 'analysisResult', 'requestId': requestId, ...analysis});
          }
        case 'check':
          {
            final report = silently(() => checkAlgorithm(createBenchmark));
            post({'type': 'checkResult', 'requestId': requestId, ...report});
          }
        default:
          post({
            'type': 'error',
            'requestId': requestId,
            'message': 'Unknown worker message: $type',
          });
      }
    } catch (error, stack) {
      post({
        'type': 'error',
        'requestId': requestId,
        'message': '$error',
        'error': describeFailure(error, stack),
      });
    }
  }

  Future<void> _visualStart(
    String requestId,
    Map<String, dynamic> message,
  ) async {
    if (_visualUsed) {
      throw StateError('This worker has already run a visual algorithm.');
    }
    _visualUsed = true;
    final values = _intList(message['values']);
    final session = CheckpointSession(
      emitFrame: (frame) => post({...frame, 'requestId': requestId}),
    );
    _visual = session;
    final console = ConsoleCapture((kind, text) => post({
          'type': 'console',
          'requestId': requestId,
          'kind': kind,
          'text': text,
          if (session.currentLine > 0) 'line': session.currentLine,
          'checkpoint': session.checkpointIndex,
        }));

    try {
      await console.run(() => withCheckpointSessionAsync<void>(session, () async {
            final list = Elements.runtime(
              probe: session.probe,
              label: 'list',
              values: values,
            );
            final scratch = Elements.runtime(
              probe: session.probe,
              label: 'scratch',
              values: List<int>.filled(values.length, 0),
              origins: List<int>.generate(values.length, (i) => -1 - i),
            );
            final dynamic algorithm = createVisual();
            final Object? result = algorithm.sort(list, scratch);
            if (result is Future) await result;
          }));
    } catch (error, stack) {
      session.flush();
      post({
        'type': 'runError',
        'requestId': requestId,
        'checkpoint': session.checkpointIndex,
        'error': describeFailure(error, stack, line: session.currentLine),
      });
      return;
    }
    session.finish();
    post({'type': 'complete', 'requestId': requestId});
  }
}

/// Forwards `print` calls of student code, with an upper bound.
class ConsoleCapture {
  ConsoleCapture(this.emit);

  final void Function(String kind, String text) emit;
  int _count = 0;
  int _characters = 0;
  bool _truncated = false;

  T run<T>(T Function() body) => runZoned(
        body,
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => _print(line),
        ),
      );

  void _print(String text) {
    if (_count < 200 && _characters + text.length <= 65536) {
      _count++;
      _characters += text.length;
      emit('stdout', text);
    } else if (!_truncated) {
      _truncated = true;
      emit('warning', 'Further print output was truncated.');
    }
  }
}

/// Runs [body] with `print` discarded (analysis runs thousands of sorts).
T silently<T>(T Function() body) => runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {},
      ),
    );

const _correctnessCases = <List<int>>[
  [],
  [1],
  [2, 1],
  [1, 2],
  [3, 1, 2],
  [4, 3, 2, 1],
  [1, 1, 1, 1],
  [3, 1, 3, 2, 1, 2],
];

/// Class-wide analysis: correctness, empirical stability and the operation
/// counts for every benchmark input. All algorithms receive the SAME inputs.
Map<String, Object?> analyzeAlgorithm(
  AlgorithmFactory create,
  List<List<int>> benchmarkCases,
) {
  List<int>? current;
  Map<String, Object?> incorrect(List<int> values, String reason) => {
        'correct': false,
        'stable': null,
        'failingCase': _show(values),
        'reason': reason,
        'benchmarks': const <Object?>[],
      };
  try {
    for (final values in _correctnessCases) {
      current = values;
      final reason = judgeResult(values, runSyncAlgorithm(create(), values));
      if (reason != null) return incorrect(values, reason);
    }

    var stable = true;
    for (final values in stabilityCases()) {
      current = values;
      final result = runSyncAlgorithm(create(), values);
      final reason = judgeResult(values, result);
      if (reason != null) return incorrect(values, reason);
      if (!result.stable) {
        stable = false;
        break;
      }
    }

    final benchmarks = <Map<String, Object?>>[];
    for (final values in benchmarkCases) {
      current = values;
      final result = runSyncAlgorithm(create(), values);
      final reason = judgeResult(values, result);
      if (reason != null) return incorrect(values, reason);
      benchmarks.add({'n': values.length, ...result.metrics.toJson()});
    }
    return {
      'correct': true,
      'stable': stable,
      'failingCase': null,
      'benchmarks': benchmarks,
    };
  } catch (error, stack) {
    final failing = current;
    return {
      'correct': false,
      'stable': null,
      'failingCase': failing == null ? null : _show(failing),
      'reason': 'The algorithm threw an exception.',
      'error': describeFailure(error, stack),
      'benchmarks': const <Object?>[],
    };
  }
}

class _CheckGroup {
  const _CheckGroup(this.name, this.cases);
  final String name;
  final List<List<int>> cases;
}

List<_CheckGroup> _checkGroups() {
  final random = Random(20240611);
  List<int> shuffled(int n) => List<int>.generate(n, (i) => i + 1)..shuffle(random);
  List<int> withDuplicates(int n, int distinct) =>
      List<int>.generate(n, (_) => random.nextInt(distinct));
  return [
    const _CheckGroup('Empty list and one element', [
      [],
      [7],
    ]),
    const _CheckGroup('Two and three elements', [
      [1, 2],
      [2, 1],
      [1, 2, 3],
      [1, 3, 2],
      [2, 1, 3],
      [2, 3, 1],
      [3, 1, 2],
      [3, 2, 1],
    ]),
    _CheckGroup('Already sorted and reversed', [
      List<int>.generate(10, (i) => i + 1),
      List<int>.generate(10, (i) => 10 - i),
      List<int>.generate(9, (i) => 9 - i),
    ]),
    const _CheckGroup('Duplicates', [
      [4, 4, 4, 4],
      [2, 1, 2, 1, 2],
      [3, 1, 3, 2, 1, 2],
      [0, 0, 1, 1, 0, 0],
    ]),
    _CheckGroup('Random inputs up to 40 elements', [
      for (var n = 4; n <= 40; n += 2)
        n % 4 == 0 ? shuffled(n) : withDuplicates(n, n ~/ 2 + 1),
    ]),
    _CheckGroup('Larger inputs', [
      shuffled(100),
      shuffled(255),
      withDuplicates(300, 20),
      shuffled(512),
    ]),
  ];
}

/// Detailed report for one algorithm, shown in the Check dialog.
Map<String, Object?> checkAlgorithm(AlgorithmFactory create) {
  final groups = <Map<String, Object?>>[];
  var allCorrect = true;
  for (final group in _checkGroups()) {
    var passed = 0;
    Map<String, Object?>? failure;
    for (final values in group.cases) {
      try {
        final result = runSyncAlgorithm(create(), values);
        final reason = judgeResult(values, result);
        if (reason == null) {
          passed++;
          continue;
        }
        failure = {
          'input': _preview(values),
          'output': _preview(result.keys),
          'message': reason,
        };
      } catch (error, stack) {
        failure = {
          'input': _preview(values),
          'message': 'The algorithm threw an exception.',
          'error': describeFailure(error, stack),
        };
      }
      break;
    }
    if (failure != null) allCorrect = false;
    groups.add({
      'name': group.name,
      'total': group.cases.length,
      'passed': passed,
      'ok': failure == null,
      'failure': failure,
    });
  }

  Map<String, Object?> stability = {'tested': false};
  if (allCorrect) {
    stability = {'tested': true, 'stable': true};
    final random = Random(7);
    final cases = <List<int>>[
      ...stabilityCases(),
      for (var n = 6; n <= 30; n += 3)
        List<int>.generate(n, (_) => random.nextInt(4)),
    ];
    try {
      for (final values in cases) {
        final result = runSyncAlgorithm(create(), values);
        if (judgeResult(values, result) == null && !result.stable) {
          stability = {
            'tested': true,
            'stable': false,
            'input': values,
            'output': result.keys,
            'origins': result.origins,
          };
          break;
        }
      }
    } catch (_) {
      stability = {'tested': false};
    }
  }
  return {'groups': groups, 'stability': stability, 'correct': allCorrect};
}

/// Null when [result] is a correct sort of [input]; otherwise the reason.
String? judgeResult(List<int> input, RunResult result) {
  if (result.keys.length != input.length) return 'The list changed its length.';
  final origins = List<int>.from(result.origins)..sort();
  for (var i = 0; i < origins.length; i++) {
    if (origins[i] != i) {
      return result.origins.any((origin) => origin < 0)
          ? 'Elements of the temporary list ended up in the result: '
              'some elements were overwritten.'
          : 'Some elements were overwritten or duplicated: the result is '
              'not a rearrangement of the input.';
    }
  }
  if (!result.sorted) return 'The result is not sorted.';
  return null;
}

Map<String, Object?> _preview(List<int> values) => {
      'length': values.length,
      'values': values.length <= 64 ? values : values.sublist(0, 64),
    };

String _show(List<int> values) => values.length <= 24
    ? values.toString()
    : '[${values.take(24).join(', ')}, …] (n = ${values.length})';

/// Turns an exception from student code into a report with original line
/// numbers. Benchmark copies are byte-identical to the student file; visual
/// copies preserve every line, so both stack traces map directly.
Map<String, Object?> describeFailure(
  Object error,
  StackTrace stack, {
  int? line,
}) {
  int? firstLine;
  int? column;
  final frames = <String>[];
  final framePattern = RegExp(r':(\d+)(?::(\d+))?\)?$');
  final functionPattern = RegExp(r'^#\d+\s+(.+?)\s+\(');
  for (final raw in stack.toString().split('\n').take(400)) {
    final frame = raw.trim();
    final benchmark = frame.contains('/algorithm.dart:');
    final visual = frame.contains('/visual.dart:');
    if (!benchmark && !visual) continue;
    final match = framePattern.firstMatch(frame);
    final frameLine = match == null ? null : int.tryParse(match.group(1)!);
    if (firstLine == null && match != null && frameLine != null) {
      firstLine = frameLine;
      final columnText = match.group(2);
      if (benchmark && columnText != null) column = int.tryParse(columnText);
    }
    if (frames.length < 8) {
      final function =
          functionPattern.firstMatch(frame)?.group(1) ?? 'student code';
      frames.add('$function · line ${frameLine ?? '?'}');
    }
  }
  var message = error.toString();
  if (message.length > 1500) message = '${message.substring(0, 1500)}…';
  final resolvedLine = firstLine ?? (line != null && line > 0 ? line : null);
  return {
    'kind': error is StackOverflowError ? 'stackOverflow' : 'runtime',
    'message': message,
    if (resolvedLine != null) 'line': resolvedLine,
    if (column != null) 'column': column,
    if (frames.isNotEmpty) 'stack': frames,
  };
}

int _toInt(Object? value, int fallback) => value is num ? value.toInt() : fallback;

List<int> _intList(Object? raw) => <int>[
      if (raw is List)
        for (final entry in raw)
          if (entry is num) entry.toInt(),
    ];
