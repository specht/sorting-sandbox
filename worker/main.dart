import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:sorting_sandbox/sandbox_worker_runtime.dart';
import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';
import 'package:web/web.dart' as web;

import 'generated/registry.g.dart';

@JS('self')
external web.DedicatedWorkerGlobalScope get workerSelf;

CheckpointSession? _visualSession;

void main() {
  workerSelf.onmessage = ((web.MessageEvent event) {
    final raw = event.data.dartify();
    if (raw is! String) return;
    final message = jsonDecode(raw) as Map<String, dynamic>;
    unawaited(_handle(message));
  }).toJS;
}

Future<void> _handle(Map<String, dynamic> message) async {
  final type = message['type'] as String?;
  final requestId = message['requestId']?.toString() ?? '';
  try {
    switch (type) {
      case 'visualStart':
        await _visualStart(requestId, message);
        return;
      case 'advance':
        _visualSession?.addBudget((message['budget'] as num?)?.toInt() ?? 1);
        return;
      case 'benchmark':
        _benchmark(requestId, message);
        return;
      case 'analyze':
        _analyze(requestId, message);
        return;
      default:
        _post({
          'type': 'error',
          'requestId': requestId,
          'message': 'Unknown worker message: $type',
        });
        return;
    }
  } catch (error, stack) {
    _post({
      'type': 'error',
      'requestId': requestId,
      'message': error.toString(),
      'stack': stack.toString(),
    });
  }
}

Future<void> _visualStart(
  String requestId,
  Map<String, dynamic> message,
) async {
  if (_visualSession != null) {
    throw StateError('This worker already has a visual run.');
  }
  final id = message['algorithmId'] as String;
  final values = (message['values'] as List).cast<num>().map((e) => e.toInt()).toList();
  final algorithm = createVisualAlgorithm(id) as dynamic;

  late CheckpointSession session;
  session = CheckpointSession(
    emitFrame: (frame) => _post({...frame, 'requestId': requestId}),
  );
  _visualSession = session;

  final list = Elements.runtime(
    probe: session.probe,
    label: 'list',
    values: values,
    origins: List<int>.generate(values.length, (i) => i),
  );
  final scratch = Elements.runtime(
    probe: session.probe,
    label: 'scratch',
    values: List<int>.filled(values.length, 0),
    origins: List<int>.generate(values.length, (i) => -1 - i),
  );

  try {
    await withCheckpointSessionAsync(session, () async {
      final result = algorithm.sort(list, scratch);
      if (result is Future) await result;
    });
    session.finish();
    _post({'type': 'complete', 'requestId': requestId});
  } finally {
    _visualSession = null;
  }
}

void _benchmark(String requestId, Map<String, dynamic> message) {
  final id = message['algorithmId'] as String;
  final values = (message['values'] as List).cast<num>().map((e) => e.toInt()).toList();
  final algorithm = createBenchmarkAlgorithm(id) as dynamic;
  final result = runSyncAlgorithm(algorithm, values);
  _post({
    'type': 'benchmarkResult',
    'requestId': requestId,
    'result': result.toJson(),
  });
}

void _analyze(String requestId, Map<String, dynamic> message) {
  final id = message['algorithmId'] as String;
  final benchmarkCases = (message['cases'] as List)
      .map((e) => (e as List).cast<num>().map((x) => x.toInt()).toList())
      .toList();

  final correctnessCases = <List<int>>[
    [],
    [1],
    [2, 1],
    [1, 2],
    [3, 1, 2],
    [4, 3, 2, 1],
    [1, 1, 1, 1],
    [3, 1, 3, 2, 1, 2],
  ];

  bool correct = true;
  String? failingCase;
  for (final values in correctnessCases) {
    final algorithm = createBenchmarkAlgorithm(id) as dynamic;
    final result = runSyncAlgorithm(algorithm, values);
    if (!_validOutput(values, result)) {
      correct = false;
      failingCase = values.toString();
      break;
    }
  }

  bool? stable;
  if (correct) {
    stable = true;
    for (final values in stabilityCases()) {
      final algorithm = createBenchmarkAlgorithm(id) as dynamic;
      final result = runSyncAlgorithm(algorithm, values);
      if (!_validOutput(values, result)) {
        correct = false;
        failingCase = values.toString();
        stable = null;
        break;
      }
      if (!result.stable) {
        stable = false;
        break;
      }
    }
  }

  final benchmarks = <Map<String, Object?>>[];
  if (correct) {
    for (final values in benchmarkCases) {
      final algorithm = createBenchmarkAlgorithm(id) as dynamic;
      final result = runSyncAlgorithm(algorithm, values);
      if (!_validOutput(values, result)) {
        correct = false;
        failingCase = values.toString();
        benchmarks.clear();
        break;
      }
      benchmarks.add({
        'n': values.length,
        ...result.metrics.toJson(),
      });
    }
  }

  _post({
    'type': 'analysisResult',
    'requestId': requestId,
    'correct': correct,
    'stable': stable,
    'stabilityNote': stable == null
        ? null
        : stable
            ? 'stable on the sandbox test suite'
            : 'unstable (counterexample found)',
    'failingCase': failingCase,
    'benchmarks': benchmarks,
  });
}


bool _validOutput(List<int> input, RunResult result) {
  if (!result.sorted || !_sameMultiset(input, result.keys)) return false;
  if (result.origins.length != input.length) return false;
  final origins = List<int>.from(result.origins)..sort();
  for (var i = 0; i < origins.length; i++) {
    if (origins[i] != i) return false;
  }
  return true;
}

bool _sameMultiset(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  final aa = List<int>.from(a)..sort();
  final bb = List<int>.from(b)..sort();
  for (var i = 0; i < aa.length; i++) {
    if (aa[i] != bb[i]) return false;
  }
  return true;
}

void _post(Map<String, Object?> message) {
  workerSelf.postMessage(jsonEncode(message).toJS);
}
