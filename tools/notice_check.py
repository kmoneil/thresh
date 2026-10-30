"""Fails when NOTICE no longer carries a dependency's NOTICE word for word.

    python3 -I tools/notice_check.py NOTICE DEPENDENCY_NOTICE...

Apache-2.0 asks a distribution to carry the attribution notices of what it
includes; thresh compiles in dateparsa, whose NOTICE also carries the
Unicode License for its CLDR data. Upgrading the dependency can change
that text, and this says so instead of shipping the old one.
"""

import sys

if len(sys.argv) < 3:
    sys.exit(__doc__)
ours = open(sys.argv[1], encoding="utf-8").read()
for dep in sys.argv[2:]:
    if open(dep, encoding="utf-8").read().strip() not in ours:
        sys.exit("notice_check: NOTICE does not carry %s as it is now; copy it in" % dep)
