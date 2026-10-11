// Sorting Sandbox host: serves the browser UI, watches the class repository,
// builds one worker per algorithm revision and runs student code in
// disposable worker processes on behalf of each browser connection.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'build.dart';
import 'catalog.dart';
import 'instrument_client.dart';
import 'source_editor.dart';
import 'settings.dart';

const maxElements = 4096;
const maxValue = 1000000;
const maxRunsPerClient = 8;
const workerStartTimeout = Duration(seconds: 30);
const analysisTimeout = Duration(seconds: 12);
const checkTimeout = Duration(seconds: 20);

late final String repoPath;
late final Catalog catalog;
final instrumenter = InstrumentClient();
final builder = WorkerBuilder(instrumenter);
final clients = <Client>{};

Timer? _catalogBroadcast;

Map<String, Object?> catalogMessage() => {
      'type': 'catalog',
      'repository': repoPath,
      'exists': catalog.repositoryExists,
      'algorithms': catalog.snapshot(),
    };

void scheduleCatalogBroadcast() {
  _catalogBroadcast ??= Timer(const Duration(milliseconds: 120), () {
    _catalogBroadcast = null;
    final json = jsonEncode(catalogMessage());
    for (final client in clients) {
      client.sendRaw(json);
    }
  });
}

class WorkerExited implements Exception {
  WorkerExited(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// One running worker process (see lib/worker_process.dart).
class WorkerProcess {
  WorkerProcess._(this._process) {
    _out = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _line,
          onError: (Object error) => _exited('worker output failed: $error'),
          onDone: () => _exited('worker output closed'),
        );
    _err = _process.stderr.transform(utf8.decoder).listen((text) {
      final combined = '$_stderr$text';
      _stderr = combined.length > 6000
          ? combined.substring(combined.length - 6000)
          : combined;
    });
    // Writing to a process that already exited must not crash the host, and
    // a startup failure nobody waits for must not become an uncaught error.
    unawaited(_process.stdin.done.then((_) {}, onError: (Object _) {}));
    unawaited(_hello.future.then((_) {}, onError: (Object _) {}));
    unawaited(_process.exitCode.then((code) => _exited('exit code $code')));
  }

  final Process _process;
  late final StreamSubscription<String> _out;
  late final StreamSubscription<String> _err;
  final _hello = Completer<void>();
  String _stderr = '';
  bool _gone = false;

  void Function(Map<String, dynamic> message)? onMessage;
  void Function(String reason)? onExit;

  bool get dead => _gone;

  static Future<WorkerProcess> start(String kernelPath) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [kernelPath],
      workingDirectory: Directory.current.path,
    );
    final worker = WorkerProcess._(process);
    try {
      await worker._hello.future.timeout(workerStartTimeout);
    } catch (error) {
      worker.kill();
      throw WorkerExited('The worker did not start ($error). ${worker._stderr}'.trim());
    }
    return worker;
  }

  void _line(String line) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic>? message;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) message = decoded;
    } catch (_) {}
    if (message == null) {
      // Not protocol output (e.g. stdout.write in student code).
      onMessage?.call({'type': 'console', 'kind': 'stdout', 'text': line});
      return;
    }
    if (message['type'] == 'hello') {
      if (!_hello.isCompleted) _hello.complete();
      return;
    }
    onMessage?.call(message);
  }

  void send(Map<String, Object?> message) {
    if (_gone) return;
    try {
      _process.stdin.writeln(jsonEncode(message));
    } catch (_) {}
  }

  void _exited(String reason) {
    if (_gone) return;
    _gone = true;
    final detail = _stderr.trim();
    final text = detail.isEmpty ? reason : '$reason: $detail';
    if (!_hello.isCompleted) _hello.completeError(WorkerExited(text));
    final callback = onExit;
    onExit = null;
    onMessage = null;
    callback?.call(text);
  }

  void kill() {
    if (!_gone) {
      _gone = true;
      onExit = null;
      onMessage = null;
      if (!_hello.isCompleted) _hello.completeError(WorkerExited('stopped'));
    }
    _process.kill(ProcessSignal.sigkill);
    unawaited(_out.cancel());
    unawaited(_err.cancel());
  }
}

