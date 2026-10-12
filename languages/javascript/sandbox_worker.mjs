// Worker process for one JavaScript sorting algorithm (one revision of one
// file). Started by the host as
//
//   node sandbox_worker.mjs WORKER_DIRECTORY CLASS_NAME
//
// where the directory holds algorithm.mjs and visual.mjs written by
// sandbox_daemon.mjs. It speaks the protocol of the Dart worker
// (lib/worker_core.dart), one JSON object per line:
//
//   visualStart {requestId, values}  run visual.mjs; one frame whenever the
//                                    budget is used up, then wait for `advance`
//   advance     {requestId, budget}  grant more checkpoints to the visual run
//   run         {requestId, values}  sort once with algorithm.mjs (no checkpoints)
//
// Replies: hello, frame, console, complete, runError, runResult, error.
//
// Student code is synchronous, so the worker is too: a checkpoint simply
// blocks on reading stdin until the host grants more budget. Stop kills the
// process.
import {readSync, writeSync} from 'node:fs';
import {StringDecoder} from 'node:string_decoder';
import {format, inspect} from 'node:util';
import {pathToFileURL} from 'node:url';

import {Element, Elements, Probe, key, keys, makeLists, origins} from './sorting-sandbox.mjs';

const MAX_PRINTS = 200;
const MAX_PRINT_CHARACTERS = 65536;
const EXPORT_NAME = '__sandboxAlgorithm';

Error.stackTraceLimit = 60;

// ---------------------------------------------------------------- protocol

const sleeper = new Int32Array(new SharedArrayBuffer(4));
const sleep = milliseconds => Atomics.wait(sleeper, 0, 0, milliseconds);

function writeAll(text) {
  const bytes = Buffer.from(text, 'utf8');
  let offset = 0;
  while (offset < bytes.length) {
    try {
      offset += writeSync(1, bytes, offset, bytes.length - offset);
    } catch (error) {
      if (error.code !== 'EAGAIN') throw error;
      sleep(2);
    }
  }
}

function post(message) {
  let encoded;
  try {
    encoded = JSON.stringify(message);
  } catch (error) {
    encoded = JSON.stringify({type: 'error', requestId: String(message.requestId ?? ''),
      message: `Could not encode a worker message: ${error.message}`});
  }
  writeAll(`${encoded}\n`);
}

const decoder = new StringDecoder('utf8');
const chunk = Buffer.alloc(65536);
let pending = '';

/** The next line from the host, or null when the host closed the pipe. */
function readLine() {
  for (;;) {
    const newline = pending.indexOf('\n');
    if (newline >= 0) {
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      return line;
    }
    let count;
    try {
      count = readSync(0, chunk, 0, chunk.length, null);
    } catch (error) {
      if (error.code === 'EAGAIN') {
        sleep(2);
        continue;
      }
      if (error.code === 'EOF') return null;
      throw error;
    }
    if (count === 0) return null;
    pending += decoder.write(chunk.subarray(0, count));
  }
}

function exit() {
  // A suspended visual run must not keep the process alive.
  process.exit(0);
}

// ---------------------------------------------------------------- failures

