// The browser editor: bundled CodeMirror, revision-checked saves, language-aware
// formatting and compiler diagnostics on the student's original lines.
import {el, icon} from './util.js';
import {LANGUAGES, commentEdits, languageOf} from './languages.js';

export class SourceEditor {
  constructor(connection, ui) {
    this.connection = connection;
    this.ui = ui; // {container, save, revert, format, title, chip, status, problems, problemCount, problemList}
    this.algorithm = null;
    this.id = null;
    this.revision = null;
    this.original = '';
    this.dirty = false;
    this.loading = false;
    this.saving = false;
    this.outdated = false;
    this.formatting = false;
    this.formatRequest = 0;
    this.formatDraft = null;
    this.suppressChange = false;
    this.executionLine = null;
    this.errorLine = null;
    this.marks = [];
    this.appliedDiagnostics = '';
    this.suggestions = [];
    this.suggestionIndex = 0;
    this.listeners = new Set();
    this.language = LANGUAGES.dart;

    this.editor = CodeMirror(ui.container, {
      value: '', mode: 'dart', lineNumbers: true, lineWrapping: false,
      indentUnit: 2, tabSize: 2, indentWithTabs: false, smartIndent: true,
      matchBrackets: true, autoCloseBrackets: true, readOnly: 'nocursor', viewportMargin: 20,
      extraKeys: {
        'Ctrl-S': () => this.save(), 'Cmd-S': () => this.save(),
        // CodeMirror matches key names only in the order Shift-Cmd-Ctrl-Alt.
        'Shift-Ctrl-K': cm => cm.execCommand('deleteLine'),
        'Shift-Cmd-K': cm => cm.execCommand('deleteLine'),
        'Shift-Alt-K': cm => cm.execCommand('deleteLine'),
        'Ctrl-/': cm => this.toggleComment(cm), 'Cmd-/': cm => this.toggleComment(cm),
        'Ctrl-#': cm => this.toggleComment(cm), 'Cmd-#': cm => this.toggleComment(cm),
        'Shift-Ctrl-7': cm => this.toggleComment(cm),
        'Shift-Alt-F': () => this.format(),
        'Ctrl-Space': cm => this.showSuggestions(cm, true),
        'Tab': cm => (cm.somethingSelected() ? cm.indentSelection('add') : cm.execCommand('insertSoftTab')),
        'Shift-Tab': cm => cm.indentSelection('subtract'),
      },
    });
    // Some browsers claim Ctrl+Shift+K for themselves before the editor sees it.
    window.addEventListener('keydown', event => {
      if (!this.editor.hasFocus() || !(event.ctrlKey || event.metaKey) || !event.shiftKey || event.altKey ||
          (event.code !== 'KeyK' && event.key?.toLowerCase() !== 'k') || this.editor.getOption('readOnly')) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      this.editor.execCommand('deleteLine');
    }, true);

    this.completion = el('div', {class: 'source-completions', role: 'listbox', hidden: true,
      'aria-label': 'Code suggestions'});
    this.editor.getWrapperElement().append(this.completion);

    this.editor.on('change', (cm, change) => {
      if (this.suppressChange || this.revision === null) return;
      this.updateDirty();
      if (change?.origin === '+input' && /^[A-Za-z_]$/.test(change.text?.join('') || '')) this.showSuggestions(cm);
      else this.hideSuggestions();
    });
    this.editor.on('keydown', (cm, event) => this.completionKeys(cm, event));
    this.editor.on('blur', () => this.hideSuggestions());

    ui.save.addEventListener('click', () => this.save());
    ui.revert.addEventListener('click', () => this.revert());
    ui.format.addEventListener('click', () => this.format());
    connection.on('sourceFile', message => this.receiveFile(message));
    connection.on('sourceSaved', message => this.receiveSaved(message));
    connection.on('sourceError', message => this.receiveError(message));
    connection.on('sourceFormatted', message => this.receiveFormat(message));
    connection.on('sourceFormatError', message => this.receiveFormat(message));
    connection.onStatus(state => {
      if (state !== 'connected') {
        this.formatting = false;
        this.formatRequest++;
      } else if (this.id && this.revision === null && !this.loading) {
        this.request();
      }
      this.updateButtons();
    });
    window.addEventListener('beforeunload', event => {
      if (!this.dirty) return;
      event.preventDefault();
      event.returnValue = '';
    });
    this.showPlaceholder('Select an algorithm to see its source code.');
  }

