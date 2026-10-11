// Analyze: every algorithm of the class runs correctness and stability checks
// and the SAME benchmark inputs. The chart shows the sandbox score
// (reads + writes + comparisons), optionally divided by a growth model.
import {$, el, icon, svg, compactCount, INPUT_SHAPES, makeInput, savePreferences, shapeLabel,
  sortAlgorithms, alpha, mix} from './util.js';
import {swatch} from './catalog.js';

export const ANALYZE_SIZES = [32, 64, 128, 256, 512, 1024, 2048];
const DIVISORS = {
  1: {label: 'score', f: () => 1},
  n: {label: 'score / n', f: n => n},
  nlogn: {label: 'score / (n log₂ n)', f: n => n * Math.log2(n)},
  n2: {label: 'score / n²', f: n => n * n},
};
let jobCounter = 0;

export function formatScore(value) {
  if (!Number.isFinite(value)) return '–';
  if (Math.abs(value) >= 1000) return compactCount(Math.round(value));
  if (Number.isInteger(value)) return String(value);
  return Number(value.toPrecision(3)).toString();
}

/** "Nice" tick values for a linear axis. */
export function linearTicks(min, max, count = 5) {
  if (!(max > min)) return [min];
  const raw = (max - min) / count;
  const magnitude = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = [1, 2, 2.5, 5, 10].map(f => f * magnitude).find(s => s >= raw) ?? raw;
  const ticks = [];
  for (let value = Math.ceil(min / step) * step; value <= max + step * 1e-9; value += step) {
    ticks.push(Number(value.toPrecision(12)));
  }
  return ticks;
}

export class AnalyzeView {
  constructor({connection, catalog, preferences, openInExplore}) {
    this.connection = connection;
    this.catalog = catalog;
    this.openInExplore = openInExplore;
    this.shape = INPUT_SHAPES.some(s => s.id === preferences.analyzeShape) ? preferences.analyzeShape : 'random';
    this.divisor = DIVISORS[preferences.analyzeDivisor] ? preferences.analyzeDivisor : '1';
    this.logX = preferences.analyzeLogX === true;
    this.logY = preferences.analyzeLogY === true;
    this.results = new Map();
    this.job = null;
    this.hovered = null;
    this.pinned = null;
    this.view = null;
    this.active = false;
    this.bind();
    this.render();
  }

  bind() {
    const shape = $('analyze-shape');
    shape.replaceChildren(...INPUT_SHAPES.map(s => el('option', {value: s.id}, s.label)));
    shape.value = this.shape;
    shape.addEventListener('change', () => {
      this.shape = shape.value;
      savePreferences({analyzeShape: this.shape});
      this.view = null;
      this.render();
    });
    const divisor = $('analyze-divisor');
    divisor.value = this.divisor;
    divisor.addEventListener('change', () => {
      this.divisor = divisor.value;
      savePreferences({analyzeDivisor: this.divisor});
      this.view = null;
      this.render();
    });
    for (const [id, key] of [['analyze-log-x', 'logX'], ['analyze-log-y', 'logY']]) {
      const box = $(id);
      box.checked = this[key];
      box.addEventListener('change', () => {
        this[key] = box.checked;
        savePreferences({[key === 'logX' ? 'analyzeLogX' : 'analyzeLogY']: box.checked});
        this.view = null;
        this.render();
      });
    }
    $('analyze-run').addEventListener('click', () => (this.job ? this.cancel() : this.run()));
    $('chart-reset').addEventListener('click', () => {
      this.view = null;
      this.renderChart();
    });
    $('chart-unpin').addEventListener('click', () => {
      this.pinned = null;
      this.render();
    });
    this.bindChart();
    window.addEventListener('resize', () => {
      if (this.active) this.renderChart();
    });

    this.connection.on('analysisResult', message => {
      if (!this.job || message.jobId !== this.job.jobId) return;
      this.job.pending.delete(message.id);
      if (message.revision) {
        this.results.set(`${message.id}@${message.revision}@${this.job.shape}`, message.result ?? {status: 'crash'});
      }
      this.render();
    });
    this.connection.on('analysisDone', message => {
      if (!this.job || message.jobId !== this.job.jobId) return;
      this.job = null;
      this.render();
    });
    this.connection.onStatus(state => {
      if (state !== 'connected' && this.job) this.job = null;
      if (this.active) this.renderToolbar();
    });
  }