const FRAME = /\(?(file:\/\/\S*\/(algorithm|visual)\.mjs):(\d+):(\d+)\)?$/;
const FUNCTION = /^at\s+(?:async\s+)?(.+?)\s+\(/;

/** An exception as {kind, message, line?, column?, stack?} in student lines. */
function describeFailure(error, line) {
  const stack = typeof error?.stack === 'string' ? error.stack.split('\n') : [];
  let firstLine = null;
  let column = null;
  const frames = [];
  for (const raw of stack.slice(0, 400)) {
    const frame = raw.trim();
    const match = FRAME.exec(frame);
    if (!match) continue;
    const frameLine = Number(match[3]);
    if (firstLine === null) {
      firstLine = frameLine;
      // Visual copies insert code into lines; only benchmark columns are exact.
      if (match[2] === 'algorithm') column = Number(match[4]);
    }
    if (frames.length < 8) {
      const name = FUNCTION.exec(frame)?.[1]?.replace(/^Object\./, '') ?? 'student code';
      frames.push(`${name} · line ${frameLine}`);
    }
  }
  let message = error instanceof Error ? `${error.name}: ${error.message}` : `Uncaught ${inspect(error)}`;
  if (message.length > 1500) message = `${message.slice(0, 1500)}…`;
  const overflow = error instanceof RangeError && /call stack size/i.test(error.message);
  const result = {kind: overflow ? 'stackOverflow' : 'runtime', message};
  const resolved = firstLine ?? (line > 0 ? line : null);
  if (resolved !== null) result.line = resolved;
  if (column !== null) result.column = column;
  if (frames.length) result.stack = frames;
  return result;
}

// ------------------------------------------------------------- student code

const [directory, className] = process.argv.slice(2);
if (!directory || !className) {
  process.stderr.write('usage: sandbox_worker.mjs WORKER_DIRECTORY CLASS_NAME\n');
  process.exit(64);
}

/** Loaded lazily: a broken module is reported on every request instead. */
const modules = {};
async function load(name) {
  if (name in modules) return modules[name];
  try {
    const module = await import(pathToFileURL(`${directory}/${name}.mjs`).href);
    const cls = module[EXPORT_NAME];
    if (typeof cls !== 'function') throw new Error(`The class ${className} was not found.`);
    modules[name] = {cls};
  } catch (error) {
    modules[name] = {error: describeFailure(error)};
  }
  return modules[name];
}

// Student output: console.* and process.stdout.write become console messages
// (visual runs) or are discarded (single sorts). The protocol uses fd 1 directly.
let output = null;
const studentConsole = (...args) => output?.(format(...args));
for (const method of ['log', 'info', 'warn', 'error', 'debug', 'trace']) console[method] = studentConsole;
process.stdout.write = (text) => {
  output?.(String(text).replace(/\n$/, ''));
  return true;
};

// --------------------------------------------------------------- visual runs

const shorten = text => (text.length <= 48 ? text : `${text.slice(0, 45)}…`);

function debugValue(value) {
  if (value === null || value === undefined || typeof value === 'boolean') return value ?? null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : String(value);
  if (typeof value === 'bigint') return shorten(String(value));
  if (typeof value === 'string') return shorten(value);
  if (value instanceof Element) return key(value);
  if (value instanceof Elements) return `Elements(${value.length})`;
  if (Array.isArray(value)) return `Array(${value.length})`;
  if (typeof value === 'function') return undefined;
  return shorten(inspect(value, {depth: 0, breakLength: Infinity}));
}

class VisualSession {
  constructor(requestId) {
    this.requestId = requestId;
    this.probe = new Probe(true);
    this.list = null;
    this.scratch = null;
    this.budget = 0;
    this.line = 0;
    this.checkpoint = -1;
    this.locals = null;
    this.printed = 0;
    this.characters = 0;
    this.truncated = false;
  }

  /** Called before every statement of the visual copy. */
  cp(line, locals) {
    this.checkpoint++;
    this.line = line;
    this.locals = locals;
    if (this.budget > 0) {
      this.budget--;
      if (this.budget > 0) {
        // A coarse animation frame skips many checkpoints; memory highlighting
        // describes only the final step, as in Dart.
        this.probe.discardMarkers();
        return;
      }
    }
    this.emit(false);
    this.wait();
  }

  wait() {
    while (this.budget <= 0) {
      const raw = readLine();
      if (raw === null) exit();
      let message;
      try {
        message = JSON.parse(raw);
      } catch {
        post({type: 'error', message: 'Invalid worker request.'});
        continue;
      }
      if (message?.type === 'advance') {
        const budget = Number(message.budget ?? 1);
        if (Number.isFinite(budget) && budget > 0) this.budget += Math.floor(budget);
      } else if (message) {
        post({type: 'error', requestId: String(message.requestId ?? ''),
          message: 'This worker is busy with a visual run.'});
      }
    }
  }

  visibleLocals() {
    const result = {};
    if (!this.locals) return result;
    let entries = [];
    try {
      entries = this.locals();
    } catch {
      return result;
    }
    for (const [name, read] of entries) {
      try {
        const value = debugValue(read());
        if (value !== undefined) result[name] = value;
      } catch {
        // Not initialized yet (temporal dead zone): not shown.
      }
    }
    return result;
  }

  emit(done) {
    post({
      type: 'frame',
      requestId: this.requestId,
      done,
      line: this.line,
      checkpoint: this.checkpoint,
      locals: this.visibleLocals(),
      numbers: this.list ? keys(this.list) : [],
      scratch: this.scratch ? keys(this.scratch) : [],
      metrics: this.probe.metrics(),
      reads: this.probe.takeReads(),
      writes: this.probe.takeWrites(),
    });
  }

  print(text) {
    let kind = 'stdout';
    if (this.printed < MAX_PRINTS && this.characters + text.length <= MAX_PRINT_CHARACTERS) {
      this.printed++;
      this.characters += text.length;
    } else if (!this.truncated) {
      this.truncated = true;
      kind = 'warning';
      text = 'Further print output was truncated.';
    } else {
      return;
    }
    const message = {type: 'console', requestId: this.requestId, kind, text, checkpoint: this.checkpoint};
    if (this.line > 0) message.line = this.line;
    post(message);
  }

  run(module, values) {
    [this.list, this.scratch] = makeLists(this.probe, values);
    if (module.error) {
      post({type: 'runError', requestId: this.requestId, checkpoint: this.checkpoint, error: module.error});
      return;
    }
    globalThis.__sandbox = this;
    output = text => {
      for (const line of text.split('\n')) this.print(line);
    };
    try {
      const algorithm = new module.cls();
      algorithm.sort(this.list, this.scratch);
    } catch (error) {
      output = null;
      this.emit(false);
      post({type: 'runError', requestId: this.requestId, checkpoint: this.checkpoint,
        error: describeFailure(error, this.line)});
      return;
    }
    output = null;
    this.emit(true);
    post({type: 'complete', requestId: this.requestId});
  }
}

// Benchmark copies contain no checkpoints, but a visual copy loaded earlier
// must never find a missing session.
globalThis.__sandbox = {cp() {}};

// ------------------------------------------------------------ single sorts

function runCase(module, values) {
  if (module.error) return {error: module.error};
  const probe = new Probe(false);
  const [list, scratch] = makeLists(probe, values);
  output = null;
  try {
    new module.cls().sort(list, scratch);
  } catch (error) {
    return {error: describeFailure(error)};
  }
  return {keys: keys(list), origins: origins(list), metrics: probe.metrics()};
}

// ------------------------------------------------------------------- main

const intList = raw => (Array.isArray(raw)
  ? raw.filter(value => typeof value === 'number' && Number.isFinite(value)).map(Math.trunc) : []);

const benchmark = await load('algorithm');
let visualUsed = false;
post({type: 'hello', pid: process.pid});
for (;;) {
  const raw = readLine();
  if (raw === null) break;
  if (!raw.trim()) continue;
  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    post({type: 'error', message: 'Invalid worker request.'});
    continue;
  }
  if (!message || typeof message !== 'object') continue;
  const requestId = String(message.requestId ?? '');
  try {
    switch (message.type) {
      case 'run':
        post({type: 'runResult', requestId, ...runCase(benchmark, intList(message.values))});
        break;
      case 'visualStart': {
        if (visualUsed) throw new Error('This worker has already run a visual algorithm.');
        visualUsed = true;
        const visual = await load('visual');
        new VisualSession(requestId).run(visual, intList(message.values));
        break;
      }
      case 'advance':
        break; // Only meaningful while a visual run waits.
      default:
        post({type: 'error', requestId, message: `Unknown worker message: ${message.type}`});
    }
  } catch (error) {
    post({type: 'error', requestId, message: String(error?.message ?? error), error: describeFailure(error)});
  }
}
exit();
