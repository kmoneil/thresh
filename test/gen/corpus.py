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
files built to make a sniffer guess wrong.

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
        self.codec = "latin-1" if encoding == "latin1" else "utf-8"
        self.policy = policy  # "minimal": quote when needed; "strings": quote every string
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
                quoted = self.needs_quotes(v) or (
                    self.policy == "strings" and kind == "s" and values[col] is not None
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

    def check(self):
        """Reads the file back with csv, and every field from its offsets."""
        d = self.d
        raw = bytes(self.out)
        text = raw.decode("utf-8-sig" if self.codec == "utf-8" else "latin-1")
        kw = {"delimiter": d.delimiter, "strict": True}
        if d.quote is None:
            kw.update(quoting=csv.QUOTE_NONE, quotechar=None)
        elif d.escape == "backslash":
            kw.update(quotechar=d.quote, doublequote=False, escapechar="\\")
        else:
            kw.update(quotechar=d.quote, doublequote=True)
        got = list(csv.reader(io.StringIO(text, newline=""), **kw))
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
]


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
    w = Writer(d, encoding, "minimal")
    if d.header:
        w.record([names[i] for i in keep], ["s"] * len(keep))
    stats = {n: {"mismatches": 0, "nulls": 0} for n in names}
    rejected = []
    rows = 60
    unquoted_special = [5 * k + 2 for k in range(6)]
    shift = rng.below(len(INJECTIONS))
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
            name(rng, d, d.quote is not None and i % 5 == 1).replace("'", "").replace('"', ""),
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
        d, encoding = w.d, ("latin1" if w.codec == "latin-1" else encoding or "utf8")
        bom = w.out.startswith(b"\xef\xbb\xbf")
        raw = w.check()
        w.check_unique(raw.decode("utf-8-sig" if w.codec == "utf-8" else "latin-1"), adv)
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
                    "encoding": "latin1" if w.codec == "latin-1" else "utf8",
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
                    "encoding": "latin1" if w.codec == "latin-1" else "utf8",
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
    total = sum(os.path.getsize(os.path.join(out_dir, n)) for n in index)
    print("corpus: %d data files, %.1f MB, in %s" % (len(index), total / 1e6, out_dir), file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv)
