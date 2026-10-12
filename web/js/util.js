// Small, dependency-free helpers shared by all views. Nothing in this module
// touches the DOM at import time, so it can be unit-tested with Node.

export const $ = id => document.getElementById(id);

/** Creates an element: el('button', {class: 'x', onclick: fn}, 'text', child). */
export function el(tag, attributes = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes)) {
    if (value === undefined || value === null || value === false) continue;
    if (key.startsWith('on') && typeof value === 'function') {
      node.addEventListener(key.slice(2), value);
    } else if (key === 'dataset') {
      Object.assign(node.dataset, value);
    } else if (value === true) {
      node.setAttribute(key, '');
    } else {
      node.setAttribute(key, String(value));
    }
  }
  for (const child of children.flat()) {
    if (child === undefined || child === null || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

const SVG = 'http://www.w3.org/2000/svg';
export function svg(tag, attributes = {}) {
  const node = document.createElementNS(SVG, tag);
  for (const [key, value] of Object.entries(attributes)) {
    if (value !== undefined && value !== null) node.setAttribute(key, String(value));
  }
  return node;
}

/** A Tabler icon from the local sprite. */
export function icon(name, className = '') {
  const node = svg('svg', {class: `ui-icon ${className}`.trim(), viewBox: '0 0 24 24', 'aria-hidden': 'true'});
  node.append(svg('use', {href: `/vendor/tabler-icons.svg#ti-${name}`}));
  return node;
}

export function compactCount(value) {
  const negative = value < 0;
  const absolute = Math.abs(value);
  const prefix = negative ? '-' : '';
  if (absolute < 1000) return `${value}`;
  const scaled = (divisor, suffix) => {
    const amount = absolute / divisor;
    const text = amount.toFixed(amount < 10 ? 1 : 0).replace(/\.0$/, '');
    return `${prefix}${text}${suffix}`;
  };
  if (absolute < 999500) return scaled(1000, 'k');
  if (absolute < 999500000) return scaled(1000000, 'M');
  return scaled(1000000000, 'G');
}

export function groupedCount(value) {
  return Number(value).toLocaleString('en-US');
}

/** Deterministic PRNG (mulberry32): the same seed gives the same input. */
export function random(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6D2B79F5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffle(values, next) {
  for (let i = values.length - 1; i > 0; i--) {
    const j = Math.floor(next() * (i + 1));
    [values[i], values[j]] = [values[j], values[i]];
  }
  return values;
}

export const INPUT_SHAPES = [
  {id: 'random', label: 'Random'},
  {id: 'sorted', label: 'Sorted'},
  {id: 'reversed', label: 'Reversed'},
  {id: 'nearlySorted', label: 'Nearly sorted'},
  {id: 'fewValues', label: 'Few distinct values'},
];

export const shapeLabel = id => INPUT_SHAPES.find(shape => shape.id === id)?.label ?? id;

/** The values 1..n arranged according to [shape]. */
export function makeInput(n, shape, seed = 42) {
  const next = random(seed);
  const ascending = () => Array.from({length: n}, (_, i) => i + 1);
  switch (shape) {
    case 'sorted': return ascending();
    case 'reversed': return Array.from({length: n}, (_, i) => n - i);
    case 'nearlySorted': {
      const values = ascending();
      const swaps = Math.max(1, Math.floor(n / 20));
      for (let i = 0; i < swaps && n > 0; i++) {
        const a = Math.floor(next() * n), b = Math.floor(next() * n);
        [values[a], values[b]] = [values[b], values[a]];
      }
      return values;
    }
    case 'fewValues': {
      const distinct = Math.max(2, Math.min(8, n + 1));
      return Array.from({length: n}, () => 1 + Math.floor(next() * distinct));
    }
    default: return shuffle(ascending(), next);
  }
}

// ---- Algorithm display order: family → variant → author → name → id ------

const FAMILIES = [
  ['bubble sort', 'bubblesort'],
  ['insertion sort', 'insert sort', 'insertionsort', 'insertsort'],
  ['selection sort', 'select sort', 'selectionsort', 'selectsort'],
  ['merge sort', 'mergesort'],
  ['quick sort', 'quicksort'],
];

const normalize = value => String(value ?? '').toLowerCase()
  .replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');

function familyFor(name) {
  for (let rank = 0; rank < FAMILIES.length; rank++) {
    for (const prefix of FAMILIES[rank]) {
      if (name === prefix || name.startsWith(`${prefix} `)) return {rank, prefix};
    }
  }
  return null;
}

function variantKey(name, family, author) {
  let rest = name.slice(family.prefix.length).trim();
  const normalizedAuthor = normalize(author);
  // "Quick Sort by Ovilli" is still a plain Quick Sort, not a variant.
  if (normalizedAuthor && rest === `by ${normalizedAuthor}`) rest = '';
  return rest;
}

const compareText = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

export function compareAlgorithms(a, b) {
  const aName = normalize(a.name), bName = normalize(b.name);
  const aFamily = familyFor(aName), bFamily = familyFor(bName);
  const aRank = aFamily?.rank ?? FAMILIES.length, bRank = bFamily?.rank ?? FAMILIES.length;
  if (aRank !== bRank) return aRank - bRank;
  let comparison = !aFamily && !bFamily
    ? compareText(aName, bName)
    : compareText(variantKey(aName, aFamily, a.author), variantKey(bName, bFamily, b.author));
  if (comparison) return comparison;
  comparison = compareText(normalize(a.author), normalize(b.author));
  if (comparison) return comparison;
  comparison = compareText(aName, bName);
  if (comparison) return comparison;
  return compareText(a.id, b.id);
}

export const sortAlgorithms = list => [...list].sort(compareAlgorithms);

// ---- Colors -----------------------------------------------------------------

export function parseHex(hex) {
  const match = /^#?([0-9a-f]{6})$/i.exec(String(hex ?? ''));
  const value = match ? parseInt(match[1], 16) : 0x7c8796;
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255];
}

export function mix(hex, target, amount) {
  const [r, g, b] = parseHex(hex);
  const [tr, tg, tb] = target === 'white' ? [255, 255, 255] : [0, 0, 0];
  const blend = (c, t) => Math.round(c + (t - c) * amount);
  return `rgb(${blend(r, tr)}, ${blend(g, tg)}, ${blend(b, tb)})`;
}

export function alpha(hex, opacity) {
  const [r, g, b] = parseHex(hex);
  return `rgba(${r}, ${g}, ${b}, ${opacity})`;
}

// ---- Preferences (per browser, never shared) ---------------------------------

const PREFERENCES_KEY = 'sorting-sandbox.v3';

export function loadPreferences() {
  try {
    const saved = JSON.parse(localStorage.getItem(PREFERENCES_KEY) || 'null');
    return saved && typeof saved === 'object' ? saved : {};
  } catch (_) {
    return {};
  }
}

export function savePreferences(patch) {
  try {
    const next = {...loadPreferences(), ...patch};
    localStorage.setItem(PREFERENCES_KEY, JSON.stringify(next));
  } catch (_) {
    // Private windows may refuse storage; preferences are a convenience only.
  }
}

/** "[3, 1, 2]" with an ellipsis for long lists. */
export function formatList(values, limit = 24) {
  if (!Array.isArray(values)) return '';
  const shown = values.slice(0, limit).join(', ');
  return values.length > limit ? `[${shown}, …]` : `[${shown}]`;
}

export function debounceFrame(callback) {
  let scheduled = false;
  return () => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      callback();
    });
  };
}

