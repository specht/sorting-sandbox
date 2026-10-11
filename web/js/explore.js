// Explore: run one algorithm step by step. The browser never pre-records the
// execution; it keeps a sparse cache of recent frames and replays a fresh
// worker to reach any earlier step exactly.
import {$, el, icon, compactCount, groupedCount, INPUT_SHAPES, makeInput, savePreferences,
  formatList} from './util.js';
import {AlgorithmPicker, isBusy} from './catalog.js';
import {ArrayCanvas} from './bars.js';

export const EXPLORE_SIZES = [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768,
  1024, 1536, 2048, 3072, 4096];
// Twenty-one speed levels: checkpoints per frame and delay between frames.
export const BUDGETS = [1, 1, 1, 2, 2, 3, 3, 4, 5, 7, 10, 14, 20, 30, 45, 67, 100, 178, 316, 562, 1000];
export const DELAYS = [220, 202, 185, 168, 150, 135, 120, 105, 90, 80, 70, 60, 50, 42, 35, 28, 20,
  15, 10, 5, 0];

let runCounter = 0;
let jobCounter = 0;

export class ExploreView {
  constructor({connection, catalog, editor, preferences}) {
    this.connection = connection;
    this.catalog = catalog;
    this.editor = editor;
    this.active = true;

    this.algorithmId = null;
    this.n = EXPLORE_SIZES.includes(preferences.exploreSize) ? preferences.exploreSize : 48;
    this.shape = INPUT_SHAPES.some(s => s.id === preferences.exploreShape) ? preferences.exploreShape : 'random';
    this.speed = Number.isInteger(preferences.exploreSpeed) ? Math.max(0, Math.min(20, preferences.exploreSpeed)) : 8;
    this.showAccess = preferences.exploreShowAccess === true;
    this.preferredId = typeof preferences.exploreAlgorithm === 'string' ? preferences.exploreAlgorithm : null;
    this.seed = Math.floor(Math.random() * 100000);
    this.input = [];

    this.runId = null;
    this.runRevision = null;
    this.running = false;
    this.paused = false;
    this.starting = null; // 'building' | 'starting'
    this.atCheckpoint = false;
    this.error = null;
    this.advanceTimer = null;
    this.clearHistory();
    this.resetFrameState();

    this.console = [];
    this.consoleHighWater = -1;
    this.consoleExpanded = false;
    this.checks = new Map(); // `${id}@${revision}` -> check result
    this.checkJob = null;
    this.checkNote = null;
    this.statusOverride = null;
    this.workerCheckpoint = -1;

    this.list = new ArrayCanvas($('list-canvas'), {pointerGutter: true});
    this.scratchCanvas = new ArrayCanvas($('scratch-canvas'), {pointerGutter: false});
    this.picker = new AlgorithmPicker($('explore-picker'), catalog, {onSelect: id => this.select(id)});
    this.bindControls();
    this.bindMessages();
    this.newInput();
  }

  // ------------------------------------------------------------------ setup

  bindControls() {
    const shape = $('explore-shape');
    shape.replaceChildren(...INPUT_SHAPES.map(s => el('option', {value: s.id}, s.label)));
    shape.value = this.shape;
    shape.addEventListener('change', () => {
      this.shape = shape.value;
      savePreferences({exploreShape: this.shape});
      this.newInput();
    });
    const size = $('explore-size');
    size.max = String(EXPLORE_SIZES.length - 1);
    size.value = String(EXPLORE_SIZES.indexOf(this.n));
    size.addEventListener('input', () => {
      this.n = EXPLORE_SIZES[Number(size.value)];
      savePreferences({exploreSize: this.n});
      this.newInput();
    });
    $('explore-shuffle').addEventListener('click', () => this.newInput());
    const speed = $('speed');
    speed.value = String(this.speed);
    speed.addEventListener('input', () => {
      this.speed = Number(speed.value);
      savePreferences({exploreSpeed: this.speed});
      this.renderControls();
    });
    const access = $('show-access');
    access.checked = this.showAccess;
    access.addEventListener('change', () => {
      this.showAccess = access.checked;
      savePreferences({exploreShowAccess: this.showAccess});
      this.render();
    });
    $('play').addEventListener('click', () => this.togglePause());
    $('step-back').addEventListener('click', () => this.stepBack());
    $('step-next').addEventListener('click', () => this.stepForward());
    $('stop').addEventListener('click', () => {
      this.stop();
      this.render();
    });
    const scrubber = $('scrubber');
    scrubber.addEventListener('input', () => this.previewScrub(Number(scrubber.value)));
    scrubber.addEventListener('change', () => {
      const checkpoint = Number(scrubber.value);
      this.scrubTarget = null;
      this.showCheckpoint(checkpoint);
    });
    $('console-toggle').addEventListener('click', () => this.setConsoleExpanded(!this.consoleExpanded));
    $('console-clear').addEventListener('click', () => {
      this.console = [];
      this.renderConsole();
    });
    $('explore-check').addEventListener('click', () => this.openCheck());
    $('check-rerun').addEventListener('click', () => this.runCheck());
    $('check-close').addEventListener('click', () => $('check-dialog').close());

    document.addEventListener('keydown', event => {
      if (!this.active || event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey) return;
      const target = event.target;
      if (target instanceof HTMLElement && (target.closest('input, select, textarea, button, .CodeMirror, dialog') ||
          target.isContentEditable)) return;
      if (event.key === ' ') {
        event.preventDefault();
        if (!event.repeat) this.togglePause();
      } else if (event.key === 'ArrowLeft' && this.canStepBack) {
        event.preventDefault();
        this.stepBack();
      } else if (event.key === 'ArrowRight' && this.canStepForward) {
        event.preventDefault();
        this.stepForward();
      }
    });
  }

