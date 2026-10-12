// What the browser needs to know about each student language: the editor
// mode, indentation, line comments and completion words. A file's language
// comes from the catalog (`algorithm.language`), which derives it from the
// file extension. DOM-free, so it is unit-tested with node.

const DART_KEYWORDS = ['abstract', 'as', 'assert', 'bool', 'break', 'case', 'class', 'const',
  'continue', 'do', 'double', 'dynamic', 'else', 'extends', 'false', 'final', 'for',
  'if', 'import', 'in', 'int', 'is', 'late', 'List', 'null', 'return', 'static',
  'String', 'super', 'switch', 'this', 'throw', 'true', 'var', 'void', 'while',
  // Sorting Sandbox API
  'Elements', 'Element', 'SortingAlgorithm', 'Colors', 'length', 'swap', 'scratch'];

const PYTHON_KEYWORDS = ['and', 'as', 'assert', 'break', 'class', 'continue', 'def', 'del',
  'elif', 'else', 'except', 'False', 'finally', 'for', 'from', 'if', 'import', 'in', 'is',
  'lambda', 'None', 'not', 'or', 'pass', 'print', 'raise', 'range', 'return', 'self',
  'True', 'try', 'while', 'with', 'len', 'int', 'list', 'min', 'max',
  // Sorting Sandbox API
  'Elements', 'Element', 'SortingAlgorithm', 'Colors', 'swap', 'scratch', 'elements'];

const JAVASCRIPT_KEYWORDS = ['break', 'case', 'catch', 'class', 'const', 'continue', 'default',
  'do', 'else', 'export', 'extends', 'false', 'finally', 'for', 'function', 'if', 'import',
  'in', 'let', 'new', 'null', 'of', 'return', 'static', 'super', 'switch', 'this', 'throw',
  'true', 'try', 'typeof', 'undefined', 'while', 'console', 'Math',
  // Sorting Sandbox API
  'Elements', 'Element', 'SortingAlgorithm', 'Colors', 'length', 'swap', 'scratch',
  'lessThan', 'lessOrEqual', 'greaterThan', 'greaterOrEqual', 'equalTo'];

const JAVA_KEYWORDS = ['boolean', 'break', 'case', 'catch', 'class', 'continue', 'default',
  'do', 'double', 'else', 'extends', 'false', 'final', 'finally', 'for', 'if', 'import', 'int',
  'long', 'new', 'null', 'private', 'public', 'return', 'static', 'String', 'super', 'switch',
  'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'System', 'Math',
  // Sorting Sandbox API
  'Elements', 'Element', 'SortingAlgorithm', 'Colors', 'length', 'get', 'set', 'swap', 'scratch',
  'lessThan', 'lessOrEqual', 'greaterThan', 'greaterOrEqual', 'equalTo'];

export const LANGUAGES = {
  dart: {id: 'dart', label: 'Dart', extension: '.dart', mode: 'dart', indent: 2, comment: '//',
    keywords: DART_KEYWORDS},
  python: {id: 'python', label: 'Python', extension: '.py', mode: 'python', indent: 4, comment: '#',
    keywords: PYTHON_KEYWORDS},
  javascript: {id: 'javascript', label: 'JavaScript', extension: '.js', mode: 'javascript', indent: 2,
    comment: '//', keywords: JAVASCRIPT_KEYWORDS},
  java: {id: 'java', label: 'Java', extension: '.java', mode: 'text/x-java', indent: 4, comment: '//',
    keywords: JAVA_KEYWORDS},
};

/** The language of a catalog entry (Dart for entries of older hosts). */
export function languageOf(algorithm) {
  return LANGUAGES[algorithm?.language] ?? LANGUAGES.dart;
}

/** `alice/quick_sort.py` → `quick_sort` (any known extension). */
export function fileStem(path) {
  const name = String(path ?? '').split('/').pop();
  for (const language of Object.values(LANGUAGES)) {
    if (name.endsWith(language.extension)) return name.slice(0, -language.extension.length);
  }
  return name;
}

/**
 * Toggles line comments for [lines] (`{text, indent}` of the non-empty lines):
 * returns the edits as `{index, from, to, insert}` in characters of each line.
 * All lines commented → uncomment them, otherwise comment all.
 */
export function commentEdits(lines, comment) {
  const prefix = `${comment} `;
  const uncomment = lines.length > 0 && lines.every(({text, indent}) => text.slice(indent).startsWith(comment));
  return lines.map(({text, indent}, index) => {
    if (!uncomment) return {index, from: indent, to: indent, insert: prefix};
    const rest = text.slice(indent);
    return {index, from: indent, to: indent + (rest.startsWith(prefix) ? prefix.length : comment.length), insert: ''};
  });
}
