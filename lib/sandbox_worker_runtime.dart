import 'dart:async';

import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

CheckpointSession? _activeCheckpointSession;

/// Called only from generated visual code.
Future<void> sandboxCheckpoint(int line, Map<String, Object?> locals) async {
  final session = _activeCheckpointSession;
  if (session == null) return;
  await session.checkpoint(line, locals);
}

T withCheckpointSession<T>(CheckpointSession session, T Function() body) {
  final previous = _activeCheckpointSession;
  _activeCheckpointSession = session;
  try {
    return body();
  } finally {
    _activeCheckpointSession = previous;
  }
}

Future<T> withCheckpointSessionAsync<T>(
  CheckpointSession session,
  Future<T> Function() body,
) async {
  final previous = _activeCheckpointSession;
  _activeCheckpointSession = session;
  try {
    return await body();
  } finally {
    _activeCheckpointSession = previous;
  }
}

class Metrics {
  int reads = 0;
  int writes = 0;
  int comparisons = 0;

  int get score => reads + writes + comparisons;

  Map<String, int> toJson() => {
    'reads': reads,
    'writes': writes,
    'comparisons': comparisons,
    'score': score,
  };
}

class ProbeState implements OperationProbe {
  ProbeState({required this.onOperation});

  final void Function() onOperation;
  final Metrics metrics = Metrics();
  final Map<String, List<ElementState>> arrays = {};

  String? readList;
  int? readIndex;
  String? writeList;
  int? writeIndex;

  @override
  void onComparison() {
    metrics.comparisons++;
    onOperation();
  }

  @override
  void onInit(String label, List<ElementState> values) {
    arrays[label] = List<ElementState>.from(values);
  }

  @override
  void onRead(String label, int index, ElementState value) {
    metrics.reads++;
    readList = label;
    readIndex = index;
    onOperation();
  }

  @override
  void onWrite(String label, int index, ElementState value) {
    metrics.writes++;
    arrays[label]![index] = value;
    writeList = label;
    writeIndex = index;
    onOperation();
  }

  List<int> keys(String label) => arrays[label]!.map((e) => e.key).toList();
  List<int> origins(String label) =>
      arrays[label]!.map((e) => e.origin).toList();
}

class CheckpointSession {
  CheckpointSession({required this.emitFrame});

  final void Function(Map<String, Object?> frame) emitFrame;
  late final ProbeState probe = ProbeState(onOperation: () {});

  int _budget = 0;
  Completer<void>? _waiting;
  int currentLine = 0;
  Map<String, Object?> currentLocals = const {};
  bool done = false;

  void attachProbe(ProbeState value) {
    // Kept for a stable call site in worker code. Probe is supplied via getter
    // in the session factory below; this method intentionally does nothing.
  }

  void addBudget(int amount) {
    if (amount <= 0 || done) return;
    _budget += amount;
    final waiter = _waiting;
    if (waiter != null && !waiter.isCompleted) {
      _waiting = null;
      waiter.complete();
    }
  }

  Future<void> checkpoint(int line, Map<String, Object?> locals) async {
    currentLine = line;
    currentLocals = <String, Object?>{
      for (final entry in locals.entries) entry.key: _debugValue(entry.value),
    };

    if (_budget > 0) {
      _budget--;
      if (_budget > 0) return;
    }

    _emit(done: false);
    final waiter = Completer<void>();
    _waiting = waiter;
    await waiter.future;
  }

  void finish() {
    done = true;
    _emit(done: true);
    final waiter = _waiting;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _emit({required bool done}) {
    final list = probe.arrays['list'] ?? const <ElementState>[];
    final scratch = probe.arrays['scratch'] ?? const <ElementState>[];
    emitFrame({
      'type': 'frame',
      'done': done,
      'line': currentLine,
      'locals': currentLocals,
      'numbers': list.map((e) => e.key).toList(),
      'scratch': scratch.map((e) => e.key).toList(),
      'origins': list.map((e) => e.origin).toList(),
      'metrics': probe.metrics.toJson(),
      'read': probe.readList == null
          ? null
          : {'list': probe.readList, 'index': probe.readIndex},
      'write': probe.writeList == null
          ? null
          : {'list': probe.writeList, 'index': probe.writeIndex},
    });
  }
}

Object? _debugValue(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  if (value is Element) return value.toString();
  return value.toString();
}

class RunResult {
  RunResult({
    required this.sorted,
    required this.stable,
    required this.keys,
    required this.origins,
    required this.metrics,
  });

  final bool sorted;
  final bool stable;
  final List<int> keys;
  final List<int> origins;
  final Metrics metrics;

  Map<String, Object?> toJson() => {
    'sorted': sorted,
    'stable': stable,
    'keys': keys,
    'origins': origins,
    'metrics': metrics.toJson(),
  };
}

RunResult runSyncAlgorithm(dynamic algorithm, List<int> values) {
  late ProbeState probe;
  probe = ProbeState(onOperation: () {});
  final list = Elements.runtime(
    probe: probe,
    label: 'list',
    values: values,
    origins: List<int>.generate(values.length, (i) => i),
  );
  final scratch = Elements.runtime(
    probe: probe,
    label: 'scratch',
    values: List<int>.filled(values.length, 0),
    origins: List<int>.generate(values.length, (i) => -1 - i),
  );

  algorithm.sort(list, scratch);

  final keys = probe.keys('list');
  final origins = probe.origins('list');
  return RunResult(
    sorted: _isSorted(keys),
    stable: _isStable(keys, origins),
    keys: keys,
    origins: origins,
    metrics: probe.metrics,
  );
}

bool _isSorted(List<int> values) {
  for (var i = 1; i < values.length; i++) {
    if (values[i - 1] > values[i]) return false;
  }
  return true;
}

bool _isStable(List<int> keys, List<int> origins) {
  if (!_isSorted(keys)) return false;
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
