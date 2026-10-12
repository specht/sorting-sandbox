// Unit tests for DOM-free browser helpers: node test/browser_helpers.test.mjs
import assert from 'node:assert/strict';
import {compactCount, makeInput, sortAlgorithms, formatList} from '../web/js/util.js';
import {linearTicks, formatScore} from '../web/js/analyze.js';
import {stabilityLabels} from '../web/js/explore.js';
import {disambiguate} from '../web/js/catalog.js';
import {LANGUAGES, commentEdits, fileStem, languageOf} from '../web/js/languages.js';

let passed = 0;
function test(name, body) {
  body();
  passed++;
  console.log(`  ✓ ${name}`);
}

test('inputs are deterministic permutations of 1..n', () => {
  const a = makeInput(48, 'random', 7), b = makeInput(48, 'random', 7);
  assert.deepEqual(a, b);
  assert.deepEqual([...a].sort((x, y) => x - y), Array.from({length: 48}, (_, i) => i + 1));
  assert.notDeepEqual(makeInput(48, 'random', 8), a);
  assert.deepEqual(makeInput(5, 'reversed'), [5, 4, 3, 2, 1]);
  assert.deepEqual(makeInput(4, 'sorted'), [1, 2, 3, 4]);
  const few = makeInput(100, 'fewValues', 3);
  assert.ok(new Set(few).size <= 8);
  assert.ok(few.every(v => v >= 1));
});

test('algorithms are ordered by teaching family, then variant and author', () => {
  const order = sortAlgorithms([
    {id: 'z/q', name: 'Quick Sort', author: 'zoe'},
    {id: 'a/x', name: 'Bogo Sort', author: 'ann'},
    {id: 'b/b', name: 'Bubble Sort optimized', author: 'ben'},
    {id: 'a/b', name: 'Bubble Sort', author: 'ann'},
    {id: 'c/m', name: 'mergesort', author: 'cem'},
    {id: 'o/q', name: 'Quick Sort by Ovilli', author: 'ovilli'},
  ]).map(a => a.id);
  assert.deepEqual(order, ['a/b', 'b/b', 'c/m', 'o/q', 'z/q', 'a/x']);
});

test('counts and scores are compact', () => {
  assert.equal(compactCount(999), '999');
  assert.equal(compactCount(1234), '1.2k');
  assert.equal(compactCount(15600000), '16M');
  assert.equal(formatScore(6.6612), '6.66');
  assert.equal(formatScore(150000), '150k');
  assert.equal(formatList([1, 2, 3]), '[1, 2, 3]');
  assert.equal(formatList([1, 2, 3, 4], 2), '[1, 2, …]');
});

test('linear axis ticks are round numbers', () => {
  assert.deepEqual(linearTicks(0, 100), [0, 20, 40, 60, 80, 100]);
  assert.deepEqual(linearTicks(0, 1), [0, 0.2, 0.4, 0.6, 0.8, 1]);
});

test('stability counterexamples label equal values', () => {
  // input [2, 2, 1] sorted unstably to [1, 2(second), 2(first)]
  const labels = stabilityLabels([2, 2, 1], [1, 2, 2], [2, 1, 0]);
  assert.deepEqual(labels.input, ['2a', '2b', '1']);
  assert.deepEqual(labels.output, ['1', '2b', '2a']);
});

test('two versions of one algorithm by the same student stay distinguishable', () => {
  const list = disambiguate([
    {id: 'HiTears/merge_sort', path: 'HiTears/merge_sort.dart', name: 'Merge Sort', author: 'HiTears'},
    {id: 'HiTears/merge_sort_try', path: 'HiTears/merge_sort_try.dart', name: 'Merge Sort', author: 'HiTears'},
    {id: 'Ovilli/merge-sort', path: 'Ovilli/merge-sort.dart', name: 'Merge Sort', author: 'Ovilli'},
  ]);
  assert.deepEqual(list.map(a => a.name), ['Merge Sort (merge_sort)', 'Merge Sort (merge_sort_try)', 'Merge Sort']);
});

test('versions in different languages are told apart by their file name', () => {
  const list = disambiguate([
    {id: 'anna/quick_sort', path: 'anna/quick_sort.dart', name: 'Quick Sort', author: 'anna'},
    {id: 'anna/quick_sort_iterative.py', path: 'anna/quick_sort_iterative.py', name: 'Quick Sort', author: 'anna'},
  ]);
  assert.deepEqual(list.map(a => a.name), ['Quick Sort (quick_sort)', 'Quick Sort (quick_sort_iterative)']);
  assert.equal(fileStem('a/b/merge.py'), 'merge');
  assert.equal(fileStem('a/merge.dart'), 'merge');
  assert.equal(fileStem('a/notes.txt'), 'notes.txt');
});

test('a catalog entry selects its editor language, Dart by default', () => {
  assert.equal(languageOf({language: 'python'}).mode, 'python');
  assert.equal(languageOf({language: 'python'}).indent, 4);
  assert.equal(languageOf({language: 'java'}).mode, 'text/x-java');
  assert.equal(languageOf({language: 'javascript'}).comment, '//');
  assert.equal(fileStem('a/heap_sort.java'), 'heap_sort');
  assert.equal(fileStem('a/heap_sort.js'), 'heap_sort');
  assert.equal(languageOf({}), LANGUAGES.dart);
  assert.equal(languageOf(null), LANGUAGES.dart);
});

test('line comments toggle with the language comment token', () => {
  const lines = [{text: '    x = 1', indent: 4}, {text: '  y', indent: 2}];
  assert.deepEqual(commentEdits(lines, '#'), [
    {index: 0, from: 4, to: 4, insert: '# '},
    {index: 1, from: 2, to: 2, insert: '# '},
  ]);
  const commented = [{text: '    # x = 1', indent: 4}, {text: '  #y', indent: 2}];
  assert.deepEqual(commentEdits(commented, '#'), [
    {index: 0, from: 4, to: 6, insert: ''},
    {index: 1, from: 2, to: 3, insert: ''},
  ]);
  const mixed = [{text: '// a', indent: 0}, {text: 'b', indent: 0}];
  assert.deepEqual(commentEdits(mixed, '//').map(e => e.insert), ['// ', '// ']);
});

console.log(`${passed} browser helper tests passed.`);
