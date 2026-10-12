// The algorithm catalog pushed by the host, plus the picker used in Explore.
import {el, icon, sortAlgorithms} from './util.js';
import {fileStem, languageOf} from './languages.js';

export class CatalogStore {
  constructor(connection) {
    this.byId = new Map();
    this.list = [];
    this.exists = true;
    this.repository = 'algorithms';
    this.loaded = false;
    this.listeners = new Set();
    connection.on('catalog', message => this.receive(message));
  }

  receive(message) {
    const previous = this.byId;
    const algorithms = Array.isArray(message.algorithms) ? message.algorithms : [];
    disambiguate(algorithms);
    this.byId = new Map(algorithms.map(algorithm => [algorithm.id, algorithm]));
    this.list = sortAlgorithms(algorithms);
    this.exists = message.exists !== false;
    this.repository = message.repository || 'algorithms';
    this.loaded = true;
    for (const listener of this.listeners) listener(previous);
  }

  get(id) {
    return this.byId.get(id) ?? null;
  }

  onChange(listener) {
    this.listeners.add(listener);
  }
}

/**
 * A student may keep several versions of one algorithm (e.g. recursive and
 * iterative). When two share a name and author, append the file name so
 * every picker, lane and table row stays distinguishable.
 */
export function disambiguate(algorithms) {
  const key = algorithm => `${String(algorithm.name).trim().toLowerCase()}\u0000${algorithm.author}`;
  const counts = new Map();
  for (const algorithm of algorithms) counts.set(key(algorithm), (counts.get(key(algorithm)) ?? 0) + 1);
  for (const algorithm of algorithms) {
    if (counts.get(key(algorithm)) > 1) {
      const file = fileStem(algorithm.path ?? algorithm.id);
      algorithm.name = `${algorithm.name} (${file})`;
    }
  }
  return algorithms;
}

export const isBusy = algorithm =>
  ['checking', 'queued', 'building'].includes(algorithm?.status);

export function statusIcon(algorithm) {
  if (!algorithm) return null;
  if (algorithm.status === 'error') {
    return el('span', {class: 'status-icon status-error', title: algorithm.message || 'Compilation errors'},
      icon('alert-triangle'));
  }
  if (isBusy(algorithm)) {
    return el('span', {class: 'status-icon status-busy',
      title: algorithm.status === 'building' ? 'Compiling…' : 'Checking…'}, icon('loader-2', 'spinner-icon'));
  }
  return null;
}

export const swatch = color => el('span', {class: 'swatch', style: `--swatch:${color}`});

/** True when the class writes in more than one language. */
export const mixedLanguages = algorithms =>
  new Set(algorithms.map(algorithm => languageOf(algorithm).id)).size > 1;

/** A small "Python" tag, shown only when the class mixes languages. */
export function languageTag(algorithm, algorithms) {
  return mixedLanguages(algorithms)
    ? el('span', {class: 'picker-language'}, languageOf(algorithm).label)
    : null;
}

/** A searchable dropdown of all algorithms, in teaching-family order. */
export class AlgorithmPicker {
  constructor(container, store, {onSelect}) {
    this.store = store;
    this.onSelect = onSelect;
    this.value = null;
    this.open = false;
    this.active = 0;
    this.filtered = [];

    this.button = el('button', {type: 'button', class: 'picker-button', 'aria-haspopup': 'listbox',
      'aria-expanded': 'false', onclick: () => this.toggle()});
    this.filter = el('input', {type: 'search', class: 'picker-filter', placeholder: 'Filter by name, student or language…',
      'aria-label': 'Filter algorithms', autocomplete: 'off', spellcheck: 'false'});
    this.options = el('div', {class: 'picker-options', role: 'listbox', 'aria-label': 'Algorithms'});
    this.popover = el('div', {class: 'picker-popover', hidden: true}, this.filter, this.options);
    container.append(this.button, this.popover);

    this.filter.addEventListener('input', () => {
      this.active = 0;
      this.renderOptions();
    });
    this.filter.addEventListener('keydown', event => this.keydown(event));
    this.button.addEventListener('keydown', event => {
      if (event.key === 'ArrowDown' && !this.open) {
        event.preventDefault();
        this.toggle(true);
      }
    });
    document.addEventListener('pointerdown', event => {
      if (this.open && !container.contains(event.target)) this.toggle(false);
    });
    store.onChange(() => this.render());
    this.render();
  }

