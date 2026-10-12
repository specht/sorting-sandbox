// Keeps the JavaScript parser and formatter loaded between edits.
//
// One JSON request and one JSON reply per line, the same protocol as
// tool/instrument_daemon.dart. This process never executes student code;
// algorithms run in separate, killable worker processes (sandbox_worker.mjs).
//
//   {"id": 1, "op": "inspect",    "path": "...", "content": "..."}
//   {"id": 2, "op": "instrument", "path": "...", "content": "...", "out": "DIR"}
//   {"id": 3, "op": "format",     "path": "...", "content": "..."}
//
// `inspect` is parser-only (every save). `instrument` is the build step: the
// contract, undefined names, and the two copies algorithm.mjs and visual.mjs
// written into `out`.
import {createRequire} from 'node:module';
import {mkdirSync, writeFileSync} from 'node:fs';
import {createInterface} from 'node:readline';

import {benchmarkCopy, checkContract, inspect, parse, staticErrors, visualCopy} from './instrument.mjs';

const require = createRequire(import.meta.url);
let beautify = null;

function instrument(content, out) {
  const {ast, result} = inspect(content);
  if (!result.ok) {
    return {...result, error: 'Fix the marked problem in your JavaScript source and save again.'};
  }
  const errors = staticErrors(ast);
  if (errors.length) {
    return {
      ok: false,
      meta: result.meta,
      error: 'Fix the errors in your JavaScript source and save again.',
      diagnostics: errors,
    };
  }
  const {cls} = checkContract(ast);
  mkdirSync(out, {recursive: true});
  writeFileSync(`${out}/algorithm.mjs`, benchmarkCopy(content, ast, cls.id.name));
  writeFileSync(`${out}/visual.mjs`, visualCopy(content, ast, cls.id.name));
  return result;
}

function format(content) {
  try {
    parse(content);
  } catch (error) {
    const where = error.loc ? `line ${error.loc.line}: ` : '';
    return {ok: false, error: `JavaScript could not format this draft: ${where}${error.message.replace(/\s*\(\d+:\d+\)$/, '')}.`};
  }
  beautify ??= require('../../vendor/javascript/js-beautify/javascript/index.js');
  let formatted = beautify(content, {
    indent_size: 2,
    end_with_newline: true,
    preserve_newlines: true,
    max_preserve_newlines: 2,
    space_after_anon_function: false,
    brace_style: 'collapse',
  });
  if (!formatted.endsWith('\n')) formatted += '\n';
  return {ok: true, content: formatted};
}

function handle(request) {
  const {op, content, path} = request;
  if (typeof content !== 'string' || typeof path !== 'string') throw new Error('Invalid request.');
  switch (op) {
    case 'inspect': return inspect(content).result;
    case 'instrument':
      if (typeof request.out !== 'string') throw new Error('Missing output directory.');
      return instrument(content, request.out);
    case 'format': return format(content);
    default: throw new Error(`Unknown operation: ${op}`);
  }
}

// Nothing but replies on the protocol channel.
const reply = message => process.stdout.write(`${JSON.stringify(message)}\n`);
console.log = console.info = console.warn = console.debug = (...args) => console.error(...args);

reply({type: 'ready', pid: process.pid});
const lines = createInterface({input: process.stdin, crlfDelay: Infinity});
lines.on('line', line => {
  if (!line.trim()) return;
  let id = null;
  let answer;
  try {
    const request = JSON.parse(line);
    if (!request || typeof request !== 'object' || !Number.isInteger(request.id)) throw new Error('Invalid request.');
    id = request.id;
    answer = handle(request);
  } catch (error) {
    answer = {ok: false, error: String(error?.message ?? error)};
  }
  reply({id, ...answer});
});
