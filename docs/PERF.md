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
| report | the same, with each column's statistics, as `--report` and the library have them |
| infer | every value's type inferred, with each column's statistics, as `infer` reads a file |
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

## The sweep of 2026-11-02

A pass over every stage with a profiler (`bench --stage` under sample(1))
and an allocation count (`bench --allocs`), each change measured against
main in turns and its output compared byte for byte with main's (Arrow
stream and file, CSV, reject files, reports, describe and infer, on eleven
inputs). The machine was busy throughout (load about 14), so this says
how much faster, not how fast: `tools/bench_gate.sh` at 256 MiB, best of
three rounds in turns, main (5db619d) against the sweep:

| profile | stage1 | parse | validate | report | infer | csv | arrow | reference |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| narrow | +5% | +12% | +16% | +19% | +63% | +24% | +36% | +11% |
| wide | -2% | +8% | +13% | +11% | +19% | +15% | +8% | +2% |
| text | +2% | +2% | +7% | +2% | +2% | +4% | +3% | +2% |

stage1 and reference did not change: their numbers are the noise. What
did:

- **Dates in infer.** Every value of a date column was detected from
  scratch, then its layout spelled as strftime, which parses it again.
  A column now keeps the last reusable layout and its spelling, and a value
  of the same shape but for its digits is read with that layout alone.
  Debug builds detect each such value as well and assert they agree.
- **Numbers in infer.** Every value of every column went through the full
  decimal scan (with a division) to rule out a zero-padded number; the
  cheap test of its first two bytes comes first now.
- **Cells.** A cell was compared with every null string through a call to
  `mem.eql`; a bitmask of the nulls' lengths rules nearly all out. Integers
  of up to 18 digits and decimals of up to 18 digits are read without
  overflow checks or i128 arithmetic, which they cannot need.
- **Appends.** Each field (stage 2) and each typed cell (output) was an
  `ArrayList.append` call; `list.push` does the common case inline.
- **Output.** CSV copies a short field into its buffer as it checks it.
  Arrow output keeps no text for typed columns (only CSV writes it), and
  writes each message's buffers from where they are rather than copying
  them into one body: at 64 MB, wide Arrow output allocates 110 MB in all
  where it allocated 176, and the allocation count no longer grows with the
  file.
- **Small files.** A file under 64 KiB is read, not mapped: an unmap stops
  every core's work on the process's memory map. 3,000 2 KB files
  validate 10% faster with the default jobs, 3% with one.

Rows allocate nothing: `bench --allocs` gives every stage the same count
at 16 MB as at 64 MB, but for lists that grow to a batch's size once, and a
string column's bytes now and then.

Left as they are, each a choice rather than a fix:

- Releases are ReleaseSafe, and there `std.process.Init` hands the CLI
  `std.heap.SafeAllocator`, which checks every free. `c_allocator` instead
  was 0 to 3% faster on large files and 5 to 8% on thousands of small ones.
- Most of a small file's time is the sniffer, which scores about twenty
  dialects by parsing the sample with the reference parser. describe
  reports the runners-up's scores, so a cheaper sniffer has to keep them.
- `@setRuntimeSafety(false)` in the hot loops, as the shipped build's
  section below suggests, would give back some of ReleaseSafe's cost along
  with its checks.

## Column statistics

A report's statistics for each column (docs/REPORT.md, `columns[].stats`)
cost a validate more than the rest of a report does, so the CLI works them
out only with `--report`; a `validate` without one runs as it did. Every
value adds a few comparisons: its length, whether it is empty, and the
least and greatest of an ordered type. Distinct values, the most common
values and the most common shapes are counted over a sample of rows: every
row of a file of up to about 65,536, and rows spread evenly through a
larger one, at a stride worked out from the line breaks in its first 64
KiB. On a large file they cost little; a small one, sampled whole, takes
up to twice validate's time.

Measured on the machine above while it ran other work, best of three at
256 MB (commit of the change that added them): `report` against
`validate` is 9% slower on the narrow profile, 12% on the wide and the
same on the text. `infer` with them took 11% longer than before them on a
100 MB, six-column file (best of seven). The two stages are in the gate
from that change on.

## Shipped build

Releases are ReleaseSafe (`zig build --release`), the stages above
ReleaseFast. ReleaseSafe keeps Zig's runtime checks, so a broken
invariant on a file nobody vouches for is a panic where ReleaseFast would
run on undefined: an assertion in the sniffer, a bad cast, a slice out of
bounds. What the checks cost, end to end on one 210 MB synthetic CSV (six
columns: integers, a date, a decimal, two strings), one worker, best of
three, M5 Max, commit 68cab4d:

| command | ReleaseFast | ReleaseSafe | cost |
| --- | ---: | ---: | ---: |
| infer | 288 MB/s | 223 MB/s | 29% |
| validate | 456 MB/s | 364 MB/s | 25% |
| convert --to csv | 285 MB/s | 229 MB/s | 25% |
| convert --to arrow | 357 MB/s | 266 MB/s | 34% |

Where that matters, the place to win it back is `@setRuntimeSafety(false)`
in the few hot loops that are fuzzed and benchmarked (the scanner's index,
the column builders), measured before and after; the bench and the gate
stay ReleaseFast, since they compare runs rather than report what ships.

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

A pull request may not make any stage of any profile more than 10% slower,
but for the reference parser's, which is shown and not gated: it is the
tests' oracle, measured for scale, and nothing a user runs.
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

What it does not take out is where the code lands. On x86 a tight loop's
speed can move by half with the addresses of its branches against 32-byte
boundaries (Intel's JCC erratum fix makes this worse), so a change
elsewhere that shifts a hot function by 16 bytes can move a stage it never
touched. Pull request #6 did: `reference.Parser.next`, the same 1599
bytes in both builds, moved from offset 16 to offset 32 in its cache line,
and the text profile's reference stage ran at half speed on the CI runner,
the same in a second run, while the stages that changed ran up to 13%
faster. `next` is aligned to 64 bytes since. A stage that slows with no
change to its code is worth that check first: `nm -S` on the two
benchmark binaries, built for the runner's target, says whether its
functions only moved.

## Reproducing

```sh
zig build bench                                   # all profiles, 1 GB each
zig build bench -- --profile text --size 268435456 --runs 5
zig build bench -- --json                         # what the gate reads
zig build bench -- --profile narrow --stage infer # one stage, for a profiler
zig build bench -- --size 67108864 --allocs       # allocations a stage, not speed
zig build scale -Doptimize=ReleaseFast            # files in parallel
tools/bench_gate.sh origin/main                   # this tree against main
```

Run with the machine otherwise idle; a browser or a build next to it moves
these numbers by more than the gate's 10%.