/**
 * A question in the style of the other dialogs instead of the browser's
 * confirm() (the same dialog in all three sandboxes): resolves true for the
 * main action, false for cancel, Esc, × or a click beside the dialog.
 */
export function askConfirm({title, message, note = '', ok = 'Discard', cancel = 'Keep editing'}) {
  const dialog = $('confirm-dialog');
  $('confirm-title').textContent = title;
  $('confirm-message').textContent = message;
  $('confirm-note').textContent = note;
  $('confirm-ok').querySelector('span').textContent = ok;
  $('confirm-cancel').textContent = cancel;
  return new Promise(resolve => {
    const handlers = [['confirm-ok', () => finish(true)], ['confirm-cancel', () => finish(false)],
      ['confirm-close', () => finish(false)]];
    const onClose = () => finish(false);
    const onBackdrop = event => { if (event.target === dialog) finish(false); };
    function finish(answer) {
      dialog.removeEventListener('close', onClose);
      dialog.removeEventListener('click', onBackdrop);
      for (const [id, handler] of handlers) $(id).removeEventListener('click', handler);
      if (dialog.open) dialog.close();
      resolve(answer);
    }
    for (const [id, handler] of handlers) $(id).addEventListener('click', handler);
    dialog.addEventListener('close', onClose);
    dialog.addEventListener('click', onBackdrop);
    dialog.showModal();
    $('confirm-cancel').focus(); // The safe choice has the focus.
  });
}
