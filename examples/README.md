# Examples

Small files from an invented orchard's harvest, each in one of the shapes
real feeds arrive in, and what thresh says about each. Every command and
every line of output below is run and compared by `zig build test`
(`tools/examples_check.py`), so this page is what thresh does today. The
files are made by `data/make.py`; every name and value in them is made up.

Run them from this directory with `thresh` on your PATH.

## A clean file

The baseline. `sniff` reads the dialect and says how sure it is; `infer`
reads every row and writes a schema; `validate` checks a file against it.

```console
$ thresh sniff data/harvest.csv
data/harvest.csv: delimiter=, quote=" escape=doubled newline=lf header=yes confidence=high
$ thresh infer data/harvest.csv --out harvest.schema.json
infer data/harvest.csv  40 rows  7 columns
$ grep -E '"(name|type|format)"' harvest.schema.json
      "name": "lug_id",
      "type": "int64",
      "name": "picked_on",
      "type": "date",
      "format": "%Y-%m-%d",
      "name": "orchard_row",
      "type": "string",
      "name": "lug_kg",
      "type": "decimal",
      "name": "cultivar",
      "type": "string",
      "name": "bruised",
      "type": "bool",
      "name": "remark",
      "type": "string",
  "match": "name"
$ thresh validate data/harvest.csv --schema harvest.schema.json
pass  data/harvest.csv  40 rows  0 rejected  2 MB/s
$ thresh convert data/harvest.csv --schema harvest.schema.json --to arrow --out out --json
{"format_version":1,"file":"data/harvest.csv","result":"pass","rows":40,"rows_rejected":0,"problems":[],"written":"out/harvest.arrows"}
```

The Arrow stream in `out/` reads straight into pyarrow, polars or DuckDB.

## What a bad delivery looks like

The same columns, with what goes wrong in a real feed: a decimal comma, a
day that does not exist, a yes/no column saying "maybe", a key left
empty, and a row with one field too many. `validate` keeps the good rows
apart from the bad and says, for each bad one, its line and why.

```console
$ thresh validate data/harvest_dirty.csv --schema harvest.schema.json --reject rejects --report reports
fail  data/harvest_dirty.csv  30 rows  4 rejected  1 MB/s
[exit 1]
$ cat rejects/harvest_dirty.csv.rejects.csv
lug_id,picked_on,orchard_row,lug_kg,cultivar,bruised,remark,_row,_errors,_extra
4,2026-09-05,R05,"18,5",Marrowdew,false,,5,lug_kg:not a decimal,
8,2026-09-31,R09,19.2,Brookwood,false,,9,picked_on:not in the column's format,
12,2026-09-13,R01,18.7,Marrowdew,maybe,,13,bruised:not a bool,
21,extra,2026-09-22,R10,14.5,Ember Pip,false,22,*:a different number of fields,ladder 2
```

The empty key passed: an inferred column takes nulls. Say it may not, and
it is caught too.

```console
$ sed 's/"name": "lug_id",/"name": "lug_id", "nullable": false,/' harvest.schema.json > strict.schema.json
$ thresh validate data/harvest_dirty.csv --schema strict.schema.json --reject rejects
fail  data/harvest_dirty.csv  30 rows  5 rejected  1 MB/s
[exit 1]
$ grep lug_id rejects/harvest_dirty.csv.rejects.csv
lug_id,picked_on,orchard_row,lug_kg,cultivar,bruised,remark,_row,_errors,_extra
,2026-09-17,R05,17.7,Marrowdew,false,,17,lug_id:null in a non-nullable column,
```

The report has the rest: per column, its nulls, its mismatches, how much
of it conforms, and a sample of the bad values with their rows and why;
then the rows rejected and the kinds of row error.
[docs/REPORT.md](../docs/REPORT.md) describes every field.

