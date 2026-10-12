import 'package:sorting_sandbox/judge.dart';
import 'package:sorting_sandbox/sandbox_worker_runtime.dart';
import 'package:sorting_sandbox/worker_core.dart';
import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

import 'harness.dart';

class StableInsertion extends SortingAlgorithm {
  @override
  String get name => 'Insertion';
  @override
  String get color => '#000000';

  void sort(Elements list, Elements scratch) {
    for (var i = 1; i < list.length; i++) {
      final value = list[i];
      var j = i - 1;
      while (j >= 0 && list[j] > value) {
        list[j + 1] = list[j];
        j--;
      }
      list[j + 1] = value;
    }
  }
}

class UnstableSelection extends SortingAlgorithm {
  @override
  String get name => 'Selection';
  @override
  String get color => '#000000';

  void sort(Elements list, Elements scratch) {
    for (var i = 0; i < list.length; i++) {
      var min = i;
      for (var j = i + 1; j < list.length; j++) {
        if (list[j] < list[min]) min = j;
      }
      if (min != i) list.swap(i, min);
    }
  }
}

/// Sorts only the first two elements: wrong for longer lists.
class Broken extends SortingAlgorithm {
  @override
  String get name => 'Broken';
  @override
  String get color => '#000000';

  void sort(Elements list, Elements scratch) {
    if (list.length >= 2 && list[0] > list[1]) list.swap(0, 1);
  }
}

class Throwing extends SortingAlgorithm {
  @override
  String get name => 'Throwing';
  @override
  String get color => '#000000';

  void sort(Elements list, Elements scratch) {
    for (var i = 0; i <= list.length; i++) {
      list[i] = list[i];
    }
  }
}

class Overwriting extends SortingAlgorithm {
  @override
  String get name => 'Overwriting';
  @override
  String get color => '#000000';

  void sort(Elements list, Elements scratch) {
    list[0] = list[1];
  }
}

/// What the host does with a real worker: one `run` request per input.
CaseRunner runnerFor(AlgorithmFactory create) =>
    (values) async => CaseResult.fromJson(runCase(create, values));

