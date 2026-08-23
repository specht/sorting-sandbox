import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

class WorkerTimeout implements Exception {
  WorkerTimeout(this.message);
  final String message;
  @override
  String toString() => message;
}

class AlgorithmWorker {
  AlgorithmWorker({required String workerPath})
      : _worker = web.Worker('runtime/$workerPath'.toJS) {
    _worker.onmessage = ((web.MessageEvent event) {
      final raw = event.data;
      if (raw is! JSString) return;
      final message = jsonDecode(raw.toDart) as Map<String, dynamic>;
      _lastMessageAt = DateTime.now();
      _messages.add(message);
    }).toJS;
    _worker.onerror = ((web.Event event) {
      _messages.add({
        'type': 'error',
        'message': 'Web Worker error',
      });
    }).toJS;
  }

  final web.Worker _worker;
  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  DateTime _lastMessageAt = DateTime.now();
  bool _closed = false;

  Stream<Map<String, dynamic>> get messages => _messages.stream;

  void send(Map<String, Object?> message) {
    if (_closed) return;
    _worker.postMessage(jsonEncode(message).toJS);
  }

  Future<Map<String, dynamic>> request(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final requestId = message['requestId']?.toString() ?? _newRequestId();
    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = messages.listen((event) {
      final eventRequestId = event['requestId']?.toString();
      final type = event['type'];
      if (eventRequestId != null && eventRequestId != requestId) return;
      if (eventRequestId == null && type != 'error') return;
      if (type == 'error') {
        if (!completer.isCompleted) {
          completer.completeError(StateError(event['message']?.toString() ?? 'Worker error'));
        }
        sub.cancel();
      } else if (type == 'benchmarkResult' || type == 'analysisResult') {
        if (!completer.isCompleted) completer.complete(event);
        sub.cancel();
      }
    });

    send({...message, 'requestId': requestId});
    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        terminate();
        throw WorkerTimeout('Algorithm did not finish within ${timeout.inSeconds}s.');
      });
    } finally {
      await sub.cancel();
    }
  }

  Timer watchdog({
    required Duration timeout,
    required void Function() onTimeout,
  }) {
    return Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (_closed) {
        timer.cancel();
        return;
      }
      if (DateTime.now().difference(_lastMessageAt) > timeout) {
        timer.cancel();
        terminate();
        onTimeout();
      }
    });
  }

  void terminate() {
    if (_closed) return;
    _closed = true;
    _worker.terminate();
    _messages.close();
  }

  static String _newRequestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
  static int _counter = 0;
}