  setActive(active) {
    this.active = active;
    if (active) this.render();
  }

  catalogChanged() {
    if (this.active) this.render();
  }

  resultFor(algorithm, shape = this.shape) {
    return this.results.get(`${algorithm.id}@${algorithm.revision}@${shape}`) ?? null;
  }

  run() {
    if (this.job || !this.connection.connected) return;
    const runnable = this.catalog.list.filter(algorithm => algorithm.status !== 'error');
    let ids = runnable.filter(algorithm => !this.resultFor(algorithm)).map(algorithm => algorithm.id);
    if (!ids.length) ids = runnable.map(algorithm => algorithm.id);
    if (!ids.length) return;
    for (const id of ids) {
      const algorithm = this.catalog.get(id);
      if (algorithm) this.results.delete(`${algorithm.id}@${algorithm.revision}@${this.shape}`);
    }
    const cases = ANALYZE_SIZES.map(n => makeInput(n, this.shape, 1000 + n));
    this.job = {jobId: `analysis-${++jobCounter}`, shape: this.shape, pending: new Set(ids), total: ids.length};
    this.connection.send({action: 'analyze', jobId: this.job.jobId, ids, cases});
    this.render();
  }

  cancel() {
    if (!this.job) return;
    this.connection.send({action: 'cancel', jobId: this.job.jobId});
    this.job = null;
    this.render();
  }

  // ------------------------------------------------------------------ data

  isValid(result) {
    return result?.status === 'done' && result.correct === true && Array.isArray(result.benchmarks) &&
      result.benchmarks.length > 0;
  }

  aggregate(result) {
    return result.benchmarks.reduce((sum, point) => sum + point.score, 0);
  }

  series() {
    const divide = DIVISORS[this.divisor].f;
    return this.catalog.list
      .map(algorithm => ({algorithm, result: this.resultFor(algorithm)}))
      .filter(({result}) => this.isValid(result))
      .sort((a, b) => this.aggregate(a.result) - this.aggregate(b.result))
      .map(({algorithm, result}) => ({
        algorithm,
        points: result.benchmarks.map(point => ({...point, value: point.score / divide(point.n)})),
      }));
  }

  tx(n) {
    return this.logX ? Math.log10(Math.max(1, n)) : n;
  }

  ty(value) {
    return this.logY ? Math.log10(Math.max(1e-9, value)) : value;
  }

  inverseY(value) {
    return this.logY ? Math.pow(10, value) : value;
  }

  autoDomain(series) {
    const xs = ANALYZE_SIZES.map(n => this.tx(n));
    const values = series.flatMap(s => s.points.map(p => this.ty(p.value)));
    let y0 = this.logY ? Math.min(...values) : 0;
    let y1 = Math.max(...values);
    if (!values.length) [y0, y1] = [0, 1];
    if (y1 <= y0) y1 = y0 + 1;
    const pad = (y1 - y0) * 0.06;
    return {x0: Math.min(...xs), x1: Math.max(...xs), y0: this.logY ? y0 - pad : y0, y1: y1 + pad};
  }

  // ------------------------------------------------------------------ chart

