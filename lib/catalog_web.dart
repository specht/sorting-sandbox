import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'models.dart';

Future<AlgorithmCatalog> loadCatalog() async {
  final url =
      'runtime/algorithms.json?ts=${DateTime.now().millisecondsSinceEpoch}';
  final response = await web.window.fetch(url.toJS).toDart;
  final text = (await response.text().toDart).toDart;
  final json = jsonDecode(text) as Map<String, dynamic>;
  return AlgorithmCatalog(
    buildId: json['buildId']?.toString() ?? '',
    workerPath: json['workerPath']?.toString() ?? 'algorithm_worker.js',
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