  /** Called with 'dirty' / 'saved' / 'loaded' events. */
  onChange(listener) {
    this.listeners.add(listener);
  }

  emit(event) {
    for (const listener of this.listeners) listener(event);
  }

  // ------------------------------------------------------------- selection

  canLeave() {
    return !this.saving && (!this.dirty || window.confirm('Discard your unsaved changes to this file?'));
  }

  open(algorithm) {
    this.hideSuggestions();
    this.clearDiagnostics();
    this.algorithm = algorithm;
    this.applyLanguage(languageOf(algorithm));
    this.id = algorithm?.id ?? null;
    this.revision = null;
    this.original = '';
    this.dirty = false;
    this.saving = false;
    this.loading = false;
    this.outdated = false;
    this.formatting = false;
    this.formatRequest++;
    this.executionLine = null;
    this.errorLine = null;
    this.ui.title.textContent = algorithm ? algorithm.path : 'No algorithm selected';
    if (!algorithm) {
      this.showPlaceholder('Select an algorithm to see its source code.');
    } else {
      this.write('');
      this.writable(false);
      this.request();
    }
    this.updateButtons();
    this.renderChip();
  }

  /** Every catalog update for the selected algorithm (status, diagnostics). */
  sync(algorithm) {
    if (!algorithm || algorithm.id !== this.id) return;
    this.algorithm = algorithm;
    this.ui.title.textContent = algorithm.path;
    if (this.revision !== null && algorithm.revision !== this.revision && !this.saving && !this.loading) {
      if (this.dirty) {
        if (!this.outdated) {
          this.outdated = true;
          this.setStatus('The file changed on disk. Your draft is kept; saving will report a conflict.', true);
        }
      } else {
        this.request();
      }
    }
    this.applyDiagnostics();
    this.renderChip();
  }

  removed() {
    if (!this.id) return;
    this.setStatus('This file was removed from the class repository.', true);
    this.writable(false);
    this.revision = null;
    this.updateButtons();
  }

  request() {
    if (!this.id || this.loading || this.saving) return;
    if (!this.connection.send({action: 'readSource', id: this.id})) return;
    this.loading = true;
    this.setStatus('Loading source…');
  }

  // ------------------------------------------------------------- messages

  receiveFile(message) {
    if (message.id !== this.id || !this.loading) return;
    this.loading = false;
    if (this.dirty || this.saving) {
      this.outdated = true;
      this.setStatus('The file changed on disk. Your draft is kept; saving will report a conflict.', true);
      this.updateButtons();
      return;
    }
    this.revision = message.revision;
    this.original = message.content;
    this.outdated = false;
    this.clearDiagnostics();
    this.write(message.content);
    this.writable(true);
    this.updateDirty();
    this.applyDiagnostics();
    this.renderChip();
    this.emit('loaded');
  }

  receiveSaved(message) {
    if (message.id !== this.id || !this.saving) return;
    this.saving = false;
    this.original = message.content;
    this.revision = message.revision;
    this.outdated = false;
    this.clearDiagnostics();
    this.updateDirty(); // The student may have kept typing during the save.
    this.setStatus(this.dirty ? 'Saved an earlier draft · newer edits are not saved yet' : 'Saved · checking and compiling…');
    this.renderChip();
    this.emit('saved');
  }

  receiveError(message) {
    if (message.id !== this.id) return;
    this.loading = false;
    this.saving = false;
    if (message.conflict) this.outdated = true;
    this.updateButtons();
    this.setStatus(message.message || 'The file could not be accessed.', true);
  }

  // ------------------------------------------------------------- editing

  save() {
    if (this.revision === null || !this.dirty || this.saving || this.loading) return;
    if (!this.connection.send({action: 'saveSource', id: this.id, revision: this.revision,
      content: this.editor.getValue()})) {
      this.setStatus('Not connected to the Dart host; your draft is kept.', true);
      return;
    }
    this.saving = true;
    this.updateButtons();
    this.setStatus('Saving…');
  }

  revert() {
    if (!this.dirty || this.saving || this.revision === null) return;
    if (!window.confirm('Discard unsaved changes and restore the last saved version?')) return;
    this.write(this.original);
    this.updateDirty();
    if (this.outdated) {
      this.revision = null;
      this.request();
    } else {
      this.setStatus('Reverted to the last saved version');
      this.applyDiagnostics();
    }
    this.renderChip();
  }

