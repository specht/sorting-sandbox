// Content-addressed worker builds: one small kernel per algorithm revision.
//
// Dart (the layout below) is compiled by this file. The other languages are
// built by their daemon (languages/*/), with the same content-addressed
// directory and ready.json:
//
//   Python      algorithm.py (a byte-identical copy); no instrumented copy
//   JavaScript  algorithm.mjs and visual.mjs (same lines, runtime import)
//   Java        benchmark/ and visual/ (classes compiled by the JDK)
//
//   runtime/workers/<key>/algorithm.dart   byte-identical copy of the student file
//   runtime/workers/<key>/visual.dart      instrumented async copy (same line numbers)
//   runtime/workers/<key>/worker.dart      generated entry point
//   runtime/workers/<key>/worker.dill      compiled kernel, started per run
//   runtime/workers/<key>/ready.json       success (metadata) or student failure
//
// The key covers the source bytes, the Dart SDK version and every sandbox file
// that influences the generated worker. Saving unchanged content, restarting
// ./run or selecting the same algorithm in another browser reuses the kernel.
// Each algorithm is compiled on its own, so one broken file never affects the
// others.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'inspect.dart' show AlgorithmMeta;
import 'instrument_client.dart';
import 'languages.dart';

const _cacheVersion = 'sorting-sandbox-worker-v2';
const workersDirectory = 'runtime/workers';

class BuiltAlgorithm {
  BuiltAlgorithm(this.key, this.kernelPath, this.meta, {this.language = Language.dart});
  final String key;

  /// The compiled kernel (Dart), the copied source file (Python) or the build
  /// directory (JavaScript, Java).
  final String kernelPath;
  final AlgorithmMeta meta;
  final Language language;

  /// The command that starts one worker process for this build.
  Future<List<String>> launchCommand() async => switch (language) {
        Language.python => await pythonToolchain.script(
            'sandbox_worker.py', [File(kernelPath).absolute.path, meta.className]),
        Language.javascript => await nodeToolchain.script(
            'sandbox_worker.mjs', [Directory(kernelPath).absolute.path, meta.className]),
        Language.java =>
          await javaToolchain.worker(Directory(kernelPath).absolute.path, meta.className),
        _ => [Platform.resolvedExecutable, kernelPath],
      };
}

/// What [BuiltAlgorithm.kernelPath] is for a build of [language] in
/// [directory], and whether that build is complete.
String _entry(String directory, Language language) => switch (language) {
      Language.python => '$directory/algorithm.py',
      Language.javascript || Language.java => directory,
      _ => '$directory/worker.dill',
    };

bool _complete(String directory, Language language) => switch (language) {
      Language.javascript => File('$directory/algorithm.mjs').existsSync() &&
          File('$directory/visual.mjs').existsSync(),
      Language.java => Directory('$directory/benchmark').existsSync() &&
          Directory('$directory/visual').existsSync(),
      _ => File(_entry(directory, language)).existsSync(),
    };

class BuildFailure implements Exception {
  BuildFailure(this.message, {this.diagnostics = const [], this.student = true});

  final String message;
  final List<Map<String, Object?>> diagnostics;

  /// False for environment problems (daemon or compiler unavailable). Those
  /// are never cached: the next attempt may succeed.
  final bool student;

  @override
  String toString() => message;
}

// Enable with SANDBOX_PROFILE=1 ./run. No student source is logged.
bool get buildProfiling => Platform.environment['SANDBOX_PROFILE'] == '1';
void buildProfile(String subject, String stage, Duration duration) {
  if (!buildProfiling) return;
  final millis = (duration.inMicroseconds / 1000).toStringAsFixed(1);
  stdout.writeln('[profile] $subject | $stage: $millis ms');
}

class WorkerBuilder {
  WorkerBuilder(
    this.instrumenter, {
    InstrumentClient? python,
    InstrumentClient? javascript,
    InstrumentClient? java,
  })  : python = python ??
            InstrumentClient(
              command: () => pythonToolchain.script('sandbox_daemon.py'),
              label: 'python',
            ),
        javascript = javascript ??
            InstrumentClient(
              command: () => nodeToolchain.script('sandbox_daemon.mjs'),
              label: 'javascript',
            ),
        java = java ?? InstrumentClient(command: javaToolchain.daemon, label: 'java');

