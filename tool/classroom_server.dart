import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final root = Directory.current.absolute;
  final build = Directory('${root.path}/build/web');
  final runtime = Directory('${root.path}/runtime');
  final port = int.tryParse(_value(args, '--port') ?? '') ?? 8080;
  final host = _value(args, '--host') ?? '127.0.0.1';

  if (!build.existsSync()) {
    stderr.writeln('build/web does not exist. Run flutter build web first.');
    exitCode = 66;
    return;
  }

  final server = await HttpServer.bind(host, port);
  final url = 'http://$host:$port/';
  stdout.writeln('Sorting Sandbox classroom server: $url');
  stdout.writeln('Algorithm worker and catalog are served live from runtime/.');
  stdout.writeln('Press Ctrl+C to stop.');

  if (args.contains('--open')) {
    unawaited(_openBrowser(url));
  }

  await for (final request in server) {
    unawaited(_serve(request, build: build, runtime: runtime));
  }
}

Future<void> _serve(
  HttpRequest request, {
  required Directory build,
  required Directory runtime,
}) async {
  try {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    final rawPath = Uri.decodeComponent(request.uri.path);
    final path = rawPath == '/' ? 'index.html' : rawPath.replaceFirst(RegExp(r'^/+'), '');

    File file;
    final runtimeName = path.startsWith('runtime/')
        ? path.substring('runtime/'.length)
        : '';
    final isRuntimeAsset = runtimeName == 'algorithms.json' ||
        RegExp(r'^algorithm_worker\.[0-9]+\.js$').hasMatch(runtimeName);
    if (isRuntimeAsset) {
      file = File('${runtime.path}${Platform.pathSeparator}$runtimeName');
      request.response.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-store, no-cache, must-revalidate')
        ..set(HttpHeaders.pragmaHeader, 'no-cache');
    } else {
      final safe = _safeRelative(path);
      file = File('${build.path}${Platform.pathSeparator}$safe');
      if (!file.existsSync()) {
        // Flutter is a single-page application; unknown routes return index.html.
        file = File('${build.path}${Platform.pathSeparator}index.html');
      }
    }

    if (!file.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not found: $path');
      await request.response.close();
      return;
    }

    request.response.headers.contentType = _contentType(file.path);
    final stat = file.statSync();
    request.response.contentLength = stat.size;
    if (request.method == 'GET') {
      await request.response.addStream(file.openRead());
    }
    await request.response.close();
  } catch (error, stack) {
    stderr.writeln('Request failed: $error\n$stack');
    try {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    } catch (_) {}
  }
}

String _safeRelative(String input) {
  final parts = <String>[];
  for (final part in input.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      throw const FormatException('Parent traversal is not allowed');
    }
    parts.add(part);
  }
  return parts.join(Platform.pathSeparator);
}

ContentType _contentType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.html')) return ContentType.html;
  if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
    return ContentType('application', 'javascript', charset: 'utf-8');
  }
  if (lower.endsWith('.json')) return ContentType.json;
  if (lower.endsWith('.css')) return ContentType('text', 'css', charset: 'utf-8');
  if (lower.endsWith('.svg')) return ContentType('image', 'svg+xml');
  if (lower.endsWith('.png')) return ContentType('image', 'png');
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return ContentType('image', 'jpeg');
  if (lower.endsWith('.webp')) return ContentType('image', 'webp');
  if (lower.endsWith('.wasm')) return ContentType('application', 'wasm');
  if (lower.endsWith('.woff2')) return ContentType('font', 'woff2');
  if (lower.endsWith('.ico')) return ContentType('image', 'x-icon');
  return ContentType.binary;
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
    // The URL is already printed; absence of a desktop opener is harmless.
  }
}

String? _value(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}
