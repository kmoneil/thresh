"""Writes the example files: an invented orchard's harvest, one messy
shape a file. Every name and value is made up.

    python3 -I examples/data/make.py
"""

import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
CULTIVARS = ["Starfall", "Brookwood", "Ember Pip", "Quillon", "Marrowdew"]
WORDS = ["windfall", "late pick", "frost", "ladder 2", "shade side", "small", "sunburn"]


def rows(seed, n, start=1):
    r = random.Random(seed)
    out = []
    for i in range(start, start + n):
        out.append({
            "lug_id": str(i),
            "picked_on": "2026-09-%02d" % (1 + i % 28),
            "orchard_row": "R%02d" % (1 + i % 12),
            "lug_kg": "%d.%d" % (r.randint(14, 22), r.randint(0, 9)),
            "cultivar": r.choice(CULTIVARS),
            "bruised": r.choice(["true", "false", "false", "false"]),
            "remark": r.choice(WORDS + ["", "", ""]),
        })
    return out


COLUMNS = ["lug_id", "picked_on", "orchard_row", "lug_kg", "cultivar", "bruised", "remark"]


def write(name, text, encoding="utf-8"):
    with open(os.path.join(HERE, name), "wb") as f:
        f.write(text.encode(encoding))


def csv(cols, data, delim=",", newline="\n"):
    lines = [delim.join(cols)]
    for d in data:
        lines.append(delim.join('"%s"' % d[c] if delim in d[c] else d[c] for c in cols))
    return newline.join(lines) + newline


# A clean file: the baseline every other one departs from.
write("harvest.csv", csv(COLUMNS, rows(1, 40)))

# The same columns, with what goes wrong in a real feed put into it.
dirty = rows(2, 30)
dirty[3]["lug_kg"] = "18,5"          # a decimal comma
dirty[7]["picked_on"] = "2026-09-31"  # no such day
dirty[11]["bruised"] = "maybe"
dirty[15]["lug_id"] = ""              # a key left empty
text = csv(COLUMNS, dirty)
text = text.replace("\n%s," % dirty[20]["lug_id"], "\n%s,extra," % dirty[20]["lug_id"], 1)  # one field too many
write("harvest_dirty.csv", text)

# A header one name short of its rows: the export added a column and not
# its name.
short = csv(["lug_id", "picked_on", "lug_kg"], [])
for d in rows(3, 30):
    short += "|".join([d["lug_id"], d["picked_on"], d["orchard_row"], d["lug_kg"]]) + "\n"
write("header_short.csv", short.replace(",", "|"))

# A header with a column left unnamed.
data = rows(4, 30)
lines = ["lug_id,picked_on,,lug_kg"]
for d in data:
    lines.append(",".join([d["lug_id"], d["picked_on"], d["orchard_row"], d["lug_kg"]]))
write("unnamed.csv", "\n".join(lines) + "\n")

# Fixed-length records: every value padded with spaces, and every record
# padded to 80 bytes.
lines = ["%-8s|%-10s|%-6s|%s" % ("lug_id", "picked_on", "lug_kg", "cultivar")]
for d in rows(5, 30):
    rec = "%-8s|%-10s|%-6s|%s" % (d["lug_id"], d["picked_on"], d["lug_kg"], d["cultivar"])
    lines.append(rec.ljust(80))
write("padded.txt", "\n".join(lines) + "\n")

# A free-text column with commas nobody quoted.
lines = ["lug_id,picked_on,remark,lug_kg"]
for i, d in enumerate(rows(6, 30)):
    remark = ", ".join(random.Random(i).sample(WORDS, 1 + i % 3))
    lines.append(",".join([d["lug_id"], d["picked_on"], remark, d["lug_kg"]]))
write("remarks.csv", "\n".join(lines) + "\n")

# Two exports joined: the second's header comes again, in other case.
first, second = rows(7, 20), rows(8, 20, start=21)
text = csv(COLUMNS[:4], first) + ",".join(c.upper() for c in COLUMNS[:4]) + "\n"
text += "\n".join(",".join(d[c] for c in COLUMNS[:4]) for d in second) + "\n"
write("joined.csv", text)

# A Windows export: Windows-1252 bytes, not UTF-8.
data = rows(9, 30)
for d in data[::4]:
    d["remark"] = "picker’s note: café row"
write("windows.csv", csv(["lug_id", "lug_kg", "remark"], data, newline="\r\n"), encoding="cp1252")

# UTF-16 with a byte order mark, as some exporters write.
write("utf16.csv", csv(["lug_id", "cultivar", "lug_kg"], rows(10, 20)), encoding="utf-16")

# An extract with nothing in it: the header and no final newline.
write("empty_extract.txt", "lug id|picked on|orchard row|lug kg")

# Two days' deliveries of one feed; the second added a column.
write("monday.csv", csv(COLUMNS[:4], rows(11, 20)))
write("tuesday.csv", csv(COLUMNS[:4] + ["brix"], [dict(d, brix="%d.%d" % (11 + i % 4, i % 10)) for i, d in enumerate(rows(12, 20))]))