  format() {
    if (this.revision === null || this.saving || this.loading || this.formatting) return;
    this.hideSuggestions();
    this.formatDraft = this.editor.getValue();
    const requestId = ++this.formatRequest;
    if (!this.connection.send({action: 'formatSource', id: this.id, requestId,
      revision: this.revision, content: this.formatDraft})) return;
    this.formatting = true;
    this.updateButtons();
    this.setStatus('Formatting the current draft…');
  }

  receiveFormat(message) {
    if (!this.formatting || message.requestId !== this.formatRequest || message.id !== this.id) return;
    this.formatting = false;
    this.updateButtons();
    if (this.editor.getValue() !== this.formatDraft) {
      this.setStatus('The draft changed while formatting; run Format again.', true);
      return;
    }
    if (message.type === 'sourceFormatError') {
      this.setStatus(message.message || `${this.language.label} could not format this draft.`, true);
      return;
    }
    if (message.content === this.editor.getValue()) {
      this.setStatus('Already formatted');
      return;
    }
    const cursor = this.editor.getCursor();
    this.editor.operation(() => {
      const last = this.editor.lastLine();
      this.editor.replaceRange(message.content, {line: 0, ch: 0},
        {line: last, ch: this.editor.getLine(last).length}, '+format');
    });
    const line = Math.min(cursor.line, this.editor.lastLine());
    this.editor.setCursor({line, ch: Math.min(cursor.ch, this.editor.getLine(line).length)});
    this.setStatus('Formatted · save with Ctrl+S');
  }

  toggleComment(cm) {
    if (this.revision === null || cm.getOption('readOnly')) return;
    const from = cm.getCursor('from'), to = cm.getCursor('to');
    const last = to.line > from.line && to.ch === 0 ? to.line - 1 : to.line;
    const lines = [];
    for (let line = from.line; line <= last; line++) {
      const text = cm.getLine(line);
      if (text.trim()) lines.push({line, text, indent: (text.match(/^\s*/) || [''])[0].length});
    }
    if (!lines.length) return;
    const edits = commentEdits(lines, this.language.comment);
    cm.operation(() => {
      for (const edit of [...edits].reverse()) {
        const {line} = lines[edit.index];
        cm.replaceRange(edit.insert, {line, ch: edit.from}, {line, ch: edit.to}, '+comment');
      }
    });
  }

  /** Mode, indentation and completion words of the selected file's language. */
  applyLanguage(language) {
    if (this.language === language) return;
    this.language = language;
    this.editor.setOption('mode', language.mode);
    this.editor.setOption('indentUnit', language.indent);
    this.editor.setOption('tabSize', language.indent);
  }

  // ------------------------------------------------------------- display

  /** Highlights the line of the current execution step (or clears it). */
  highlight(line, revision) {
    if (this.executionLine !== null) {
      this.editor.removeLineClass(this.executionLine, 'background', 'source-execution-line');
      this.executionLine = null;
    }
    if (this.dirty || revision !== this.revision || !Number.isInteger(line) ||
        line < 1 || line > this.editor.lineCount()) return;
    this.executionLine = line - 1;
    this.editor.addLineClass(this.executionLine, 'background', 'source-execution-line');
    this.scrollTo(this.executionLine);
  }

  /** Marks the line of a runtime error (cleared on the next run or edit). */
  markError(line, revision) {
    if (this.errorLine !== null) {
      this.editor.removeLineClass(this.errorLine, 'background', 'source-runtime-error-line');
      this.errorLine = null;
    }
    if (this.dirty || revision !== this.revision || !Number.isInteger(line) ||
        line < 1 || line > this.editor.lineCount()) return;
    this.errorLine = line - 1;
    this.editor.addLineClass(this.errorLine, 'background', 'source-runtime-error-line');
    this.scrollTo(this.errorLine);
  }

  jumpTo(line) {
    if (!Number.isInteger(line) || line < 1 || line > this.editor.lineCount()) return;
    this.editor.setCursor({line: line - 1, ch: 0});
    this.scrollTo(line - 1);
    this.editor.focus();
  }

  scrollTo(line) {
    const info = this.editor.getScrollInfo();
    const top = this.editor.heightAtLine(line, 'local');
    if (top < info.top + 30 || top > info.top + info.clientHeight - 50) {
      this.editor.scrollTo(null, Math.max(0, top - info.clientHeight / 3));
    }
  }

