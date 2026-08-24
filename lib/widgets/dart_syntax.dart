import 'package:flutter/material.dart';

enum DartSyntaxKind { plain, keyword, type, string, comment, number, annotation }

class DartSyntaxToken {
  const DartSyntaxToken(this.text, this.kind);

  final String text;
  final DartSyntaxKind kind;
}

const _keywords = <String>{
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'when',
  'while',
  'with',
  'yield',
};

const _builtInTypes = <String>{
  'bool',
  'double',
  'dynamic',
  'Function',
  'int',
  'Never',
  'num',
  'Object',
  'Record',
  'String',
  'void',
};

List<List<DartSyntaxToken>> highlightDartSource(String source) {
  final lines = <List<DartSyntaxToken>>[<DartSyntaxToken>[]];

  void emit(String text, DartSyntaxKind kind) {
    if (text.isEmpty) return;
    var start = 0;
    while (true) {
      final newline = text.indexOf('\n', start);
      if (newline < 0) {
        final tail = text.substring(start);
        if (tail.isNotEmpty) lines.last.add(DartSyntaxToken(tail, kind));
        return;
      }
      final before = text.substring(start, newline);
      if (before.isNotEmpty) lines.last.add(DartSyntaxToken(before, kind));
      lines.add(<DartSyntaxToken>[]);
      start = newline + 1;
    }
  }

  var index = 0;
  while (index < source.length) {
    final start = index;
    final char = source[index];

    if (_startsWith(source, index, '//')) {
      final newline = source.indexOf('\n', index + 2);
      index = newline < 0 ? source.length : newline;
      emit(source.substring(start, index), DartSyntaxKind.comment);
      continue;
    }

    if (_startsWith(source, index, '/*')) {
      var depth = 1;
      index += 2;
      while (index < source.length && depth > 0) {
        if (_startsWith(source, index, '/*')) {
          depth++;
          index += 2;
        } else if (_startsWith(source, index, '*/')) {
          depth--;
          index += 2;
        } else {
          index++;
        }
      }
      emit(source.substring(start, index), DartSyntaxKind.comment);
      continue;
    }

    final rawString = (char == 'r' || char == 'R') &&
        index + 1 < source.length &&
        (source[index + 1] == "'" || source[index + 1] == '"');
    if (rawString || char == "'" || char == '"') {
      final quoteIndex = rawString ? index + 1 : index;
      final quote = source[quoteIndex];
      final triple = quoteIndex + 2 < source.length &&
          source[quoteIndex + 1] == quote &&
          source[quoteIndex + 2] == quote;
      final delimiterLength = triple ? 3 : 1;
      final raw = rawString;
      index = quoteIndex + delimiterLength;
      while (index < source.length) {
        if (!raw && source[index] == '\\') {
          index += index + 1 < source.length ? 2 : 1;
          continue;
        }
        if (triple) {
          if (index + 2 < source.length &&
              source[index] == quote &&
              source[index + 1] == quote &&
              source[index + 2] == quote) {
            index += 3;
            break;
          }
        } else if (source[index] == quote) {
          index++;
          break;
        } else if (source[index] == '\n') {
          break;
        }
        index++;
      }
      emit(source.substring(start, index), DartSyntaxKind.string);
      continue;
    }

    if (char == '@' &&
        index + 1 < source.length &&
        _isIdentifierStart(source[index + 1])) {
      index += 2;
      while (index < source.length && _isIdentifierPart(source[index])) {
        index++;
      }
      emit(source.substring(start, index), DartSyntaxKind.annotation);
      continue;
    }

    if (_isDigit(char)) {
      index = _scanNumber(source, index);
      emit(source.substring(start, index), DartSyntaxKind.number);
      continue;
    }

    if (_isIdentifierStart(char)) {
      index++;
      while (index < source.length && _isIdentifierPart(source[index])) {
        index++;
      }
      final identifier = source.substring(start, index);
      final kind = _keywords.contains(identifier)
          ? DartSyntaxKind.keyword
          : (_builtInTypes.contains(identifier) ||
                _looksLikeType(identifier))
          ? DartSyntaxKind.type
          : DartSyntaxKind.plain;
      emit(identifier, kind);
      continue;
    }

    index++;
    while (index < source.length &&
        !_beginsSpecialToken(source, index)) {
      index++;
    }
    emit(source.substring(start, index), DartSyntaxKind.plain);
  }

  return lines;
}

TextStyle syntaxStyle(DartSyntaxKind kind, ColorScheme scheme) {
  final color = switch (kind) {
    DartSyntaxKind.keyword => const Color(0xFF569CD6),
    DartSyntaxKind.type => const Color(0xFF4EC9B0),
    DartSyntaxKind.string => const Color(0xFFCE9178),
    DartSyntaxKind.comment => const Color(0xFF6A9955),
    DartSyntaxKind.number => const Color(0xFFB5CEA8),
    DartSyntaxKind.annotation => const Color(0xFFDCDCAA),
    DartSyntaxKind.plain => scheme.onSurface,
  };
  return TextStyle(color: color);
}

bool _startsWith(String source, int index, String needle) =>
    index + needle.length <= source.length &&
    source.substring(index, index + needle.length) == needle;

bool _beginsSpecialToken(String source, int index) {
  final char = source[index];
  if (_isIdentifierStart(char) || _isDigit(char)) return true;
  if (char == "'" || char == '"' || char == '@') return true;
  return _startsWith(source, index, '//') ||
      _startsWith(source, index, '/*');
}

bool _isIdentifierStart(String char) {
  final code = char.codeUnitAt(0);
  return char == '_' ||
      char == r'$' ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122);
}

bool _isIdentifierPart(String char) =>
    _isIdentifierStart(char) || _isDigit(char);

bool _isDigit(String char) {
  final code = char.codeUnitAt(0);
  return code >= 48 && code <= 57;
}

bool _looksLikeType(String identifier) {
  if (identifier.isEmpty) return false;
  final code = identifier.codeUnitAt(0);
  return code >= 65 && code <= 90;
}

int _scanNumber(String source, int index) {
  if (index + 1 < source.length &&
      source[index] == '0' &&
      (source[index + 1] == 'x' || source[index + 1] == 'X')) {
    index += 2;
    while (index < source.length && _isHexDigit(source[index])) index++;
    return index;
  }

  while (index < source.length && _isDigit(source[index])) index++;
  if (index + 1 < source.length &&
      source[index] == '.' &&
      _isDigit(source[index + 1])) {
    index++;
    while (index < source.length && _isDigit(source[index])) index++;
  }
  if (index < source.length &&
      (source[index] == 'e' || source[index] == 'E')) {
    var cursor = index + 1;
    if (cursor < source.length &&
        (source[cursor] == '+' || source[cursor] == '-')) {
      cursor++;
    }
    final digitsStart = cursor;
    while (cursor < source.length && _isDigit(source[cursor])) cursor++;
    if (cursor > digitsStart) index = cursor;
  }
  return index;
}

bool _isHexDigit(String char) {
  final code = char.codeUnitAt(0);
  return _isDigit(char) ||
      (code >= 65 && code <= 70) ||
      (code >= 97 && code <= 102);
}
