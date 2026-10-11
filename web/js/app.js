// Entry point: one connection, one catalog, three views.
import {$, el, icon, loadPreferences, savePreferences} from './util.js';
import {Connection} from './connection.js';
import {CatalogStore, swatch} from './catalog.js';
import {SourceEditor} from './editor.js';
import {ExploreView} from './explore.js';
import {RaceView} from './race.js';
import {AnalyzeView} from './analyze.js';

const preferences = loadPreferences();
const connection = new Connection();
const catalog = new CatalogStore(connection);

const editor = new SourceEditor(connection, {
  container: $('source-editor'), save: $('source-save'), revert: $('source-revert'),
  format: $('source-format'), title: $('source-title'), chip: $('source-chip'),
  status: $('source-status'), problems: $('source-problems'),
  problemCount: $('source-problem-count'), problemList: $('source-problem-list'),
});

const views = {};
function openInExplore(id) {
  showView('explore');
  views.explore.select(id);
}
views.explore = new ExploreView({connection, catalog, editor, preferences});
views.race = new RaceView({connection, catalog, preferences, openInExplore});
views.analyze = new AnalyzeView({connection, catalog, preferences, openInExplore});

// ------------------------------------------------------------------ tabs

let current = null;
function showView(name) {
  if (!views[name] || name === current) return;
  current = name;
  for (const button of document.querySelectorAll('[data-view]')) {
    const selected = button.dataset.view === name;
    button.setAttribute('aria-selected', String(selected));
    button.tabIndex = selected ? 0 : -1;
  }
  for (const [key, view] of Object.entries(views)) {
    $(`view-${key}`).hidden = key !== name;
    view.setActive(key === name);
  }
  savePreferences({view: name});
  if (location.hash !== `#${name}`) history.replaceState(null, '', `#${name}`);
}
for (const button of document.querySelectorAll('[data-view]')) {
  button.addEventListener('click', () => showView(button.dataset.view));
  button.addEventListener('keydown', event => {
    if (event.key !== 'ArrowRight' && event.key !== 'ArrowLeft') return;
    const tabs = [...document.querySelectorAll('[data-view]')];
    const index = tabs.indexOf(button) + (event.key === 'ArrowRight' ? 1 : -1);
    const next = tabs[(index + tabs.length) % tabs.length];
    next.focus();
    showView(next.dataset.view);
  });
}
window.addEventListener('hashchange', () => showView(location.hash.slice(1)));

// ------------------------------------------------------------ connection

connection.onStatus(state => {
  const label = $('connection');
  label.textContent = {
    connecting: 'Connecting…', reconnecting: 'Reconnecting…', connected: 'Connected',
    disconnected: 'Connection lost · reconnecting…',
  }[state] ?? state;
  label.className = `connection ${state}`;
});

// --------------------------------------------------------------- catalog

catalog.onChange(() => {
  const missing = $('repository-missing');
  missing.hidden = catalog.exists;
  if (!catalog.exists) {
    missing.replaceChildren(icon('info-circle'), el('span', {},
      'The class repository ', el('code', {}, catalog.repository), ' does not exist yet. Clone it from a terminal: ',
      el('code', {}, `git clone <class-repository-url> ${catalog.repository}`),
      ' — the app picks it up automatically.'));
  } else if (!catalog.list.length) {
    missing.hidden = false;
    missing.replaceChildren(icon('info-circle'), el('span', {},
      'No algorithms yet. Create one from a terminal in the app folder: ',
      el('code', {}, './new-algorithm YOUR_NAME'), ' — it appears here automatically.'));
  }
  renderProblems();
  views.explore.catalogChanged();
  views.race.catalogChanged();
  views.analyze.catalogChanged();
});

function renderProblems() {
  const broken = catalog.list.filter(algorithm => algorithm.status === 'error');
  const button = $('problems-open');
  button.hidden = !broken.length;
  button.replaceChildren(icon('alert-triangle'),
    el('span', {}, broken.length === 1 ? '1 file with errors' : `${broken.length} files with errors`));
  $('problems-list').replaceChildren(...broken.map(algorithm => el('li', {},
    el('button', {type: 'button', class: 'problem-file', onclick: () => {
      $('problems-dialog').close();
      openInExplore(algorithm.id);
    }}, swatch(algorithm.color), el('strong', {}, algorithm.path),
    el('span', {class: 'muted'}, algorithm.diagnostics?.[0]
      ? `line ${algorithm.diagnostics[0].line}: ${algorithm.diagnostics[0].message}`
      : (algorithm.message ?? 'Cannot be compiled'))))));
  if (!broken.length && $('problems-dialog').open) $('problems-dialog').close();
}
$('problems-open').addEventListener('click', () => $('problems-dialog').showModal());
$('problems-close').addEventListener('click', () => $('problems-dialog').close());

// A click on the backdrop closes a dialog, as in the Data Structure Sandbox.
for (const dialog of document.querySelectorAll('dialog.app-dialog')) {
  dialog.addEventListener('click', event => { if (event.target === dialog) dialog.close(); });
}

// ------------------------------------------------------------------ start

const initial = location.hash.slice(1);
showView(views[initial] ? initial : (views[preferences.view] ? preferences.view : 'explore'));
connection.connect();
