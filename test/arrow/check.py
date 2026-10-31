#!/usr/bin/env python3
"""The Arrow writer against independent readers: pyarrow, and DuckDB when
it can read the files; and the library's Arrow C streams, imported by
pyarrow.

    uv run --with pyarrow --with duckdb --with pytz zig build arrow-check
    python3 test/arrow/check.py THRESH CORPUS_DIR LIBTHRESH    (with pyarrow installed)

For every clean corpus file, thresh writes Arrow (the stream format and,
with --arrow-file, the file format) and CSV with dates normalized to RFC
3339, twice: with `run` against the file's own schema (its enum column is
dictionary-encoded, its decimals have a set precision) and with `convert`
inferring one. pyarrow must read both Arrow forms to the same table, and
every value must be the one the CSV holds, read as the column's Arrow
type. DuckDB, when installed with its community arrow extension
(INSTALL arrow FROM community), must read both files itself, through
read_arrow, to the same values pyarrow does.

The same file read through libthresh's C ABI (include/thresh.h, loaded
with ctypes as a Python package would: thresh_infer for the inferred
schema, thresh_read for the streams) must give pyarrow, through the C
Data Interface, the table it read from the IPC stream, and a rejects
stream that holds what the reject file does, its codes the sentences of
PROBLEMS.md's reasons table.
"""

import csv
import ctypes
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


class ArrowArrayStream(ctypes.Structure):
    _fields_ = [(name, ctypes.c_void_p) for name in ("get_schema", "get_next", "get_last_error", "release", "private_data")]


class Options(ctypes.Structure):
    """thresh_options, as include/thresh.h lays it out."""

    _fields_ = [
        ("size", ctypes.c_size_t),
        ("flags", ctypes.c_uint32),
        ("quote", ctypes.c_int32),
        ("delimiter", ctypes.c_uint8),
        ("escape", ctypes.c_uint8),
        ("newline", ctypes.c_uint8),
        ("header", ctypes.c_uint8),
        ("comment", ctypes.c_uint8),
        ("ragged", ctypes.c_uint8),
        ("encoding", ctypes.c_char_p),
        ("nulls", ctypes.POINTER(ctypes.c_char_p)),
        ("nulls_len", ctypes.c_size_t),
        ("sample_bytes", ctypes.c_uint64),
        ("sample_rows", ctypes.c_uint64),
        ("threshold", ctypes.c_double),
        ("jobs", ctypes.c_uint32),
        ("cancel", ctypes.c_void_p),
    ]


LIB = None
HANDLE = None
WANT_ROWS, WANT_REJECTS = 1, 2


def load(path):
    global LIB, HANDLE
    LIB = ctypes.CDLL(path)
    p, s, i, u = ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_uint32
    out = ctypes.POINTER(ctypes.c_void_p)
    sigs = {
        "thresh_new": ([], p),
        "thresh_error": ([p], s),
        "thresh_string_free": ([p], None),
        "thresh_infer": ([p, ctypes.POINTER(s), ctypes.c_size_t, ctypes.POINTER(Options), out], i),
        "thresh_read": ([p, s, s, ctypes.POINTER(Options), u, out, out], i),
        "thresh_reader_rows": ([p, ctypes.POINTER(ArrowArrayStream)], i),
        "thresh_reader_rejects": ([p, ctypes.POINTER(ArrowArrayStream)], i),
        "thresh_reader_free": ([p], None),
    }
    for name, (args, res) in sigs.items():
        f = getattr(LIB, name)
        f.argtypes, f.restype = args, res
    HANDLE = LIB.thresh_new()


def taken(p):
    """A string libthresh returned, freed."""
    text = ctypes.string_at(p).decode()
    LIB.thresh_string_free(p)
    return text


def expect_ok(code, what):
    if code != 0:
        raise AssertionError("%s: status %d, %s" % (what, code, LIB.thresh_error(HANDLE).decode()))


