import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'cache_utils.dart';
import 'instrumenter.dart';
import 'model.dart';

Future<void> main(List<String> args) async {
  final repoArg = _value(args, '--repo');
  if (repoArg == null) {
    stderr.writeln(
      'Usage: dart run tool/build_algorithms.dart --repo PATH '
      '[--compile-worker] [--no-pub-get] [--force]',
    );
    exitCode = 64;
    return;
  }

  final compileWorker = !args.contains('--no-compile-worker');
  final force = args.contains('--force');
  final root = Directory.current.absolute;
  final repo = Directory(repoArg).absolute;
  if (!repo.existsSync()) {
    stderr.writeln('Algorithm repository not found: ${repo.path}');
    exitCode = 66;
    return;
  }

  final cacheRoot = Directory(
    '${root.path}/.dart_tool/sorting_sandbox',
  )..createSync(recursive: true);
  final stateFile = File('${cacheRoot.path}/worker_state.json');
  final previousState = readJsonMap(stateFile);
  var inputFingerprint = _inputFingerprint(root, repo);

  if (!force &&
      compileWorker &&
      previousState?['inputFingerprint'] == inputFingerprint &&
      _cachedRuntimeIsUsable(root, repo, previousState)) {
    stdout.writeln(
      'Algorithms unchanged — using cached worker '
      '${previousState!['workerPath']} ✓',
    );
    return;
  }

  if (!await _ensureDependencies(
    root: root,
    repo: repo,
    cacheRoot: cacheRoot,
    force: force,
    skip: args.contains('--no-pub-get'),
  )) {
    return;
  }
  // pub get may have updated pubspec.lock; persist the post-resolution key.
  inputFingerprint = _inputFingerprint(root, repo);

  final stage = Directory('${root.path}/worker/generated_next');
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);

  final definitions = <AlgorithmDefinition>[];
  final diagnostics = <AlgorithmDiagnostic>[];
  final candidates = repo
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .where((file) => !_isHiddenRelative(repo, file))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final instrumenter = VisualInstrumenter();
  final toolFingerprint = _toolFingerprint(root, repo);
  var cacheHits = 0;
  var checked = 0;

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
    final entryKey = fingerprintStrings([relative, source, toolFingerprint]);
    final entryDirectory = Directory(
      '${cacheRoot.path}/algorithms/${fingerprintStrings([relative])}',
    );
    final cached = force ? null : _readCachedAlgorithm(entryDirectory, entryKey);

    if (cached != null) {
      cacheHits++;
      if (cached.diagnostic != null) {
        diagnostics.add(cached.diagnostic!);
        stdout.writeln('↪ cached invalid: $relative');
      } else {
        final definition = cached.definition!;
        _copyCachedSources(entryDirectory, stage, definition);
        definitions.add(definition);
        stdout.writeln('↪ cached: ${definition.author} / ${definition.name}');
      }
      continue;
    }

    checked++;
    final definitionOrError = _extractDefinition(
      source: source,
      path: file.path,
      relativePath: relative,
      author: author,
    );
    if (definitionOrError.error != null) {
      final diagnostic = AlgorithmDiagnostic(
        path: relative,
        author: author,
        message: definitionOrError.error!,
      );
      diagnostics.add(diagnostic);
      _writeDiagnosticCache(entryDirectory, entryKey, diagnostic);
      continue;
    }
    final definition = definitionOrError.definition!;

    final semanticErrors = await _analyzeFile(file, repo);
    if (semanticErrors.isNotEmpty) {
      final diagnostic = AlgorithmDiagnostic(
        path: relative,
        author: author,
        message: semanticErrors.join('\n'),
      );
      diagnostics.add(diagnostic);
      _writeDiagnosticCache(entryDirectory, entryKey, diagnostic);
      continue;
    }

    final visual = instrumenter.instrument(source, path: file.path);
    if (visual.errors.isNotEmpty) {
      final diagnostic = AlgorithmDiagnostic(
        path: relative,
        author: author,
        message: 'Could not instrument algorithm:\n${visual.errors.join('\n')}',
      );
      diagnostics.add(diagnostic);
      _writeDiagnosticCache(entryDirectory, entryKey, diagnostic);
      continue;
    }

    final safe = _safeId(definition.id);
    final benchmarkFile = File('${stage.path}/${safe}_benchmark.dart')
      ..writeAsStringSync(source);
    final visualFile = File('${stage.path}/${safe}_visual.dart')
      ..writeAsStringSync(visual.source);

    final transformedErrors = await _analyzeGenerated(visualFile, root);
    if (transformedErrors.isNotEmpty) {
      benchmarkFile.deleteSync();
      visualFile.deleteSync();
      final diagnostic = AlgorithmDiagnostic(
        path: relative,
        author: author,
        message:
            'The visual instrumentation could not safely transform this file. '
            'The original file is untouched.\n${transformedErrors.join('\n')}',
      );
      diagnostics.add(diagnostic);
      _writeDiagnosticCache(entryDirectory, entryKey, diagnostic);
      continue;
    }

    _writeValidCache(
      entryDirectory,
      entryKey,
      definition,
      benchmarkFile,
      visualFile,
    );
    definitions.add(definition);
    stdout.writeln('✓ ${definition.author} / ${definition.name}');
  }

  _writeRegistry(stage, definitions);

  final buildId = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
  final compiledFingerprint = _compiledFingerprint(root, stage);
  String? workerPath = previousState?['workerPath']?.toString();
  final canReuseWorker = !force &&
      workerPath != null &&
      previousState?['compiledFingerprint'] == compiledFingerprint &&
      File('${root.path}/runtime/$workerPath').existsSync();

  if (compileWorker && canReuseWorker) {
    stdout.writeln('Compiled worker inputs unchanged — reusing $workerPath ✓');
  } else if (compileWorker) {
    workerPath = await _compileWorker(root, buildId);
    if (workerPath == null) {
      stage.deleteSync(recursive: true);
      exitCode = 1;
      return;
    }
  }

  _replaceDirectory(stage, Directory('${root.path}/worker/generated'));

  if (compileWorker) {
    _writeManifest(
      root,
      buildId,
      workerPath!,
      definitions,
      diagnostics,
    );
    writeJsonMapAtomic(stateFile, {
      'inputFingerprint': inputFingerprint,
      'compiledFingerprint': compiledFingerprint,
      'workerPath': workerPath,
      'buildId': buildId,
    });
    _cleanupOldWorkers(root, keep: 8);
  }

  stdout.writeln(
    'Prepared ${definitions.length} algorithm(s); '
    '${diagnostics.length} file(s) skipped; '
    '$cacheHits cached, $checked checked. Build $buildId.',
  );
}

