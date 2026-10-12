import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

class InstrumentationResult {
  InstrumentationResult({required this.source, required this.errors});

  final String source;
  final List<String> errors;
}

/// Creates the asynchronous "visual" copy of a student algorithm.
///
/// Methods and functions become `async`, calls of local helpers are awaited
/// and a checkpoint is inserted before every statement. The transformation
/// never inserts line breaks: line N of the generated copy is line N of the
/// student's file, so compiler errors, stack traces and highlighted source
/// lines can be reported against the original source.
class VisualInstrumenter {
  InstrumentationResult instrument(String source, {required String path}) {
    final parsed = parseString(
      content: source,
      path: path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) {
      return InstrumentationResult(
        source: source,
        errors: parsed.errors.map((e) => e.toString()).toList(),
      );
    }

    final unit = parsed.unit;
    final callableNames = <String>{};
    unit.accept(_CallableCollector(callableNames));

    final edits = <_Edit>[];
    // A prefixed import cannot clash with any name the student declares.
    final importOffset = unit.directives.isEmpty ? 0 : unit.directives.last.end;
    edits.add(_Edit.insert(
      importOffset,
      unit.directives.isEmpty
          ? "import 'package:sorting_sandbox/sandbox_worker_runtime.dart' "
              'as __sandbox; '
          : " import 'package:sorting_sandbox/sandbox_worker_runtime.dart' "
              'as __sandbox;',
      order: 0,
    ));

    unit.accept(_AsyncTransformer(callableNames, edits));
    unit.accept(_CheckpointCollector(parsed.lineInfo, edits));

    try {
      return InstrumentationResult(
        source: _applyEdits(source, edits),
        errors: const [],
      );
    } catch (error) {
      return InstrumentationResult(source: source, errors: [error.toString()]);
    }
  }
}

class _CallableCollector extends RecursiveAstVisitor<void> {
  _CallableCollector(this.names);
  final Set<String> names;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (_convertibleMethod(node)) names.add(node.name.lexeme);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (!node.isGetter && !node.isSetter) names.add(node.name.lexeme);
    super.visitFunctionDeclaration(node);
  }
}

class _AsyncTransformer extends RecursiveAstVisitor<void> {
  _AsyncTransformer(this.callableNames, this.edits);

  final Set<String> callableNames;
  final List<_Edit> edits;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (_convertibleMethod(node)) {
      _makeAsync(node.returnType, node.name.offset, node.body);
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (!node.isGetter &&
        !node.isSetter &&
        _insideConvertibleExecutable(node.functionExpression.body)) {
      _makeAsync(
        node.returnType,
        node.name.offset,
        node.functionExpression.body,
      );
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    // Only calls with no receiver (helper()) or an explicit `this` receiver
    // can refer to methods/functions that this transformer has made async.
    // In particular, never turn list.swap(...) into `await list.swap(...)`
    // merely because a student also happens to have a helper named `swap`.
    final target = node.target;
    final localCall = target == null || target is ThisExpression;
    if (localCall &&
        callableNames.contains(node.methodName.name) &&
        node.thisOrAncestorOfType<AwaitExpression>() == null &&
        _insideConvertibleExecutable(node)) {
      // Parenthesized, so `helper().x` and `helper()[i]` keep their meaning.
      edits.add(_Edit.insert(node.offset, '(await ', order: 20));
      edits.add(_Edit.insert(node.end, ')', order: 0));
    }
    super.visitMethodInvocation(node);
  }

  void _makeAsync(
    TypeAnnotation? returnType,
    int nameOffset,
    FunctionBody body,
  ) {
    if (body is EmptyFunctionBody) return;
    if (body.keyword != null) return; // Already async/sync*: leave it alone.

    if (returnType != null) {
      final original = returnType.toSource();
      edits.add(_Edit.replace(
        returnType.offset,
        returnType.length,
        'Future<$original>',
      ));
    } else {
      edits.add(_Edit.insert(nameOffset, 'Future<dynamic> ', order: 10));
    }
    edits.add(_Edit.insert(body.offset, 'async ', order: 10));
  }
}

class _CheckpointCollector extends RecursiveAstVisitor<void> {
  _CheckpointCollector(this.lineInfo, this.edits);

  final LineInfo lineInfo;
  final List<_Edit> edits;

