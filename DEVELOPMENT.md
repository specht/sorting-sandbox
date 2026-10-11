# Sorting Sandbox · development guide

A classroom sorting-algorithm visualizer, race arena and analyzer that runs in
the browser and needs only the **Dart SDK** (3.11+). There is no Flutter and no
build step for the UI: a Dart host serves plain HTML/CSS/JavaScript and runs
student code in separate Dart worker processes.

The central rule is unchanged: **students write ordinary sorting code**. They
add no animation calls, yields, benchmark hooks, stability metadata or
variable tracing; the sandbox builds all of that around their source.

## Layout

```text
run                     start the app (dart pub get on demand, then tool/host.dart)
new-algorithm           create algorithms/STUDENT/NAME.dart from templates/
update-algorithms       git pull in the nested class repository
check                   analysis + all tests
packages/sorting_sandbox_api/   the tiny student-facing API (Elements, Colors, …)
lib/
  sandbox_worker_runtime.dart   operation counting, checkpoints, stability
  worker_core.dart              worker protocol: visual runs, check, analysis
  worker_process.dart           stdin/stdout loop of a generated worker
tool/
  host.dart               HTTP + WebSocket server, runs, checks, analysis jobs
  catalog.dart            watches algorithms/, per-file status and diagnostics
  build.dart              content-addressed kernel builds per algorithm revision
  inspect.dart            parser-only syntax and contract checks (editor positions)
  instrumenter.dart       creates the async "visual" copy with checkpoints
  instrument_daemon.dart  keeps the parser loaded (instrument_client.dart talks to it)
  source_editor.dart      revision-checked browser saves and `dart format`
web/                      index.html, style.css, js/*.js, vendored CodeMirror/fonts/icons
templates/                Bubble Sort example and an empty template
test/                     plain `dart run` / `node` tests (no extra packages)
```

`algorithms/` is the class repository, a **separate Git repository** nested in
the app checkout and ignored by it (not a submodule). Generated workers live in
the ignored `runtime/workers/` directory.

## Start

```bash
./run                         # http://127.0.0.1:8080/
./run --port 8090 --no-open
./run --algorithms /some/other/repo
./run --host 0.0.0.0          # serve other machines (see "Limits" below)
SANDBOX_PROFILE=1 ./run       # print build timings
```

The class repository may contain its own `pubspec.yaml` pointing at
`../packages/sorting_sandbox_api`; `./run` resolves it so that external editors
(VS Code etc.) understand student files. The app itself does not need it.

## How a save becomes a visualization

```text
browser Save (or any editor, or git pull)
      ↓  catalog notices the new revision (700 ms poll, content hash)
parser check in the instrument daemon  → name, color, syntax/contract diagnostics
      ↓  (valid)
instrument → runtime/workers/<key>/visual.dart   (same line numbers as the original)
copy       → runtime/workers/<key>/algorithm.dart (byte-identical, for benchmarks)
generate   → runtime/workers/<key>/worker.dart, compile → worker.dill
      ↓
catalog broadcast → editor chip "Ready", Run enabled
```

Every algorithm is compiled **on its own**, so a broken file never affects any
other algorithm. The cache key covers the source bytes, the Dart SDK version
and every sandbox file that influences the worker; saving unchanged content,
restarting `./run` or another browser selecting the same file reuses the
kernel. Unused builds are pruned at startup after 14 days.

When compilation fails, the host runs `dart analyze` on the generated copies.
Because `algorithm.dart` is byte-identical and `visual.dart` never inserts line
breaks, the analyzer's positions are the student's own lines and columns. They
are shown below the editor and underlined in the source.

## Runs, checks and analysis

Each browser run gets its **own disposable worker process**:

- **Explore / Race**: `visualStart` runs the async copy. Every checkpoint
  consumes one unit of budget; when the budget is used up the worker sends one
  frame (arrays, counters, line, locals, read/write markers) and waits for
  `advance`. Nothing is pre-recorded. Stepping back uses a sparse cache of
  frames in the browser and, for exact steps, a fresh worker that is
  fast-forwarded (replayed) to the requested checkpoint.
- **Check**: correctness groups (empty, tiny, sorted/reversed, duplicates,
  random, larger inputs), then an empirical stability test. Failures report the
  input and the wrong result, or the exception with its line.
- **Analyze**: correctness and stability cases, then the same benchmark inputs
  for every algorithm (two workers in parallel).

Student `print` output is forwarded to the Console with its source line. An
exception reports its message, line and the student frames of the stack. A
run that reaches no checkpoint for 4 seconds is killed (90 seconds while
replaying to an earlier step); checks and analyses have hard timeouts of 20
and 12 seconds. A crashed worker never affects the host.

## Browser protocol (WebSocket `/ws`)

Client → host: `readSource`, `saveSource`, `formatSource`, `visualStart`,
`advance`, `stop`, `check`, `analyze`, `cancel`, `ping`.
Host → client: `catalog` (all files with status and diagnostics), `sourceFile`,
`sourceSaved`, `sourceError`, `sourceFormatted`, `sourceFormatError`,
`runStatus`, `runStarted`, `frame`, `console`, `complete`, `runError`,
`checkResult`, `analysisResult`, `analysisDone`, `pong`, `error`.

## Checks

```bash
./check
```

runs `dart analyze` on `lib`, `tool` and `test`, the API package tests, the
runtime/instrumenter/parser tests, an end-to-end smoke test that compiles real
workers and talks to them, and the Node tests for browser helpers.

## Limits

- Worker processes are **not** OS-level isolation. On a shared host with
  untrusted users, run the sandbox in a container or with separate filesystem,
  network and resource restrictions. By default the server listens on
  `127.0.0.1` only.
- The visual instrumentation covers ordinary classroom code (methods, top-level
  helper functions, recursion, loops). Helpers called from inside closures
  (e.g. `list.forEach((x) => helper(x))`) are not transformed; such a file shows
  a clear "visualizer cannot transform" message instead of running.
- The Android APK of the previous Flutter version is no longer built.
