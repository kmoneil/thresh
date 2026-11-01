"""The README's blocks and examples/python's scripts, each run from
examples/ and its output compared with what is written beside it. A block
or script that imports pyarrow, polars or duckdb is skipped where that is
not installed."""

import contextlib
import importlib.util
import io
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = ROOT / "examples"
OPTIONAL = ("pyarrow", "polars", "duckdb")


def missing(source):
    return [m for m in OPTIONAL if re.search(r"^import %s\b" % m, source, re.M) and importlib.util.find_spec(m) is None]


def blocks(text):
    """Each python block, and the text block that follows it, if one does."""
    pattern = re.compile(r"```python\n(.*?)```\n(?:\n```text\n(.*?)```\n)?", re.S)
    return [(m.group(1), m.group(2)) for m in pattern.finditer(text)]


class Readme(unittest.TestCase):
    def test_blocks(self):
        found = blocks((ROOT / "python" / "README.md").read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(found), 6)
        namespace = {}
        cwd = os.getcwd()
        os.chdir(EXAMPLES)
        try:
            for i, (code, want) in enumerate(found):
                with self.subTest(block=i + 1):
                    if missing(code):
                        self.skipTest("not installed: %s" % ", ".join(missing(code)))
                    out = io.StringIO()
                    with contextlib.redirect_stdout(out):
                        exec(compile(code, "README block %d" % (i + 1), "exec"), namespace)
                    if want is not None:
                        self.assertEqual(out.getvalue(), want)
        finally:
            os.chdir(cwd)


class Scripts(unittest.TestCase):
    def test_scripts(self):
        scripts = sorted((EXAMPLES / "python").glob("*.py"))
        self.assertGreaterEqual(len(scripts), 6)
        for script in scripts:
            with self.subTest(script=script.name):
                if missing(script.read_text(encoding="utf-8")):
                    self.skipTest("not installed: %s" % ", ".join(missing(script.read_text(encoding="utf-8"))))
                env = dict(os.environ, PYTHONIOENCODING="utf-8")
                got = subprocess.run(
                    [sys.executable, os.path.join("python", script.name)],
                    cwd=str(EXAMPLES),
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    universal_newlines=True,
                    encoding="utf-8",
                )
                self.assertEqual(got.returncode, 0, got.stderr)
                self.assertEqual(got.stdout, script.with_suffix(".out").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
