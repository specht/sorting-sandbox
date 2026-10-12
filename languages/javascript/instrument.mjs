// Parser-based checks and the two generated copies of a JavaScript algorithm.
//
//   algorithm.mjs  the student's source, byte-identical except that the
//                  `sorting-sandbox` import points at the sandbox runtime and
//                  one export line is appended (benchmark runs)
//   visual.mjs     the same plus a checkpoint before every statement
//                  (visual runs)
//
// Insertions never contain line breaks, so the line numbers of both copies are
// the student's own. Uses the vendored acorn and eslint-scope.
import {pathToFileURL} from 'node:url';
import {realpathSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

import * as acorn from '../../vendor/javascript/acorn/index.js';
import * as walk from '../../vendor/javascript/acorn-walk/index.js';
import * as eslintScope from '../../vendor/javascript/eslint-scope/index.js';

export const API_MODULE = 'sorting-sandbox';
export const EXPORT_NAME = '__sandboxAlgorithm';
export const CHECKPOINT = '__sandbox';

const HERE = fileURLToPath(new URL('.', import.meta.url));
export const RUNTIME_URL = pathToFileURL(realpathSync(`${HERE}sorting-sandbox.mjs`)).href;

export const PALETTE = {
  red: '#F44336', pink: '#E91E63', purple: '#9C27B0', deepPurple: '#673AB7',
  indigo: '#3F51B5', blue: '#2196F3', lightBlue: '#03A9F4', cyan: '#00BCD4',
  teal: '#009688', green: '#4CAF50', lightGreen: '#8BC34A', lime: '#CDDC39',
  yellow: '#FFEB3B', amber: '#FFC107', orange: '#FF9800', deepOrange: '#FF5722',
  brown: '#795548', blueGrey: '#607D8B',
};

export class Problem extends Error {
  constructor(node, message, length) {
    super(message);
    this.node = node;
    this.length = length;
  }
}

export function diagnostic(line, column, length, message) {
  return {
    line: Math.max(1, line || 1),
    column: Math.max(1, column || 1),
    length: Math.max(1, Math.min(40, length || 1)),
    message,
    severity: 'error',
  };
}

function nodeDiagnostic(node, message, length) {
  if (!node) return diagnostic(1, 1, 1, message);
  const {start, end} = node.loc;
  const span = length ?? (end.line === start.line ? end.column - start.column : 5);
  return diagnostic(start.line, start.column + 1, span, message);
}

export function parse(source) {
  return acorn.parse(source, {
    ecmaVersion: 'latest',
    sourceType: 'module',
    locations: true,
    ranges: true,
    allowHashBang: true,
  });
}

function syntaxDiagnostic(error) {
  const message = String(error.message).replace(/\s*\(\d+:\d+\)$/, '');
  if (error.loc) return diagnostic(error.loc.line, error.loc.column + 1, 1, message);
  return diagnostic(1, 1, 1, message);
}

// ------------------------------------------------------------ the contract

const isAlgorithmClass = node =>
  node && (node.type === 'ClassDeclaration' || node.type === 'ClassExpression') &&
  node.superClass &&
  ((node.superClass.type === 'Identifier' && node.superClass.name === 'SortingAlgorithm') ||
   (node.superClass.type === 'MemberExpression' && !node.superClass.computed &&
    node.superClass.property.name === 'SortingAlgorithm'));

const keyName = member =>
  member.computed ? null
    : member.key.type === 'Identifier' ? member.key.name
    : member.key.type === 'Literal' ? String(member.key.value)
    : null;

/** `name = "…"` or `get name() { return "…"; }`: the value expression. */
function memberValue(cls, name) {
  for (const member of cls.body.body) {
    if (member.static || keyName(member) !== name) continue;
    if (member.type === 'PropertyDefinition') return {member, value: member.value};
    if (member.type === 'MethodDefinition' && member.kind === 'get') {
      const body = member.value.body.body;
      const returned = body.find(statement => statement.type === 'ReturnStatement');
      return {member, value: returned?.argument ?? null};
    }
  }
  return {member: null, value: null};
}

const literalString = value =>
  value?.type === 'Literal' && typeof value.value === 'string' ? value.value
    : value?.type === 'TemplateLiteral' && value.expressions.length === 0
      ? value.quasis[0].value.cooked : null;

function colorOf(value) {
  const text = literalString(value);
  if (text !== null) return /^#[0-9a-fA-F]{6}$/.test(text) ? text : null;
  if (value?.type === 'MemberExpression' && !value.computed &&
      value.object.type === 'Identifier' && value.object.name === 'Colors') {
    return PALETTE[value.property.name] ?? null;
  }
  return null;
}

/** The single top-level algorithm class with its metadata; throws Problem. */
export function checkContract(ast) {
  const classes = [];
  for (const statement of ast.body) {
    const declaration = statement.type === 'ExportDefaultDeclaration' ||
        statement.type === 'ExportNamedDeclaration' ? statement.declaration : statement;
    if (isAlgorithmClass(declaration)) classes.push(declaration);
  }
  walk.full(ast, node => {
    if (isAlgorithmClass(node) && !classes.includes(node)) {
      throw new Problem(node, 'The class that extends SortingAlgorithm must be declared at the top ' +
        'level of the file.', 5);
    }
  });
  for (const statement of ast.body) {
    if (statement.type !== 'ImportDeclaration') continue;
    const source = statement.source.value;
    if (source !== API_MODULE && !String(source).startsWith('node:')) {
      throw new Problem(statement.source, `Only "${API_MODULE}" and Node built-ins ("node:…") can ` +
        'be imported: the sandbox runs a copy of this file.');
    }
  }
  if (classes.length === 0) {
    throw new Problem(null, 'No class extending SortingAlgorithm found. Start with: ' +
      'class MySort extends SortingAlgorithm { … }');
  }
  if (classes.length > 1) {
    throw new Problem(classes[1], 'One file must contain exactly one class that extends SortingAlgorithm.', 5);
  }
  const cls = classes[0];
  if (!cls.id) throw new Problem(cls, 'Give the class a name, e.g. class BubbleSort extends SortingAlgorithm.', 5);

  const sort = cls.body.body.find(member => member.type === 'MethodDefinition' &&
    member.kind === 'method' && !member.static && keyName(member) === 'sort');
  if (!sort) throw new Problem(cls, 'Missing method: sort(list, scratch) { … }', 5);
  if (sort.value.async || sort.value.generator) {
    throw new Problem(sort.key, 'sort must stay synchronous; remove async or *.');
  }
  if (sort.value.params.length !== 2 || sort.value.params.some(param => param.type !== 'Identifier')) {
    throw new Problem(sort.key, 'sort must take exactly two parameters: sort(list, scratch).');
  }

  const name = memberValue(cls, 'name');
  const nameText = literalString(name.value);
  if (nameText === null || !nameText.trim()) {
    throw new Problem(name.member ?? cls, 'Give the algorithm a literal name, e.g. name = "Bubble Sort";',
      name.member ? undefined : 5);
  }
  const author = memberValue(cls, 'author');
  let authorText = null;
  if (author.member) {
    authorText = literalString(author.value);
    if (authorText === null || !authorText.trim()) {
      throw new Problem(author.member, 'Use a literal author, e.g. author = "Anna"; or remove it.');
    }
  }
  const color = memberValue(cls, 'color');
  const colorText = color.value ? colorOf(color.value) : null;
  if (colorText === null) {
    throw new Problem(color.member ?? cls, 'Choose a color: color = Colors.green; or a hex color such ' +
      'as "#4CAF50".', color.member ? undefined : 5);
  }
  const meta = {name: nameText.trim(), color: colorText.toUpperCase(), className: cls.id.name};
  if (authorText !== null) meta.author = authorText.trim();
  return {meta, cls};
}

export function inspect(source) {
  let ast;
  try {
    ast = parse(source);
  } catch (error) {
    if (error instanceof SyntaxError) return {ast: null, result: {ok: false, diagnostics: [syntaxDiagnostic(error)]}};
    throw error;
  }
  try {
    const {meta} = checkContract(ast);
    return {ast, result: {ok: true, meta, diagnostics: []}};
  } catch (error) {
    if (!(error instanceof Problem)) throw error;
    return {ast, result: {ok: false, diagnostics: [nodeDiagnostic(error.node, error.message, error.length)]}};
  }
}

// ---------------------------------------------------- build-time checks

const KNOWN_GLOBALS = new Set([
  ...Object.getOwnPropertyNames(globalThis),
  'console', 'process', 'Buffer', 'globalThis', 'undefined', 'NaN', 'Infinity',
]);

/** Names that are used but never declared (typos like `lenght`). */
export function staticErrors(ast) {
  const manager = eslintScope.analyze(ast, {ecmaVersion: 2022, sourceType: 'module'});
  const typeofArguments = new Set();
  walk.full(ast, node => {
    if (node.type === 'UnaryExpression' && node.operator === 'typeof' && node.argument.type === 'Identifier') {
      typeofArguments.add(node.argument);
    }
  });
  const result = [];
  const seen = new Set();
  for (const reference of manager.globalScope.through) {
    const identifier = reference.identifier;
    if (KNOWN_GLOBALS.has(identifier.name) || typeofArguments.has(identifier)) continue;
    const at = `${identifier.loc.start.line}:${identifier.loc.start.column}`;
    if (seen.has(at)) continue;
    seen.add(at);
    result.push(diagnostic(identifier.loc.start.line, identifier.loc.start.column + 1,
      identifier.name.length, `${identifier.name} is not defined.`));
    if (result.length >= 30) break;
  }
  return result;
}

// ------------------------------------------------------- generated copies

function applyEdits(source, edits) {
  // Stable: equal offsets keep their insertion order.
  const ordered = edits.map((edit, order) => ({...edit, order}))
    .sort((a, b) => b.at - a.at || b.order - a.order);
  let out = source;
  for (const edit of ordered) out = out.slice(0, edit.at) + edit.text + out.slice(edit.at + (edit.remove ?? 0));
  return out;
}

function importEdits(ast) {
  const edits = [];
  for (const statement of ast.body) {
    if (statement.type === 'ImportDeclaration' && statement.source.value === API_MODULE) {
      const literal = statement.source;
      edits.push({at: literal.start, remove: literal.end - literal.start, text: JSON.stringify(RUNTIME_URL)});
    }
  }
  return edits;
}

const exportLine = className => `\nexport { ${className} as ${EXPORT_NAME} };\n`;

/** The benchmark copy: same lines, runtime import, export appended. */
export function benchmarkCopy(source, ast, className) {
  return applyEdits(source, importEdits(ast)) + exportLine(className);
}

const FUNCTION_TYPES = new Set(['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression']);
const LOOP_TYPES = new Set(['ForStatement', 'ForInStatement', 'ForOfStatement', 'WhileStatement', 'DoWhileStatement']);

function patternNames(pattern, out) {
  if (!pattern) return out;
  switch (pattern.type) {
    case 'Identifier': out.push(pattern.name); break;
    case 'ObjectPattern':
      for (const property of pattern.properties) {
        patternNames(property.type === 'RestElement' ? property.argument : property.value, out);
      }
      break;
    case 'ArrayPattern': for (const element of pattern.elements) patternNames(element, out); break;
    case 'RestElement': patternNames(pattern.argument, out); break;
    case 'AssignmentPattern': patternNames(pattern.left, out); break;
  }
  return out;
}

function declaredNames(statement, out) {
  if (statement.type === 'VariableDeclaration') {
    for (const declarator of statement.declarations) patternNames(declarator.id, out);
  } else if ((statement.type === 'FunctionDeclaration' || statement.type === 'ClassDeclaration') && statement.id) {
    out.push(statement.id.name);
  }
  return out;
}

/** `var` declarations of a function body before [position], at any depth. */
function hoistedVars(body, position) {
  const out = [];
  walk.recursive(body, null, {
    Function() {}, // Nested functions have their own vars.
    VariableDeclaration(node, state, c) {
      if (node.kind === 'var' && node.start < position) declaredNames(node, out);
      for (const declarator of node.declarations) if (declarator.init) c(declarator.init, state);
    },
  });
  return out;
}

/**
 * Locals that can be shown at [statement]: parameters, loop variables and
 * declarations that come before it, up to the enclosing function. Reading
 * them is wrapped in try/catch by the runtime, so a variable that is not
 * initialized yet (temporal dead zone) is simply left out.
 */
function visibleNames(ancestors, statement) {
  const names = [];
  for (let i = ancestors.length - 1; i >= 0; i--) {
    const node = ancestors[i];
    if (node.type === 'BlockStatement' || node.type === 'StaticBlock') {
      for (const child of node.body) {
        if (child.start >= statement.start) break;
        declaredNames(child, names);
      }
    } else if (node.type === 'SwitchCase') {
      // Declarations of all cases share one scope.
      const switchNode = ancestors[i - 1];
      for (const switchCase of switchNode.cases) {
        for (const child of switchCase.consequent) {
          if (child.start >= statement.start) break;
          declaredNames(child, names);
        }
      }
    } else if ((node.type === 'ForStatement' && node.init?.type === 'VariableDeclaration') ) {
      if (node.init !== statement) declaredNames(node.init, names);
    } else if ((node.type === 'ForInStatement' || node.type === 'ForOfStatement') &&
        node.left.type === 'VariableDeclaration') {
      declaredNames(node.left, names);
    } else if (node.type === 'CatchClause' && node.param) {
      patternNames(node.param, names);
    } else if (FUNCTION_TYPES.has(node.type)) {
      for (const param of node.params) patternNames(param, names);
      if (node.body.type === 'BlockStatement') names.push(...hoistedVars(node.body, statement.start));
      break;
    }
  }
  return [...new Set(names)].filter(name => !name.startsWith(CHECKPOINT) && name !== 'arguments');
}

function checkpoint(statement, names) {
  const getters = names.map(name => `[${JSON.stringify(name)}, () => ${name}]`).join(', ');
  return `${CHECKPOINT}.cp(${statement.loc.start.line}, () => [${getters}]); `;
}

const isDirective = statement => statement.type === 'ExpressionStatement' && statement.directive !== undefined;

/** The visual copy: a checkpoint before every statement inside functions. */
export function visualCopy(source, ast, className) {
  const edits = importEdits(ast);
  const ancestors = [];
  let functionDepth = 0;

  const before = (statement, wrap) => {
    const names = visibleNames(ancestors, statement);
    if (wrap) {
      edits.push({at: statement.start, text: `{ ${checkpoint(statement, names)}`});
      edits.push({at: statement.end, text: ' }'});
    } else {
      edits.push({at: statement.start, text: checkpoint(statement, names)});
    }
  };

  // A statement in a position where a single statement is allowed (if, loop
  // bodies): it gets braces around its checkpoint. Labeled statements are
  // never wrapped, or `continue label` would break.
  const single = (statement) => {
    if (!statement || functionDepth === 0) return;
    if (statement.type === 'BlockStatement' || statement.type === 'LabeledStatement') return;
    before(statement, true);
  };

  const visit = (node, parent) => {
    if (!node || typeof node.type !== 'string') return;
    ancestors.push(node);
    const isFunction = FUNCTION_TYPES.has(node.type);
    if (isFunction) functionDepth++;

    if (functionDepth > 0) {
      if (node.type === 'BlockStatement' || node.type === 'StaticBlock') {
        let prologue = node === parent?.body && FUNCTION_TYPES.has(parent.type);
        for (const statement of node.body) {
          if (prologue && isDirective(statement)) continue;
          prologue = false;
          before(statement, false);
        }
      } else if (node.type === 'SwitchCase') {
        for (const statement of node.consequent) before(statement, false);
      } else if (node.type === 'IfStatement') {
        single(node.consequent);
        single(node.alternate);
      } else if (LOOP_TYPES.has(node.type)) {
        single(node.body);
      }
    }

    for (const [field, value] of Object.entries(node)) {
      if (field === 'loc' || field === 'range' || field === 'start' || field === 'end') continue;
      if (Array.isArray(value)) {
        for (const child of value) if (child && typeof child.type === 'string') visit(child, node);
      } else if (value && typeof value.type === 'string') {
        visit(value, node);
      }
    }

    if (isFunction) functionDepth--;
    ancestors.pop();
  };
  visit(ast, null);
  return applyEdits(source, edits) + exportLine(className);
}
