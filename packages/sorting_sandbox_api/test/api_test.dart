import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';
import 'package:test/test.dart';

class Probe implements OperationProbe {
  int reads = 0;
  int writes = 0;
  int comparisons = 0;

  @override
  void onComparison() => comparisons++;

  @override
  void onInit(String label, List<ElementState> values) {}

  @override
  void onRead(String label, int index, Element element, ElementState value) =>
      reads++;

  @override
  void onWrite(String label, int index, Element element, ElementState value) =>
      writes++;
}

void main() {
  test('swap counts exactly like a temporary variable swap', () {
    final p1 = Probe();
    final a = Elements.runtime(probe: p1, label: 'list', values: [2, 1]);
    a.swap(0, 1);
    expect(p1.reads, 2);
    expect(p1.writes, 2);

    final p2 = Probe();
    final b = Elements.runtime(probe: p2, label: 'list', values: [2, 1]);
    final temp = b[1];
    b[1] = b[0];
    b[0] = temp;
    expect(p2.reads, p1.reads);
    expect(p2.writes, p1.writes);
  });

  test('Element does not expose its sorting key', () {
    final p = Probe();
    final list = Elements.runtime(
      probe: p,
      label: 'list',
      values: [137, 42, 137],
    );

    final first = list[0];
    final second = list[1];
    final equalToFirst = list[2];

    expect(first.toString(), 'Element');
    expect(int.tryParse(first.toString()), isNull);
    expect(first.hashCode, second.hashCode);
    expect(first == equalToFirst, isTrue);
    expect(first.hashCode, equalToFirst.hashCode);
  });

  test('comparisons are counted', () {
    final p = Probe();
    final list = Elements.runtime(probe: p, label: 'list', values: [2, 1]);
    expect(list[0] > list[1], isTrue);
    expect(p.reads, 2);
    expect(p.comparisons, 1);
  });
}
