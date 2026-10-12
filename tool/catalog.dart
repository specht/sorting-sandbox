// The class repository as the browser sees it: every algorithm file, valid or
// not, with its metadata, build status and editor diagnostics.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'build.dart';
import 'inspect.dart' show AlgorithmMeta;
import 'instrument_client.dart';
import 'languages.dart';

// Student folders and file names as they occur in class repositories:
// letters, digits, '_', '-' and '.', e.g. liu.kashiwabara/ or even a folder
// called klara_sort.dart/. A segment never starts with '.', so hidden
// folders, '.' and '..' are excluded.
final studentName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final _fileSegment = studentName;
const maxSourceBytes = 256 * 1024;

String revisionOf(List<int> bytes) =>
    sha256.convert(bytes).toString().substring(0, 24);

class AlgorithmFile {
  AlgorithmFile({
    required this.id,
    required this.student,
    required this.relativePath,
    required this.path,
    required this.stem,
    this.language = Language.dart,
  });

  /// `student/name` for Dart files (the path without `.dart`, as always);
  /// other languages keep their extension, e.g. `student/name.py`, so that
  /// quick_sort.dart and quick_sort.py of one student are different entries.
  final String id;
  final String student;
  final String relativePath;
  final String path;

  /// The file name without its extension, e.g. `quick_sort`.
  final String stem;
  final Language language;

  int size = -1;
  DateTime modified = DateTime.fromMillisecondsSinceEpoch(0);
  String revision = '';
  List<int> bytes = const [];

  AlgorithmMeta? meta;

  /// checking · queued · building · ready · error
  String status = 'checking';
  String? message;
  List<Map<String, Object?>> diagnostics = const [];
  BuiltAlgorithm? built;

  /// The last error came from the environment, not from the student's code:
  /// the next run or check tries again.
  bool retryable = false;

  String get author => meta?.author ?? student;
  String get displayName => meta?.name ?? _prettyName(stem);

  Map<String, Object?> toJson() => {
    'id': id,
    'student': student,
    'path': relativePath,
    'language': language.id,
    'revision': revision,
    'name': displayName,
    'author': author,
    'color': meta?.color ?? '#7C8796',
    // An environment failure is not the student's fault: the browser may
    // still try to run the algorithm (which retries the build).
    'status': status == 'error' && retryable ? 'unavailable' : status,
    if (message != null) 'message': message,
    'diagnostics': diagnostics,
  };
}

String _prettyName(String stem) => stem
    .split(RegExp(r'[_-]+'))
    .where((part) => part.isNotEmpty)
    .map((part) => part[0].toUpperCase() + part.substring(1))
    .join(' ');

class Catalog {
  Catalog({
    required this.repoPath,
    required this.builder,
    required this.instrumenter,
    required this.onChanged,
  });

  final String repoPath;
  final WorkerBuilder builder;
  final InstrumentClient instrumenter;

  /// Called (debounced by the host) whenever entries or statuses change.
  final void Function() onChanged;

  final Map<String, AlgorithmFile> files = {};
  final List<String> _queue = [];
  int _activeBuilds = 0;
  /// Background builds (each is one `dart compile kernel` process).
  static final _parallelBuilds =
      math.max(1, math.min(4, Platform.numberOfProcessors ~/ 2));

  bool get repositoryExists => Directory(repoPath).existsSync();

  List<Map<String, Object?>> snapshot() {
    final entries = files.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return [for (final file in entries) file.toJson()];
  }

  AlgorithmFile? operator [](String id) => files[id];

