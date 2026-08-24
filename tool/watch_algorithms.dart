import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final repoArg = _value(args, '--repo') ?? 'algorithms';
  final repo = Directory(repoArg).absolute;
  if (!repo.existsSync()) {
    stderr.writeln('Algorithm repository not found: ${repo.path}');
    exitCode = 66;
    return;
  }

  final root = Directory.current.absolute;
  final pollMs = int.tryParse(_value(args, '--poll-ms') ?? '') ?? 350;
  final quietMs = int.tryParse(_value(args, '--quiet-ms') ?? '') ?? 450;

  stdout.writeln('Watching ${repo.path} for algorithm changes…');
  stdout.writeln('Valid saves are rebuilt automatically; broken files are reported and skipped.');

  var fingerprint = _fingerprint(repo);
  var dependencyStamp = _dependencyStamp(repo);
  String? pendingFingerprint;
  DateTime? lastChange;
  var pendingPubGet = false;
  var building = false;
  var rebuildAgain = false;

  Future<void> rebuild() async {
    if (building) {
      rebuildAgain = true;
      return;
    }
    building = true;
    do {
      rebuildAgain = false;
      stdout.writeln('\n↻ Algorithms changed — rebuilding worker…');
      final doPubGet = pendingPubGet;
      pendingPubGet = false;
      final prepareArgs = <String>[
        'run',
        'tool/build_algorithms.dart',
        '--repo',
        repo.path,
        '--compile-worker',
        if (!doPubGet) '--no-pub-get',
      ];
      final result = await Process.start(
        Platform.resolvedExecutable,
        prepareArgs,
        workingDirectory: root.path,
        mode: ProcessStartMode.inheritStdio,
      );
      final code = await result.exitCode;
      if (code == 0) {
        stdout.writeln('✓ Running browser will pick up the new algorithm build automatically.');
      } else {
        stderr.writeln('✗ Rebuild failed (exit $code). The last successful worker stays active.');
      }
    } while (rebuildAgain);
    building = false;
  }

  late final Timer pollTimer;
  pollTimer = Timer.periodic(Duration(milliseconds: pollMs), (timer) {
    final next = _fingerprint(repo);
    if (next != fingerprint) {
      fingerprint = next;
      final nextDependencyStamp = _dependencyStamp(repo);
      if (nextDependencyStamp != dependencyStamp) {
        dependencyStamp = nextDependencyStamp;
        pendingPubGet = true;
      }
      pendingFingerprint = next;
      lastChange = DateTime.now();
      if (building) rebuildAgain = true;
      return;
    }

    final changedAt = lastChange;
    if (pendingFingerprint != null &&
        changedAt != null &&
        DateTime.now().difference(changedAt).inMilliseconds >= quietMs) {
      pendingFingerprint = null;
      lastChange = null;
      unawaited(rebuild());
    }
  });

  // Keep the command alive until it receives a signal from the run script.
  final done = Completer<void>();
  void finish(ProcessSignal signal) {
    pollTimer.cancel();
    if (!done.isCompleted) done.complete();
  }

  if (!Platform.isWindows) {
    ProcessSignal.sigint.watch().listen(finish);
    ProcessSignal.sigterm.watch().listen(finish);
  }
  await done.future;
}

String? _value(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

String _fingerprint(Directory root) {
  final entries = <String>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = _relative(root.path, entity.path);
    final parts = relative.split(Platform.pathSeparator);
    if (parts.any((part) => part.startsWith('.'))) continue;

    final basename = parts.last;
    final interesting = entity.path.endsWith('.dart') ||
        basename == 'pubspec.yaml' ||
        basename == 'pubspec.lock' ||
        basename == 'analysis_options.yaml';
    if (!interesting) continue;

    final stat = entity.statSync();
    entries.add('$relative|${stat.size}|${stat.modified.microsecondsSinceEpoch}');
  }
  entries.sort();
  return entries.join('\n');
}


String _dependencyStamp(Directory repo) =>
    '${_fileStamp(File('${repo.path}/pubspec.yaml'))}|'
    '${_fileStamp(File('${repo.path}/pubspec.lock'))}';

String _fileStamp(File file) {
  if (!file.existsSync()) return 'missing';
  final stat = file.statSync();
  return '${stat.size}|${stat.modified.microsecondsSinceEpoch}';
}

String _relative(String root, String path) {
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}
