// The deliberately tiny API students program against (JavaScript version).
//
// It mirrors the Dart package `sorting_sandbox_api`: students move and compare
// Element objects inside an Elements list. Every read, write and comparison is
// counted, and every element secretly remembers its original position, so the
// sandbox can test stability without any bookkeeping in student code.
//
//   import { Colors, SortingAlgorithm } from "sorting-sandbox";
//
//   export default class BubbleSort extends SortingAlgorithm {
//     name = "Bubble Sort";
//     color = Colors.green;
//
//     sort(list, scratch) { … list[j].greaterThan(list[j + 1]) … }
//   }
//
// JavaScript cannot overload `<` for objects, so comparisons are methods:
// a.lessThan(b), a.lessOrEqual(b), a.greaterThan(b), a.greaterOrEqual(b) and
// a.equalTo(b) each count as one comparison. Using `<` or `>` on elements is
// an error instead of silently comparing nonsense.

export const Colors = Object.freeze({
  red: '#F44336',
  pink: '#E91E63',
  purple: '#9C27B0',
  deepPurple: '#673AB7',
  indigo: '#3F51B5',
  blue: '#2196F3',
  lightBlue: '#03A9F4',
  cyan: '#00BCD4',
  teal: '#009688',
  green: '#4CAF50',
  lightGreen: '#8BC34A',
  lime: '#CDDC39',
  yellow: '#FFEB3B',
  amber: '#FFC107',
  orange: '#FF9800',
  deepOrange: '#FF5722',
  brown: '#795548',
  blueGrey: '#607D8B',
});

/**
 * Base class of one sorting algorithm. Subclasses set `name` and `color` as
 * class fields and implement `sort(list, scratch)`. `author` is optional;
 * when omitted, the sandbox uses the student's folder name.
 */
export class SortingAlgorithm {
  sort(list, scratch) {
    throw new Error('Implement sort(list, scratch).');
  }
}

// Privileged access for the sandbox runtime (set in the static blocks).
let keyOf, originOf, createElements;

/** One sortable item. Its value is hidden; compare it with another Element. */
export class Element {
  #key;
  #origin;
  #probe;

  constructor(key, origin, probe) {
    this.#key = key;
    this.#origin = origin;
    this.#probe = probe;
  }

  static {
    keyOf = element => element.#key;
    originOf = element => element.#origin;
  }

