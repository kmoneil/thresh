"""Know a delimited file before your code reads it.

A CSV, TSV or pipe-delimited export arrives from somewhere you do not
control. threshio says how it is written (its dialect), what its columns
hold (a schema it infers), and whether its rows fit the schema you expect,
row by row and value by value, with a stable code for everything that is
wrong. Then it hands the rows that fit, and the rows that do not, to
pyarrow, polars or DuckDB without a copy.

    >>> import threshio
    >>> schema = threshio.infer("data/harvest.csv").schema
    >>> report = threshio.validate("data/harvest_dirty.csv", schema)
    >>> print(report)
    fail  data/harvest_dirty.csv  30 rows  4 rejected
    >>> import pyarrow
    >>> table = pyarrow.table(threshio.read("data/harvest.csv", schema))

A file's own trouble (it is missing, its dialect is not settled, a value
does not fit) is in what a call returns, not an exception. Exceptions are
for a call made wrongly, a schema refused, a read that failed partway, a
cancel, and the two calls whose point is to stop: check() and read().

These are bindings to libthresh, the C library of thresh
(https://github.com/kmoneil/thresh), which ships inside this package.
"""

from __future__ import annotations

import ctypes
import json
import os
import sys
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, Iterable, List, Mapping, NamedTuple, NoReturn, Optional, Tuple, Union

__all__ = [
    "ArgumentError",
    "Cancel",
    "ColumnReport",
    "Count",
    "Description",
    "Dialect",
    "Error",
    "FileFailed",
    "FileOutcome",
    "Inference",
    "Interrupted",
    "Problem",
    "ReadError",
    "Reader",
    "RejectedLine",
    "Report",
    "RowError",
    "Sample",
    "Schema",
    "SchemaColumn",
    "SchemaError",
    "Sniff",
    "Stats",
    "check",
    "columns",
    "describe",
    "infer",
    "read",
    "sniff",
    "validate",
]

PathLike = Union[str, "os.PathLike[str]"]
SchemaLike = Union["Schema", Mapping[str, Any], str, "os.PathLike[str]"]


# ---------------------------------------------------------------------------
# The library and its structs, as include/thresh.h declares them.


class _Options(ctypes.Structure):
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
        ("cancel", ctypes.POINTER(ctypes.c_uint8)),
    ]


class _ArrowSchema(ctypes.Structure):
    pass


_ArrowSchema._fields_ = [
    ("format", ctypes.c_void_p),
    ("name", ctypes.c_void_p),
    ("metadata", ctypes.c_void_p),
    ("flags", ctypes.c_int64),
    ("n_children", ctypes.c_int64),
    ("children", ctypes.c_void_p),
    ("dictionary", ctypes.c_void_p),
    ("release", ctypes.CFUNCTYPE(None, ctypes.POINTER(_ArrowSchema))),
    ("private_data", ctypes.c_void_p),
]


class _ArrowArrayStream(ctypes.Structure):
    pass


_StreamPtr = ctypes.POINTER(_ArrowArrayStream)
_ArrowArrayStream._fields_ = [
    ("get_schema", ctypes.CFUNCTYPE(ctypes.c_int, _StreamPtr, ctypes.POINTER(_ArrowSchema))),
    ("get_next", ctypes.c_void_p),
    ("get_last_error", ctypes.CFUNCTYPE(ctypes.c_char_p, _StreamPtr)),
    ("release", ctypes.CFUNCTYPE(None, _StreamPtr)),
    ("private_data", ctypes.c_void_p),
]


def _load() -> ctypes.CDLL:
    path = os.environ.get("THRESHIO_LIBRARY")
    if not path:
        name = {"win32": "libthresh.dll", "darwin": "libthresh.dylib"}.get(sys.platform, "libthresh.so")
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    lib = ctypes.CDLL(path)
    P = ctypes.POINTER
    h, s, out = ctypes.c_void_p, ctypes.c_char_p, P(ctypes.c_void_p)
    sigs = {
        "thresh_version": ([], ctypes.c_char_p),
        "thresh_new": ([], h),
        "thresh_free": ([h], None),
        "thresh_error": ([h], ctypes.c_char_p),
        "thresh_string_free": ([ctypes.c_void_p], None),
        "thresh_sniff": ([h, s, P(_Options), out], ctypes.c_int),
        "thresh_infer": ([h, P(ctypes.c_char_p), ctypes.c_size_t, P(_Options), out], ctypes.c_int),
        "thresh_columns": ([h, s, out], ctypes.c_int),
        "thresh_validate": ([h, s, s, P(_Options), out], ctypes.c_int),
        "thresh_describe": ([h, s, s, P(_Options), out], ctypes.c_int),
        "thresh_read": ([h, s, s, P(_Options), ctypes.c_uint32, out, out], ctypes.c_int),
        "thresh_reader_rows": ([h, ctypes.c_void_p], ctypes.c_int),
        "thresh_reader_rejects": ([h, ctypes.c_void_p], ctypes.c_int),
        "thresh_reader_report": ([h, out], ctypes.c_int),
        "thresh_reader_error": ([h], ctypes.c_char_p),
        "thresh_reader_free": ([h], None),
    }
    for fn_name, (args, res) in sigs.items():
        fn = getattr(lib, fn_name)
        fn.argtypes = args
        fn.restype = res
    return lib


