# libthresh: thresh from C

thresh as a C library: [`include/thresh.h`](../include/thresh.h) over the
same code the CLI runs. It sniffs a file's dialect, infers the schema its
values fit, checks its rows against a schema, and hands its rows and
rejected rows to pyarrow, polars, DuckDB or any other Arrow consumer in
the same process through Arrow's C Data Interface, without a copy or a
file between.

## Building and linking

`zig build` (Zig 0.17) installs, beside the `thresh` executable:

| | Linux, macOS | Windows |
| --- | --- | --- |
| header | `zig-out/include/thresh.h` | the same |
| shared | `zig-out/lib/libthresh.so`, `.dylib` | `zig-out/bin/libthresh.dll`, its import library `zig-out/lib/libthresh.lib` |
| static | `zig-out/lib/libthresh.a` | `zig-out/lib/libthresh_static.lib` |

Both link libc, and the static library carries the compiler runtime it
needs, so a C program links it with nothing else:

```sh
zig build --release
cc app.c -Izig-out/include zig-out/lib/libthresh.a -o app        # static
cc app.c -Izig-out/include -Lzig-out/lib -lthresh -o app         # shared
```

`test/c/smoke.c` is a C program through the header alone, run against
both libraries by `zig build test`.

## A call

```c
#include "thresh.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    thresh *t = thresh_new();
    thresh_options o;
    memset(&o, 0, sizeof o);
    o.size = sizeof o;
    char *schema = NULL, *report = NULL;
    if (thresh_columns(t, "lug_id:int64,lug_kg:decimal(5,2)", &schema) != THRESH_OK ||
        thresh_validate(t, "lugs.csv", schema, &o, &report) != THRESH_OK) {
        fprintf(stderr, "%s\n", thresh_error(t));
        return 1;
    }
    puts(report); /* the file report: "result", "problems", "columns", ... */
    thresh_string_free(report);
    thresh_string_free(schema);
    thresh_free(t);
    return 0;
}
```

## The calls

