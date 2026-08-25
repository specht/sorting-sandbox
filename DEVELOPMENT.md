# Sorting Sandbox

A classroom sorting-algorithm visualizer, race arena and analyzer.

The central rule is deliberately strict: **students write normal sorting code**.
They do not add animation calls, yields, benchmark hooks, stability metadata or
variable tracing. The sandbox builds those capabilities around their source.

## Student-facing algorithm API

A submission still looks like this:

```dart
import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

class BubbleSortAnna extends SortingAlgorithm {
  get name => 'Bubble Sort';
  get color => Colors.green; // or any '#RRGGBB'

  void sort(Elements list, Elements scratch) {
    int length = list.length;
    for (int i = 0; i < length; i++) {
      for (int j = 0; j < length - i - 1; j++) {
        if (list[j] > list[j + 1]) list.swap(j, j + 1);
      }
    }
  }
}
```

`name` is explicit because a readable name is useful in the UI. `color` is
chosen by the student. The author is **not** written in the file: it is the
student directory name.

Students may submit multiple algorithms:

```text
algorithms/
  anna/
    bubble_sort.dart
    insertion_sort.dart
    cocktail_sort.dart
  ben/
    merge_sort.dart
    quick_sort.dart
  carla/
    selection_sort.dart
```

Each `.dart` file contains one `SortingAlgorithm` subclass. Helper methods and
top-level helper functions in the same file are fine.

## Two Git repositories, nested on disk

`algorithms/` is intended to be a completely separate class Git repository
nested inside the application checkout:

```text
sorting_sandbox/               # teacher-maintained app repository
  .git/
  lib/
  tool/
  packages/
  algorithms/                  # ignored by the outer repository
    .git/                       # shared class repository
    anna/
    ben/
    carla/
```

The outer `.gitignore` ignores `/algorithms/`, so the repositories do not
interfere with each other. This is deliberately **not a Git submodule**.

Typical commands are therefore independent:

```bash
# Get fixes/features for the sandbox itself.
git pull

# Get everybody's newest algorithms.
git -C algorithms pull
```

For a real class, replace the bundled example `algorithms/` directory with the
class repository:

```bash
rm -rf algorithms
git clone <class-algorithm-repository> algorithms
```

The class repository's `pubspec.yaml` expects to live at exactly this nested
location so it can use `../packages/sorting_sandbox_api`.

## Start it

With a current Flutter installation in `PATH`:

```bash
./run
```

`./run` does four things:

1. resolves application and algorithm dependencies;
2. validates/instruments the current algorithms and builds a Web Worker;
3. builds the Flutter web UI once;
4. starts a local classroom server **and an algorithm watcher**.

The browser opens at `http://127.0.0.1:8080/` by default.

Useful variants:

```bash
./run --no-open
./run --port 8090
./run --algorithms /some/other/nested/repo
```

## Build an Android APK

Android uses the same Flutter UI and the same generated algorithm code as the
web version. The only difference is isolation: browsers use a disposable Web
Worker, while Android runs each algorithm in a disposable Dart isolate.

With the class repository checked out as `algorithms/`, build an installable
release APK with:

```bash
./build-apk
```

The command validates/instruments the current algorithms, embeds a native
snapshot, generates an Android host from the **installed Flutter SDK**, and
runs `flutter build apk --release`. The host lives in ignored `android/` and is
regenerated on every `./build-apk`, so its Gradle/Android plugin versions stay
matched to Flutter instead of being frozen in this repository.

The resulting file is:

```text
build/app/outputs/flutter-apk/app-release.apk
```

Use `./build-apk` again after changing or pulling algorithms. The optional
`ANDROID_ORG` environment variable changes the generated Android application
namespace; it defaults to `de.hackschule`.

## Saving and pulling algorithms is live

While `./run` is running, the watcher observes all student `.dart` files plus
class-repository configuration files.

A save or `git -C algorithms pull` triggers this pipeline automatically:

```text
changed student files
       ↓
analyze each file independently
       ↓
instrument every valid file
       ↓
compile a new versioned Web Worker
       ↓
atomically publish a new algorithm catalog
       ↓
running Flutter app notices the build id
       ↓
new runs use the new algorithms
```

**The Flutter application is not rebuilt or restarted for algorithm edits.**
It polls only a tiny runtime catalog once per second. The worker file is
versioned, so a run already in progress can finish on its old worker while the
next run uses the new build.

