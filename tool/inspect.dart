// Syntax and classroom-contract checks for one student algorithm file.
//
// Only the parser is used here (no type analysis), so this is fast enough to
// run on every save. Each problem carries an editor position in the
// student's ORIGINAL file.
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

class AlgorithmMeta {
  AlgorithmMeta({
    required this.name,
    required this.color,
    required this.className,
    this.author,
  });

  final String name;
  final String color;
  final String className;

  /// Optional `get author => '...'`; otherwise the student directory name.
  final String? author;

  Map<String, Object?> toJson() => {
    'name': name,
    'color': color,
    'className': className,
    if (author != null) 'author': author,
  };

  static AlgorithmMeta? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], color = json['color'], className = json['className'];
    if (name is! String || color is! String || className is! String) return null;
    final author = json['author'];
    return AlgorithmMeta(
      name: name,
      color: color,
      className: className,
      author: author is String ? author : null,
    );
  }
}

class InspectResult {
  InspectResult({this.meta, this.diagnostics = const []});

  final AlgorithmMeta? meta;
  final List<Map<String, Object?>> diagnostics;

  bool get ok => meta != null && diagnostics.isEmpty;

  Map<String, Object?> toJson() => {
    'ok': ok,
    if (meta != null) 'meta': meta!.toJson(),
    'diagnostics': diagnostics,
  };
}

InspectResult inspectAlgorithm(String content, {required String path}) {
  final parsed = parseString(
    content: content,
    path: path,
    throwIfDiagnostics: false,
  );
  final lineInfo = parsed.lineInfo;
  if (parsed.errors.isNotEmpty) {
    return InspectResult(diagnostics: [
      for (final error in parsed.errors.take(30))
        _diagnostic(lineInfo, error.offset, error.length, error.message),
    ]);
  }

  InspectResult problem(int offset, int length, String message) =>
      InspectResult(diagnostics: [_diagnostic(lineInfo, offset, length, message)]);

  ClassDeclaration? algorithmClass;
  for (final declaration
      in parsed.unit.declarations.whereType<ClassDeclaration>()) {
    if (declaration.extendsClause?.superclass.toSource() == 'SortingAlgorithm') {
      if (algorithmClass != null) {
        return problem(declaration.offset, 5,
            'One file must contain exactly one class that extends SortingAlgorithm.');
      }
      algorithmClass = declaration;
    }
  }
  if (algorithmClass == null) {
    return problem(0, 1,
        'No class extending SortingAlgorithm found. Start with: '
        'class MySort extends SortingAlgorithm { … }');
  }

  final classOffset = algorithmClass.offset;
  String? name;
  String? author;
  var hasAuthorGetter = false;
  String? color;
  MethodDeclaration? nameGetter, colorGetter, authorGetter, sortMethod;
  for (final member in algorithmClass.body.members.whereType<MethodDeclaration>()) {
    final memberName = member.name.lexeme;
    if (memberName == 'sort' && !member.isGetter) sortMethod = member;
    if (member.isGetter && memberName == 'name') {
      nameGetter = member;
      name = _literalGetter(member);
    }
    if (member.isGetter && memberName == 'author') {
      hasAuthorGetter = true;
      authorGetter = member;
      author = _literalGetter(member);
    }
    if (member.isGetter && memberName == 'color') {
      colorGetter = member;
      color = _colorGetter(member);
    }
  }

  if (sortMethod == null) {
    return problem(classOffset, 5,
        'Missing method: void sort(Elements list, Elements scratch) { … }');
  }
  final sortParameters = sortMethod.parameters;
  final parameterSource = sortParameters?.toSource() ?? '';
  if (sortParameters == null ||
      sortParameters.parameters.length != 2 ||
      parameterSource.contains('{') ||
      parameterSource.contains('[')) {
    return problem(sortMethod.name.offset, sortMethod.name.length,
        'sort must take exactly two positional parameters: '
        'sort(Elements list, Elements scratch).');
  }
  if (sortMethod.body.keyword != null) {
    return problem(sortMethod.body.offset, sortMethod.body.keyword!.length,
        'sort must stay synchronous; remove async, sync* or async*.');
  }
  if (name == null || name.trim().isEmpty) {
    final at = nameGetter ?? algorithmClass;
    return problem(at.offset, nameGetter == null ? 5 : _span(at.length),
        "Give the algorithm a literal name, e.g. get name => 'Bubble Sort';");
  }
  if (hasAuthorGetter && (author == null || author.trim().isEmpty)) {
    final at = authorGetter!;
    return problem(at.offset, _span(at.length),
        "Use a literal author, e.g. get author => 'Anna'; or remove the getter.");
  }
  if (color == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
    final at = colorGetter ?? algorithmClass;
    return problem(at.offset, colorGetter == null ? 5 : _span(at.length),
        "Choose a color: get color => Colors.green; or a hex color such as '#4CAF50'.");
  }

  return InspectResult(
    meta: AlgorithmMeta(
      name: name.trim(),
      color: color.toUpperCase(),
      className: _className(algorithmClass),
      author: author?.trim(),
    ),
  );
}

Map<String, Object?> _diagnostic(
  LineInfo lineInfo,
  int offset,
  int length,
  String message,
) {
  final location = lineInfo.getLocation(offset);
  return {
    'line': location.lineNumber,
    'column': location.columnNumber,
    'length': length < 1 ? 1 : length,
    'message': message,
    'severity': 'error',
  };
}

int _span(int length) => length < 1 ? 1 : (length > 40 ? 40 : length);

String _className(ClassDeclaration declaration) {
  // Primary constructors are not part of the classroom API. Reading the first
  // identifier from namePart keeps this compatible with both ordinary class
  // declarations and newer grammar additions.
  final text = declaration.namePart.toSource();
  final match = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*').firstMatch(text);
  return match?.group(0) ?? text;
}

String? _colorGetter(MethodDeclaration method) {
  final expression = _returnedExpression(method);
  if (expression is StringLiteral) return expression.stringValue;
  if (expression is PrefixedIdentifier && expression.prefix.name == 'Colors') {
    return palette[expression.identifier.name];
  }
  return null;
}

String? _literalGetter(MethodDeclaration method) {
  final expression = _returnedExpression(method);
  return expression is StringLiteral ? expression.stringValue : null;
}

Expression? _returnedExpression(MethodDeclaration method) {
  final body = method.body;
  if (body is ExpressionFunctionBody) return body.expression;
  if (body is BlockFunctionBody) {
    for (final statement in body.block.statements) {
      if (statement is ReturnStatement) return statement.expression;
    }
  }
  return null;
}

/// Mirrors `Colors` in package:sorting_sandbox_api.
const palette = <String, String>{
  'red': '#F44336',
  'pink': '#E91E63',
  'purple': '#9C27B0',
  'deepPurple': '#673AB7',
  'indigo': '#3F51B5',
  'blue': '#2196F3',
  'lightBlue': '#03A9F4',
  'cyan': '#00BCD4',
  'teal': '#009688',
  'green': '#4CAF50',
  'lightGreen': '#8BC34A',
  'lime': '#CDDC39',
  'yellow': '#FFEB3B',
  'amber': '#FFC107',
  'orange': '#FF9800',
  'deepOrange': '#FF5722',
  'brown': '#795548',
  'blueGrey': '#607D8B',
};