  bindChart() {
    const chart = $('chart');
    let drag = null;
    chart.addEventListener('pointerdown', event => {
      if (!this.layout) return;
      drag = {x: event.clientX, y: event.clientY, view: {...this.currentDomain}, moved: false};
      chart.setPointerCapture(event.pointerId);
    });
    chart.addEventListener('pointermove', event => {
      if (!this.layout) return;
      if (drag) {
        const dx = event.clientX - drag.x, dy = event.clientY - drag.y;
        if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true;
        if (drag.moved) {
          const {plotWidth, plotHeight} = this.layout;
          const v = drag.view;
          const sx = (v.x1 - v.x0) / plotWidth, sy = (v.y1 - v.y0) / plotHeight;
          this.view = {x0: v.x0 - dx * sx, x1: v.x1 - dx * sx, y0: v.y0 + dy * sy, y1: v.y1 + dy * sy};
          this.renderChart();
          return;
        }
      }
      this.hover(event);
    });
    chart.addEventListener('pointerup', event => {
      if (drag && !drag.moved) {
        const hit = this.nearest(event);
        if (hit) {
          this.pinned = this.pinned === hit.series.algorithm.id ? null : hit.series.algorithm.id;
          this.render();
        }
      }
      drag = null;
    });
    chart.addEventListener('pointerleave', () => {
      if (drag) return;
      this.hovered = null;
      $('chart-tooltip').hidden = true;
      this.renderHighlight();
    });
    chart.addEventListener('wheel', event => {
      if (!this.layout) return;
      event.preventDefault();
      const {left, top, plotWidth, plotHeight} = this.layout;
      const bounds = chart.getBoundingClientRect();
      const u = Math.max(0, Math.min(1, (event.clientX - bounds.left - left) / plotWidth));
      const v = Math.max(0, Math.min(1, (event.clientY - bounds.top - top) / plotHeight));
      const factor = Math.exp(Math.sign(event.deltaY) * 0.15);
      const d = this.currentDomain;
      const x = d.x0 + u * (d.x1 - d.x0), y = d.y1 - v * (d.y1 - d.y0);
      const auto = this.autoDomain(this.lastSeries ?? []);
      const width = Math.min((auto.x1 - auto.x0) * 1.02, (d.x1 - d.x0) * factor);
      const height = Math.min((auto.y1 - auto.y0) * 4, (d.y1 - d.y0) * factor);
      this.view = {x0: x - u * width, x1: x - u * width + width, y1: y + v * height, y0: y + v * height - height};
      this.renderChart();
    }, {passive: false});
    chart.addEventListener('dblclick', () => {
      this.view = null;
      this.renderChart();
    });
  }

  nearest(event) {
    if (!this.layout || !this.lastSeries) return null;
    const bounds = $('chart').getBoundingClientRect();
    const px = event.clientX - bounds.left, py = event.clientY - bounds.top;
    let best = null;
    for (const series of this.lastSeries) {
      for (const point of series.points) {
        const x = this.layout.sx(this.tx(point.n)), y = this.layout.sy(this.ty(point.value));
        const distance = Math.hypot(x - px, y - py);
        if (distance <= 36 && (!best || distance < best.distance)) best = {series, point, distance, x, y};
      }
    }
    return best;
  }

  hover(event) {
    const hit = this.nearest(event);
    const tooltip = $('chart-tooltip');
    const id = hit?.series.algorithm.id ?? null;
    if (id !== this.hovered) {
      this.hovered = id;
      this.renderHighlight();
    }
    if (!hit) {
      tooltip.hidden = true;
      return;
    }
    const {algorithm} = hit.series;
    const {point} = hit;
    const lines = [
      el('strong', {style: `color:${mix(algorithm.color, 'white', 0.45)}`}, `${algorithm.name} · ${algorithm.author}`),
      el('span', {}, `n = ${point.n} · score ${compactCount(point.score)}`),
    ];
    if (this.divisor !== '1') lines.push(el('span', {}, `${DIVISORS[this.divisor].label} = ${formatScore(point.value)}`));
    lines.push(el('span', {class: 'muted'}, `${compactCount(point.reads)} reads · ${compactCount(point.writes)} writes · ` +
      `${compactCount(point.comparisons)} comparisons`));
    tooltip.replaceChildren(...lines);
    tooltip.hidden = false;
    const wrap = tooltip.parentElement.getBoundingClientRect();
    const width = tooltip.offsetWidth, height = tooltip.offsetHeight;
    const left = Math.min(wrap.width - width - 4, Math.max(4, hit.x + 14));
    const top = hit.y - height - 12 < 4 ? hit.y + 14 : hit.y - height - 12;
    tooltip.style.left = `${left}px`;
    tooltip.style.top = `${top}px`;
  }

