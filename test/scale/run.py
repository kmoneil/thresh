#!/usr/bin/env python3
"""The parallel driver at scale: milestone 10's checks.

    zig build scale                      (or python3 test/scale/run.py THRESH)

1. 10,000 files in one invocation: every one validated, every report and
   summary.json written, exit 0.
2. Throughput with --jobs 1, 2, 4, 8 and 16 over 32 files of 32 MiB,
   printed as MB/s and speedup (the machine decides what scaling it has;
   this only fails if more workers are slower than one).
3. Ctrl-C: a convert interrupted mid-run exits 130, leaves no temporary
   file, and every output file it did leave is byte for byte the one an
   uninterrupted run writes.

Everything is generated from a fixed seed into a temporary directory.
"""

import json
import os
import random
import signal
import subprocess
import sys
import tempfile
import time

SCHEMA = {
    "columns": [
        {"name": "id", "type": "int64", "nullable": False},
        {"name": "amount", "type": "decimal", "precision": 12, "scale": 2},
        {"name": "status", "type": "enum", "values": ["open", "closed", "pending"]},
        {"name": "note", "type": "string"},
    ]
}


def write_file(path, rows, rng):
    with open(path, "w", newline="") as f:
        f.write("id,amount,status,note\n")
        for i in range(rows):
            note = rng.choice(["plain", '"a, quoted one"', "ok", '"say ""hi"""'])
            f.write("%d,%d.%02d,%s,%s\n" % (i + 1, rng.randrange(100000), rng.randrange(100), rng.choice(["open", "closed", "pending"]), note))


def thresh(binary, args, **kw):
    return subprocess.run([binary] + args, capture_output=True, text=True, **kw)


def many_files(binary, root, rng):
    d = os.path.join(root, "many")
    os.makedirs(d)
    files = []
    for i in range(10000):
        p = os.path.join(d, "f%05d.csv" % i)
        write_file(p, 5, rng)
        files.append(p)
    schema = os.path.join(root, "s.json")
    reports = os.path.join(root, "reports")
    start = time.time()
    r = thresh(binary, ["validate"] + files + ["--schema", schema, "--report", reports, "--quiet"])
    took = time.time() - start
    if r.returncode != 0:
        sys.exit("10,000 files: exit %d\n%s" % (r.returncode, r.stderr[-2000:]))
    with open(os.path.join(reports, "summary.json")) as f:
        summary = json.load(f)
    assert summary["files"] == 10000 and summary["passed"] == 10000, summary
    assert len(os.listdir(reports)) == 10001
    print("10,000 files: all passed, 10,000 reports and summary.json, %.1f s" % took)


def scaling(binary, root, rng):
    d = os.path.join(root, "big")
    os.makedirs(d)
    files = []
    target = 32 << 20
    for i in range(32):
        p = os.path.join(d, "b%02d.csv" % i)
        rows = target // 40
        write_file(p, rows, rng)
        files.append(p)
    total = sum(os.path.getsize(p) for p in files)
    schema = os.path.join(root, "s.json")
    # Once to bring the files into the page cache.
    thresh(binary, ["validate"] + files + ["--schema", schema, "--quiet"])
    base = None
    print("%-6s %10s %8s" % ("jobs", "MB/s", "speedup"))
    for jobs in (1, 2, 4, 8, 16):
        start = time.time()
        r = thresh(binary, ["validate"] + files + ["--schema", schema, "--quiet", "--jobs", str(jobs)])
        took = time.time() - start
        assert r.returncode == 0, r.stderr
        mbs = total / 1e6 / took
        base = base or mbs
        print("%-6d %10.0f %7.1fx" % (jobs, mbs, mbs / base))
        if jobs > 1 and mbs < base * 0.9:
            sys.exit("--jobs %d is slower than --jobs 1" % jobs)
    return files


def ctrl_c(binary, root, files):
    schema = os.path.join(root, "s.json")
    full = os.path.join(root, "full")
    r = thresh(binary, ["run"] + files + ["--schema", schema, "--to", "arrow", "--out", full, "--quiet", "--jobs", "4"])
    assert r.returncode == 0, r.stderr
    cut = os.path.join(root, "cut")
    p = subprocess.Popen([binary, "run"] + files + ["--schema", schema, "--to", "arrow", "--out", cut, "--quiet", "--jobs", "4"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    # Long enough for some files to finish, not all.
    time.sleep(0.4)
    p.send_signal(signal.SIGINT)
    _, err = p.communicate(timeout=60)
    if p.returncode != 130:
        sys.exit("interrupted run: exit %d, not 130\n%s" % (p.returncode, err[-2000:]))
    left = os.listdir(cut) if os.path.isdir(cut) else []
    tmp = [n for n in left if n.endswith(".tmp")]
    if tmp:
        sys.exit("interrupted run left temporary files: %s" % tmp)
    for n in left:
        with open(os.path.join(cut, n), "rb") as a, open(os.path.join(full, n), "rb") as b:
            if a.read() != b.read():
                sys.exit("interrupted run left a partial %s" % n)
    print("Ctrl-C: exit 130, no temporary file, %d of %d outputs complete and the rest not written" % (len(left), len(files)))


def main():
    binary = os.path.abspath(sys.argv[1])
    rng = random.Random(10)
    with tempfile.TemporaryDirectory() as root:
        with open(os.path.join(root, "s.json"), "w") as f:
            json.dump(SCHEMA, f)
        many_files(binary, root, rng)
        files = scaling(binary, root, rng)
        ctrl_c(binary, root, files)


if __name__ == "__main__":
    main()
