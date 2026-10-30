#!/usr/bin/env python3
"""The fixture corpus: delimited files whose dialect, schema and field
boundaries are known because this script wrote them.

    python3 test/gen/corpus.py OUT_DIR                     write the corpus
    python3 test/gen/corpus.py OUT_DIR --check MANIFEST    and fail unless it matches
    python3 test/gen/corpus.py OUT_DIR --manifest MANIFEST and rewrite MANIFEST

`zig build corpus` runs the second form into the build cache. Run the third
after changing this script on purpose, and commit MANIFEST with it: the
diff of MANIFEST is the list of files the change moved.

Every data file NAME.csv has three siblings:

    NAME.dialect.json  the dialect the sniffer should settle, plus the
                       encoding, whether there is a BOM, and "adversarial"
    NAME.schema.json   its columns in thresh's schema format
    NAME.fields        one line per field, "record column start length flags":
                       record and column from 0, the header record included;
                       start and length are byte offsets into the file of the
                       field's content, inside its quotes if it has them and
                       still escaped; flags is 1 for quoted plus 2 when the
                       content holds an escape to undo

index.txt lists the data files, one per line. The files are
deterministic: a seeded generator of this script's own (not `random`,
whose sequences are not promised across Python versions), seeded from each
file's name, so adding a file moves no other.

Every file is read back with Python's csv module under its dialect before
it is written, and every field's bytes at (start, length), unescaped, must
be the value csv reads. A disagreement is a bug here and stops the run.

The files cover delimiter x quote x newline for two field profiles: short
(numbers, codes, dates, short names) and text (free text of 1 to 100 KB
with embedded delimiters, quotes and line breaks). Header and encoding
(UTF-8, UTF-8 with a BOM, Latin-1) cycle through each product, so each
value of every dimension appears with each of the others' values somewhere.
Backslash escaping gets eight files of its own. Then the adversarial set:
files built to make a sniffer guess wrong. Then the export set: files in
the shapes of real exports (product masters, lookup lists, mainframe and
FoxPro dumps, CRM reports), written from this script's own words and
numbers.

A file can only have one right answer if its bytes rule out the others,
so the generator makes sure they do: a quoted file has fields that need
their quotes (they hold the delimiter), and an unquoted file has values
that start with a quote character and never close it, so reading it as
quoted runs records together.
"""

import csv
import hashlib
import io
import json
import os
import sys

MASK = (1 << 64) - 1


class Rng:
    """splitmix64: small, and the same sequence on every Python."""

    def __init__(self, name):
        self.s = int.from_bytes(hashlib.sha256(name.encode()).digest()[:8], "little")

    def u64(self):
        self.s = (self.s + 0x9E3779B97F4A7C15) & MASK
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)

    def below(self, n):
        return self.u64() % n

    def between(self, lo, hi):
        return lo + self.below(hi - lo + 1)

    def chance(self, num, den):
        return self.below(den) < num

    def choice(self, seq):
        return seq[self.below(len(seq))]

    def log_uniform(self, lo, hi):
        """An int from lo to hi, each power of ten as likely as the next."""
        import math

        f = (self.u64() >> 11) / float(1 << 53)
        return int(math.exp(math.log(lo) + f * (math.log(hi) - math.log(lo))))


DELIMITERS = [
    ("comma", ","),
    ("tab", "\t"),
    ("pipe", "|"),
    ("semicolon", ";"),
    ("colon", ":"),
    ("tilde", "~"),
    ("soh", "\x01"),
    ("us", "\x1f"),
]
QUOTES = [("dq", '"'), ("sq", "'"), ("noquote", None)]
NEWLINES = [("lf", "\n"), ("crlf", "\r\n"), ("cr", "\r")]
ENCODINGS = ["utf8", "utf8-bom", "latin1"]

# Words for names and text. The accented ones are in Latin-1, so every
# encoding can write them.
WORDS = (
    "the of and to in is was for on that with as by at from it an be this "
    "order shipment invoice customer account balance payment delivery "
    "warehouse pallet carton refund return credit debit ledger quarter "
    "café niño Müller façade Ångström smörgåsbord crème brûlée jalapeño "
    "naïve coöperate señor déjà vu über straße"
).split()
FIRST = ["Ana", "Bo", "Chloé", "Dev", "Émile", "Fatima", "Günter", "Hana", "Iñigo", "Jo"]
LAST = ["Smith", "O'Brien", "Núñez", "Ng", "Østergaard", "Kowalski", "D'Souza", "Lee"]
CODES = ["open", "closed", "pending"]


class Dialect:
    def __init__(self, delimiter, quote, newline, header, escape="doubled"):
        self.delimiter = delimiter
        self.quote = quote
        self.newline = newline
        self.header = header
        self.escape = escape

    def newline_name(self):
        return {"\n": "lf", "\r\n": "crlf", "\r": "cr"}[self.newline]