/// Starts a worker, sends one request and waits for [reply] (or an error).
Future<Map<String, dynamic>> requestOnce(
  BuiltAlgorithm built,
  Map<String, Object?> request, {
  required String reply,
  required Duration timeout,
  void Function(WorkerProcess worker)? register,
}) async {
  final worker = await WorkerProcess.start(built.kernelPath);
  register?.call(worker);
  final result = Completer<Map<String, dynamic>>();
  worker.onMessage = (message) {
    final type = message['type'];
    if ((type == reply || type == 'error') && !result.isCompleted) {
      result.complete(message);
    }
  };
  worker.onExit = (reason) {
    if (!result.isCompleted) result.completeError(WorkerExited(reason));
  };
  worker.send(request);
  try {
    return await result.future.timeout(timeout);
  } finally {
    worker.kill();
  }
}

class VisualRun {
  VisualRun(this.runId, this.algorithmId);

  final String runId;
  final String algorithmId;
  WorkerProcess? worker;
  Timer? watchdog;
  bool cancelled = false;
  int pendingBudget = 0;
  int lastLine = 0;

  void dispose() {
    cancelled = true;
    watchdog?.cancel();
    watchdog = null;
    worker?.kill();
    worker = null;
  }
}

class Job {
  Job(this.id);

  final String id;
  bool cancelled = false;
  final _workers = <WorkerProcess>{};

  void track(WorkerProcess worker) {
    if (cancelled) {
      worker.kill();
      return;
    }
    _workers.add(worker);
  }

  void cancel() {
    cancelled = true;
    for (final worker in _workers) {
      worker.kill();
    }
    _workers.clear();
  }
}

class Client {
  Client(this.socket);

  final WebSocket socket;
  bool closed = false;
  final runs = <String, VisualRun>{};
  final jobs = <String, Job>{};

  void send(Map<String, Object?> data) => sendRaw(jsonEncode(data));

  void sendRaw(String data) {
    if (!closed && socket.readyState == WebSocket.open) socket.add(data);
  }

  void close() {
    closed = true;
    for (final run in runs.values) {
      run.dispose();
    }
    runs.clear();
    for (final job in jobs.values) {
      job.cancel();
    }
    jobs.clear();
  }

  /// Long operations are never awaited here: the next message (Stop, an
  /// advance for another lane, a ping) must not wait for a compilation.
  void handle(Map<String, dynamic> message) {
    switch (message['action']) {
      case 'ping':
        send({'type': 'pong'});
      case 'readSource':
        _readSource(message);
      case 'saveSource':
        _saveSource(message);
      case 'formatSource':
        unawaited(_formatSource(message));
      case 'visualStart':
        unawaited(_visualStart(message));
      case 'advance':
        _advance(message);
      case 'stop':
        final runId = message['runId'];
        if (runId is String) runs.remove(runId)?.dispose();
      case 'analyze':
        unawaited(_analyze(message));
      case 'check':
        unawaited(_check(message));
      case 'cancel':
        final jobId = message['jobId'];
        if (jobId is String) jobs.remove(jobId)?.cancel();
      default:
        send({'type': 'error', 'message': 'Unknown action: ${message['action']}'});
    }
  }

  // ---------------------------------------------------------------- sources

  void _readSource(Map<String, dynamic> message) {
    final id = message['id'];
    final algorithm = id is String ? catalog[id] : null;
    if (algorithm == null) {
      send({'type': 'sourceError', 'id': id, 'message': 'This algorithm no longer exists.'});
      return;
    }
    try {
      send(readEditableSource(algorithm, repoPath));
    } on FormatException catch (error) {
      send({'type': 'sourceError', 'id': id, 'message': error.message});
    } on FileSystemException catch (error) {
      send({'type': 'sourceError', 'id': id, 'message': 'Could not read the file: ${error.message}'});
    }
  }

