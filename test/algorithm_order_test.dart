import 'package:flutter_test/flutter_test.dart';
import 'package:sorting_sandbox/algorithm_order.dart';
import 'package:sorting_sandbox/models.dart';

void main() {
  test('orders algorithm families, variants, then authors', () {
    final algorithms = [
      _meta('thread', 'Thread Sort', 'HiTear'),
      _meta('quick-lomuto-j', 'Quick Sort (Lomuto)', 'Julian'),
      _meta('selection-a', 'Selection Sort', 'anna'),
      _meta('merge-try', 'Merge Sort Try', 'HiTear'),
      _meta('bubble-j', 'Bubble Sort', 'Julian'),
      _meta('quick-o', 'Quick Sort by Ovilli', 'ovilli'),
      _meta('insert-o', 'Insertion Sort', 'ovilli'),
      _meta('quick-hoare', 'Quick Sort (Hoare)', 'Julian'),
      _meta('select-short', 'SelectSort', 'Sebastian_Marhoff'),
      _meta('communism', 'Communism Sort', 'Julian'),
      _meta('merge-h', 'Merge Sort', 'HiTear'),
      _meta('quick-h', 'Quick Sort', 'HiTear'),
      _meta('insert-h', 'insertion Sort', 'HiTear'),
      _meta('bogo', 'Bogo Sort', 'Julian'),
      _meta('quick-lomuto-i', 'Quick Sort - lomuto', 'Inuh Kang'),
      _meta('bubble-h', 'Bubble Sort', 'HiTear'),
    ];

    expect(
      algorithmsInDisplayOrder(algorithms).map((a) => a.id),
      [
        'bubble-h',
        'bubble-j',
        'insert-h',
        'insert-o',
        'selection-a',
        'select-short',
        'merge-h',
        'merge-try',
        'quick-h',
        'quick-o',
        'quick-hoare',
        'quick-lomuto-i',
        'quick-lomuto-j',
        'bogo',
        'communism',
        'thread',
      ],
    );
  });
}

AlgorithmMeta _meta(String id, String name, String author) => AlgorithmMeta(
  id: id,
  author: author,
  name: name,
  color: '#4488cc',
  className: 'Algorithm$id',
  path: '$author/$id.dart',
  source: '',
);
