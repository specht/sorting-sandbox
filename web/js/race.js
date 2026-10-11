// Race: two to four algorithms sort the SAME input. All lanes advance in
// lockstep by the same number of checkpoints, so the race measures steps of
// the algorithm, not the speed of a particular computer.
import {$, el, icon, compactCount, groupedCount, INPUT_SHAPES, makeInput, savePreferences} from './util.js';
import {statusIcon, swatch} from './catalog.js';
import {ArrayCanvas} from './bars.js';
import {BUDGETS, DELAYS} from './explore.js';

export const RACE_SIZES = [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024];
let laneCounter = 0;

export class RaceView {
  constructor({connection, catalog, preferences, openInExplore}) {
    this.connection = connection;
    this.catalog = catalog;
    this.openInExplore = openInExplore;
    this.selected = new Set(Array.isArray(preferences.raceSelected) ? preferences.raceSelected : []);
    this.n = RACE_SIZES.includes(preferences.raceSize) ? preferences.raceSize : 48;
    this.shape = INPUT_SHAPES.some(s => s.id === preferences.raceShape) ? preferences.raceShape : 'random';
    this.speed = Number.isInteger(preferences.raceSpeed) ? Math.max(0, Math.min(20, preferences.raceSpeed)) : 12;
    this.seed = 100 + Math.floor(Math.random() * 1000);
    this.input = [];
    this.lanes = [];
    this.running = false;
    this.timer = null;
    this.active = false;
    this.bind();
    this.newInput();
  }

  bind() {
    const shape = $('race-shape');
    shape.replaceChildren(...INPUT_SHAPES.map(s => el('option', {value: s.id}, s.label)));
    shape.value = this.shape;
    shape.addEventListener('change', () => {
      this.shape = shape.value;
      savePreferences({raceShape: this.shape});
      this.newInput();
    });
    const size = $('race-size');
    size.max = String(RACE_SIZES.length - 1);
    size.value = String(RACE_SIZES.indexOf(this.n));
    size.addEventListener('input', () => {
      this.n = RACE_SIZES[Number(size.value)];
      savePreferences({raceSize: this.n});
      this.newInput();
    });
    $('race-shuffle').addEventListener('click', () => this.newInput());
    const speed = $('race-speed');
    speed.value = String(this.speed);
    speed.addEventListener('input', () => {
      this.speed = Number(speed.value);
      savePreferences({raceSpeed: this.speed});
      $('race-speed-output').textContent = `${this.speed * 5}%`;
    });
    $('race-speed-output').textContent = `${this.speed * 5}%`;
    $('race-start').addEventListener('click', () => (this.running ? this.stop() : this.start()));

    const mine = handler => message => {
      const lane = this.lanes.find(candidate => candidate.runId && candidate.runId === message.runId);
      if (lane) handler(lane, message);
    };
    this.connection.on('runStatus', mine((lane, message) => {
      lane.status = message.state === 'building' ? 'Compiling…' : 'Starting…';
      this.renderLane(lane);
    }));
    this.connection.on('runStarted', mine(lane => {
      lane.status = 'Ready';
      this.renderLane(lane);
    }));
    this.connection.on('frame', mine((lane, message) => this.onFrame(lane, message)));
    this.connection.on('complete', mine(lane => this.finishLane(lane)));
    this.connection.on('runError', mine((lane, message) => {
      const error = message.error ?? {};
      lane.error = error.kind === 'compile' ? 'Does not compile'
        : error.kind === 'timeout' ? 'Stopped: no progress'
          : `Error${Number.isInteger(error.line) ? ` in line ${error.line}` : ''}: ${error.message ?? ''}`;
      this.finishLane(lane);
    }));
    this.connection.onStatus(state => {
      if (state !== 'connected' && this.running) {
        for (const lane of this.lanes) if (!lane.done) lane.error = 'Connection lost';
        this.endRace();
      }
      this.renderControls();
    });
  }

  setActive(active) {
    this.active = active;
    if (active) for (const lane of this.lanes) lane.canvas?.schedule();
  }

  get available() {
    return this.catalog.list;
  }

  catalogChanged() {
    const ids = new Set(this.catalog.list.map(algorithm => algorithm.id));
    for (const id of [...this.selected]) if (!ids.has(id)) this.selected.delete(id);
    if (this.selected.size < 2) {
      for (const algorithm of this.catalog.list) {
        if (this.selected.size >= 2) break;
        if (algorithm.status !== 'error') this.selected.add(algorithm.id);
      }
    }
    this.renderChoices();
    if (!this.running) this.prepareLanes();
    else for (const lane of this.lanes) this.renderLane(lane);
    this.renderControls();
  }

  toggle(id) {
    if (this.running) return;
    if (this.selected.has(id)) this.selected.delete(id);
    else if (this.selected.size < 4) this.selected.add(id);
    savePreferences({raceSelected: [...this.selected]});
    this.renderChoices();
    this.prepareLanes();
    this.renderControls();
  }

