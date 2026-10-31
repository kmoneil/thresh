# Problems, warnings and reasons

Everything thresh says about a file has a stable code, so a program can act
on it without reading English. The CLI prints each as a sentence; the JSON
carries the code, its parameters and, where there is one, the fix. A test
(`src/problems_doc_test.zig`) fails when a code is added without a line
here, or a line here names a code thresh does not have.

There are three lists:

- **Problems**: what stops a file or fails it, and what infer has to say
  about the files it read.
- **Warnings**: what is unusual about a file but stops nothing.
- **Reasons**: why one value, or one row, was rejected.

## Problems

A problem is an object:

```json
{
  "code": "header_width",
  "message": "row 1 is a header of 69 names over rows of 70 fields, ...",
  "header_fields": 69,
  "fields": 70,
  "suggest": { "header": "no" }
}
```

`code` and `message` are always there; the parameters are the code's own,
listed below; `suggest` is there only when thresh knows the fix. Its keys
are the options that make it, named as `thresh --help` names them:

| Key | Value |
| --- | --- |
| `header` | `"yes"` or `"no"`: pin `--header` to it |
| `encoding` | a list: read the file with `--encoding` set to any one of them |
| `threshold` | a number: `--threshold` set to it |
| `quote` | `"none"`: pin `--quote none`, so a quote character is data |

Where they appear ([REPORT.md](REPORT.md) has every field of each):

- A file's report (`--report DIR`): `problems`, every problem that
  stopped or failed the file.
- `summary.json`'s `results`, and each `--json` line: `problems`, the file's
  first problem (or none).
- Each `sniff --json` line: `problems`, what stops the file at its sniff
  (or none).
- stderr: the sentence.

### A file thresh cannot read

The file's result is `error` (exit 2).

| Code | Parameters | When |
| --- | --- | --- |
| `no_such_file` | | the path names nothing |
| `permission_denied` | | thresh may not read it |
| `is_directory` | | the path is a directory |
| `binary` | | a NUL byte in the first 8 KiB, and no UTF-16 byte order mark |
| `utf16_untranscoded` | | UTF-16 bytes reached the sniffer without being transcoded |
| `utf16_with_encoding` | | a UTF-16 file (it is transcoded as it is read) given an `--encoding`; suggests `encoding: ["utf8"]` |
| `unscorable` | | the pinned quote and escape leave no dialect to score |
| `out_of_memory` | | |
| `output_closed` | | what thresh writes to was closed, as a pipe is when its reader leaves |
| `io_error` | `error`: the system's name for it | any other failure to read or write |
| `interrupted` | | Ctrl-C while the file was being read |
| `not_reached` | | Ctrl-C before the run reached the file |
| `dialect_unsettled` | `score` | the sniffer is not sure enough of the dialect (confidence low) to read the file; pin it |
| `header_width` | `header_fields`, `fields` | row 1 is a header of another width than the rows, so which name goes with which column cannot be told; suggests `header: "no"` |
| `quote_is_data` | `records`, `lines`, `line`, the first | the file's quotes look like data, as in a file that never quotes and uses `"` for inches: values that start with one folded `lines` lines into `records` records, each line a whole row without the quotes, in a file with quotes inside unquoted fields too; what was read is not the file's rows, so nothing is written. Seen in the sniffer's sample, it stops the file there, sniff included, with the sample's counts; past the sample, when the whole file has been read. Never with `--quote` pinned; suggests `quote: "none"` |
| `column_not_utf8` | `column`, `row` | infer, reading as UTF-8, found a column that is not; suggests `encoding: ["cp1252", "latin1"]` |

### A file that fails its schema

The file's result is `fail` (exit 1).

| Code | Parameters | When |
| --- | --- | --- |
| `match_needs_header` | | the schema matches columns by name and the file has no header |
| `column_missing` | `column` | a schema column is not in the header |
| `column_extra` | `column` | a header column is not in the schema (`--strict`; otherwise the warning `extra_columns`) |
| `width_mismatch` | `columns`, `schema_columns` | matching by position, the file has fewer columns than the schema (or more, under `--strict`) |
| `cut_off_in_quote` | | the file ends inside a quoted field with no line break: cut off in a copy? |
| `cut_off` | `fields`, `width` | the last line has no line break and too few fields: cut off? |