  applyDiagnostics() {
    const algorithm = this.algorithm;
    if (!algorithm || this.dirty || this.revision === null || algorithm.revision !== this.revision) return;
    const entries = algorithm.status === 'error' ? (algorithm.diagnostics ?? []) : [];
    const message = algorithm.status === 'error' ? (algorithm.message ?? '') : '';
    const key = JSON.stringify([this.revision, entries, message]);
    if (key === this.appliedDiagnostics) return;
    this.clearDiagnostics();
    this.appliedDiagnostics = key;
    if (algorithm.status !== 'error') return;
    const items = [];
    for (const issue of entries) {
      if (!Number.isInteger(issue.line) || issue.line < 1 || issue.line > this.editor.lineCount()) continue;
      const line = issue.line - 1;
      const text = this.editor.getLine(line);
      const column = Math.max(0, Math.min(text.length, (issue.column || 1) - 1));
      const end = Math.min(text.length, column + Math.max(1, issue.length || 1));
      const note = String(issue.message || `${this.language.label} could not compile this line.`);
      this.editor.addLineClass(line, 'background', 'source-error-line');
      const marker = end > column
        ? this.editor.markText({line, ch: column}, {line, ch: end}, {className: 'source-error-underline', title: note})
        : null;
      this.marks.push({line, marker});
      items.push(el('li', {}, el('button', {type: 'button', class: 'source-problem',
        onclick: () => this.jumpTo(issue.line)}, `Line ${issue.line}, column ${issue.column || 1}: ${note}`)));
    }
    if (!items.length && message) items.push(el('li', {}, el('p', {class: 'source-problem-text'}, message)));
    if (!items.length) return;
    this.ui.problemCount.textContent = this.marks.length
      ? `${this.marks.length === 1 ? '1 problem' : `${this.marks.length} problems`} · select one to jump to it`
      : 'This algorithm cannot be compiled';
    if (this.marks.length && message && !/^Fix the errors/.test(message)) {
      items.unshift(el('li', {}, el('p', {class: 'source-problem-text'}, message)));
    }
    this.ui.problemList.replaceChildren(...items);
    this.ui.problems.hidden = false;
    if (this.marks.length) this.scrollTo(this.marks[0].line);
  }

  clearDiagnostics() {
    for (const {line, marker} of this.marks) {
      this.editor.removeLineClass(line, 'background', 'source-error-line');
      marker?.clear();
    }
    this.marks = [];
    this.appliedDiagnostics = '';
    this.ui.problemList.replaceChildren();
    this.ui.problems.hidden = true;
  }

  renderChip() {
    const chip = this.ui.chip;
    const algorithm = this.algorithm;
    chip.className = 'source-chip';
    chip.replaceChildren();
    if (!algorithm) {
      chip.hidden = true;
      return;
    }
    chip.hidden = false;
    let text, kind, glyph;
    if (this.dirty) {
      [text, kind, glyph] = ['Unsaved', 'dirty', 'edit'];
    } else if (algorithm.revision !== this.revision && this.revision !== null) {
      [text, kind, glyph] = ['Updating…', 'busy', 'loader-2'];
    } else if (algorithm.status === 'error') {
      const count = algorithm.diagnostics?.length ?? 0;
      [text, kind, glyph] = [count ? `${count} ${count === 1 ? 'problem' : 'problems'}` : 'Cannot compile', 'error', 'alert-triangle'];
    } else if (algorithm.status === 'unavailable') {
      [text, kind, glyph] = ['Not checked', 'dirty', 'alert-triangle'];
    } else if (algorithm.status === 'ready') {
      [text, kind, glyph] = ['Ready', 'ready', 'check'];
    } else {
      [text, kind, glyph] = [algorithm.status === 'building' ? 'Compiling…' : 'Checking…', 'busy', 'loader-2'];
    }
    chip.classList.add(`source-chip-${kind}`);
    chip.append(icon(glyph, kind === 'busy' ? 'spinner-icon' : ''), el('span', {}, text));
  }

  updateDirty() {
    const before = this.dirty;
    this.dirty = this.revision !== null && this.editor.getValue() !== this.original;
    if (this.dirty) {
      this.highlight(null);
      this.markError(null);
      this.clearDiagnostics();
    } else if (before) {
      this.applyDiagnostics();
    }
    this.updateButtons();
    if (!this.saving) {
      this.setStatus(this.dirty ? 'Unsaved changes · Ctrl+S saves · the visualizer runs the saved version' : '');
    }
    if (before !== this.dirty) {
      this.renderChip();
      this.emit(this.dirty ? 'dirty' : 'clean');
    }
  }

