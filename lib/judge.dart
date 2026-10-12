// Correctness, stability and benchmark judgement for one algorithm.
//
// This runs in the HOST, not in the worker: a worker of any language only
// sorts one given input at a time and reports the resulting keys, hidden
// origins and operation counts (see `run` in lib/worker_core.dart and
// languages/*/). Every language is therefore judged by exactly the same code
// on exactly the same inputs.
//
// Pure Dart (dart:math only), so it is usable from tool/host.dart and tests.
import 'dart:math';

/// One sort as reported by a worker: either the result or the failure.
class CaseResult {
  CaseResult({
    required this.keys,
    required this.origins,
    required this.metrics,
  }) : error = null;

  CaseResult.failure(Map<String, Object?> this.error)
      : keys = const [],
        origins = const [],
        metrics = const {};

  /// Accepts a worker's `runResult` message (or the same map without type).
  factory CaseResult.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    if (error is Map) {
      return CaseResult.failure(
          error.map((key, value) => MapEntry(key.toString(), value as Object?)));
    }
    final metrics = json['metrics'];
    return CaseResult(
      keys: _ints(json['keys']),
      origins: _ints(json['origins']),
      metrics: metrics is Map
          ? metrics.map((key, value) => MapEntry(key.toString(), value as Object?))
          : const {},
    );
  }

  final List<int> keys;
  final List<int> origins;

  /// {reads, writes, comparisons, score}
  final Map<String, Object?> metrics;

  /// The student's exception, already mapped to their lines:
  /// {kind, message, line?, column?, stack?}.
  final Map<String, Object?>? error;

  bool get failed => error != null;
  bool get sorted => isSortedKeys(keys);
  bool get stable => isStableKeys(keys, origins);
}

/// Sorts [values] once in a worker. Throws only when the worker itself fails
/// (crash, timeout, cancelled); student exceptions are [CaseResult.failure].
typedef CaseRunner = Future<CaseResult> Function(List<int> values);

bool isSortedKeys(List<int> values) {
  for (var i = 1; i < values.length; i++) {
    if (values[i - 1] > values[i]) return false;
  }
  return true;
}

/// Equal adjacent keys keep their original order.
bool isStableKeys(List<int> keys, List<int> origins) {
  if (!isSortedKeys(keys) || keys.length != origins.length) return false;
  for (var i = 1; i < keys.length; i++) {
    if (keys[i - 1] == keys[i] && origins[i - 1] > origins[i]) return false;
  }
  return true;
}

List<List<int>> stabilityCases() {
  final seeds = <List<int>>[
    [2, 2, 1],
    [2, 1, 2, 1],
    [0, 0, 1, 1, 2],
    [3, 1, 3, 2, 3, 1],
  ];
  final result = <List<int>>[];
  for (final seed in seeds) {
    result.addAll(_uniquePermutations(seed));
  }
  return result;
}

List<List<int>> _uniquePermutations(List<int> values) {
  final sorted = List<int>.from(values)..sort();
  final out = <List<int>>[];

  void walk(List<int> prefix, List<int> rest) {
    if (rest.isEmpty) {
      out.add(List<int>.from(prefix));
      return;
    }
    int? last;
    for (var i = 0; i < rest.length; i++) {
      if (last == rest[i]) continue;
      last = rest[i];
      final nextRest = List<int>.from(rest)..removeAt(i);
      prefix.add(rest[i]);
      walk(prefix, nextRest);
      prefix.removeLast();
    }
  }

  walk([], sorted);
  return out;
}

const _correctnessCases = <List<int>>[
  [],
  [1],
  [2, 1],
  [1, 2],
  [3, 1, 2],
  [4, 3, 2, 1],
  [1, 1, 1, 1],
  [3, 1, 3, 2, 1, 2],
];

/// Class-wide analysis: correctness, empirical stability and the operation
/// counts for every benchmark input. All algorithms receive the SAME inputs.
Future<Map<String, Object?>> analyzeCases(
  CaseRunner run,
  List<List<int>> benchmarkCases,
) async {
  Map<String, Object?> incorrect(List<int> values, String reason) => {
        'correct': false,
        'stable': null,
        'failingCase': _show(values),
        'reason': reason,
        'benchmarks': const <Object?>[],
      };
  Map<String, Object?> threw(List<int> values, CaseResult result) => {
        'correct': false,
        'stable': null,
        'failingCase': _show(values),
        'reason': 'The algorithm threw an exception.',
        'error': result.error,
        'benchmarks': const <Object?>[],
      };

  for (final values in _correctnessCases) {
    final result = await run(values);
    if (result.failed) return threw(values, result);
    final reason = judgeResult(values, result);
    if (reason != null) return incorrect(values, reason);
  }

  var stable = true;
  for (final values in stabilityCases()) {
    final result = await run(values);
    if (result.failed) return threw(values, result);
    final reason = judgeResult(values, result);
    if (reason != null) return incorrect(values, reason);
    if (!result.stable) {
      stable = false;
      break;
    }
  }

  final benchmarks = <Map<String, Object?>>[];
  for (final values in benchmarkCases) {
    final result = await run(values);
    if (result.failed) return threw(values, result);
    final reason = judgeResult(values, result);
    if (reason != null) return incorrect(values, reason);
    benchmarks.add({'n': values.length, ...result.metrics});
  }
  return {
    'correct': true,
    'stable': stable,
    'failingCase': null,
    'benchmarks': benchmarks,
  };
}

