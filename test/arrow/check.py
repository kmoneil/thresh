#!/usr/bin/env python3
"""The Arrow writer against independent readers: pyarrow, and DuckDB when
it can read the files.

    uv run --with pyarrow --with duckdb --with pytz zig build arrow-check
    python3 test/arrow/check.py THRESH CORPUS_DIR      (with pyarrow installed)

For every clean corpus file, thresh writes Arrow (the stream format and,
with --arrow-file, the file format) and CSV with dates normalized to RFC
3339, twice: with `run` against the file's own schema (its enum column is
dictionary-encoded, its decimals have a set precision) and with `convert`
inferring one. pyarrow must read both Arrow forms to the same table, and
every value must be the one the CSV holds, read as the column's Arrow
type. DuckDB, when installed with its community arrow extension
(INSTALL arrow FROM community), must read both files itself, through
read_arrow, to the same values pyarrow does.
"""

import csv
import datetime
import decimal
import io
import json
import math
import os
import re
import subprocess
import sys
import tempfile

import pyarrow as pa
import pyarrow.ipc as ipc

try:
    import duckdb
except ImportError:
    duckdb = None

TRUE = {"true", "t", "yes", "1"}


def expected(text, typ):
    """The CSV text as a value of the Arrow type, as pyarrow gives it."""
    if text == "":
        return None
    t = text.strip(" \t")
    if pa.types.is_dictionary(typ):
        return text
    if pa.types.is_boolean(typ):
        return t.lower() in TRUE
    if pa.types.is_int64(typ):
        return int(t)
    if pa.types.is_decimal(typ):
        return decimal.Decimal(t).quantize(decimal.Decimal(1).scaleb(-typ.scale))
    if pa.types.is_float64(typ):
        return float(t)
    if pa.types.is_date32(typ):
        return datetime.date.fromisoformat(t)
    if pa.types.is_timestamp(typ):
        return datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
    if pa.types.is_time64(typ):
        return datetime.time.fromisoformat(t if t.count(":") == 2 else t + ":00")
    if pa.types.is_binary(typ):
        return text.encode()
    if pa.types.is_string(typ):
        return text
    raise AssertionError("no comparison for %s" % typ)


def same(a, b):
    if isinstance(a, float) and isinstance(b, float) and math.isnan(a) and math.isnan(b):
        return True
    return a == b


def run(thresh, args):
    p = subprocess.run([thresh] + args, capture_output=True, text=True)
    if p.returncode not in (0, 1):
        sys.exit("thresh %s: exit %d\n%s" % (" ".join(args), p.returncode, p.stderr))


def check(thresh, corpus, name, out, mode):
    stem = name[: name.rindex(".")]
    path = name if os.path.isabs(name) else os.path.join(corpus, name)
    corpus = os.path.dirname(path)
    stem = os.path.basename(stem)
    try:
        with open(os.path.join(corpus, stem + ".dialect.json")) as f:
            encoding = json.load(f)["encoding"]
    except FileNotFoundError:
        encoding = "utf8"
    common = [path, "--quiet", "--encoding", encoding]
    if mode == "run":
        common += ["--schema", os.path.join(corpus, stem + ".schema.json")]
    d = os.path.join(out, mode)
    run(thresh, [mode] + common + ["--to", "arrow", "--out", d])
    run(thresh, [mode] + common + ["--to", "arrow", "--arrow-file", "--out", d])
    run(thresh, [mode] + common + ["--to", "csv", "--normalize-dates", "--out", d])

    with open(os.path.join(d, stem + ".arrows"), "rb") as f:
        table = ipc.open_stream(f).read_all()
    with open(os.path.join(d, stem + ".arrow"), "rb") as f:
        from_file = ipc.open_file(f).read_all()
    if not table.equals(from_file):
        raise AssertionError("%s (%s): the stream and the file format differ" % (name, mode))
    with open(os.path.join(d, stem + ".csv"), newline="", encoding="utf-8") as f:
        rows = list(csv.reader(f))
    header, rows = rows[0], rows[1:]
    if table.column_names != header:
        raise AssertionError("%s (%s): columns %s, the CSV's %s" % (name, mode, table.column_names, header))
    if table.num_rows != len(rows):
        raise AssertionError("%s (%s): %d rows, the CSV %d" % (name, mode, table.num_rows, len(rows)))
    for i, field in enumerate(table.schema):
        got = table.column(i).to_pylist()
        for r, (g, row) in enumerate(zip(got, rows)):
            w = expected(row[i], field.type)
            if not same(g, w):
                raise AssertionError("%s (%s): row %d, %s (%s): Arrow %r, CSV %r" % (name, mode, r, field.name, field.type, g, w))
            # int() of "007" is 7, so the comparison above cannot see a
            # lost zero: an inferred integer must have had none to lose.
            if mode == "convert" and pa.types.is_int64(field.type) and re.fullmatch(r"[+-]?0\d+", row[i].strip(" \t")):
                raise AssertionError("%s (%s): row %d, %s: inferred int64 for %r, which Arrow holds as %r" % (name, mode, r, field.name, row[i], g))
    if DUCK is not None:
        for ext in (".arrows", ".arrow"):
            p = os.path.join(d, stem + ext)
            duck = DUCK.sql("SELECT * FROM read_arrow('%s')" % p.replace("'", "''")).to_arrow_table()
            if duck.column_names != table.column_names or duck.num_rows != table.num_rows:
                raise AssertionError("%s (%s): DuckDB reads %s as %d rows of %s" % (name, mode, ext, duck.num_rows, duck.column_names))
            for i in range(table.num_columns):
                for r, (g, w) in enumerate(zip(duck.column(i).to_pylist(), table.column(i).to_pylist())):
                    if not same(g, w):
                        raise AssertionError("%s (%s%s): row %d, %s: DuckDB %r, pyarrow %r" % (name, mode, ext, r, table.column_names[i], g, w))
    return [str(f.type) for f in table.schema]


def duck_connection():
    """A DuckDB connection with the arrow extension loaded, or None."""
    if duckdb is None:
        return None
    con = duckdb.connect()
    try:
        con.execute("LOAD arrow")
    except duckdb.Error:
        try:
            con.execute("INSTALL arrow FROM community")
            con.execute("LOAD arrow")
        except duckdb.Error as e:
            print("arrow-check: DuckDB without its arrow extension (%s): pyarrow only" % str(e).splitlines()[0], file=sys.stderr)
            return None
    return con


DUCK = None


def main():
    global DUCK
    thresh, corpus = sys.argv[1], sys.argv[2]
    csv.field_size_limit(1 << 30)
    DUCK = duck_connection()
    with open(os.path.join(corpus, "index.txt")) as f:
        names = f.read().split()
    seen = set()
    # Every type the corpus lacks: time, binary, an enum with nulls.
    types = os.path.join(os.path.dirname(os.path.abspath(__file__)), "types.csv")
    with tempfile.TemporaryDirectory() as out:
        seen.update(check(thresh, corpus, types, out, "run"))
        for name in names:
            for mode in ("run", "convert"):
                seen.update(check(thresh, corpus, name, out, mode))
    print(
        "arrow-check: %d files, both modes, stream and file format, pyarrow%s; types %s"
        % (len(names), " and DuckDB" if DUCK else "", ", ".join(sorted(seen))),
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
