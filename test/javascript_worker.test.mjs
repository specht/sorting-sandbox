// JavaScript worker, instrumenter and daemon tests: real processes, the
// host's protocol.   node test/javascript_worker.test.mjs
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

import {benchmarkCopy, checkContract, inspect, parse, staticErrors, visualCopy} from '../languages/javascript/instrument.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const WORKER = join(ROOT, 'languages/javascript/sandbox_worker.mjs');
const DAEMON = join(ROOT, 'languages/javascript/sandbox_daemon.mjs');
const HEADER = 'import { Colors, SortingAlgorithm } from "sorting-sandbox";\n\n';
const TEMPLATE = readFileSync(join(ROOT, 'templates/bubble_sort.js'), 'utf8');
const scratchRoot = mkdtempSync(join(tmpdir(), 'js-worker-test-'));
let next = 0;

let passed = 0;
async function test(name, body) {
  await body();
  passed++;
  console.log(`  ✓ ${name}`);
}

/** Writes both copies like the daemon does; returns the worker directory. */
function build(source) {
  const ast = parse(source);
  const {cls} = checkContract(ast);
  const directory = join(scratchRoot, String(next++));
  spawnSync('mkdir', ['-p', directory]);
  writeFileSync(join(directory, 'algorithm.mjs'), benchmarkCopy(source, ast, cls.id.name));
  writeFileSync(join(directory, 'visual.mjs'), visualCopy(source, ast, cls.id.name));
  return {directory, className: cls.id.name};
}

/** Sends [requests] (advancing visual runs one step at a time) and collects replies. */
function talk(source, requests, {budget = 1} = {}) {
  const {directory, className} = build(source);
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [WORKER, directory, className], {stdio: ['pipe', 'pipe', 'pipe']});
    const replies = [];
    let buffer = '', errors = '';
    let open = requests.length;
    const send = message => child.stdin.write(`${JSON.stringify(message)}\n`);
    child.stderr.on('data', data => { errors += data; });
    child.stdout.on('data', data => {
      buffer += data;
      const lines = buffer.split('\n');
      buffer = lines.pop();
      for (const line of lines) {
        const message = JSON.parse(line);
        replies.push(message);
        if (message.type === 'frame' && !message.done) send({type: 'advance', requestId: message.requestId, budget});
        if (['runResult', 'complete', 'runError', 'error'].includes(message.type) && --open === 0) child.stdin.end();
      }
    });
    child.on('exit', () => (replies[0]?.type === 'hello' ? resolve(replies) : reject(new Error(errors))));
    for (const request of requests) send(request);
  });
}

const run = async (source, values) => (await talk(source, [{type: 'run', requestId: 'r', values}]))
  .find(message => message.type === 'runResult');

async function visual(source, values, budget = 1) {
  const replies = await talk(source, [{type: 'visualStart', requestId: 'v', values}], {budget});
  return {
    frames: replies.filter(message => message.type === 'frame'),
    console: replies.filter(message => message.type === 'console'),
    error: replies.find(message => message.type === 'runError' || message.type === 'error') ?? null,
  };
}

const algorithm = (className, body, extra = '') => `${HEADER}${extra}export default class ${className} extends SortingAlgorithm {
  name = "${className}";
  color = Colors.red;

  sort(list, scratch) {
${body}
  }
}
`;

await test('the template runs step by step, sorts and counts like Dart', async () => {
  const {frames, error} = await visual(TEMPLATE, [3, 1, 2]);
  assert.equal(error, null);
  const last = frames.at(-1);
  assert.equal(last.done, true);
  assert.deepEqual(last.numbers, [1, 2, 3]);
  assert.equal(frames[0].line, 8);
  assert.equal(frames[0].checkpoint, 0);
  assert.ok(frames.some(frame => frame.line === 11), 'the if line');
  assert.equal(frames[3].locals.i, 0);
  assert.equal(frames[3].locals.list, 'Elements(3)');
  assert.equal(last.metrics.comparisons, 6);
});

