import 'dart:async';
import 'dart:isolate';

import 'algorithm_worker_core.dart';
import 'generated/registry.g.dart';

class WorkerTimeout implements Exception {
  WorkerTimeout(this.message);
  final String message;
  @override
  String toString() => message;
}

class AlgorithmWorker {
  AlgorithmWorker({required String workerPath}) {
    // Native builds use the same catalog model as web builds. The worker path
    // is intentionally ignored because execution happens in a Dart isolate.
    if (workerPath.isEmpty) {
      throw ArgumentError.value(workerPath, 'workerPath', 'must not be empty');
    }
    _inboxSubscription = _inbox.listen(_handleIncoming);
    unawaited(_start());
  }

  final ReceivePort _inbox = ReceivePort();
  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, Object?>> _queued = [];

  late final StreamSubscription<dynamic> _inboxSubscription;
  Isolate? _isolate;
  SendPort? _sendPort;
  DateTime _lastMessageAt = DateTime.now();
  bool _closed = false;

  Stream<Map<String, dynamic>> get messages => _messages.stream;

  Future<void> _start() async {
    try {
      final isolate = await Isolate.spawn<SendPort>(
        _nativeWorkerMain,
        _inbox.sendPort,
        onError: _inbox.sendPort,
        errorsAreFatal: true,
      );
      if (_closed) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
    } catch (error, stack) {
      if (_closed) return;
      _messages.add({
        'type': 'error',
        'message': 'Could not start algorithm isolate: $error',
        'stack': stack.toString(),
      });
    }
  }

  void _handleIncoming(dynamic message) {
    if (_closed) return;
    if (message is SendPort) {
      _sendPort = message;
      _lastMessageAt = DateTime.now();
      for (final queued in _queued) {
        message.send(queued);
      }
      _queued.clear();
      return;
    }
    if (message is List && message.isNotEmpty) {
      _lastMessageAt = DateTime.now();
      _messages.add({
        'type': 'error',
        'message': message.first.toString(),
        if (message.length > 1) 'stack': message[1].toString(),
      });
      return;
    }
    if (message is Map) {
      _lastMessageAt = DateTime.now();
      _messages.add(Map<String, dynamic>.from(message));
    }
  }

  void send(Map<String, Object?> message) {
    if (_closed) return;
    final port = _sendPort;
    if (port == null) {
      _queued.add(Map<String, Object?>.from(message));
    } else {
      port.send(message);
    }
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
          completer.completeError(
            StateError(event['message']?.toString() ?? 'Worker error'),
          );
        }
        sub.cancel();
      } else if (type == 'benchmarkResult' || type == 'analysisResult') {
        if (!completer.isCompleted) completer.complete(event);
        sub.cancel();
      }
    });

    send({...message, 'requestId': requestId});
    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          terminate();
          throw WorkerTimeout(
            'Algorithm did not finish within ${timeout.inSeconds}s.',
          );
        },
      );
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
    _queued.clear();
    _sendPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _inbox.close();
    _inboxSubscription.cancel();
    _messages.close();
  }

  static String _newRequestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
  static int _counter = 0;
}

void _nativeWorkerMain(SendPort ownerPort) {
  final inbox = ReceivePort();
  ownerPort.send(inbox.sendPort);

  final core = AlgorithmWorkerCore(
    post: (message) => ownerPort.send(message),
    createVisualAlgorithm: createVisualAlgorithm,
    createBenchmarkAlgorithm: createBenchmarkAlgorithm,
  );

  inbox.listen((message) {
    if (message is! Map) return;
    unawaited(core.handle(Map<String, dynamic>.from(message)));
  });
}
