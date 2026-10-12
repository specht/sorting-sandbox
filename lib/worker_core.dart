import 'dart:async';

import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

import 'sandbox_worker_runtime.dart';

typedef AlgorithmFactory = SortingAlgorithm Function();

/// The message protocol of one disposable worker process.
///
/// Requests (from the host):
///   visualStart {requestId, values}   run the generated async copy; frames
///                                     are emitted whenever the budget is used up
///   advance     {requestId, budget}   grant more checkpoints to the visual run
///   run         {requestId, values}   sort once without visualization overhead;
///                                     the host judges the result (lib/judge.dart)
/// Replies: frame, complete, runError, console, runResult, error.
///
/// Workers of the other languages (languages/*/) speak the same protocol.
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
        case 'run':
          post({
            'type': 'runResult',
            'requestId': requestId,
            ...runCase(createBenchmark, _intList(message['values'])),
          });
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

/// Sorts [values] once with the benchmark copy, with `print` discarded.
///
/// The result is what every language's worker reports for `run`:
/// `{keys, origins, metrics}` or `{error}` with the student's line.
Map<String, Object?> runCase(AlgorithmFactory create, List<int> values) {
  try {
    final result = silently(() => runSyncAlgorithm(create(), values));
    return {
      'keys': result.keys,
      'origins': result.origins,
      'metrics': result.metrics.toJson(),
    };
  } catch (error, stack) {
    return {'error': describeFailure(error, stack)};
  }
}

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