  get highlighted() {
    return this.pinned ?? this.hovered;
  }

  renderHighlight() {
    const highlighted = this.highlighted;
    for (const group of $('chart').querySelectorAll('.series')) {
      const id = group.dataset.id;
      group.classList.toggle('highlighted', highlighted === id);
      group.classList.toggle('dimmed', highlighted !== null && highlighted !== id);
    }
    for (const row of $('results').querySelectorAll('.result-row')) {
      row.classList.toggle('highlighted', row.dataset.id === highlighted);
    }
  }

  renderChart() {
    const chart = $('chart');
    const wrap = chart.parentElement;
    const width = wrap.clientWidth, height = wrap.clientHeight;
    const series = this.series();
    this.lastSeries = series;
    $('chart-empty').hidden = series.length > 0;
    $('chart-empty').textContent = this.job ? 'Analyzing…'
      : this.catalog.list.length ? 'Run the class-wide correctness, stability and complexity analysis.'
        : 'The class repository has no algorithms yet.';
    chart.setAttribute('viewBox', `0 0 ${Math.max(1, width)} ${Math.max(1, height)}`);
    chart.replaceChildren();
    const titleParts = [DIVISORS[this.divisor].label === 'score' ? 'Sandbox score' : `Sandbox ${DIVISORS[this.divisor].label}`];
    if (this.logX || this.logY) titleParts.push(`logarithmic ${[this.logX && 'x', this.logY && 'y'].filter(Boolean).join('/')}`);
    titleParts.push(shapeLabel(this.shape).toLowerCase());
    $('chart-title').textContent = titleParts.join(' · ');
    $('chart-unpin').hidden = this.pinned === null;
    if (!series.length || width < 50 || height < 50) {
      this.layout = null;
      return;
    }
    const domain = this.view ?? this.autoDomain(series);
    this.currentDomain = domain;
    const left = 58, right = 16, top = 12, bottom = 30;
    const plotWidth = width - left - right, plotHeight = height - top - bottom;
    const sx = x => left + ((x - domain.x0) / (domain.x1 - domain.x0)) * plotWidth;
    const sy = y => top + plotHeight - ((y - domain.y0) / (domain.y1 - domain.y0)) * plotHeight;
    this.layout = {left, top, plotWidth, plotHeight, sx, sy};

    const axes = svg('g', {class: 'axes'});
    const clipId = 'chart-clip';
    const defs = svg('defs');
    const clip = svg('clipPath', {id: clipId});
    clip.append(svg('rect', {x: left, y: top, width: plotWidth, height: plotHeight}));
    defs.append(clip);
    chart.append(defs, axes);

    // y axis
    const yTicks = this.logY ? logTicks(domain.y0, domain.y1) : linearTicks(domain.y0, domain.y1);
    for (const tick of yTicks) {
      const y = sy(tick);
      if (y < top - 1 || y > top + plotHeight + 1) continue;
      axes.append(svg('line', {class: 'grid', x1: left, x2: left + plotWidth, y1: y, y2: y}));
      const label = svg('text', {class: 'tick', x: left - 8, y: y + 3.5, 'text-anchor': 'end'});
      label.textContent = formatScore(this.inverseY(tick));
      axes.append(label);
    }
    // x axis: the benchmark sizes themselves
    for (const n of ANALYZE_SIZES) {
      const x = sx(this.tx(n));
      if (x < left - 1 || x > left + plotWidth + 1) continue;
      axes.append(svg('line', {class: 'grid grid-x', x1: x, x2: x, y1: top, y2: top + plotHeight}));
      const label = svg('text', {class: 'tick', x, y: top + plotHeight + 18, 'text-anchor': 'middle'});
      label.textContent = compactCount(n);
      axes.append(label);
    }
    axes.append(svg('line', {class: 'axis', x1: left, x2: left + plotWidth, y1: top + plotHeight, y2: top + plotHeight}));
    const xTitle = svg('text', {class: 'axis-title', x: left + plotWidth, y: top + plotHeight + 18, 'text-anchor': 'end'});
    xTitle.textContent = '';
    axes.append(xTitle);

    const plot = svg('g', {'clip-path': `url(#${clipId})`});
    chart.append(plot);
    for (const {algorithm, points} of series) {
      const group = svg('g', {class: 'series', 'data-id': algorithm.id, style: `--series:${algorithm.color}`});
      const path = points.map((p, i) => `${i ? 'L' : 'M'}${sx(this.tx(p.n)).toFixed(1)},${sy(this.ty(p.value)).toFixed(1)}`).join('');
      group.append(svg('path', {class: 'series-line', d: path}));
      for (const p of points) {
        group.append(svg('circle', {class: 'series-dot', cx: sx(this.tx(p.n)), cy: sy(this.ty(p.value)), r: 3}));
      }
      plot.append(group);
    }
    this.renderHighlight();
  }