  bindMessages() {
    const mine = handler => message => {
      if (message.runId && message.runId === this.runId) handler(message);
    };
    this.connection.on('runStatus', mine(message => {
      this.starting = message.state;
      this.renderControls();
    }));
    this.connection.on('runStarted', mine(message => {
      this.runRevision = message.revision;
      this.starting = null;
      this.renderControls();
    }));
    this.connection.on('frame', mine(message => this.onFrame(message)));
    this.connection.on('console', mine(message => this.onConsole(message)));
    this.connection.on('complete', mine(() => this.finish(true)));
    this.connection.on('runError', mine(message => this.onRunError(message.error ?? {})));
    this.connection.on('checkResult', message => this.onCheckResult(message));
    this.connection.onStatus(state => {
      if (state !== 'connected' && this.running) this.fail('The connection to the Dart host was lost.');
      if (state !== 'connected' && this.checkJob) {
        this.checkJob = null;
        this.checkNote = 'The connection to the Dart host was lost.';
        this.renderCheck();
      }
      this.renderControls();
    });
  }

  setActive(active) {
    this.active = active;
    if (active) {
      this.list.schedule();
      this.scratchCanvas.schedule();
      this.editor.editor.refresh();
    }
  }

  get algorithm() {
    return this.catalog.get(this.algorithmId);
  }

  // -------------------------------------------------------------- selection

  select(id) {
    if (id === this.algorithmId) return true;
    if (!this.editor.canLeave()) return false;
    this.stop();
    this.algorithmId = id;
    this.preferredId = id;
    savePreferences({exploreAlgorithm: id});
    this.picker.setValue(id);
    this.editor.open(this.algorithm);
    // Keep the same input so students compare algorithms, not data.
    this.restoreInput();
    this.console = [];
    this.renderConsole();
    this.render();
    return true;
  }

  catalogChanged() {
    if (!this.catalog.list.length) {
      if (this.algorithmId && !this.algorithm) {
        this.stop();
        this.editor.removed();
      }
      this.render();
      return;
    }
    if (!this.algorithmId) {
      const preferred = this.catalog.get(this.preferredId) ? this.preferredId : this.catalog.list[0].id;
      this.select(preferred);
      return;
    }
    const algorithm = this.algorithm;
    if (!algorithm) {
      this.stop();
      if (this.editor.dirty) {
        this.editor.removed();
      } else {
        this.algorithmId = null;
        this.select(this.catalog.list[0].id);
      }
      this.render();
      return;
    }
    this.editor.sync(algorithm);
    const stale = this.runRevision !== null && algorithm.revision !== this.runRevision;
    if (stale && (this.running || this.latestCheckpoint >= 0)) {
      // The visualization belongs to code that no longer exists on disk.
      this.stop();
      this.restoreInput();
      this.setStatus('The source changed · run it again');
    }
    this.picker.render();
    this.render();
  }

  // ------------------------------------------------------------------ input

  newInput() {
    this.seed++;
    this.input = makeInput(this.n, this.shape, this.seed);
    $('explore-size-output').textContent = String(this.n);
    this.stop();
    this.restoreInput();
    this.render();
  }

  resetFrameState() {
    this.numbers = [...(this.input ?? [])];
    this.scratch = new Array(this.numbers.length).fill(0);
    this.metrics = {reads: 0, writes: 0, comparisons: 0, score: 0};
    this.reads = [];
    this.writes = [];
    this.locals = {};
    this.line = 0;
  }

  clearHistory() {
    this.history = [];
    this.historyCursor = -1;
    this.latestCheckpoint = -1;
    this.scrubTarget = null;
    this.replaying = false;
    this.replayTarget = null;
    this.continueAfterReplay = false;
    this.advanceAfterReplay = false;
    this.completed = false;
    this.completionCorrect = null;
  }

