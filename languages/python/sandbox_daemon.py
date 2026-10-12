"""Keeps the Python checks and the formatter loaded between edits.

One JSON request and one JSON reply per line, the same protocol as
tool/instrument_daemon.dart. This process never executes student code;
algorithms run in separate, killable worker processes (sandbox_worker.py).

Requests:
    {"id": 1, "op": "inspect",    "path": "...", "content": "..."}
    {"id": 2, "op": "instrument", "path": "...", "content": "...", "out": "DIR"}
    {"id": 3, "op": "format",     "path": "...", "content": "..."}
Replies:
    {"id": 1, "ok": true, "meta": {...}, "diagnostics": []}
    {"id": 2, "ok": false, "error": "...", "diagnostics": [{line, column, length, message}]}
    {"id": 3, "ok": true, "content": "..."}

`inspect` is parser-only (every save). `instrument` is the build step: the
same contract checks plus pyflakes (undefined names and similar mistakes
that Python itself would only report while running). Python needs no
instrumented copy, so nothing is written to `out`.
"""

import ast
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.path.join(os.path.dirname(os.path.dirname(HERE)), "vendor", "python")
if VENDOR not in sys.path:
    sys.path.append(VENDOR)

sys.path.insert(0, HERE)
from sorting_sandbox import Colors  # noqa: E402

PALETTE = {
    name: value
    for name, value in vars(Colors).items()
    if name.isupper() and isinstance(value, str)
}
HEX_COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")
BASE_CLASS = "SortingAlgorithm"


class Problem(Exception):
    def __init__(self, node, message, length=None):
        super().__init__(message)
        self.node = node
        self.message = message
        self.length = length


def diagnostic(line, column, length, message):
    return {
        "line": max(1, int(line or 1)),
        "column": max(1, int(column or 1)),
        "length": max(1, min(40, int(length or 1))),
        "message": message,
        "severity": "error",
    }


def node_diagnostic(problem):
    node = problem.node
    if node is None:
        return diagnostic(1, 1, 1, problem.message)
    line = getattr(node, "lineno", 1)
    column = getattr(node, "col_offset", 0) + 1
    length = problem.length
    if length is None:
        end_line = getattr(node, "end_lineno", line)
        end_column = getattr(node, "end_col_offset", column)
        length = (end_column + 1 - column) if end_line == line else 5
    return diagnostic(line, column, length, problem.message)


def syntax_diagnostic(error):
    line = error.lineno or 1
    column = error.offset or 1
    end = getattr(error, "end_offset", None)
    end_line = getattr(error, "end_lineno", None)
    length = (end - column) if end and end_line == line and end > column else 1
    return diagnostic(line, column, length, error.msg or "Invalid syntax.")


def parse(content, path):
    """The module AST, or raises SyntaxError (including compile-time errors
    such as `return` outside a function)."""
    tree = ast.parse(content, filename=path)
    compile(content, path, "exec", dont_inherit=True)
    return tree


# ------------------------------------------------------------ the contract


def _is_algorithm_class(node):
    for base in node.bases:
        if isinstance(base, ast.Name) and base.id == BASE_CLASS:
            return True
        if isinstance(base, ast.Attribute) and base.attr == BASE_CLASS:
            return True
    return False


def _class_attribute(cls, name):
    """The value node of `name = ...` (or `name: str = ...`) in the class body."""
    for statement in cls.body:
        if isinstance(statement, ast.Assign):
            for target in statement.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return statement, statement.value
        elif isinstance(statement, ast.AnnAssign):
            target = statement.target
            if isinstance(target, ast.Name) and target.id == name and statement.value is not None:
                return statement, statement.value
    return None, None


def _literal_string(value):
    if isinstance(value, ast.Constant) and isinstance(value.value, str):
        return value.value
    return None


def _color(value):
    text = _literal_string(value)
    if text is not None:
        return text if HEX_COLOR.match(text) else None
    if (
        isinstance(value, ast.Attribute)
        and isinstance(value.value, ast.Name)
        and value.value.id == "Colors"
    ):
        return PALETTE.get(value.attr)
    return None


def _own_yield(function):
    stack = list(function.body)
    while stack:
        node = stack.pop()
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
            continue
        if isinstance(node, (ast.Yield, ast.YieldFrom)):
            return node
        stack.extend(ast.iter_child_nodes(node))
    return None


