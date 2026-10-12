"""Worker process for one Python sorting algorithm (one revision of one file).

Started by the host as

    python3 -I -B sandbox_worker.py PATH/algorithm.py CLASS_NAME

and spoken to through stdin/stdout, one JSON object per line - the same
protocol as the Dart worker (lib/worker_core.dart):

    visualStart {requestId, values}  run with checkpoints; one frame whenever the
                                     budget is used up, then wait for `advance`
    advance     {requestId, budget}  grant more checkpoints to the visual run
    run         {requestId, values}  sort once without any visualization
                                     overhead; the host judges the result

Replies: hello, frame, console, complete, runError, runResult, error.

Python needs no instrumented copy: `sys.settrace` reports every executed line
of the student's file together with its local variables. A checkpoint blocks
on stdin until the host grants more budget; Stop simply kills this process.
"""

import importlib.util
import io
import json
import math
import os
import sys
import threading
import traceback
import types

# `python3 -I` does not put this script's directory on sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sorting_sandbox  # noqa: E402
from sorting_sandbox import Element, Elements  # noqa: E402

MAX_PRINTS = 200
MAX_PRINT_CHARACTERS = 65536

# The protocol owns the real stdin/stdout. Student code gets a console that
# forwards `print` to the browser and an empty stdin.
_protocol_out = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
_protocol_in = os.fdopen(os.dup(0), "r", encoding="utf-8")
sys.stdin = io.StringIO("")


def post(message):
    try:
        encoded = json.dumps(message, allow_nan=False)
    except (TypeError, ValueError) as error:
        encoded = json.dumps(
            {
                "type": "error",
                "requestId": str(message.get("requestId", "")),
                "message": f"Could not encode a worker message: {error}",
            }
        )
    _protocol_out.write(encoded + "\n")
    _protocol_out.flush()


# ------------------------------------------------------------------ probe


class Probe:
    """Counts operations; in visual runs also remembers what was touched.

    Element comparisons increment `comparisons` directly (hot path)."""

    __slots__ = ("reads", "writes", "comparisons", "track", "_reads", "_writes")

    def __init__(self, track=False):
        self.reads = 0
        self.writes = 0
        self.comparisons = 0
        self.track = track
        self._reads = {}
        self._writes = {}

    def read(self, label, index):
        self.reads += 1
        if self.track:
            self._reads.setdefault(label, set()).add(index)

    def write(self, label, index):
        self.writes += 1
        if self.track:
            self._writes.setdefault(label, set()).add(index)

    def metrics(self):
        return {
            "reads": self.reads,
            "writes": self.writes,
            "comparisons": self.comparisons,
            "score": self.reads + self.writes + self.comparisons,
        }

    def discard_markers(self):
        self._reads.clear()
        self._writes.clear()

    def take_reads(self):
        return self._take(self._reads)

    def take_writes(self):
        return self._take(self._writes)

    @staticmethod
    def _take(source):
        result = [
            {"list": label, "index": index}
            for label in sorted(source)
            for index in sorted(source[label])
        ]
        source.clear()
        return result


def make_lists(probe, values):
    n = len(values)
    elements = Elements(probe, "list", values, list(range(n)))
    scratch = Elements(probe, "scratch", [0] * n, [-1 - i for i in range(n)])
    return elements, scratch


# ---------------------------------------------------------- student module


class Student:
    def __init__(self, path, class_name):
        self.path = os.path.abspath(path)
        self.class_name = class_name
        self.cls = None
        self.load_error = None
        try:
            spec = importlib.util.spec_from_file_location("algorithm", self.path)
            module = importlib.util.module_from_spec(spec)
            sys.modules["algorithm"] = module
            with Silenced():
                spec.loader.exec_module(module)
            cls = getattr(module, class_name, None)
            if not isinstance(cls, type):
                raise RuntimeError(f"The class {class_name} was not found.")
            self.cls = cls
        except BaseException as error:  # noqa: BLE001 - reported to the student
            self.load_error = describe_failure(error, self.path)

    def create(self):
        return self.cls()


class Silenced:
    """Discards student output (checks and analyses run many sorts)."""

    def __enter__(self):
        self._previous = sys.stdout
        sys.stdout = io.StringIO()
        return self

    def __exit__(self, *exc):
        sys.stdout = self._previous
        return False


# -------------------------------------------------------------- failures