  void _saveSource(Map<String, dynamic> message) {
    final id = message['id'];
    final content = message['content'];
    final revision = message['revision'];
    final algorithm = id is String ? catalog[id] : null;
    if (algorithm == null || content is! String || revision is! String) {
      send({'type': 'sourceError', 'id': id, 'message': 'Invalid save request.'});
      return;
    }
    try {
      send(saveEditableSource(algorithm, repoPath, revision, content));
      catalog.touch(algorithm.id); // Starts checking and compiling right away.
    } on FormatException catch (error) {
      send({'type': 'sourceError', 'id': id, 'message': error.message, 'conflict': error.message.contains('changed since')});
    } on FileSystemException catch (error) {
      send({'type': 'sourceError', 'id': id, 'message': 'Could not save the file: ${error.message}'});
    }
  }

  Future<void> _formatSource(Map<String, dynamic> message) async {
    final id = message['id'];
    final requestId = message['requestId'];
    final content = message['content'];
    final algorithm = id is String ? catalog[id] : null;
    final response = <String, Object?>{
      'id': id,
      'requestId': requestId,
      'revision': message['revision'],
    };
    try {
      if (algorithm == null || content is! String || requestId is! int) {
        throw const FormatException('Invalid format request.');
      }
      final formatted = await formatDraft(algorithm.path, content);
      send({'type': 'sourceFormatted', ...response, 'content': formatted});
    } catch (error) {
      final text = error is FormatException ? error.message : '$error';
      send({
        'type': 'sourceFormatError',
        ...response,
        'message': text.length > 1800 ? text.substring(0, 1800) : text,
      });
    }
  }

  // ------------------------------------------------------------ visual runs

  Future<void> _visualStart(Map<String, dynamic> message) async {
    final runId = message['runId'];
    final id = message['id'];
    final raw = message['values'];
    if (runId is! String || runId.isEmpty || runId.length > 120 ||
        id is! String || raw is! List || raw.length > maxElements) {
      send({'type': 'error', 'message': 'Invalid run request.'});
      return;
    }
    final values = <int>[];
    for (final value in raw) {
      if (value is! int || value.abs() > maxValue) {
        send({'type': 'runError', 'runId': runId, 'error': {'kind': 'request', 'message': 'Invalid input values.'}});
        return;
      }
      values.add(value);
    }

    runs.remove(runId)?.dispose();
    while (runs.length >= maxRunsPerClient) {
      runs.remove(runs.keys.first)?.dispose();
    }
    final run = VisualRun(runId, id);
    runs[runId] = run;

    final algorithm = catalog[id];
    if (algorithm == null) {
      _runError(run, {'kind': 'missing', 'message': 'This algorithm no longer exists.'});
      return;
    }
    final revision = algorithm.revision;
    if (algorithm.built == null) {
      send({'type': 'runStatus', 'runId': runId, 'state': 'building'});
    }
    final BuiltAlgorithm built;
    try {
      built = await catalog.ensureBuilt(id);
    } on BuildFailure catch (failure) {
      if (!run.cancelled) {
        _runError(run, {
          'kind': failure.student ? 'compile' : 'unavailable',
          'message': failure.message,
        });
      }
      return;
    } catch (error) {
      if (!run.cancelled) {
        _runError(run, {'kind': 'crash', 'message': 'Could not prepare the algorithm: $error'});
      }
      return;
    }
    if (run.cancelled || closed) return;

    final WorkerProcess worker;
    try {
      worker = await WorkerProcess.start(built.kernelPath);
    } catch (error) {
      if (!run.cancelled) _runError(run, {'kind': 'crash', 'message': '$error'});
      return;
    }
    if (run.cancelled || closed) {
      worker.kill();
      return;
    }
    run.worker = worker;
    worker.onMessage = (workerMessage) => _workerMessage(run, workerMessage);
    worker.onExit = (reason) {
      if (run.cancelled) return;
      _runError(run, {
        'kind': 'crash',
        'message': 'The algorithm process stopped unexpectedly ($reason). '
            'It may have run out of memory.',
        if (run.lastLine > 0) 'line': run.lastLine,
      });
    };
    send({'type': 'runStarted', 'runId': runId, 'id': id, 'revision': revision});
    worker.send({'type': 'visualStart', 'requestId': runId, 'values': values});
    _arm(run, const Duration(seconds: 10));
    if (run.pendingBudget > 0) {
      worker.send({'type': 'advance', 'requestId': runId, 'budget': run.pendingBudget});
      run.pendingBudget = 0;
    }
  }

