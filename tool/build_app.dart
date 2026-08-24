import 'dart:io';

import 'cache_utils.dart';

Future<void> main(List<String> args) async {
  final root = Directory.current.absolute;
  final force = args.contains('--force');
  final stateFile = File(
    '${root.path}/.dart_tool/sorting_sandbox/app_build.json',
  );
  final buildIndex = File('${root.path}/build/web/index.html');

  final flutterVersion = await Process.run('flutter', ['--version', '--machine']);
  if (flutterVersion.exitCode != 0) {
    stdout.write(flutterVersion.stdout);
    stderr.write(flutterVersion.stderr);
    exitCode = flutterVersion.exitCode;
    return;
  }

  final inputs = <File>[
    ...filesUnder(Directory('${root.path}/lib')),
    ...filesUnder(Directory('${root.path}/web')),
    ...filesUnder(
      Directory('${root.path}/packages/sorting_sandbox_api'),
      include: _packageInput,
    ),
    ...filesUnder(Directory('${root.path}/assets')),
    for (final name in ['pubspec.yaml', 'pubspec.lock'])
      if (File('${root.path}/$name').existsSync()) File('${root.path}/$name'),
  ];

  final fingerprint = fingerprintFiles(
    root,
    inputs,
    extra: [flutterVersion.stdout.toString()],
  );
  final previous = readJsonMap(stateFile);

  if (!force &&
      buildIndex.existsSync() &&
      previous?['fingerprint'] == fingerprint) {
    stdout.writeln('Flutter web application unchanged — using cached build/web ✓');
    return;
  }

  stdout.writeln('Flutter application changed — building web release…');
  final process = await Process.start(
    'flutter',
    ['build', 'web', '--release', '--no-wasm-dry-run', '--dart2js-optimization', 'O1'],
    workingDirectory: root.path,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) {
    exitCode = code;
    return;
  }

  writeJsonMapAtomic(stateFile, {
    'fingerprint': fingerprint,
    'builtAt': DateTime.now().toUtc().toIso8601String(),
  });
}

bool _packageInput(File file) {
  final normalized = file.path.replaceAll('\\', '/');
  return !normalized.contains('/.dart_tool/') &&
      !normalized.contains('/build/') &&
      !normalized.endsWith('/pubspec.lock');
}
