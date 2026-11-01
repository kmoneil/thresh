"""Everything about a file in one bounded document, and with
shapes_only=True none of its values: digits become 9, letters a. Hand it
to an AI before it writes code for the file, or paste it into an issue.

    cd examples && python python/for_an_ai.py
"""

import json

import threshio

description = threshio.describe("data/harvest_dirty.csv", shapes_only=True)
print(description, "| inferred:", description.inferred, "| encoding:", description.encoding)

# A rejected row, as its shape.
print(description.rejected_lines[0].text)

# Each column: the type inferred, and the shape most of its values have.
for column in description.columns:
    print(f"  {column.name:<12} {column.type:<8} {column.stats.shapes[0].value}")

# The whole of it is JSON, bounded whatever the file's size: each list's
# cap is in "limits".
document = json.loads(description.to_json())
print(sorted(document))
print(document["limits"]["rejected_lines"], "rejected lines at most")

# prompt = "Write a loader for this file.\n\n" + description.to_json()