void main() {
  test('hidden origins detect stability without student annotations', () {
    final stable = runSyncAlgorithm(StableInsertion(), [2, 2, 1]);
    final unstable = runSyncAlgorithm(UnstableSelection(), [2, 2, 1]);
    expect(stable.sorted, isTrue);
    expect(stable.stable, isTrue);
    expect(unstable.sorted, isTrue);
    expect(unstable.stable, isFalse);
  });

  test('visual checkpoints can show an opaque Element value', () async {
    final frames = <Map<String, Object?>>[];
    final session = CheckpointSession(emitFrame: frames.add);
    final list = Elements.runtime(
      probe: session.probe,
      label: 'list',
      values: [137, 42],
    );

    final pivot = list[0];
    expect(pivot.toString(), 'Element');

    final checkpoint = session.checkpoint(10, {'pivot': pivot});
    await Future<void>.delayed(Duration.zero);

    final locals = (frames.single['locals'] as Map).cast<String, Object?>();
    expect(locals['pivot'], 137);

    session.addBudget(1);
    await checkpoint;
    session.finish();
  });

  test('visual frames preserve every read and write in one source step', () async {
    final frames = <Map<String, Object?>>[];
    final session = CheckpointSession(emitFrame: frames.add);
    final list = Elements.runtime(
      probe: session.probe,
      label: 'list',
      values: [2, 1],
    );

    final first = session.checkpoint(20, const {});
    await Future<void>.delayed(Duration.zero);
    session.addBudget(1);
    await first;

    list.swap(0, 1);
    final second = session.checkpoint(21, const {});
    await Future<void>.delayed(Duration.zero);

    final reads = (frames.last['reads'] as List)
        .cast<Map>()
        .map((marker) => marker['index'])
        .toSet();
    final writes = (frames.last['writes'] as List)
        .cast<Map>()
        .map((marker) => marker['index'])
        .toSet();
    expect(reads, {0, 1});
    expect(writes, {0, 1});

    session.addBudget(1);
    await second;
    session.finish();
  });

  test('coarse playback keeps only the latest step memory markers', () async {
    final frames = <Map<String, Object?>>[];
    final session = CheckpointSession(emitFrame: frames.add);
    final list = Elements.runtime(
      probe: session.probe,
      label: 'list',
      values: [3, 2, 1],
    );

    final first = session.checkpoint(30, const {});
    await Future<void>.delayed(Duration.zero);
    session.addBudget(2);
    await first;

    final a = list[0];
    list[1] = a;
    await session.checkpoint(31, const {}); // skipped and discarded

    final b = list[1];
    list[2] = b;
    final emitted = session.checkpoint(32, const {});
    await Future<void>.delayed(Duration.zero);

    final reads = (frames.last['reads'] as List)
        .cast<Map>()
        .map((marker) => marker['index'])
        .toSet();
    final writes = (frames.last['writes'] as List)
        .cast<Map>()
        .map((marker) => marker['index'])
        .toSet();
    expect(reads, {1});
    expect(writes, {2});

    session.addBudget(1);
    await emitted;
    session.finish();
  });

  test('visual checkpoints carry deterministic sequence numbers', () async {
    final frames = <Map<String, Object?>>[];
    final session = CheckpointSession(emitFrame: frames.add);

    final first = session.checkpoint(10, {'i': 0});
    await Future<void>.delayed(Duration.zero);
    expect(frames.single['checkpoint'], 0);
    session.addBudget(1);
    await first;

    final second = session.checkpoint(11, {'i': 1});
    await Future<void>.delayed(Duration.zero);
    expect(frames.last['checkpoint'], 1);
    session.addBudget(1);
    await second;

    session.finish();
    expect(frames.last['checkpoint'], 1);
    expect(frames.last['done'], isTrue);
  });

  test('analysis reports correctness, stability and identical inputs', () async {
    final stable = await analyzeCases(runnerFor(StableInsertion.new), [
      [3, 1, 2],
      [5, 4, 3, 2, 1],
    ]);
    expect(stable['correct'], isTrue);
    expect(stable['stable'], isTrue);
    expect((stable['benchmarks'] as List).length, 2);

    final unstable = await analyzeCases(runnerFor(UnstableSelection.new), const []);
    expect(unstable['correct'], isTrue);
    expect(unstable['stable'], isFalse);

    final broken = await analyzeCases(runnerFor(Broken.new), const []);
    expect(broken['correct'], isFalse);
    expect(broken['stable'], null);
  });

  test('the check report names the failing group and input', () async {
    final report = await checkCases(runnerFor(Broken.new));
    expect(report['correct'], isFalse);
    final groups = (report['groups'] as List).cast<Map<String, Object?>>();
    expect(groups.first['ok'], isTrue, reason: 'empty and one-element lists');
    final failing = groups.firstWhere((group) => group['ok'] != true);
    final failure = failing['failure'] as Map<String, Object?>;
    expectContains(failure['message'].toString(), 'not sorted');

    final good = await checkCases(runnerFor(StableInsertion.new));
    expect(good['correct'], isTrue);
    expect((good['stability'] as Map)['stable'], isTrue);
  });

  test('an exception becomes a report with the student line', () async {
    final report = await analyzeCases(runnerFor(Throwing.new), const []);
    expect(report['correct'], isFalse);
    final error = report['error'] as Map<String, Object?>;
    expectContains(error['message'].toString(), 'RangeError');
  });

  test('overwritten elements are detected through hidden origins', () {
    final result = CaseResult.fromJson(runCase(Overwriting.new, [2, 1]));
    expectContains(judgeResult([2, 1], result) ?? '', 'overwritten');
  });

  test('a run reports keys, hidden origins and counts as plain JSON', () {
    final result = runCase(StableInsertion.new, [2, 2, 1]);
    expect(result['keys'], [1, 2, 2]);
    expect(result['origins'], [2, 0, 1]);
    final metrics = result['metrics'] as Map<String, int>;
    expect(metrics['score'], metrics['reads']! + metrics['writes']! + metrics['comparisons']!);
  });
}