  restoreInput() {
    this.resetFrameState();
    this.error = null;
    this.runRevision = null;
    this.clearHistory();
    this.consoleHighWater = -1;
    this.editor.highlight(null);
    this.editor.markError(null);
  }

  // ---------------------------------------------------------------- history

  get currentCheckpoint() {
    if (this.historyCursor < 0 || this.historyCursor >= this.history.length) return -1;
    return this.history[this.historyCursor].checkpoint;
  }

  get viewingHistory() {
    return this.currentCheckpoint >= 0 && this.currentCheckpoint < this.latestCheckpoint;
  }

  get canBrowseHistory() {
    return this.latestCheckpoint >= 0 && (!this.running || (this.atCheckpoint && !this.replaying));
  }

  get canStepBack() {
    return this.canBrowseHistory && this.currentCheckpoint > 0;
  }

  get canStepForward() {
    if (this.replaying || !this.algorithm || this.algorithm.status === 'error') return false;
    if (this.currentCheckpoint < 0) return !this.running && !this.starting;
    if (this.currentCheckpoint < this.latestCheckpoint) return this.canBrowseHistory;
    if (this.completed || this.error) return false;
    if (this.running) return this.paused && this.atCheckpoint;
    return true;
  }

  get historyLimit() {
    const cells = Math.max(1, this.numbers.length * 3);
    return Math.max(24, Math.min(300, Math.floor(300000 / cells)));
  }

  applyFrame(frame) {
    this.numbers = frame.numbers;
    this.scratch = frame.scratch;
    this.metrics = frame.metrics ?? this.metrics;
    this.reads = frame.reads ?? [];
    this.writes = frame.writes ?? [];
    this.locals = frame.locals ?? {};
    this.line = frame.line ?? 0;
  }

  recordFrame(frame) {
    if (frame.checkpoint > this.latestCheckpoint) this.latestCheckpoint = frame.checkpoint;
    let index = this.history.findIndex(candidate => candidate.checkpoint >= frame.checkpoint);
    if (index >= 0 && this.history[index].checkpoint === frame.checkpoint) {
      this.history[index] = frame;
    } else {
      if (index < 0) index = this.history.length;
      this.history.splice(index, 0, frame);
    }
    this.historyCursor = index;
    // A sparse cache across the whole timeline makes scrubbing immediate;
    // exact steps are reconstructed by replay.
    while (this.history.length > this.historyLimit) {
      let remove = -1, smallest = Infinity;
      for (let i = 1; i < this.history.length - 1; i++) {
        if (i === this.historyCursor) continue;
        const span = this.history[i + 1].checkpoint - this.history[i - 1].checkpoint;
        if (span < smallest) {
          smallest = span;
          remove = i;
        }
      }
      if (remove < 0) remove = this.historyCursor === 0 ? this.history.length - 1 : 0;
      this.history.splice(remove, 1);
      if (remove < this.historyCursor) this.historyCursor--;
    }
  }

  // -------------------------------------------------------------------- runs

  start({paused = false, replayCheckpoint = null, continueAfterReplay = false, advanceAfterReplay = false} = {}) {
    const algorithm = this.algorithm;
    if (!algorithm || !this.connection.connected) return;
    if (algorithm.status === 'error') {
      this.setStatus('Fix the problems in the source first.');
      return;
    }
    this.stop();
    if (replayCheckpoint === null) {
      this.restoreInput();
      this.console = [];
      this.renderConsole();
    }
    this.editor.markError(null);
    this.runId = `explore-${++runCounter}`;
    this.workerCheckpoint = -1;
    this.running = true;
    this.paused = paused || replayCheckpoint !== null;
    this.atCheckpoint = false;
    this.error = null;
    this.replaying = replayCheckpoint !== null;
    this.replayTarget = replayCheckpoint;
    this.continueAfterReplay = continueAfterReplay;
    this.advanceAfterReplay = advanceAfterReplay;
    this.starting = algorithm.status === 'ready' ? 'starting' : 'building';
    this.connection.send({action: 'visualStart', runId: this.runId, id: algorithm.id, values: this.input});
    this.render();
  }

  onFrame(frame) {
    if (this.replaying) {
      this.handleReplayFrame(frame);
      return;
    }
    this.starting = null;
    this.workerCheckpoint = frame.checkpoint;
    this.applyFrame(frame);
    this.recordFrame(frame);
    this.atCheckpoint = true;
    if (frame.done) {
      this.finish(true);
      return;
    }
    if (!this.paused) this.scheduleAdvance();
    this.render();
  }

