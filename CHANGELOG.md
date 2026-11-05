# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
A change to what a file reports, a new problem code aside, counts as
breaking even when no signature moves, because a caller acts on the codes
and fields. Before 1.0 a breaking change is a minor bump.

## [Unreleased]

### Added

- `thresh explain FILE...`: each file in plain words, for a reader who
  knows neither the file nor thresh. A line says what is wrong, or that
  the file is fine; under it, the rows set aside and why, what to notice
  (no header row, the header again, dates that read either way) and what
  the file is (how it is written, its columns by type, its dates as
  `MM/DD/YYYY`, a likely key, columns of one value or none, digit codes
  kept as text). It works from what `describe` finds. Each finding has a
  stable kind and a level, and `--json` (or `--out DIR`) gives them with
  the file's whole description (docs/REPORT.md, "An explanation"). A row
  set aside makes the file fail, exit 1, whatever `--threshold` allows.
- `thresh explain` reads a file that is not UTF-8 again, as Windows-1252,
  when every byte past ASCII is a character there and none is part of a
  UTF-8 one, and says what that read found under the stop: the bytes
  counted, the flag that reads it (`--encoding cp1252`), its rows and
  columns. A file part UTF-8, or with a byte neither encoding reads, is
  said to be so and not read again. The exit is still the stop's.
- `thresh explain` reads a file whose header is another width than its
  rows again with row 1 as data (`--header no`), the stop's own
  suggestion, and says what that read found: the header row set aside,
  the rest of the rows and the columns' types from them.

### Fixed

- infer, and describe with no schema, leave out every row of another
  width than the columns, as they left out rows wider than a header, and
  validate still rejects them. A short row's values typed the columns
  they landed in: a header read as a row (`--header no`) made its names'
  columns text, and a cut-off last line made a date column text. In a
  file with no header a wider row added columns, so the schema had more
  than the file and failed it whole ("the file has 7 columns, the schema
  12"); the columns are now the rows' width as sniffed. A new note,
  `rows_short`, says how many short rows were left out, and `rows_wider`
  now comes for a file with no header too; both name the column count.

## [0.4.0] - 2026-11-04

A file whose quotes all close on the line they open on is stopped too,
and a stopped file keeps nothing of what was read.

### Changed

- A file whose quotes are data is now stopped (`quote_is_data`) when
  every quote closes on the line it opens on, as a ditto mark and then
  an inch mark do (`"|24"`). Before, it took a quote that ran across
  lines, and such a file's rows came out a field short and were set
  aside as "a different number of fields": a loader's symptom, without
  the cause or the fix. The rows a quote ran together, across lines or
  on one, are now weighed against the rows that say the file really
  quotes (quoted text across lines, a row a quoted delimiter keeps
  whole) or is ragged anyway (a row short with no quote to blame).
- Breaking: such a file now ends in `error` where it ended in `fail`.
  And a file with quotes across lines that has more rows saying it
  quotes than rows run together is no longer stopped.

### Fixed

- A file stopped as `quote_is_data` after it is read no longer keeps a
  reject file of the rows the quote misread, nor counts them as
  rejected. As its output is not written, nothing of what was read is
  kept: its report has no columns and no rows set aside, as for a file
  stopped at its sniff.

## [0.3.0] - 2026-11-03

A file whose quotes are data is stopped with the line a loader would
fail on, and why.

### Changed

- When a file's quotes look like data (`quote_is_data`), thresh now says
  where a loader that reads quotes first goes wrong, and why: the line,
  the field and column the quote opens in, and what that line reads as
  ("so the line reads as 78 fields of 79"). It also counts the rows a
  quote shortens on their own line beside the records it runs across
  lines; before, it gave only the first record across lines, which can
  be thousands of lines past the one a loader's error names. The
  problem gains `narrowed`, `end_line`, `fields`, `width`, `field` and
  `column`; `sniff` names the field by place only.
- Breaking: `quote_is_data`'s `line` is the first line of either kind,
  so for a file whose quotes shorten a row before any runs across lines
  it is earlier than 0.2 gave.

## [0.2.1] - 2026-11-03

The `thresh` command, ready to download for every platform, and faster.

### Added

- The `thresh` command, ready to run, in every release: an archive for
  macOS (Apple silicon and Intel), Linux (x86-64 and arm64; static, so
  any distribution) and Windows (x86-64 and arm64), each with the
  license and a short README, in SHA256SUMS and attested with the
  wheels. Each is unpacked and run on its own platform before it is
  published. No Zig needed to use thresh any more.

### Changed

- Faster, with every output byte for byte the same. On files of a few
  narrow columns, `infer` reads 63% more a second, Arrow output 36%, CSV
  output 24%, `--report` 19%, `validate` 16% and parsing 12%; on wide
  files each is 8 to 19% faster. A folder of thousands of small files is
  10% faster, and Arrow output of a wide file allocates a third less
  memory. docs/PERF.md has the measurements.

## [0.2.0] - 2026-11-02

One command for everything thresh knows of a file and every row it set
aside, with no schema written first.

### Added

- `describe --reject DIR --report DIR`: the rejected rows, whole, with
  their lines and reasons; the file report, with each column's
  statistics; and `summary.json`, as `validate` writes them, from the same
  read as the description. Without `--schema`, describe reads the file
  against the schema it infers from it.
- `lib.describeWith` in the Zig library: describe, with each rejected row
  written as it is read. `lib.describe`, the C library and threshio are
  unchanged.

### Changed

- `sniff` and `infer` refuse `--reject` and `--report` (exit 3) rather than
  taking them and writing nothing.

### Fixed

- With `--report`, `summary.json` could give a file whose name is not
  UTF-8 a garbled name, read from memory the next file had reused.

## [0.1.0] - 2026-11-02

The first release, for threshio on PyPI.

### Added

- The `thresh` command: `sniff`, `infer`, `validate`, `convert`, `run` and
  `describe`, over files of any delimiter and quoting in UTF-8,
  Windows-1252, Latin-1 or UTF-16, with JSON reports in a versioned format
  (docs/REPORT.md), every problem a stable code (docs/PROBLEMS.md), the
  rejected rows with their reasons, and the good rows as CSV or Arrow.
  Built from this tag with Zig 0.17.0: `zig build --release`.
- libthresh, the C library (include/thresh.h, docs/C.md): every call, and
  the rows and rejects as Arrow C streams.
- threshio, the Python package over libthresh: `pip install threshio`.
  Every call with typed results, and a reader that is an Arrow stream for
  pyarrow, polars and DuckDB. Wheels for Linux (glibc 2.17 and later, and
  musl), macOS 13 and later, and Windows, on x86-64 and arm64, Python 3.9
  and later; each attached here with SHA256SUMS and build provenance.

[Unreleased]: https://github.com/kmoneil/thresh/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/kmoneil/thresh/releases/tag/v0.4.0
[0.3.0]: https://github.com/kmoneil/thresh/releases/tag/v0.3.0
[0.2.1]: https://github.com/kmoneil/thresh/releases/tag/v0.2.1
[0.2.0]: https://github.com/kmoneil/thresh/releases/tag/v0.2.0
[0.1.0]: https://github.com/kmoneil/thresh/releases/tag/v0.1.0
