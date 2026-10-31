#!/usr/bin/env python3
"""Compares two benchmark runs, each a file of bench --json lines (one a
round), and fails if HEAD is more than 10% slower than BASE at any stage
thresh ships. Each stage's best round counts on either side. The
reference parser's stage is shown and not gated: it is the tests' oracle,
measured for scale, and its speed is nothing a user sees.

    python3 tools/bench_compare.py BASE.jsonl HEAD.jsonl [TOLERANCE]
"""

import json
import sys

UNGATED = {"reference"}


def best(path):
    out = {}
    with open(path) as f:
        for line in f:
            for profile, stages in json.loads(line).items():
                for stage, mbs in stages.items():
                    key = (profile, stage)
                    out[key] = max(out.get(key, 0), mbs)
    return out


def main():
    base, head = best(sys.argv[1]), best(sys.argv[2])
    tolerance = float(sys.argv[3]) if len(sys.argv) > 3 else 0.10
    worse = []
    print("%-8s %-10s %10s %10s %8s" % ("profile", "stage", "base", "head", "change"))
    for key in sorted(base):
        if key not in head:
            continue
        b, h = base[key], head[key]
        change = (h - b) / b if b else 0
        mark = ""
        if change < -tolerance:
            if key[1] in UNGATED:
                mark = "  slower (not gated)"
            else:
                worse.append(key)
                mark = "  slower"
        print("%-8s %-10s %10.0f %10.0f %+7.1f%%%s" % (key[0], key[1], b, h, change * 100, mark))
    if worse:
        sys.exit("bench_compare: %d stage(s) more than %d%% slower: %s" % (len(worse), tolerance * 100, ", ".join("%s/%s" % k for k in worse)))


if __name__ == "__main__":
    main()