  updateButtons() {
    const connected = this.connection.connected;
    this.ui.save.disabled = !this.dirty || this.saving || this.loading || !connected;
    this.ui.revert.disabled = !this.dirty || this.saving;
    this.ui.format.disabled = this.revision === null || this.saving || this.loading || this.formatting || !connected;
  }

  setStatus(text, error = false) {
    this.ui.status.textContent = text;
    this.ui.status.hidden = !text;
    this.ui.status.classList.toggle('source-edit-error', error);
  }

  write(text) {
    this.suppressChange = true;
    this.editor.setValue(text);
    this.editor.clearHistory();
    this.suppressChange = false;
    this.executionLine = null;
    this.errorLine = null;
    this.ui.container.classList.remove('source-empty');
    this.editor.setOption('lineNumbers', true);
    this.editor.refresh();
  }

  writable(on) {
    this.editor.setOption('readOnly', on ? false : 'nocursor');
    this.ui.container.classList.toggle('is-editing', on);
  }

  showPlaceholder(text) {
    this.write(text);
    this.writable(false);
    this.ui.container.classList.add('source-empty');
    this.editor.setOption('lineNumbers', false);
    this.setStatus('');
  }

  // ------------------------------------------------------------- completion

  hideSuggestions() {
    this.suggestions = [];
    this.completion.hidden = true;
    this.completion.replaceChildren();
  }

  wordAtCursor(cm) {
    const cursor = cm.getCursor();
    const prefix = (cm.getLine(cursor.line).slice(0, cursor.ch).match(/[A-Za-z_][A-Za-z_0-9]*$/) || [''])[0];
    return {cursor, prefix, from: {line: cursor.line, ch: cursor.ch - prefix.length}};
  }

  showSuggestions(cm, explicit = false) {
    if (this.revision === null || cm.getOption('readOnly')) return this.hideSuggestions();
    const {cursor, prefix} = this.wordAtCursor(cm);
    if ((!explicit && prefix.length < 2) || cm.somethingSelected() ||
        /comment|string/.test(cm.getTokenAt(cursor).type || '')) return this.hideSuggestions();
    const words = new Set(this.language.keywords);
    for (const word of cm.getValue().match(/[A-Za-z_][A-Za-z_0-9]*/g) || []) words.add(word);
    this.suggestions = [...words].filter(word => word.startsWith(prefix) && word !== prefix).sort().slice(0, 9);
    if (!this.suggestions.length) return this.hideSuggestions();
    this.suggestionIndex = 0;
    const coords = cm.cursorCoords(cursor, 'window');
    const wrapper = cm.getWrapperElement();
    const bounds = wrapper.getBoundingClientRect();
    const left = coords.left - bounds.left;
    const below = bounds.bottom - coords.bottom > 200 || coords.top - bounds.top < 200;
    this.completion.style.left = `${Math.max(0, Math.min(left, wrapper.clientWidth - 230))}px`;
    this.completion.style.top = `${Math.max(0, below ? coords.bottom - bounds.top + 4
      : coords.top - bounds.top - 194)}px`;
    this.completion.hidden = false;
    this.paintSuggestions();
  }

  paintSuggestions() {
    this.completion.replaceChildren(...this.suggestions.map((word, index) => el('button', {
      type: 'button', class: `source-completion${index === this.suggestionIndex ? ' selected' : ''}`,
      role: 'option', 'aria-selected': String(index === this.suggestionIndex),
      onmousedown: event => event.preventDefault(),
      onclick: () => this.chooseSuggestion(index),
    }, word)));
  }

  chooseSuggestion(index) {
    const word = this.suggestions[index];
    if (!word) return;
    const {cursor, from} = this.wordAtCursor(this.editor);
    this.hideSuggestions();
    this.editor.replaceRange(word, from, cursor, '+completion');
    this.editor.focus();
  }

  completionKeys(cm, event) {
    if (this.completion.hidden) return;
    if (event.key === 'Escape') {
      this.hideSuggestions();
      event.preventDefault();
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      this.suggestionIndex = (this.suggestionIndex + (event.key === 'ArrowDown' ? 1 : -1) +
        this.suggestions.length) % this.suggestions.length;
      this.paintSuggestions();
      event.preventDefault();
    } else if (event.key === 'Enter' || event.key === 'Tab') {
      this.chooseSuggestion(this.suggestionIndex);
      event.preventDefault();
    }
  }
}