_lib = _load()

#: The version of thresh inside this package, which is the package's own.
__version__: str = _lib.thresh_version().decode()


# ---------------------------------------------------------------------------
# Errors


class Error(Exception):
    """What threshio raises. A file's own trouble is a report instead,
    except from check() and read(), which raise FileFailed."""


class ArgumentError(Error, ValueError):
    """A call made wrongly: an option out of range, a stream taken twice."""


class SchemaError(Error, ValueError):
    """The schema was refused; the message says why."""


class ReadError(Error, OSError):
    """Reading failed partway through, or a file could not be read for a
    reason that is not the file's own."""


class Interrupted(Error):
    """The call's Cancel was set."""


class FileFailed(Error):
    """check() found the file does not pass, or read() could not read it.

    ``report`` is the file's Report when there is one; ``problems`` says
    why in either case.
    """

    def __init__(self, file: str, result: str, problems: List["Problem"], report: Optional["Report"] = None):
        self.file = file
        self.result = result
        self.problems = problems
        self.report = report
        if problems:
            why = problems[0].message
        elif report is not None:
            why = "%d of %d rows rejected" % (report.rows_rejected, report.rows)
        else:
            why = "no reason given"
        super().__init__("%s: %s: %s" % (file, result, why))


def _raise(status: int, message: Optional[bytes]) -> NoReturn:
    text = (message or b"").decode("utf-8", "replace")
    if status == 4:
        raise MemoryError(text or "thresh: out of memory")
    kind = {1: ArgumentError, 2: SchemaError, 3: ReadError, 5: Interrupted}.get(status, Error)
    raise kind(text or "thresh: status %d" % status)


# ---------------------------------------------------------------------------
# Options


class Cancel:
    """Stops a call from another thread: pass ``cancel=c`` to any call (or
    read()) and ``c.set()`` makes it raise Interrupted at its next batch.

        >>> c = threshio.Cancel()
        >>> threading.Timer(5.0, c.set).start()
        >>> threshio.validate("huge.csv", schema, cancel=c)
    """

    def __init__(self) -> None:
        self._byte = ctypes.c_uint8(0)

    def set(self) -> None:
        self._byte.value = 1

    def is_set(self) -> bool:
        return self._byte.value != 0


_ESCAPES = {"doubled": 1, "backslash": 2}
_NEWLINES = {"lf": 1, "crlf": 2, "cr": 3}
_RAGGED = {"pad": 1, "truncate": 2}
_ENCODINGS = ("utf8", "latin1", "cp1252")
_FLAGS = {"keep_empty": 1, "day_first": 2, "strict": 4, "shapes_only": 32, "shape_names": 64}
_NO_MMAP = 8
_THRESHOLD = 16
_OPTIONS = (
    "delimiter quote escape newline header comment encoding nulls ragged sample_bytes sample_rows "
    "threshold jobs keep_empty day_first strict mmap shapes_only shape_names cancel"
).split()


def _byte(name: str, value: Any) -> int:
    if isinstance(value, bytes) and len(value) == 1:
        return value[0]
    if isinstance(value, str) and len(value) == 1 and ord(value) < 256:
        return ord(value)
    raise ValueError("%s: one character (one byte), as ',' or '\\t'; not %r" % (name, value))


def _choice(name: str, value: Any, choices: Mapping[str, int]) -> int:
    if isinstance(value, str) and value in choices:
        return choices[value]
    raise ValueError("%s: one of %s; not %r" % (name, ", ".join(choices), value))


