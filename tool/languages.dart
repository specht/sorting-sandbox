// The languages students may write their algorithms in.
//
// A file's extension is its language: alice/quick_sort.dart and
// bob/quick_sort.py live side by side in the class repository and race each
// other in the same browser. There is no setting for the class; each student
// chooses per file (see ./new-algorithm).
//
// Dart needs nothing but the SDK that runs the host. Every other language
// needs its interpreter or compiler on the PATH (Python 3.10+, Node.js 18+,
// JDK 17+); when it is missing, only the files of that language show an
// explanation, everything else keeps working.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

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

  /// Uses a Proxy for `list[i]`, so it is somewhat slower than Dart.
  static const javascript = Language._(
    id: 'javascript',
    label: 'JavaScript',
    extension: '.js',
    timeoutFactor: 2,
  );

  /// Fast once running; the factor covers starting the JVM on slow machines.
  static const java = Language._(
    id: 'java',
    label: 'Java',
    extension: '.java',
    timeoutFactor: 2,
  );

  static const all = [dart, python, javascript, java];

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

/// The Dart SDK, for .dart files: compiling workers, the analyzer daemon,
/// `dart format`.
///
/// Under `dart run` (./run with a Dart SDK) this is the running `dart`, as it
/// always was. The precompiled host (./run without a Dart SDK, for schools
/// that only teach Python, JavaScript or Java) looks for $SANDBOX_DART or
/// `dart` on the PATH; without one, only .dart files show an explanation.
class DartToolchain {
  /// True in a host compiled with `dart compile exe`.
  static const precompiled = bool.fromEnvironment('dart.vm.product');

  Future<String>? _executable;

  /// Throws [ToolchainMissing].
  Future<String> executable() => _executable ??= _find();

  /// Whether .dart files can be built (never throws).
  Future<bool> available() async {
    try {
      await executable();
      return true;
    } on ToolchainMissing {
      return false;
    }
  }

  Future<String> _find() async {
    if (!precompiled) return Platform.resolvedExecutable;
    final configured = Platform.environment['SANDBOX_DART'];
    for (final candidate in [
      if (configured != null && configured.trim().isNotEmpty) configured.trim(),
      'dart',
    ]) {
      final output = await _probe([candidate], ['--version']);
      if (output != null && output.contains('Dart SDK')) {
        stdout.writeln('[dart] Using $candidate');
        return candidate;
      }
    }
    throw ToolchainMissing(
      'The Dart SDK is needed for .dart files but was not found. Install Dart '
      '(https://dart.dev/get-dart) and restart ./run, or set SANDBOX_DART.',
    );
  }
}

final dartToolchain = DartToolchain();

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

/// Runs `COMMAND ARGUMENTS` and returns stdout and stderr, or null when the
/// command does not exist or fails.
Future<String?> _probe(List<String> command, List<String> arguments) async {
  try {
    final result = await Process.run(command.first, [...command.skip(1), ...arguments])
        .timeout(const Duration(seconds: 15));
    if (result.exitCode != 0) return null;
    return '${result.stdout}\n${result.stderr}';
  } catch (_) {
    return null;
  }
}

/// Finds Node.js 18+ once per host process: $SANDBOX_NODE, `node`, `nodejs`.
class NodeToolchain {
  static const minimum = 18;
  static const scriptsDirectory = 'languages/javascript';

  Future<List<String>>? _command;

  Future<List<String>> command() => _command ??= _find();

  Future<List<String>> _find() async {
    final configured = Platform.environment['SANDBOX_NODE'];
    final candidates = <List<String>>[
      if (configured != null && configured.trim().isNotEmpty) [configured.trim()],
      ['node'],
      if (!Platform.isWindows) ['nodejs'],
    ];
    final found = <String>[];
    for (final candidate in candidates) {
      final output = await _probe(candidate, ['--version']);
      final match = output == null ? null : RegExp(r'v(\d+)\.\d+\.\d+').firstMatch(output);
      if (match == null) continue;
      if (int.parse(match.group(1)!) >= minimum) {
        stdout.writeln('[javascript] Using ${candidate.join(' ')} (Node ${match.group(0)})');
        return candidate;
      }
      found.add('${candidate.join(' ')} is Node ${match.group(0)}');
    }
    final detail = found.isEmpty ? '' : ' (${found.join('; ')})';
    throw ToolchainMissing(
      'Node.js $minimum or newer is needed for .js algorithms but was not '
      'found$detail. Install Node.js and restart ./run, or set SANDBOX_NODE to '
      'the node executable.',
    );
  }

  /// `node languages/javascript/SCRIPT ARGS…`
  Future<List<String>> script(String name, [List<String> arguments = const []]) async => [
        ...await command(),
        File('$scriptsDirectory/$name').absolute.path,
        ...arguments,
      ];
}

final nodeToolchain = NodeToolchain();