  #other(other, method) {
    if (!(other instanceof Element)) {
      throw new TypeError(`${method} expects another Element, not ${describe(other)}.`);
    }
    this.#probe.comparisons++;
    return other.#key;
  }

  lessThan(other) { return this.#key < this.#other(other, 'lessThan'); }
  lessOrEqual(other) { return this.#key <= this.#other(other, 'lessOrEqual'); }
  greaterThan(other) { return this.#key > this.#other(other, 'greaterThan'); }
  greaterOrEqual(other) { return this.#key >= this.#other(other, 'greaterOrEqual'); }
  equalTo(other) { return this.#key === this.#other(other, 'equalTo'); }

  // `a < b` would compare two objects: an error, never a silent wrong answer.
  [Symbol.toPrimitive](hint) {
    if (hint === 'string') return 'Element';
    throw new TypeError('Elements cannot be compared with <, <=, > or >= or used in ' +
      'arithmetic. Use a.lessThan(b), a.lessOrEqual(b), a.greaterThan(b), ' +
      'a.greaterOrEqual(b) or a.equalTo(b).');
  }

  toString() { return 'Element'; }
}

function describe(value) {
  if (value === null) return 'null';
  if (value === undefined) return 'undefined';
  if (typeof value === 'object') return value.constructor?.name ?? 'an object';
  return `a ${typeof value}`;
}

const INDEX = /^-?\d+(?:\.\d+)?(?:e[+-]?\d+)?$/i;

/**
 * A list of Elements with a fixed length.
 *
 *   list.length            number of elements
 *   list[i]                read an element (one read)
 *   list[i] = element      write an element (one write)
 *   list.swap(i, j)        two reads and two writes
 */
export class Elements {
  constructor() {
    throw new TypeError('Elements are created by the sandbox.');
  }

  static {
    createElements = (probe, label, values, origins) => {
      const items = values.map((value, i) => new Element(value, origins[i], probe));
      const length = items.length;

      const index = raw => {
        const number = Number(raw);
        if (!Number.isInteger(number)) {
          throw new TypeError(`Indices must be integers, not ${raw}.`);
        }
        if (number < 0 || number >= length) {
          const valid = length === 0 ? 'the list is empty' : `valid: 0 … ${length - 1}`;
          throw new RangeError(`Index ${number} is out of range (${valid}).`);
        }
        return number;
      };
      const read = i => {
        probe.reads++;
        if (probe.track) probe.mark(probe.readMarks, label, i);
        return items[i];
      };
      const write = (i, value) => {
        if (!(value instanceof Element)) {
          throw new TypeError(`Only Elements can be stored, not ${describe(value)}.`);
        }
        items[i] = value;
        probe.writes++;
        if (probe.track) probe.mark(probe.writeMarks, label, i);
      };
      const swap = (a, b) => {
        const i = index(a), j = index(b);
        const temp = read(j);
        write(j, read(i));
        write(i, temp);
      };
      function* iterate() {
        for (let i = 0; i < length; i++) yield read(i);
      }
      const internal = {items, label};

      return new Proxy(Object.create(Elements.prototype), {
        get(target, property) {
          if (typeof property === 'string' && INDEX.test(property)) return read(index(property));
          switch (property) {
            case 'length': return length;
            case 'swap': return swap;
            case Symbol.iterator: return iterate;
            case INTERNAL: return internal;
            case 'toString': return () => `Elements(${length})`;
            case Symbol.toStringTag: return 'Elements';
            default: return Reflect.get(target, property);
          }
        },
        set(target, property, value) {
          if (typeof property === 'string' && INDEX.test(property)) {
            write(index(property), value);
            return true;
          }
          throw new TypeError(property === 'length'
            ? 'Elements have a fixed length.'
            : `Only list[i] = element can be assigned, not list.${String(property)}.`);
        },
        has(target, property) {
          if (typeof property === 'string' && INDEX.test(property)) {
            const number = Number(property);
            return Number.isInteger(number) && number >= 0 && number < length;
          }
          return property === 'length' || property === 'swap' || Reflect.has(target, property);
        },
        deleteProperty() {
          throw new TypeError('Elements cannot be deleted; overwrite them instead.');
        },
        defineProperty() {
          throw new TypeError('Elements have a fixed length.');
        },
        ownKeys() {
          return [...Array.from({length}, (_, i) => String(i)), 'length'];
        },
        getOwnPropertyDescriptor(target, property) {
          if (property === 'length') {
            return {value: length, writable: false, enumerable: false, configurable: true};
          }
          if (typeof property === 'string' && INDEX.test(property)) {
            const number = Number(property);
            if (Number.isInteger(number) && number >= 0 && number < length) {
              return {value: items[number], writable: true, enumerable: true, configurable: true};
            }
          }
          return undefined;
        },
      });
    };
  }
}

const INTERNAL = Symbol('sorting-sandbox internal');

// ------------------------------------------------------------------ sandbox
// Used by the worker only. Students never need these.

/** Counts operations; in visual runs also remembers what was touched. */
export class Probe {
  constructor(track = false) {
    this.reads = 0;
    this.writes = 0;
    this.comparisons = 0;
    this.track = track;
    this.readMarks = new Map();
    this.writeMarks = new Map();
  }

  mark(marks, label, index) {
    let set = marks.get(label);
    if (!set) marks.set(label, set = new Set());
    set.add(index);
  }

  metrics() {
    return {
      reads: this.reads,
      writes: this.writes,
      comparisons: this.comparisons,
      score: this.reads + this.writes + this.comparisons,
    };
  }

  discardMarkers() {
    this.readMarks.clear();
    this.writeMarks.clear();
  }

  takeReads() { return Probe.#take(this.readMarks); }
  takeWrites() { return Probe.#take(this.writeMarks); }

  static #take(marks) {
    const result = [];
    for (const label of [...marks.keys()].sort()) {
      for (const index of [...marks.get(label)].sort((a, b) => a - b)) {
        result.push({list: label, index});
      }
    }
    marks.clear();
    return result;
  }
}

export function makeLists(probe, values) {
  const n = values.length;
  return [
    createElements(probe, 'list', values, values.map((_, i) => i)),
    createElements(probe, 'scratch', new Array(n).fill(0), values.map((_, i) => -1 - i)),
  ];
}

export const keys = elements => elements[INTERNAL].items.map(item => keyOf(item));
export const origins = elements => elements[INTERNAL].items.map(item => originOf(item));
export const key = element => keyOf(element);