def _count(name: str, value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError("%s: a whole number, 0 or more; not %r" % (name, value))
    return value


def _flag(name: str, value: Any) -> bool:
    if not isinstance(value, bool):
        raise ValueError("%s: True or False; not %r" % (name, value))
    return value


class _Built:
    """A thresh_options and what its pointers point at, kept alive with it."""

    def __init__(self, options: Mapping[str, Any]):
        unknown = sorted(set(options) - set(_OPTIONS))
        if unknown:
            raise TypeError("unknown option %r; the options are %s" % (unknown[0], ", ".join(_OPTIONS)))
        self.struct = _Options()
        self.struct.size = ctypes.sizeof(_Options)
        self.keep: List[Any] = []
        for name, value in options.items():
            if value is not None:
                self._set(name, value)

    def _set(self, name: str, value: Any) -> None:
        o = self.struct
        if name in ("delimiter", "comment"):
            setattr(o, name, _byte(name, value))
        elif name == "quote":
            o.quote = -1 if value is False else _byte(name, value)
        elif name == "escape":
            o.escape = _choice(name, value, _ESCAPES)
        elif name == "newline":
            o.newline = _choice(name, value, _NEWLINES)
        elif name == "ragged":
            o.ragged = _choice(name, value, _RAGGED)
        elif name == "header":
            o.header = 1 if _flag(name, value) else 2
        elif name == "encoding":
            _choice(name, value, dict.fromkeys(_ENCODINGS, 0))
            o.encoding = self._kept(value.encode())
        elif name == "nulls":
            self._nulls(value)
        elif name in ("sample_bytes", "sample_rows", "jobs"):
            setattr(o, name, _count(name, value))
        elif name == "threshold":
            self._threshold(value)
        elif name == "mmap":
            if not _flag(name, value):
                o.flags |= _NO_MMAP
        elif name == "cancel":
            if not isinstance(value, Cancel):
                raise ValueError("cancel: a threshio.Cancel; not %r" % (value,))
            o.cancel = ctypes.pointer(self._kept(value)._byte)
        elif _flag(name, value):
            o.flags |= _FLAGS[name]

    def _kept(self, value: Any) -> Any:
        self.keep.append(value)
        return value

    def _nulls(self, value: Any) -> None:
        if isinstance(value, (str, bytes)) or not all(isinstance(v, str) for v in value):
            raise ValueError("nulls: a list of strings, as ['', 'NA']; not %r" % (value,))
        items = [v.encode() for v in value]
        array = (ctypes.c_char_p * len(items))(*items)
        self.struct.nulls = ctypes.cast(self._kept(array), ctypes.POINTER(ctypes.c_char_p))
        self.struct.nulls_len = len(items)
        self._kept(items)

    def _threshold(self, value: Any) -> None:
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 1:
            raise ValueError("threshold: a fraction from 0 to 1; not %r" % (value,))
        self.struct.threshold = float(value)
        self.struct.flags |= _THRESHOLD

    def pointer(self) -> Any:
        return ctypes.byref(self.struct)


# ---------------------------------------------------------------------------
# Calls


def _path(path: PathLike) -> bytes:
    return os.fsencode(os.fspath(path))


def _take(out: ctypes.c_void_p) -> Optional[str]:
    if not out.value:
        return None
    try:
        return ctypes.string_at(out.value).decode("utf-8")
    finally:
        _lib.thresh_string_free(out.value)


def _call(fn: Callable[..., int], *args: Any) -> str:
    """One call on a handle of its own (so any thread may make one), its
    returned string read and freed."""
    t = _lib.thresh_new()
    if not t:
        raise MemoryError("thresh: out of memory")
    try:
        out = ctypes.c_void_p()
        status = fn(t, *args, ctypes.byref(out))
        text = _take(out)
        if status != 0:
            _raise(status, _lib.thresh_error(t))
        return text or ""
    finally:
        _lib.thresh_free(t)


def _schema_json(schema: SchemaLike) -> bytes:
    if isinstance(schema, Schema):
        return schema.to_json().encode()
    if isinstance(schema, Mapping):
        return json.dumps(schema).encode()
    if isinstance(schema, str):
        if schema.lstrip().startswith("{"):
            return schema.encode()
        if not schema.endswith(".json"):
            return columns(schema).to_json().encode()
    if isinstance(schema, (str, os.PathLike)):
        with open(schema, "rb") as f:
            return f.read()
    raise TypeError("schema: a Schema, a dict, JSON text, a .json path, or columns as 'id:int64,kg:decimal(5,2)'; not %r" % (schema,))


def sniff(path: PathLike, **options: Any) -> Sniff:
    """How the file is written: its delimiter, quote, escape, line breaks,
    whether row 1 is a header, and how sure thresh is.

    A file that cannot be read, or whose dialect is not settled, gives a
    Sniff whose ``problems`` say why, not an exception.
    """
    o = _Built(options)
    return Sniff._of(json.loads(_call(_lib.thresh_sniff, _path(path), o.pointer())))


def infer(*paths: PathLike, **options: Any) -> Inference:
    """The schema the files' values fit, from reading every row (or the
    first ``sample_rows``), with what thresh found in each file. Several
    files are read at once (``jobs``, default one a CPU core) and the
    schema fits them all."""
    if not paths:
        raise TypeError("infer: give at least one path")
    o = _Built(options)
    encoded = [_path(p) for p in paths]
    array = (ctypes.c_char_p * len(encoded))(*encoded)
    return Inference._of(json.loads(_call(_lib.thresh_infer, array, len(encoded), o.pointer())))


def columns(spec: str) -> Schema:
    """A Schema from the inline form: ``"lug_id:int64,lug_kg:decimal(5,2)"``.
    Every column nullable, the nulls ``""``."""
    return Schema(json.loads(_call(_lib.thresh_columns, spec.encode())))


def validate(path: PathLike, schema: SchemaLike, **options: Any) -> Report:
    """The file read against the schema: every value checked, every row
    that does not fit set aside with why. ``report.passed`` says whether
    it passed; a file that fails, or cannot be read, is a Report too."""
    o = _Built(options)
    text = _call(_lib.thresh_validate, _path(path), _schema_json(schema), o.pointer())
    return Report._of(json.loads(text))


def check(path: PathLike, schema: SchemaLike, **options: Any) -> Report:
    """validate(), for code that should not go on with a file that fails:
    its Report when it passes, FileFailed (with the Report) when not."""
    report = validate(path, schema, **options)
    if not report.passed:
        raise FileFailed(report.file, report.result, report.problems, report)
    return report


def describe(path: PathLike, schema: Optional[SchemaLike] = None, **options: Any) -> Description:
    """Everything thresh can say of the file in one bounded document: read
    against the schema, or with none, against one inferred from it first.
    With ``shapes_only=True`` it holds none of the file's values (digits
    become 9, letters a), so it can go to an AI or into an issue."""
    o = _Built(options)
    text = _call(_lib.thresh_describe, _path(path), None if schema is None else _schema_json(schema), o.pointer())
    return Description._of(json.loads(text))


def read(path: PathLike, schema: Optional[SchemaLike] = None, *, rejects: bool = False, **options: Any) -> Reader:
    """The file opened to read its rows as Arrow: pass the Reader to
    ``pyarrow.table``, ``polars.DataFrame`` or anything that takes the
    Arrow PyCapsule stream protocol. With no schema, one is inferred from
    the file first. With ``rejects=True``, ``reader.rejects`` is the rows
    that did not fit, the same way.

    A file that cannot be read at all raises FileFailed, with its report.
    """
    if schema is None:
        inference = infer(path, **options)
        if inference.schema is None:
            outcome = inference.files[0]
            raise FileFailed(outcome.file, outcome.result, outcome.problems + inference.problems)
        schema = inference.schema
    o = _Built(options)
    t = _lib.thresh_new()
    if not t:
        raise MemoryError("thresh: out of memory")
    try:
        reader, out = ctypes.c_void_p(), ctypes.c_void_p()
        want = 1 | (2 if rejects else 0)
        status = _lib.thresh_read(t, _path(path), _schema_json(schema), o.pointer(), want, ctypes.byref(reader), ctypes.byref(out))
        text = _take(out)
        if status != 0:
            _raise(status, _lib.thresh_error(t))
    finally:
        _lib.thresh_free(t)
    if not reader.value:
        report = Report._of(json.loads(text or "{}"))
        raise FileFailed(report.file, report.result, report.problems, report)
    return Reader(reader.value, rejects, o)


# ---------------------------------------------------------------------------
# Arrow streams, handed out as PyCapsules


_capsule_new = ctypes.pythonapi.PyCapsule_New
_capsule_new.restype = ctypes.py_object
_capsule_new.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p]
_capsule_pointer = ctypes.PYFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p)(("PyCapsule_GetPointer", ctypes.pythonapi))
_raw_malloc = ctypes.pythonapi.PyMem_RawMalloc
_raw_malloc.restype = ctypes.c_void_p
_raw_malloc.argtypes = [ctypes.c_size_t]
_raw_free = ctypes.pythonapi.PyMem_RawFree
_raw_free.restype = None
_raw_free.argtypes = [ctypes.c_void_p]

