# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
A change to what a file reports, a new problem code aside, counts as
breaking even when no signature moves, because a caller acts on the codes
and fields. Before 1.0 a breaking change is a minor bump.

## [Unreleased]

### Added

- The `thresh` command, ready to run, in every release: an archive for
  macOS (Apple silicon and Intel), Linux (x86-64 and arm64; static, so
  any distribution) and Windows (x86-64 and arm64), each with the
  license and a short README, in SHA256SUMS and attested with the
  wheels. Each is unpacked and run on its own platform before it is
  published. No Zig needed to use thresh any more.

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

[Unreleased]: https://github.com/kmoneil/thresh/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/kmoneil/thresh/releases/tag/v0.2.0
[0.1.0]: https://github.com/kmoneil/thresh/releases/tag/v0.1.0