`header_repeated` (`line`, the first; `count`) is a file's problem too when
it has no other: records that were the header again, skipped. The file
passes, and the warning of the same name says so as well.

### What infer says

infer prints these on stderr and goes on; only `files_*` make its exit 1.

| Code | Parameters | When |
| --- | --- | --- |
| `header_repeated` | `line`, `count` | records that were the header again, skipped: files joined? |
| `rows_wider` | `rows`, `line`, the first | rows wider than the header, left out: validate rejects them |
| `utf16_replaced` | `units` | UTF-16 code units that made no character, read as U+FFFD |
| `column_widened` | `column`, `from`, `to`, `file` | a later file took a column the earlier ones agreed on to a lower type |
| `column_tolerated` | `column`, `type`, `misfits`, `values`, `row`, the first | under `--threshold`, a column kept a type some of its values refuse; validate rejects those |
| `column_misfits` | `column`, `type`, `misfits`, `values`, `row`, `rest`, `threshold` | a few values hold a column at `type` where the rest are `rest`; suggests the `threshold` that infers `rest` |
| `columns_thin` | `columns` (the first five), `count`, `few_values` | typed columns read from fewer than `few_values` values: check them |
| `files_mixed_headers` | `headless`, `files`, `first` | some of the files have a header and some do not, so the schema matches by position |
| `files_widths` | `min`, `max` | headerless files of different widths |
| `files_columns` | `missing`, `columns`, `files`, `first`: up to three `{column, files}` | columns not in every file, which validate fails a file without |
| `nothing_to_infer` | | no file could be read |

`type`, `rest`, `from` and `to` are type names: `bool`, `int64`, `decimal`,
`float64`, `date`, `timestamp`, `string`, and for `from` and `to` also
`null`, a column with no values yet.

## Warnings

A report's `warnings` and `sniff`'s are lists of codes. None stops a file.

| Code | When |
| --- | --- |
| `utf8_bom` | the file starts with a UTF-8 byte order mark, which is skipped |
| `mixed_newlines` | records end in more than one kind of line break |
| `quote_in_unquoted` | a quote character inside an unquoted field, read as data |
| `not_utf8` | read as UTF-8, and the sniffer's sample is not: `--encoding cp1252` or `latin1` reads it |
| `utf16` | the file is UTF-16 and was transcoded as it was read |
| `utf16_invalid` | some of its code units made no character and are U+FFFD |
| `header_width` | row 1 is a header of another width than the rows (the problem of the same name) |
| `extra_columns` | the header has columns the schema does not; they are not read |
| `header_repeated` | records were the header again and were skipped: `repeated_header_rows` lists the first lines |

## Reasons

Why a value or a row was rejected. A report's column `samples` carry the
code as `code`; `row_errors` counts rows by code; a reject file's
`_errors` names the sentence, and the library's rejects stream the code.

| Code | Sentence |
| --- | --- |
| `null_value` | null in a non-nullable column |
| `not_bool` | not a bool |
| `not_int` | not an int64 |
| `int_overflow` | out of int64 range |
| `not_float` | not a float64 |
| `not_decimal` | not a decimal |
| `decimal_precision` | too many digits for the decimal's precision |
| `decimal_scale` | too many digits after the point for the decimal's scale |
| `not_time` | not a time |
| `not_in_enum` | not one of the enum's values |
| `too_long` | longer than max_len |
| `invalid_utf8` | not valid UTF-8 |
| `not_date` | not a date |
| `not_in_format` | not in the column's format |
| `relative_date` | a relative date, which needs a base time |
| `ambiguous_date` | an ambiguous date (--strict) |
| `ragged` | a different number of fields (a whole row) |
| `unterminated_quote` | a quote never closed (a whole row) |
| `bad_quote` | something after a closing quote (a whole row) |
| `field_too_long` | a field over 4 GiB (a whole row) |
