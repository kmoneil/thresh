"""When thresh cannot read a file it says why, with a stable code, and
when it knows the fix, the fix: as options to call again with.

    cd examples && python python/follow_the_fix.py
"""

import threshio

# A Windows export, inch marks in a file that never quotes, and a header
# one name short.
for path in ["data/windows.csv", "data/bins.txt", "data/header_short.csv"]:
    first = threshio.infer(path)
    problem = first.files[0].problems[0]
    print(path)
    print(f"  {problem.code}: {problem.message}")
    print(f"  fix: {problem.fix}")
    again = threshio.infer(path, **problem.fix)
    print(f"  then: {again.files[0].result}, {len(again.schema.columns)} columns")

# Commas nobody quoted: thresh will not guess, and knows no fix to offer.
sniff = threshio.sniff("data/remarks.csv")
print(sniff.problems[0].code, sniff.problems[0].fix)

# Told the delimiter and the columns, it reads the file and sets aside
# the rows that do not fit.
columns = threshio.columns("lug_id:int64,picked_on:date,remark:string,lug_kg:decimal(4,1)")
report = threshio.validate("data/remarks.csv", columns, delimiter=",")
print(report)
print(report.rejected_lines[0].text, report.rejected_lines[0].errors)