await test('runs report keys, hidden origins and counts', async () => {
  const result = await run(TEMPLATE, [2, 2, 1]);
  assert.deepEqual(result.keys, [1, 2, 2]);
  assert.deepEqual(result.origins, [2, 0, 1]);
  assert.equal(result.metrics.score, result.metrics.reads + result.metrics.writes + result.metrics.comparisons);
  const many = await talk(TEMPLATE, [
    {type: 'run', requestId: 'a', values: []},
    {type: 'run', requestId: 'b', values: [5, 4, 3, 2, 1]},
  ]);
  assert.deepEqual(many.filter(m => m.type === 'runResult').map(m => m.keys), [[], [1, 2, 3, 4, 5]]);
});

await test('swap counts exactly like a manual swap', async () => {
  const manual = await run(algorithm('Manual', '    const temp = list[1];\n    list[1] = list[0];\n    list[0] = temp;'), [2, 1]);
  const swapped = await run(algorithm('Swap', '    list.swap(0, 1);'), [2, 1]);
  assert.deepEqual(manual.metrics, swapped.metrics);
  assert.equal(manual.metrics.reads, 2);
  assert.equal(manual.metrics.writes, 2);
});

await test('element locals show their hidden key', async () => {
  const {frames} = await visual(algorithm('Peek', '    const first = list[0];\n    const again = first;'), [42, 7]);
  assert.equal(frames.at(-1).locals.first, 42);
});

await test('runtime errors and console output carry source lines', async () => {
  const source = algorithm('OffByOne', [
    '    console.log("start", 1);',
    '    for (let i = 0; i <= list.length; i++) {',
    '      if (list[i].greaterThan(list[0])) list.swap(i, 0);',
    '    }',
  ].join('\n'));
  const {console: output, error, frames} = await visual(source, [2, 1]);
  assert.equal(output[0].text, 'start 1');
  assert.equal(output[0].line, 8);
  assert.equal(error.type, 'runError');
  assert.equal(error.error.line, 10);
  assert.match(error.error.message, /RangeError: Index 2 is out of range/);
  assert.equal(frames.at(-1).done, false);
  const result = await run(source, [2, 1]);
  assert.equal(result.error.line, 10);
  assert.ok(result.error.column > 0);
  assert.ok(result.error.stack.some(frame => frame.endsWith('· line 10')), result.error.stack.join());
});

await test('< on elements, negative indices and wrong values are errors', async () => {
  const compare = await run(algorithm('Compare', '    if (list[0] < list[1]) list.swap(0, 1);'), [2, 1]);
  assert.match(compare.error.message, /lessThan/);
  const negative = await run(algorithm('Negative', '    const x = list[-1];'), [2, 1]);
  assert.match(negative.error.message, /out of range/);
  const number = await run(algorithm('Number', '    list[0] = 5;'), [2, 1]);
  assert.match(number.error.message, /Only Elements can be stored/);
  const mixed = await run(algorithm('Mixed', '    list[0].lessThan(3);'), [2, 1]);
  assert.match(mixed.error.message, /expects another Element/);
});

await test('helpers, recursion, closures and scratch work in the visual copy', async () => {
  const source = `${HEADER}function mergeSort(list, scratch, left, right) {
  if (right - left < 2) return;
  const middle = Math.floor((left + right) / 2);
  mergeSort(list, scratch, left, middle);
  mergeSort(list, scratch, middle, right);
  let i = left, j = middle;
  for (let k = left; k < right; k++) {
    if (i < middle && (j >= right || list[i].lessOrEqual(list[j]))) scratch[k] = list[i++];
    else scratch[k] = list[j++];
  }
  [...Array(right - left).keys()].forEach(offset => { list[left + offset] = scratch[left + offset]; });
}

export default class Merge extends SortingAlgorithm {
  name = "Merge Sort";
  color = Colors.orange;

  sort(list, scratch) {
    mergeSort(list, scratch, 0, list.length);
  }
}
`;
  const {frames, error} = await visual(source, [5, 2, 4, 1, 3]);
  assert.equal(error, null);
  assert.deepEqual(frames.at(-1).numbers, [1, 2, 3, 4, 5]);
  assert.ok(frames.some(frame => frame.line === 13), 'the arrow callback body is traced');
  const result = await run(source, Array.from({length: 300}, (_, i) => 300 - i));
  assert.deepEqual(result.keys, Array.from({length: 300}, (_, i) => i + 1));
});