Future<bool> _ensureDependencies({
  required Directory root,
  required Directory repo,
  required Directory cacheRoot,
  required bool force,
  required bool skip,
}) async {
  final pubspec = File('${repo.path}/pubspec.yaml');
  if (skip || !pubspec.existsSync()) return true;

  final lock = File('${repo.path}/pubspec.lock');
  final packageConfig = File('${repo.path}/.dart_tool/package_config.json');
  final dependencyState = File('${cacheRoot.path}/algorithm_dependencies.json');
  final fingerprint = fingerprintFiles(
    root,
    [pubspec, if (lock.existsSync()) lock],
    extra: [Platform.version],
  );
  final previous = readJsonMap(dependencyState);

  if (!force &&
      packageConfig.existsSync() &&
      previous?['fingerprint'] == fingerprint) {
    stdout.writeln('Algorithm dependencies unchanged — cached ✓');
    return true;
  }

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
    return false;
  }

  final resolvedFingerprint = fingerprintFiles(
    root,
    [pubspec, if (lock.existsSync()) lock],
    extra: [Platform.version],
  );
  writeJsonMapAtomic(dependencyState, {
    'fingerprint': resolvedFingerprint,
    'resolvedAt': DateTime.now().toUtc().toIso8601String(),
  });
  return true;
}

