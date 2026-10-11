import 'dart:convert';
import 'dart:io';

/// Local settings of this installation (for now: the theme). They live in
/// .settings.yaml next to the app, which Git ignores, so they never end up in
/// the app's repository or in the class repository. Only simple
/// `key: value` lines are read; other lines are kept as they are.
const settingsPath = '.settings.yaml';
const themes = {'dark', 'light'};

Map<String, String> readSettings([String path = settingsPath]) {
  var theme = 'dark';
  final file = File(path);
  if (file.existsSync()) {
    final pattern = RegExp(r'''^\s*theme\s*:\s*["']?(\w+)["']?\s*(#.*)?$''');
    for (final line in file.readAsLinesSync()) {
      final value = pattern.firstMatch(line)?.group(1);
      if (value != null && themes.contains(value)) theme = value;
    }
  }
  return {'theme': theme};
}

void writeSettings(Map<String, String> changes, [String path = settingsPath]) {
  final file = File(path);
  final lines = file.existsSync()
      ? [...file.readAsLinesSync()]
      : <String>['# Local settings of this sandbox. Not part of Git.'];
  changes.forEach((key, value) {
    final pattern = RegExp('^\\s*${RegExp.escape(key)}\\s*:');
    final at = lines.indexWhere(pattern.hasMatch);
    if (at < 0) {
      lines.add('$key: $value');
    } else {
      lines[at] = '$key: $value';
    }
  });
  file.writeAsStringSync('${lines.join('\n')}\n');
}

/// GET /api/settings returns {"theme": …}; PUT with {"theme": "dark"|"light"}
/// stores it. Writes are accepted from the page itself only.
Future<void> handleSettings(HttpRequest request) async {
  final response = request.response;
  response.headers
    ..contentType = ContentType.json
    ..set(HttpHeaders.cacheControlHeader, 'no-store');
  try {
    if (request.method == 'PUT') {
      final origin = request.headers.value('origin');
      final host = request.headers.value(HttpHeaders.hostHeader);
      if (origin != null && origin != 'http://$host') {
        response.statusCode = HttpStatus.forbidden;
        response.write(jsonEncode({'error': 'Cross-origin writes are not allowed'}));
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      Object? input;
      try {
        input = body.length <= 4096 ? jsonDecode(body) : null;
      } on FormatException {
        input = null;
      }
      final theme = input is Map ? input['theme'] : null;
      if (theme is! String || !themes.contains(theme)) {
        response.statusCode = HttpStatus.badRequest;
        response.write(jsonEncode({'error': 'theme must be dark or light'}));
        return;
      }
      writeSettings({'theme': theme});
    } else if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }
    response.write(jsonEncode(readSettings()));
  } finally {
    await response.close();
  }
}

/// The page with the stored theme, so it never flashes the wrong colors.
String themedPage(String html) => html.replaceFirst(
    '<html lang="en">', '<html lang="en" data-theme="${readSettings()['theme']}">');