def c_streams(path, schema_path, encoding):
    """The file read through libthresh: its rows and its rejected rows,
    each a table pyarrow imported from an Arrow C stream. With no schema,
    the one thresh_infer gives for the file alone, as convert infers."""
    o = Options(size=ctypes.sizeof(Options), encoding=encoding.encode())
    json_out = ctypes.c_void_p()
    if schema_path:
        with open(schema_path, "rb") as f:
            schema = f.read()
    else:
        paths = (ctypes.c_char_p * 1)(path.encode())
        expect_ok(LIB.thresh_infer(HANDLE, paths, 1, ctypes.byref(o), ctypes.byref(json_out)), path)
        schema = json.dumps(json.loads(taken(json_out))["schema"]).encode()
    reader = ctypes.c_void_p()
    expect_ok(LIB.thresh_read(HANDLE, path.encode(), schema, ctypes.byref(o), WANT_ROWS | WANT_REJECTS, ctypes.byref(reader), ctypes.byref(json_out)), path)
    if not reader:
        raise AssertionError("%s: stopped before it was read: %s" % (path, taken(json_out)))
    rows, rejects = ArrowArrayStream(), ArrowArrayStream()
    expect_ok(LIB.thresh_reader_rows(reader, ctypes.byref(rows)), path)
    expect_ok(LIB.thresh_reader_rejects(reader, ctypes.byref(rejects)), path)
    # The streams hold what they read from.
    LIB.thresh_reader_free(reader)
    tables = [pa.RecordBatchReader._import_from_c(ctypes.addressof(s)).read_all() for s in (rows, rejects)]
    # Imported: pyarrow holds them, and marked the structs released.
    if rows.release or rejects.release:
        raise AssertionError("%s: a stream pyarrow imported is not marked released" % path)
    return tables