| Call | Gives |
| --- | --- |
| `thresh_sniff` | the file's [sniff line](REPORT.md#a-sniff-line-sniff---json) |
| `thresh_infer` | an [infer result](REPORT.md#an-infer-result-the-c-library): the schema its files fit, each file's outcome and notes |
| `thresh_columns` | the inline form (`"lug_id:int64,lug_kg:decimal(5,2)"`) as [schema](REPORT.md#the-schema) JSON |
| `thresh_validate` | the file's [report](REPORT.md#the-file-report) against a schema |
| `thresh_describe` | a [description](REPORT.md#a-description-describe): everything thresh can say of the file in one bounded document, against a schema or one inferred from the file |
| `thresh_read` | a reader: the accepted rows, and the rejected rows when asked, as Arrow C streams, then the report |

A schema is given as its JSON, as `infer` writes it; the inline form
becomes one with `thresh_columns`. Reports are JSON in the versioned
formats of [REPORT.md](REPORT.md), indented as the CLI writes them, with
every problem a [code](PROBLEMS.md) and its parameters.

## A status, or a report

A file's own trouble is its report, not a status: a file that is missing,
whose dialect is not settled, whose quotes look like data, or whose
values do not fit its schema gives `THRESH_OK` and a report that says so
(`result` `error` or `fail`, and its `problems`). `thresh_read` of such a
file gives no reader, and the report in `*json`.

A status other than `THRESH_OK` is for the call itself:

| Status | When |
| --- | --- |
| `THRESH_ERROR_ARGUMENT` | a NULL where a value is needed, an option out of range, options from a newer thresh that set what this one does not know, a stream taken twice |
| `THRESH_ERROR_SCHEMA` | the schema JSON (or inline form) was refused |
| `THRESH_ERROR_IO` | reading failed partway through |
| `THRESH_ERROR_MEMORY` | out of memory |
| `THRESH_ERROR_INTERRUPTED` | `thresh_options.cancel` was set |

`thresh_error(t)` says why, until the handle's next call: for example
`thresh_options.encoding is "ebcdic": utf8, latin1 or cp1252`, or `the
schema: line 1, column 12: ...`. A reader has `thresh_reader_error` for
its own calls, and a stream `get_last_error`, as Arrow has it.

No file, schema or option brings the host process down: whatever their
bytes, each call returns one of these statuses or a report. A panic is
left only for a broken invariant of thresh's own, which is a bug to
report. `src/capi_fuzz_test.zig` holds the calls to that under Zig's
fuzzer (`tools/fuzz.sh`), through this header, on any file bytes,
schema text and options.

## Options

`thresh_options` set to zero is every default: the sniffer settles the
dialect, and a call reads as the CLI does with no flags. Set `size` to
`sizeof(thresh_options)` and only the fields you mean; `NULL` for the
options is the defaults too. Each field is the CLI flag of the same name
(`thresh --help`): the dialect's pins (`delimiter`, `quote`, `escape`,
`newline`, `header`, `comment`), `encoding`, `sample_bytes`, `nulls`,
`ragged`, `flags` (`THRESH_STRICT`, `THRESH_DAY_FIRST`,
`THRESH_KEEP_EMPTY`, `THRESH_NO_MMAP`, `THRESH_THRESHOLD` to use
`threshold`, and `THRESH_SHAPES_ONLY` and `THRESH_SHAPE_NAMES`, which
write the file's values, and its column names, as shapes in every JSON a
call returns: [REPORT.md](REPORT.md#shapes-only); the Arrow streams'
rows are the data, as they are), and for `thresh_infer` `sample_rows` and
`jobs`.

`size` versions the struct. Fields are only ever added at its end, so a
program built against an older header passes a shorter struct, whose
missing fields read as zero, and one built against a newer header a
longer one, which an older library takes if the fields it does not know
are zero and refuses with `THRESH_ERROR_ARGUMENT` if any is set.

`cancel` points at a byte the caller sets to 1, from any thread, to stop
the call at its next batch (`THRESH_ERROR_INTERRUPTED`). A reader's
streams read it too, so it must outlive them.

## Ownership

Everything a call returns is the caller's, and nothing points into the
handle:

- A string (`char **json`): free it with `thresh_string_free`.
- A reader: free it with `thresh_reader_free`. It keeps its own copies of
  the path, the schema and the options, so they may go when `thresh_read`
  returns.
- A stream from `thresh_reader_rows` or `thresh_reader_rejects`: release
  it with its `release`. It keeps what it reads from alive, so it may be
  read and released after the reader is freed, and after the handle.
- A batch from a stream's `get_next`, and a schema from `get_schema`:
  release each with its own `release`. A batch is independent of its
  stream: it may outlive it, and a consumer may move a child array out
  of it, as the Arrow spec allows, and release that after its parent.

## Threads

A handle is used by one thread at a time; give each thread its own. A
reader and its streams likewise. `thresh_infer` reads its files on
threads of its own, `jobs` at once (0: one a CPU core), joined before it
returns. Anything returned may be freed or released on any thread.

The library reads with an I/O implementation that installs no signal
handler, so loading it into another program (Python, say) changes nothing
of that program's signals.

## Rows as Arrow

Each batch of `thresh_reader_rows` is a struct array, a field a schema
column, nullable as the column is:

| Schema type | Arrow type | Format |
| --- | --- | --- |
| `int64` | int64 | `l` |
| `float64` | float64 | `g` |
| `decimal` | decimal128(precision, scale) | `d:P,S` |
| `bool` | boolean | `b` |
| `date` | date32 (days) | `tdD` |
| `time` | time64 (microseconds) | `ttu` |
| `timestamp` | timestamp (microseconds, UTC) | `tsu:UTC` |
| `string` | utf8; binary under `utf8: binary` | `u`, `z` |
| `binary` | binary | `z` |
| `enum` | dictionary: int32 indices into a utf8 array of its values | `i` |

The types are those of `--to arrow`. `thresh_reader_rejects` gives the
rejected rows as [REPORT.md's "Reject files"](REPORT.md#reject-files)
describes them in Arrow.

A batch's values are handed over without a copy: int, float, decimal,
date and enum values and string bytes are moved from where the row was
parsed into the batch. Only null bitmaps, bool bitmaps and string offsets
are made for it.

A stream asked for and never taken still has its batches kept while the
reader or a stream of it lives, so ask `thresh_read` only for the
streams you will read (`THRESH_WANT_ROWS`, `THRESH_WANT_REJECTS`). When the full read finds a
file's quotes are data, after the sniff's sample looked fine, its rows
are not the file's: the streams end in an error, `get_last_error` says
why, and the report has the problem.

## Stability

`THRESH_` constants, the calls and `thresh_options`' fields are only
added to; the JSON documents follow [REPORT.md's
versions](REPORT.md#versions). thresh is not at 1.0 yet, so this holds
from the first release on.