  handleReplayFrame(frame) {
    const target = this.replayTarget;
    if (target === null) return;
    this.starting = null;
    this.workerCheckpoint = frame.checkpoint;
    if (frame.checkpoint < target && !frame.done) {
      this.sendAdvance(target - frame.checkpoint, true);
      this.renderControls();
      return;
    }
    if (frame.checkpoint > target) {
      this.fail(`Could not replay step ${target}: the algorithm behaved differently this time ` +
        '(does it use randomness?).');
      return;
    }
    const continueRunning = this.continueAfterReplay && !frame.done;
    const advanceOne = this.advanceAfterReplay && !frame.done;
    this.applyFrame(frame);
    this.recordFrame(frame);
    this.replaying = false;
    this.replayTarget = null;
    this.continueAfterReplay = false;
    this.advanceAfterReplay = false;
    this.paused = !continueRunning;
    this.atCheckpoint = true;
    if (frame.done) {
      this.finish(true);
      return;
    }
    if (advanceOne) this.sendAdvance(1);
    else if (continueRunning) this.scheduleAdvance();
    this.render();
  }

  scheduleAdvance() {
    clearTimeout(this.advanceTimer);
    const runId = this.runId;
    this.advanceTimer = setTimeout(() => {
      if (!this.running || this.paused || this.runId !== runId) return;
      this.sendAdvance(BUDGETS[this.speed]);
    }, DELAYS[this.speed]);
  }

  sendAdvance(budget, long = false) {
    if (!this.running || !this.runId) return;
    this.atCheckpoint = false;
    this.connection.send({action: 'advance', runId: this.runId, budget, long});
  }

  togglePause() {
    const algorithm = this.algorithm;
    if (!algorithm || this.replaying) return;
    if (this.viewingHistory && !this.error) {
      this.resumeFromHistory(true);
      return;
    }
    if (!this.running) {
      if (this.completed || this.error || this.currentCheckpoint < 0) {
        this.start();
      } else {
        this.resumeFromHistory(true);
      }
      return;
    }
    if (this.starting) return;
    this.paused = !this.paused;
    if (!this.paused && this.atCheckpoint) this.sendAdvance(BUDGETS[this.speed]);
    this.render();
  }

  stepBack() {
    if (this.canStepBack) this.showCheckpoint(this.currentCheckpoint - 1);
  }

  stepForward() {
    if (!this.canStepForward) return;
    if (this.currentCheckpoint < 0) {
      this.start({paused: true});
      return;
    }
    if (this.currentCheckpoint < this.latestCheckpoint) {
      this.showCheckpoint(this.currentCheckpoint + 1);
      return;
    }
    if (this.running && this.paused && this.atCheckpoint) {
      this.sendAdvance(1);
      this.renderControls();
      return;
    }
    if (!this.running) {
      this.start({paused: true, replayCheckpoint: this.currentCheckpoint, advanceAfterReplay: true});
    }
  }

  showCheckpoint(checkpoint) {
    if (!this.canBrowseHistory || checkpoint < 0 || checkpoint > this.latestCheckpoint) return;
    this.scrubTarget = null;
    const cached = this.history.findIndex(frame => frame.checkpoint === checkpoint);
    if (cached >= 0) {
      this.showHistoryAt(cached);
      return;
    }
    if (this.running && this.atCheckpoint && !this.replaying && checkpoint > this.workerCheckpoint) {
      // The paused worker is behind the requested step: let it catch up.
      this.replaying = true;
      this.replayTarget = checkpoint;
      this.continueAfterReplay = false;
      this.advanceAfterReplay = false;
      this.sendAdvance(checkpoint - this.workerCheckpoint, true);
      this.render();
      return;
    }
    // Fast-forward a fresh worker to the exact step.
    const latest = this.latestCheckpoint;
    const completed = this.completed, correct = this.completionCorrect;
    this.start({paused: true, replayCheckpoint: checkpoint});
    this.latestCheckpoint = latest;
    this.completed = completed;
    this.completionCorrect = correct;
    this.render();
  }

  nearestCachedIndex(checkpoint) {
    if (!this.history.length) return -1;
    let low = 0, high = this.history.length - 1;
    while (low <= high) {
      const middle = (low + high) >> 1;
      const value = this.history[middle].checkpoint;
      if (value === checkpoint) return middle;
      if (value < checkpoint) low = middle + 1;
      else high = middle - 1;
    }
    if (low <= 0) return 0;
    if (low >= this.history.length) return this.history.length - 1;
    const before = this.history[low - 1].checkpoint, after = this.history[low].checkpoint;
    return checkpoint - before <= after - checkpoint ? low - 1 : low;
  }

  previewScrub(checkpoint) {
    if (!this.canBrowseHistory || !this.history.length) return;
    const target = Math.max(0, Math.min(this.latestCheckpoint, checkpoint));
    const cached = this.nearestCachedIndex(target);
    if (cached < 0) return;
    this.scrubTarget = target;
    if (this.running) this.paused = true;
    this.historyCursor = cached;
    this.applyFrame(this.history[cached]);
    this.render();
  }