await test('unusual statement positions keep their meaning and lines', async () => {
  const body = [
    '    "use strict";',
    '    outer: for (let i = 0; i < list.length; i++) {',
    '      for (let j = 0; j < list.length; j++) { if (j > i) continue outer; }',
    '    }',
    '    let n = 0;',
    '    if (n === 1) n = 10; else if (n === 0) n = 20; else n = 30;',
    '    switch (n) { case 20: { let inner = n; n = inner + 1; break; } default: n = -1; }',
    '    do n++; while (n < 25);',
    '    while (n < 30) n++;',
    '    for (const value of [1, 2]) n += value;',
    '    try { list[99]; } catch ({message}) { n = message.length > 0 ? n : -1; }',
    '    console.log(n);',
    '    if (list.length > 1 && list[0].greaterThan(list[1])) list.swap(0, 1);',
  ].join('\n');
  const source = algorithm('Shapes', body);
  const {frames, console: output, error} = await visual(source, [2, 1]);
  assert.equal(error, null, JSON.stringify(error));
  assert.equal(output[0].text, '33');
  assert.deepEqual(frames.at(-1).numbers, [1, 2]);
  const lines = new Set(frames.map(frame => frame.line));
  assert.ok(!lines.has(8), "no checkpoint before a directive");
  for (const line of [9, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20]) assert.ok(lines.has(line), `line ${line}`);
  const ast = parse(source);
  const copy = visualCopy(source, ast, 'Shapes');
  assert.equal(copy.split('\n').length, source.split('\n').length + 2, 'only the export line is added');
  parse(copy);
});

await test('variables that are not initialized yet are simply not shown', async () => {
  const source = algorithm('Later', '    const before = 1;\n    const after = before + 1;');
  const {frames, error} = await visual(source, [1]);
  assert.equal(error, null);
  assert.deepEqual(Object.keys(frames[0].locals).sort(), ['list', 'scratch']);
  assert.equal(frames[1].locals.before, 1);
  assert.equal(frames[1].locals.after, undefined);
});

await test('deep recursion works and endless recursion is a stack overflow', async () => {
  const deep = algorithm('Deep', '    const down = n => (n === 0 ? 0 : down(n - 1));\n    down(list.length);');
  assert.deepEqual((await run(deep, new Array(3000).fill(0))).keys, new Array(3000).fill(0));
  const endless = algorithm('Endless', '    const down = n => down(n - 1);\n    down(1);');
  assert.equal((await run(endless, [1])).error.kind, 'stackOverflow');
});

await test('stability is visible through origins', async () => {
  const selection = algorithm('Selection', [
    '    for (let i = 0; i < list.length; i++) {',
    '      let smallest = i;',
    '      for (let j = i + 1; j < list.length; j++) if (list[j].lessThan(list[smallest])) smallest = j;',
    '      if (smallest !== i) list.swap(i, smallest);',
    '    }',
  ].join('\n'));
  const result = await run(selection, [2, 2, 1]);
  assert.deepEqual(result.keys, [1, 2, 2]);
  assert.deepEqual(result.origins, [2, 1, 0]);
});

await test('a failing module reports its error on every request', async () => {
  const source = `${HEADER}const broken = null.value;\n${algorithm('Broken', '').slice(HEADER.length)}`;
  const result = await run(source, [1]);
  assert.match(result.error.message, /TypeError/);
  assert.equal(result.error.line, 3);
});

// -------------------------------------------------------------- the daemon

