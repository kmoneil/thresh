# thresh

**Know what is in a delimited file before you load it.**

Other tools read files you already understand. thresh tells you whether
you do: what dialect a file is written in and how sure it is of that,
whether its header fits its rows, which values do not fit their columns
and why, and which rows to set aside, before anything reaches a database
or a dataframe. Then it writes the good rows as clean CSV or Arrow.

One static binary, written in Zig. Any delimiter, any quoting, UTF-8,
Windows-1252, Latin-1 or UTF-16.

## What it tells you

A delivery with a decimal comma, a day that does not exist, a yes/no
column saying "maybe" and one row a field too wide. A dataframe loader
typically stops at the wide row (or, told to, skips it without a word)
and reads the weight column as text because of one comma. thresh keeps
the good rows and says, for each bad one, its line and why:

```console
$ thresh infer data/harvest.csv --out harvest.schema.json
infer data/harvest.csv  40 rows  7 columns
$ thresh validate data/harvest_dirty.csv --schema harvest.schema.json --reject rejects --report reports
fail  data/harvest_dirty.csv  30 rows  4 rejected  1 MB/s
[exit 1]
$ cat rejects/harvest_dirty.csv.rejects.csv
lug_id,picked_on,orchard_row,lug_kg,cultivar,bruised,remark,_row,_errors
4,2026-09-05,R05,"18,5",Marrowdew,false,,5,lug_kg:not a decimal
8,2026-09-31,R09,19.2,Brookwood,false,,9,picked_on:not in the column's format
12,2026-09-13,R01,18.7,Marrowdew,maybe,,13,bruised:not a bool
21,extra,2026-09-22,R10,14.5,Ember Pip,false,ladder 2,22,*:a different number of fields
```

The report, one JSON file per input, has the rest: per column its nulls,
its mismatches, how much of it conforms, and samples of the bad values.

It will not guess where a file is ambiguous. A free-text column with
commas nobody quoted, a header a name short of its rows, deliveries of
one feed that no longer agree:

```console
$ thresh sniff data/remarks.csv
data/remarks.csv: delimiter=, quote=" escape=doubled newline=lf header=yes confidence=low
thresh: data/remarks.csv: the dialect is not settled (confidence low, score 0.57); pin it with --delimiter, --quote, --escape, --newline and --header
[exit 2]
$ thresh sniff data/header_short.csv
thresh: data/header_short.csv: row 1 is a header of 3 names over rows of 4 fields, and which names go with which columns cannot be told; fix the header, or pin --header no to read row 1 as data
[exit 2]
$ thresh infer data/monday.csv data/tuesday.csv --out week.schema.json --jobs 1
infer data/monday.csv  20 rows  4 columns
infer data/tuesday.csv  20 rows  5 columns
thresh: the files disagree: 1 of the schema's 5 columns is not in every file: 'brix' (1 of 2); validate fails a file without one
[exit 1]
```

Each says what is wrong and, where it can, what to do about it. Every
command and output on this page is run by `zig build test` against the
files in [examples/](examples), so it is what thresh prints today; the
[walkthrough](examples/README.md) has more shapes, from padded
fixed-length records to Windows exports and joined files.

## Commands

```
thresh sniff    <file>...                       dialect, confidence, header verdict
thresh infer    <file>... [--out schema.json]   type inference across files; writes a schema
thresh validate <file>... --schema s.json       report, and rejected rows with their reasons
thresh convert  <file>... --to csv|arrow        writes output; infers types if no --schema
thresh run      <file>... --schema s.json --to arrow --out dir/
```

Files run in parallel, one per worker (`--jobs`, default one per CPU).
Ctrl-C stops a run with no partial output file. `thresh --help` lists
every option.

**Reports.** `--report DIR` writes a JSON report per file and a
`summary.json`; `--json` prints one object per file; `--reject DIR`
writes each failing row with its source line (`_row`) and its errors
(`_errors`).

**Exit status.** 0 every file passed; 1 a file failed validation but
every file was processed (infer: the files disagree on their columns); 2
a file could not be read or its dialect could not be settled; 3 a usage
error.

**Arrow.** The stream format by default, the file format with
`--arrow-file`; it reads straight into pyarrow, polars or DuckDB. Until
thresh writes Parquet, DuckDB converts in one line: `duckdb -c "INSTALL
arrow FROM community; LOAD arrow; COPY (FROM read_arrow('x.arrows')) TO
'x.parquet'"`.

## Build

Zig 0.17.0.

```sh
zig build --release       # zig-out/bin/thresh, ReleaseSafe: what a release ships
zig build                 # Debug
zig build test            # unit tests, the corpus, the command and examples/
                          # (-Dcorpus=false skips the parts needing python3)
zig build fmt-check       # zig fmt --check
zig build vet             # zigvet, built from the pinned dependency
zig build corpus          # the fixture corpus, into zig-out/corpus (python3)
zig build bench           # MB/s per parsing stage, ReleaseFast (-- --size BYTES)
zig build scale -Doptimize=ReleaseFast  # 10,000 files, MB/s by --jobs, Ctrl-C
zig build fuzz            # replay the fuzz seeds; tools/fuzz.sh [LIMIT] fuzzes
zig build arrow-check     # Arrow output read back by pyarrow and DuckDB
```

## Speed

Fast enough not to be the bottleneck: a few hundred MB/s per file per
core in the shipped build, files in parallel across cores. Releases are
ReleaseSafe, keeping Zig's runtime checks (bounds, overflow, assertions),
because thresh reads files nobody vouches for and a broken invariant
should stop it rather than give a wrong answer; that costs a quarter to a
third of ReleaseFast's speed. [docs/PERF.md](docs/PERF.md) has the
numbers, stage by stage, and the regression gate.

## How it is tested

- A SIMD structural index checked against a scalar reference parser, on
  random inputs and under a fuzzer (`tools/fuzz.sh`).
- A fixture corpus written by `test/gen/corpus.py`: 165 files across
  delimiter, quote, newline, header, encoding and field profiles, an
  adversarial set, and a set in the shapes of real exports, each with its
  expected dialect, schema and field boundaries. It is regenerated by the
  build; `test/gen/MANIFEST` holds every file's SHA-256, so the build
  fails if it moves.
- The command itself, its output, files and exit status (`cli_checks` in
  `build.zig`), and this page and the examples, run as written.
- Tests in Debug and ReleaseSafe in CI, and a benchmark gate on every pull
  request.

Dates go through [dateparsa](https://github.com/kmoneil/dateparsa.zig), and
[zigvet](https://github.com/kmoneil/zigvet) checks the sources for code Zig
compiles that is almost certainly wrong.

## Status

Early, and tried on real feeds. Next: problems as codes as well as
sentences, a versioned report format, and then thresh as a C library and
a Python package that hands rows and rejects to pyarrow, polars or DuckDB
without a copy.

## License

Apache-2.0; see [LICENSE](LICENSE).