  void _advance(Map<String, dynamic> message) {
    final runId = message['runId'];
    final budget = message['budget'];
    if (runId is! String || budget is! int || budget < 1) return;
    final run = runs[runId];
    if (run == null) return;
    final worker = run.worker;
    if (worker == null) {
      run.pendingBudget += budget;
      return;
    }
    worker.send({'type': 'advance', 'requestId': runId, 'budget': budget});
    // Replaying to an earlier step can legitimately take a while.
    _arm(run, message['long'] == true ? const Duration(seconds: 90) : const Duration(seconds: 4));
  }

  void _arm(VisualRun run, Duration limit) {
    run.watchdog?.cancel();
    run.watchdog = Timer(limit, () {
      if (!identical(runs[run.runId], run)) return;
      _runError(run, {
        'kind': 'timeout',
        'message': 'No checkpoint was reached for ${limit.inSeconds} seconds, '
            'so the algorithm was stopped. Is it stuck in a loop or recursion?',
        if (run.lastLine > 0) 'line': run.lastLine,
      });
    });
  }

  void _workerMessage(VisualRun run, Map<String, dynamic> message) {
    if (!identical(runs[run.runId], run)) return;
    final type = message['type'];
    message.remove('requestId');
    switch (type) {
      case 'frame':
        run.watchdog?.cancel();
        final line = message['line'];
        if (line is int) run.lastLine = line;
        send({...message, 'runId': run.runId});
      case 'complete':
        send({'type': 'complete', 'runId': run.runId});
        _finish(run);
      case 'runError':
        send({'type': 'runError', 'runId': run.runId, 'error': message['error']});
        _finish(run);
      case 'console':
        send({...message, 'runId': run.runId});
      case 'error':
        _runError(run, {
          'kind': 'runtime',
          'message': message['message']?.toString() ?? 'The worker reported an error.',
        });
      default:
        break;
    }
  }

  void _runError(VisualRun run, Map<String, Object?> error) {
    send({'type': 'runError', 'runId': run.runId, 'error': error});
    _finish(run);
  }

  void _finish(VisualRun run) {
    if (identical(runs[run.runId], run)) runs.remove(run.runId);
    run.dispose();
  }

  // ------------------------------------------------------ analysis & checks

  Job _newJob(String jobId) {
    jobs.remove(jobId)?.cancel();
    final job = Job(jobId);
    jobs[jobId] = job;
    return job;
  }

  void _endJob(Job job) {
    if (identical(jobs[job.id], job)) jobs.remove(job.id);
  }

  Future<void> _analyze(Map<String, dynamic> message) async {
    final jobId = message['jobId'];
    final rawIds = message['ids'];
    final rawCases = message['cases'];
    if (jobId is! String || rawIds is! List || rawCases is! List || rawCases.length > 16) {
      send({'type': 'error', 'message': 'Invalid analysis request.'});
      return;
    }
    final cases = <List<int>>[];
    for (final entry in rawCases) {
      if (entry is! List || entry.length > 2 * maxElements) {
        send({'type': 'error', 'message': 'Invalid analysis input.'});
        return;
      }
      cases.add([for (final value in entry) if (value is int) value]);
    }
    final queue = [for (final id in rawIds) if (id is String) id];
    final job = _newJob(jobId);

    Future<void> lane() async {
      while (queue.isNotEmpty && !job.cancelled && !closed) {
        final id = queue.removeAt(0);
        final outcome = await _runJobRequest(
          job,
          id,
          {'type': 'analyze', 'requestId': jobId, 'cases': cases},
          reply: 'analysisResult',
          timeout: analysisTimeout,
        );
        if (job.cancelled || closed) return;
        send({'type': 'analysisResult', 'jobId': jobId, 'id': id, ...outcome});
      }
    }

    final lanes = math.max(2, math.min(6, Platform.numberOfProcessors - 1));
    await Future.wait([for (var i = 0; i < lanes; i++) lane()]);
    if (!job.cancelled && !closed) send({'type': 'analysisDone', 'jobId': jobId});
    _endJob(job);
  }