# A capsule keeps a pointer to its name, so the names live as long as the
# module.
_STREAM = b"arrow_array_stream"
_SCHEMA = b"arrow_schema"


def _zeroed(size: int) -> int:
    ptr = _raw_malloc(size)
    if not ptr:
        raise MemoryError("out of memory for an Arrow struct")
    ctypes.memset(ptr, 0, size)
    return ptr


def _free_stream(ptr: int) -> None:
    # A consumer that took the stream moved it out and left release NULL;
    # one never taken is released here.
    stream = _ArrowArrayStream.from_address(ptr)
    if stream.release:
        stream.release(ctypes.cast(ptr, _StreamPtr))
    _raw_free(ptr)


def _free_schema(ptr: int) -> None:
    schema = _ArrowSchema.from_address(ptr)
    if schema.release:
        schema.release(ctypes.cast(ptr, ctypes.POINTER(_ArrowSchema)))
    _raw_free(ptr)


@ctypes.CFUNCTYPE(None, ctypes.c_void_p)
def _drop_stream_capsule(capsule: int) -> None:
    ptr = _capsule_pointer(capsule, _STREAM)
    if ptr:
        _free_stream(ptr)


@ctypes.CFUNCTYPE(None, ctypes.c_void_p)
def _drop_schema_capsule(capsule: int) -> None:
    ptr = _capsule_pointer(capsule, _SCHEMA)
    if ptr:
        _free_schema(ptr)


