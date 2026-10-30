#!/bin/sh
# Fails if a stage of the benchmark is more than 10% slower at HEAD than at
# BASE, measured on this machine in this run: hosted runners are not fixed
# machines, so a stored baseline would measure the runner, not the change.
#
#   tools/bench_gate.sh BASE [SIZE] [ROUNDS]
#
# BASE is a git ref. Both are built (ReleaseFast) and run in turns, BASE
# then HEAD, ROUNDS times (default 3) on SIZE bytes a profile (default 256
# MiB); each stage's best run counts. A BASE whose bench has no --json
# (older than the gate) passes with a note.
set -eu

base=$1
size=${2:-268435456}
rounds=${3:-3}
root=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
trap 'git -C "$root" worktree remove --force "$work/base" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

git -C "$root" worktree add --detach "$work/base" "$base" >/dev/null
(cd "$work/base" && zig build bench-install --pkg-dir "$root/zig-pkg" -p "$work/base-out")
(cd "$root" && zig build bench-install -p "$work/head-out")

if ! "$work/base-out/bin/bench" --size 1024 --runs 1 --json >/dev/null 2>&1; then
    echo "bench_gate: $base's bench has no --json; nothing to compare against"
    exit 0
fi
i=0
while [ "$i" -lt "$rounds" ]; do
    "$work/base-out/bin/bench" --size "$size" --runs 1 --json >>"$work/base.jsonl"
    "$work/head-out/bin/bench" --size "$size" --runs 1 --json >>"$work/head.jsonl"
    i=$((i + 1))
done
python3 -I "$root/tools/bench_compare.py" "$work/base.jsonl" "$work/head.jsonl"