String _inputFingerprint(Directory root, Directory repo) {
  final files = <File>[
    ...filesUnder(repo, include: (file) => _repoInput(repo, file)),
    ..._toolAndWorkerInputs(root),
  ];
  return fingerprintFiles(
    root,
    files,
    extra: [Platform.version, repo.path],
  );
}

String _toolFingerprint(Directory root, Directory repo) {
  final files = <File>[
    ..._toolAndWorkerInputs(root),
    for (final name in ['pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml'])
      if (File('${repo.path}/$name').existsSync()) File('${repo.path}/$name'),
  ];
  return fingerprintFiles(root, files, extra: [Platform.version]);
}

String _compiledFingerprint(Directory root, Directory stage) {
  final files = <File>[
    ...filesUnder(stage, include: (file) => file.path.endsWith('.dart')),
    File('${root.path}/worker/main.dart'),
    File('${root.path}/lib/sandbox_worker_runtime.dart'),
    ...filesUnder(
      Directory('${root.path}/packages/sorting_sandbox_api'),
      include: _packageInput,
    ),
    for (final name in ['pubspec.yaml', 'pubspec.lock'])
      if (File('${root.path}/$name').existsSync()) File('${root.path}/$name'),
  ];
  return fingerprintFiles(root, files, extra: [Platform.version]);
}

List<File> _toolAndWorkerInputs(Directory root) => <File>[
  for (final path in [
    'tool/build_algorithms.dart',
    'tool/cache_utils.dart',
    'tool/instrumenter.dart',
    'tool/model.dart',
    'worker/main.dart',
    'lib/sandbox_worker_runtime.dart',
    'pubspec.yaml',
    'pubspec.lock',
  ])
    if (File('${root.path}/$path').existsSync()) File('${root.path}/$path'),
  ...filesUnder(
    Directory('${root.path}/packages/sorting_sandbox_api'),
    include: _packageInput,
  ),
];

bool _repoInput(Directory repo, File file) {
  if (_isHiddenRelative(repo, file)) return false;
  final basename = file.uri.pathSegments.last;
  return file.path.endsWith('.dart') ||
      basename == 'pubspec.yaml' ||
      basename == 'pubspec.lock' ||
      basename == 'analysis_options.yaml';
}

bool _packageInput(File file) {
  final normalized = file.path.replaceAll('\\', '/');
  return !normalized.contains('/.dart_tool/') &&
      !normalized.contains('/build/');
}

bool _cachedRuntimeIsUsable(
  Directory root,
  Directory repo,
  Map<String, dynamic>? state,
) {
  final workerPath = state?['workerPath']?.toString();
  if (workerPath == null || workerPath.isEmpty) return false;
  if (!File('${root.path}/runtime/$workerPath').existsSync()) return false;
  if (!File('${root.path}/runtime/algorithms.json').existsSync()) return false;
  if (File('${repo.path}/pubspec.yaml').existsSync() &&
      !File('${repo.path}/.dart_tool/package_config.json').existsSync()) {
    return false;
  }
  return true;
}

Future<String?> _compileWorker(Directory root, String buildId) async {
  stdout.writeln('Compiling disposable web worker…');
  final temporaryMain = File('${root.path}/worker/main_next.dart');
  final mainSource = File('${root.path}/worker/main.dart').readAsStringSync();
  temporaryMain.writeAsStringSync(
    mainSource.replaceFirst(
      "import 'generated/registry.g.dart';",
      "import 'generated_next/registry.g.dart';",
    ),
  );

  final workerPath = 'algorithm_worker.$buildId.js';
  final nextWorker = File('${root.path}/runtime/$workerPath.next');
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
      'runtime/$workerPath.next',
    ],
    workingDirectory: root.path,
  );
  if (temporaryMain.existsSync()) temporaryMain.deleteSync();
  stdout.write(result.stdout);
  stderr.write(result.stderr);

  if (result.exitCode != 0 || !nextWorker.existsSync()) {
    if (nextWorker.existsSync()) nextWorker.deleteSync();
    stderr.writeln(
      'Worker compilation failed; the last successful build remains active.',
    );
    exitCode = result.exitCode == 0 ? 1 : result.exitCode;
    return null;
  }

  _replaceFile(nextWorker, File('${root.path}/runtime/$workerPath'));
  return workerPath;
}