  // ------------------------------------------------------------------ table

  renderToolbar() {
    const button = $('analyze-run');
    const runnable = this.catalog.list.filter(algorithm => algorithm.status !== 'error');
    const missing = runnable.filter(algorithm => !this.resultFor(algorithm)).length;
    button.replaceChildren(icon(this.job ? 'player-stop' : 'chart-line'),
      el('span', {}, this.job ? 'Stop' : missing === runnable.length ? 'Analyze all'
        : missing ? `Analyze ${missing} new` : 'Analyze again'));
    button.disabled = !this.job && (!runnable.length || !this.connection.connected);
    button.classList.toggle('danger', Boolean(this.job));
    for (const id of ['analyze-shape']) $(id).disabled = Boolean(this.job);
    const status = $('analyze-status');
    if (this.job) {
      status.textContent = `Analyzing ${this.job.total - this.job.pending.size + 1 > this.job.total
        ? this.job.total : this.job.total - this.job.pending.size + 1} of ${this.job.total}…`;
    } else {
      const done = runnable.filter(algorithm => this.resultFor(algorithm)).length;
      status.textContent = done ? `${done} of ${runnable.length} analyzed` : '';
    }
  }

  render() {
    this.renderToolbar();
    this.renderTable();
    this.renderChart();
  }

