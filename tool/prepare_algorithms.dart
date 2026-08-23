import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'instrumenter.dart';
import 'model.dart';

Future<void> main(List<String> args) async {
  final repoArg = _value(args, '--repo');
  if (repoArg == null) {
    stderr.writeln(
      'Usage: dart run tool/prepare_algorithms.dart --repo PATH '
      '[--compile-worker] [--no-pub-get]',
    );
    exitCode = 64;
    return;
  }

  final compileWorker = !args.contains('--no-compile-worker');
  final root = Directory.current.absolute;
  final repo = Directory(repoArg).absolute;
  if (!repo.existsSync()) {
    stderr.writeln('Algorithm repository not found: ${repo.path}');
    exitCode = 66;
    return;
  }

  if (!args.contains('--no-pub-get') &&
      File('${repo.path}/pubspec.yaml').existsSync()) {
    stdout.writeln('Resolving algorithm repository dependencies…');
    final get = await Process.run(
      Platform.resolvedExecutable,
      ['pub', 'get'],
      workingDirectory: repo.path,
    );
    stdout.write(get.stdout);
    stderr.write(get.stderr);
    if (get.exitCode != 0) {
      stderr.writeln('dart pub get failed in ${repo.path}');
      exitCode = get.exitCode;
      return;
    }
  }

  final stage = Directory('${root.path}/worker/generated_next');
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);

  final definitions = <AlgorithmDefinition>[];
  final diagnostics = <AlgorithmDiagnostic>[];
  final candidates = repo
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !_isHiddenRelative(repo, f))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final instrumenter = VisualInstrumenter();

  for (final file in candidates) {
    final relative = _relative(repo.path, file.path);
    final segments = relative.split(Platform.pathSeparator);
    if (segments.length < 2) {
      diagnostics.add(
        AlgorithmDiagnostic(
          path: relative,
          author: '',
          message: 'Algorithm files must live in a student subdirectory.',
        ),
      );
      continue;
    }

    final author = segments.first;
    final source = file.readAsStringSync();
    final definitionOrError = _extractDefinition(
      source: source,
      path: file.path,
      relativePath: relative,
      author: author,
    );
    if (definitionOrError.error != null) {
      diagnostics.add(
        AlgorithmDiagnostic(
          path: relative,
          author: author,
          message: definitionOrError.error!,
        ),
      );
      continue;
    }
    final definition = definitionOrError.definition!;

    final semanticErrors = await _analyzeFile(file, repo);
    if (semanticErrors.isNotEmpty) {
      diagnostics.add(
        AlgorithmDiagnostic(
          path: relative,
          author: author,
          message: semanticErrors.join('\n'),
        ),
      );
      continue;
    }

    final visual = instrumenter.instrument(source, path: file.path);
    if (visual.errors.isNotEmpty) {
      diagnostics.add(
        AlgorithmDiagnostic(
          path: relative,
          author: author,
          message: 'Could not instrument algorithm:\n${visual.errors.join('\n')}',
        ),
      );
      continue;
    }

    final safe = _safeId(definition.id);
    final benchmarkPath = '${stage.path}/${safe}_benchmark.dart';
    final visualPath = '${stage.path}/${safe}_visual.dart';
    File(benchmarkPath).writeAsStringSync(source);
    File(visualPath).writeAsStringSync(visual.source);

    final transformedErrors = await _analyzeGenerated(File(visualPath), root);
    if (transformedErrors.isNotEmpty) {
      File(benchmarkPath).deleteSync();
      File(visualPath).deleteSync();
      diagnostics.add(
        AlgorithmDiagnostic(
          path: relative,
          author: author,
          message:
              'The visual instrumentation could not safely transform this file. '
              'The original file is untouched.\n${transformedErrors.join('\n')}',
        ),
      );
      continue;
    }

    definitions.add(definition);
    stdout.writeln('✓ ${definition.author} / ${definition.name}');
  }

  _writeRegistry(stage, definitions);
  final format = await Process.run(
    Platform.resolvedExecutable,
    ['format', stage.path],
    workingDirectory: root.path,
  );
  if (format.exitCode != 0) {
    stdout.write(format.stdout);
    stderr.write(format.stderr);
    stage.deleteSync(recursive: true);
    exitCode = format.exitCode;
    return;
  }

  final buildId = DateTime.now().toUtc().microsecondsSinceEpoch.toString();

  if (compileWorker) {
    stdout.writeln('Compiling disposable web worker…');
    final temporaryMain = File('${root.path}/worker/main_next.dart');
    final mainSource = File('${root.path}/worker/main.dart').readAsStringSync();
    temporaryMain.writeAsStringSync(
      mainSource.replaceFirst(
        "import 'generated/registry.g.dart';",
        "import 'generated_next/registry.g.dart';",
      ),
    );

    final workerName = 'algorithm_worker.$buildId.js';
    final nextWorker = File('${root.path}/runtime/$workerName.next');
    if (nextWorker.existsSync()) nextWorker.deleteSync();
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'compile',
        'js',
        '--no-source-maps',
        '-O2',
        'worker/main_next.dart',
        '-o',
        'runtime/$workerName.next',
      ],
      workingDirectory: root.path,
    );
    temporaryMain.deleteSync();
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0 || !nextWorker.existsSync()) {
      stage.deleteSync(recursive: true);
      if (nextWorker.existsSync()) nextWorker.deleteSync();
      stderr.writeln('Worker compilation failed; the last successful build remains active.');
      exitCode = result.exitCode == 0 ? 1 : result.exitCode;
      return;
    }

    _replaceFile(
      nextWorker,
      File('${root.path}/runtime/$workerName'),
    );
  }

  _replaceDirectory(stage, Directory('${root.path}/worker/generated'));
  if (compileWorker) {
    final workerPath = 'algorithm_worker.$buildId.js';
    _writeManifest(root, buildId, workerPath, definitions, diagnostics);
    _cleanupOldWorkers(root, keep: 8);
  }

  stdout.writeln(
    'Prepared ${definitions.length} algorithm(s); '
    '${diagnostics.length} file(s) skipped. Build $buildId.',
  );
}

