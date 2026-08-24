import 'package:flutter_test/flutter_test.dart';
import 'package:sorting_sandbox/widgets/dart_syntax.dart';

void main() {
  test('highlighting preserves source text exactly', () {
    const source = '''import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

class BubbleSort extends SortingAlgorithm {
  @override
  void sort(Elements list, Elements scratch) {
    for (int i = 0; i < 12; i++) { // pass
      if (list[i] > list[i + 1]) list.swap(i, i + 1);
    }
  }
}''';

    final lines = highlightDartSource(source);

    expect(
      lines.map((line) => line.map((token) => token.text).join()).join('\n'),
      source,
    );
    expect(_kindFor(lines, 'import'), DartSyntaxKind.keyword);
    expect(_kindFor(lines, 'BubbleSort'), DartSyntaxKind.type);
    expect(_kindFor(lines, 'SortingAlgorithm'), DartSyntaxKind.type);
    expect(_kindFor(lines, 'Elements'), DartSyntaxKind.type);
    expect(_kindFor(lines, '12'), DartSyntaxKind.number);
    expect(_kindFor(lines, '@override'), DartSyntaxKind.annotation);
    expect(_kindFor(lines, '// pass'), DartSyntaxKind.comment);
  });

  test('multiline comments and strings keep their lexical style', () {
    const source = '''/* first
   second /* nested */ third */
final message = r\'''line one
line two\''';''';

    final lines = highlightDartSource(source);

    expect(lines, hasLength(4));
    expect(lines[0].single.kind, DartSyntaxKind.comment);
    expect(lines[1].single.kind, DartSyntaxKind.comment);
    expect(_kindFor(lines, "r'''line one"), DartSyntaxKind.string);
    expect(_kindFor(lines, "line two'''"), DartSyntaxKind.string);
  });

  test('hex, decimal and exponent numbers are highlighted', () {
    const source = 'var values = [0x2A, 3.14, 6e2];';
    final lines = highlightDartSource(source);

    expect(_kindFor(lines, '0x2A'), DartSyntaxKind.number);
    expect(_kindFor(lines, '3.14'), DartSyntaxKind.number);
    expect(_kindFor(lines, '6e2'), DartSyntaxKind.number);
  });
}

DartSyntaxKind? _kindFor(List<List<DartSyntaxToken>> lines, String text) {
  for (final line in lines) {
    for (final token in line) {
      if (token.text == text) return token.kind;
    }
  }
  return null;
}
