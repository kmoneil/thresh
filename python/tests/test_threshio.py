"""threshio over libthresh: each call, its results, its options and its
errors, and the Arrow streams read through the C stream interface itself
(so with no pyarrow installed), then through pyarrow, polars and DuckDB
where they are."""

import ctypes
import json
import os
import re
import tempfile
import threading
import unittest
from pathlib import Path

import threshio

DATA = Path(__file__).resolve().parents[2] / "examples" / "data"


def data(name):
    return str(DATA / name)


def importable(name):
    try:
        __import__(name)
        return True
    except ImportError:
        return False


# Arrow's C structs, enough to read a stream's batches' lengths.
class ArrowArray(ctypes.Structure):
    pass


ArrowArray._fields_ = [
    ("length", ctypes.c_int64),
    ("null_count", ctypes.c_int64),
    ("offset", ctypes.c_int64),
    ("n_buffers", ctypes.c_int64),
    ("n_children", ctypes.c_int64),
    ("buffers", ctypes.c_void_p),
    ("children", ctypes.c_void_p),
    ("dictionary", ctypes.c_void_p),
    ("release", ctypes.CFUNCTYPE(None, ctypes.POINTER(ArrowArray))),
    ("private_data", ctypes.c_void_p),
]


class ArrowStream(ctypes.Structure):
    pass


ArrowStream._fields_ = [
    ("get_schema", ctypes.c_void_p),
    ("get_next", ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(ArrowStream), ctypes.POINTER(ArrowArray))),
    ("get_last_error", ctypes.CFUNCTYPE(ctypes.c_char_p, ctypes.POINTER(ArrowStream))),
    ("release", ctypes.CFUNCTYPE(None, ctypes.POINTER(ArrowStream))),
    ("private_data", ctypes.c_void_p),
]

_get_pointer = ctypes.pythonapi.PyCapsule_GetPointer
_get_pointer.restype = ctypes.c_void_p
_get_pointer.argtypes = [ctypes.py_object, ctypes.c_char_p]
_get_name = ctypes.pythonapi.PyCapsule_GetName
_get_name.restype = ctypes.c_char_p
_get_name.argtypes = [ctypes.py_object]


def count_rows(source):
    """Rows in an object's Arrow stream, read batch by batch as a C
    consumer would, the stream released after."""
    capsule = source.__arrow_c_stream__()
    stream_p = ctypes.cast(_get_pointer(capsule, b"arrow_array_stream"), ctypes.POINTER(ArrowStream))
    stream = stream_p.contents
    rows = 0
    while True:
        batch = ArrowArray()
        if stream.get_next(stream_p, ctypes.byref(batch)) != 0:
            raise RuntimeError(stream.get_last_error(stream_p))
        if not batch.release:
            break
        rows += batch.length
        batch.release(ctypes.byref(batch))
    stream.release(stream_p)
    return rows


