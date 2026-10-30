# Performance

What thresh does a second, stage by stage, and how that is measured and
held. Every number here says the machine and the commit it came from.

## Stages

`zig build bench` (ReleaseFast) builds 1 GB of CSV in memory for each of
three profiles and runs each stage over it three times, keeping the fastest.
The input is in memory so the disk is not what is measured; a mapped file
in the page cache reads the same way. Each stage includes the ones before it.

| Stage | What it does |
| --- | --- |
| stage1 | the structural index alone: delimiters and line breaks outside quotes, as bitmasks |
| parse | stages 1 and 2: records and fields, in batches of 65,536 rows |
| validate | every cell checked against the profile's schema |
| csv | validated rows built into typed columns and written as RFC 4180 CSV |
| arrow | the same, written as Arrow IPC (stream format) |
| reference | the scalar reference parser, byte at a time, for scale |

The writers write to a sink that discards, so their numbers are the
encoding, not the disk.

Profiles: **narrow**, six short columns a row (int64, an enum, decimal(12,2),
int64, bool, a date with a format); **wide**, thirty columns a row (int64,
decimal(10,3), and three strings, two of them quoted with embedded commas
and doubled quotes); **text**, four columns of which one is 1 to 20 KB of
quoted prose with line breaks and doubled quotes.

Apple M5 Max (18 cores, 64 GB), macOS 27.2, Zig 0.17.0, one core: commit
2d12371's code with this benchmark. MB/s of input:

| profile | stage1 | parse | validate | csv | arrow | reference |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| narrow | 6,909 | 1,286 | 473 | 267 | 343 | 1,185 |
| wide | 7,172 | 1,351 | 509 | 250 | 368 | 1,186 |
| text | 6,346 | 3,396 | 1,001 | 894 | 962 | 1,998 |

Against the spec's targets, which name one x86_64 core with AVX2: stage 1 at
1 GB/s or better, stages 1 and 2 at 600 MB/s, validation with Arrow at 350 to
500 MB/s. On this machine stage 1 is 6 to 7 times the target and stages 1
and 2 twice it; Arrow output is at the target's low end on the narrow
profile (343 MB/s) and above it on the others. Built for x86_64-v3 (AVX2)
and run under Rosetta on the same machine (commit c6a49d6, 256 MB, before
validation existed), stage 1 ran at 3.6 to 4.1 GB/s: a lower bound for
x86_64, not a measurement of one.

Where the time goes: on the narrow and wide profiles the index is about a
fifth of the parse's time, and stage 2 (records and fields from the index)
leaves the whole only about 1.1 times as fast as the scalar reference: the
first place to look for speed. On the text profile, where a long quoted field is
mostly bytes the index skips, it is 1.7 times. CSV output costs more than
Arrow because every field is scanned for bytes that need quoting.

## Files in parallel

`zig build scale -Doptimize=ReleaseFast` (test/scale/run.py) validates 32
files of 32 MiB (1 GiB, already in the page cache) with `--jobs` 1 to 16, on
the same machine, commit 68bbf4d:

| jobs | MB/s | speedup |
| ---: | ---: | ---: |
| 1 | 400 | 1.0x |
| 2 | 775 | 1.9x |
| 4 | 1,386 | 3.5x |
| 8 | 2,409 | 6.0x |
| 16 | 4,045 | 10.1x |

The M5 Max mixes performance and efficiency cores, so the curve bends
before 16; the spec's "linear to 16 workers" wants a machine with 16 cores
of one kind to show. The same run validates 10,000 small files in one
invocation in 0.4 s.

## The regression gate

A pull request may not make any stage of any profile more than 10% slower.
`tools/bench_gate.sh BASE` builds the benchmark at BASE (in a git worktree)
and at the working tree, runs them in turns, BASE then HEAD, three rounds
on 256 MiB a profile, and `tools/bench_compare.py` compares each stage's
best round. CI's `benchmark gate` job runs it against the pull request's
base branch.

Both sides run on one machine in one job because a hosted runner is not a
fixed machine: a baseline stored from one run and compared with another
would measure the difference between runners, which is often more than 10%.
Taking turns and the best of three keeps a noisy neighbour from failing a
change that did nothing.

## Reproducing

```sh
zig build bench                                   # all profiles, 1 GB each
zig build bench -- --profile text --size 268435456 --runs 5
zig build bench -- --json                         # what the gate reads
zig build scale -Doptimize=ReleaseFast            # files in parallel
tools/bench_gate.sh origin/main                   # this tree against main
```

Run with the machine otherwise idle; a browser or a build next to it moves
these numbers by more than the gate's 10%.