def check_contract(tree):
    """Metadata of the one algorithm class; raises Problem otherwise."""
    classes = [
        node
        for node in tree.body
        if isinstance(node, ast.ClassDef) and _is_algorithm_class(node)
    ]
    if not classes:
        raise Problem(
            None,
            "No class extending SortingAlgorithm found. Start with: "
            "class MySort(SortingAlgorithm): …",
        )
    if len(classes) > 1:
        raise Problem(
            classes[1],
            "One file must contain exactly one class that extends SortingAlgorithm.",
            5,
        )
    cls = classes[0]

    sort = None
    init = None
    for statement in cls.body:
        if isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if statement.name == "sort":
                sort = statement
            elif statement.name == "__init__":
                init = statement
    if sort is None:
        raise Problem(cls, "Missing method: def sort(self, elements, scratch): …", 5)
    if isinstance(sort, ast.AsyncFunctionDef):
        raise Problem(sort, "sort must stay synchronous; remove async.", 5)
    arguments = sort.args
    if (
        len(arguments.posonlyargs) + len(arguments.args) != 3
        or arguments.vararg
        or arguments.kwarg
        or arguments.kwonlyargs
        or arguments.defaults
    ):
        raise Problem(
            sort,
            "sort must take exactly two parameters besides self: "
            "def sort(self, elements, scratch).",
            3 + len("sort"),
        )
    found_yield = _own_yield(sort)
    if found_yield is not None:
        raise Problem(
            found_yield,
            "sort must sort the list in place; remove yield.",
        )
    if init is not None:
        init_args = init.args
        required = len(init_args.posonlyargs) + len(init_args.args) - len(init_args.defaults)
        required_keywords = [
            name
            for name, default in zip(init_args.kwonlyargs, init_args.kw_defaults)
            if default is None
        ]
        if required > 1 or required_keywords:
            raise Problem(
                init,
                f"The sandbox cannot create {cls.name}(): the class needs a "
                "constructor without parameters.",
                3 + len("__init__"),
            )

    name_statement, name_value = _class_attribute(cls, "name")
    name = _literal_string(name_value)
    if name is None or not name.strip():
        raise Problem(
            name_statement or cls,
            'Give the algorithm a literal name, e.g. name = "Bubble Sort"',
            None if name_statement else 5,
        )
    author_statement, author_value = _class_attribute(cls, "author")
    author = None
    if author_statement is not None:
        author = _literal_string(author_value)
        if author is None or not author.strip():
            raise Problem(
                author_statement,
                'Use a literal author, e.g. author = "Anna", or remove the line.',
            )
    color_statement, color_value = _class_attribute(cls, "color")
    color = _color(color_value) if color_value is not None else None
    if color is None:
        raise Problem(
            color_statement or cls,
            "Choose a color: color = Colors.GREEN or a hex color such as \"#4CAF50\".",
            None if color_statement else 5,
        )

    meta = {"name": name.strip(), "color": color.upper(), "className": cls.name}
    if author is not None:
        meta["author"] = author.strip()
    return meta


def inspect(content, path):
    try:
        tree = parse(content, path)
    except SyntaxError as error:
        return None, {"ok": False, "diagnostics": [syntax_diagnostic(error)]}
    except ValueError as error:  # e.g. NUL bytes
        return None, {"ok": False, "diagnostics": [diagnostic(1, 1, 1, str(error))]}
    try:
        meta = check_contract(tree)
    except Problem as problem:
        return tree, {"ok": False, "diagnostics": [node_diagnostic(problem)]}
    return tree, {"ok": True, "meta": meta, "diagnostics": []}


# ---------------------------------------------------- build-time checks

_flakes = None


def _pyflakes():
    global _flakes
    if _flakes is None:
        from pyflakes import checker, messages

        errors = (
            messages.UndefinedName,
            messages.UndefinedLocal,
            messages.UndefinedExport,
            messages.DuplicateArgument,
            messages.ReturnOutsideFunction,
            messages.YieldOutsideFunction,
            messages.ContinueOutsideLoop,
            messages.BreakOutsideLoop,
            messages.TwoStarredExpressions,
            messages.TooManyExpressionsInStarredAssignment,
        )
        _flakes = (checker, tuple(e for e in errors if isinstance(e, type)))
    return _flakes


def static_errors(tree, path):
    checker, errors = _pyflakes()
    result = []
    found = checker.Checker(tree, filename=path)
    for message in sorted(found.messages, key=lambda m: (m.lineno, getattr(m, "col", 0))):
        if not isinstance(message, errors):
            continue
        text = message.message % message.message_args
        name = message.message_args[0] if message.message_args else None
        length = len(name) if isinstance(name, str) else 1
        result.append(diagnostic(message.lineno, getattr(message, "col", 0) + 1, length, text))
        if len(result) >= 30:
            break
    return result


def instrument(content, path):
    tree, result = inspect(content, path)
    if not result["ok"]:
        return {**result, "error": "Fix the marked problem in your Python source and save again."}
    errors = static_errors(tree, path)
    if errors:
        return {
            "ok": False,
            "meta": result["meta"],
            "error": "Fix the errors in your Python source and save again.",
            "diagnostics": errors,
        }
    return result


# ------------------------------------------------------------ formatting

_black = None


def format_source(content):
    global _black
    try:
        ast.parse(content)
    except SyntaxError as error:
        return {
            "ok": False,
            "error": f"Python could not format this draft: line {error.lineno}: {error.msg}.",
        }
    if _black is None:
        import black

        _black = black
    try:
        formatted = _black.format_str(content, mode=_black.Mode())
    except Exception as error:  # noqa: BLE001
        return {"ok": False, "error": f"Python could not format this draft: {error}"}
    return {"ok": True, "content": formatted}


# ------------------------------------------------------------------ main


def handle(request):
    op = request.get("op")
    content = request.get("content")
    path = request.get("path")
    if not isinstance(content, str) or not isinstance(path, str):
        raise ValueError("Invalid request.")
    if op == "inspect":
        return inspect(content, path)[1]
    if op == "instrument":
        return instrument(content, path)
    if op == "format":
        return format_source(content)
    raise ValueError(f"Unknown operation: {op}")


def main():
    sys.setrecursionlimit(10000)
    out = sys.stdout
    sys.stdout = sys.stderr  # Nothing but replies on the protocol channel.
    out.write(json.dumps({"type": "ready", "pid": os.getpid()}) + "\n")
    out.flush()
    for line in sys.stdin:
        if not line.strip():
            continue
        request_id = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict) or not isinstance(request.get("id"), int):
                raise ValueError("Invalid request.")
            request_id = request["id"]
            reply = handle(request)
        except Exception as error:  # noqa: BLE001 - never die on one request
            reply = {"ok": False, "error": str(error)}
        out.write(json.dumps({"id": request_id, **reply}) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
