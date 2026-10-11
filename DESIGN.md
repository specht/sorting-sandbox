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
8. Non-terminating algorithms are stoppable and cannot freeze the UI or the
   server.
9. Benchmarking contains no visualization/checkpoint overhead.
10. Main and scratch arrays keep fixed relative visual space.
11. Correctness and empirical stability require no extra student API.
12. Group comparisons use the same concrete inputs.
13. The application and class algorithms are separate Git repositories even
    though the class repository is nested at `algorithms/`.
14. Saving/pulling algorithms updates a running classroom instance without a
    restart.
15. Students can edit, save and format their file in the browser; errors are
    shown at their own source lines.

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

The class repository may have a tiny `pubspec.yaml` whose API dependency
points at `../packages/sorting_sandbox_api`, so external editors understand
student files. The sandbox itself compiles copies of student files inside the
app package and does not depend on it.

## Compilation boundary

The host never loads student code into its own process. For each revision of
each file, `tool/build.dart` creates a separate worker under
`runtime/workers/<content-hash>/`:

1. parse syntax and required metadata (`tool/inspect.dart`, editor positions);
2. generate the instrumented visual copy (`tool/instrumenter.dart`);
3. compile one small kernel containing the benchmark copy and the visual copy;
4. on failure, run `dart analyze` on the copies and report the errors at the
   student's original lines (the visual copy never inserts line breaks).

A broken file therefore becomes an editor diagnostic for that file only.

## Live reload without a rebuild of the app

The UI is static HTML/JS served by the host; there is no app build. The host
polls the class repository (content hashes, 700 ms), recompiles only changed
files and pushes the catalog to every browser over a WebSocket. A run already
in progress keeps its old worker process; the next run uses the new build. The
browser notices that the source of a visualization changed and asks the
student to run it again.

## Two generated execution forms

### Benchmark form

The student's original source is copied unchanged. `Elements` and `Element`
perform operation counting. There is no checkpoint overhead. Check and
analysis requests run synchronously inside a disposable worker process.

### Visual form

The analyzer-AST transformer creates a second source form. Ordinary algorithm
methods and top-level helper functions become async, local helper calls are
awaited, and checkpoints are inserted before statements / inside loop bodies:

```dart
await __sandbox.sandboxCheckpoint(12, {'length': length, 'i': i, 'j': j});
```

Only locals that are definitely readable are included (no `late` or
unassigned variables). The transformer works only on the generated copy; the
file shown to and edited by the learner remains untouched.

## Worker protocol

Visual execution is cooperative:

```text
Browser            Host                    Worker process
   | visualStart -->|-- visualStart ------->|
   |                |<-------------- frame --|  (budget 0: first checkpoint)
   | advance(20) -->|-- advance(20) ------->|
   |                |         run 20 checkpoints
   |<----- frame ---|<-------------- frame --|
```

Only the current state is sent. There is no growing animation-frame list.

Stop kills the worker process. A watchdog in the host also kills a visual
worker that fails to reach another checkpoint. Check/analysis requests have a
hard timeout and their worker is killed if they exceed it.

This deliberately uses two protections:

- cooperative checkpoints for smooth stepping/animation;
- hard process termination as the safety net for code that never cooperates.

## Operation model

The student-facing API is a tiny pure-Dart package.

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

For Analyze, the browser constructs each `(shape, n)` list once and sends
that same concrete list to every algorithm. Race similarly creates one list and
copies it into every lane. There is no per-algorithm reshuffle.

## Classroom server

`./run` starts `tool/host.dart`. It serves `web/`, keeps one parser daemon
loaded for fast feedback on every save, and starts worker processes on demand.
Students do not need to invoke the generator, compiler, watcher or server
separately, and only the Dart SDK is required.
