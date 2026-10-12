#!/usr/bin/env bash
# Tests ./new-algorithm in a temporary copy of the app:  bash test/new_algorithm.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
fresh() {
  rm -rf "$WORK/app"
  mkdir -p "$WORK/app/templates" "$WORK/app/algorithms"
  cp "$ROOT/new-algorithm" "$WORK/app/"
  cp "$ROOT"/templates/* "$WORK/app/templates/"
}
run() { (cd "$WORK/app" && ./new-algorithm "$@"); }
ok() { passed=$((passed + 1)); echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }
expect_file() { [[ -f "$WORK/app/$1" ]] || fail "missing $1"; }
add() { mkdir -p "$WORK/app/algorithms/$(dirname "$1")"; echo "# x" > "$WORK/app/algorithms/$1"; }

fresh
out="$(run alice)"
expect_file algorithms/alice/bubble_sort.dart
[[ "$out" == *"Dart: the default"* ]] || fail "default reason: $out"
[[ ! -f "$WORK/app/.settings.yaml" ]] || fail "a default must not be remembered"
ok 'an empty class starts with Dart'

fresh
add bob/a.py; add carl/b.py; add dora/c.dart
out="$(run erin)"
expect_file algorithms/erin/bubble_sort.py
[[ "$out" == *"most of your class"* ]] || fail "class reason: $out"
cmp -s "$WORK/app/algorithms/erin/bubble_sort.py" "$ROOT/templates/bubble_sort.py" || fail 'template copied'
ok 'a Python class defaults to Python'

fresh
add bob/a.dart; add carl/b.dart; add dora/c.dart
add erin/old.dart; sleep 1; add erin/newer.py
run erin quick_sort > /dev/null
expect_file algorithms/erin/quick_sort.py
grep -q '^class QuickSort(SortingAlgorithm):$' "$WORK/app/algorithms/erin/quick_sort.py" || fail 'class name'
grep -q 'name = "Quick Sort"' "$WORK/app/algorithms/erin/quick_sort.py" || fail 'display name'
ok "the student's own newest file beats the class"

fresh
add bob/a.py; add bob/b.py
run alice --lang dart > /dev/null
expect_file algorithms/alice/bubble_sort.dart
grep -q '^language: dart$' "$WORK/app/.settings.yaml" || fail 'remembered'
out="$(run alice merge_sort)"
expect_file algorithms/alice/merge_sort.dart
[[ "$out" == *"your last choice"* ]] || fail "remembered reason: $out"
run alice heap_sort.py > /dev/null
expect_file algorithms/alice/heap_sort.py
[[ "$(grep -c '^language:' "$WORK/app/.settings.yaml")" == 1 ]] || fail 'one language line'
grep -q '^language: python$' "$WORK/app/.settings.yaml" || fail 'updated'
ok 'an explicit choice is remembered and can be changed'

fresh
printf '# Local settings\ntheme: light\n' > "$WORK/app/.settings.yaml"
run alice --lang=python > /dev/null
grep -q '^theme: light$' "$WORK/app/.settings.yaml" || fail 'theme kept'
grep -q '^language: python$' "$WORK/app/.settings.yaml" || fail 'language added'
ok 'other settings are kept'

fresh
if run alice quick_sort.py --lang dart 2> /dev/null; then fail 'conflict accepted'; fi
if run alice --lang cobol 2> /dev/null; then fail 'unknown language accepted'; fi
if run alice Quick.py 2> /dev/null; then fail 'invalid name accepted'; fi
run alice x.py > /dev/null
if run alice x.py 2> /dev/null; then fail 'overwrote a file'; fi
ok 'conflicts, unknown languages, bad names and existing files are refused'

echo "$passed new-algorithm tests passed."