def _capsule(ptr: int, name: bytes, drop: Any, free: Callable[[int], None]) -> Any:
    try:
        return _capsule_new(ptr, name, ctypes.cast(drop, ctypes.c_void_p))
    except BaseException:
        free(ptr)
        raise


class _Stream:
    """One of a Reader's streams. It is taken from the reader when first
    asked for, so its schema can be read (``__arrow_c_schema__``, which
    DuckDB asks for before the rows) without using it up, and then handed
    out once."""

    def __init__(self, reader: "Reader", take: Callable[[int, int], int], what: str):
        self._reader = reader
        self._take = take
        self._what = what
        self._ptr: Optional[int] = None
        self._handed = False

    def __arrow_c_schema__(self) -> Any:
        ptr = self._held()
        stream = _ArrowArrayStream.from_address(ptr)
        schema = _zeroed(ctypes.sizeof(_ArrowSchema))
        status = stream.get_schema(ctypes.cast(ptr, _StreamPtr), ctypes.cast(schema, ctypes.POINTER(_ArrowSchema)))
        if status != 0:
            _raw_free(schema)
            message = stream.get_last_error(ctypes.cast(ptr, _StreamPtr)) or b""
            raise ReadError(message.decode("utf-8", "replace") or "the %s stream gave no schema" % self._what)
        return _capsule(schema, _SCHEMA, _drop_schema_capsule, _free_schema)

    def __arrow_c_stream__(self, requested_schema: Any = None) -> Any:
        """The stream. ``requested_schema`` is ignored: the schema decides."""
        ptr = self._held()
        self._ptr, self._handed = None, True
        return _capsule(ptr, _STREAM, _drop_stream_capsule, _free_stream)

    def _held(self) -> int:
        if self._handed:
            raise ArgumentError("the %s stream was taken already: a Reader is read once" % self._what)
        if self._ptr is None:
            reader = self._reader._live()
            ptr = _zeroed(ctypes.sizeof(_ArrowArrayStream))
            status = self._take(reader, ptr)
            if status != 0:
                _raw_free(ptr)
                _raise(status, _lib.thresh_reader_error(reader))
            self._ptr = ptr
        return self._ptr

    def _drop(self) -> None:
        if self._ptr is not None:
            _free_stream(self._ptr)
            self._ptr = None

    def __del__(self) -> None:
        if getattr(self, "_ptr", None) is not None:
            self._drop()


class Reader:
    """A file opened by read(). It is the rows' stream itself: pass it to
    ``pyarrow.table(reader)``, ``polars.DataFrame(reader)``, a DuckDB
    query, or anything that takes the Arrow PyCapsule protocol. A Reader is
    read once.

    Use a Reader from one thread at a time. A stream taken from it is
    independent of it: it may be read after the Reader is closed.
    """

    def __init__(self, ptr: int, rejects: bool, options: _Built):
        self._ptr: Optional[int] = ptr
        self._options = options  # its cancel byte must outlive the streams
        self._rows = _Stream(self, _lib.thresh_reader_rows, "rows")
        self._rejects = _Stream(self, _lib.thresh_reader_rejects, "rejects") if rejects else None

    def __arrow_c_schema__(self) -> Any:
        """The rows' schema: a struct, a field a schema column."""
        return self._rows.__arrow_c_schema__()

    def __arrow_c_stream__(self, requested_schema: Any = None) -> Any:
        """The accepted rows, a struct array a batch, a field a schema
        column. ``requested_schema`` is ignored: the schema decides."""
        return self._rows.__arrow_c_stream__()

    @property
    def rejects(self) -> _Stream:
        """The rejected rows, a stream of their own: the file's fields as
        text (null where a short row had none), then ``_row``, ``_errors``
        (a list of {column, code}) and ``_extra``. Only with
        ``read(..., rejects=True)``."""
        if self._rejects is None:
            raise ArgumentError("read(..., rejects=True) to read the rejected rows")
        return self._rejects

    def report(self) -> Report:
        """The file's Report. What the streams have not read yet is read
        first (and kept for them), so this can come before or after."""
        out = ctypes.c_void_p()
        status = _lib.thresh_reader_report(self._live(), ctypes.byref(out))
        text = _take(out)
        if status != 0:
            _raise(status, _lib.thresh_reader_error(self._ptr))
        return Report._of(json.loads(text or "{}"))

    def close(self) -> None:
        """Frees the reader, and a stream asked for its schema and never
        taken. Streams already taken stay readable."""
        for s in (self._rows, self._rejects):
            if s is not None:
                s._drop()
        if self._ptr:
            _lib.thresh_reader_free(self._ptr)
            self._ptr = None

    def __enter__(self) -> "Reader":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def __del__(self) -> None:
        if getattr(self, "_ptr", None):
            self.close()

    def _live(self) -> int:
        if not self._ptr:
            raise ArgumentError("the Reader is closed")
        return self._ptr