class _CheckGroup {
  const _CheckGroup(this.name, this.cases);
  final String name;
  final List<List<int>> cases;
}

List<_CheckGroup> _checkGroups() {
  final random = Random(20240611);
  List<int> shuffled(int n) => List<int>.generate(n, (i) => i + 1)..shuffle(random);
  List<int> withDuplicates(int n, int distinct) =>
      List<int>.generate(n, (_) => random.nextInt(distinct));
  return [
    const _CheckGroup('Empty list and one element', [
      [],
      [7],
    ]),
    const _CheckGroup('Two and three elements', [
      [1, 2],
      [2, 1],
      [1, 2, 3],
      [1, 3, 2],
      [2, 1, 3],
      [2, 3, 1],
      [3, 1, 2],
      [3, 2, 1],
    ]),
    _CheckGroup('Already sorted and reversed', [
      List<int>.generate(10, (i) => i + 1),
      List<int>.generate(10, (i) => 10 - i),
      List<int>.generate(9, (i) => 9 - i),
    ]),
    const _CheckGroup('Duplicates', [
      [4, 4, 4, 4],
      [2, 1, 2, 1, 2],
      [3, 1, 3, 2, 1, 2],
      [0, 0, 1, 1, 0, 0],
    ]),
    _CheckGroup('Random inputs up to 40 elements', [
      for (var n = 4; n <= 40; n += 2)
        n % 4 == 0 ? shuffled(n) : withDuplicates(n, n ~/ 2 + 1),
    ]),
    _CheckGroup('Larger inputs', [
      shuffled(100),
      shuffled(255),
      withDuplicates(300, 20),
      shuffled(512),
    ]),
  ];
}

/// Detailed report for one algorithm, shown in the Check dialog.
Future<Map<String, Object?>> checkCases(CaseRunner run) async {
  final groups = <Map<String, Object?>>[];
  var allCorrect = true;
  for (final group in _checkGroups()) {
    var passed = 0;
    Map<String, Object?>? failure;
    for (final values in group.cases) {
      final result = await run(values);
      if (result.failed) {
        failure = {
          'input': _preview(values),
          'message': 'The algorithm threw an exception.',
          'error': result.error,
        };
        break;
      }
      final reason = judgeResult(values, result);
      if (reason == null) {
        passed++;
        continue;
      }
      failure = {
        'input': _preview(values),
        'output': _preview(result.keys),
        'message': reason,
      };
      break;
    }
    if (failure != null) allCorrect = false;
    groups.add({
      'name': group.name,
      'total': group.cases.length,
      'passed': passed,
      'ok': failure == null,
      'failure': failure,
    });
  }

  Map<String, Object?> stability = {'tested': false};
  if (allCorrect) {
    stability = {'tested': true, 'stable': true};
    final random = Random(7);
    final cases = <List<int>>[
      ...stabilityCases(),
      for (var n = 6; n <= 30; n += 3)
        List<int>.generate(n, (_) => random.nextInt(4)),
    ];
    for (final values in cases) {
      final result = await run(values);
      if (result.failed) {
        stability = {'tested': false};
        break;
      }
      if (judgeResult(values, result) == null && !result.stable) {
        stability = {
          'tested': true,
          'stable': false,
          'input': values,
          'output': result.keys,
          'origins': result.origins,
        };
        break;
      }
    }
  }
  return {'groups': groups, 'stability': stability, 'correct': allCorrect};
}

/// Null when [result] is a correct sort of [input]; otherwise the reason.
String? judgeResult(List<int> input, CaseResult result) {
  if (result.keys.length != input.length ||
      result.origins.length != input.length) {
    return 'The list changed its length.';
  }
  final origins = List<int>.from(result.origins)..sort();
  for (var i = 0; i < origins.length; i++) {
    if (origins[i] != i) {
      return result.origins.any((origin) => origin < 0)
          ? 'Elements of the temporary list ended up in the result: '
              'some elements were overwritten.'
          : 'Some elements were overwritten or duplicated: the result is '
              'not a rearrangement of the input.';
    }
  }
  if (!result.sorted) return 'The result is not sorted.';
  return null;
}

Map<String, Object?> _preview(List<int> values) => {
      'length': values.length,
      'values': values.length <= 64 ? values : values.sublist(0, 64),
    };

String _show(List<int> values) => values.length <= 24
    ? values.toString()
    : '[${values.take(24).join(', ')}, …] (n = ${values.length})';

List<int> _ints(Object? raw) => <int>[
      if (raw is List)
        for (final entry in raw)
          if (entry is num) entry.toInt(),
    ];