  /// The Dart parser and instrumenter daemon.
  final InstrumentClient instrumenter;

  /// Check, build and format the other languages (languages/*/sandbox_daemon.*
  /// and __sandbox.Daemon for Java).
  final InstrumentClient python;
  final InstrumentClient javascript;
  final InstrumentClient java;

  /// The daemon that inspects, builds and formats files of [language].
  InstrumentClient daemonFor(Language language) => switch (language) {
        Language.python => python,
        Language.javascript => javascript,
        Language.java => java,
        _ => instrumenter,
      };

  /// Stops all daemons (tests; the host keeps them for its whole lifetime).
  void dispose() {
    instrumenter.dispose();
    python.dispose();
    javascript.dispose();
    java.dispose();
  }

  final _inFlight = <String, Future<BuiltAlgorithm>>{};
  late final String _toolFingerprint = _computeToolFingerprint();

  String keyFor(List<int> bytes, {Language language = Language.dart}) {
    final data = BytesBuilder(copy: false)
      // The JavaScript copies refer to the runtime by its absolute path.
      ..add(utf8.encode('$_cacheVersion\u0000${language.id}\u0000'
          '${Directory.current.absolute.path}\u0000'
          '${Platform.version}\u0000$_toolFingerprint\u0000'))
      ..add(bytes);
    return sha256.convert(data.takeBytes()).toString().substring(0, 32);
  }

  /// The cached outcome for [key]: a [BuiltAlgorithm], a [BuildFailure] or
  /// null when this revision has not been built yet.
  Object? cached(String key) {
    final directory = '$workersDirectory/$key';
    final ready = File('$directory/ready.json');
    if (!ready.existsSync()) return null;
    try {
      final record = jsonDecode(ready.readAsStringSync());
      if (record is! Map || record['key'] != key) return null;
      if (record['ok'] == true) {
        final meta = AlgorithmMeta.fromJson(record['meta']);
        final language = Language.byId(record['language']?.toString() ?? 'dart');
        if (language == null) return null;
        if (meta == null || !_complete(directory, language)) return null;
        try {
          ready.setLastModifiedSync(DateTime.now()); // Recently used: keep.
        } catch (_) {}
        return BuiltAlgorithm(key, _entry(directory, language), meta, language: language);
      }
      final failure = record['failure'];
      if (failure is Map) {
        return BuildFailure(
          failure['message']?.toString() ?? 'The build failed.',
          diagnostics: diagnosticList(failure['diagnostics']),
        );
      }
    } catch (_) {
      // A truncated or obsolete record is rebuilt.
    }
    return null;
  }

  bool isBuilding(String key) => _inFlight.containsKey(key);

  Future<BuiltAlgorithm> build(
    List<int> bytes, {
    required String subject,
    Language language = Language.dart,
  }) {
    final key = keyFor(bytes, language: language);
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = language == Language.dart
        ? _build(key, bytes, subject)
        : _buildWithDaemon(key, bytes, subject, language);
    _inFlight[key] = future;
    // Block body: whenComplete must not wait for the map's (own) future.
    unawaited(future.then((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }));
    return future;
  }