class Writer:
    """Builds a file's bytes and the boundaries of every field in it."""

    def __init__(self, dialect, encoding, policy):
        self.d = dialect
        self.encoding = "utf8" if encoding == "utf8-bom" else encoding
        self.codec = {"latin1": "latin-1", "cp1252": "cp1252"}.get(encoding, "utf-8")
        # "minimal": quote when needed; "strings": quote every string;
        # "all": quote every field but the header's, an empty one as "".
        self.policy = policy
        self.out = bytearray(b"\xef\xbb\xbf" if encoding == "utf8-bom" else b"")
        self.fields = []
        self.records = []

    def needs_quotes(self, v):
        d = self.d
        return (
            d.delimiter in v
            or "\r" in v
            or "\n" in v
            or (d.quote is not None and v.startswith(d.quote))
        )

    def escape(self, v):
        q = self.d.quote
        if self.d.escape == "backslash":
            return v.replace("\\", "\\\\").replace(q, "\\" + q)
        return v.replace(q, q + q)

    def record(self, values, kinds, raw_last=None):
        """values: str or None (null, written empty); kinds: "s" string, "n" not.
        raw_last: written as it is for the last value, quoting and all (a
        dirty file's broken quote). A lone surrogate is written as the byte
        it escapes, for a dirty file's invalid UTF-8."""
        d = self.d
        self.records.append(["" if v is None else v for v in values])
        row = len(self.records) - 1
        kinds = list(kinds) + ["s"] * (len(values) - len(kinds))
        for col, (v, kind) in enumerate(zip(values, kinds)):
            if col:
                self.out += d.delimiter.encode(self.codec)
            if raw_last is not None and col == len(values) - 1:
                self.out += raw_last.encode(self.codec)
                continue
            v = "" if v is None else v
            quoted = False
            if d.quote is not None:
                quoted = (
                    self.needs_quotes(v)
                    or (self.policy == "strings" and kind == "s" and values[col] is not None)
                    or (self.policy == "all" and kind != "h")
                )
                # A field holding the quote character mid-value is data to
                # an unquoted reader, but csv quotes it, and so do we.
                quoted = quoted or d.quote in v
            else:
                assert not self.needs_quotes(v), (v, "cannot be written unquoted")
            if quoted:
                body = self.escape(v)
                self.out += d.quote.encode(self.codec)
                start = len(self.out)
                self.out += body.encode(self.codec, "surrogateescape")
                self.fields.append((row, col, start, len(self.out) - start, 1 | (2 if body != v else 0)))
                self.out += d.quote.encode(self.codec)
            else:
                start = len(self.out)
                self.out += v.encode(self.codec, "surrogateescape")
                self.fields.append((row, col, start, len(self.out) - start, 0))
        self.out += d.newline.encode(self.codec)

    def blank(self):
        """An empty line between records: no record, and no field."""
        self.out += self.d.newline.encode(self.codec)

    def check(self):
        """Reads the file back with csv, and every field from its offsets."""
        d = self.d
        raw = bytes(self.out)
        text = raw.decode("utf-8-sig" if self.codec == "utf-8" else self.codec)
        kw = {"delimiter": d.delimiter, "strict": True}
        if d.quote is None:
            kw.update(quoting=csv.QUOTE_NONE, quotechar=None)
        elif d.escape == "backslash":
            kw.update(quotechar=d.quote, doublequote=False, escapechar="\\")
        else:
            kw.update(quotechar=d.quote, doublequote=True)
        # csv reads an empty line as a record of no fields; thresh skips it.
        got = [r for r in csv.reader(io.StringIO(text, newline=""), **kw) if r]
        if got != self.records:
            for i, (a, b) in enumerate(zip(got, self.records)):
                if a != b:
                    raise AssertionError("record %d: csv read %r, wrote %r" % (i, a[:4], b[:4]))
            raise AssertionError("csv read %d records, wrote %d" % (len(got), len(self.records)))
        for row, col, start, length, flags in self.fields:
            v = raw[start : start + length].decode(self.codec)
            if flags & 2:
                if d.escape == "backslash":
                    out, i = [], 0
                    while i < len(v):
                        if v[i] == "\\":
                            i += 1
                        out.append(v[i])
                        i += 1
                    v = "".join(out)
                else:
                    v = v.replace(d.quote * 2, d.quote)
            assert v == self.records[row][col], (row, col, v[:40], self.records[row][col][:40])
        return raw

    def check_unique(self, text, adversarial):
        """No other quote or escape reads the file as well as its own, or
        one that does comes later in the sniffer's prior order, so a tie
        still goes to the right answer. Read the way thresh's scanner
        reads: every quote character toggles, a doubled one twice."""
        d = self.d
        own = counts(text, d.delimiter, d.quote, d.escape, d.newline)
        mode = max(set(own), key=own.count)
        assert own.count(mode) == len(own), "the file's own dialect reads ragged records"
        order = ['"', "'", None]
        rivals = [(q, "doubled") for q in order if q != d.quote]
        if d.escape == "backslash":
            rivals.append((d.quote, "doubled"))
        for q, e in rivals:
            got = counts(text, d.delimiter, q, e, d.newline)
            ties = got == own
            earlier = order.index(q) < order.index(d.quote) or (q == d.quote and e == "doubled")
            if ties and earlier and not adversarial:
                raise AssertionError("quote %r escape %s reads it as well and wins the tie" % (q, e))


def counts(text, delim, quote, escape, newline):
    """Fields per record, quote-aware the way a structural index sees it."""
    out = []
    fields, in_quote, i, n, empty = 1, False, 0, len(text), True
    while i < n:
        c = text[i]
        if quote is not None and escape == "backslash" and c == "\\" and in_quote:
            i += 2
            empty = False
            continue
        if quote is not None and c == quote:
            in_quote = not in_quote
        elif not in_quote and c == delim:
            fields += 1
        elif not in_quote and text.startswith(newline, i):
            if not empty or fields > 1:
                out.append(fields)
            fields, empty = 1, True
            i += len(newline)
            continue
        empty = False
        i += 1
    if not empty or fields > 1:
        out.append(fields)
    return out


def words(rng, n, d, allow_breaks, allow_quotes):
    """n words of text: some with the delimiter, quotes or line breaks in them."""
    out = []
    for i in range(n):
        w = rng.choice(WORDS)
        r = rng.below(40)
        if r == 0 and allow_breaks:
            w += rng.choice(["\n", "\r\n", d.newline])
        elif r == 1 and allow_breaks:
            w += d.delimiter
        elif r == 2 and allow_quotes:
            w = rng.choice(['"%s"', "'%s'", "%s's", '%s"']) % w
        elif r == 3:
            w += rng.choice([",", ";", ":", "|", "~", "."])
        out.append(w)
    text = " ".join(out)
    if not allow_breaks:
        for c in (d.delimiter, "\r", "\n"):
            text = text.replace(c, " ")
    if d.escape == "doubled":
        # A backslash before a quote would read as an escape to a sniffer
        # weighing backslash escaping; the doubled files never have one.
        text = text.replace("\\", "/")
    return text


def unclosed(rng, special, i):
    """A value starting with a quote character it never closes: the double
    quote and the single in turn, so each appears and neither reads the
    file as well as no quoting does."""
    q = '"' if special.index(i) % 2 == 0 else "'"
    return q + rng.choice(LAST).replace("'", "") + " " + rng.choice(WORDS)


def name(rng, d, need_delim):
    n = rng.choice(FIRST) + " " + rng.choice(LAST)
    if need_delim:
        n = rng.choice(LAST) + d.delimiter + " " + rng.choice(FIRST)
    return n


def date(rng):
    return "%04d-%02d-%02d" % (rng.between(2019, 2026), rng.between(1, 12), rng.between(1, 28))