  newInput() {
    if (this.running) return;
    this.seed++;
    this.input = makeInput(this.n, this.shape, this.seed);
    $('race-size-output').textContent = String(this.n);
    this.prepareLanes();
  }

  prepareLanes() {
    const algorithms = this.catalog.list.filter(algorithm => this.selected.has(algorithm.id));
    for (const lane of this.lanes) lane.canvas?.observer.disconnect();
    this.lanes = algorithms.map(algorithm => this.createLane(algorithm));
    this.renderLanes();
  }

  createLane(algorithm) {
    return {
      id: algorithm.id, runId: null, numbers: [...this.input], scratch: [],
      metrics: {reads: 0, writes: 0, comparisons: 0}, checkpoint: 0,
      waiting: false, done: false, completed: false, correct: null, error: null, rank: null,
      status: '', canvas: null, node: null,
    };
  }

  start() {
    if (this.running || !this.connection.connected) return;
    const algorithms = this.catalog.list.filter(algorithm =>
      this.selected.has(algorithm.id) && algorithm.status !== 'error');
    if (algorithms.length < 2) return;
    for (const lane of this.lanes) lane.canvas?.observer.disconnect();
    this.lanes = algorithms.map(algorithm => this.createLane(algorithm));
    this.renderLanes();
    this.running = true;
    this.finishOrder = 0;
    for (const lane of this.lanes) {
      lane.runId = `race-${++laneCounter}`;
      lane.waiting = true;
      lane.status = 'Starting…';
      this.connection.send({action: 'visualStart', runId: lane.runId, id: lane.id, values: this.input});
      this.renderLane(lane);
    }
    this.renderChoices();
    this.renderControls();
  }

  onFrame(lane, frame) {
    lane.numbers = frame.numbers;
    lane.scratch = frame.scratch;
    lane.metrics = frame.metrics ?? lane.metrics;
    lane.checkpoint = frame.checkpoint;
    lane.waiting = false;
    lane.status = '';
    if (frame.done) {
      lane.completed = true;
      const expected = [...this.input].sort((a, b) => a - b);
      lane.correct = frame.numbers.length === expected.length && frame.numbers.every((v, i) => v === expected[i]);
      this.finishLane(lane);
      return;
    }
    this.renderLane(lane);
    this.maybeAdvance();
  }