  showHistoryAt(index) {
    if (index < 0 || index >= this.history.length) return;
    if (this.running && (!this.atCheckpoint || this.replaying)) return;
    if (this.running) this.paused = true;
    this.historyCursor = index;
    this.applyFrame(this.history[index]);
    this.render();
  }

  resumeFromHistory(continueRunning) {
    if (this.historyCursor < 0 || this.historyCursor >= this.history.length) return;
    const target = this.history[this.historyCursor].checkpoint;
    if (target < 0) return;
    this.history.splice(this.historyCursor + 1);
    this.historyCursor = this.history.length - 1;
    this.latestCheckpoint = target;
    this.scrubTarget = null;
    this.completed = false;
    this.completionCorrect = null;
    this.start({paused: true, replayCheckpoint: target, continueAfterReplay: continueRunning});
  }

  matchesExpectedInput() {
    const expected = [...this.input].sort((a, b) => a - b);
    return this.numbers.length === expected.length && this.numbers.every((value, i) => value === expected[i]);
  }

  finish(completed) {
    if (!this.running) return;
    this.completed = completed;
    this.completionCorrect = completed ? this.matchesExpectedInput() : null;
    this.endRun();
    this.reads = [];
    this.writes = [];
    this.render();
  }

  fail(message) {
    this.error = message;
    this.endRun();
    this.completed = false;
    this.completionCorrect = null;
    this.reads = [];
    this.writes = [];
    this.render();
  }

  /** Stops the worker and forgets the run (history and frames stay). */
  stop() {
    this.endRun();
  }

  endRun() {
    clearTimeout(this.advanceTimer);
    this.advanceTimer = null;
    if (this.runId) this.connection.send({action: 'stop', runId: this.runId});
    this.runId = null;
    this.running = false;
    this.paused = false;
    this.starting = null;
    this.atCheckpoint = false;
    this.replaying = false;
    this.replayTarget = null;
    this.continueAfterReplay = false;
    this.advanceAfterReplay = false;
  }

  onRunError(error) {
    const kind = error.kind;
    let summary;
    if (kind === 'compile') {
      summary = 'The algorithm does not compile · see the problems below the editor.';
    } else if (kind === 'timeout') {
      summary = 'Stopped: no progress for several seconds.';
      this.addConsole({kind: 'timeout', text: error.message, line: error.line ?? null, always: true});
    } else {
      summary = 'The algorithm threw an exception.';
      const where = Number.isInteger(error.line) ? ` (line ${error.line})` : '';
      this.addConsole({kind: 'error', text: `Runtime error${where}: ${error.message ?? 'unknown error'}`,
        line: error.line ?? null, stack: error.stack ?? [], always: true});
      if (kind === 'crash') summary = 'The algorithm process stopped unexpectedly.';
    }
    if (Number.isInteger(error.line)) this.editor.markError(error.line, this.runRevision);
    if (kind !== 'compile') this.setConsoleExpanded(true);
    this.fail(summary);
  }

  // ----------------------------------------------------------------- console

  onConsole(message) {
    const checkpoint = Number.isInteger(message.checkpoint) ? message.checkpoint : null;
    // A replay re-executes the same prints; keep only output beyond the replay.
    if (checkpoint !== null && checkpoint <= this.consoleHighWater) return;
    if (checkpoint !== null) this.consoleHighWater = checkpoint;
    this.addConsole({kind: message.kind === 'warning' ? 'warning' : 'stdout', text: String(message.text ?? ''),
      line: Number.isInteger(message.line) ? message.line : null, checkpoint});
    if (this.console.length === 1) this.setConsoleExpanded(true);
  }

  addConsole(entry) {
    if (this.console.length >= 500) return;
    this.console.push(entry);
    this.renderConsole();
  }

  setConsoleExpanded(expanded) {
    this.consoleExpanded = expanded;
    $('console').classList.toggle('expanded', expanded);
    $('console-toggle').setAttribute('aria-expanded', String(expanded));
    $('console-output').hidden = !expanded;
    this.renderConsole();
  }