  @override
  void visitBlock(Block node) {
    if (_insideConvertibleExecutable(node)) {
      for (final statement in node.statements) {
        final line = lineInfo.getLocation(statement.offset).lineNumber;
        final variables = _visibleVariablesAt(statement);
        edits.add(_Edit.insert(
          statement.offset,
          _checkpoint(line, variables),
          order: 0,
        ));
      }

      if (node.statements.isEmpty && _isLoopBody(node)) {
        final line = lineInfo.getLocation(node.offset).lineNumber;
        edits.add(_Edit.insert(
          node.leftBracket.end,
          _checkpoint(line, _visibleVariablesAt(node)),
          order: 0,
        ));
      }
    }
    super.visitBlock(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    if (node.body is! Block && _insideConvertibleExecutable(node)) {
      _wrapLoopBody(node.body);
    }
    super.visitForStatement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    if (node.body is! Block && _insideConvertibleExecutable(node)) {
      _wrapLoopBody(node.body);
    }
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    if (node.body is! Block && _insideConvertibleExecutable(node)) {
      _wrapLoopBody(node.body);
    }
    super.visitDoStatement(node);
  }

  void _wrapLoopBody(Statement body) {
    final line = lineInfo.getLocation(body.offset).lineNumber;
    final cp = _checkpoint(line, _visibleVariablesAt(body));
    edits.add(_Edit.insert(body.offset, '{$cp', order: -10));
    edits.add(_Edit.insert(body.end, '}', order: 100));
  }

  String _checkpoint(int line, List<String> variables) {
    final filtered =
        variables.where((v) => v != 'list' && v != 'scratch').toList();
    final entries = filtered.map((v) => "'$v': $v").join(', ');
    // A trailing space, never a newline: generated line N == student line N.
    return 'await __sandbox.sandboxCheckpoint($line, {$entries}); ';
  }
}

/// Members of Object keep their synchronous signatures (an async toString()
/// would no longer override Object.toString).
const _objectMembers = {'toString', 'noSuchMethod'};

bool _convertibleMethod(MethodDeclaration node) =>
    !node.isGetter &&
    !node.isSetter &&
    !node.isOperator &&
    // Abstract (and external) methods have no body to convert. Not
    // `isAbstract`, which newer analyzer versions deprecate.
    node.body is! EmptyFunctionBody &&
    !_objectMembers.contains(node.name.lexeme);

bool _insideConvertibleExecutable(AstNode node) {
  // Closures stay synchronous; they cannot contain `await`.
  final closure = node.thisOrAncestorOfType<FunctionExpression>();
  if (closure != null && closure.parent is! FunctionDeclaration) return false;
  final method = node.thisOrAncestorOfType<MethodDeclaration>();
  if (method != null) return _convertibleMethod(method);
  final function = node.thisOrAncestorOfType<FunctionDeclaration>();
  if (function != null) return !function.isGetter && !function.isSetter;
  return false;
}

bool _isLoopBody(Block node) {
  final parent = node.parent;
  return (parent is ForStatement && identical(parent.body, node)) ||
      (parent is WhileStatement && identical(parent.body, node)) ||
      (parent is DoStatement && identical(parent.body, node));
}

/// Locals that can be read safely at [node]: a checkpoint must never read a
/// `late`, final-without-initializer or non-nullable unassigned variable.
List<String> _visibleVariablesAt(AstNode node) {
  final result = <String>[];
  final seen = <String>{};

  void add(String? name) {
    if (name != null && name.isNotEmpty && seen.add(name)) result.add(name);
  }

  AstNode? current = node;
  while (current != null) {
    if (current is Block) {
      for (final statement in current.statements) {
        if (statement.offset >= node.offset) break;
        if (statement is VariableDeclarationStatement) {
          final list = statement.variables;
          for (final variable in list.variables) {
            if (_safeToRead(list, variable)) add(variable.name.lexeme);
          }
        }
      }
    }

    if (current is ForStatement && !identical(current, node)) {
      final parts = current.forLoopParts;
      if (parts is ForPartsWithDeclarations) {
        final list = parts.variables;
        for (final variable in list.variables) {
          if (_safeToRead(list, variable)) add(variable.name.lexeme);
        }
      }
    }

    if (current is MethodDeclaration) {
      for (final parameter
          in current.parameters?.parameters ?? const <FormalParameter>[]) {
        add(parameter.name?.lexeme);
      }
      break;
    }

    if (current is FunctionDeclaration) {
      for (final parameter
          in current.functionExpression.parameters?.parameters ??
              const <FormalParameter>[]) {
        add(parameter.name?.lexeme);
      }
      break;
    }

    current = current.parent;
  }

  return result;
}

bool _safeToRead(VariableDeclarationList list, VariableDeclaration variable) {
  if (list.isLate) return false;
  if (variable.initializer != null) return true;
  if (list.isFinal || list.isConst) return false;
  final type = list.type;
  return type == null || type.question != null;
}

class _Edit {
  _Edit(this.offset, this.length, this.text, this.order);

  factory _Edit.insert(int offset, String text, {int order = 0}) =>
      _Edit(offset, 0, text, order);

  factory _Edit.replace(int offset, int length, String text) =>
      _Edit(offset, length, text, 0);

  final int offset;
  final int length;
  final String text;
  final int order;
}

String _applyEdits(String source, List<_Edit> edits) {
  final replacements = edits.where((e) => e.length > 0).toList()
    ..sort((a, b) => b.offset.compareTo(a.offset));
  final inserts = <int, List<_Edit>>{};
  for (final edit in edits.where((e) => e.length == 0)) {
    inserts.putIfAbsent(edit.offset, () => []).add(edit);
  }

  final allOffsets = <int>{
    ...replacements.map((e) => e.offset),
    ...inserts.keys,
  }.toList()
    ..sort((a, b) => b.compareTo(a));

  var out = source;
  for (final offset in allOffsets) {
    final replacementAtOffset =
        replacements.where((e) => e.offset == offset).toList();
    if (replacementAtOffset.length > 1) {
      throw StateError('Overlapping replacements at $offset');
    }
    if (replacementAtOffset.isNotEmpty) {
      final edit = replacementAtOffset.single;
      out = out.replaceRange(edit.offset, edit.offset + edit.length, edit.text);
    }
    final here = inserts[offset];
    if (here != null) {
      here.sort((a, b) => a.order.compareTo(b.order));
      final text = here.map((e) => e.text).join();
      out = out.replaceRange(offset, offset, text);
    }
  }
  return out;
}