# ---------------------------------------------------------------------------
# What the calls return, from the JSON documents of docs/REPORT.md. Each
# keeps the whole document in ``raw``; a field a later thresh adds is
# there before it has an attribute.


class _Document:
    raw: Dict[str, Any]

    def to_json(self, indent: Optional[int] = 2) -> str:
        """The document as thresh wrote it (docs/REPORT.md), for code, a
        file, or an AI."""
        return json.dumps(self.raw, indent=indent, ensure_ascii=False)


def _problems(items: Optional[Iterable[Mapping[str, Any]]]) -> List["Problem"]:
    return [Problem._of(p) for p in items or ()]


@dataclass(frozen=True)
class Problem:
    """Something thresh has to say about a file, with a stable ``code``
    (docs/PROBLEMS.md), a sentence, the code's parameters, and the fix
    when thresh knows one."""

    code: str
    message: str
    params: Dict[str, Any] = field(default_factory=dict)
    suggest: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def _of(cls, d: Mapping[str, Any]) -> "Problem":
        params = {k: v for k, v in d.items() if k not in ("code", "message", "suggest")}
        return cls(d["code"], d["message"], params, dict(d.get("suggest") or {}))

    @property
    def fix(self) -> Dict[str, Any]:
        """thresh's suggested fix as this package's options: call again
        with them, ``threshio.validate(path, schema, **problem.fix)``.
        Empty when thresh knows no fix."""
        out: Dict[str, Any] = {}
        for key, value in self.suggest.items():
            if key == "header":
                out["header"] = value == "yes"
            elif key == "quote":
                out["quote"] = False if value == "none" else value
            elif key == "encoding" and isinstance(value, list):
                out["encoding"] = value[0]
            else:
                out[key] = value
        return out

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True)
class Dialect:
    """How a file is written, and how sure thresh is (``confidence`` is
    high, medium or low)."""

    delimiter: str
    quote: Optional[str]
    escape: str
    newline: str
    header: bool
    confidence: str
    score: float
    comment: Optional[str] = None
    runners_up: Tuple[Tuple[str, float], ...] = ()

    @classmethod
    def _of(cls, d: Optional[Mapping[str, Any]]) -> Optional["Dialect"]:
        if d is None:
            return None
        runners = tuple((r["delimiter"], r["score"]) for r in d.get("runners_up", ()))
        return cls(d["delimiter"], d["quote"], d["escape"], d["newline"], d["header"], d["confidence"], d["score"], d.get("comment"), runners)

    @property
    def options(self) -> Dict[str, Any]:
        """This dialect as options, to pin it for this file or the next
        like it: ``threshio.validate(path, schema, **dialect.options)``."""
        o: Dict[str, Any] = {
            "delimiter": self.delimiter,
            "quote": False if self.quote is None else self.quote,
            "escape": self.escape,
            "newline": self.newline,
            "header": self.header,
        }
        if self.comment is not None:
            o["comment"] = self.comment
        return o

    def __str__(self) -> str:
        quote = "none" if self.quote is None else self.quote
        return "delimiter=%s quote=%s escape=%s newline=%s header=%s confidence=%s" % (
            _shown(self.delimiter),
            quote,
            self.escape,
            self.newline,
            "yes" if self.header else "no",
            self.confidence,
        )


def _shown(c: str) -> str:
    return {"\t": "\\t", " ": "space"}.get(c, c)