  renderConsole() {
    const current = this.currentCheckpoint;
    const showAll = !this.viewingHistory && (this.completed || this.error || this.running);
    const visible = this.console.filter(entry => entry.always || entry.checkpoint === null ||
      showAll || entry.checkpoint < current);
    const output = $('console-output');
    output.replaceChildren(...visible.map(entry => {
      const location = el('button', {type: 'button', class: 'console-line', disabled: entry.line === null,
        title: entry.line === null ? undefined : `Show line ${entry.line}`,
        onclick: () => this.editor.jumpTo(entry.line)}, entry.line === null ? 'output' : `line ${entry.line}`);
      const row = el('div', {class: `console-entry ${entry.kind}`}, location,
        el('p', {class: 'console-message'}, entry.text));
      if (entry.stack?.length) row.append(el('pre', {class: 'console-stack'}, entry.stack.join('\n')));
      return row;
    }));
    if (!visible.length && this.consoleExpanded) {
      output.append(el('div', {class: 'console-empty'}, this.console.length
        ? 'No output up to this step.' : 'No output yet. Use print(...) in your algorithm.'));
    }
    output.scrollTop = output.scrollHeight;
    const count = $('console-count');
    count.hidden = !this.console.length;
    count.textContent = visible.length === this.console.length
      ? String(this.console.length) : `${visible.length}/${this.console.length}`;
    $('console-clear').disabled = !this.console.length;
  }

  // ------------------------------------------------------------------ checks

  checkKey(algorithm = this.algorithm) {
    return algorithm ? `${algorithm.id}@${algorithm.revision}` : '';
  }

  openCheck() {
    const algorithm = this.algorithm;
    if (!algorithm) return;
    $('check-title').textContent = `${algorithm.name} · ${algorithm.author}`;
    const dialog = $('check-dialog');
    if (!dialog.open) dialog.showModal();
    if (this.checks.has(this.checkKey())) this.renderCheck();
    else this.runCheck();
  }

  runCheck() {
    const algorithm = this.algorithm;
    if (!algorithm) return;
    if (algorithm.status === 'error') {
      this.checkJob = null;
      this.checkNote = 'This algorithm does not compile yet. Fix the problems shown below the editor, then save.';
      this.renderCheck();
      return;
    }
    this.checkNote = this.editor.dirty
      ? 'Checks use the SAVED version; your unsaved edits are not included.' : null;
    this.checkJob = {jobId: `check-${++jobCounter}`, key: this.checkKey(algorithm)};
    if (!this.connection.send({action: 'check', jobId: this.checkJob.jobId, id: algorithm.id})) {
      this.checkJob = null;
      this.checkNote = 'Not connected to the Dart host.';
    }
    this.renderCheck();
  }

  onCheckResult(message) {
    if (!this.checkJob || message.jobId !== this.checkJob.jobId) return;
    const algorithm = this.catalog.get(message.id);
    const key = algorithm && algorithm.revision === message.revision
      ? `${message.id}@${message.revision}` : this.checkJob.key;
    this.checks.set(key, message.result ?? {status: 'crash', message: 'No result.'});
    this.checkJob = null;
    this.renderCheck();
    this.renderControls();
  }

  renderCheck() {
    const status = $('check-status');
    const list = $('check-results');
    const note = this.checkNote ? ` ${this.checkNote}` : '';
    $('check-rerun').disabled = this.checkJob !== null || !this.algorithm || this.algorithm.status === 'error';
    if (this.checkJob) {
      status.textContent = `Compiling and running the checks…${note}`;
      status.className = 'dialog-status running';
      list.replaceChildren();
      return;
    }
    const result = this.checks.get(this.checkKey());
    if (!result) {
      status.textContent = this.checkNote ?? 'Run the checks to test this algorithm on many inputs.';
      status.className = 'dialog-status';
      list.replaceChildren();
      return;
    }
    if (result.status !== 'done') {
      status.className = 'dialog-status failed';
      status.textContent = (result.status === 'compile' ? 'The algorithm does not compile.'
        : result.status === 'timeout' ? `The checks did not finish: ${result.message}`
          : `The checks could not run: ${result.message ?? 'unknown error'}`) + note;
      list.replaceChildren();
      return;
    }
    const groups = Array.isArray(result.groups) ? result.groups : [];
    const failed = groups.filter(group => !group.ok).length;
    status.className = `dialog-status ${failed ? 'failed' : 'passed'}`;
    status.textContent = (failed
      ? `${failed} of ${groups.length} groups failed.`
      : `All ${groups.length} groups passed.`) + note;
    const items = groups.map(group => this.checkGroupItem(group));
    items.push(this.stabilityItem(result.stability ?? {}));
    list.replaceChildren(...items);
  }

