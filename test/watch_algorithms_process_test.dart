import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('algorithm watcher exits after SIGTERM', () async {
    if (Platform.isWindows) return;

    final repo = await Directory.systemTemp.createTemp(
      'sorting-sandbox-watcher-',
    );
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        'tool/watch_algorithms.dart',
        '--repo',
        repo.path,
        '--poll-ms',
        '50',
      ],
      workingDirectory: Directory.current.path,
    );

    addTearDown(() async {
      process.kill(ProcessSignal.sigkill);
      await repo.delete(recursive: true);
    });

    final ready = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.startsWith('Watching '));
    await ready.timeout(const Duration(seconds: 10));

    expect(process.kill(ProcessSignal.sigterm), isTrue);
    expect(
      await process.exitCode.timeout(const Duration(seconds: 5)),
      0,
    );
  });
}
