import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

import 'worker_core.dart';

/// Entry point of every generated worker (one per algorithm revision).
///
/// The host talks to this process through stdin/stdout, one JSON object per
/// line. A worker serves one browser run and is killed afterwards (or as soon
/// as student code stops cooperating), so a stuck algorithm can never block
/// the server or another student's run.
Future<void> runWorkerProcess({
  required SortingAlgorithm Function() createVisual,
  required SortingAlgorithm Function() createBenchmark,
}) async {
  void post(Map<String, Object?> message) {
    String encoded;
    try {
      encoded = jsonEncode(message);
    } catch (error) {
      encoded = jsonEncode({
        'type': 'error',
        'requestId': message['requestId']?.toString() ?? '',
        'message': 'Could not encode a worker message: $error',
      });
    }
    stdout.writeln(encoded);
  }

  final core = WorkerCore(
    post: post,
    createVisual: createVisual,
    createBenchmark: createBenchmark,
  );
  final inputClosed = Completer<void>();

  runZonedGuarded(() {
    post({'type': 'hello', 'pid': pid});
    stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim().isEmpty) return;
            Object? decoded;
            try {
              decoded = jsonDecode(line);
            } catch (_) {
              post({'type': 'error', 'message': 'Invalid worker request.'});
              return;
            }
            if (decoded is Map<String, dynamic>) unawaited(core.handle(decoded));
          },
          onDone: () {
            if (!inputClosed.isCompleted) inputClosed.complete();
          },
        );
  }, (error, stack) {
    // For example an unawaited Future in student code that fails later.
    post({
      'type': 'error',
      'requestId': '',
      'message': 'Unhandled error: $error',
      'error': describeFailure(error, stack),
    });
  });

  await inputClosed.future;
  await stdout.flush();
  // A suspended visual run must not keep the process alive.
  exit(0);
}