def describe_failure(error, student_path, line=None):
    """An exception as {kind, message, line?, column?, stack?}, with the
    student's own line numbers (the worker runs a byte-identical copy)."""
    frames = [
        frame
        for frame in traceback.extract_tb(error.__traceback__)
        if os.path.abspath(frame.filename) == student_path
    ]
    text = str(error)
    if isinstance(error, SystemExit):
        message = "The algorithm called exit()."
    else:
        message = f"{type(error).__name__}: {text}" if text else type(error).__name__
    if len(message) > 1500:
        message = message[:1500] + "…"
    result = {
        "kind": "stackOverflow" if isinstance(error, RecursionError) else "runtime",
        "message": message,
    }
    if frames:
        innermost = frames[-1]
        result["line"] = innermost.lineno
        column = getattr(innermost, "colno", None)
        if column is not None:
            result["column"] = column + 1
        result["stack"] = [
            f"{frame.name} · line {frame.lineno}" for frame in reversed(frames)
        ][:8]
    elif line:
        result["line"] = line
    return result


# ------------------------------------------------------------ visual runs


def _shorten(text):
    return text if len(text) <= 48 else text[:45] + "…"


def debug_value(value):
    """A local variable as a small JSON-safe display value."""
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else str(value)
    if isinstance(value, str):
        return _shorten(value)
    if isinstance(value, Element):
        return sorting_sandbox._key(value)
    if isinstance(value, Elements):
        return f"Elements({len(value)})"
    if isinstance(value, list):
        return f"List({len(value)})"
    return _shorten(repr(value))


_HIDDEN_TYPES = (types.FunctionType, types.BuiltinFunctionType, types.ModuleType, type)


def visible_locals(frame):
    if frame is None:
        return {}
    result = {}
    for name, value in dict(frame.f_locals).items():
        if name == "self" or name.startswith("__") or name.startswith("."):
            continue
        if isinstance(value, _HIDDEN_TYPES):
            continue
        result[name] = debug_value(value)
    return result


class VisualSession:
    """Cooperative execution: every executed student line is a checkpoint.

    Each checkpoint consumes one unit of budget. When the budget is used up,
    ONE frame describing the current state is sent and the session blocks
    until the host grants more. Nothing is recorded in advance."""

    def __init__(self, request_id, student):
        self.request_id = request_id
        self.student = student
        self.probe = Probe(track=True)
        self.elements = None
        self.scratch = None
        self.budget = 0
        self.line = 0
        self.checkpoint = -1
        self.frame = None
        self.done = False

    # sys.settrace hooks ----------------------------------------------------

    def trace_calls(self, frame, event, arg):
        if os.path.abspath(frame.f_code.co_filename) != self.student.path:
            return None
        return self.trace_lines

    def trace_lines(self, frame, event, arg):
        if event == "line":
            self.reached(frame.f_lineno, frame)
        return self.trace_lines

    # checkpoints -----------------------------------------------------------

    def reached(self, line, frame):
        self.checkpoint += 1
        self.line = line
        self.frame = frame
        if self.budget > 0:
            self.budget -= 1
            if self.budget > 0:
                # A coarse animation frame skips many checkpoints; memory
                # highlighting describes only the final step, as in Dart.
                self.probe.discard_markers()
                return
        self.emit(False)
        self.wait()

    def wait(self):
        while self.budget <= 0:
            raw = _protocol_in.readline()
            if not raw:
                # The host closed the pipe: never raise into student code.
                _protocol_out.flush()
                os._exit(0)
            try:
                message = json.loads(raw)
            except ValueError:
                post({"type": "error", "message": "Invalid worker request."})
                continue
            if not isinstance(message, dict):
                continue
            if message.get("type") == "advance":
                budget = message.get("budget", 1)
                if isinstance(budget, (int, float)) and budget > 0:
                    self.budget += int(budget)
            else:
                post(
                    {
                        "type": "error",
                        "requestId": str(message.get("requestId", "")),
                        "message": "This worker is busy with a visual run.",
                    }
                )

    def emit(self, done):
        post(
            {
                "type": "frame",
                "requestId": self.request_id,
                "done": done,
                "line": self.line,
                "checkpoint": self.checkpoint,
                "locals": visible_locals(self.frame),
                "numbers": sorting_sandbox._keys(self.elements) if self.elements else [],
                "scratch": sorting_sandbox._keys(self.scratch) if self.scratch else [],
                "metrics": self.probe.metrics(),
                "reads": self.probe.take_reads(),
                "writes": self.probe.take_writes(),
            }
        )

    def run(self, values):
        console = Console(self)
        previous_stdout = sys.stdout
        sys.stdout = console
        try:
            self.elements, self.scratch = make_lists(self.probe, values)
            if self.student.load_error is not None:
                raise _LoadFailure()
            algorithm = self.student.create()
            sys.settrace(self.trace_calls)
            try:
                algorithm.sort(self.elements, self.scratch)
            finally:
                sys.settrace(None)
        except _LoadFailure:
            console.close()
            post(
                {
                    "type": "runError",
                    "requestId": self.request_id,
                    "checkpoint": self.checkpoint,
                    "error": self.student.load_error,
                }
            )
            return
        except BaseException as error:  # noqa: BLE001 - reported to the student
            console.close()
            self.emit(False)
            post(
                {
                    "type": "runError",
                    "requestId": self.request_id,
                    "checkpoint": self.checkpoint,
                    "error": describe_failure(error, self.student.path, self.line),
                }
            )
            return
        finally:
            sys.stdout = previous_stdout
        console.close()
        self.done = True
        self.emit(True)
        post({"type": "complete", "requestId": self.request_id})


