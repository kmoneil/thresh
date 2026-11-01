"""A delivery with what goes wrong in a real feed: a decimal comma, a day
that does not exist, a yes/no column saying "maybe", a key left empty, and
a row with one field too many. thresh keeps the good rows apart from the
bad, and says for each bad one its line and why.

    cd examples && python python/bad_delivery.py
"""

import threshio

# The schema of a clean delivery, and today's file against it.
schema = threshio.infer("data/harvest.csv").schema
report = threshio.validate("data/harvest_dirty.csv", schema)
print(report)

# Each rejected row: the line it is on, what was wrong, and the row.
for line in report.rejected_lines:
    why = "; ".join(f"{e.column or 'the row'}: {e.code}" for e in line.errors)
    print(f"  line {line.row}  {why}")
    print(f"    {line.text}")

# Per column: how much of it fits, and the first value that does not.
for column in report.columns:
    if column.mismatches:
        first = column.samples[0]
        print(f"  {column.name}: {column.conformance:.1%} fit; {first.value!r} on line {first.row} is {first.code}")

# The empty key passed: an inferred column takes nulls. Say it may not,
# and it is caught too.
strict = schema.with_column("lug_id", nullable=False)
print(threshio.validate("data/harvest_dirty.csv", strict))

# In a pipeline, stop before using a file that does not fit. The
# exception carries the whole report.
try:
    threshio.check("data/harvest_dirty.csv", strict)
except threshio.FileFailed as e:
    print("stopped:", e)
    print("rows set aside:", e.report.rejected_sample)