  Future<void> _check(Map<String, dynamic> message) async {
    final jobId = message['jobId'];
    final id = message['id'];
    if (jobId is! String || id is! String) {
      send({'type': 'error', 'message': 'Invalid check request.'});
      return;
    }
    final job = _newJob(jobId);
    final outcome = await _runJobRequest(
      job,
      id,
      {'type': 'check', 'requestId': jobId},
      reply: 'checkResult',
      timeout: checkTimeout,
    );
    if (!job.cancelled && !closed) {
      send({'type': 'checkResult', 'jobId': jobId, 'id': id, ...outcome});
    }
    _endJob(job);
  }

  /// Builds (if needed) and runs one disposable request. Never throws: the
  /// outcome is `{revision, result: {status, ...}}`.
  Future<Map<String, Object?>> _runJobRequest(
    Job job,
    String id,
    Map<String, Object?> request, {
    required String reply,
    required Duration timeout,
  }) async {
    final algorithm = catalog[id];
    if (algorithm == null) {
      return {'revision': null, 'result': {'status': 'missing', 'message': 'This algorithm no longer exists.'}};
    }
    final revision = algorithm.revision;
    try {
      final built = await catalog.ensureBuilt(id);
      if (job.cancelled) return {'revision': revision, 'result': {'status': 'cancelled'}};
      final response = await requestOnce(
        built,
        request,
        reply: reply,
        timeout: timeout,
        register: job.track,
      );
      if (response['type'] == 'error') {
        return {
          'revision': revision,
          'result': {
            'status': 'crash',
            'message': response['message']?.toString() ?? 'The worker reported an error.',
            'error': response['error'],
          },
        };
      }
      final result = Map<String, Object?>.from(response)
        ..remove('type')
        ..remove('requestId');
      return {'revision': revision, 'result': {'status': 'done', ...result}};
    } on BuildFailure catch (failure) {
      return {
        'revision': revision,
        'result': {
          'status': failure.student ? 'compile' : 'crash',
          'message': failure.student
              ? failure.message
              : 'The sandbox could not build this algorithm: ${failure.message}',
        },
      };
    } on TimeoutException {
      return {
        'revision': revision,
        'result': {
          'status': 'timeout',
          'message': 'Did not finish within ${timeout.inSeconds} seconds.',
        },
      };
    } catch (error) {
      return {
        'revision': revision,
        'result': {'status': job.cancelled ? 'cancelled' : 'crash', 'message': '$error'},
      };
    }
  }
}

// ----------------------------------------------------------------- server

void main(List<String> args) {
  // A bug in the host must never take the classroom server down: log
  // unexpected asynchronous errors instead of terminating the process.
  runZonedGuarded(() => unawaited(_main(args)), (error, stack) {
    stderr.writeln('[host] Unexpected error: $error\n$stack');
  });
}