  Future<BuiltAlgorithm> _build(String key, List<int> bytes, String subject) async {
    final hit = cached(key);
    if (hit is BuiltAlgorithm) return hit;
    if (hit is BuildFailure) throw hit;

    final total = Stopwatch()..start();
    stdout.writeln('[build] $subject: compiling');
    final directory = Directory('$workersDirectory/$key');
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    directory.createSync(recursive: true);
    final source = File('${directory.path}/algorithm.dart')
      ..writeAsBytesSync(bytes, flush: true);

    final String content;
    try {
      content = utf8.decode(bytes);
    } on FormatException {
      throw _record(key, BuildFailure('The file is not valid UTF-8 text.'));
    }

    final Map<String, dynamic> instrumented;
    final instrumentClock = Stopwatch()..start();
    try {
      instrumented = await instrumenter.instrument(
        source.absolute.path,
        content,
        directory.absolute.path,
      );
    } on StudentDiagnosticsException catch (error) {
      throw _record(
        key,
        BuildFailure(error.message, diagnostics: error.diagnostics),
      );
    } on InstrumenterUnavailable catch (error) {
      throw BuildFailure('$error', student: false);
    }
    buildProfile(subject, 'instrument', instrumentClock.elapsed);
    final meta = AlgorithmMeta.fromJson(instrumented['meta']);
    if (meta == null) {
      throw BuildFailure('The instrumenter returned no metadata.', student: false);
    }

    File('${directory.path}/worker.dart')
        .writeAsStringSync(workerSource(meta.className));
    final kernel = File('${directory.path}/worker.dill');
    final compileClock = Stopwatch()..start();
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '${directory.path}/worker.dart',
      '-o',
      kernel.path,
    ]);
    buildProfile(subject, 'compile kernel', compileClock.elapsed);
    if (compiled.exitCode == 0 && kernel.existsSync()) {
      File('${directory.path}/ready.json').writeAsStringSync(
          jsonEncode({'key': key, 'ok': true, 'meta': meta.toJson()}));
      buildProfile(subject, 'build total', total.elapsed);
      stdout.writeln('[build] $subject: ready');
      return BuiltAlgorithm(key, kernel.path, meta);
    }

    // The compiler reports positions in generated files. Ask the analyzer for
    // the copies instead: algorithm.dart is byte-identical to the student's
    // file and visual.dart keeps its line numbers.
    final original = await analyzeFile(source);
    if (original.isNotEmpty) {
      throw _record(
        key,
        BuildFailure(
          'Fix the errors in your Dart source and save again.',
          diagnostics: original,
        ),
      );
    }
    stderr.writeln('[build] $subject: compiler output:\n'
        '${compiled.stdout}${compiled.stderr}');
    final visual = await analyzeFile(File('${directory.path}/visual.dart'));
    if (visual.isNotEmpty) {
      throw _record(
        key,
        BuildFailure(
          'Your code is valid Dart, but the step-by-step visualizer cannot '
          'transform the marked line(s) yet. Try writing them more simply.',
          diagnostics: visual,
        ),
      );
    }
    final entry = await analyzeFile(File('${directory.path}/worker.dart'));
    if (entry.isNotEmpty) {
      throw _record(
        key,
        BuildFailure(
          'The sandbox cannot create ${meta.className}(): the class needs a '
          'constructor without parameters. (${entry.first['message']})',
        ),
      );
    }
    throw BuildFailure(
      'Dart could not compile this algorithm; see the terminal running ./run '
      'for details.',
      student: false,
    );
  }

  /// The other languages are built by their daemon: the contract, the
  /// language's own error checks (pyflakes, undefined names, javac) and the
  /// copies or classes the worker runs, written into the build directory.
  Future<BuiltAlgorithm> _buildWithDaemon(
    String key,
    List<int> bytes,
    String subject,
    Language language,
  ) async {
    final hit = cached(key);
    if (hit is BuiltAlgorithm) return hit;
    if (hit is BuildFailure) throw hit;

    final clock = Stopwatch()..start();
    stdout.writeln('[build] $subject: building');
    final directory = Directory('$workersDirectory/$key');
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    directory.createSync(recursive: true);
    final source = File('${directory.path}/algorithm${language.extension}')
      ..writeAsBytesSync(bytes, flush: true);

    final String content;
    try {
      content = utf8.decode(bytes);
    } on FormatException {
      throw _record(key, BuildFailure('The file is not valid UTF-8 text.'));
    }

    final Map<String, dynamic> built;
    try {
      built = await daemonFor(language).instrument(
        source.absolute.path,
        content,
        directory.absolute.path,
      );
    } on StudentDiagnosticsException catch (error) {
      throw _record(
        key,
        BuildFailure(error.message, diagnostics: error.diagnostics),
      );
    } on InstrumenterUnavailable catch (error) {
      throw BuildFailure(error.message, student: false);
    }
    final meta = AlgorithmMeta.fromJson(built['meta']);
    if (meta == null || !_complete(directory.path, language)) {
      throw BuildFailure('The ${language.label} build returned no result.', student: false);
    }
    File('${directory.path}/ready.json').writeAsStringSync(jsonEncode(
        {'key': key, 'ok': true, 'meta': meta.toJson(), 'language': language.id}));
    buildProfile(subject, '${language.id} build', clock.elapsed);
    stdout.writeln('[build] $subject: ready');
    return BuiltAlgorithm(key, _entry(directory.path, language), meta, language: language);
  }

  BuildFailure _record(String key, BuildFailure failure) {
    try {
      File('$workersDirectory/$key/ready.json').writeAsStringSync(jsonEncode({
        'key': key,
        'ok': false,
        'failure': {
          'message': failure.message,
          'diagnostics': failure.diagnostics,
        },
      }));
    } catch (_) {}
    return failure;
  }
}