```console
$ cat reports/harvest_dirty.csv.report.json
{
  "format_version": 1,
  "file": "data/harvest_dirty.csv",
  "bytes": 1340,
  "rows": 30,
  "result": "fail",
  "dialect": {
    "delimiter": ",",
    "quote": "\"",
    "escape": "doubled",
    "newline": "lf",
    "header": true,
    "confidence": "medium",
    "score": 3.01,
    "runners_up": [
      {
        "delimiter": "\t",
        "score": 0.19
      },
      {
        "delimiter": "|",
        "score": 0.19
      }
    ]
  },
  "columns": [
    {
      "name": "lug_id",
      "type": "int64",
      "nulls": 1,
      "mismatches": 0,
      "conformance": 1.0
    },
    {
      "name": "picked_on",
      "type": "date",
      "nulls": 0,
      "mismatches": 1,
      "conformance": 0.96551724,
      "format": "%Y-%m-%d",
      "ambiguous": 0,
      "samples": [
        {
          "row": 9,
          "value": "2026-09-31",
          "code": "not_in_format"
        }
      ]
    },
    {
      "name": "orchard_row",
      "type": "string",
      "nulls": 0,
      "mismatches": 0,
      "conformance": 1.0
    },
    {
      "name": "lug_kg",
      "type": "decimal",
      "nulls": 0,
      "mismatches": 1,
      "conformance": 0.96551724,
      "samples": [
        {
          "row": 5,
          "value": "18,5",
          "code": "not_decimal"
        }
      ]
    },
    {
      "name": "cultivar",
      "type": "string",
      "nulls": 0,
      "mismatches": 0,
      "conformance": 1.0
    },
    {
      "name": "bruised",
      "type": "bool",
      "nulls": 0,
      "mismatches": 1,
      "conformance": 0.96551724,
      "samples": [
        {
          "row": 13,
          "value": "maybe",
          "code": "not_bool"
        }
      ]
    },
    {
      "name": "remark",
      "type": "string",
      "nulls": 16,
      "mismatches": 0,
      "conformance": 1.0
    }
  ],
  "problems": [],
  "rows_rejected": 4,
  "rejected_sample": [
    5,
    9,
    13,
    22
  ],
  "row_errors": {
    "ragged": 1
  },
  "warnings": [],
  "timing_ms": {
    "sniff": 0,
    "parse": 1,
    "write": 0
  },
  "throughput_mb_s": 1
}
```

## Commas nobody quoted

A free-text column holds commas that were never quoted, so its rows have
more fields than the header. Other tools pick some reading and carry on;
thresh will not guess.

```console
$ thresh sniff data/remarks.csv
data/remarks.csv: delimiter=, quote=" escape=doubled newline=lf header=yes confidence=low
thresh: data/remarks.csv: the dialect is not settled (confidence low, score 0.57); pin it with --delimiter, --quote, --escape, --newline and --header
[exit 2]
```

Told the delimiter, it reads the file and rejects the rows that do not
fit, saying why.

```console
$ thresh validate data/remarks.csv --delimiter , --columns "lug_id:int64,picked_on:date,remark:string,lug_kg:decimal(4,1)" --reject rejects
fail  data/remarks.csv  30 rows  20 rejected  1 MB/s
[exit 1]
$ head -3 rejects/remarks.csv.rejects.csv
lug_id,picked_on,remark,lug_kg,_row,_errors,_extra
2,2026-09-03,late pick, shade side,3,*:a different number of fields,16.9
3,2026-09-04,sunburn, windfall,4,*:a different number of fields," small,14.4"
```

## Inch marks in a file that never quotes

The bins are measured in inches, `36"`, and nothing in the file is
quoted. On row 12 the mark was typed before the number, `"36`, and a
value that starts with a quote reads as a quoted field: it runs on, over
delimiters and line breaks, to the next value that ends in one, and the
rows between fold into one as wide as a row. A loader would load it as
one row with a strange value in it, or stop at a later row it cannot
fit. thresh sees that each folded line is a whole row without the quotes
and stops.

```console
$ thresh infer data/bins.txt --out bins.schema.json
error data/bins.txt  the quotes look like data: 1 record holds 4 lines inside quotes, the first on line 13, and each of those lines is a whole row without them; pin --quote none to read quotes as data
thresh: no file to infer a schema from
[exit 2]
$ thresh infer data/bins.txt --out bins.schema.json --quote none
infer data/bins.txt  30 rows  4 columns
```