  /** Lockstep: advance only when every running lane has reported its frame. */
  maybeAdvance() {
    if (!this.running || this.timer) return;
    const running = this.lanes.filter(lane => !lane.done);
    if (!running.length || running.some(lane => lane.waiting)) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      if (!this.running) return;
      const budget = BUDGETS[this.speed];
      for (const lane of this.lanes) {
        if (lane.done || !lane.runId) continue;
        lane.waiting = true;
        this.connection.send({action: 'advance', runId: lane.runId, budget});
      }
    }, DELAYS[this.speed]);
  }

  finishLane(lane) {
    if (lane.done) return;
    lane.done = true;
    lane.waiting = false;
    if (lane.runId) this.connection.send({action: 'stop', runId: lane.runId});
    lane.runId = null;
    this.rankLanes();
    if (this.lanes.every(candidate => candidate.done)) this.endRace();
    else this.maybeAdvance();
    for (const candidate of this.lanes) this.renderLane(candidate);
  }

  /** Fewer steps wins; correct results only. */
  rankLanes() {
    const finished = this.lanes.filter(lane => lane.completed && lane.correct)
      .sort((a, b) => a.checkpoint - b.checkpoint);
    let rank = 0, previous = null;
    finished.forEach((lane, index) => {
      if (lane.checkpoint !== previous) rank = index + 1;
      previous = lane.checkpoint;
      lane.rank = rank;
    });
  }

  stop() {
    for (const lane of this.lanes) {
      if (!lane.done) {
        lane.done = true;
        lane.status = 'Stopped';
      }
      if (lane.runId) this.connection.send({action: 'stop', runId: lane.runId});
      lane.runId = null;
    }
    this.endRace();
    for (const lane of this.lanes) this.renderLane(lane);
  }

  endRace() {
    clearTimeout(this.timer);
    this.timer = null;
    this.running = false;
    this.renderChoices();
    this.renderControls();
  }

  // ------------------------------------------------------------------ render

  renderControls() {
    const button = $('race-start');
    const ready = this.catalog.list.filter(algorithm =>
      this.selected.has(algorithm.id) && algorithm.status !== 'error').length;
    button.replaceChildren(icon(this.running ? 'player-stop' : 'flag'),
      el('span', {}, this.running ? 'Stop' : 'Race'));
    button.disabled = !this.running && (ready < 2 || !this.connection.connected);
    button.classList.toggle('danger', this.running);
    for (const id of ['race-shape', 'race-size', 'race-shuffle']) $(id).disabled = this.running;
    const hint = $('race-hint');
    if (this.catalog.list.length < 2) hint.textContent = 'A race needs at least two algorithms in the class repository.';
    else if (ready < 2) hint.textContent = 'Select at least two algorithms that compile.';
    else hint.textContent = 'Every lane gets exactly the same input and advances by the same number of steps.';
  }

  renderChoices() {
    const container = $('race-choices');
    container.replaceChildren(...this.catalog.list.map(algorithm => {
      const selected = this.selected.has(algorithm.id);
      const broken = algorithm.status === 'error';
      const button = el('button', {
        type: 'button', class: `race-choice${selected ? ' selected' : ''}${broken ? ' broken' : ''}`,
        'aria-pressed': String(selected), disabled: this.running || (!selected && this.selected.size >= 4),
        title: broken ? 'This algorithm does not compile' : `${algorithm.name} · ${algorithm.author}`,
        onclick: () => this.toggle(algorithm.id),
      }, swatch(algorithm.color), el('span', {class: 'race-choice-name'}, algorithm.name),
      el('span', {class: 'race-choice-author'}, algorithm.author));
      const status = statusIcon(algorithm);
      if (status) button.append(status);
      return button;
    }));
  }

  renderLanes() {
    const container = $('race-lanes');
    if (!this.lanes.length) {
      container.replaceChildren(el('div', {class: 'race-empty muted'},
        'Choose two to four algorithms above. Every lane receives exactly the same input.'));
      return;
    }
    container.dataset.count = String(this.lanes.length);
    container.replaceChildren(...this.lanes.map(lane => {
      const algorithm = this.catalog.get(lane.id);
      const canvas = el('canvas', {class: 'lane-canvas', 'aria-label': `${algorithm?.name ?? lane.id} list`});
      lane.node = {
        title: el('div', {class: 'lane-title'}),
        badge: el('span', {class: 'lane-badge', hidden: true}),
        stats: el('div', {class: 'lane-stats'}),
        status: el('div', {class: 'lane-status'}),
      };
      const card = el('article', {class: 'panel lane'},
        el('header', {class: 'lane-header'}, lane.node.title, lane.node.badge),
        el('div', {class: 'lane-frame'}, canvas), lane.node.stats, lane.node.status);
      lane.canvas = new ArrayCanvas(canvas, {pointerGutter: false});
      this.renderLane(lane);
      return card;
    }));
  }

  renderLane(lane) {
    if (!lane.node) return;
    const algorithm = this.catalog.get(lane.id);
    const color = algorithm?.color ?? '#7c8796';
    lane.node.title.replaceChildren(swatch(color),
      el('button', {type: 'button', class: 'lane-name', title: 'Open in Explore',
        onclick: () => this.openInExplore(lane.id)}, algorithm?.name ?? lane.id),
      el('span', {class: 'lane-author'}, algorithm?.author ?? ''));
    const badge = lane.node.badge;
    badge.hidden = !(lane.completed || lane.error);
    if (lane.error) {
      badge.className = 'lane-badge error';
      badge.replaceChildren(icon('alert-triangle'), 'error');
    } else if (lane.completed && !lane.correct) {
      badge.className = 'lane-badge error';
      badge.replaceChildren(icon('circle-x'), 'incorrect');
    } else if (lane.completed) {
      badge.className = `lane-badge${lane.rank === 1 ? ' winner' : ''}`;
      badge.replaceChildren(icon(lane.rank === 1 ? 'trophy' : 'circle-check'), ordinal(lane.rank));
    }
    lane.canvas.set({values: lane.numbers, maxValue: Math.max(1, ...this.input), color,
      reads: new Set(), writes: new Set(), variables: new Map()});
    lane.node.stats.replaceChildren(
      el('span', {}, 'steps ', el('b', {}, groupedCount(lane.checkpoint))),
      el('span', {}, 'R ', el('b', {}, compactCount(lane.metrics.reads ?? 0))),
      el('span', {}, 'W ', el('b', {}, compactCount(lane.metrics.writes ?? 0))),
      el('span', {}, 'C ', el('b', {}, compactCount(lane.metrics.comparisons ?? 0))));
    const status = lane.error ?? lane.status ?? '';
    lane.node.status.textContent = status;
    lane.node.status.className = `lane-status${lane.error ? ' error' : ''}`;
    lane.node.status.hidden = !status;
  }
}

function ordinal(rank) {
  if (!rank) return 'finished';
  const suffix = rank % 10 === 1 && rank % 100 !== 11 ? 'st'
    : rank % 10 === 2 && rank % 100 !== 12 ? 'nd'
      : rank % 10 === 3 && rank % 100 !== 13 ? 'rd' : 'th';
  return `${rank}${suffix}`;
}