class Calls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = threshio.infer(data("harvest.csv")).schema

    def test_version(self):
        self.assertRegex(threshio.__version__, r"^\d+\.\d+\.\d+")

    def test_sniff(self):
        s = threshio.sniff(data("harvest.csv"))
        self.assertTrue(s.ok)
        d = s.dialect
        self.assertEqual((d.delimiter, d.quote, d.escape, d.newline, d.header, d.confidence), (",", '"', "doubled", "lf", True, "high"))
        self.assertIn("delimiter=, quote=\" escape=doubled", str(s))

    def test_a_missing_file_is_a_problem_not_an_exception(self):
        s = threshio.sniff(data("nope.csv"))
        self.assertFalse(s.ok)
        self.assertIsNone(s.dialect)
        self.assertEqual(s.problems[0].code, "no_such_file")
        r = threshio.validate(data("nope.csv"), self.schema)
        self.assertEqual(r.result, "error")

    def test_infer(self):
        i = threshio.infer(data("harvest.csv"))
        self.assertTrue(i.ok)
        self.assertEqual(i.schema.names, ["lug_id", "picked_on", "orchard_row", "lug_kg", "cultivar", "bruised", "remark"])
        self.assertEqual([c.type for c in i.schema.columns], ["int64", "date", "string", "decimal", "string", "bool", "string"])
        self.assertEqual(i.files[0].result, "pass")

    def test_infer_files_that_disagree(self):
        week = threshio.infer(data("monday.csv"), data("tuesday.csv"), jobs=1)
        self.assertFalse(week.ok)
        self.assertEqual([p.code for p in week.problems], ["files_columns"])
        self.assertIn("brix", week.schema.names)

    def test_columns(self):
        s = threshio.columns("lug_id:int64,lug_kg:decimal(5,2)")
        self.assertEqual(repr(s), "Schema(lug_id int64, lug_kg decimal)")
        self.assertEqual(s["lug_kg"].raw["precision"], 5)
        with self.assertRaises(threshio.SchemaError):
            threshio.columns("lug_id:integer")

    def test_validate(self):
        r = threshio.validate(data("harvest_dirty.csv"), self.schema)
        self.assertFalse(r.passed)
        self.assertEqual((r.result, r.rows, r.rows_rejected), ("fail", 30, 4))
        self.assertEqual([line.row for line in r.rejected_lines], [5, 9, 13, 22])
        self.assertEqual(r.rejected_lines[3].errors, [threshio.RowError(None, "ragged")])
        self.assertEqual(r.column("picked_on").samples, [threshio.Sample(9, "2026-09-31", "not_in_format")])
        self.assertEqual(r.row_errors, {"ragged": 1})
        stats = r.column("lug_id").stats
        self.assertEqual((stats.min, stats.max, stats.values), ("1", "30", 28))
        self.assertEqual(str(r), "fail  %s  30 rows  4 rejected" % data("harvest_dirty.csv"))

    def test_every_form_of_schema_reads_alike(self):
        want = threshio.validate(data("harvest_dirty.csv"), self.schema).rows_rejected
        text = self.schema.to_json()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "harvest.schema.json")
            self.schema.save(path)
            self.assertEqual(threshio.Schema.load(path), self.schema)
            for form in (self.schema.raw, text, path, Path(path)):
                self.assertEqual(threshio.validate(data("harvest_dirty.csv"), form).rows_rejected, want)
        inline = "lug_id:int64,picked_on:date,orchard_row:string,lug_kg:decimal(4,1),cultivar:string,bruised:bool,remark:string"
        self.assertEqual(threshio.validate(data("harvest_dirty.csv"), inline).rows_rejected, want)
        with self.assertRaises(TypeError):
            threshio.validate(data("harvest.csv"), 42)

    def test_with_column(self):
        strict = self.schema.with_column("lug_id", nullable=False)
        self.assertFalse(strict["lug_id"].nullable)
        self.assertTrue(self.schema["lug_id"].nullable)
        r = threshio.validate(data("harvest_dirty.csv"), strict)
        self.assertEqual(r.rows_rejected, 5)
        with self.assertRaises(KeyError):
            self.schema.with_column("brix", nullable=False)

    def test_check(self):
        r = threshio.check(data("harvest.csv"), self.schema)
        self.assertTrue(r.passed)
        with self.assertRaises(threshio.FileFailed) as caught:
            threshio.check(data("harvest_dirty.csv"), self.schema)
        self.assertEqual(caught.exception.report.rows_rejected, 4)
        self.assertEqual(caught.exception.result, "fail")

    def test_describe(self):
        d = threshio.describe(data("harvest.csv"))
        self.assertTrue(d.inferred)
        self.assertEqual(d.encoding, "utf8")
        self.assertEqual(d.schema.names, self.schema.names)
        self.assertTrue(all(c.stats is not None for c in d.columns))
        given = threshio.describe(data("harvest.csv"), self.schema)
        self.assertFalse(given.inferred)

    def test_shapes_only_holds_no_values(self):
        d = threshio.describe(data("harvest_dirty.csv"), shapes_only=True)
        text = d.to_json()
        self.assertNotIn("Marrowdew", text)
        self.assertNotIn("2026-09-31", text)
        self.assertEqual(d.rejected_lines[0].text, "9,a,9-9-9,a9,9.9,a a,a,a 9")
        named = threshio.describe(data("harvest.csv"), shape_names=True)
        self.assertNotIn("cultivar", named.to_json())

    def test_to_json_is_the_document(self):
        r = threshio.validate(data("harvest.csv"), self.schema)
        doc = json.loads(r.to_json())
        self.assertEqual(doc["format_version"], 1)
        self.assertEqual(doc, r.raw)

    def test_problem_fix(self):
        for name, fix in [
            ("windows.csv", {"encoding": "cp1252"}),
            ("bins.txt", {"quote": False}),
            ("header_short.csv", {"header": False}),
        ]:
            with self.subTest(name):
                first = threshio.infer(data(name))
                self.assertFalse(first.ok)
                problem = first.files[0].problems[0]
                self.assertEqual(problem.fix, fix)
                self.assertTrue(threshio.infer(data(name), **problem.fix).ok)

    def test_dialect_options_pin_the_same_reading(self):
        pins = threshio.sniff(data("harvest.csv")).dialect.options
        self.assertEqual(pins, {"delimiter": ",", "quote": '"', "escape": "doubled", "newline": "lf", "header": True})
        self.assertTrue(threshio.validate(data("harvest.csv"), self.schema, **pins).passed)

    def test_options(self):
        r = threshio.validate(data("remarks.csv"), "lug_id:int64,picked_on:date,remark:string,lug_kg:decimal(4,1)", delimiter=",")
        self.assertEqual(r.rows_rejected, 20)
        # Line 22's field too many is dropped, so it is rejected for the
        # values its fields moved into, not for its width.
        cut = threshio.validate(data("harvest_dirty.csv"), self.schema, ragged="truncate")
        self.assertEqual(cut.row_errors, {})
        self.assertEqual(cut.rejected_lines[3].errors[0], threshio.RowError("picked_on", "not_in_format"))
        loose = threshio.validate(data("harvest_dirty.csv"), self.schema, threshold=0.9)
        self.assertTrue(loose.passed)
        nulls = threshio.validate(data("harvest_dirty.csv"), self.schema, nulls=["", "maybe"])
        self.assertEqual(nulls.rows_rejected, 3)
        self.assertTrue(threshio.validate(data("harvest.csv"), self.schema, mmap=False, keep_empty=True, day_first=True).passed)
        self.assertEqual(threshio.infer(data("harvest.csv"), sample_rows=5, sample_bytes=1024).raw["schema"]["sampled"], True)
        self.assertTrue(threshio.infer(data("windows.csv"), encoding="latin1").ok)

    def test_options_refused(self):
        with self.assertRaises(TypeError):
            threshio.sniff(data("harvest.csv"), delimeter=",")
        for bad in (
            {"delimiter": ",;"},
            {"quote": True},
            {"escape": "quoted"},
            {"newline": "\n"},
            {"header": "yes"},
            {"encoding": "ebcdic"},
            {"nulls": "NA"},
            {"threshold": 2},
            {"jobs": -1},
            {"ragged": ["pad"]},
            {"cancel": True},
        ):
            with self.subTest(bad), self.assertRaises(ValueError):
                threshio.sniff(data("harvest.csv"), **bad)

    def test_cancel(self):
        c = threshio.Cancel()
        self.assertFalse(c.is_set())
        c.set()
        with self.assertRaises(threshio.Interrupted):
            threshio.validate(data("harvest.csv"), self.schema, cancel=c)

    def test_threads(self):
        results = []

        def work():
            results.append(threshio.validate(data("harvest_dirty.csv"), self.schema).rows_rejected)

        threads = [threading.Thread(target=work) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(results, [4] * 8)


class Streams(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = threshio.infer(data("harvest.csv")).schema

    def test_rows(self):
        self.assertEqual(count_rows(threshio.read(data("harvest.csv"), self.schema)), 40)

    def test_rows_rejects_and_report(self):
        reader = threshio.read(data("harvest_dirty.csv"), self.schema, rejects=True)
        self.assertEqual(count_rows(reader), 26)
        self.assertEqual(count_rows(reader.rejects), 4)
        self.assertEqual(reader.report().rows_rejected, 4)

    def test_report_first(self):
        reader = threshio.read(data("harvest_dirty.csv"), self.schema, rejects=True)
        self.assertEqual(reader.report().rows, 30)
        self.assertEqual(count_rows(reader.rejects), 4)
        self.assertEqual(count_rows(reader), 26)

    def test_without_a_schema_one_is_inferred(self):
        self.assertEqual(count_rows(threshio.read(data("harvest.csv"))), 40)

    def test_read_once(self):
        reader = threshio.read(data("harvest.csv"), self.schema)
        count_rows(reader)
        with self.assertRaises(threshio.ArgumentError):
            reader.__arrow_c_stream__()
        with self.assertRaises(threshio.ArgumentError):
            reader.rejects

    def test_schema_then_rows(self):
        reader = threshio.read(data("harvest.csv"), self.schema)
        self.assertEqual(_get_name(reader.__arrow_c_schema__()), b"arrow_schema")
        self.assertEqual(_get_name(reader.__arrow_c_schema__()), b"arrow_schema")
        self.assertEqual(count_rows(reader), 40)

    def test_a_stream_outlives_its_reader(self):
        with threshio.read(data("harvest.csv"), self.schema) as reader:
            capsule = reader.__arrow_c_stream__()
        self.assertIsNotNone(capsule)
        del capsule
        with self.assertRaises(threshio.ArgumentError):
            reader.report()

    def test_a_file_it_cannot_read(self):
        with self.assertRaises(threshio.FileFailed) as caught:
            threshio.read(data("nope.csv"), self.schema)
        self.assertEqual(caught.exception.report.result, "error")
        self.assertEqual(caught.exception.problems[0].code, "no_such_file")
        with self.assertRaises(threshio.FileFailed):
            threshio.read(data("nope.csv"))

    def test_a_stream_never_taken_is_released(self):
        for _ in range(50):
            reader = threshio.read(data("harvest_dirty.csv"), self.schema, rejects=True)
            reader.__arrow_c_schema__()
            reader.rejects.__arrow_c_schema__()
            reader.__arrow_c_stream__()
            del reader


@unittest.skipUnless(importable("pyarrow"), "pyarrow is not installed")
class Pyarrow(unittest.TestCase):
    def test_types(self):
        import pyarrow as pa

        schema = threshio.columns("lug_id:int64,picked_on:date,orchard_row:string,lug_kg:decimal(4,1),cultivar:string,bruised:bool,remark:string")
        table = pa.table(threshio.read(data("harvest.csv"), schema))
        self.assertEqual(table.num_rows, 40)
        types = [str(f.type) for f in table.schema]
        self.assertEqual(types, ["int64", "date32[day]", "string", "decimal128(4, 1)", "string", "bool", "string"])
        self.assertEqual(table.column("lug_id")[0].as_py(), 1)

    def test_rejects(self):
        import pyarrow as pa

        schema = threshio.infer(data("harvest.csv")).schema
        reader = threshio.read(data("harvest_dirty.csv"), schema, rejects=True)
        rejects = pa.table(reader.rejects)
        self.assertEqual(rejects.column_names[-3:], ["_row", "_errors", "_extra"])
        self.assertEqual(rejects.column("_row").to_pylist(), [5, 9, 13, 22])
        self.assertEqual(rejects.column("_extra").to_pylist()[3], "ladder 2")


@unittest.skipUnless(importable("polars"), "polars is not installed")
class Polars(unittest.TestCase):
    def test_frame(self):
        import polars as pl

        frame = pl.DataFrame(threshio.read(data("harvest.csv")))
        self.assertEqual(frame.shape, (40, 7))


@unittest.skipUnless(importable("duckdb"), "duckdb is not installed")
class DuckDB(unittest.TestCase):
    def test_query(self):
        import duckdb

        harvest = threshio.read(data("harvest.csv"))
        self.assertEqual(duckdb.sql("select count(*) from harvest").fetchall(), [(40,)])


if __name__ == "__main__":
    unittest.main()