@dataclass
class Sniff(_Document):
    """What sniff() found: the dialect, what is unusual, and what stops
    the file (``problems``; empty when nothing does)."""

    file: str
    dialect: Optional[Dialect]
    warnings: List[str]
    problems: List[Problem]
    raw: Dict[str, Any] = field(repr=False)

    @classmethod
    def _of(cls, d: Dict[str, Any]) -> "Sniff":
        return cls(d["file"], Dialect._of(d.get("dialect")), list(d.get("warnings", ())), _problems(d.get("problems")), d)

    @property
    def ok(self) -> bool:
        """The dialect is settled and nothing stops the file."""
        return self.dialect is not None and not self.problems

    def __str__(self) -> str:
        if self.dialect is None or self.problems:
            return "%s: %s" % (self.file, self.problems[0].message if self.problems else "no dialect")
        return "%s: %s" % (self.file, self.dialect)


@dataclass(frozen=True)
class SchemaColumn:
    """One column of a Schema: ``raw`` has every field it was given."""

    name: str
    type: str
    nullable: bool
    raw: Dict[str, Any] = field(repr=False, compare=False)

    def __str__(self) -> str:
        return "%s %s%s" % (self.name, self.type, "" if self.nullable else " not null")


class Schema(_Document):
    """The columns a file should have, their types, nulls and formats, as
    docs/REPORT.md's schema: what infer() writes, columns() builds, and
    validate(), check(), describe() and read() take. A dict, JSON text or
    a ``.json`` path is taken wherever a Schema is."""

    def __init__(self, data: Mapping[str, Any]):
        self.raw: Dict[str, Any] = json.loads(json.dumps(data))
        if not isinstance(self.raw.get("columns"), list):
            raise SchemaError("a schema has a list of columns")

    @classmethod
    def load(cls, path: PathLike) -> "Schema":
        """A schema from a JSON file, as infer --out writes one."""
        with open(path, "rb") as f:
            return cls(json.loads(f.read().decode("utf-8")))

    @classmethod
    def from_json(cls, text: str) -> "Schema":
        return cls(json.loads(text))

    def save(self, path: PathLike) -> None:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(self.to_json() + "\n")

    @property
    def columns(self) -> List[SchemaColumn]:
        return [SchemaColumn(c["name"], c["type"], c.get("nullable", True), c) for c in self.raw["columns"]]

    @property
    def names(self) -> List[str]:
        return [c["name"] for c in self.raw["columns"]]

    def __getitem__(self, name: str) -> SchemaColumn:
        for c in self.columns:
            if c.name == name:
                return c
        raise KeyError(name)

    def with_column(self, name: str, **fields: Any) -> "Schema":
        """A copy with one column's fields set, as the schema's JSON names
        them: ``schema.with_column("lug_id", nullable=False)``."""
        data = json.loads(json.dumps(self.raw))
        for c in data["columns"]:
            if c["name"] == name:
                c.update(fields)
                return Schema(data)
        raise KeyError(name)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Schema) and self.raw == other.raw

    def __repr__(self) -> str:
        return "Schema(%s)" % ", ".join(str(c) for c in self.columns)


class Count(NamedTuple):
    """A value (or a shape) and how many times it was seen."""

    value: str
    count: int


@dataclass
class Stats:
    """What a column's values are like, without reading them all."""

    values: int
    empty: int
    length: Optional[Tuple[int, int]]
    min: Optional[str]
    max: Optional[str]
    distinct: int
    distinct_at_least: bool
    top: List[Count]
    top_estimated: bool
    shapes: List[Count]
    shapes_estimated: bool
    sampled: Optional[int]

    @classmethod
    def _of(cls, d: Optional[Mapping[str, Any]]) -> Optional["Stats"]:
        if d is None:
            return None
        length = d.get("length")
        return cls(
            d["values"],
            d["empty"],
            (length["min"], length["max"]) if length else None,
            d.get("min"),
            d.get("max"),
            d["distinct"],
            d.get("distinct_at_least", False),
            [Count(t["value"], t["count"]) for t in d.get("top", ())],
            d.get("top_estimated", False),
            [Count(s["shape"], s["count"]) for s in d.get("shapes", ())],
            d.get("shapes_estimated", False),
            d.get("sampled"),
        )


class Sample(NamedTuple):
    """A value that did not fit its column: the line its row starts on, the
    value, and why (a reason code)."""

    row: int
    value: str
    code: str


@dataclass
class ColumnReport:
    """One schema column of a Report: its nulls, the values that did not
    fit, how much of it conforms, and what its values are like."""

    name: str
    type: str
    nulls: int
    mismatches: int
    conformance: float
    format: Optional[str]
    ambiguous: Optional[int]
    fits: List[str]
    samples: List[Sample]
    stats: Optional[Stats]

    @classmethod
    def _of(cls, d: Mapping[str, Any]) -> "ColumnReport":
        samples = [Sample(s["row"], s["value"], s["code"]) for s in d.get("samples", ())]
        return cls(
            d["name"],
            d["type"],
            d["nulls"],
            d["mismatches"],
            d["conformance"],
            d.get("format"),
            d.get("ambiguous"),
            list(d.get("fits", ())),
            samples,
            Stats._of(d.get("stats")),
        )