  /// Re-reads the directory listing; cheap enough to run every 700 ms.
  void scan() {
    final root = Directory(repoPath);
    final seen = <String>{};
    var changed = false;
    if (root.existsSync()) {
      var rootPath = root.absolute.path;
      while (rootPath.length > 1 && rootPath.endsWith(Platform.pathSeparator)) {
        rootPath = rootPath.substring(0, rootPath.length - 1);
      }
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final language = Language.forPath(entity.path);
        if (language == null) continue;
        final relative = entity.absolute.path.substring(rootPath.length + 1);
        final segments = relative.split(Platform.pathSeparator);
        if (segments.length < 2 || !studentName.hasMatch(segments.first)) continue;
        if (segments.any((segment) => segment.startsWith('.'))) continue;
        final stem = segments.last
            .substring(0, segments.last.length - language.extension.length);
        final stems = [...segments.sublist(0, segments.length - 1), stem];
        if (!stems.every(_fileSegment.hasMatch)) continue;
        // Caches, virtual environments and packages are never algorithms.
        if (segments.any(const {'__pycache__', 'venv', 'site-packages', 'node_modules'}.contains)) {
          continue;
        }
        final id = language == Language.dart
            ? stems.join('/')
            : '${stems.join('/')}${language.extension}';
        seen.add(id);
        final file = files.putIfAbsent(id, () {
          changed = true;
          return AlgorithmFile(
            id: id,
            student: segments.first,
            relativePath: segments.join('/'),
            path: entity.absolute.path,
            stem: stem,
            language: language,
          );
        });
        if (_refreshFromDisk(file)) changed = true;
      }
    }
    final removed = files.keys.where((id) => !seen.contains(id)).toList();
    for (final id in removed) {
      files.remove(id);
      changed = true;
    }
    if (changed) onChanged();
  }

  /// Rescans one file immediately (after a browser save).
  void touch(String id) {
    final file = files[id];
    if (file != null && _refreshFromDisk(file, force: true)) onChanged();
  }

  bool _refreshFromDisk(AlgorithmFile file, {bool force = false}) {
    final FileStat stat;
    try {
      stat = File(file.path).statSync();
    } catch (_) {
      return false;
    }
    if (!force && stat.size == file.size && stat.modified == file.modified) {
      return false;
    }
    file.size = stat.size;
    file.modified = stat.modified;
    if (stat.size > maxSourceBytes) {
      final changed = file.status != 'error';
      file
        ..revision = 'too-large-${stat.size}'
        ..bytes = const []
        ..meta = null
        ..built = null
        ..status = 'error'
        ..message = 'This file is larger than 256 KiB.'
        ..diagnostics = const [];
      return changed;
    }
    final List<int> bytes;
    try {
      bytes = File(file.path).readAsBytesSync();
    } catch (_) {
      return false;
    }
    final revision = revisionOf(bytes);
    if (revision == file.revision) return false;
    file
      ..revision = revision
      ..bytes = bytes
      ..built = null
      ..status = 'checking'
      ..message = null
      ..retryable = false
      ..diagnostics = const [];
    unawaited(_inspect(file, revision));
    return true;
  }

  Future<void> _inspect(AlgorithmFile file, String revision) async {
    final key = builder.keyFor(file.bytes, language: file.language);
    final cached = builder.cached(key);
    if (cached is BuiltAlgorithm) {
      file
        ..meta = cached.meta
        ..built = cached
        ..status = 'ready';
      onChanged();
      return;
    }
    if (cached is BuildFailure) {
      // Keep the name and color visible even when the code does not compile.
      await _inspectMetadata(file, revision);
      if (file.revision != revision) return;
      _fail(file, cached);
      onChanged();
      return;
    }
    final ok = await _inspectMetadata(file, revision);
    if (file.revision != revision) return;
    // A browser run may have built this revision in the meantime.
    if (ok && file.built == null && file.status == 'checking') {
      file.status = 'queued';
      _enqueue(file.id);
    }
    onChanged();
  }

  /// Parser-only check; returns true when the file may be compiled.
  Future<bool> _inspectMetadata(AlgorithmFile file, String revision) async {
    final content = _decode(file.bytes);
    if (content == null) {
      file
        ..status = 'error'
        ..message = 'The file is not valid UTF-8 text.'
        ..diagnostics = const [];
      return false;
    }
    try {
      final result =
          await builder.daemonFor(file.language).inspect(file.path, content);
      if (file.revision != revision) return false;
      final meta = AlgorithmMeta.fromJson(result['meta']);
      if (meta != null) file.meta = meta;
      if (result['ok'] == true) return true;
      if (file.built != null) return false;
      file
        ..status = 'error'
        ..message = result['error']?.toString() ??
            'Fix the marked problems and save again.'
        ..diagnostics = diagnosticList(result['diagnostics']);
      return false;
    } catch (error) {
      if (file.revision == revision && file.built == null) {
        file
          ..status = 'error'
          ..message = error is ToolchainMissing
              ? error.message
              : 'The sandbox could not check this file: $error'
          ..retryable = true
          ..diagnostics = const [];
      }
      return false;
    }
  }

  void _enqueue(String id) {
    if (!_queue.contains(id)) _queue.add(id);
    _pump();
  }

  void _pump() {
    while (_activeBuilds < _parallelBuilds && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      final file = files[id];
      if (file == null || file.status != 'queued') continue;
      _activeBuilds++;
      unawaited(ensureBuilt(id).then((_) {}, onError: (Object _) {}).whenComplete(() {
        _activeBuilds--;
        _pump();
      }));
    }
  }

  /// The compiled worker for the CURRENT revision of [id], building it if
  /// necessary. Throws [BuildFailure] (with editor diagnostics) on errors.
  Future<BuiltAlgorithm> ensureBuilt(String id) async {
    final file = files[id];
    if (file == null) throw BuildFailure('Algorithm not found: $id', student: false);
    final existing = file.built;
    if (existing != null) return existing;
    if (file.status == 'error' && !file.retryable) {
      throw BuildFailure(file.message ?? 'Fix the errors in this file first.',
          diagnostics: file.diagnostics);
    }
    final revision = file.revision;
    final bytes = file.bytes;
    if (file.status != 'building') {
      file.status = 'building';
      onChanged();
    }
    try {
      final built = await builder.build(bytes, subject: id, language: file.language);
      if (file.revision == revision) {
        file
          ..built = built
          ..meta = built.meta
          ..status = 'ready'
          ..message = null
          ..diagnostics = const [];
        onChanged();
      }
      return built;
    } on BuildFailure catch (failure) {
      if (file.revision == revision) {
        _fail(file, failure);
        onChanged();
      }
      rethrow;
    }
  }

  void _fail(AlgorithmFile file, BuildFailure failure) {
    file
      ..built = null
      ..status = 'error'
      ..message = failure.message
      ..retryable = !failure.student
      ..diagnostics = failure.diagnostics;
  }
}

String? _decode(List<int> bytes) {
  try {
    return const Utf8Decoder().convert(bytes);
  } on FormatException {
    return null;
  }
}
