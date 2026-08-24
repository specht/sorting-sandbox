import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:sorting_sandbox/algorithm_worker_core.dart';
import 'package:web/web.dart' as web;

import 'generated/registry.g.dart';

@JS('self')
external web.DedicatedWorkerGlobalScope get workerSelf;

final AlgorithmWorkerCore _core = AlgorithmWorkerCore(
  post: _post,
  createVisualAlgorithm: createVisualAlgorithm,
  createBenchmarkAlgorithm: createBenchmarkAlgorithm,
);

void main() {
  workerSelf.onmessage = ((web.MessageEvent event) {
    final raw = event.data.dartify();
    if (raw is! String) return;
    final message = jsonDecode(raw) as Map<String, dynamic>;
    unawaited(_core.handle(message));
  }).toJS;
}

void _post(Map<String, Object?> message) {
  workerSelf.postMessage(jsonEncode(message).toJS);
}