If a student saves half-written code with a syntax error, that file is skipped
and shown as a diagnostic. All other algorithms remain usable. Once the file
is valid again it reappears automatically.

There is also a convenience command for a normal class pull:

```bash
./update-algorithms
```

## No pre-recorded animation

The old Sorting Sandbox ran the complete algorithm first, recorded a long list
of frames and replayed them later. This rewrite does not.

For each valid source file the tool generates two forms:

- **benchmark form** — the student's original synchronous implementation;
- **visual form** — a generated async copy with transparent checkpoints.

The original student file is never changed.

The visual form runs in a disposable Web Worker. At a checkpoint it sends only
the current arrays, counters, source line and local variables to Flutter and
waits for a new execution budget. This makes single-step, pause, run and stop
possible without storing the whole execution.

A normal loop that never terminates remains stoppable because it keeps reaching
generated checkpoints. Code that gets stuck without reaching a checkpoint is
terminated by a watchdog. Benchmark/analysis jobs run synchronously in their
own disposable workers and are killed on timeout. Student code therefore
cannot freeze the Flutter UI.

## Automatic local variables

The source transformer inserts checkpoints such as this in the generated copy:

```dart
await sandboxCheckpoint(12, {'length': length, 'i': i, 'j': j});
```

The checked-in student source remains the simple version. `Explore` can show
`i`, `j`, `left`, `right`, `minimum`, and other lexically visible locals next
to the highlighted original source line.

## `swap` is only convenience sugar

`list.swap(a, b)` is implemented through exactly the same indexed operations a
student would write manually:

```dart
final temp = this[b];
this[b] = this[a];
this[a] = temp;
```

It therefore costs **two reads and two writes**. A unit test explicitly checks
that `swap()` and the temporary-variable version have identical read/write
counts. Students are free to use either style.

## Scratch storage always stays visible

Explore and Race always reserve the same amount of vertical space for the main
list and scratch list. Algorithms that do not use scratch simply leave it
empty/zeroed. This prevents the primary array from suddenly changing height
when comparing an in-place algorithm with, for example, Merge Sort.

## Stability without a student-facing feature

Every primary-list element secretly carries its original position. Operators
compare **only the sort key**, so students do not see or maintain this data.
After sorting, the analyzer can check whether elements with equal keys kept
their original relative order.

The UI reports:

- `stable (tested)` when all duplicate-heavy test cases pass;
- `unstable` when it finds a counterexample;
- unknown when the algorithm is incorrect or times out.

This is empirical testing, not a mathematical proof, hence the wording
`stable (tested)`.

## Teaching modes

### Explore

Run one implementation. Both arrays stay visible; reads, writes, comparisons,
current source line and automatically tracked local variables update live.
Single-step, pause/continue and Stop operate on the running worker.

### Race

Choose two to four implementations. Every lane receives **the exact same input
array**. The visualization advances by generated logical checkpoints rather
than measuring browser CPU speed.

### Analyze

Run every valid class algorithm through correctness cases, duplicate-heavy
stability cases and identical benchmark inputs. The UI keeps reads, writes and
comparisons separate and also offers an explicitly artificial classroom score:

```text
sandbox score = reads + writes + comparisons
```

Graphs can display raw score or normalize it by `n`, `n log n`, or `n²` so
students can investigate which growth model tends toward a constant. Input
shapes include random, sorted, reversed, nearly sorted and few-distinct-values.

## Example class repository in this ZIP

The included `algorithms/` directory is a small ready-to-run example containing
several algorithms from fictional students, including both `swap()` and a
manual temporary-variable swap. It intentionally contains no `.git` metadata.
To turn it into its own repository:

```bash
git -C algorithms init
git -C algorithms add .
git -C algorithms commit -m 'Initial class algorithms'
```

Or delete it and clone your real class repository into `algorithms/`.

## Checks

After installing Flutter, run:

```bash
./check
```

This runs application analysis/tests, the API package tests, class-repository
analysis, and a full algorithm preparation/worker compilation pass.

The most important regression tests cover:

- `swap()` vs manual swapping counts;
- hidden-origin stability detection;
- automatic checkpoint/local-variable instrumentation.

## Toolchain

The project targets Dart 3.11+ and currently declares analyzer 14.1, `web` 1.1
and `fl_chart` 1.2. See `DESIGN.md` for the architecture and worker protocol.
