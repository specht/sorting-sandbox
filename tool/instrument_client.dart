// A single, persistent parser/instrumenter process shared by all browser
// sessions. Student algorithms still run in separate, killable workers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A problem in the student's source: shown in the editor, never retried.
class StudentDiagnosticsException implements Exception {
  StudentDiagnosticsException(this.message, this.diagnostics);
  final String message;
  final List<Map<String, Object?>> diagnostics;
  @override
  String toString() => message;
}

/// The daemon itself failed (startup, crash, broken pipe, timeout).
class InstrumenterUnavailable implements Exception {
  InstrumenterUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class InstrumentClient {
  /// The Dart parser daemon (tool/instrument_daemon.dart). Other languages
  /// pass the command of their own daemon, which speaks the same protocol
  /// (e.g. languages/python/sandbox_daemon.py).
  InstrumentClient({
    Future<List<String>> Function()? command,
    this.label = 'instrumenter',
  }) : _command = command ??
            (() async => [Platform.resolvedExecutable, 'run', 'tool/instrument_daemon.dart']);

  final Future<List<String>> Function() _command;

  /// Prefix of this daemon's lines in the terminal.
  final String label;

  Process? _process;
  Future<void>? _starting;
  Completer<void>? _greeting;
  bool _ready = false;
  int _requestId = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  Future<void> warm() => _ensureStarted();

  /// Stops the daemon (tests; the host keeps it for its whole lifetime).
  void dispose() {
    final process = _process;
    if (process == null) return;
    _lost(process, 'disposed');
    process.kill();
  }

  /// Parser-only check of a file's syntax and classroom contract.
  Future<Map<String, dynamic>> inspect(String path, String content) =>
      _request({'op': 'inspect', 'path': path, 'content': content},
          throwOnStudentError: false);

  /// Writes `visual.dart` into [outDirectory]; throws
  /// [StudentDiagnosticsException] for invalid student source.
  Future<Map<String, dynamic>> instrument(
    String path,
    String content,
    String outDirectory,
  ) =>
      _request({
        'op': 'instrument',
        'path': path,
        'content': content,
        'out': outDirectory,
      }, throwOnStudentError: true);

  /// Formats an editor draft (daemons of languages without a formatter
  /// command of their own). Returns `{ok, content}` or `{ok: false, error}`.
  Future<Map<String, dynamic>> format(String path, String content) =>
      _request({'op': 'format', 'path': path, 'content': content},
          throwOnStudentError: false);

  Future<void> _ensureStarted() {
    if (_ready && _process != null) return Future<void>.value();
    return _starting ??= _start().whenComplete(() {
      _starting = null;
    });
  }

  Future<void> _start() async {
    final greeting = Completer<void>();
    // May throw a subclass of InstrumenterUnavailable (toolchain missing).
    final command = await _command();
    late final Process process;
    try {
      process = await Process.start(
        command.first,
        command.sublist(1),
        workingDirectory: Directory.current.path,
      );
    } catch (error) {
      throw InstrumenterUnavailable('Cannot start the $label: $error');
    }
    _process = process;
    _greeting = greeting;
    _ready = false;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              final response = jsonDecode(line);
              if (response is! Map<String, dynamic>) {
                throw const FormatException('Not an object');
              }
              if (response['type'] == 'ready') {
                if (!greeting.isCompleted) greeting.complete();
                return;
              }
              final id = response['id'];
              if (id is int) {
                final waiter = _pending.remove(id);
                if (waiter != null && !waiter.isCompleted) {
                  waiter.complete(response);
                }
              }
            } catch (_) {
              stderr.writeln('[$label] $line');
            }
          },
          onError: (Object error) => _lost(process, error),
          onDone: () => _lost(process, 'stdout closed'),
        );
    process.stderr.transform(utf8.decoder).listen((text) {
      stderr.write('[$label] $text');
    });
    unawaited(process.exitCode
        .then((code) => _lost(process, 'process exited with code $code')));
    try {
      await greeting.future.timeout(const Duration(seconds: 90));
      if (!identical(_process, process)) {
        throw InstrumenterUnavailable('The $label exited during startup.');
      }
      _ready = true;
    } catch (error) {
      _lost(process, error);
      process.kill();
      if (error is InstrumenterUnavailable) rethrow;
      throw InstrumenterUnavailable('The $label could not start: $error');
    }
  }

  void _lost(Process process, Object error) {
    if (!identical(_process, process)) return;
    _process = null;
    _ready = false;
    final greeting = _greeting;
    _greeting = null;
    final failure = InstrumenterUnavailable('Instrumenter unavailable: $error');
    if (greeting != null && !greeting.isCompleted) {
      greeting.completeError(failure);
    }
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(failure);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> _request(
    Map<String, Object?> payload, {
    required bool throwOnStudentError,
  }) async {
    // Retry only process/transport failures. Invalid student code returns its
    // diagnostics immediately and is never retried.
    for (var attempt = 0;; attempt++) {
      try {
        await _ensureStarted();
        final process = _process;
        if (process == null) {
          throw InstrumenterUnavailable('Instrumenter exited before request.');
        }
        final id = ++_requestId;
        final waiting = Completer<Map<String, dynamic>>();
        // A failure of the daemon completes every pending request with an
        // error; one that is not awaited yet must not become uncaught.
        unawaited(waiting.future.then((_) {}, onError: (Object _) {}));
        _pending[id] = waiting;
        try {
          // No flush(): many files are checked at once, and concurrent
          // flushes of one pipe throw "StreamSink is bound to a stream".
          // The sink delivers buffered lines on its own.
          process.stdin.writeln(jsonEncode({...payload, 'id': id}));
          final result =
              await waiting.future.timeout(const Duration(seconds: 60));
          if (throwOnStudentError && result['ok'] != true) {
            final diagnostics = _diagnostics(result['diagnostics']);
            final message = result['error']?.toString() ??
                'Fix the errors in your Dart source and save again.';
            throw StudentDiagnosticsException(message, diagnostics);
          }
          return result;
        } on TimeoutException {
          _lost(process, 'request timed out');
          process.kill();
          throw InstrumenterUnavailable('Instrumenter request timed out.');
        } on FileSystemException catch (error) {
          _lost(process, error);
          process.kill();
          throw InstrumenterUnavailable('Instrumenter pipe failed: $error');
        } on StateError catch (error) {
          _lost(process, error);
          process.kill();
          throw InstrumenterUnavailable('Instrumenter closed its input: $error');
        } finally {
          _pending.remove(id);
        }
      } on InstrumenterUnavailable {
        if (attempt >= 1) rethrow;
      }
    }
  }
}

List<Map<String, Object?>> _diagnostics(Object? raw) => [
  if (raw is List)
    for (final entry in raw)
      if (entry is Map)
        entry.map((key, value) => MapEntry(key.toString(), value as Object?)),
];