class RowError(NamedTuple):
    """Why a row was rejected: the column (None for the whole row's error,
    a ragged one say) and a reason code."""

    column: Optional[str]
    code: str


@dataclass
class RejectedLine:
    """A rejected row as the file has it, and why."""

    row: int
    text: str
    length: Optional[int]
    errors: List[RowError]

    @classmethod
    def _of(cls, d: Mapping[str, Any]) -> "RejectedLine":
        errors = [RowError(e.get("column"), e["code"]) for e in d.get("errors", ())]
        return cls(d["row"], d["text"], d.get("length"), errors)


def _report_fields(d: Dict[str, Any]) -> Dict[str, Any]:
    return dict(
        file=d["file"],
        result=d["result"],
        rows=d["rows"],
        bytes=d["bytes"],
        dialect=Dialect._of(d.get("dialect")),
        columns=[ColumnReport._of(c) for c in d.get("columns", ())],
        problems=_problems(d.get("problems")),
        warnings=list(d.get("warnings", ())),
        rows_rejected=d.get("rows_rejected", 0),
        rejected_sample=list(d.get("rejected_sample", ())),
        rejected_lines=[RejectedLine._of(r) for r in d.get("rejected_lines", ())],
        row_errors=dict(d.get("row_errors", {})),
        repeated_header_rows=list(d.get("repeated_header_rows", ())),
        raw=d,
    )


@dataclass
class Report(_Document):
    """A file read against a schema (docs/REPORT.md, "The file report").
    ``result`` is ``pass``, ``fail`` (it does not fit its schema) or
    ``error`` (it could not be read, or its dialect not settled)."""

    file: str
    result: str
    rows: int
    bytes: int
    dialect: Optional[Dialect]
    columns: List[ColumnReport]
    problems: List[Problem]
    warnings: List[str]
    rows_rejected: int
    rejected_sample: List[int]
    rejected_lines: List[RejectedLine]
    row_errors: Dict[str, int]
    repeated_header_rows: List[int]
    raw: Dict[str, Any] = field(repr=False)

    @classmethod
    def _of(cls, d: Dict[str, Any]) -> "Report":
        return cls(**_report_fields(d))

    @property
    def passed(self) -> bool:
        return self.result == "pass"

    def column(self, name: str) -> ColumnReport:
        for c in self.columns:
            if c.name == name:
                return c
        raise KeyError(name)

    def __str__(self) -> str:
        return "%s  %s  %d rows  %d rejected" % (self.result, self.file, self.rows, self.rows_rejected)


@dataclass
class Description(Report):
    """Everything thresh can say of a file (docs/REPORT.md, "A
    description"): a Report with every column's statistics, and what it
    was read as and against."""

    encoding: str = "utf8"
    inferred: bool = False
    schema: Optional[Schema] = None
    notes: List[Problem] = field(default_factory=list)

    @classmethod
    def _of(cls, d: Dict[str, Any]) -> "Description":
        schema = Schema(d["schema"]) if "schema" in d else None
        return cls(**_report_fields(d), encoding=d.get("encoding", "utf8"), inferred=d.get("inferred", False), schema=schema, notes=_problems(d.get("notes")))


@dataclass
class FileOutcome:
    """One file of an infer() call: ``pass``, or ``error`` and why."""

    file: str
    result: str
    problems: List[Problem]
    notes: List[Problem]


@dataclass
class Inference(_Document):
    """What infer() found: the schema the files fit, each file's outcome
    and notes, and how the files disagree (``problems``)."""

    schema: Optional[Schema]
    files: List[FileOutcome]
    notes: List[Problem]
    problems: List[Problem]
    raw: Dict[str, Any] = field(repr=False)

    @classmethod
    def _of(cls, d: Dict[str, Any]) -> "Inference":
        files = [FileOutcome(f["file"], f["result"], _problems(f.get("problems")), _problems(f.get("notes"))) for f in d.get("files", ())]
        schema = Schema(d["schema"]) if "schema" in d else None
        return cls(schema, files, _problems(d.get("notes")), _problems(d.get("problems")), d)

    @property
    def ok(self) -> bool:
        """A schema was inferred, every file could be read, and they agree."""
        return self.schema is not None and not self.problems and all(f.result == "pass" for f in self.files)
