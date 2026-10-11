import '../tool/inspect.dart';
import 'harness.dart';

String algorithm({
  String name = "get name => 'Quick Sort';",
  String color = 'get color => Colors.red;',
  String extra = '',
  String sort = 'void sort(Elements list, Elements scratch) {}',
}) => '''
import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

class QuickSort extends SortingAlgorithm {
  $name
  $color
  $extra
  $sort
}
''';

void main() {
  test('metadata is read from literal getters and the palette', () {
    final result = inspectAlgorithm(algorithm(), path: 'q.dart');
    expect(result.ok, isTrue);
    expect(result.meta!.name, 'Quick Sort');
    expect(result.meta!.color, '#F44336');
    expect(result.meta!.className, 'QuickSort');
    expect(result.meta!.author, null);
  });

  test('hex colors and an optional author are accepted', () {
    final result = inspectAlgorithm(
      algorithm(color: "get color => '#4caf50';", extra: "get author => 'Anna';"),
      path: 'q.dart',
    );
    expect(result.ok, isTrue);
    expect(result.meta!.color, '#4CAF50');
    expect(result.meta!.author, 'Anna');
  });

  test('a syntax error gives an editor position', () {
    final result = inspectAlgorithm(
      algorithm(name: "get name => 'Quick Sort'"),
      path: 'q.dart',
    );
    expect(result.ok, isFalse);
    expect(result.diagnostics.isNotEmpty, isTrue);
    expect(result.diagnostics.first['line'], 4);
  });

  test('classroom contract problems point at the offending line', () {
    final missingSort = inspectAlgorithm(algorithm(sort: ''), path: 'q.dart');
    expectContains(missingSort.diagnostics.single['message'].toString(), 'Missing method');
    expect(missingSort.diagnostics.single['line'], 3);

    final asyncSort = inspectAlgorithm(
      algorithm(sort: 'void sort(Elements list, Elements scratch) async {}'),
      path: 'q.dart',
    );
    expectContains(asyncSort.diagnostics.single['message'].toString(), 'synchronous');
    expect(asyncSort.diagnostics.single['line'], 7);

    final badColor = inspectAlgorithm(
      algorithm(color: "get color => 'green';"),
      path: 'q.dart',
    );
    expectContains(badColor.diagnostics.single['message'].toString(), 'color');
    expect(badColor.diagnostics.single['line'], 5);
    expect(badColor.meta, null);
  });

  test('a file without a SortingAlgorithm class is rejected', () {
    final result = inspectAlgorithm('void main() {}', path: 'x.dart');
    expect(result.ok, isFalse);
    expectContains(result.diagnostics.single['message'].toString(), 'SortingAlgorithm');
  });
}