await test('the contract: metadata and its problems', () => {
  const ok = inspect(TEMPLATE).result;
  assert.deepEqual(ok, {ok: true, meta: {name: 'Bubble Sort', color: '#4CAF50', className: 'BubbleSort'}, diagnostics: []});
  const base = algorithm('A', '');
  assert.equal(inspect(base.replace('Colors.red', '"#12abef"')).result.meta.color, '#12ABEF');
  assert.equal(inspect(base.replace('  name = "A";', '  name = "A";\n  author = "Anna";')).result.meta.author, 'Anna');
  assert.equal(inspect(base.replace('  name = "A";', '  get name() { return "Getter"; }')).result.meta.name, 'Getter');
  const cases = {
    syntax: [base.replace('sort(list, scratch) {', 'sort(list, scratch {'), 'Unexpected', 7],
    'no class': [`${HEADER}const x = 1;\n`, 'No class extending SortingAlgorithm'],
    'two classes': [`${base}class B extends SortingAlgorithm {}\n`, 'exactly one class'],
    nested: [`${base}function f() { return class C extends SortingAlgorithm {}; }\n`, 'top level'],
    'no name': [base.replace('  name = "A";\n', ''), 'literal name'],
    'computed name': [base.replace('name = "A"', 'name = "A" + 1'), 'literal name'],
    'bad color': [base.replace('Colors.red', 'Colors.mauve'), 'color'],
    'no sort': [base.replace('sort(list, scratch)', 'sorted(list, scratch)'), 'Missing method'],
    parameters: [base.replace('sort(list, scratch)', 'sort(list)'), 'exactly two'],
    async: [base.replace('sort(list, scratch)', 'async sort(list, scratch)'), 'synchronous'],
    imports: [`import x from "./helper.js";\n${base}`, 'can be imported'],
  };
  for (const [label, [source, message, line]] of Object.entries(cases)) {
    const result = inspect(source).result;
    assert.equal(result.ok, false, label);
    assert.ok(result.diagnostics[0].message.includes(message), `${label}: ${result.diagnostics[0].message}`);
    if (line) assert.equal(result.diagnostics[0].line, line, label);
  }
});

await test('undefined names are build errors with their line', () => {
  const source = algorithm('Typo', '    list.swap(0, lenght);\n    if (typeof window === "undefined") Math.max(1, 2);');
  const errors = staticErrors(parse(source));
  assert.equal(errors.length, 1);
  assert.equal(errors[0].line, 8);
  assert.match(errors[0].message, /lenght is not defined/);
  assert.deepEqual(staticErrors(parse(TEMPLATE)), []);
});

await test('the daemon checks, builds and formats', async () => {
  const daemon = spawn(process.execPath, [DAEMON], {stdio: ['pipe', 'pipe', 'inherit']});
  const replies = [];
  let buffer = '';
  const waiting = new Map();
  daemon.stdout.on('data', data => {
    buffer += data;
    const lines = buffer.split('\n');
    buffer = lines.pop();
    for (const line of lines) {
      const reply = JSON.parse(line);
      replies.push(reply);
      waiting.get(reply.id)?.(reply);
    }
  });
  let id = 0;
  const request = (op, content, extra = {}) => new Promise(resolve => {
    waiting.set(++id, resolve);
    daemon.stdin.write(`${JSON.stringify({id, op, path: 'x.js', content, ...extra})}\n`);
  });
  const out = join(scratchRoot, 'daemon');
  const built = await request('instrument', TEMPLATE, {out});
  assert.equal(built.ok, true);
  assert.ok(readFileSync(join(out, 'visual.mjs'), 'utf8').includes('__sandbox.cp('));
  const empty = readFileSync(join(ROOT, 'templates/empty.js.tmpl'), 'utf8')
    .replace('@@CLASS@@', 'QuickSort').replace('@@NAME@@', 'Quick Sort');
  assert.equal((await request('instrument', empty, {out})).meta.name, 'Quick Sort');
  const typo = await request('instrument', algorithm('Typo', '    lenght;'), {out});
  assert.equal(typo.ok, false);
  assert.equal(typo.diagnostics[0].line, 8);
  const formatted = await request('format', 'function f(a){if(a){return 1}else{return [1,2 ,3]}}\n');
  assert.equal(formatted.content, 'function f(a) {\n  if (a) {\n    return 1\n  } else {\n    return [1, 2, 3]\n  }\n}\n');
  const broken = await request('format', 'function f(:) {}\n');
  assert.equal(broken.ok, false);
  assert.match(broken.error, /line 1/);
  assert.equal(replies[0].type, 'ready');
  daemon.stdin.end();
});

rmSync(scratchRoot, {recursive: true, force: true});
console.log(`${passed} JavaScript worker tests passed.`);
