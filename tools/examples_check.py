"""Runs every command in a Markdown walkthrough and checks what it prints.

    python3 -I tools/examples_check.py THRESH PAGE.md [--dir DIR] [--update]

A ```console block holds commands, each a line starting "$ ", and after
each what it prints, stdout and stderr together as a terminal shows them,
then "[exit N]" when its status is not 0. The commands run in order, in
a copy of the page's directory (or of --dir, for a page that shows
another directory's files, as the top README shows examples/), with
THRESH's directory first on PATH, so a schema one command writes the
next can read. Numbers that
change from run to run (MB/s, timing_ms, throughput_mb_s) are not
compared. With --update the walkthrough is rewritten with what the
commands print, for when thresh's output changes on purpose.
"""

import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile


def blocks(lines):
    """Each console block's (first line, last line) indexes, fences out."""
    out, start = [], None
    for i, line in enumerate(lines):
        if start is None and line.strip() == "```console":
            start = i + 1
        elif start is not None and line.strip() == "```":
            out.append((start, i))
            start = None
    if start is not None:
        sys.exit("examples_check: a console block is never closed")
    return out


def steps(body):
    """A block's commands, each with what it should print and its status."""
    out = []
    for line in body:
        if line.startswith("$ "):
            out.append([line[2:], [], 0])
        elif not out:
            sys.exit("examples_check: output before any command: %r" % line)
        elif re.fullmatch(r"\[exit \d+\]", line):
            out[-1][2] = int(line[6:-1])
        else:
            out[-1][1].append(line)
    return out


def normal(line):
    line = re.sub(r"\b\d+ MB/s", "N MB/s", line)
    line = re.sub(r'("(?:sniff|parse|write)": )\d+', r"\1N", line)
    return re.sub(r'("throughput_mb_s": )[\d.]+', r"\1N", line)


def main():
    args = [a for a in sys.argv[1:] if a != "--update"]
    update = "--update" in sys.argv[1:]
    run_dir = None
    if "--dir" in args:
        i = args.index("--dir")
        run_dir = os.path.abspath(args[i + 1])
        del args[i : i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    thresh, doc = os.path.abspath(args[0]), os.path.abspath(args[1])
    lines = open(doc, encoding="utf-8").read().split("\n")
    work = tempfile.mkdtemp(prefix="thresh-examples-")
    try:
        here = os.path.join(work, "w")
        shutil.copytree(run_dir or os.path.dirname(doc), here)
        env = dict(os.environ, PATH=os.path.dirname(thresh) + os.pathsep + os.environ.get("PATH", ""))
        # Windows has no /bin/sh; Git for Windows puts its sh on PATH.
        sh = shutil.which("sh") or "/bin/sh"
        failed, rewritten, last = 0, [], 0
        for start, end in blocks(lines):
            rewritten += lines[last:start]
            for cmd, want, code in steps(lines[start:end]):
                p = subprocess.run([sh, "-c", cmd], cwd=here, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                got = p.stdout.decode("utf-8", "replace").rstrip("\n")
                got = got.split("\n") if got else []
                rewritten.append("$ " + cmd)
                rewritten += got
                if p.returncode != 0:
                    rewritten.append("[exit %d]" % p.returncode)
                if [normal(x) for x in got] != [normal(x) for x in want] or p.returncode != code:
                    failed += 1
                    if not update:
                        print("examples_check: $ %s" % cmd)
                        if p.returncode != code:
                            print("  exit %d, the walkthrough says %d" % (p.returncode, code))
                        for d in difflib.unified_diff(want, got, "walkthrough", "thresh", lineterm="", n=1):
                            print("  " + d)
            last = end
        rewritten += lines[last:]
        if update:
            open(doc, "w", encoding="utf-8").write("\n".join(rewritten))
            print("examples_check: %d command%s rewritten" % (failed, "" if failed == 1 else "s"))
        elif failed:
            sys.exit("examples_check: %d command%s print other than the walkthrough says (--update rewrites it)" % (failed, "" if failed == 1 else "s"))
    finally:
        shutil.rmtree(work)


main()