String? _value(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

bool _isHiddenRelative(Directory repo, File file) {
  final relative = _relative(repo.path, file.path);
  return relative
      .split(Platform.pathSeparator)
      .any((part) => part.startsWith('.'));
}

Future<List<String>> _analyzeFile(File file, Directory repo) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['analyze', '--format=machine', file.path],
    workingDirectory: repo.path,
  );
  return _machineErrors('${result.stdout}\n${result.stderr}');
}

Future<List<String>> _analyzeGenerated(File file, Directory root) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['analyze', '--format=machine', file.path],
    workingDirectory: root.path,
  );
  return _machineErrors('${result.stdout}\n${result.stderr}');
}

List<String> _machineErrors(String output) => output
    .split('\n')
    .where((line) => line.startsWith('ERROR|'))
    .map((line) {
      final fields = line.split('|');
      if (fields.length >= 8) return fields.skip(7).join('|').trim();
      return line.trim();
    })
    .where((line) => line.isNotEmpty)
    .toList();

_DefinitionResult _extractDefinition({
  required String source,
  required String path,
  required String relativePath,
  required String author,
}) {
  final parsed = parseString(
    content: source,
    path: path,
    throwIfDiagnostics: false,
  );
  if (parsed.errors.isNotEmpty) {
    return _DefinitionResult.error(
      parsed.errors.map((e) => e.toString()).join('\n'),
    );
  }

  ClassDeclaration? algorithmClass;
  for (final declaration in parsed.unit.declarations.whereType<ClassDeclaration>()) {
    if (declaration.extendsClause?.superclass.toSource() == 'SortingAlgorithm') {
      if (algorithmClass != null) {
        return _DefinitionResult.error(
          'One file must contain exactly one SortingAlgorithm subclass.',
        );
      }
      algorithmClass = declaration;
    }
  }
  if (algorithmClass == null) {
    return _DefinitionResult.error('No class extending SortingAlgorithm found.');
  }

  String? name;
  String? color;
  MethodDeclaration? sortMethod;
  for (final member in algorithmClass.body.members.whereType<MethodDeclaration>()) {
    if (member.name.lexeme == 'sort' && !member.isGetter) sortMethod = member;
    if (member.isGetter && member.name.lexeme == 'name') {
      name = _literalGetter(member);
    }
    if (member.isGetter && member.name.lexeme == 'color') {
      color = _colorGetter(member);
    }
  }

  if (sortMethod == null) {
    return _DefinitionResult.error(
      'Missing sort(Elements list, Elements scratch).',
    );
  }
  final sortParameters = sortMethod.parameters;
  final parameterSource = sortParameters?.toSource() ?? '';
  if (sortParameters == null ||
      sortParameters.parameters.length != 2 ||
      parameterSource.contains('{') ||
      parameterSource.contains('[')) {
    return _DefinitionResult.error(
      'sort must take exactly two positional parameters: '
      'sort(Elements list, Elements scratch).',
    );
  }
  if (sortMethod.body.keyword != null) {
    return _DefinitionResult.error(
      'sort must stay synchronous; do not add async, sync*, or async*.',
    );
  }
  if (name == null || name.trim().isEmpty) {
    return _DefinitionResult.error(
      "Use a literal name getter, e.g. get name => 'Bubble Sort';",
    );
  }
  if (color == null || !_validColor(color)) {
    return _DefinitionResult.error(
      "Use Colors.green or a hex color such as get color => '#4CAF50';",
    );
  }

  final normalizedRelative = relativePath.replaceAll(Platform.pathSeparator, '/');
  final stem = normalizedRelative.substring(0, normalizedRelative.length - 5);
  return _DefinitionResult.ok(
    AlgorithmDefinition(
      id: stem,
      author: author,
      name: name,
      color: color,
      className: _className(algorithmClass),
      path: normalizedRelative,
      source: source,
    ),
  );
}

String _className(ClassDeclaration declaration) {
  // Primary constructors are not part of the classroom API. Reading the first
  // identifier from namePart keeps this compatible with both ordinary class
  // declarations and future grammar additions without exposing either to
  // students.
  final text = declaration.namePart.toSource();
  final match = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*').firstMatch(text);
  return match?.group(0) ?? text;
}