String workerSource(String className) => '''
// Generated by the Sorting Sandbox. Do not edit.
import 'package:sorting_sandbox/worker_process.dart';

import 'algorithm.dart' as benchmark;
import 'visual.dart' as visual;

Future<void> main() => runWorkerProcess(
      createVisual: () => visual.$className(),
      createBenchmark: () => benchmark.$className(),
    );
''';

/// Errors that `dart analyze` reports for exactly [file], with positions in
/// that file. Used only after a failed compilation.
Future<List<Map<String, Object?>>> analyzeFile(File file) async {
  try {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['analyze', '--format=machine', file.absolute.path],
    );
    final expected = file.absolute.path;
    final diagnostics = <Map<String, Object?>>[];
    for (final line in '${result.stdout}\n${result.stderr}'.split('\n')) {
      // SEVERITY|TYPE|CODE|FILE|LINE|COLUMN|LENGTH|MESSAGE; `\|` escapes a pipe.
      final fields = line.split(RegExp(r'(?<!\\)\|'));
      if (fields.length < 8 || fields[0] != 'ERROR') continue;
      final filename = fields[3].replaceAll(r'\|', '|');
      if (File(filename).absolute.path != expected) continue;
      final row = int.tryParse(fields[4]);
      final column = int.tryParse(fields[5]);
      final length = int.tryParse(fields[6]);
      if (row == null || row < 1 || column == null || column < 1) continue;
      diagnostics.add({
        'line': row,
        'column': column,
        'length': length ?? 1,
        'message': fields.sublist(7).join('|').replaceAll(r'\|', '|'),
        'severity': 'error',
      });
      if (diagnostics.length >= 30) break;
    }
    return diagnostics;
  } catch (error) {
    stderr.writeln('[build] Could not analyze ${file.path}: $error');
    return const [];
  }
}

List<Map<String, Object?>> diagnosticList(Object? raw) => [
      if (raw is List)
        for (final entry in raw)
          if (entry is Map)
            entry.map((key, value) => MapEntry(key.toString(), value as Object?)),
    ];

String _computeToolFingerprint() {
  final files = <File>[
    File('pubspec.yaml'),
    File('pubspec.lock'),
    File('tool/build.dart'),
    File('tool/inspect.dart'),
    File('tool/instrumenter.dart'),
    File('tool/instrument_daemon.dart'),
    for (final directory in ['lib', 'packages/sorting_sandbox_api/lib'])
      if (Directory(directory).existsSync())
        ...Directory(directory)
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart')),
    if (Directory('languages').existsSync())
      ...Directory('languages').listSync(recursive: true).whereType<File>(),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final data = BytesBuilder(copy: false);
  for (final file in files) {
    data.add(utf8.encode('${file.path}\u0000'));
    if (file.existsSync()) data.add(file.readAsBytesSync());
    data.addByte(0);
  }
  return sha256.convert(data.takeBytes()).toString();
}

/// Removes worker revisions not used for [keep] and abandoned partial builds.
/// Runs at startup only, before any worker process exists.
({int removed, int bytes}) pruneWorkerCache({
  Duration keep = const Duration(days: 14),
}) {
  final root = Directory(workersDirectory);
  if (!root.existsSync()) return (removed: 0, bytes: 0);
  final now = DateTime.now();
  var removed = 0;
  var bytes = 0;
  for (final directory in root.listSync(followLinks: false).whereType<Directory>()) {
    try {
      final ready = File('${directory.path}/ready.json');
      final stamp = ready.existsSync()
          ? ready.lastModifiedSync()
          : directory.statSync().modified;
      final limit = ready.existsSync() ? keep : const Duration(hours: 1);
      if (now.difference(stamp) <= limit) continue;
      for (final file in directory.listSync(recursive: true).whereType<File>()) {
        bytes += file.lengthSync();
      }
      directory.deleteSync(recursive: true);
      removed++;
    } catch (_) {
      // Another ./run may be using it; try again next start.
    }
  }
  return (removed: removed, bytes: bytes);
}
