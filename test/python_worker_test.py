"""Python worker and daemon tests: real processes, the host's protocol.

    python3 -I -B test/python_worker_test.py
"""

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKER = os.path.join(ROOT, "languages", "python", "sandbox_worker.py")
DAEMON = os.path.join(ROOT, "languages", "python", "sandbox_daemon.py")
HEADER = "from sorting_sandbox import Colors, Elements, SortingAlgorithm\n\n\n"


def write_algorithm(directory, source, name="algorithm.py"):
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as file:
        file.write(source)
    return path


class Worker:
    def __init__(self, path, class_name):
        self.process = subprocess.Popen(
            [sys.executable, "-I", "-B", WORKER, path, class_name],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        hello = self.receive()
        assert hello["type"] == "hello", hello

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def receive(self):
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError("worker exited: " + self.process.stderr.read())
        return json.loads(line)

    def run(self, values):
        self.send({"type": "run", "requestId": "r", "values": values})
        reply = self.receive()
        assert reply["type"] == "runResult", reply
        return reply

    def visual(self, values, budget=1):
        """Runs to the end; returns (frames, console, error)."""
        frames, console = [], []
        self.send({"type": "visualStart", "requestId": "v", "values": values})
        while True:
            message = self.receive()
            kind = message["type"]
            if kind == "frame":
                frames.append(message)
                if not message["done"]:
                    self.send({"type": "advance", "requestId": "v", "budget": budget})
            elif kind == "console":
                console.append(message)
            elif kind == "complete":
                return frames, console, None
            elif kind in ("runError", "error"):
                return frames, console, message

    def close(self):
        self.process.kill()
        self.process.wait()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


class WorkerTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.workers = []

    def tearDown(self):
        for worker in self.workers:
            worker.close()
        self.directory.cleanup()

    def worker(self, source, class_name):
        worker = Worker(write_algorithm(self.directory.name, source), class_name)
        self.workers.append(worker)
        return worker

    def template(self):
        with open(os.path.join(ROOT, "templates", "bubble_sort.py"), encoding="utf-8") as file:
            return file.read()

    def test_template_runs_step_by_step_and_sorts(self):
        frames, console, error = self.worker(self.template(), "BubbleSort").visual([3, 1, 2])
        self.assertIsNone(error)
        last = frames[-1]
        self.assertTrue(last["done"])
        self.assertEqual(last["numbers"], [1, 2, 3])
        self.assertEqual(last["scratch"], [0, 0, 0])
        lines = {frame["line"] for frame in frames}
        self.assertIn(12, lines, "the if line of the template")
        self.assertEqual(frames[0]["checkpoint"], 0)
        self.assertEqual(frames[0]["line"], 9)
        self.assertEqual(frames[3]["locals"]["i"], 0)
        self.assertEqual(frames[3]["locals"]["elements"], "Elements(3)")
        self.assertNotIn("self", frames[3]["locals"])
        # 3 outer iterations x 2 comparisons, exactly like the Dart template.
        self.assertEqual(last["metrics"]["comparisons"], 6)
        self.assertEqual(
            last["metrics"]["score"],
            last["metrics"]["reads"] + last["metrics"]["writes"] + last["metrics"]["comparisons"],
        )

    def test_frames_mark_reads_and_writes_of_the_last_step_only(self):
        frames, _, error = self.worker(self.template(), "BubbleSort").visual([2, 1], budget=1)
        self.assertIsNone(error)
        swaps = [f for f in frames if f["writes"]]
        self.assertTrue(swaps)
        self.assertEqual(
            swaps[0]["writes"], [{"list": "list", "index": 0}, {"list": "list", "index": 1}]
        )
        coarse, _, _ = self.worker(self.template(), "BubbleSort").visual([2, 1], budget=1000)
        self.assertEqual(len(coarse), 2, "first checkpoint and the final frame")
        self.assertEqual(coarse[-1]["writes"], [])

    def test_element_locals_show_their_hidden_key(self):
        source = HEADER + textwrap.dedent(
            """\
            class Peek(SortingAlgorithm):
                name = "Peek"
                color = Colors.RED

                def sort(self, elements, scratch):
                    first = elements[0]
                    pass
            """
        )
        frames, _, error = self.worker(source, "Peek").visual([42, 7])
        self.assertIsNone(error)
        self.assertEqual(frames[-2]["locals"]["first"], 42)

    def test_runs_report_keys_origins_and_counts(self):
        worker = self.worker(self.template(), "BubbleSort")
        result = worker.run([2, 2, 1])
        self.assertEqual(result["keys"], [1, 2, 2])
        self.assertEqual(result["origins"], [2, 0, 1])
        metrics = result["metrics"]
        self.assertEqual(metrics["comparisons"], 6)
        # Several runs in one worker (the host sends one input at a time).
        self.assertEqual(worker.run([])["keys"], [])
        self.assertEqual(worker.run(list(range(50, 0, -1)))["keys"], list(range(1, 51)))

    def test_swap_counts_like_a_manual_swap(self):
        source = HEADER + textwrap.dedent(
            """\
            class Manual(SortingAlgorithm):
                name = "Manual"
                color = Colors.RED

                def sort(self, elements, scratch):
                    temp = elements[1]
                    elements[1] = elements[0]
                    elements[0] = temp
            """
        )
        manual = self.worker(source, "Manual").run([2, 1])["metrics"]
        swap_source = source.replace(
            "temp = elements[1]\n        elements[1] = elements[0]\n        elements[0] = temp",
            "elements.swap(0, 1)",
        )
        swapped = self.worker(swap_source, "Manual").run([2, 1])["metrics"]
        self.assertEqual(manual, swapped)
        self.assertEqual(manual["reads"], 2)
        self.assertEqual(manual["writes"], 2)

    def test_runtime_errors_and_print_output_carry_source_lines(self):
        source = HEADER + textwrap.dedent(
            """\
            class OffByOne(SortingAlgorithm):
                name = "Off by one"
                color = Colors.RED

                def sort(self, elements, scratch):
                    print("start")
                    for i in range(len(elements) + 1):
                        if elements[i] > elements[0]:
                            elements.swap(i, 0)
            """
        )
        worker = self.worker(source, "OffByOne")
        frames, console, error = worker.visual([2, 1])
        self.assertEqual(console[0]["text"], "start")
        self.assertEqual(console[0]["line"], 9)
        self.assertEqual(error["type"], "runError")
        self.assertEqual(error["error"]["line"], 11)
        self.assertIn("IndexError", error["error"]["message"])
        self.assertFalse(frames[-1]["done"], "the state at the moment of failure")
        result = self.worker(source, "OffByOne").run([2, 1])
        self.assertEqual(result["error"]["line"], 11)
        self.assertIn("sort · line 11", result["error"]["stack"])

    def test_negative_indices_are_errors_not_wraparound(self):
        source = HEADER + textwrap.dedent(
            """\
            class Wrap(SortingAlgorithm):
                name = "Wrap"
                color = Colors.RED

                def sort(self, elements, scratch):
                    x = elements[-1]
            """
        )
        result = self.worker(source, "Wrap").run([1, 2])
        self.assertIn("out of range", result["error"]["message"])

    def test_elements_cannot_be_compared_with_numbers(self):
        source = HEADER + textwrap.dedent(
            """\
            class Numbers(SortingAlgorithm):
                name = "Numbers"
                color = Colors.RED

                def sort(self, elements, scratch):
                    if elements[0] < 3:
                        pass
            """
        )
        result = self.worker(source, "Numbers").run([1, 2])
        self.assertIn("only be compared with another Element", result["error"]["message"])

    def test_helpers_recursion_and_scratch_work(self):
        source = HEADER + textwrap.dedent(
            """\
            def merge_sort(elements, scratch, left, right):
                if right - left < 2:
                    return
                middle = (left + right) // 2
                merge_sort(elements, scratch, left, middle)
                merge_sort(elements, scratch, middle, right)
                i, j = left, middle
                for k in range(left, right):
                    if i < middle and (j >= right or elements[i] <= elements[j]):
                        scratch[k] = elements[i]
                        i += 1
                    else:
                        scratch[k] = elements[j]
                        j += 1
                for k in range(left, right):
                    elements[k] = scratch[k]


            class Merge(SortingAlgorithm):
                name = "Merge Sort"
                color = Colors.ORANGE

                def sort(self, elements, scratch):
                    merge_sort(elements, scratch, 0, len(elements))
            """
        )
        frames, _, error = self.worker(source, "Merge").visual([5, 2, 4, 1, 3])
        self.assertIsNone(error)
        self.assertEqual(frames[-1]["numbers"], [1, 2, 3, 4, 5])
        self.assertIn(5, {frame["line"] for frame in frames}, "helper lines are traced")
        result = self.worker(source, "Merge").run(list(range(300, 0, -1)))
        self.assertEqual(result["keys"], list(range(1, 301)))

    def test_deep_recursion_is_possible_and_infinite_recursion_is_reported(self):
        source = HEADER + textwrap.dedent(
            """\
            class Deep(SortingAlgorithm):
                name = "Deep"
                color = Colors.RED

                def down(self, n):
                    return 0 if n == 0 else self.down(n - 1)

                def sort(self, elements, scratch):
                    self.down(len(elements))
            """
        )
        self.assertEqual(self.worker(source, "Deep").run([0] * 4000)["keys"], [0] * 4000)
        endless = source.replace("0 if n == 0 else ", "")
        result = self.worker(endless, "Deep").run([1])
        self.assertEqual(result["error"]["kind"], "stackOverflow")

    def test_a_broken_module_reports_its_error_on_every_request(self):
        source = HEADER + "x = undefined_name\n"
        worker = self.worker(source, "Missing")
        result = worker.run([1])
        self.assertIn("NameError", result["error"]["message"])
        self.assertEqual(result["error"]["line"], 4)
        _, _, error = worker.visual([1])
        self.assertEqual(error["type"], "runError")

    def test_student_code_cannot_read_the_protocol(self):
        source = HEADER + textwrap.dedent(
            """\
            import sys


            class Sneaky(SortingAlgorithm):
                name = "Sneaky"
                color = Colors.RED

                def sort(self, elements, scratch):
                    print(repr(sys.stdin.read()))
            """
        )
        _, console, error = self.worker(source, "Sneaky").visual([1])
        self.assertIsNone(error)
        self.assertEqual(console[0]["text"], "''")

    def test_stability_is_visible_through_origins(self):
        source = HEADER + textwrap.dedent(
            """\
            class Selection(SortingAlgorithm):
                name = "Selection"
                color = Colors.RED

                def sort(self, elements, scratch):
                    for i in range(len(elements)):
                        smallest = i
                        for j in range(i + 1, len(elements)):
                            if elements[j] < elements[smallest]:
                                smallest = j
                        if smallest != i:
                            elements.swap(i, smallest)
            """
        )
        result = self.worker(source, "Selection").run([2, 2, 1])
        self.assertEqual(result["keys"], [1, 2, 2])
        self.assertEqual(result["origins"], [2, 1, 0], "unstable: the two 2s swapped")


class Daemon:
    def __init__(self):
        self.process = subprocess.Popen(
            [sys.executable, "-I", "-B", DAEMON],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        ready = json.loads(self.process.stdout.readline())
        assert ready["type"] == "ready", ready
        self.next = 0

    def request(self, op, content, path="/tmp/x/algorithm.py"):
        self.next += 1
        self.process.stdin.write(
            json.dumps({"id": self.next, "op": op, "path": path, "content": content, "out": "/tmp"})
            + "\n"
        )
        self.process.stdin.flush()
        reply = json.loads(self.process.stdout.readline())
        assert reply["id"] == self.next, reply
        return reply

    def close(self):
        self.process.stdin.close()
        self.process.wait()
        self.process.stdout.close()


class DaemonTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.daemon = Daemon()

    @classmethod
    def tearDownClass(cls):
        cls.daemon.close()

    def inspect(self, source):
        return self.daemon.request("inspect", source)

    def test_the_template_is_valid(self):
        with open(os.path.join(ROOT, "templates", "bubble_sort.py"), encoding="utf-8") as file:
            result = self.daemon.request("instrument", file.read())
        self.assertTrue(result["ok"], result)
        self.assertEqual(
            result["meta"],
            {"name": "Bubble Sort", "color": "#4CAF50", "className": "BubbleSort"},
        )

    def test_the_empty_template_is_valid(self):
        with open(os.path.join(ROOT, "templates", "empty.py.tmpl"), encoding="utf-8") as file:
            source = file.read().replace("@@CLASS@@", "QuickSort").replace("@@NAME@@", "Quick Sort")
        result = self.daemon.request("instrument", source)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["meta"]["name"], "Quick Sort")

    def test_syntax_errors_have_positions(self):
        result = self.inspect(HEADER + "class A(SortingAlgorithm)\n    name = 'A'\n")
        self.assertFalse(result["ok"])
        self.assertEqual(result["diagnostics"][0]["line"], 4)

    def test_metadata_rules(self):
        base = HEADER + 'class A(SortingAlgorithm):\n    name = "A"\n    color = Colors.RED\n\n    def sort(self, elements, scratch):\n        pass\n'
        self.assertTrue(self.inspect(base)["ok"])
        self.assertEqual(self.inspect(base)["meta"]["color"], "#F44336")
        hexed = base.replace("Colors.RED", '"#12abef"')
        self.assertEqual(self.inspect(hexed)["meta"]["color"], "#12ABEF")
        with_author = base.replace('    name = "A"\n', '    name = "A"\n    author = "Anna"\n')
        self.assertEqual(self.inspect(with_author)["meta"]["author"], "Anna")

        cases = {
            "no class": (HEADER + "x = 1\n", "No class extending SortingAlgorithm"),
            "two classes": (base + "\n\nclass B(SortingAlgorithm):\n    pass\n", "exactly one class"),
            "no name": (base.replace('    name = "A"\n', ""), "literal name"),
            "computed name": (base.replace('name = "A"', 'name = "A" + "B"'), "literal name"),
            "bad color": (base.replace("Colors.RED", "Colors.MAUVE"), "color"),
            "no sort": (base.replace("def sort", "def sorted"), "Missing method"),
            "wrong parameters": (base.replace("self, elements, scratch", "self, elements"), "exactly two"),
            "async": (base.replace("def sort", "async def sort"), "synchronous"),
            "generator": (base.replace("pass", "yield 1"), "yield"),
            "constructor": (
                base + "\n    def __init__(self, size):\n        self.size = size\n",
                "constructor without parameters",
            ),
        }
        for label, (source, message) in cases.items():
            with self.subTest(label):
                result = self.inspect(source)
                self.assertFalse(result["ok"], label)
                self.assertIn(message, result["diagnostics"][0]["message"])

    def test_build_reports_undefined_names_with_their_line(self):
        source = HEADER + textwrap.dedent(
            """\
            class Typo(SortingAlgorithm):
                name = "Typo"
                color = Colors.RED

                def sort(self, elements, scratch):
                    elements.swap(0, lenght)
            """
        )
        self.assertTrue(self.inspect(source)["ok"], "inspect is parser-only")
        result = self.daemon.request("instrument", source)
        self.assertFalse(result["ok"])
        self.assertEqual(result["diagnostics"][0]["line"], 9)
        self.assertIn("lenght", result["diagnostics"][0]["message"])

    def test_format(self):
        result = self.daemon.request("format", "x=[1,2 ,3]\ndef f( a ):\n  return a\n")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["content"], "x = [1, 2, 3]\n\n\ndef f(a):\n    return a\n")
        broken = self.daemon.request("format", "def f(:\n")
        self.assertFalse(broken["ok"])
        self.assertIn("line 1", broken["error"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