String? _colorGetter(MethodDeclaration method) {
  final body = method.body;
  Expression? expression;
  if (body is ExpressionFunctionBody) {
    expression = body.expression;
  } else if (body is BlockFunctionBody) {
    for (final statement in body.block.statements) {
      if (statement is ReturnStatement) {
        expression = statement.expression;
        break;
      }
    }
  }
  if (expression is StringLiteral) return expression.stringValue;
  if (expression is PrefixedIdentifier && expression.prefix.name == 'Colors') {
    return _palette[expression.identifier.name];
  }
  return null;
}

const _palette = <String, String>{
  'red': '#F44336',
  'pink': '#E91E63',
  'purple': '#9C27B0',
  'deepPurple': '#673AB7',
  'indigo': '#3F51B5',
  'blue': '#2196F3',
  'lightBlue': '#03A9F4',
  'cyan': '#00BCD4',
  'teal': '#009688',
  'green': '#4CAF50',
  'lightGreen': '#8BC34A',
  'lime': '#CDDC39',
  'yellow': '#FFEB3B',
  'amber': '#FFC107',
  'orange': '#FF9800',
  'deepOrange': '#FF5722',
  'brown': '#795548',
  'blueGrey': '#607D8B',
};

String? _literalGetter(MethodDeclaration method) {
  final body = method.body;
  if (body is ExpressionFunctionBody && body.expression is StringLiteral) {
    return (body.expression as StringLiteral).stringValue;
  }
  if (body is BlockFunctionBody) {
    for (final statement in body.block.statements) {
      if (statement is ReturnStatement &&
          statement.expression is StringLiteral) {
        return (statement.expression as StringLiteral).stringValue;
      }
    }
  }
  return null;
}

bool _validColor(String value) =>
    RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value);

void _writeRegistry(
  Directory generated,
  List<AlgorithmDefinition> definitions,
) {
  final out = StringBuffer()
    ..writeln('// Generated by tool/prepare_algorithms.dart. Do not edit.')
    ..writeln("import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';");

  for (var i = 0; i < definitions.length; i++) {
    final safe = _safeId(definitions[i].id);
    out.writeln("import '${safe}_visual.dart' as v$i;");
    out.writeln("import '${safe}_benchmark.dart' as b$i;");
  }

  out
    ..writeln()
    ..writeln('SortingAlgorithm createVisualAlgorithm(String id) {')
    ..writeln('  switch (id) {');
  for (var i = 0; i < definitions.length; i++) {
    out.writeln(
      "    case '${_escape(definitions[i].id)}': "
      'return v$i.${definitions[i].className}();',
    );
  }
  out
    ..writeln("    default: throw StateError('Unknown algorithm: \$id');")
    ..writeln('  }')
    ..writeln('}')
    ..writeln()
    ..writeln('SortingAlgorithm createBenchmarkAlgorithm(String id) {')
    ..writeln('  switch (id) {');
  for (var i = 0; i < definitions.length; i++) {
    out.writeln(
      "    case '${_escape(definitions[i].id)}': "
      'return b$i.${definitions[i].className}();',
    );
  }
  out
    ..writeln("    default: throw StateError('Unknown algorithm: \$id');")
    ..writeln('  }')
    ..writeln('}');

  File('${generated.path}/registry.g.dart').writeAsStringSync(out.toString());
}

void _writeManifest(
  Directory root,
  String buildId,
  String workerPath,
  List<AlgorithmDefinition> definitions,
  List<AlgorithmDiagnostic> diagnostics,
) {
  final manifest = {
    'buildId': buildId,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'workerPath': workerPath,
    'algorithms': definitions.map((e) => e.toJson()).toList(),
    'diagnostics': diagnostics.map((e) => e.toJson()).toList(),
  };
  final next = File('${root.path}/runtime/algorithms.json.next');
  next.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  _replaceFile(next, File('${root.path}/runtime/algorithms.json'));
}

void _cleanupOldWorkers(Directory root, {required int keep}) {
  final runtime = Directory('${root.path}/runtime');
  if (!runtime.existsSync()) return;
  final files = runtime
      .listSync()
      .whereType<File>()
      .where((file) => RegExp(r'algorithm_worker\.\d+\.js$').hasMatch(file.path))
      .toList()
    ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  for (final file in files.skip(keep)) {
    try {
      file.deleteSync();
    } catch (_) {}
  }
}


void _replaceFile(File source, File destination) {
  destination.parent.createSync(recursive: true);
  if (destination.existsSync()) destination.deleteSync();
  source.renameSync(destination.path);
}

void _replaceDirectory(Directory source, Directory destination) {
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  source.renameSync(destination.path);
}

String _relative(String root, String path) {
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}

String _safeId(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
String _escape(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

class _DefinitionResult {
  _DefinitionResult.ok(this.definition) : error = null;
  _DefinitionResult.error(this.error) : definition = null;

  final AlgorithmDefinition? definition;
  final String? error;
}
