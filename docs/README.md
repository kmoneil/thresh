<sub>[thresh](../README.md) › Docs</sub>

# 📚 thresh docs

Everything thresh does, explained. Start with the walkthrough: it shows
thresh on every kind of file it meets, with what it prints. The
references below it are for when you need every field, code and call.

## 🚀 Start here

| | |
| --- | --- |
| **[thresh README](../README.md)** | What thresh is, what it catches, and how to get it. |
| **[🧺 Walkthrough](../examples/README.md)** | Small files in the shapes real feeds arrive in, and what thresh says about each, run by the tests. |
| **[📖 Glossary](#-glossary)** | The handful of data words these pages use, in plain English. |

## 🧾 Reference

| Page | In one line |
| --- | --- |
| [🧾 Reports](REPORT.md) | Every field of every JSON document thresh writes, and what may change between versions. |
| [🩺 Problems](PROBLEMS.md) | Every problem, warning and reason thresh can give, with its code and its fix. |
| [🧩 The C library](C.md) | libthresh: its calls, who owns what, threads, and rows handed over as Arrow. |
| [🏎️ Performance](PERF.md) | How fast each stage is, how that is measured, and the gate every change must pass. |

## 🐍 From Python

| Page | In one line |
| --- | --- |
| [🐍 threshio](../python/README.md) | The Python package: the same checks, and the rows into pyarrow, pandas or polars. |
| [📜 Example scripts](../examples/python) | Whole scripts on the walkthrough's files, each beside its output. |

## 📖 Glossary

New to data files? These are the words the docs lean on.

| Word | What it means |
| --- | --- |
| **CSV** | *Comma-separated values*: a plain text file with one row of a table on each line and commas between the values. **TSV** uses tabs, and many exports use pipes (`\|`). thresh reads them all. |
| **Row**, **line** | One record of the table: one order, one lug of apples. thresh counts lines as a text editor does, from 1, header included, so its line numbers find the row in any editor. |
| **Column**, **field** | One kind of value across every row: a date, a weight. A *field* is one value in one row. |
| **Header** | The first row, when it holds the columns' names rather than data. |
| **Delimiter** | The character between the values: a comma, a tab, a pipe or a semicolon. |
| **Quotes** | A value with the delimiter inside it is wrapped in quotes, `"18,5"`, so the comma is read as part of it. |
| **Dialect** | How a file is written: its delimiter, its quoting, its line endings and whether it has a header. `sniff` works it out. |
| **Encoding** | How the letters are stored as bytes. **UTF-8** is today's standard; Windows programs often write **Windows-1252**, older systems **Latin-1**, and some exporters **UTF-16**. Read with the wrong one, `café` comes out as `caf�`. |
| **Schema**, **rulebook** | What each column should hold: whole numbers, decimals, dates in a given format, yes or no, one of a few codes. `infer` writes one from a good file; `validate` checks a file against it. |
| **Set aside**, **reject** | A row that does not fit is set aside rather than loaded: written to a *rejects file*, whole, with its line number (`_row`), what is wrong (`_errors`) and any fields past the last column (`_extra`). |
| **Report** | A JSON file thresh writes about each file it reads: what each column holds, and every problem, with a code and a fix. |
| **JSON** | A text format for structured data that programs, and people at a pinch, read easily. |
| **Shape** | A value with its letters written `a` and its digits `9`: `Ember Pip` is `a a`, `2026-09-22` is `9-9-9`. `--shapes-only` writes shapes instead of values, so a report holds none of the data. |
| **Arrow** | A format for tables that pyarrow, pandas, polars and DuckDB read straight into memory, with no parsing. |
| **Exit status** | The number a command ends with, for scripts: 0 everything passed, 1 a file failed, 2 a file could not be read, 3 the command was mistyped. |
| **Terminal** | The window where you type commands: Terminal on a Mac, Windows Terminal or PowerShell on Windows. |
| **Path** | The list of folders your terminal looks in for a command, so you can type `thresh` rather than where it is. |