/// Finds a JDK 17+ (javac and java) once per host process and compiles the
/// Java sandbox runtime (languages/java/src) with it.
///
/// Order: $SANDBOX_JAVA_HOME/bin, $JAVA_HOME/bin, then `javac` on the PATH.
class JavaToolchain {
  static const minimum = 17;
  static const sourceDirectory = 'languages/java/src';

  /// The daemon uses the newest one this JDK can run: 1.35.0 needs JDK 21+,
  /// 1.28.0 is the newest that formats on JDK 17 to 20 (vendor/java/README.md).
  static const formatterJars = [
    'vendor/java/google-java-format-1.35.0-all-deps.jar',
    'vendor/java/google-java-format-1.28.0-all-deps.jar',
  ];

  /// google-java-format uses the JDK's compiler internals.
  static const formatterExports = [
    '--add-exports=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED',
    '--add-exports=jdk.compiler/com.sun.tools.javac.code=ALL-UNNAMED',
    '--add-exports=jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED',
    '--add-exports=jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED',
    '--add-exports=jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED',
    '--add-exports=jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED',
  ];

  Future<({String java, String javac, String version})>? _tools;
  Future<String>? _runtime;

  Future<({String java, String javac, String version})> tools() => _tools ??= _find();

  Future<({String java, String javac, String version})> _find() async {
    String executable(String bin, String name) => bin.isEmpty
        ? name
        : '$bin${Platform.pathSeparator}$name${Platform.isWindows ? '.exe' : ''}';
    final directories = <String>[
      for (final variable in ['SANDBOX_JAVA_HOME', 'JAVA_HOME'])
        if ((Platform.environment[variable] ?? '').trim().isNotEmpty)
          '${Platform.environment[variable]!.trim()}${Platform.pathSeparator}bin',
      '',
    ];
    final found = <String>[];
    for (final bin in directories) {
      final javac = executable(bin, 'javac');
      final output = await _probe([javac], ['-version']);
      final match = output == null ? null : RegExp(r'javac (\d+)(?:\.(\d+))?').firstMatch(output);
      if (match == null) continue;
      var major = int.parse(match.group(1)!);
      if (major == 1) major = int.tryParse(match.group(2) ?? '') ?? 0; // javac 1.8
      if (major >= minimum) {
        stdout.writeln('[java] Using $javac (${match.group(0)})');
        return (java: executable(bin, 'java'), javac: javac, version: match.group(0)!);
      }
      found.add('$javac is ${match.group(0)}');
    }
    final detail = found.isEmpty ? '' : ' (${found.join('; ')})';
    throw ToolchainMissing(
      'A Java Development Kit (JDK) $minimum or newer is needed for .java '
      'algorithms but javac was not found$detail. Install a JDK and restart '
      './run, or set SANDBOX_JAVA_HOME.',
    );
  }

  /// The compiled runtime (student API, worker, daemon), built once per
  /// version of its sources and of the JDK under runtime/java/.
  Future<String> runtimeClasses() => _runtime ??= _buildRuntime();

  Future<String> _buildRuntime() async {
    final tools = await this.tools();
    final sources = Directory(sourceDirectory)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.java'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final data = BytesBuilder(copy: false)..add(utf8.encode('${tools.version}\u0000'));
    for (final file in sources) {
      data
        ..add(utf8.encode('${file.path}\u0000'))
        ..add(file.readAsBytesSync())
        ..addByte(0);
    }
    final hash = sha256.convert(data.takeBytes()).toString().substring(0, 24);
    final directory = Directory('runtime/java/$hash');
    final classes = Directory('${directory.path}/classes');
    final complete = File('${directory.path}/complete');
    if (complete.existsSync()) return classes.absolute.path;
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    classes.createSync(recursive: true);
    final result = await Process.run(tools.javac, [
      '--release',
      '$minimum',
      '-encoding',
      'UTF-8',
      '-nowarn',
      '-d',
      classes.path,
      for (final file in sources) file.path,
    ]);
    if (result.exitCode != 0) {
      _runtime = null;
      throw InstrumenterUnavailable(
          'The Java sandbox runtime could not be compiled:\n${result.stdout}${result.stderr}');
    }
    complete.writeAsStringSync(tools.version);
    return classes.absolute.path;
  }

  /// The checks, the compiler and the formatter (__sandbox.Daemon).
  Future<List<String>> daemon() async {
    final tools = await this.tools();
    final classes = await runtimeClasses();
    return [
      tools.java,
      ...formatterExports,
      '-XX:+UseSerialGC',
      '-cp',
      classes,
      '__sandbox.Daemon',
      classes,
      for (final jar in formatterJars) File(jar).absolute.path,
    ];
  }

  /// One worker for the classes the daemon compiled into [directory].
  Future<List<String>> worker(String directory, String className) async {
    final tools = await this.tools();
    final classes = await runtimeClasses();
    return [
      tools.java,
      '-XX:+UseSerialGC',
      '-Xshare:auto',
      '-cp',
      classes,
      '__sandbox.Worker',
      directory,
      className,
    ];
  }
}

final javaToolchain = JavaToolchain();