_CachedAlgorithm? _readCachedAlgorithm(Directory directory, String key) {
  final metadata = readJsonMap(File('${directory.path}/metadata.json'));
  if (metadata == null || metadata['key'] != key) return null;

  if (metadata['valid'] == false) {
    final value = metadata['diagnostic'];
    if (value is! Map) return null;
    return _CachedAlgorithm.diagnostic(
      _diagnosticFromJson(value.cast<String, dynamic>()),
    );
  }

  final value = metadata['definition'];
  if (value is! Map) return null;
  final benchmark = File('${directory.path}/benchmark.dart');
  final visual = File('${directory.path}/visual.dart');
  if (!benchmark.existsSync() || !visual.existsSync()) return null;
  return _CachedAlgorithm.valid(
    _definitionFromJson(value.cast<String, dynamic>()),
  );
}

void _writeValidCache(
  Directory directory,
  String key,
  AlgorithmDefinition definition,
  File benchmark,
  File visual,
) {
  directory.createSync(recursive: true);
  benchmark.copySync('${directory.path}/benchmark.dart');
  visual.copySync('${directory.path}/visual.dart');
  writeJsonMapAtomic(File('${directory.path}/metadata.json'), {
    'key': key,
    'valid': true,
    'definition': definition.toJson(),
  });
}

void _writeDiagnosticCache(
  Directory directory,
  String key,
  AlgorithmDiagnostic diagnostic,
) {
  directory.createSync(recursive: true);
  for (final name in ['benchmark.dart', 'visual.dart']) {
    final file = File('${directory.path}/$name');
    if (file.existsSync()) file.deleteSync();
  }
  writeJsonMapAtomic(File('${directory.path}/metadata.json'), {
    'key': key,
    'valid': false,
    'diagnostic': diagnostic.toJson(),
  });
}

void _copyCachedSources(
  Directory directory,
  Directory stage,
  AlgorithmDefinition definition,
) {
  final safe = _safeId(definition.id);
  File('${directory.path}/benchmark.dart').copySync(
    '${stage.path}/${safe}_benchmark.dart',
  );
  File('${directory.path}/visual.dart').copySync(
    '${stage.path}/${safe}_visual.dart',
  );
}

AlgorithmDefinition _definitionFromJson(Map<String, dynamic> json) =>
    AlgorithmDefinition(
      id: json['id'] as String,
      author: json['author'] as String,
      name: json['name'] as String,
      color: json['color'] as String,
      className: json['className'] as String,
      path: json['path'] as String,
      source: json['source'] as String,
    );

AlgorithmDiagnostic _diagnosticFromJson(Map<String, dynamic> json) =>
    AlgorithmDiagnostic(
      path: json['path'] as String,
      author: json['author'] as String,
      message: json['message'] as String,
    );

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
      parsed.errors.map((error) => error.toString()).join('\n'),
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
    ..writeln('// Generated by tool/build_algorithms.dart. Do not edit.')
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
  writeJsonMapAtomic(File('${root.path}/runtime/algorithms.json'), {
    'buildId': buildId,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'workerPath': workerPath,
    'algorithms': definitions.map((definition) => definition.toJson()).toList(),
    'diagnostics': diagnostics.map((diagnostic) => diagnostic.toJson()).toList(),
  });
}

void _cleanupOldWorkers(Directory root, {required int keep}) {
  final runtime = Directory('${root.path}/runtime');
  if (!runtime.existsSync()) return;
  final files = runtime
      .listSync()
      .whereType<File>()
      .where(
        (file) => RegExp(r'algorithm_worker\.\d+\.js$').hasMatch(file.path),
      )
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

class _CachedAlgorithm {
  _CachedAlgorithm.valid(this.definition) : diagnostic = null;
  _CachedAlgorithm.diagnostic(this.diagnostic) : definition = null;

  final AlgorithmDefinition? definition;
  final AlgorithmDiagnostic? diagnostic;
}
