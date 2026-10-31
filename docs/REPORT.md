# Reports: the JSON thresh writes

thresh writes six kinds of JSON document for programs to read:

| Document | Written by | Where |
| --- | --- | --- |
| [The file report](#the-file-report) | validate, convert, run with `--report DIR` | `DIR/<file>.report.json`, one per input |
| [summary.json](#summaryjson) | validate, convert, run with `--report DIR` | `DIR/summary.json`, one per run |
| [A file's line](#a-files-line---json) | validate, convert, run with `--json` | stdout, one line per input as it finishes |
| [A sniff line](#a-sniff-line-sniff---json) | sniff with `--json`; the C library's `thresh_sniff` | stdout, one line per input |
| [An infer result](#an-infer-result-the-c-library) | the C library's `thresh_infer` | returned, one per call |
| [The schema](#the-schema) | infer | stdout, or `--out FILE`; validate, convert and run read it with `--schema` |

Every code in them (a problem, a warning, why a value was rejected) is
listed in [PROBLEMS.md](PROBLEMS.md). The text thresh prints on stderr is
for people and is not part of the format.

## Versions

Each document starts with `format_version`, an integer. The four reports
share one number; the schema has its own, as a schema is also something
people write and thresh reads.

A reader can rely on this:

- **A field is never removed or renamed, and never changes type or
  meaning, within a version.** Any of those takes the version to the next
  number, and a row in [Changes](#changes) says what moved.
- **Fields are added without a new version.** A reader should ignore a
  field it does not know.
- **Codes are added without a new version.** A problem, warning or reason
  code a reader does not know should be treated as one more of its kind:
  a problem that stopped the file, a warning, a rejected value.
- **A field's listed values are closed.** `result`, `confidence`,
  `escape`, `newline`, `type`, `match`, `utf8` and `fits` take only the
  values given here; a new one takes the version to the next number.
- **Order and spacing are not part of the format.** Fields may come in
  another order; the report and summary.json are indented, the lines are
  not.

A field marked "when ..." below is left out, not written as `null`, when
that does not hold. A JSON integer may be as large as 2^64 - 1; a number
written as a fraction (`conformance`, `score`, `threshold`) has at most
eight places.

A schema without `format_version` is read as version 1, as a hand-written
one is. One with a version newer than the thresh reading it is refused,
naming both.

A test (`src/format_test.zig`) writes every document with every field it
can have and holds it to the tables below: a field thresh writes that has
no row fails it, as does a row for a field thresh no longer writes, or a
value of another type than its row says.

## Changes

| Document | Version | Date | What changed |
| --- | --- | --- | --- |
| reports | 1 | 2026-10-31 | The first versioned format. Against what thresh wrote before: `format_version` added; the report's `structural`, the outcome's `problem` and a sample's `reason`, sentences that `problems[].message` and `samples[].code` now carry, removed; a row rejected whole counts in `row_errors` and no longer as a mismatch in every column, and `conformance` is over the rows read into columns; the reject file gains `_extra`, and every line of it is as wide as its header |
| schema | 1 | 2026-10-31 | `format_version` added |

## The file report

One per input, `<file>.report.json` in the `--report` directory, written
as the file finishes. A file that could not be read has one too: its
`result` is `error` and its `problems` say why.

<!-- fields: report -->
| Field | Type | Meaning |
| --- | --- | --- |
| `format_version` | `integer` | 1 |
| `file` | `string` | the input's path, as it was given |
| `bytes` | `integer` | the file's size on disk |
| `rows` | `integer` | data rows read: not the header, nor a repeat of it |
| `result` | `string` | `pass`, `fail` (it fails its schema: a problem, a column whose `conformance` is below the threshold, or a smaller fraction of rows read whole than the threshold; exit 1) or `error` (it could not be read, or its dialect could not be settled or was wrong; exit 2) |
| `dialect` | `object` | when the file was sniffed: how it is written, and how sure thresh is |
| `dialect.delimiter` | `string` | the delimiter, one byte |
| `dialect.quote` | `string` or `null` | the quote character, or `null` for none |
| `dialect.escape` | `string` | how a quote is written inside a quoted field: `doubled` or `backslash` |
| `dialect.newline` | `string` | the line break records end in: `lf`, `crlf` or `cr` |
| `dialect.header` | `boolean` | row 1 is a header |
| `dialect.comment` | `string` | when `--comment` was given: the byte that starts a comment line |
| `dialect.confidence` | `string` | `high`, `medium` or `low`; low stops the file unless every dimension was pinned |
| `dialect.score` | `number` | the winning dialect's score, two places |
| `dialect.runners_up` | `array` | up to two dialects with other delimiters, best first |
| `dialect.runners_up[].delimiter` | `string` | its delimiter |
| `dialect.runners_up[].score` | `number` | its score, two places |
| `columns` | `array` | when the file was read against its schema: one per schema column, in the schema's order |
| `columns[].name` | `string` | the schema's name for it |
| `columns[].type` | `string` | its type: `bool`, `int64`, `float64`, `decimal`, `date`, `timestamp`, `time`, `string`, `enum` or `binary` |
| `columns[].nulls` | `integer` | values read as null |
| `columns[].mismatches` | `integer` | values that do not fit the column; a row rejected whole (`row_errors`) counts in no column |
| `columns[].conformance` | `number` | the fraction of the rows read into columns (all but those rejected whole) whose value fits, a null the column allows fitting: 1.0, or up to eight places |
| `columns[].format` | `string` | when the schema gives one: its strftime layout |
| `columns[].ambiguous` | `integer` | a date or timestamp column: values whose order of day, month and year is a guess |
| `columns[].fits` | `array` | when `ambiguous` is not 0: the orders every guessed value still fits |
| `columns[].fits[]` | `string` | `month_first`, `day_first` or `year_first` |
| `columns[].samples` | `array` | when any value does not fit: the first ten |
| `columns[].samples[].row` | `integer` | the source line the value's record starts on, from 1 |
| `columns[].samples[].value` | `string` | the value as read, its first 200 bytes, in UTF-8: transcoded from `--encoding`, and under UTF-8 a byte that is not part of a character is U+FFFD |
| `columns[].samples[].code` | `string` | why it does not fit: a [reason](PROBLEMS.md#reasons) |
| `problems` | `array` | what stopped or failed the file; empty when it passed |
| `problems[]` | `problem` | a [problem object](PROBLEMS.md#problems): `code`, `message`, its parameters, and `suggest` where there is a fix |
| `rows_rejected` | `integer` | when read against its schema: rows set aside, as the reject file has them |
| `rejected_sample` | `array` | when read against its schema: the source lines of the first ten |
| `rejected_sample[]` | `integer` | a source line, from 1 |
| `rejected_lines` | `array` | when read against its schema: the first twenty rejected rows, as the file has them, and why |
| `rejected_lines[].row` | `integer` | the source line the row starts on, from 1 |
| `rejected_lines[].text` | `string` | the row as written, delimiters and quotes and the line breaks inside its quotes too, without its own line break: its first 300 bytes, cut at a character, in UTF-8 as `samples[].value` is |
| `rejected_lines[].length` | `integer` | when `text` is cut: the row's whole length in bytes |
| `rejected_lines[].errors` | `array` | what was wrong, as the reject file's `_errors` says it |
| `rejected_lines[].errors[].column` | `string` | when the error is a value's: its schema column; an error of the whole row (a ragged one, say) has none |
| `rejected_lines[].errors[].code` | `string` | a [reason](PROBLEMS.md#reasons) |
| `limits` | `object` | when read against its schema: how much the lists above keep, so a list that is full says there may be more than it holds |
| `limits.samples` | `integer` | `columns[].samples`, a column: 10 |
| `limits.sample_bytes` | `integer` | of a sample's `value`: 200 |
| `limits.rejected_sample` | `integer` | 10 |
| `limits.rejected_lines` | `integer` | 20 |
| `limits.line_bytes` | `integer` | of a rejected line's `text`: 300 |
| `limits.repeated_header_rows` | `integer` | 10 |
| `row_errors` | `object` | when read against its schema: rejected rows by what was wrong with the whole row, a [reason](PROBLEMS.md#reasons) code to a count; empty when none |
| `row_errors{}` | `integer` | rows with that reason |
| `warnings` | `array` | what is unusual about the file and stopped nothing |
| `warnings[]` | `string` | a [warning](PROBLEMS.md#warnings) code |
| `repeated_header_rows` | `array` | when the header repeats: the source lines of the first ten repeats, which are skipped |
| `repeated_header_rows[]` | `integer` | a source line, from 1 |
| `timing_ms` | `object` | how long each stage took; differs from run to run |
| `timing_ms.sniff` | `integer` | sniffing, in milliseconds |
| `timing_ms.parse` | `integer` | reading, validating and building typed columns |
| `timing_ms.write` | `integer` | convert and run: writing the output; 0 for validate |
| `throughput_mb_s` | `integer` | megabytes read per second of parse and write |

## summary.json

One per run, in the `--report` directory, written when every file has
finished.

<!-- fields: summary -->
| Field | Type | Meaning |
| --- | --- | --- |
| `format_version` | `integer` | 1 |
| `files` | `integer` | the inputs |
| `passed` | `integer` | files whose result is `pass` |
| `failed` | `integer` | `fail` |
| `errors` | `integer` | `error` |
| `rows` | `integer` | data rows read, over every file |
| `rows_rejected` | `integer` | rows set aside, over every file |
| `exit` | `integer` | the run's exit status |
| `results` | `array` | each file's outcome, in the order the files were given |
| `results[].file` | `string` | the input's path, as it was given |
| `results[].result` | `string` | `pass`, `fail` or `error`, as the report's |
| `results[].rows` | `integer` | data rows read |
| `results[].rows_rejected` | `integer` | rows set aside |
| `results[].problems` | `array` | the file's first problem, or none |
| `results[].problems[]` | `problem` | a [problem object](PROBLEMS.md#problems) |
| `results[].written` | `string` | convert and run, when the file was written: the output's path, which may not be named as the input is when two inputs share a name |

## A file's line (`--json`)

One compact JSON object per input on stdout, as each finishes (so not in
the order given when `--jobs` is more than 1): the outcome that
summary.json's `results` holds, and its version.

<!-- fields: line -->
| Field | Type | Meaning |
| --- | --- | --- |
| `format_version` | `integer` | 1 |
| `file` | `string` | the input's path, as it was given |
| `result` | `string` | `pass`, `fail` or `error`, as the report's |
| `rows` | `integer` | data rows read |
| `rows_rejected` | `integer` | rows set aside |
| `problems` | `array` | the file's first problem, or none |
| `problems[]` | `problem` | a [problem object](PROBLEMS.md#problems) |
| `written` | `string` | convert and run, when the file was written: the output's path |

## A sniff line (`sniff --json`)

One compact JSON object per input on stdout. A file that cannot be read
has no line; stderr says why, and the exit is 2. A file whose dialect is
not settled, or whose sample's quotes look like data, has its line with
the problem in `problems`; stderr says so too, and the exit is 2. The C
library's `thresh_sniff` returns the same line, and one for a file it
cannot read too: no `dialect`, and the problem in `problems`.

<!-- fields: sniff -->
| Field | Type | Meaning |
| --- | --- | --- |
| `format_version` | `integer` | 1 |
| `file` | `string` | the input's path, as it was given |
| `dialect` | `object` | when the file could be read: as the report's `dialect` |
| `dialect.delimiter` | `string` | |
| `dialect.quote` | `string` or `null` | |
| `dialect.escape` | `string` | `doubled` or `backslash` |
| `dialect.newline` | `string` | `lf`, `crlf` or `cr` |
| `dialect.header` | `boolean` | |
| `dialect.comment` | `string` | when `--comment` was given |
| `dialect.confidence` | `string` | `high`, `medium` or `low` |
| `dialect.score` | `number` | |
| `dialect.runners_up` | `array` | |
| `dialect.runners_up[].delimiter` | `string` | |
| `dialect.runners_up[].score` | `number` | |
| `warnings` | `array` | what is unusual about the file |
| `warnings[]` | `string` | a [warning](PROBLEMS.md#warnings) code |
| `problems` | `array` | what stops the file at its sniff, `dialect_unsettled` or `quote_is_data`, or why it could not be read; empty when nothing does |
| `problems[]` | `problem` | a [problem object](PROBLEMS.md#problems) |

## An infer result (the C library)

What `thresh_infer` returns: the schema its files fit, as `infer` writes
it, and what it has to say about each file and about the run, which the
CLI prints on stderr.

<!-- fields: infer -->
| Field | Type | Meaning |
| --- | --- | --- |
| `format_version` | `integer` | 1 |
| `schema` | `schema` | when any file could be read: the schema, as [The schema](#the-schema) describes it |
| `files` | `array` | one per input, in the order given |
| `files[].file` | `string` | the input's path, as it was given |
| `files[].result` | `string` | `pass`, or `error`: it could not be read, or stopped at its sniff, and the schema leaves it out |
| `files[].problems` | `array` | why it is an error; empty when it is not |
| `files[].problems[]` | `problem` | a [problem object](PROBLEMS.md#problems) |
| `files[].notes` | `array` | what inference found in this file: a column a few values moved (`column_misfits`) or one the threshold kept (`column_tolerated`), a type widened by it (`column_widened`), a repeated header, wide rows |
| `files[].notes[]` | `problem` | a [problem object](PROBLEMS.md#problems) |
| `notes` | `array` | the run's: columns typed from too few values (`columns_thin`) |
| `notes[]` | `problem` | a [problem object](PROBLEMS.md#problems) |
| `problems` | `array` | `nothing_to_infer` when no file could be read, or how the files disagree, so the schema fails some of them (`files_columns`, `files_widths`, `files_mixed_headers`; the CLI's exit 1); empty when neither |
| `problems[]` | `problem` | a [problem object](PROBLEMS.md#problems) |

## The schema

What infer writes, and what `--schema` reads. A hand-written one has the
same shape; only `name` and `type` are needed for a column, and only
`columns` for the schema. A field the schema does not know is refused by
name, so a misspelt one is never ignored.

Infer writes a column's `precision` and `scale`, `format`, `nulls` and
`utf8` where it found them, and `conformance`, `samples`, `widened_by`
and `inferred` to say what it saw: those four are read back and never
checked.

<!-- fields: schema -->
| Field | Type | Meaning |
| --- | --- | --- |
| `format_version` | `integer` | 1; left out, read as 1 |
| `columns` | `array` | the columns |
| `columns[].name` | `string` | the column's name, as the header has it (ASCII case and surrounding spaces aside) |
| `columns[].type` | `string` | `bool`, `int64`, `float64`, `decimal`, `date`, `timestamp`, `time`, `string`, `enum` or `binary` |
| `columns[].nullable` | `boolean` | false: a null value is rejected. Written only when false |
| `columns[].nulls` | `array` | values read as null in this column, besides the schema's |
| `columns[].nulls[]` | `string` | a value read as null |
| `columns[].precision` | `integer` | decimal: digits in all, 1 to 38 (default 38) |
| `columns[].scale` | `integer` | decimal: digits after the point (default 0) |
| `columns[].format` | `string` | date, timestamp: a strftime layout; without one, each value's is detected |
| `columns[].day_first` | `boolean` | date, timestamp: an ambiguous value reads day first |
| `columns[].values` | `array` | enum: the values allowed |
| `columns[].values[]` | `string` | a value allowed |
| `columns[].case_insensitive` | `boolean` | enum: compare ignoring case |
| `columns[].max_len` | `integer` | string: the longest value, in bytes |
| `columns[].utf8` | `string` | string: what a value that is not UTF-8 is: `error` (a mismatch, the default), `replace` (valid, written with U+FFFD) or `binary` (valid, and the column is written as Arrow Binary) |
| `columns[].true_values` | `array` | bool: the spellings of true, case ignored (default `true`, `t`, `yes`, `1`) |
| `columns[].true_values[]` | `string` | a spelling of true |
| `columns[].false_values` | `array` | bool: the spellings of false (default `false`, `f`, `no`, `0`) |
| `columns[].false_values[]` | `string` | a spelling of false |
| `columns[].conformance` | `number` | infer: the fraction of values that fit the type (below 1 under `--threshold`) |
| `columns[].samples` | `array` | infer: a few of the values it read |
| `columns[].samples[]` | `string` | a value |
| `columns[].widened_by` | `string` | infer, from several files: the file that took the column to a lower type |
| `columns[].inferred` | `boolean` | infer: true |
| `nulls` | `array` | values read as null in every column (default `""`) |
| `nulls[]` | `string` | a value read as null |
| `match` | `string` | how the file's columns are found: `name` (by the header) or `position`; left out, by name when the file has a header |
| `threshold` | `number` | the fraction of a column's values that must fit, and of rows that must be read whole, for the file to pass (default 1.0); infer writes the `--threshold` it was given |
| `sampled` | `boolean` | infer, with `--sample-rows`: only the first rows were read |

## Reject files

Not JSON, but read by programs too, and versioned with the reports. With
`--reject DIR`, each file with a rejected row has `DIR/<file>.rejects.csv`:
RFC 4180 CSV (commas, double quotes, LF). Its header is a name for each
of the file's fields (the header's; for a file without one, the schema's
by position, then `column4` and so on past them), then `_row`, `_errors`
and `_extra`. Every line is as wide as the header: a rejected row's
fields as read, a short row's padded with empty fields, then:

- `_row`: the source line the row starts on, from 1.
- `_errors`: what was wrong, `column:reason` for each value, joined by
  `;`, the reason as its sentence in [PROBLEMS.md](PROBLEMS.md#reasons);
  a whole row's (a ragged one, say) is `*:reason`.
- `_extra`: a row wider than the header, its fields past it, joined by
  the file's own delimiter as one field; empty for any other row.

Through the library (`readArrow` in `src/lib.zig`), the same rows come as
an Arrow C stream, a struct array a batch: a nullable `utf8` for each
name of the header above, then `_row` (`int64`), `_errors` (a `list` of
`struct<column: utf8, code: utf8>`, `column` null for a whole row's
error, `code` the reason's code in PROBLEMS.md) and `_extra` (a nullable
`utf8`). Where the CSV pads, the stream has nulls: a short row's missing
fields, and `_extra` for a row no wider than the header. Every field is
UTF-8, transcoded from the file's encoding, with U+FFFD for a byte that
is not UTF-8.