## A header one name short

The export added a column and not its name: 3 names over rows of 4
fields. Which column has no name cannot be told from the file, so thresh
says so instead of naming the wrong one.

```console
$ thresh sniff data/header_short.csv
thresh: data/header_short.csv: row 1 is a header of 3 names over rows of 4 fields, and which names go with which columns cannot be told; fix the header, or pin --header no to read row 1 as data
[exit 2]
$ thresh sniff data/header_short.csv --header no
data/header_short.csv: delimiter=| quote=" escape=doubled newline=lf header=no confidence=medium
```

## A column left unnamed

A blank name in the header is still a header. The column is named
`column3` by its place, the same by `infer` and by `validate`, so the
schema one writes the other reads.

```console
$ thresh infer data/unnamed.csv --out unnamed.schema.json
infer data/unnamed.csv  30 rows  4 columns
$ grep '"name"' unnamed.schema.json
      "name": "lug_id",
      "name": "picked_on",
      "name": "column3",
      "name": "lug_kg",
  "match": "name"
$ thresh validate data/unnamed.csv --schema unnamed.schema.json
pass  data/unnamed.csv  30 rows  0 rejected  1 MB/s
```

## Fixed-length records

Every value padded with spaces, every record padded to 80 bytes, pipes
between. The padding is not a delimiter, and padded numbers are numbers.

```console
$ thresh sniff data/padded.txt
data/padded.txt: delimiter=| quote=" escape=doubled newline=lf header=yes confidence=high
$ thresh infer data/padded.txt --out padded.schema.json
infer data/padded.txt  30 rows  4 columns
$ grep -E '"(name|type)"' padded.schema.json
      "name": "lug_id",
      "type": "int64",
      "name": "picked_on",
      "type": "date",
      "name": "lug_kg",
      "type": "decimal",
      "name": "cultivar",
      "type": "string",
  "match": "name"
```

## Two exports joined

Someone concatenated two exports, so the header comes again halfway down,
in capitals this time. It is skipped and said, not read as a row that
turns every column into text.

```console
$ thresh infer data/joined.csv --out joined.schema.json
infer data/joined.csv  40 rows  4 columns
thresh: data/joined.csv: the header repeats at row 22: files joined? It is skipped
$ grep '"type"' joined.schema.json
      "type": "int64",
      "type": "date",
      "type": "string",
      "type": "decimal",
```

## A Windows export

Windows-1252 bytes, not UTF-8. Read as UTF-8, an accented letter would
become a replacement character in every row it is in; thresh stops and
says which encoding to try.

```console
$ thresh infer data/windows.csv --out windows.schema.json
error data/windows.csv  column 'remark' is not UTF-8 (row 1); read the file with --encoding cp1252 (Windows) or latin1
thresh: no file to infer a schema from
[exit 2]
$ thresh infer data/windows.csv --out windows.schema.json --encoding cp1252
infer data/windows.csv  30 rows  3 columns
```

## UTF-16

Some exporters write UTF-16 with a byte order mark. It is read as such,
and said.

```console
$ thresh sniff data/utf16.csv
data/utf16.csv: delimiter=, quote=" escape=doubled newline=lf header=yes confidence=high warnings=utf16
```

## An empty extract

A header and nothing else, with no final newline. One line splits on
anything, and its names hold spaces; the pipes are the delimiter.

```console
$ thresh sniff data/empty_extract.txt
data/empty_extract.txt: delimiter=| quote=" escape=doubled newline=lf header=yes confidence=medium
```

## Deliveries that disagree

Monday's and Tuesday's files of one feed, and Tuesday's has a new column.
A schema from both would fail Monday's file, so `infer` says so, and
exits 1.

```console
$ thresh infer data/monday.csv data/tuesday.csv --out week.schema.json --jobs 1
infer data/monday.csv  20 rows  4 columns
infer data/tuesday.csv  20 rows  5 columns
thresh: the files disagree: 1 of the schema's 5 columns is not in every file: 'brix' (1 of 2); validate fails a file without one
[exit 1]
```
