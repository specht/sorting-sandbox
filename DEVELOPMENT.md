# Sorting Sandbox · development guide

A classroom sorting-algorithm visualizer, race arena and analyzer that runs in
the browser and needs only the **Dart SDK** (3.11+). There is no Flutter and no
build step for the UI: a Dart host serves plain HTML/CSS/JavaScript and runs
student code in separate worker processes. Students write in **Dart, Python,
JavaScript or Java** (Python 3.10+, Node.js 18+ or a JDK 17+ is only needed
by those who choose it); see "Languages" below.

The central rule is unchanged: **students write ordinary sorting code**. They
add no animation calls, yields, benchmark hooks, stability metadata or
variable tracing; the sandbox builds all of that around their source.

## Layout

```text
run                     start the app (dart pub get on demand, then tool/host.dart)
new-algorithm           create algorithms/STUDENT/NAME.dart|.py|.js|.java from templates/
update-algorithms       git pull in the nested class repository
check                   analysis + all tests
packages/sorting_sandbox_api/   the tiny student-facing API (Elements, Colors, …)
lib/
  judge.dart                    host-side Check/Analyze: correctness, stability, benchmarks
  sandbox_worker_runtime.dart   operation counting, checkpoints, stability
  worker_core.dart              worker protocol: visual runs and single sorts (`run`)
  worker_process.dart           stdin/stdout loop of a generated worker
tool/
  host.dart               HTTP + WebSocket server, runs, checks, analysis jobs
  catalog.dart            watches algorithms/, per-file status and diagnostics
  build.dart              content-addressed kernel builds per algorithm revision
  inspect.dart            parser-only syntax and contract checks (editor positions)
  instrumenter.dart       creates the async "visual" copy with checkpoints
  instrument_daemon.dart  keeps the parser loaded (instrument_client.dart talks to it)
  source_editor.dart      revision-checked browser saves and `dart format`
  languages.dart          the student languages (by file extension), toolchain discovery
  settings.dart           local .settings.yaml (theme, last chosen language), /api/settings
  light-theme.mjs         generates web/light.css from web/style.css (Node)
web/                      index.html, style.css, light.css, js/*.js, vendored CodeMirror/fonts/icons
languages/python/         Python API (sorting_sandbox), worker and check/format daemon
languages/javascript/     JavaScript API (sorting-sandbox.mjs), instrumenter, worker, daemon
languages/java/src/       Java API (sandbox.sorting) and __sandbox: instrumenter, worker, daemon
vendor/python/            vendored tools: black, pyflakes (see the READMEs there)
vendor/javascript/        vendored tools: acorn, eslint-scope, js-beautify
vendor/java/              vendored google-java-format
templates/                Bubble Sort example and an empty template per language
test/                     plain `dart run` / `node` / `python3` / `java` / `bash` tests
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

Check and Analyze are judged by the **host** (`lib/judge.dart`). The worker
only answers `run {values}` with the resulting keys, hidden origins and
operation counts (or the student's exception); the host sends one input at a
time and stops at the first failure. Workers of every language are therefore
judged by the same code on the same inputs.

Student `print` output is forwarded to the Console with its source line. An
exception reports its message, line and the student frames of the stack. A
run that reaches no checkpoint for 4 seconds is killed (90 seconds while
replaying to an earlier step); checks and analyses have hard timeouts of 20
and 12 seconds. A crashed worker never affects the host.

## Languages

A file's extension is its language (`tool/languages.dart`); the class has no
language setting, and files of all languages race each other in one browser.
Catalog ids stay `student/name` for Dart and keep the extension otherwise
(`student/name.py`, `.js`, `.java`). Every language provides the same pieces:

| | Dart | Python | JavaScript | Java |
| --- | --- | --- | --- | --- |
| check on save | `tool/instrument_daemon.dart` | `languages/python/sandbox_daemon.py` | `languages/javascript/sandbox_daemon.mjs` | `__sandbox.Daemon` |
| build | instrumented copy + kernel | contract + pyflakes; copy | contract + undefined names; two `.mjs` copies | javac: `benchmark/` and `visual/` classes |
| lines and locals | checkpoints in a copy | `sys.settrace`, no copy | checkpoints in a copy (acorn) | checkpoints in a copy (javac trees) |
| a checkpoint waits by | `await` (async copy) | blocking on stdin | blocking on stdin (`readSync`) | blocking on stdin |
| Format | `dart format` | black | js-beautify | google-java-format (AOSP) |
| time factor | 1 | 3 | 2 | 2 |

All workers speak the same JSON-lines protocol (`visualStart`, `advance`,
`run`), so the host, the judge and the browser do not know the language.
Inserted code never contains line breaks, so stack traces and the editor use
the student's own lines everywhere. The operation counts are identical:
one read per element read, one write per element write, one comparison per
comparison, `swap` = two reads + two writes, negative indices are errors.
JavaScript and Java compare with `lessThan`, `lessOrEqual`, `greaterThan`,
`greaterOrEqual` and `equalTo`; Java reads with `get(i)` and writes with
`set(i, e)`.

Toolchains are found once per host: Python as `$SANDBOX_PYTHON`, `python3`,
`python` (or `py -3`); Node as `$SANDBOX_NODE`, `node`, `nodejs`; the JDK in
`$SANDBOX_JAVA_HOME/bin`, `$JAVA_HOME/bin` or on the PATH. The Java runtime
(`languages/java/src`) is compiled with `--release 17` into
`runtime/java/<hash>/classes` on first use. Without a toolchain, only the files
of that language show an explanation. Python runs with `-I -B`.

`./new-algorithm` picks the language from `--lang` (`js` is short for
`javascript`) or the file extension, otherwise from the last explicit choice
(`language:` in `.settings.yaml`), the student's newest file, the class
majority, then Dart.

## Without a Dart SDK

`./run` (and `run.cmd` on Windows) uses the Dart SDK when one is installed,
exactly as before. Without one it starts the host compiled with
`dart compile exe`: `.github/workflows/host.yml` builds it for Linux, macOS
(x64, arm64) and Windows on every push and attaches it to a prerelease
`host-<key>`, where the key is the first 16 hex digits of
`git ls-tree HEAD tool lib pubspec.yaml pubspec.lock | git hash-object --stdin`.
The scripts compute the same key, download the matching program once into
`runtime/host/` and remove older ones. Python, JavaScript and Java work as
usual; `.dart` algorithms report that the Dart SDK is missing
(`DartToolchain` in `tool/languages.dart`, which is the running `dart` under
`dart run`). `SANDBOX_PRECOMPILED=1 ./run` tries this path on a computer
with Dart; `SANDBOX_RELEASES=owner/repo` uses the releases of a fork.
`new-algorithm.cmd` runs `./new-algorithm` with the bash of Git for Windows.

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
workers of every installed language and talks to them, the Python, Java and
JavaScript worker/daemon tests (each when its toolchain is installed), the
`new-algorithm` tests and the Node tests for browser helpers.

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

## Light theme

`web/light.css` is generated from `web/style.css`: every rule that sets a color
is repeated under `:root[data-theme="light"]` with the color mirrored in
lightness. After changing colors in `style.css`, run

```bash
node tool/light-theme.mjs web/style.css web/light.css
```

The choice of theme is stored in `.settings.yaml` (ignored by Git) and written
into `index.html` by the host. The same script and mechanism are used by the
CPU and the Data Structure Sandbox.
