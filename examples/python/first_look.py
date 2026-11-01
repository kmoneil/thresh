"""A first look at a file: how it is written, what its columns hold, and
whether its rows fit.

    cd examples && python python/first_look.py
"""

import os
import tempfile

import threshio

# How the file is written, and how sure thresh is.
sniff = threshio.sniff("data/harvest.csv")
print(sniff)

# The schema its values fit, from reading every row.
schema = threshio.infer("data/harvest.csv").schema
for column in schema.columns:
    print(f"  {column.name:<12} {column.type}")

# The file read against it: every value checked.
report = threshio.validate("data/harvest.csv", schema)
print(report)

# What a column's values are like, without reading them yourself.
kg = report.column("lug_kg").stats
print(f"lug_kg: {kg.values} values from {kg.min} to {kg.max} kg, {kg.distinct} distinct")
top = report.column("cultivar").stats.top
print("most picked:", ", ".join(f"{t.value} ({t.count})" for t in top[:3]))

# A schema is JSON: keep it beside your code, and check every delivery
# against it.
with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "harvest.schema.json")
    schema.save(path)
    print(threshio.validate("data/harvest.csv", path))
