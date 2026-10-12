// Browser editing of student files. Writes are limited to an existing,
// catalogued algorithm file; the browser never supplies a path.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'catalog.dart';

File editableSource(AlgorithmFile algorithm, String repoPath) {
  final file = File(algorithm.path);
  final directory = file.parent;
  // A symbolic link must not turn a catalogued file into an arbitrary write.
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const FormatException('The selected source is not a regular file.');
  }
  final root = Directory(repoPath).absolute.path;
  if (!file.absolute.path.startsWith(root)) {
    throw const FormatException('The selected source is outside the class repository.');
  }
  return file;
}

Map<String, Object?> readEditableSource(AlgorithmFile algorithm, String repoPath) {
  final file = editableSource(algorithm, repoPath);
  final bytes = file.readAsBytesSync();
  if (bytes.length > maxSourceBytes) {
    throw const FormatException('This file is too large for the browser editor.');
  }
  return {
    'type': 'sourceFile',
    'id': algorithm.id,
    'path': algorithm.relativePath,
    'content': utf8.decode(bytes, allowMalformed: true),
    'revision': revisionOf(bytes),
  };
}

Map<String, Object?> saveEditableSource(
  AlgorithmFile algorithm,
  String repoPath,
  String baseRevision,
  String content,
) {
  final encoded = utf8.encode(content);
  if (encoded.length > maxSourceBytes || content.contains('\u0000')) {
    throw const FormatException('Source must be UTF-8 text smaller than 256 KiB.');
  }
  final file = editableSource(algorithm, repoPath);
  final current = file.readAsBytesSync();
  if (revisionOf(current) != baseRevision) {
    throw const FormatException(
      'The file changed since you started editing (another editor or git pull). '
      'Your draft was kept; review the latest version before saving.',
    );
  }
  if (utf8.decode(current, allowMalformed: true) != content) {
    file.writeAsBytesSync(encoded, flush: true);
  }
  return {
    'type': 'sourceSaved',
    'id': algorithm.id,
    'content': content,
    'revision': revisionOf(file.readAsBytesSync()),
  };
}

/// Rejects drafts that no formatter should see.
void checkDraftSize(String content) {
  if (utf8.encode(content).length > maxSourceBytes || content.contains('\u0000')) {
    throw const FormatException('Source must be UTF-8 text smaller than 256 KiB.');
  }
}

/// Formats a Dart editor draft through stdin. Never writes the student's
/// file. (Other languages are formatted by their daemon, see host.dart.)
Future<String> formatDraft(String sourcePath, String content) async {
  checkDraftSize(content);
  final process = await Process.start(Platform.resolvedExecutable,
      ['format', '--output=show', '--stdin-name=$sourcePath']);
  final formattedOutput = process.stdout.transform(utf8.decoder).join();
  final errorOutput = process.stderr.transform(utf8.decoder).join();
  try {
    process.stdin.write(content);
    await process.stdin.close();
    final status = await process.exitCode.timeout(const Duration(seconds: 10));
    final formatted = await formattedOutput;
    final errors = await errorOutput;
    if (status != 0) {
      throw FormatException(errors.trim().isNotEmpty
          ? errors.trim()
          : 'Dart could not format this draft. Check its syntax.');
    }
    return formatted;
  } on TimeoutException {
    process.kill();
    throw const FormatException('Formatting timed out. Your draft was not changed.');
  }
}
