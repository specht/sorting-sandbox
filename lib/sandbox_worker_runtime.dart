import 'dart:async';

import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

CheckpointSession? _activeCheckpointSession;

/// The visual session that generated code is currently reporting to, if any.
CheckpointSession? get activeCheckpointSession => _activeCheckpointSession;

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
  final Map<Element, ElementState> _debugStates =
      Map<Element, ElementState>.identity();

  final Map<String, Set<int>> _reads = {};
  final Map<String, Set<int>> _writes = {};

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
  void onRead(String label, int index, Element element, ElementState value) {
    _debugStates[element] = value;
    metrics.reads++;
    (_reads[label] ??= <int>{}).add(index);
    onOperation();
  }

  @override
  void onWrite(String label, int index, Element element, ElementState value) {
    _debugStates[element] = value;
    metrics.writes++;
    arrays[label]![index] = value;
    (_writes[label] ??= <int>{}).add(index);
    onOperation();
  }

  List<Map<String, Object>> takeReads() => _takeMarkers(_reads);

  List<Map<String, Object>> takeWrites() => _takeMarkers(_writes);

  void discardMarkers() {
    _reads.clear();
    _writes.clear();
  }

  List<Map<String, Object>> _takeMarkers(Map<String, Set<int>> source) {
    final result = <Map<String, Object>>[];
    final labels = source.keys.toList()..sort();
    for (final label in labels) {
      final indices = source[label]!.toList()..sort();
      for (final index in indices) {
        result.add({'list': label, 'index': index});
      }
    }
    source.clear();
    return result;
  }

  ElementState? debugState(Element element) => _debugStates[element];

  List<int> keys(String label) => arrays[label]!.map((e) => e.key).toList();
  List<int> origins(String label) =>
      arrays[label]!.map((e) => e.origin).toList();
}

/// Cooperative execution of a generated (async) visual algorithm.
///
/// Every generated checkpoint consumes one unit of budget. When the budget is
/// used up, the session emits ONE frame describing the current state and
/// waits until the host grants more budget. Nothing is recorded: the browser
/// only ever receives the current state.
class CheckpointSession {
  CheckpointSession({required this.emitFrame});

  final void Function(Map<String, Object?> frame) emitFrame;
  final ProbeState probe = ProbeState(onOperation: () {});

  int _budget = 0;
  Completer<void>? _waiting;
  int currentLine = 0;
  int checkpointIndex = -1;
  Map<String, Object?> currentLocals = const {};
  bool done = false;

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
    checkpointIndex++;
    currentLine = line;
    currentLocals = <String, Object?>{
      for (final entry in locals.entries)
        entry.key: _debugValue(entry.value, probe),
    };

    if (_budget > 0) {
      _budget--;
      if (_budget > 0) {
        // A coarse animation frame can skip many source checkpoints. Memory
        // highlighting should still describe only the final logical step,
        // exactly like single-step mode, rather than all skipped work.
        probe.discardMarkers();
        return;
      }
    }

    _emit(done: false);
    final waiter = Completer<void>();
    _waiting = waiter;
    await waiter.future;
  }

  /// Emits the current state without waiting, e.g. right before an error
  /// is reported, so the browser shows the arrays at the moment of failure.
  void flush() => _emit(done: false);

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
      'checkpoint': checkpointIndex,
      'locals': currentLocals,
      'numbers': [for (final e in list) e.key],
      'scratch': [for (final e in scratch) e.key],
      'metrics': probe.metrics.toJson(),
      'reads': probe.takeReads(),
      'writes': probe.takeWrites(),
    });
  }
}

/// Converts a local variable into a small JSON-safe display value.
Object? _debugValue(Object? value, ProbeState probe) {
  if (value == null || value is bool || value is int) return value;
  if (value is double) return value.isFinite ? value : value.toString();
  if (value is String) return _shorten(value);
  if (value is Element) return probe.debugState(value)?.key ?? 'Element';
  if (value is Elements) return 'Elements(${value.length})';
  if (value is List) return 'List(${value.length})';
  return _shorten(value.toString());
}

String _shorten(String text) =>
    text.length <= 48 ? text : '${text.substring(0, 45)}…';

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
  final probe = ProbeState(onOperation: () {});
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
    sorted: isSortedKeys(keys),
    stable: _isStable(keys, origins),
    keys: keys,
    origins: origins,
    metrics: probe.metrics,
  );
}

bool isSortedKeys(List<int> values) {
  for (var i = 1; i < values.length; i++) {
    if (values[i - 1] > values[i]) return false;
  }
  return true;
}

bool _isStable(List<int> keys, List<int> origins) {
  if (!isSortedKeys(keys)) return false;
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