  checkGroupItem(group) {
    const item = el('li', {class: group.ok ? 'check-pass' : 'check-fail'},
      el('span', {class: 'check-icon'}, icon(group.ok ? 'check' : 'x')),
      el('span', {class: 'check-name'}, group.name),
      el('span', {class: 'check-count'}, `${group.passed}/${group.total}`));
    const failure = group.failure;
    if (failure) {
      const details = el('div', {class: 'check-details'});
      details.append(el('p', {class: 'check-message'}, failure.message ?? 'Failed.'));
      if (failure.input) details.append(el('p', {}, el('span', {class: 'muted'}, 'Input  '),
        el('code', {}, previewList(failure.input))));
      if (failure.output) details.append(el('p', {}, el('span', {class: 'muted'}, 'Result '),
        el('code', {}, previewList(failure.output))));
      if (failure.error) {
        const line = failure.error.line;
        details.append(el('p', {class: 'check-error'}, failure.error.message ?? ''));
        if (Number.isInteger(line)) {
          details.append(el('button', {type: 'button', class: 'link-button', onclick: () => {
            $('check-dialog').close();
            this.editor.markError(line, this.editor.revision);
            this.editor.jumpTo(line);
          }}, `Show line ${line}`));
        }
      }
      item.append(details);
    }
    return item;
  }

  stabilityItem(stability) {
    if (!stability.tested) {
      return el('li', {class: 'check-skip'}, el('span', {class: 'check-icon'}, icon('info-circle')),
        el('span', {class: 'check-name'}, 'Stability'),
        el('span', {class: 'check-count muted'}, 'not tested until all groups pass'));
    }
    if (stability.stable) {
      return el('li', {class: 'check-pass'}, el('span', {class: 'check-icon'}, icon('check')),
        el('span', {class: 'check-name'}, 'Stable (tested)'),
        el('span', {class: 'check-count muted'}, 'equal values keep their order'));
    }
    const {input, output} = stabilityLabels(stability.input ?? [], stability.output ?? [], stability.origins ?? []);
    return el('li', {class: 'check-info'}, el('span', {class: 'check-icon'}, icon('info-circle')),
      el('span', {class: 'check-name'}, 'Not stable'),
      el('span', {class: 'check-count muted'}, 'equal values changed their order'),
      el('div', {class: 'check-details'},
        el('p', {}, el('span', {class: 'muted'}, 'Input  '), el('code', {}, `[${input.join(', ')}]`)),
        el('p', {}, el('span', {class: 'muted'}, 'Result '), el('code', {}, `[${output.join(', ')}]`))));
  }

  // ------------------------------------------------------------------ render

  setStatus(text) {
    this.statusOverride = text;
    this.renderControls();
  }

  indexVariables() {
    if (!this.running && !this.viewingHistory) return new Map();
    const n = this.numbers.length;
    const result = new Map();
    for (const [name, value] of Object.entries(this.locals)) {
      if (!Number.isInteger(value) || value < 0) continue;
      const lower = name.toLowerCase();
      const lengthLike = ['length', 'size', 'count', 'n'].includes(lower) ||
        lower.endsWith('length') || lower.endsWith('count');
      if (value < n || (value === n && !lengthLike)) result.set(name, value);
    }
    return result;
  }

  render() {
    const algorithm = this.algorithm;
    const maxValue = Math.max(1, ...this.input);
    const markers = (list, label) => new Set(list.filter(m => m.list === label).map(m => m.index));
    this.list.set({
      values: this.numbers, maxValue, color: algorithm?.color ?? '#7c8796',
      reads: this.showAccess ? markers(this.reads, 'list') : new Set(),
      writes: this.showAccess ? markers(this.writes, 'list') : new Set(),
      variables: this.indexVariables(),
    });
    this.scratchCanvas.set({
      values: this.scratch, maxValue, color: '#9aa3ad',
      reads: this.showAccess ? markers(this.reads, 'scratch') : new Set(),
      writes: this.showAccess ? markers(this.writes, 'scratch') : new Set(),
      variables: new Map(),
    });
    $('stat-reads').textContent = compactCount(this.metrics.reads ?? 0);
    $('stat-writes').textContent = compactCount(this.metrics.writes ?? 0);
    $('stat-comparisons').textContent = compactCount(this.metrics.comparisons ?? 0);
    $('access-legend').hidden = !this.showAccess;

    const badge = $('completion-badge');
    badge.hidden = !this.completed;
    if (this.completed) {
      const correct = this.completionCorrect === true;
      badge.className = `completion-badge ${correct ? 'correct' : 'incorrect'}`;
      badge.replaceChildren(icon(correct ? 'circle-check' : 'circle-x'),
        correct ? 'Sorted correctly' : 'Finished, result incorrect');
    }

    const chips = $('variables');
    const entries = Object.entries(this.locals).sort(([a], [b]) => a.localeCompare(b));
    if (!entries.length) {
      chips.replaceChildren(el('span', {class: 'muted'}, this.running && this.currentCheckpoint < 0
        ? 'Waiting for the first step…' : 'Run the algorithm to see its local variables.'));
    } else {
      const pointers = this.indexVariables();
      chips.replaceChildren(...entries.map(([name, value]) =>
        el('span', {class: `variable-chip${pointers.has(name) ? ' pointer' : ''}`, title: `${name} = ${value}`},
          el('span', {class: 'variable-name'}, name), ' = ', el('span', {class: 'variable-value'}, String(value)))));
    }

    if (this.currentCheckpoint >= 0 && !this.editor.dirty) this.editor.highlight(this.line, this.runRevision);
    else this.editor.highlight(null);
    this.renderControls();
    this.renderConsole();
  }