  renderTable() {
    const container = $('results');
    const rows = sortAlgorithms(this.catalog.list).map(algorithm => ({algorithm, result: this.resultFor(algorithm)}));
    rows.sort((a, b) => {
      const av = this.isValid(a.result), bv = this.isValid(b.result);
      if (av !== bv) return av ? -1 : 1;
      if (av && bv) return this.aggregate(a.result) - this.aggregate(b.result);
      return 0;
    });
    let rank = 0;
    if (!rows.length) {
      container.replaceChildren(el('p', {class: 'muted results-empty'}, 'No algorithms in the class repository yet.'));
      return;
    }
    container.replaceChildren(...rows.map(({algorithm, result}) => {
      const valid = this.isValid(result);
      const marker = valid
        ? el('span', {class: 'rank', style: `--series:${algorithm.color};background:${alpha(algorithm.color, 0.22)};` +
            `border-color:${alpha(algorithm.color, 0.6)};color:${mix(algorithm.color, 'white', 0.62)}`}, String(++rank))
        : el('span', {class: 'rank rank-none'}, swatch(algorithm.color));
      const info = el('div', {class: 'result-info'},
        el('div', {class: 'result-name'}, algorithm.name, el('span', {class: 'result-author'}, ` · ${algorithm.author}`)),
        el('div', {class: `result-status ${this.statusClass(algorithm, result)}`}, this.statusText(algorithm, result)));
      const latest = valid ? result.benchmarks[result.benchmarks.length - 1] : null;
      if (latest) {
        info.append(el('div', {class: 'result-metrics'},
          el('span', {class: 'muted'}, `n = ${latest.n}: `),
          `${compactCount(latest.reads)} reads · ${compactCount(latest.writes)} writes · ${compactCount(latest.comparisons)} comparisons`));
      } else if (result?.status === 'done' && result.failingCase) {
        info.append(el('div', {class: 'result-metrics'}, el('span', {class: 'muted'}, 'Failing input: '),
          el('code', {}, result.failingCase)));
      }
      const pending = this.job?.pending.has(algorithm.id);
      const side = el('div', {class: 'result-side'});
      if (valid) {
        side.append(el('strong', {class: 'aggregate'}, compactCount(this.aggregate(result))),
          el('span', {class: 'muted aggregate-label'}, 'total score'));
      } else if (pending) {
        side.append(icon('loader-2', 'spinner-icon'));
      }
      const open = el('button', {type: 'button', class: 'icon-button open-button', title: 'Open in Explore',
        'aria-label': `Open ${algorithm.name} in Explore`,
        onclick: event => {
          event.stopPropagation();
          this.openInExplore(algorithm.id);
        }}, icon('external-link'));
      const row = el('div', {
        class: `result-row${valid ? ' selectable' : ''}${this.pinned === algorithm.id ? ' pinned' : ''}`,
        dataset: {id: algorithm.id}, style: `--series:${algorithm.color}`,
      }, marker, info, side, open);
      if (valid) {
        row.addEventListener('pointerenter', () => {
          this.hovered = algorithm.id;
          this.renderHighlight();
        });
        row.addEventListener('pointerleave', () => {
          this.hovered = null;
          this.renderHighlight();
        });
        row.addEventListener('click', () => {
          this.pinned = this.pinned === algorithm.id ? null : algorithm.id;
          this.render();
        });
      }
      return row;
    }));
  }

  statusClass(algorithm, result) {
    if (algorithm.status === 'error' || (result && result.status !== 'done') ||
        (result?.status === 'done' && !result.correct)) return 'bad';
    if (this.isValid(result)) return result.stable ? 'good' : 'ok';
    return '';
  }

  statusText(algorithm, result) {
    if (algorithm.status === 'error') return 'does not compile';
    if (this.job?.pending.has(algorithm.id) && !result) return 'waiting…';
    if (!result) return 'not analyzed yet';
    switch (result.status) {
      case 'compile': return 'does not compile';
      case 'timeout': return 'timeout: did not finish';
      case 'crash': return `error: ${result.message ?? 'the worker failed'}`;
      case 'missing': return 'removed';
      case 'done': break;
      default: return result.status;
    }
    if (!result.correct) {
      if (result.error) {
        const line = Number.isInteger(result.error.line) ? ` (line ${result.error.line})` : '';
        return `incorrect: exception${line}: ${result.error.message ?? ''}`;
      }
      return `incorrect: ${result.reason ?? 'wrong result'}`;
    }
    return result.stable ? 'correct · stable (tested)' : 'correct · unstable';
  }
}

function logTicks(min, max) {
  const ticks = [];
  const first = Math.floor(min), last = Math.ceil(max);
  const dense = last - first <= 2;
  for (let power = first; power <= last; power++) {
    for (const factor of dense ? [1, 2, 5] : [1]) {
      const value = power + Math.log10(factor);
      if (value >= min && value <= max) ticks.push(value);
    }
  }
  return ticks;
}