def reasons():
    """Each reason's code to its sentence, from docs/PROBLEMS.md."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    with open(os.path.join(root, "docs", "PROBLEMS.md")) as f:
        text = f.read()
    table = text[text.index("## Reasons") :]
    out = dict(re.findall(r"^\| `(\w+)` \| (.+?)(?: \(a whole row\))? \|$", table, re.M))
    if "not_int" not in out or "ragged" not in out:
        raise AssertionError("no reasons table in PROBLEMS.md")
    return out


REASONS = None


def check_rejects(name, mode, table, reject_file):
    """The rejects stream against the reject file: the same rows, a short
    row's missing fields null where the file pads them, the errors as
    codes where it has sentences."""
    if not os.path.exists(reject_file):
        if table.num_rows:
            raise AssertionError("%s (%s): %d rejected rows streamed, no reject file" % (name, mode, table.num_rows))
        return
    with open(reject_file, newline="", encoding="utf-8") as f:
        lines = list(csv.reader(f))
    header, lines = lines[0], lines[1:]
    if table.column_names != header:
        raise AssertionError("%s (%s): rejects columns %s, the reject file's %s" % (name, mode, table.column_names, header))
    if table.num_rows != len(lines):
        raise AssertionError("%s (%s): %d rejected rows streamed, the reject file %d" % (name, mode, table.num_rows, len(lines)))
    width = len(header) - 3
    columns = [table.column(i).to_pylist() for i in range(table.num_columns)]
    for r, line in enumerate(lines):
        got = [c[r] for c in columns]
        fields = ["" if v is None else v for v in got[:width]]
        errors = ";".join("%s:%s" % (e["column"] or "*", REASONS[e["code"]]) for e in got[width + 1])
        streamed = fields + [str(got[width]), errors, got[width + 2] or ""]
        if streamed != line:
            raise AssertionError("%s (%s): rejected row %d streamed as %r, the reject file %r" % (name, mode, r, streamed, line))


def same(a, b):
    if isinstance(a, float) and isinstance(b, float) and math.isnan(a) and math.isnan(b):
        return True
    return a == b


def run(thresh, args):
    p = subprocess.run([thresh] + args, capture_output=True, text=True)
    if p.returncode not in (0, 1):
        sys.exit("thresh %s: exit %d\n%s" % (" ".join(args), p.returncode, p.stderr))


CODECS = {"utf8": "utf-8-sig", "latin1": "latin-1", "cp1252": "cp1252", "utf16": "utf-16"}


def source_rows(path, dialect):
    """The file's data records as Python's csv and codecs read them: the
    oracle for what thresh transcodes, independent of its tables."""
    kw = {"delimiter": dialect["delimiter"], "strict": False}
    if dialect["quote"] is None:
        kw.update(quoting=csv.QUOTE_NONE)
    elif dialect["escape"] == "backslash":
        kw.update(quotechar=dialect["quote"], doublequote=False, escapechar="\\")
    else:
        kw.update(quotechar=dialect["quote"], doublequote=True)
    with open(path, encoding=CODECS[dialect["encoding"]], newline="") as f:
        rows = [r for r in csv.reader(f, **kw) if r]
    if not dialect["header"]:
        return rows
    # The header again (joined files) is not data, and thresh skips it.
    names = [n.strip(" \t").lower() for n in rows[0]]
    return [r for r in rows[1:] if [v.strip(" \t").lower() for v in r] != names]


def check(thresh, corpus, name, out, mode):
    stem = name[: name.rindex(".")]
    path = name if os.path.isabs(name) else os.path.join(corpus, name)
    corpus = os.path.dirname(path)
    stem = os.path.basename(stem)
    try:
        with open(os.path.join(corpus, stem + ".dialect.json")) as f:
            dialect = json.load(f)
        encoding = dialect["encoding"]
    except FileNotFoundError:
        dialect, encoding = None, "utf8"
    # A UTF-16 file is told by its byte order mark, with no --encoding.
    common = [path, "--quiet", "--encoding", "utf8" if encoding == "utf16" else encoding]
    if mode == "run":
        common += ["--schema", os.path.join(corpus, stem + ".schema.json")]
    d = os.path.join(out, mode)
    run(thresh, [mode] + common + ["--to", "arrow", "--out", d])
    run(thresh, [mode] + common + ["--to", "arrow", "--arrow-file", "--out", d])
    run(thresh, [mode] + common + ["--to", "csv", "--normalize-dates", "--out", d, "--reject", d])

    with open(os.path.join(d, stem + ".arrows"), "rb") as f:
        table = ipc.open_stream(f).read_all()
    with open(os.path.join(d, stem + ".arrow"), "rb") as f:
        from_file = ipc.open_file(f).read_all()
    if not table.equals(from_file):
        raise AssertionError("%s (%s): the stream and the file format differ" % (name, mode))
    # The library's C streams: the IPC stream's table, which the rest of
    # this checks against the CSV, and the reject file's rows.
    streamed, rejected = c_streams(path, common[common.index("--schema") + 1] if mode == "run" else None, common[3])
    if not streamed.equals(table):
        raise AssertionError("%s (%s): the C stream's table differs from the IPC stream's:\n%s\n%s" % (name, mode, streamed.schema, table.schema))
    check_rejects(name, mode, rejected, os.path.join(d, os.path.basename(path) + ".rejects.csv"))
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
            # float() of a 48-digit key rounds it as Arrow does, so the two
            # agree: an inferred float64 must have had no such integer.
            digits = row[i].strip(" \t").lstrip("+-")
            if mode == "convert" and pa.types.is_float64(field.type) and digits.isdigit() and len(digits.lstrip("0")) > 15:
                raise AssertionError("%s (%s): row %d, %s: inferred float64 for %r, which Arrow holds as %r" % (name, mode, r, field.name, row[i], g))
    # Text as the source holds it, decoded by Python: a Latin-1 or
    # Windows-1252 byte thresh maps wrongly shows here, and nowhere above,
    # where Arrow and the CSV are both thresh's.
    if dialect is not None:
        source = source_rows(path, dialect)
        for i, field in enumerate(table.schema):
            if not pa.types.is_string(field.type):
                continue
            for r, (src, row) in enumerate(zip(source, rows)):
                if i < len(src) and src[i] != row[i]:
                    raise AssertionError("%s (%s): row %d, %s: the source reads %r, thresh wrote %r" % (name, mode, r, field.name, src[i][:60], row[i][:60]))
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
    global DUCK, REASONS
    thresh, corpus = sys.argv[1], sys.argv[2]
    load(sys.argv[3])
    REASONS = reasons()
    csv.field_size_limit(1 << 30)
    DUCK = duck_connection()
    with open(os.path.join(corpus, "index.txt")) as f:
        names = f.read().split()
    seen = set()
    here = os.path.dirname(os.path.abspath(__file__))
    with tempfile.TemporaryDirectory() as out:
        # Every type the corpus lacks: time, binary, an enum with nulls.
        seen.update(check(thresh, corpus, os.path.join(here, "types.csv"), out, "run"))
        # Rows rejected every way: a bad value, two in a row, a short row,
        # a wide one with a field over two lines, a value not in the enum.
        seen.update(check(thresh, corpus, os.path.join(here, "rejects.csv"), out, "run"))
        for name in names:
            for mode in ("run", "convert"):
                seen.update(check(thresh, corpus, name, out, mode))
    print(
        "arrow-check: %d files, both modes, stream and file format and libthresh's C streams, pyarrow%s; types %s"
        % (len(names), " and DuckDB" if DUCK else "", ", ".join(sorted(seen))),
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