def short_file(fname, d, encoding, policy):
    """Numbers, codes, dates and names, 80 to 160 records."""
    rng = Rng(fname)
    # A timestamp holds ':' and ' '; a file that cannot quote a ':' leaves it out.
    with_ts = not (d.quote is None and d.delimiter == ":")
    columns = [
        {"name": "id", "type": "int64", "nullable": False},
        {"name": "code", "type": "enum", "values": CODES},
        {"name": "amount", "type": "decimal", "precision": 12, "scale": 2},
        {"name": "ratio", "type": "float64"},
        {"name": "flag", "type": "bool"},
        {"name": "created", "type": "date", "format": "%Y-%m-%d"},
    ]
    if with_ts:
        columns.append({"name": "updated", "type": "timestamp", "format": "%Y-%m-%d %H:%M:%S"})
    columns.append({"name": "name", "type": "string"})
    kinds = ["n", "s", "n", "n", "n", "n"] + (["n"] if with_ts else []) + ["s"]
    w = Writer(d, encoding, policy)
    if d.header:
        w.record([c["name"] for c in columns], ["s"] * len(columns))
    rows = rng.between(80, 160)
    # Rows whose name needs its quotes, or (unquoted) opens a quote it never
    # closes: early enough that the first 64 KiB holds them.
    special = [5 * k + rng.between(1, 4) for k in range(6)]
    for i in range(rows):
        cents = rng.between(-500000, 2000000)
        ratio = None if rng.chance(1, 10) else rng.choice(
            ["%.6f" % (rng.below(10**6) / 10**6), "%de-%02d" % (rng.between(1, 9), rng.between(1, 12))]
        )
        values = [
            str(i + 1),
            rng.choice(CODES),
            "%s%d.%02d" % ("-" if cents < 0 else "", abs(cents) // 100, abs(cents) % 100),
            ratio,
            rng.choice(["true", "false"]),
            date(rng),
        ]
        if with_ts:
            values.append(date(rng) + " %02d:%02d:%02d" % (rng.below(24), rng.below(60), rng.below(60)))
        if d.quote is None:
            values.append(unclosed(rng, special, i) if i in special else name(rng, d, False).replace("'", ""))
        else:
            values.append(name(rng, d, i in special))
        w.record(values, kinds)
    return w, columns


def text_file(fname, d, encoding, policy, rows=None, body=(1000, 100000)):
    """An id, a title and long free text: 12 to 20 records."""
    rng = Rng(fname)
    columns = [
        {"name": "id", "type": "int64", "nullable": False},
        {"name": "title", "type": "string"},
        {"name": "body", "type": "string", "max_len": 1 << 20},
        {"name": "note", "type": "string"},
    ]
    kinds = ["n", "s", "s", "s"]
    w = Writer(d, encoding, policy)
    if d.header:
        w.record([c["name"] for c in columns], ["s"] * len(columns))
    quoted = d.quote is not None
    special = [2 * k + rng.below(2) for k in range(4)]
    for i in range(rows or rng.between(12, 20)):
        size = rng.log_uniform(body[0], body[1])
        text = words(rng, max(1, size // 7), d, quoted, quoted)[:size]
        if quoted:
            title = name(rng, d, i in special)
        else:
            title = unclosed(rng, special, i) if i in special else name(rng, d, False).replace("'", "")
        note = None if rng.chance(1, 4) else words(rng, rng.between(3, 30), d, quoted, quoted)
        w.record([str(i + 1), title, text, note], kinds)
    return w, columns


def adversarial(name):
    """Files built to fool a sniffer, each returning (writer, columns)."""
    rng = Rng(name)
    if name == "adv-comma-rich-tsv":
        # Tab-delimited, every text field full of commas, unevenly.
        d = Dialect("\t", '"', "\n", True)
        w = Writer(d, "utf8", "minimal")
        cols = [{"name": n, "type": t} for n, t in [("id", "int64"), ("summary", "string"), ("tags", "string")]]
        w.record([c["name"] for c in cols], "sss")
        for i in range(60):
            summary = ", ".join(rng.choice(WORDS) for _ in range(rng.between(2, 9)))
            tags = ",".join(rng.choice(WORDS) for _ in range(rng.between(1, 6)))
            w.record([str(i + 1), summary, tags], "nss")
        return w, cols
    if name == "adv-pipe-text":
        # Pipe-delimited, with more pipes inside quoted text than between fields.
        d = Dialect("|", '"', "\n", True)
        w = Writer(d, "utf8", "minimal")
        cols = [{"name": n, "type": t} for n, t in [("id", "int64"), ("path", "string"), ("cmd", "string")]]
        w.record([c["name"] for c in cols], "sss")
        for i in range(60):
            path = "|".join(rng.choice(WORDS) for _ in range(rng.between(3, 8)))
            cmd = " | ".join(rng.choice(["grep", "sort", "uniq -c", "head", "wc -l"]) for _ in range(rng.between(2, 6)))
            w.record([str(i + 1), path, cmd], "nss")
        return w, cols
    if name == "adv-giant-first-field":
        # No header, and the first field of the first record is one quoted
        # 150 KB value full of commas and line breaks: bigger than the
        # initial sniff window.
        d = Dialect(",", '"', "\n", False)
        w = Writer(d, "utf8", "minimal")
        cols = [{"name": n, "type": t} for n, t in [("body", "string"), ("id", "int64"), ("code", "string")]]
        giant = words(rng, 150000 // 6, d, True, True)
        w.record([giant, "1", rng.choice(CODES)], "sns")
        for i in range(1, 50):
            w.record([words(rng, rng.between(3, 12), d, True, True), str(i + 1), rng.choice(CODES)], "sns")
        return w, cols
    if name == "adv-decimal-comma":
        # Semicolons between fields and commas in every decimal, unquoted:
        # European exports. The comma candidate sees a consistent count too.
        # No quote character appears, so every quote reads it alike and the
        # first in the prior order, the double quote, is the right answer.
        d = Dialect(";", '"', "\r\n", True)
        w = Writer(d, "latin1", "minimal")
        cols = [{"name": n, "type": t} for n, t in [("id", "int64"), ("price", "string"), ("qty", "int64"), ("vat", "string")]]
        w.record([c["name"] for c in cols], "ssss")
        for i in range(80):
            price = "%d,%02d" % (rng.between(0, 9999), rng.below(100))
            vat = "%d,%d" % (rng.choice([7, 19, 20, 21]), rng.below(10))
            w.record([str(i + 1), price, str(rng.between(1, 500)), vat], "nsns")
        return w, cols
    raise KeyError(name)


ADVERSARIAL = ["adv-comma-rich-tsv", "adv-pipe-text", "adv-giant-first-field", "adv-decimal-comma"]

# Export files: the shapes of real feeds (work samples seen 2026-10-30, card
# t19) with none of their values. Each is a table: per column its name, its
# schema, its kind for quoting, and a function of the row number giving its
# value, None for an empty field.

BLANK_DATE = "  /  /    "
BLANK_DATETIME = "  /  /       :  :  "
STRING = {"type": "string"}
INT = {"type": "int64"}
BOOL = {"type": "bool"}
US_DATE = {"type": "date", "format": "%m/%d/%Y"}
US_TIMESTAMP = {"type": "timestamp", "format": "%m/%d/%Y %H:%M:%S"}
PLACES = ["north", "harbor", "maple", "cedar", "river", "summit", "oak", "bay"]


def digits(rng, n):
    return "".join(str(rng.below(10)) for _ in range(n))


def padded_id(rng, n, zeros):
    """n digits, an identifier's shape (a GS1 number, a ZIP code): zeros is
    the chance, as (num, den), that it starts with 0."""
    return ("0" if rng.chance(*zeros) else str(rng.between(1, 9))) + digits(rng, n - 1)


def us_date(rng):
    return "%02d/%02d/%04d" % (rng.between(1, 12), rng.between(1, 28), rng.between(2019, 2026))


def us_timestamp(rng):
    return us_date(rng) + " %02d:%02d:%02d" % (rng.below(24), rng.below(60), rng.below(60))


def fox_id(rng):
    """A FoxPro SYS(2015) key: an underscore and nine base-36 characters."""
    return "_" + "".join(rng.choice("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(9))


def some(rng, num, den, f):
    """f() in num of den rows, None in the rest."""
    return f() if rng.chance(num, den) else None


def table(d, policy, spec, rows, header=None, blank_every=0, encoding="utf8"):
    """A header (never quoted unless it must be) and rows of spec."""
    w = Writer(d, encoding, policy)
    w.record(header or [n for n, _, _, _ in spec], "h" * len(spec))
    kinds = [k for _, _, k, _ in spec]
    for i in range(rows):
        w.record([f(i) for _, _, _, f in spec], kinds)
        if blank_every and i % blank_every == blank_every - 1:
            w.blank()
    return w, [dict({"name": n}, **c) for n, c, _, _ in spec]


def export(name):
    """Files in the shapes of real exports, each returning (writer, columns)."""
    rng = Rng(name)
    if name == "exp-pipe-crlf-product":
        # A product master: every text field quoted, numbers and dates not;
        # ids of 13 and 14 digits, some with a leading zero; US timestamps;
        # Yes/No; measures with their units; most columns empty in most
        # rows, and twenty in every row.
        d = Dialect("|", '"', "\r\n", True)

        def measure():
            return "%d.%03d" % (rng.below(100), rng.below(1000))

        def unit():
            return rng.choice(["KG", "LB", "G", "OZ", "EA"])

        spec = [
            ("Article Code", STRING, "s", lambda i: "%06d-%05d" % (100000 + i, rng.below(10**5))),
            ("Barcode 14", STRING, "s", lambda i: padded_id(rng, 14, (1, 3))),
            ("Site Code 13", STRING, "s", lambda i: some(rng, 2, 3, lambda: padded_id(rng, 13, (1, 3)))),
            ("Added At", US_TIMESTAMP, "n", lambda i: us_timestamp(rng)),
            ("Added By", STRING, "s", lambda i: rng.choice(["batch", "loader_job", "admin"])),
            ("Revised At", US_TIMESTAMP, "n", lambda i: us_timestamp(rng)),
            ("Facts Supplied", BOOL, "s", lambda i: some(rng, 1, 2, lambda: rng.choice(["Yes", "No"]))),
            ("Brand House", STRING, "s", lambda i: some(rng, 1, 2, lambda: rng.choice(LAST) + " " + rng.choice(["Foods", "Brands Inc.", "Ltd."]))),
            ("Mass Net", {"type": "decimal", "precision": 9, "scale": 3}, "n", lambda i: some(rng, 1, 2, measure)),
            ("Mass Net Unit", STRING, "s", lambda i: some(rng, 1, 2, unit)),
            ("Mass Gross", {"type": "decimal", "precision": 9, "scale": 3}, "n", lambda i: some(rng, 1, 2, measure)),
            ("Box/size", STRING, "s", lambda i: some(rng, 1, 3, lambda: "%d X %d CM" % (rng.between(1, 99), rng.between(1, 99)))),
            ("Tax/levy exempt", BOOL, "s", lambda i: None),
            ("Layer Count", INT, "n", lambda i: some(rng, 1, 2, lambda: str(rng.between(1, 12)))),
            ("Retired", BOOL, "s", lambda i: some(rng, 1, 2, lambda: rng.choice(["Yes", "No"]))),
            ("Tree Path", STRING, "s", lambda i: "%d-%d-%d" % (rng.between(1, 9), rng.between(10, 99), rng.between(1, 9))),
            ("Listing ID", INT, "n", lambda i: str(rng.between(10**9, 2 * 10**9))),
        ] + [("Attribute %02d" % k, STRING, "s", lambda i: None) for k in range(1, 21)]
        return table(d, "strings", spec, 120)
    if name == "exp-pipe-crlf-lookup":
        # A lookup list: dotted and bracketed codes, quotes only around a
        # value that holds one (doubled), True/False, and labels in a second
        # language for a few rows only.
        d = Dialect("|", '"', "\r\n", True)
        groups = ["[Order_Status]", "[Ship_Mode]", "Pack_Type", "[Region]"]

        def label():
            w = rng.choice(WORDS)
            return "[%s]" % w.title() if rng.chance(1, 2) else w

        spec = [
            ("Entry.List", STRING, "s", lambda i: "%s.%s.%s" % (rng.choice(groups), rng.choice(["Main", "Alt"]), rng.choice(["Kind", "Value", "Code"]))),
            ("Entry.Code", STRING, "s", lambda i: ".".join(rng.choice(["ab", "cd", "ef", "gh", "x1"]) for _ in range(rng.between(2, 5)))),
            ("Entry.Active", BOOL, "n", lambda i: rng.choice(["True", "False"])),
            ("Entry.Rank", INT, "n", lambda i: str(rng.between(0, 99999))),
            ("EntryText.Label(en)", STRING, "s", lambda i: some(rng, 99, 100, label)),
            ("EntryText.Label(fr)", STRING, "s", lambda i: some(rng, 1, 30, lambda: rng.choice(["café", "crème brûlée", "façade", "déjà vu"]))),
            ("EntryText.Note(en)", STRING, "s", lambda i: some(rng, 1, 50, lambda: words(rng, rng.between(4, 20), d, False, True))),
        ]
        return table(d, "minimal", spec, 400)
    if name == "exp-pipe-crlf-units":
        # Units of measure, an empty line after every five records.
        d = Dialect("|", '"', "\r\n", True)
        spec = [
            ("Part Number", INT, "n", lambda i: str(1000000 + 7 * i)),
            ("Unit Text", STRING, "s", lambda i: rng.choice(["each", "case of twelve", "pallet", "inner pack (6)", "kilogram"])),
            ("Unit Code", STRING, "s", lambda i: rng.choice(["EA", "CS", "PL", "IP", "KG"])),
            ("Per Pack", INT, "n", lambda i: str(rng.between(1, 48))),
            ("Of Units", INT, "n", lambda i: str(rng.choice([1, 1, 1, 2, 10]))),
        ]
        return table(d, "strings", spec, 50, blank_every=5)
    if name == "exp-pipe-lf-padded":
        # A mainframe dump: every field padded to its width, text and numbers
        # alike; upper-case names with underscores; a zero-padded sequence
        # number; Y/N flags; a wide field of spaces. No quote character
        # anywhere, so the first in the prior order is the right answer.
        d = Dialect("|", '"', "\n", True)

        def description():
            return words(rng, rng.between(1, 4), d, False, False)[:40] if rng.chance(1, 2) else ""

        spec = [
            ("DEAL_ID", STRING, "s", lambda i: ("C%d" % (4000 + i)).ljust(10)),
            ("LABEL_TEXT", STRING, "s", lambda i: description().ljust(40)),
            ("AGENT", STRING, "s", lambda i: rng.choice(["AB", "CDE", ""]).ljust(4)),
            ("PRICE_FLAG", STRING, "s", lambda i: rng.choice(["Y", "N"])),
            ("FEE", {"type": "decimal", "precision": 5, "scale": 2}, "n", lambda i: rng.choice(["0", "2.5", "12.75", "5"]).ljust(5)),
            ("FLOOR_QTY", INT, "n", lambda i: str(rng.choice([0, 50, 100, 250])).ljust(6)),
            ("SPARE_1", STRING, "s", lambda i: " " * 120),
            ("VOID_FLAG", STRING, "s", lambda i: " "),
            ("LINE_SEQ", STRING, "s", lambda i: "%010d" % (i + 1)),
        ]
        return table(d, "minimal", spec, 40)
    if name == "exp-comma-lf-plan":
        # A planning extract: no quoting, snake_case names, codes with four
        # underscores apiece, two quantities of which a row fills one, and a
        # decimal of up to eighteen places.
        d = Dialect(",", '"', "\n", True)
        rows = 3000
        makes = [rng.chance(2, 3) for _ in range(rows)]

        def step():
            return "%s_%s_%d_%s_%d" % (rng.choice(["MAKE", "MOVE", "BUY"]), rng.choice("ABC"), rng.between(1, 99), rng.choice("XY"), rng.between(1, 9))

        spec = [
            ("is_live", INT, "n", lambda i: "1"),
            ("Scenario", STRING, "s", lambda i: rng.choice(["Baseline", "Upside"])),
            ("Site", INT, "n", lambda i: str(rng.between(1000, 1999))),
            ("Source_Site", INT, "n", lambda i: str(rng.between(100000000, 199999999))),
            ("Step_3", INT, "n", lambda i: str(rng.between(100000, 999999))),
            ("Step_1", STRING, "s", lambda i: step()),
            ("Part", INT, "n", lambda i: str(rng.between(100000, 999999))),
            ("Line_ID", STRING, "s", lambda i: "%dAB_%s" % (rng.between(10000, 99999), rng.choice(["CD", "EF"]))),
            ("Week_Start", US_DATE, "n", lambda i: us_date(rng)),
            ("Step_2", STRING, "s", lambda i: rng.choice(["Plant", "DC", "Vendor"])),
            ("Prod_Qty", INT, "n", lambda i: str(rng.between(1, 99999)) if makes[i] else None),
            ("Cons_Qty", INT, "n", lambda i: None if makes[i] else str(rng.between(1, 9999))),
            ("Demand_Qty", {"type": "decimal", "precision": 24, "scale": 18}, "n", lambda i: some(rng, 3, 4, lambda: "%d.%s" % (rng.below(10**5), digits(rng, rng.between(1, 18))))),
        ]
        return table(d, "minimal", spec, rows)
    if name == "exp-comma-lf-codes":
        # Three columns, one of codes like AB_CD_EF_GH_AB: read at _ they
        # are six columns, nearly as consistent, and the header has no _
        # (card t20).
        d = Dialect(",", '"', "\n", True)
        spec = [
            ("id", INT, "n", lambda i: str(i)),
            ("code", STRING, "s", lambda i: "_".join(rng.choice(["AB", "CD", "EF", "GH"]) for _ in range(5))),
            ("name", STRING, "s", lambda i: rng.choice(["red", "blue", "green"])),
        ]
        return table(d, "minimal", spec, 200)
    if name == "exp-comma-crlf-leads":
        # A CRM report: every field quoted, an empty one as "", but not the
        # header, whose names after the first start with a space. ZIP codes,
        # some with a leading zero; US dates; e-mail and web addresses; a
        # contact of one space when unknown; eight columns empty in every row.
        d = Dialect(",", '"', "\r\n", True)

        def notes():
            return ", ".join(words(rng, rng.between(2, 8), d, False, True) for _ in range(rng.between(1, 4)))

        spec = [
            ("RefNo", INT, "n", lambda i: str(1000000 + 13 * i)),
            ("Business", STRING, "s", lambda i: "%s %s" % (rng.choice(PLACES).title(), rng.choice(["Bistro", "Grill", "Cafe & Bar", "Kitchen"]))),
            ("Kind", STRING, "s", lambda i: rng.choice(["New", "Reno"])),
            ("Stage", STRING, "s", lambda i: rng.choice(["Planning", "Under Construction", "Opening Soon"])),
            ("Given Name", STRING, "s", lambda i: some(rng, 3, 5, lambda: rng.choice(FIRST))),
            ("Family Name", STRING, "s", lambda i: some(rng, 3, 5, lambda: rng.choice(LAST))),
            ("Contact", STRING, "s", lambda i: rng.choice(FIRST) + " " + rng.choice(LAST) if rng.chance(3, 5) else " "),
            ("Role", STRING, "s", lambda i: some(rng, 1, 2, lambda: rng.choice(["Owner", "Chef", "GM"]))),
            ("E-mail Address", STRING, "s", lambda i: some(rng, 3, 4, lambda: "%s.%s@%s-%s.com" % tuple(rng.choice(PLACES) for _ in range(4)))),
            ("Telephone", STRING, "n", lambda i: some(rng, 2, 3, lambda: str(rng.between(2, 9)) + digits(rng, 9))),
            ("Ext", STRING, "s", lambda i: None),
            ("Alt Contact", STRING, "s", lambda i: None),
            ("Web", STRING, "s", lambda i: some(rng, 9, 10, lambda: rng.choice(["https://www.%s.com/", "%s.com", "http://%s.example.org/menu"]) % rng.choice(PLACES))),
            ("Street", STRING, "s", lambda i: "%d %s %s" % (rng.between(1, 9999), rng.choice(PLACES).title(), rng.choice(["St", "Ave", "Rd."]))),
            ("Street2", STRING, "s", lambda i: None),
            ("Town", STRING, "s", lambda i: rng.choice(PLACES).title() + rng.choice(["", " Falls", " City"])),
            ("Region", STRING, "s", lambda i: rng.choice(["MA", "NJ", "TX", "CA", "NY"])),
            ("Postcode", STRING, "s", lambda i: padded_id(rng, 5, (1, 8))),
            ("Venue Type", STRING, "s", lambda i: rng.choice(["Full Service (Sit-Down)", "Quick Service", "Bar/Tavern"])),
            ("Price Band", STRING, "s", lambda i: some(rng, 20, 21, lambda: rng.choice(["$", "$$", "$$$", "$/$$"]))),
            ("Cuisine", STRING, "s", lambda i: rng.choice(["American", "Italian", "Café", "Tex-Mex", "Sushi  Bar"])),
            ("Opening", US_DATE, "n", lambda i: some(rng, 50, 51, lambda: us_date(rng))),
            ("Published", US_DATE, "n", lambda i: us_date(rng)),
            ("Notes", STRING, "s", lambda i: some(rng, 3, 5, notes)),
            ("Mobile", STRING, "s", lambda i: None),
            ("Alt Phone", STRING, "s", lambda i: None),
            ("Second E-mail", STRING, "s", lambda i: None),
            ("Licence", STRING, "s", lambda i: some(rng, 1, 6, lambda: rng.choice(["Beer & Wine", "Full Bar"]))),
            ("Origin", STRING, "s", lambda i: some(rng, 99, 100, lambda: "https://news.example.com/%d/%02d/%s-%s/" % (rng.between(2019, 2026), rng.between(1, 12), rng.choice(PLACES), rng.choice(PLACES)))),
            ("Social A", STRING, "s", lambda i: None),
            ("Social B (old)", STRING, "s", lambda i: None),
            ("Social C", STRING, "s", lambda i: None),
            ("Social D", STRING, "s", lambda i: None),
        ]
        header = [spec[0][0]] + [" " + n for n, _, _, _ in spec[1:]]
        return table(d, "all", spec, 300, header=header)
    if name == "exp-comma-crlf-foxpro":
        # A FoxPro table dump: lower-case typed names, keys like _5TF0XWQ1Z,
        # decimals at five places, T/F logicals, 0/1 numeric flags, US dates
        # and timestamps whose empty value is their punctuation and spaces, a
        # code column with "-", "NA" and zero-padded codes, and three columns
        # empty in every row.
        d = Dialect(",", '"', "\r\n", True)
        stamp = dict(US_TIMESTAMP, nulls=[BLANK_DATETIME])

        def five():
            return "%d.%05d" % (rng.below(100), rng.below(10**5))

        spec = [
            ("kkey", STRING, "s", lambda i: fox_id(rng)),
            ("cownerkey", STRING, "s", lambda i: fox_id(rng)),
            ("ctypeid", STRING, "s", lambda i: some(rng, 9, 10, lambda: fox_id(rng))),
            ("nkind", INT, "n", lambda i: str(rng.between(1, 3))),
            ("nline", INT, "n", lambda i: str(rng.between(1, 9999))),
            ("cclass", STRING, "s", lambda i: some(rng, 1, 3, lambda: rng.choice(["-", "NA", "A%d" % rng.between(1, 99), "%04d" % rng.below(10000)]))),
            ("clibelle", STRING, "s", lambda i: ", ".join(rng.choice(WORDS) for _ in range(rng.between(1, 4)))),
            ("bfactor", {"type": "decimal", "precision": 10, "scale": 5}, "n", lambda i: five()),
            ("bcost", {"type": "decimal", "precision": 10, "scale": 5}, "n", lambda i: ("-" if rng.chance(1, 3) else "") + five()),
            ("lprimary", BOOL, "n", lambda i: rng.choice(["T", "F"])),
            ("nflag", INT, "n", lambda i: rng.choice(["0", "1"])),
            ("dposted", dict(US_DATE, nulls=[BLANK_DATE]), "n", lambda i: us_date(rng) if rng.chance(9, 10) else BLANK_DATE),
            ("dcreated", stamp, "n", lambda i: us_timestamp(rng) if rng.chance(4, 5) else BLANK_DATETIME),
            ("dchanged", stamp, "n", lambda i: us_timestamp(rng) if rng.chance(1, 2) else BLANK_DATETIME),
            ("coperator", STRING, "s", lambda i: rng.choice(["ADMIN", "JD", "SYS"])),
            ("cspare1", STRING, "s", lambda i: None),
            ("cspare2", STRING, "s", lambda i: None),
            ("cspare3", STRING, "s", lambda i: None),
        ]
        return table(d, "strings", spec, 500)
    if name == "exp-pipe-crlf-tiny":
        # Two records under a header of sixty columns, most of them empty:
        # all a sniffer and inference get to go on.
        d = Dialect("|", '"', "\r\n", True)
        spec = [
            ("Record ID", INT, "n", lambda i: str(500 + i)),
            ("Changed At", US_TIMESTAMP, "n", lambda i: us_timestamp(rng)),
            ("Owner", STRING, "s", lambda i: rng.choice(FIRST)),
            ("Amount", {"type": "decimal", "precision": 8, "scale": 2}, "n", lambda i: "%d.%02d" % (rng.below(10000), rng.below(100))),
        ] + [("Field %02d" % k, STRING, "s", lambda i: some(rng, 1, 4, lambda: rng.choice(WORDS))) for k in range(1, 57)]
        return table(d, "strings", spec, 2)
    if name == "exp-comma-crlf-cp1252":
        # A Windows ledger export: French text in Windows-1252, whose bytes
        # 0x80 to 0x9f are punctuation and letters (’ is 0x92, œ 0x9c, €
        # 0x80), not the control characters Latin-1 has there (card t21).
        d = Dialect(",", '"', "\r\n", True)
        french = ["l’œuvre", "café", "crème brûlée", "pâté", "société", "reçu", "« facture »", "coût", "dépôt", "frais d’envoi", "œufs", "Noël", "à régler", "€"]
        spec = [
            ("kkey", STRING, "s", lambda i: fox_id(rng)),
            ("njournal", INT, "n", lambda i: str(rng.between(1, 9))),
            ("cledger", STRING, "s", lambda i: "%d-%03d" % (rng.between(1000, 9999), rng.below(1000))),
            ("dposting", US_DATE, "n", lambda i: us_date(rng)),
            ("clibelle", STRING, "s", lambda i: " ".join(rng.choice(french) for _ in range(rng.between(1, 4)))),
            ("nsomme", {"type": "decimal", "precision": 10, "scale": 2}, "n", lambda i: "%s%d.%02d" % ("-" if rng.chance(2, 3) else "", rng.below(100000), rng.below(100))),
            ("cmonnaie", STRING, "s", lambda i: rng.choice(["CAD", "USD", "EUR"])),
        ]
        return table(d, "strings", spec, 300, encoding="cp1252")
    if name == "exp-tab-lf-ledger":
        # An ERP ledger extract: tabs, no quoting, keys of 48 and 56 digits
        # (too long for any number type: card t25), zero-padded codes,
        # amounts with a sign, and one padded to its width with a bare
        # point, as fixed-width numeric fields are.
        d = Dialect("\t", '"', "\n", True)

        def amount(i):
            if i == 7:
                return " " * 18 + "%d." % rng.between(1, 999)
            cents = rng.between(-10**8, 10**9)
            return "%s%d.%02d" % ("-" if cents < 0 else "", abs(cents) // 100, abs(cents) % 100)

        spec = [
            ("Batch Key", STRING, "s", lambda i: str(rng.between(1, 9)) + digits(rng, 46) + str(i % 10)),
            ("Year", INT, "n", lambda i: str(rng.between(2019, 2026))),
            ("Unit Code", STRING, "s", lambda i: "%010d" % rng.between(1, 99999)),
            ("Cost Pool", STRING, "s", lambda i: some(rng, 2, 5, lambda: "%010d" % rng.between(1, 999999))),
            ("Period", STRING, "s", lambda i: "%03d" % rng.between(1, 12)),
            ("Local Amount", {"type": "decimal", "precision": 18, "scale": 2}, "n", amount),
            ("Group Amount", {"type": "decimal", "precision": 18, "scale": 2}, "n", amount),
            ("Run Key", STRING, "s", lambda i: str(rng.between(1, 9)) + digits(rng, 55)),
        ]
        return table(d, "minimal", spec, 2000)
    raise KeyError(name)


EXPORTS = [
    "exp-pipe-crlf-product",
    "exp-pipe-crlf-lookup",
    "exp-pipe-crlf-units",
    "exp-pipe-lf-padded",
    "exp-comma-lf-plan",
    "exp-comma-lf-codes",
    "exp-comma-crlf-leads",
    "exp-comma-crlf-foxpro",
    "exp-pipe-crlf-tiny",
    "exp-comma-crlf-cp1252",
    "exp-tab-lf-ledger",
]


def plan():
    """Every file: (name, build) where build() gives (writer, columns, encoding, adversarial)."""
    files = []
    i = 0
    for profile, build in (("short", short_file), ("text", text_file)):
        for dn, dc in DELIMITERS:
            for qn, qc in QUOTES:
                for nn, nc in NEWLINES:
                    header = i % 2 == 0
                    encoding = ENCODINGS[(i // 2) % 3]
                    policy = "strings" if (i // 6) % 2 else "minimal"
                    i += 1
                    fname = "%s-%s-%s-%s-%s-%s" % (profile, dn, qn, nn, "h" if header else "nh", encoding)
                    d = Dialect(dc, qc, nc, header)
                    files.append((fname, d, encoding, False, (lambda b, f, d, e, p: lambda: b(f, d, e, p))(build, fname, d, encoding, policy)))
    for j, (dn, dc) in enumerate(DELIMITERS):
        qn, qc = QUOTES[j % 2]
        nn, nc = NEWLINES[j % 3]
        fname = "text-%s-%s-%s-backslash" % (dn, qn, nn)
        d = Dialect(dc, qc, nc, j % 2 == 0, escape="backslash")
        files.append((fname, d, "utf8", False, (lambda f, d: lambda: text_file(f, d, "utf8", "minimal", body=(1000, 20000)))(fname, d)))
    for name in ADVERSARIAL:
        files.append((name, None, None, True, (lambda n: lambda: adversarial(n))(name)))
    for name in EXPORTS:
        files.append((name, None, None, False, (lambda n: lambda: export(n))(name)))
    return files


# Dirty files: short-profile records with one error put into some of them,
# and what validating them against their schema must find (.expect.json),
# worked out here as the errors are made. Each error is one of these, a
# cell's (counted against its column) or a row's (counted against every
# column, and the row's cells not looked at).
INJECTIONS = [
    ("id", "12a"),
    ("id", None),
    ("id", "99999999999999999999"),
    ("code", "OPEN"),
    ("amount", "1234567890123.45"),
    ("amount", "1.234"),
    ("amount", "12,50"),
    ("ratio", "abc"),
    ("flag", "maybe"),
    ("created", "2024-02-30"),
    ("updated", "3 days ago"),
    ("name", "x" * 60),
    ("name", "caf\udce9"),
    ("*", "short"),
    ("*", "long"),
    ("*", "bad_quote"),
]

DIRTY = [
    ("dirty-comma-dq-lf-h-utf8", Dialect(",", '"', "\n", True), "utf8", None),
    ("dirty-tab-sq-crlf-h-latin1", Dialect("\t", "'", "\r\n", True), "latin1", None),
    ("dirty-pipe-noquote-lf-nh-utf8", Dialect("|", None, "\n", False), "utf8", None),
    ("dirty-semicolon-dq-cr-h-utf8-bom", Dialect(";", '"', "\r", True), "utf8-bom", None),
    ("dirty-comma-dq-lf-h-missing-column", Dialect(",", '"', "\n", True), "utf8", "flag"),
    ("dirty-comma-dq-crlf-h-quote-all", Dialect(",", '"', "\r\n", True), "utf8", None),
]

# A dirty file whose every field is quoted: a quote inside one, not doubled,
# breaks its record under '"', and reading every quote as data breaks none,
# so the sniffer must still take '"' (card t24). Its first injection is that
# quote, inside the sniffer's first 32 records, and no name in it holds the
# delimiter, so the reading that ignores quotes parses all of those.
DIRTY_POLICY = {"dirty-comma-dq-crlf-h-quote-all": "all"}


def dirty_file(fname, d, encoding, missing):
    rng = Rng(fname)
    columns = [
        {"name": "id", "type": "int64", "nullable": False},
        {"name": "code", "type": "enum", "values": CODES},
        {"name": "amount", "type": "decimal", "precision": 12, "scale": 2},
        {"name": "ratio", "type": "float64"},
        {"name": "flag", "type": "bool"},
        {"name": "created", "type": "date", "format": "%Y-%m-%d"},
        {"name": "updated", "type": "timestamp", "format": "%Y-%m-%d %H:%M:%S"},
        {"name": "name", "type": "string", "max_len": 40},
    ]
    names = [c["name"] for c in columns]
    kinds = ["n", "s", "n", "n", "n", "n", "n", "s"]
    # The file's columns: the schema's, less the one it is missing.
    keep = [i for i, n in enumerate(names) if n != missing]
    w = Writer(d, encoding, DIRTY_POLICY.get(fname, "minimal"))
    if d.header:
        w.record([names[i] for i in keep], ["h"] * len(keep))
    stats = {n: {"mismatches": 0, "nulls": 0} for n in names}
    rejected = []
    rows = 60
    unquoted_special = [5 * k + 2 for k in range(6)]
    quote_all = fname in DIRTY_POLICY
    shift = len(INJECTIONS) - 1 if quote_all else rng.below(len(INJECTIONS))
    injected = 0
    for i in range(rows):
        line = i + (2 if d.header else 1)
        cents = rng.between(-500000, 2000000)
        values = [
            str(i + 1),
            rng.choice(CODES),
            "%s%d.%02d" % ("-" if cents < 0 else "", abs(cents) // 100, abs(cents) % 100),
            None if rng.chance(1, 8) else "%.4f" % (rng.below(10**4) / 10**4),
            rng.choice(["true", "false"]),
            date(rng),
            date(rng) + " %02d:%02d:%02d" % (rng.below(24), rng.below(60), rng.below(60)),
            # Some names need their quotes, so the file's quote is the one
            # the sniffer settles: one nothing needs reads as data. An
            # unquoted file opens quotes it never closes, as the clean ones do.
            name(rng, d, d.quote is not None and i % 5 == 1 and not quote_all).replace("'", "").replace('"', ""),
        ]
        if d.quote is None and i in unquoted_special:
            values[-1] = unclosed(rng, unquoted_special, i)
        col, bad = (None, None)
        if missing is None and i % 4 == 3:
            col, bad = INJECTIONS[(shift + injected) % len(INJECTIONS)]
            injected += 1
            # Errors some files cannot hold: an invalid byte in Latin-1 (every
            # byte is one), a broken quote where nothing is quoted.
            if (bad == "caf\udce9" and encoding == "latin1") or (bad == "bad_quote" and d.quote is None):
                col, bad = ("ratio", "1.2.3")
        raw = None
        if col == "*":
            if bad == "short":
                values = values[:-1]
            elif bad == "long":
                values = values + ["extra"]
            else:
                raw = "%sBad%s quote" % (d.quote, d.quote)
                values[-1] = raw
            for n in names:
                if n != missing:
                    stats[n]["mismatches"] += 1
            rejected.append(line)
        else:
            if col is not None:
                values[names.index(col)] = bad
                stats[col]["mismatches"] += 1
                rejected.append(line)
            for n, v in zip(names, values):
                if n != missing and v is None and n != "id":
                    stats[n]["nulls"] += 1
        out = [values[j] for j in keep if j < len(values)] + values[len(names):]
        w.record(out, kinds, raw_last=raw)
    expect = {
        "result": "fail",
        "rows": rows,
        "rows_rejected": len(rejected),
        "rejected_sample": rejected[:10],
        "columns": [{"name": n, "mismatches": stats[n]["mismatches"], "nulls": stats[n]["nulls"]} for n in names],
        "structural": ["the schema's column '%s' is not in the header" % missing] if missing else [],
    }
    return w, columns, expect




def dumps(obj):
    return json.dumps(obj, indent=2, sort_keys=False, ensure_ascii=True) + "\n"


def main(argv):
    args = argv[1:]
    check = manifest = None
    out_dir = None
    while args:
        a = args.pop(0)
        if a == "--check":
            check = args.pop(0)
        elif a == "--manifest":
            manifest = args.pop(0)
        elif out_dir is None:
            out_dir = a
        else:
            sys.exit("usage: corpus.py OUT_DIR [--check MANIFEST | --manifest MANIFEST]")
    if out_dir is None:
        sys.exit("usage: corpus.py OUT_DIR [--check MANIFEST | --manifest MANIFEST]")
    csv.field_size_limit(1 << 30)
    os.makedirs(out_dir, exist_ok=True)
    written = {}

    def put(name, data):
        if isinstance(data, str):
            data = data.encode()
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(data)
        written[name] = hashlib.sha256(data).hexdigest()

    index = []
    for fname, d, encoding, adv, build in plan():
        w, columns = build()
        d, encoding = w.d, w.encoding
        bom = w.out.startswith(b"\xef\xbb\xbf")
        raw = w.check()
        w.check_unique(raw.decode("utf-8-sig" if w.codec == "utf-8" else w.codec), adv)
        put(fname + ".csv", raw)
        put(
            fname + ".dialect.json",
            dumps(
                {
                    "delimiter": d.delimiter,
                    "quote": d.quote,
                    "escape": d.escape,
                    "newline": d.newline_name(),
                    "header": d.header,
                    "encoding": w.encoding,
                    "bom": bom,
                    "adversarial": adv,
                }
            ),
        )
        put(fname + ".schema.json", dumps({"columns": columns, "nulls": [""], "match": "name" if d.header else "position"}))
        put(fname + ".fields", "".join("%d %d %d %d %d\n" % f for f in w.fields))
        index.append(fname + ".csv")
    put("index.txt", "".join(n + "\n" for n in index))

    dirty = []
    for fname, d, encoding, missing in DIRTY:
        w, columns, expect = dirty_file(fname, d, encoding, missing)
        put(fname + ".csv", bytes(w.out))
        put(
            fname + ".dialect.json",
            dumps(
                {
                    "delimiter": d.delimiter,
                    "quote": d.quote,
                    "escape": d.escape,
                    "newline": d.newline_name(),
                    "header": d.header,
                    "encoding": w.encoding,
                    "bom": w.out.startswith(b"\xef\xbb\xbf"),
                    "adversarial": False,
                }
            ),
        )
        put(fname + ".schema.json", dumps({"columns": columns, "nulls": [""]}))
        put(fname + ".expect.json", dumps(expect))
        dirty.append(fname + ".csv")
    put("dirty.txt", "".join(n + "\n" for n in dirty))

    lines = "".join("%s  %s\n" % (written[n], n) for n in sorted(written))
    if manifest:
        with open(manifest, "w") as f:
            f.write(lines)
    if check:
        with open(check) as f:
            want = f.read()
        if want != lines:
            want_map = dict(l.split("  ", 1)[::-1] for l in want.splitlines())
            got_map = dict(l.split("  ", 1)[::-1] for l in lines.splitlines())
            for n in sorted(set(want_map) | set(got_map)):
                if want_map.get(n) != got_map.get(n):
                    print("corpus: %s differs from %s" % (n, check), file=sys.stderr)
            sys.exit("corpus: output does not match %s; rerun with --manifest if the change is meant" % check)
    # Under --check, as the build runs it, a pass is silent: zig build shows
    # a step's stderr under "failed command:", even when it exits 0.
    if not check:
        total = sum(os.path.getsize(os.path.join(out_dir, n)) for n in index)
        print("corpus: %d data files, %.1f MB, in %s" % (len(index), total / 1e6, out_dir), file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv)
