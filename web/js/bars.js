// Canvas renderer for one array: bars in the algorithm's color, read/write
// caps, variable bands at the foot of a bar and a fixed-height gutter with
// labelled index pointers (i, j, left, right, …).
import {alpha, mix} from './util.js';

// The pointer color follows the theme (--pointer in style.css / light.css).
const pointerColor = () =>
  getComputedStyle(document.documentElement).getPropertyValue('--pointer').trim() || '#7dd3fc';
const READ = '#ffab40';
const WRITE = '#ff5252';
const GUTTER = 46;

export class ArrayCanvas {
  constructor(canvas, {pointerGutter = true} = {}) {
    this.canvas = canvas;
    this.context = canvas.getContext('2d');
    this.pointerGutter = pointerGutter;
    this.state = {values: [], maxValue: 1, color: '#7c8796', reads: new Set(), writes: new Set(),
      variables: new Map()};
    this.scheduled = false;
    this.observer = new ResizeObserver(() => this.schedule());
    this.observer.observe(canvas);
    window.addEventListener('sandbox-theme', () => this.schedule());
  }

  set(patch) {
    Object.assign(this.state, patch);
    this.schedule();
  }

  schedule() {
    if (this.scheduled) return;
    this.scheduled = true;
    requestAnimationFrame(() => {
      this.scheduled = false;
      this.draw();
    });
  }

  draw() {
    const canvas = this.canvas;
    const ratio = window.devicePixelRatio || 1;
    const width = canvas.clientWidth, height = canvas.clientHeight;
    if (!width || !height) return;
    if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
    }
    const g = this.context;
    g.setTransform(ratio, 0, 0, ratio, 0, 0);
    g.clearRect(0, 0, width, height);
    const {values, color, reads, writes, variables} = this.state;
    const POINTER = pointerColor();
    const n = values.length;
    if (!n) return;
    const maxValue = Math.max(1, this.state.maxValue || Math.max(...values));
    const gutter = this.pointerGutter ? GUTTER : 0;
    const barsHeight = height - gutter;
    const slot = width / n;
    const barWidth = Math.max(1, Math.min(slot * 0.72, 24));
    const radius = barWidth >= 4 ? 2 : 0;
    const gradients = n <= 256;
    const light = mix(color, 'white', 0.26), dark = mix(color, 'black', 0.16);

    const variableCounts = new Map();
    for (const index of variables.values()) {
      if (index >= 0 && index < n) variableCounts.set(index, (variableCounts.get(index) ?? 0) + 1);
    }

    for (let i = 0; i < n; i++) {
      const value = values[i];
      if (!(value > 0)) continue;
      const display = Math.pow(Math.min(1, value / maxValue), 0.52);
      const h = Math.max(1, display * (barsHeight - 6));
      const x = i * slot + (slot - barWidth) / 2;
      const y = barsHeight - h;
      if (gradients) {
        const gradient = g.createLinearGradient(0, barsHeight, 0, y);
        gradient.addColorStop(0, dark);
        gradient.addColorStop(0.58, color);
        gradient.addColorStop(1, light);
        g.fillStyle = gradient;
      } else {
        g.fillStyle = color;
      }
      roundedRect(g, x, y, barWidth, h, radius, radius, 0);
      g.fill();

      const count = variableCounts.get(i) ?? 0;
      if (count) {
        const band = Math.min(h, count === 1 ? 3.5 : 6);
        g.fillStyle = alpha(POINTER, count === 1 ? 0.68 : 0.96);
        roundedRect(g, x, barsHeight - band, barWidth, band, 0, 0, radius);
        g.fill();
      }

      const isRead = reads.has(i), isWrite = writes.has(i);
      if (isRead || isWrite) {
        const cap = Math.min(h / (isRead && isWrite ? 2 : 1), 3.5);
        if (isRead) {
          g.fillStyle = READ;
          roundedRect(g, x, y, barWidth, cap, radius, radius, 0);
          g.fill();
        }
        if (isWrite) {
          g.fillStyle = WRITE;
          const top = y + (isRead ? cap : 0);
          roundedRect(g, x, top, barWidth, cap, isRead ? 0 : radius, isRead ? 0 : radius, 0);
          g.fill();
        }
      }
    }

    if (gutter && variables.size) this.drawPointers(g, width, barsHeight, n, slot);
  }

  drawPointers(g, width, top, n, slot) {
    const POINTER = pointerColor();
    const byIndex = new Map();
    for (const [name, index] of this.state.variables) {
      if (index < 0 || index > n) continue;
      if (!byIndex.has(index)) byIndex.set(index, []);
      byIndex.get(index).push(name);
    }
    g.font = '600 10px "Open Sans", system-ui, sans-serif';
    g.textBaseline = 'top';
    const labels = [...byIndex].map(([index, names]) => {
      const onePastEnd = index === n;
      const text = names.sort().join(', ') + (onePastEnd ? '  +1' : '');
      return {x: onePastEnd ? width - 4 : (index + 0.5) * slot, text, width: g.measureText(text).width};
    }).sort((a, b) => a.x - b.x);

    // Nearby labels use separate lanes; the gutter height never changes.
    const lanes = 3, laneGap = 4, laneHeight = 11;
    const laneRight = Array(lanes).fill(-Infinity);
    for (const label of labels) {
      const maxLeft = Math.max(0, width - label.width);
      const preferred = Math.min(maxLeft, Math.max(0, label.x - label.width / 2));
      let lane = laneRight.findIndex(right => preferred >= right + laneGap);
      if (lane < 0) {
        lane = 0;
        for (let candidate = 1; candidate < lanes; candidate++) {
          if (laneRight[candidate] < laneRight[lane]) lane = candidate;
        }
      }
      const left = Math.min(maxLeft, Math.max(preferred, laneRight[lane] + laneGap));
      laneRight[lane] = left + label.width;

      const y0 = top + 2;
      g.fillStyle = POINTER;
      g.beginPath();
      g.moveTo(label.x, y0);
      g.lineTo(label.x - 3.5, y0 + 5);
      g.lineTo(label.x + 3.5, y0 + 5);
      g.closePath();
      g.fill();
      const textY = y0 + 10 + lane * laneHeight;
      const center = left + label.width / 2;
      g.strokeStyle = alpha(POINTER, 0.55);
      g.lineWidth = 1;
      g.beginPath();
      g.moveTo(label.x, y0 + 5);
      g.lineTo(label.x, y0 + 8);
      if (Math.abs(center - label.x) > 1) g.lineTo(center, textY - 1);
      g.stroke();
      g.fillText(label.text, left, textY);
    }
  }
}

function roundedRect(g, x, y, width, height, topLeft, topRight, bottom) {
  g.beginPath();
  if (!topLeft && !topRight && !bottom) {
    g.rect(x, y, width, height);
    return;
  }
  const r = Math.min(width / 2, height / 2);
  const tl = Math.min(topLeft, r), tr = Math.min(topRight, r), b = Math.min(bottom, r);
  g.moveTo(x + tl, y);
  g.lineTo(x + width - tr, y);
  g.quadraticCurveTo(x + width, y, x + width, y + tr);
  g.lineTo(x + width, y + height - b);
  g.quadraticCurveTo(x + width, y + height, x + width - b, y + height);
  g.lineTo(x + b, y + height);
  g.quadraticCurveTo(x, y + height, x, y + height - b);
  g.lineTo(x, y + tl);
  g.quadraticCurveTo(x, y, x + tl, y);
  g.closePath();
}
