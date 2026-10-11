// Keeps the Dart parser loaded between edits: one JSON request and one JSON
// reply per line. This process never executes student code; algorithms run
// in separate, killable worker processes.
//
// Requests:
//   {"id": 1, "op": "inspect",    "path": "...", "content": "..."}
//   {"id": 2, "op": "instrument", "path": "...", "content": "...", "out": "DIR"}
// Replies:
//   {"id": 1, "ok": true, "meta": {...}, "diagnostics": []}
//   {"id": 2, "ok": false, "diagnostics": [{line, column, length, message}]}
import 'dart:convert';
import 'dart:io';

import 'inspect.dart';
import 'instrumenter.dart';

Future<void> main() async {
  stdout.writeln(jsonEncode({'type': 'ready', 'pid': pid}));
  final instrumenter = VisualInstrumenter();
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    Object? id;
    try {
      final request = jsonDecode(line);
      if (request is! Map<String, dynamic> ||
          request['id'] is! int ||
          request['op'] is! String ||
          request['path'] is! String ||
          request['content'] is! String) {
        throw const FormatException('Invalid instrumentation request.');
      }
      id = request['id'];
      final path = request['path'] as String;
      final content = request['content'] as String;
      final inspected = inspectAlgorithm(content, path: path);
      if (!inspected.ok || request['op'] == 'inspect') {
        stdout.writeln(jsonEncode({'id': id, ...inspected.toJson()}));
        continue;
      }
      if (request['op'] != 'instrument' || request['out'] is! String) {
        throw const FormatException('Unknown instrumentation operation.');
      }
      final visual = instrumenter.instrument(content, path: path);
      if (visual.errors.isNotEmpty) {
        stdout.writeln(jsonEncode({
          'id': id,
          'ok': false,
          'error': 'The visual instrumentation could not transform this file:\n'
              '${visual.errors.join('\n')}',
          'diagnostics': const [],
        }));
        continue;
      }
      final out = Directory(request['out'] as String)..createSync(recursive: true);
      File('${out.path}/visual.dart').writeAsStringSync(visual.source);
      stdout.writeln(jsonEncode({'id': id, ...inspected.toJson()}));
    } catch (error) {
      stdout.writeln(jsonEncode({'id': id, 'ok': false, 'error': '$error'}));
    }
  }
}
