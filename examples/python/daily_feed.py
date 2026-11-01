"""A feed that arrives every day: the schema and dialect of one delivery,
and each later one checked against them.

    cd examples && python python/daily_feed.py
"""

import threshio

# Monday's delivery sets the contract: its schema, and its dialect pinned
# so a later file is never read another way.
schema = threshio.infer("data/monday.csv").schema
pins = threshio.sniff("data/monday.csv").dialect.options
print(pins)

# Tuesday's has a column Monday's did not. It passes, and says so.
report = threshio.validate("data/tuesday.csv", schema, **pins)
print(report, report.warnings)

# Under strict, a column the schema does not know fails the file.
report = threshio.validate("data/tuesday.csv", schema, strict=True, **pins)
print(report)
for problem in report.problems:
    print(f"  {problem.code}: {problem.message}")

# A schema from both days would fail Monday's file, and infer says so.
week = threshio.infer("data/monday.csv", "data/tuesday.csv", jobs=1)
print("one schema for the week:", week.ok)
for problem in week.problems:
    print(f"  {problem.code}: {problem.message}")
