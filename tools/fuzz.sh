#!/bin/sh
# Runs the fuzz targets in src/fuzz_test.zig under Zig's fuzzer and fails if
# one of them found an input it fails on.
#
#   tools/fuzz.sh [LIMIT [ROUND]]    LIMIT as zig build --fuzz takes it
#                                    (default 1M), run ROUND at a time
#                                    (default 10K)
#
# Zig 0.17's fuzzer grows its memory for as long as one process runs,
# whatever the target: about 9 MB a second on an M-series Mac, 38 GB after
# 73 minutes. So the limit is run in rounds, each a fresh process that
# starts from the corpus the last one kept in .zig-cache/f. A round of 10K
# stays near 1 GB (20K peaked at 2.1 GB). The first round that finds
# something ends the run.
#
# Zig 0.17.0's `zig build --fuzz` exits 0 when a fuzz test fails, so the
# failure is read from its output instead (dateparsa's tools/fuzz.sh found
# this). The file it names as the saved input comes out empty, so the input
# is read from the fuzzer's own input files, .zig-cache/f/in<N>: a 20-byte
# header whose last u32 is the length, then the input. Each is printed in
# hex. An input is what the target's Smith read: for each string a
# four-byte little-endian length and its bytes, then each choice as eight
# bytes little-endian. Add it to the seeds in src/fuzz_test.zig, or the C
# calls' in src/capi_fuzz_test.zig, before fixing what it found.
#
# The fuzzer turns between every target in the test binary, but Zig
# 0.17's report names only the first ("the scanner agrees ..."): its Runs
# and Coverage lines are all of them together.
set -eu

limit=${1:-1M}
round=${2:-10K}
cd "$(dirname "$0")/.."
log=$(mktemp)
trap 'rm -f "$log" "$log.status"' EXIT

# A count as zig build --fuzz writes it (10K, 1M, 2G), as a number.
count() {
    case "$1" in
    *K) echo $((${1%K} * 1000)) ;;
    *M) echo $((${1%M} * 1000000)) ;;
    *G) echo $((${1%G} * 1000000000)) ;;
    *) echo "$1" ;;
    esac
}

total=$(count "$limit")
step=$(count "$round")
if [ "$step" -ge "$total" ]; then
    step=$total
fi
rounds=$(((total + step - 1) / step))

i=1
while [ "$i" -le "$rounds" ]; do
    echo "fuzz.sh: round $i of $rounds, $step runs"
    {
        status=0
        zig build fuzz --fuzz="$step" 2>&1 || status=$?
        echo "$status" >"$log.status"
    } | tee "$log"

    status=$(cat "$log.status")
    if [ "$status" -ne 0 ]; then
        exit "$status"
    fi
    if grep -q -e "input saved to" -e "failed" "$log"; then
        for f in .zig-cache/f/in*; do
            test_i=$(od -A n -t u4 -j 12 -N 4 "$f" | tr -d ' ')
            len=$(od -A n -t u4 -j 16 -N 4 "$f" | tr -d ' ')
            echo "last input of $f, fuzz test $test_i, $len bytes:"
            od -A d -t x1 -j 20 -N "$len" "$f"
        done
        exit 1
    fi
    i=$((i + 1))
done