  renderControls() {
    const algorithm = this.algorithm;
    const broken = !algorithm || algorithm.status === 'error';
    const connected = this.connection.connected;
    this.picker.setEnabled(!this.running);
    for (const id of ['explore-shape', 'explore-size', 'explore-shuffle']) $(id).disabled = this.running;
    $('explore-check').disabled = !algorithm;
    $('step-back').disabled = !this.canStepBack;
    $('step-next').disabled = !this.canStepForward || !connected;
    $('stop').disabled = !this.running;

    const play = $('play');
    let label = 'Run', glyph = 'player-play';
    if (this.running && !this.paused && !this.replaying) {
      [label, glyph] = ['Pause', 'player-pause'];
    } else if (this.viewingHistory || (this.running && this.paused)) {
      label = 'Continue';
    } else if (this.completed || this.error) {
      label = 'Run again';
    }
    play.replaceChildren(icon(glyph), el('span', {}, label));
    play.disabled = broken || this.replaying || !connected;
    play.title = broken && algorithm ? 'Fix the problems in the source first' : `${label} (Space)`;

    $('speed-output').textContent = `${this.speed * 5}%`;

    const latest = this.latestCheckpoint;
    const current = this.currentCheckpoint;
    const scrubber = $('scrubber');
    scrubber.max = String(Math.max(1, latest));
    scrubber.value = String(Math.max(0, this.scrubTarget ?? current));
    scrubber.disabled = !this.canBrowseHistory || latest <= 0;
    $('step-label').textContent = current >= 0
      ? `step ${groupedCount(this.scrubTarget ?? current)} / ${groupedCount(latest)}` : 'start';

    const status = $('run-status');
    let text = 'Ready', kind = '';
    if (this.starting === 'building') [text, kind] = ['Compiling…', 'busy'];
    else if (this.starting === 'starting') [text, kind] = ['Starting…', 'busy'];
    else if (this.replaying) [text, kind] = [`Going to step ${groupedCount(this.replayTarget ?? 0)}…`, 'busy'];
    else if (this.error) [text, kind] = [this.error, 'error'];
    else if (this.running) text = this.paused ? 'Paused' : 'Running';
    else if (this.completed) text = 'Finished';
    else if (this.viewingHistory) text = 'Viewing an earlier step';
    else if (broken && algorithm) [text, kind] = ['Fix the problems in the source first', 'error'];
    else if (algorithm && isBusy(algorithm)) [text, kind] = ['Compiling…', 'busy'];
    if (this.statusOverride && !this.running && !this.error && !this.completed && current < 0) {
      text = this.statusOverride;
    }
    if (this.running || this.error || this.completed) this.statusOverride = null;
    status.textContent = text;
    status.className = `run-status ${kind}`;

    const summary = $('check-summary');
    const result = this.checks.get(this.checkKey());
    if (result?.status === 'done') {
      const groups = result.groups ?? [];
      const failed = groups.filter(group => !group.ok).length;
      summary.hidden = false;
      summary.className = `check-summary ${failed ? 'failed' : 'passed'}`;
      summary.textContent = failed ? `${failed} failed` : `${groups.length}/${groups.length}`;
    } else if (result) {
      summary.hidden = false;
      summary.className = 'check-summary failed';
      summary.textContent = result.status === 'timeout' ? 'timeout' : 'error';
    } else {
      summary.hidden = true;
    }
  }
}

function previewList(preview) {
  if (Array.isArray(preview)) return formatList(preview, 40);
  const values = Array.isArray(preview?.values) ? preview.values : [];
  const text = formatList(values, 40);
  return preview?.length > values.length || values.length > 40 ? `${text}  (n = ${preview.length})` : text;
}

/** Labels equal values a, b, c … in input order so a reordering is visible. */
export function stabilityLabels(input, output, origins) {
  const seen = new Map();
  const labels = input.map(value => {
    const count = seen.get(value) ?? 0;
    seen.set(value, count + 1);
    return {value, label: String.fromCharCode(97 + (count % 26))};
  });
  const duplicate = value => input.filter(v => v === value).length > 1;
  const show = entry => (duplicate(entry.value) ? `${entry.value}${entry.label}` : String(entry.value));
  return {
    input: labels.map(show),
    output: output.map((value, i) => {
      const origin = labels[origins[i]];
      return origin ? show(origin) : String(value);
    }),
  };
}