  setValue(id) {
    this.value = id;
    this.render();
  }

  setEnabled(enabled) {
    this.button.disabled = !enabled;
    if (!enabled) this.toggle(false);
  }

  toggle(force) {
    const open = force ?? !this.open;
    if (open === this.open) return;
    this.open = open;
    this.popover.hidden = !open;
    this.button.setAttribute('aria-expanded', String(open));
    if (open) {
      this.filter.value = '';
      const index = this.store.list.findIndex(algorithm => algorithm.id === this.value);
      this.active = Math.max(0, index);
      this.renderOptions();
      this.filter.focus();
      this.options.children[this.active]?.scrollIntoView({block: 'nearest'});
    }
  }

  keydown(event) {
    if (event.key === 'Escape') {
      this.toggle(false);
      this.button.focus();
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (!this.filtered.length) return;
      this.active = (this.active + (event.key === 'ArrowDown' ? 1 : -1) + this.filtered.length) %
        this.filtered.length;
      this.renderOptions();
      this.options.children[this.active]?.scrollIntoView({block: 'nearest'});
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const choice = this.filtered[this.active];
      if (choice) this.choose(choice.id);
    }
  }

  choose(id) {
    this.toggle(false);
    this.button.focus();
    if (id !== this.value) this.onSelect(id);
  }

  render() {
    const algorithm = this.store.get(this.value);
    this.button.replaceChildren();
    if (!algorithm) {
      this.button.append(el('span', {class: 'picker-placeholder'},
        this.store.list.length ? 'Choose an algorithm' : 'No algorithms yet'));
    } else {
      this.button.append(swatch(algorithm.color),
        el('span', {class: 'picker-name'}, algorithm.name),
        el('span', {class: 'picker-author'}, algorithm.author));
      const tag = languageTag(algorithm, this.store.list);
      if (tag) this.button.append(tag);
      const status = statusIcon(algorithm);
      if (status) this.button.append(status);
    }
    this.button.append(icon('chevron-down', 'picker-chevron'));
    if (this.open) this.renderOptions();
  }

  renderOptions() {
    // All typed words must match, as in the other sandboxes: "merge python".
    const words = this.filter.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    this.filtered = this.store.list.filter(algorithm => {
      const text = `${algorithm.name} ${algorithm.author} ${algorithm.id} ${languageOf(algorithm).label}`.toLowerCase();
      return words.every(word => text.includes(word));
    });
    if (this.active >= this.filtered.length) this.active = Math.max(0, this.filtered.length - 1);
    this.options.replaceChildren(...this.filtered.map((algorithm, index) => {
      const option = el('div', {
        class: `picker-option${index === this.active ? ' active' : ''}${algorithm.id === this.value ? ' selected' : ''}`,
        role: 'option', 'aria-selected': String(algorithm.id === this.value),
        onpointerdown: event => event.preventDefault(),
        onclick: () => this.choose(algorithm.id),
        onpointermove: () => {
          if (this.active === index) return;
          this.active = index;
          for (const [i, child] of [...this.options.children].entries()) child.classList.toggle('active', i === index);
        },
      }, swatch(algorithm.color),
      el('span', {class: 'picker-name'}, algorithm.name),
      el('span', {class: 'picker-author'}, algorithm.author));
      const tag = languageTag(algorithm, this.store.list);
      if (tag) option.append(tag);
      const status = statusIcon(algorithm);
      if (status) option.append(status);
      option.append(el('span', {class: 'picker-check'}, algorithm.id === this.value ? icon('check') : null));
      return option;
    }));
    if (!this.filtered.length) {
      this.options.append(el('div', {class: 'picker-empty'},
        this.store.list.length ? 'No algorithm matches this filter.' : 'The class repository has no algorithms yet.'));
    }
  }
}
