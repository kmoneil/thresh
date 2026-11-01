#!/bin/bash
# vmrun: machine=e2-standard-2 timeout=360 spot=1
#
# A long fuzz campaign, the kind this Mac has neither the space nor the
# hours for: tools/fuzz.sh's rounds on a VM, for as long as the VM has.
#
#   tools/vmrun/vmrun tools/vmrun/jobs/fuzz.sh                    # 6 hours
#   tools/vmrun/vmrun --timeout 720 tools/vmrun/jobs/fuzz.sh      # 12
#   tools/vmrun/vmrun --timeout 30 tools/vmrun/jobs/fuzz.sh 10K   # a smoke run
#
# Rounds of ROUND runs a target (default 20K; each a fresh fuzzer
# process, so memory stays bounded) until the next might not end before
# the VM does, with time left to send the corpus back: past its timeout
# the VM deletes itself and nothing comes back. vmrun says when that is
# ($VMRUN_DEADLINE), so the timeout is the one knob.
#
# zig build --fuzz starts one fuzzer per test binary, and thresh's four
# targets share one, so a campaign uses one core: more sit idle, hence
# e2-standard-2 (8 GB; a 20K round peaked at 2.1 GB on a Mac). Measured
# there: the build takes about 3.5 minutes, and a 10K round (some 42K
# runs over the four targets) about 135 seconds, so 6 hours is about
# 80 rounds of 20K, at a spot price of roughly 2 cents an hour.
#
# Spot: losing a campaign to preemption costs nothing but a rerun, so
# the VM is a spot one (well under half the price; vmrun exits 75 when
# Google took it). --on-demand opts out.
#
# A found input fails the run with the input printed in hex (it is all
# in job.log). The corpus the fuzzer grew comes back as corpus.tgz; to
# carry it into the next campaign, copy it to
# tools/vmrun/seed-corpus.tgz (untracked files ship too, and .gitignore
# does not cover it) and it is unpacked here before the first round. A
# corpus from the Mac or the nightly works the same way: the fuzzer
# keeps one directory per target, named alike on every platform.
set -u
round=${1:-20K}
deadline=${VMRUN_DEADLINE:?run this through tools/vmrun/vmrun}
# To pack and send the corpus back, and slack for a round that runs long.
margin=300

if [ -f tools/vmrun/seed-corpus.tgz ]; then
  mkdir -p .zig-cache/f
  tar xzf tools/vmrun/seed-corpus.tgz -C .zig-cache/f
  echo "fuzz: seeded the corpus with tools/vmrun/seed-corpus.tgz"
fi

# The first round builds the test binary too, so it is the longest
# until another is longer.
status=0 n=0 longest=0
while :; do
  left=$((deadline - $(date +%s)))
  if [ "$left" -lt $((longest + margin)) ]; then
    echo "fuzz: $n round(s) of $round, stopping with $((left / 60)) minutes left"
    break
  fi
  n=$((n + 1))
  echo "fuzz: round $n, $((left / 60)) minutes left"
  start=$(date +%s)
  tools/fuzz.sh "$round" "$round" || { status=$?; break; }
  took=$(($(date +%s) - start))
  echo "fuzz: round $n took ${took}s"
  if [ "$took" -gt "$longest" ]; then longest=$took; fi
done

if [ -d .zig-cache/f ]; then
  tar czf "$RESULTS/corpus.tgz" -C .zig-cache/f .
fi
exit $status