Future<void> _main(List<String> args) async {
  var port = 8080;
  var host = '127.0.0.1';
  var openBrowser = true;
  var repository = 'algorithms';
  const usage = 'Usage: ./run [--algorithms PATH] [--port PORT] '
      '[--host ADDRESS] [--no-open]';
  for (var i = 0; i < args.length; i++) {
    final flag = args[i];
    final needsValue = flag == '--port' || flag == '--host' || flag == '--algorithms';
    if (needsValue && i + 1 >= args.length) {
      stderr.writeln('Missing value for $flag\n$usage');
      exit(64);
    }
    switch (flag) {
      case '--port':
        final parsed = int.tryParse(args[++i]);
        if (parsed == null) {
          stderr.writeln('Invalid port.\n$usage');
          exit(64);
        }
        port = parsed;
      case '--host':
        host = args[++i];
      case '--algorithms':
        repository = args[++i];
      case '--no-open':
        openBrowser = false;
      default:
        stderr.writeln(usage);
        exit(64);
    }
  }
  repoPath = repository;

  final pruned = pruneWorkerCache();
  if (pruned.removed > 0) {
    stdout.writeln('[cache] Removed ${pruned.removed} unused worker builds '
        '(${(pruned.bytes / (1024 * 1024)).toStringAsFixed(1)} MiB).');
  }

  catalog = Catalog(
    repoPath: repoPath,
    builder: builder,
    instrumenter: instrumenter,
    onChanged: scheduleCatalogBroadcast,
  );
  if (!catalog.repositoryExists) {
    stdout.writeln('Algorithm repository not found: '
        '${Directory(repoPath).absolute.path}\n'
        'Clone the class repository into it, for example:\n'
        '  git clone <class-repository-url> $repoPath\n'
        'The app picks it up automatically once it exists.');
  }
  unawaited(instrumenter.warm().catchError((Object error) {
    stderr.writeln('[instrumenter] Startup failed: $error');
  }));
  catalog.scan();
  Timer.periodic(const Duration(milliseconds: 700), (_) {
    try {
      catalog.scan();
    } catch (error) {
      stderr.writeln('[watch] $error');
    }
  });

  final HttpServer server;
  try {
    server = await HttpServer.bind(host, port);
  } on SocketException catch (error) {
    stderr.writeln('Could not listen on $host:$port (${error.message}). '
        'Is the Sorting Sandbox already running? Try ./run --port ${port + 1}');
    exit(69);
  }
  final shown = host == '0.0.0.0' ? '127.0.0.1' : host;
  final url = 'http://$shown:${server.port}/';
  stdout.writeln('Sorting Sandbox · $url · algorithms: '
      '${Directory(repoPath).absolute.path}');
  stdout.writeln('Press Ctrl+C to stop.');
  if (openBrowser) unawaited(_openBrowser(url));

  await for (final request in server) {
    unawaited(_handleRequest(request));
  }
}

const _contentTypes = <String, String>{
  'html': 'text/html; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'mjs': 'text/javascript; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'svg': 'image/svg+xml',
  'jpg': 'image/jpeg',
  'png': 'image/png',
  'ttf': 'font/ttf',
  'txt': 'text/plain; charset=utf-8',
};

Future<void> _handleRequest(HttpRequest request) async {
  try {
    if (request.uri.path == '/ws' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.pingInterval = const Duration(seconds: 20);
      final client = Client(socket);
      clients.add(client);
      client.send(catalogMessage());
      try {
        await for (final raw in socket) {
          try {
            if (raw is! String) continue;
            final decoded = jsonDecode(raw);
            if (decoded is! Map<String, dynamic>) {
              throw const FormatException('Expected a JSON object.');
            }
            client.handle(decoded);
          } catch (error) {
            client.send({'type': 'error', 'message': '$error'});
          }
        }
      } finally {
        client.close();
        clients.remove(client);
      }
      return;
    }

    if (request.uri.path == '/api/settings') {
      await handleSettings(request);
      return;
    }

    final response = request.response;
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final file = _staticFile(request.uri.path);
    if (file == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final extension = file.path.split('.').last.toLowerCase();
    response.headers
      ..set(HttpHeaders.contentTypeHeader,
          _contentTypes[extension] ?? 'application/octet-stream')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    if (file.path == 'web/index.html') {
      if (request.method == 'GET') response.write(themedPage(await file.readAsString()));
    } else if (request.method == 'GET') {
      await response.addStream(file.openRead());
    }
    await response.close();
  } catch (error) {
    stderr.writeln('Browser request error: $error');
    try {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    } catch (_) {}
  }
}

/// Files below web/ only; no hidden segments and no parent traversal.
File? _staticFile(String path) {
  final relative = path == '/' ? 'index.html' : path.replaceFirst(RegExp(r'^/+'), '');
  final segments = relative.split('/');
  if (segments.any((s) => s.isEmpty || s.startsWith('.') || s.contains('\\'))) {
    return null;
  }
  final file = File('web/${segments.join('/')}');
  if (!file.existsSync()) return null;
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    return null;
  }
  return file;
}

Future<void> _openBrowser(String url) async {
  await Future<void>.delayed(const Duration(milliseconds: 350));
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url]);
    } else {
      await Process.run('xdg-open', [url]);
    }
  } catch (_) {
    // The URL is printed; a missing desktop opener is harmless.
  }
}
