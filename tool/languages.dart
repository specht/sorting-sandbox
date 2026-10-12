// The languages students may write their algorithms in.
//
// A file's extension is its language: alice/quick_sort.dart and
// bob/quick_sort.py live side by side in the class repository and race each
// other in the same browser. There is no setting for the class; each student
// chooses per file (see ./new-algorithm).
//
// Dart needs nothing but the SDK that runs the host. Every other language
// needs its interpreter or compiler on the PATH; when it is missing, only the
// files of that language show an explanation, everything else keeps working.
import 'dart:io';

import 'instrument_client.dart' show InstrumenterUnavailable;

class Language {
  const Language._({
    required this.id,
    required this.label,
    required this.extension,
    required this.timeoutFactor,
  });

  static const dart = Language._(
    id: 'dart',
    label: 'Dart',
    extension: '.dart',
    timeoutFactor: 1,
  );

  /// Interpreted, so Check and Analyze get more time for the same inputs
  /// (the operation counts themselves do not depend on the speed).
  static const python = Language._(
    id: 'python',
    label: 'Python',
    extension: '.py',
    timeoutFactor: 3,
  );

  static const all = [dart, python];

  /// 'dart', 'python', … (also used by the browser and in .settings.yaml).
  final String id;
  final String label;

  /// Including the dot.
  final String extension;

  /// Multiplies the hard time limits of Check and Analyze.
  final int timeoutFactor;

  static Language? forPath(String path) {
    for (final language in all) {
      if (path.endsWith(language.extension)) return language;
    }
    return null;
  }

  static Language? byId(String id) {
    for (final language in all) {
      if (language.id == id) return language;
    }
    return null;
  }

  Duration scaled(Duration limit) => limit * timeoutFactor;

  @override
  String toString() => id;
}

/// The language's interpreter or compiler is not installed. Not the
/// student's fault; the message says what to install.
class ToolchainMissing extends InstrumenterUnavailable {
  ToolchainMissing(super.message);
}

/// Finds a Python 3.10+ interpreter once per host process.
///
/// Order: $SANDBOX_PYTHON (a path or command), `python3`, `python`, and on
/// Windows the `py -3` launcher.
class PythonToolchain {
  static const minimum = (3, 10);
  static const scriptsDirectory = 'languages/python';

  Future<List<String>>? _command;

  /// The command prefix that starts Python, e.g. `[python3]` or `[py, -3]`.
  /// Throws [ToolchainMissing].
  Future<List<String>> command() => _command ??= _find();

  Future<List<String>> _find() async {
    final configured = Platform.environment['SANDBOX_PYTHON'];
    final candidates = <List<String>>[
      if (configured != null && configured.trim().isNotEmpty) [configured.trim()],
      ['python3'],
      ['python'],
      if (Platform.isWindows) ['py', '-3'],
    ];
    final found = <String>[];
    for (final candidate in candidates) {
      try {
        final result = await Process.run(candidate.first, [
          ...candidate.skip(1),
          '-c',
          'import sys; print("%d.%d" % sys.version_info[:2])',
        ]).timeout(const Duration(seconds: 15));
        if (result.exitCode != 0) continue;
        final version = result.stdout.toString().trim();
        final parts = version.split('.').map(int.tryParse).toList();
        if (parts.length != 2 || parts.contains(null)) continue;
        final (major, minor) = (parts[0]!, parts[1]!);
        if (major > minimum.$1 || (major == minimum.$1 && minor >= minimum.$2)) {
          stdout.writeln('[python] Using ${candidate.join(' ')} (Python $version)');
          return candidate;
        }
        found.add('${candidate.join(' ')} is Python $version');
      } catch (_) {
        // Not installed under this name.
      }
    }
    final detail = found.isEmpty ? '' : ' (${found.join('; ')})';
    throw ToolchainMissing(
      'Python ${minimum.$1}.${minimum.$2} or newer is needed for .py algorithms '
      'but was not found$detail. Install Python 3 and restart ./run, or set '
      'SANDBOX_PYTHON to the interpreter.',
    );
  }

  /// `python3 -I -B languages/python/SCRIPT ARGS…`: isolated mode ignores
  /// PYTHON* variables, the user's site-packages and the current directory.
  Future<List<String>> script(String name, [List<String> arguments = const []]) async => [
        ...await command(),
        '-I',
        '-B',
        File('$scriptsDirectory/$name').absolute.path,
        ...arguments,
      ];
}

final pythonToolchain = PythonToolchain();
