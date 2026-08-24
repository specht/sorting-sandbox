import 'dart:convert';
import 'dart:io';

const int _fnvOffset = 0xcbf29ce484222325;
const int _fnvPrime = 0x100000001b3;
const int _mask64 = 0xffffffffffffffff;

String fingerprintStrings(Iterable<String> values) {
  var hash = _fnvOffset;

  void addBytes(Iterable<int> bytes) {
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * _fnvPrime) & _mask64;
    }
  }

  for (final value in values) {
    addBytes(utf8.encode(value));
    addBytes(const [0]);
  }

  return hash.toRadixString(16).padLeft(16, '0');
}

String fingerprintFiles(
  Directory root,
  Iterable<File> files, {
  Iterable<String> extra = const [],
}) {
  final ordered = files.where((file) => file.existsSync()).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final parts = <String>[];
  for (final file in ordered) {
    parts
      ..add(_displayPath(root.path, file.path))
      ..add(base64Encode(file.readAsBytesSync()));
  }
  parts.addAll(extra);
  return fingerprintStrings(parts);
}

List<File> filesUnder(
  Directory directory, {
  bool Function(File file)? include,
}) {
  if (!directory.existsSync()) return const [];
  final files = directory
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => include?.call(file) ?? true)
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

Map<String, dynamic>? readJsonMap(File file) {
  if (!file.existsSync()) return null;
  try {
    final value = jsonDecode(file.readAsStringSync());
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
  } catch (_) {}
  return null;
}

void writeJsonMapAtomic(File file, Map<String, Object?> value) {
  file.parent.createSync(recursive: true);
  final next = File('${file.path}.next');
  next.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(value));
  if (file.existsSync()) file.deleteSync();
  next.renameSync(file.path);
}

String _displayPath(String root, String path) {
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  final value = path.startsWith(prefix) ? path.substring(prefix.length) : path;
  return value.replaceAll(Platform.pathSeparator, '/');
}
