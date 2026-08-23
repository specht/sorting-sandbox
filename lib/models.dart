class AlgorithmMeta {
  AlgorithmMeta({
    required this.id,
    required this.author,
    required this.name,
    required this.color,
    required this.className,
    required this.path,
    required this.source,
  });

  factory AlgorithmMeta.fromJson(Map<String, dynamic> json) => AlgorithmMeta(
        id: json['id'] as String,
        author: json['author'] as String,
        name: json['name'] as String,
        color: json['color'] as String,
        className: json['className'] as String,
        path: json['path'] as String,
        source: json['source'] as String,
      );

  final String id;
  final String author;
  final String name;
  final String color;
  final String className;
  final String path;
  final String source;

  String get label => '$name ($author)';
}

class BuildDiagnostic {
  BuildDiagnostic({required this.path, required this.author, required this.message});

  factory BuildDiagnostic.fromJson(Map<String, dynamic> json) => BuildDiagnostic(
        path: json['path']?.toString() ?? '',
        author: json['author']?.toString() ?? '',
        message: json['message']?.toString() ?? '',
      );

  final String path;
  final String author;
  final String message;
}

class AlgorithmCatalog {
  AlgorithmCatalog({
    required this.buildId,
    required this.workerPath,
    required this.algorithms,
    required this.diagnostics,
  });

  final String buildId;
  final String workerPath;
  final List<AlgorithmMeta> algorithms;
  final List<BuildDiagnostic> diagnostics;
}

class MetricsData {
  const MetricsData({
    this.reads = 0,
    this.writes = 0,
    this.comparisons = 0,
    this.score = 0,
  });

  factory MetricsData.fromJson(Map<String, dynamic> json) => MetricsData(
        reads: (json['reads'] as num?)?.toInt() ?? 0,
        writes: (json['writes'] as num?)?.toInt() ?? 0,
        comparisons: (json['comparisons'] as num?)?.toInt() ?? 0,
        score: (json['score'] as num?)?.toInt() ?? 0,
      );

  final int reads;
  final int writes;
  final int comparisons;
  final int score;
}

class MarkerData {
  const MarkerData({this.list, this.index});

  factory MarkerData.fromJson(dynamic json) {
    if (json is! Map) return const MarkerData();
    return MarkerData(
      list: json['list']?.toString(),
      index: (json['index'] as num?)?.toInt(),
    );
  }

  final String? list;
  final int? index;
}

class VisualFrame {
  VisualFrame({
    required this.numbers,
    required this.scratch,
    required this.origins,
    required this.metrics,
    required this.line,
    required this.locals,
    required this.read,
    required this.write,
    required this.done,
  });

  factory VisualFrame.fromJson(Map<String, dynamic> json) => VisualFrame(
        numbers: (json['numbers'] as List).cast<num>().map((e) => e.toInt()).toList(),
        scratch: (json['scratch'] as List).cast<num>().map((e) => e.toInt()).toList(),
        origins: (json['origins'] as List).cast<num>().map((e) => e.toInt()).toList(),
        metrics: MetricsData.fromJson((json['metrics'] as Map).cast<String, dynamic>()),
        line: (json['line'] as num?)?.toInt() ?? 0,
        locals: (json['locals'] as Map?)?.cast<String, dynamic>() ?? const {},
        read: MarkerData.fromJson(json['read']),
        write: MarkerData.fromJson(json['write']),
        done: json['done'] == true,
      );

  final List<int> numbers;
  final List<int> scratch;
  final List<int> origins;
  final MetricsData metrics;
  final int line;
  final Map<String, dynamic> locals;
  final MarkerData read;
  final MarkerData write;
  final bool done;
}

class BenchmarkPoint {
  BenchmarkPoint({required this.n, required this.metrics});

  factory BenchmarkPoint.fromJson(Map<String, dynamic> json) => BenchmarkPoint(
        n: (json['n'] as num).toInt(),
        metrics: MetricsData.fromJson(json),
      );

  final int n;
  final MetricsData metrics;
}

class AnalysisData {
  AnalysisData({
    required this.correct,
    required this.stable,
    required this.stabilityNote,
    required this.failingCase,
    required this.benchmarks,
    this.timeout = false,
    this.error,
  });

  factory AnalysisData.fromJson(Map<String, dynamic> json) => AnalysisData(
        correct: json['correct'] == true,
        stable: json['stable'] as bool?,
        stabilityNote: json['stabilityNote']?.toString(),
        failingCase: json['failingCase']?.toString(),
        benchmarks: ((json['benchmarks'] as List?) ?? const [])
            .map((e) => BenchmarkPoint.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );

  final bool correct;
  final bool? stable;
  final String? stabilityNote;
  final String? failingCase;
  final List<BenchmarkPoint> benchmarks;
  final bool timeout;
  final String? error;
}
