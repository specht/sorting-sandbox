# Sorting Sandbox — design notes

## Non-negotiable teaching goals

1. Student code reads like an ordinary sorting algorithm.
2. `swap` is optional sugar; manual reads/writes with a temporary variable are
   equally valid and counted equivalently.
3. One student directory may contain multiple algorithms.
4. Author comes from the directory; readable algorithm name and color remain
   student-controlled metadata.
5. A syntax/type error in one file cannot make the class sandbox uncompilable.
6. Local variables can be visualized without tracing calls in student source.
7. Visualization is live; it does not pre-record the complete execution.
8. Non-terminating algorithms are stoppable and cannot freeze the UI.
9. Benchmarking contains no visualization/checkpoint overhead.
10. Main and scratch arrays keep fixed relative visual space.
11. Correctness and empirical stability require no extra student API.
12. Group comparisons use the same concrete inputs.
13. The application and class algorithms are separate Git repositories even
    though the class repository is nested at `algorithms/`.
14. Saving/pulling algorithms updates a running classroom instance without a
    Flutter rebuild/restart.

## Repository boundary

```text
sorting_sandbox/                 application Git repository
  .git/
  algorithms/                    ignored by application repository
    .git/                         class Git repository
    student-a/*.dart
    student-b/*.dart
```

No Git submodule is used. The app's `.gitignore` owns the boundary.

The class repository has a tiny `pubspec.yaml` whose API dependency points at
`../packages/sorting_sandbox_api`. That deliberately makes the supported class
layout explicit and lets `dart analyze` validate student source before it is
admitted to the runtime worker.

## Compilation boundary

The Flutter application **never imports generated student algorithms**.
Instead, `tool/prepare_algorithms.dart` independently scans the class repo and
produces a separate browser worker plus a JSON catalog under `runtime/`.

For each candidate file:

1. parse syntax and required metadata;
2. run `dart analyze` against just that file;
3. generate an instrumented visual copy;
4. analyze the generated visual copy;
5. include the file only if all stages succeed.

A broken file therefore becomes a catalog diagnostic, not a Flutter compile
failure.

## Atomic/versioned live reload

Successful builds are published as:

```text
runtime/
  algorithms.json
  algorithm_worker.<build-id>.js
```

The worker filename contains a fresh build id. `algorithms.json` is written to
a temporary file and renamed only after the worker has compiled successfully.
The classroom server sends runtime files with no-cache headers.

The Flutter UI polls the tiny JSON catalog. If its `buildId` changes it uses the
new metadata/worker for future runs. A worker already running has already loaded
its old version and may finish normally. Old worker files are retained for a
small number of builds to avoid races and then cleaned up.

`tool/watch_algorithms.dart` fingerprints algorithm/config files on a short
interval with debounce. A normal editor save or `git pull` therefore triggers a
rebuild. `.git/` and `.dart_tool/` changes are ignored so the build does not
feed itself.

## Two generated execution forms

### Benchmark form

The student's original source is copied unchanged. `Elements` and `Element`
perform operation counting. There is no checkpoint overhead. Benchmark and
analysis requests run synchronously inside a disposable worker.

### Visual form

The analyzer-AST transformer creates a second source form. Ordinary algorithm
methods and top-level helper functions become async, local helper calls are
awaited, and checkpoints are inserted before statements / inside loop bodies.
For example:

```dart
await sandboxCheckpoint(12, {'length': length, 'i': i, 'j': j});
```

The transformer works only on the generated copy. The checked-in source shown
to the learner remains untouched.

The initial implementation intentionally favors ordinary classroom algorithm
code. If an exotic language construct cannot be transformed safely, analysis
of the generated copy fails and only that algorithm is skipped.

## Worker protocol

Visual execution is cooperative:

```text
Flutter                               Worker
   | visualStart(values), budget=0      |
   |----------------------------------->|
   |                       checkpoint   |
   |<-------------------------- frame --|
   | advance(budget=20)                 |
   |----------------------------------->|
   |                  run checkpoints   |
   |<-------------------------- frame --|
```

Only the current state is sent. There is no growing animation-frame list.

Stop is `Worker.terminate()`. A watchdog also terminates a visual worker that
fails to reach another checkpoint. Benchmark/analysis requests have a hard
request timeout and their disposable worker is terminated if they exceed it.

This deliberately uses two protections:

- cooperative checkpoints for smooth stepping/animation;
- hard worker termination as the safety net for code that never cooperates.

## Operation model

The student-facing API is Flutter-free.

- `list[i]`: one read;
- `list[i] = value`: one write;
- `<`, `<=`, `>`, `>=`, `==` between Elements: one comparison;
- `swap(a, b)`: implemented as two indexed reads + two indexed writes.

The visualizer receives markers for recent list/scratch reads and writes, but
those markers do not change the counts.

The UI keeps R/W/C separate. `R + W + C` is labelled a **sandbox score**, not a
claim that all machine operations have identical real cost.

## Stability

A primary-list element internally contains `(key, origin)`. `origin` is hidden
from student code and comparison operators compare only `key`.

After a run, equal adjacent keys are stable iff their origins remain in their
original order. The analyzer uses duplicate-heavy cases and returns a
counterexample as soon as it finds instability. A successful suite is labelled
`stable (tested)`, never `proved stable`.

Scratch starts with dummy elements whose negative origins make accidental use
of uninitialized scratch entries fail the correctness/permutation check.

## Fair inputs

For Analyze, the Flutter side constructs each `(shape, n)` list once and sends
that same concrete list to every algorithm. Race similarly creates one list and
copies it into every lane. There is no per-algorithm reshuffle.

## Classroom server

`flutter build web` creates the static UI in `build/web`. The custom Dart server
serves that static build plus `runtime/` under the same origin. Dynamic worker
and catalog files are *not* Flutter build assets, which prevents Flutter's
static asset/service-worker caching from pinning an old algorithm build.

The normal entry point is `./run`; students do not need to invoke the generator,
compiler, watcher or server separately.