class _LoadFailure(Exception):
    pass


class Console(io.TextIOBase):
    """Forwards each printed line to the browser, with an upper bound."""

    def __init__(self, session):
        super().__init__()
        self.session = session
        self.buffer_text = ""
        self.count = 0
        self.characters = 0
        self.truncated = False

    def writable(self):
        return True

    def write(self, text):
        if not isinstance(text, str):
            text = str(text)
        self.buffer_text += text
        while "\n" in self.buffer_text:
            line, self.buffer_text = self.buffer_text.split("\n", 1)
            self.emit(line)
        return len(text)

    def close(self):
        if self.buffer_text:
            self.emit(self.buffer_text)
            self.buffer_text = ""

    def emit(self, text):
        session = self.session
        if self.count < MAX_PRINTS and self.characters + len(text) <= MAX_PRINT_CHARACTERS:
            self.count += 1
            self.characters += len(text)
            kind, shown = "stdout", text
        elif not self.truncated:
            self.truncated = True
            kind, shown = "warning", "Further print output was truncated."
        else:
            return
        message = {
            "type": "console",
            "requestId": session.request_id,
            "kind": kind,
            "text": shown,
            "checkpoint": session.checkpoint,
        }
        if session.line > 0:
            message["line"] = session.line
        post(message)


# ------------------------------------------------------------ single sorts


def run_case(student, values):
    """Sorts once without checkpoints: {keys, origins, metrics} or {error}."""
    if student.load_error is not None:
        return {"error": student.load_error}
    probe = Probe()
    elements, scratch = make_lists(probe, values)
    try:
        with Silenced():
            student.create().sort(elements, scratch)
    except BaseException as error:  # noqa: BLE001 - reported to the student
        return {"error": describe_failure(error, student.path)}
    return {
        "keys": sorting_sandbox._keys(elements),
        "origins": sorting_sandbox._origins(elements),
        "metrics": probe.metrics(),
    }


# ------------------------------------------------------------------- main


def int_list(raw):
    if not isinstance(raw, list):
        return []
    return [int(v) for v in raw if isinstance(v, (int, float)) and not isinstance(v, bool)]


def serve(student):
    visual_used = False
    post({"type": "hello", "pid": os.getpid()})
    for raw in _protocol_in:
        if not raw.strip():
            continue
        try:
            message = json.loads(raw)
        except ValueError:
            post({"type": "error", "message": "Invalid worker request."})
            continue
        if not isinstance(message, dict):
            continue
        kind = message.get("type")
        request_id = str(message.get("requestId", ""))
        try:
            if kind == "run":
                post(
                    {
                        "type": "runResult",
                        "requestId": request_id,
                        **run_case(student, int_list(message.get("values"))),
                    }
                )
            elif kind == "visualStart":
                if visual_used:
                    raise RuntimeError("This worker has already run a visual algorithm.")
                visual_used = True
                VisualSession(request_id, student).run(int_list(message.get("values")))
            elif kind == "advance":
                pass  # Only meaningful while a visual run waits.
            else:
                post(
                    {
                        "type": "error",
                        "requestId": request_id,
                        "message": f"Unknown worker message: {kind}",
                    }
                )
        except Exception as error:  # noqa: BLE001 - a bug in the worker itself
            post(
                {
                    "type": "error",
                    "requestId": request_id,
                    "message": str(error),
                    "error": describe_failure(error, student.path),
                }
            )


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: sandbox_worker.py ALGORITHM.py CLASS_NAME\n")
        sys.exit(64)
    # Deep recursion (e.g. Quicksort on sorted input) needs a large stack.
    sys.setrecursionlimit(20000)
    try:
        threading.stack_size(512 * 1024 * 1024)
    except (ValueError, RuntimeError):
        pass
    student_holder = {}

    def body():
        student_holder["student"] = Student(sys.argv[1], sys.argv[2])
        serve(student_holder["student"])

    thread = threading.Thread(target=body, name="student")
    thread.start()
    thread.join()
    _protocol_out.flush()
    # A suspended visual run must not keep the process alive.
    os._exit(0)


if __name__ == "__main__":
    main()
