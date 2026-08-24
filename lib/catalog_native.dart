import 'dart:convert';

import 'generated/catalog.g.dart';
import 'models.dart';

AlgorithmCatalog? _cachedCatalog;

Future<AlgorithmCatalog> loadCatalog() async => _cachedCatalog ??= _loadCatalog();

AlgorithmCatalog _loadCatalog() {
  if (generatedCatalogBase64.isEmpty) {
    return AlgorithmCatalog(
      buildId: 'unprepared-native',
      workerPath: 'native',
      algorithms: const [],
      diagnostics: [
        BuildDiagnostic(
          path: '',
          author: '',
          message: 'No Android algorithm snapshot. Build with ./build-apk.',
        ),
      ],
    );
  }

  final json = jsonDecode(
    utf8.decode(base64Decode(generatedCatalogBase64)),
  ) as Map<String, dynamic>;
  return AlgorithmCatalog(
    buildId: json['buildId']?.toString() ?? '',
    workerPath: json['workerPath']?.toString() ?? 'native',
    algorithms: ((json['algorithms'] as List?) ?? const [])
        .map((e) => AlgorithmMeta.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
    diagnostics: ((json['diagnostics'] as List?) ?? const [])
        .map(
          (e) => BuildDiagnostic.fromJson((e as Map).cast<String, dynamic>()),
        )
        .toList(),
  );
}
