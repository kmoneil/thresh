# threshio

Know a delimited file before your code reads it.

A CSV, TSV or pipe-delimited export arrives from somewhere you do not
control. threshio says how it is written, what its columns hold, and
whether its rows fit the schema you expect, value by value, with a stable
code for everything that is wrong and the fix when there is one. Then it
hands the rows that fit, and the rows that do not, to pyarrow, polars or
DuckDB without a copy.

```sh
pip install threshio
```

No dependencies: the package carries libthresh, the C library of
[thresh](https://github.com/kmoneil/thresh), built for Linux (glibc and
musl), macOS and Windows on x86-64 and arm64. Python 3.9 and later.

The files below are an invented orchard's harvest, from the repository's
[`examples/data`](https://github.com/kmoneil/thresh/tree/main/examples/data).
Every block on this page is run by the package's tests, and its output
compared with what is shown.

## A first look

```python
import threshio

print(threshio.sniff("data/harvest.csv"))

schema = threshio.infer("data/harvest.csv").schema
print(schema)

report = threshio.validate("data/harvest.csv", schema)
print(report)
```

```text
data/harvest.csv: delimiter=, quote=" escape=doubled newline=lf header=yes confidence=high
Schema(lug_id int64, picked_on date, orchard_row string, lug_kg decimal, cultivar string, bruised bool, remark string)
pass  data/harvest.csv  40 rows  0 rejected
```

`sniff` reads the dialect and says how sure it is. `infer` reads every row
and gives the schema the values fit. `validate` checks a file against a
schema: yours, or one `infer` wrote. A schema is JSON (`schema.save(path)`,
`threshio.Schema.load(path)`), and every call that takes one also takes a
dict, JSON text, a `.json` path, or columns inline:
`"lug_id:int64,lug_kg:decimal(5,2)"`.

## A bad delivery

The same columns, with what goes wrong in a real feed:

```python
report = threshio.validate("data/harvest_dirty.csv", schema)
print(report)
for line in report.rejected_lines:
    print(line.row, line.errors)
print(report.column("lug_kg").samples)
```

```text
fail  data/harvest_dirty.csv  30 rows  4 rejected
5 [RowError(column='lug_kg', code='not_decimal')]
9 [RowError(column='picked_on', code='not_in_format')]
13 [RowError(column='bruised', code='not_bool')]
22 [RowError(column=None, code='ragged')]
[Sample(row=5, value='18,5', code='not_decimal')]
```

A file that fails is a report, not an exception: its `result` is `pass`,
`fail` or `error` (it could not be read, or its dialect is not settled),
and `problems` says why. Each column has its nulls, mismatches,
conformance and statistics (`report.column("lug_kg").stats`: min, max,
distinct values, the most common, their shapes).

Where code should not go on with a file that fails, `check` raises:

```python
strict = schema.with_column("lug_id", nullable=False)
try:
    threshio.check("data/harvest_dirty.csv", strict)
except threshio.FileFailed as e:
    print(e)
    print(e.report.rejected_sample)
```

```text
data/harvest_dirty.csv: fail: 5 of 30 rows rejected
[5, 9, 13, 17, 22]
```

## Into pyarrow, polars and DuckDB

`read` opens the file and is itself an Arrow stream (the PyCapsule
protocol), typed by the schema: decimals as decimal128, dates as date32,
bools as bool. Nothing is copied on the way.

```python
import pyarrow as pa

table = pa.table(threshio.read("data/harvest.csv", schema))
print(table.num_rows, table.schema.field("lug_kg").type)

reader = threshio.read("data/harvest_dirty.csv", schema, rejects=True)
good, bad = pa.table(reader), pa.table(reader.rejects)
print(good.num_rows, bad.num_rows, bad.column("_errors")[0])
print(reader.report())
```

```text
40 decimal128(18, 1)
26 4 [{'column': 'lug_kg', 'code': 'not_decimal'}]
fail  data/harvest_dirty.csv  30 rows  4 rejected
```

`polars.DataFrame(threshio.read(...))` takes it the same way, and in DuckDB
a Reader is a table:

```python
import duckdb

harvest = threshio.read("data/harvest.csv", schema)
print(duckdb.sql("select cultivar, count(*) from harvest group by 1 order by 2 desc, 1 limit 2").fetchall())
```

```text
[('Brookwood', 10), ('Ember Pip', 9)]
```

With no schema, `read` infers one from the file first. A Reader is read
once; `rejects=True` keeps the rows that did not fit, with `_row`,
`_errors` and `_extra`, for a stream of their own.

## When thresh knows the fix

A file thresh cannot read says why, with a code, and the fix when there is
one, as options to call again with:

```python
first = threshio.infer("data/windows.csv")
problem = first.files[0].problems[0]
print(problem.code, problem.fix)

again = threshio.infer("data/windows.csv", **problem.fix)
print(again.ok)
```

```text
column_not_utf8 {'encoding': 'cp1252'}
True
```

The `message` names the command line's flags; `fix` is this package's
options. Every code is listed in
[PROBLEMS.md](https://github.com/kmoneil/thresh/blob/main/docs/PROBLEMS.md).

## For an AI

`describe` is everything thresh can say of a file in one bounded
document. With `shapes_only=True` it holds none of the file's values
(digits become 9, letters a), so it can go to an AI, or into an issue:

```python
d = threshio.describe("data/harvest_dirty.csv", shapes_only=True)
print(d.rejected_lines[0].text)
print([(c.name, c.stats.shapes[0].value) for c in d.columns[:3]])
prompt = "Write a loader for this file.\n\n" + d.to_json()
```

```text
9,a,9-9-9,a9,9.9,a a,a,a 9
[('lug_id', '9'), ('picked_on', '9-9-9'), ('orchard_row', 'a9')]
```

## Options

Every call takes the same keyword options, each the command line's flag of
the same name; a call ignores those it has no use for. Left out (or
`None`), the sniffer settles the dialect and nothing else changes.

| Option | Value |
| --- | --- |
| `delimiter`, `comment` | one character, as `","` or `"\t"` |
| `quote` | one character, or `False` for none |
| `escape` | `"doubled"` or `"backslash"` |
| `newline` | `"lf"`, `"crlf"` or `"cr"` |
| `header` | `True` or `False` |
| `encoding` | `"utf8"`, `"latin1"` or `"cp1252"` (UTF-16 is told by its byte order mark) |
| `nulls` | a list of strings read as null in every column |
| `ragged` | `"pad"` or `"truncate"` a short or long row, rather than reject it |
| `threshold` | the fraction of a column's values (and of rows) that must fit |
| `strict` | extra columns, ragged rows and ambiguous dates fail the file |
| `day_first` | ambiguous dates read day first |
| `keep_empty` | an empty line is a one-field record |
| `sample_bytes` | the sniffer's first window |
| `sample_rows`, `jobs` | infer: the first rows only; files read at once |
| `shapes_only`, `shape_names` | values (and names) as shapes in what comes back |
| `mmap` | `False` reads through a buffer, not a mapping |
| `cancel` | a `threshio.Cancel`: `.set()` from another thread stops the call |

A sniffed dialect pins the next file the same way:
`threshio.validate(path, schema, **sniff.dialect.options)`.

## What comes back

| Call | Returns |
| --- | --- |
| `sniff(path)` | `Sniff`: `dialect`, `warnings`, `problems`, `ok` |
| `infer(*paths)` | `Inference`: `schema`, each file's outcome and notes, `problems`, `ok` |
| `columns(spec)` | `Schema` from the inline form |
| `validate(path, schema)` | `Report`: `result`, `rows`, `columns`, `rejected_lines`, `problems`, `passed` |
| `check(path, schema)` | the `Report`, or `FileFailed` with it |
| `describe(path, schema=None)` | `Description`: a `Report` with every column's statistics, the schema, the encoding |
| `read(path, schema=None, rejects=False)` | `Reader`: an Arrow stream of rows, `.rejects`, `.report()` |

Every result has `to_json()`, the document thresh wrote
([REPORT.md](https://github.com/kmoneil/thresh/blob/main/docs/REPORT.md)),
and `raw`, the same as a dict.

Exceptions are for the call, not the file: `ArgumentError` (a call made
wrongly), `SchemaError`, `ReadError` (reading failed partway),
`Interrupted` (a cancel), all `threshio.Error`; and `FileFailed` from
`check` and from `read` of a file it cannot read.

Calls release the GIL and use a handle of their own, so threads may call
at once; `infer` reads several files on threads of its own. A Reader is
used from one thread at a time.

## More

Whole scripts, each with its output:
[`examples/python`](https://github.com/kmoneil/thresh/tree/main/examples/python).
Apache-2.0.
