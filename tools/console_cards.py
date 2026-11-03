"""Draws a page's terminal pictures from its console blocks.

    python3 -I tools/console_cards.py PAGE.md            # write them
    python3 -I tools/console_cards.py PAGE.md --check    # fail if one is stale

A line `<!-- card: docs/assets/NAME.svg -->` in PAGE.md names a picture,
drawn from the first ```console block below it as a terminal window
shows it: the commands, what they print and their exit status, with
pass and fail in colour and, in a file of rejected rows, each row's bad
value and the reason picked out. The path is relative to the page.
tools/examples_check.py runs the block and holds it to what thresh
prints, and --check holds the picture to the block, so a picture shows
what thresh prints today. A throughput figure ("12 MB/s") is left out,
as examples_check leaves it out: it is the machine's, not thresh's.
The SVG is written byte for byte the same from the same block.
"""

import os
import re
import sys

MARKER = re.compile(r"^<!-- card: (\S+\.svg) -->$")

FONT = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"
SIZE = 15  # font size, px
ADVANCE = 9.1  # a character's width at SIZE, the widest of the fonts above
LINE = 23  # line height, px
PAD = 26  # left and right of the text
TOP = 50  # the title bar and the gap under it
MIN_WIDTH = 640

TEXT = "#e7d9b0"
BRIGHT = "#fef3c7"
DIM = "#8a7d62"
GOLD = "#fcd34d"
GREEN = "#4ade80"
RED = "#f87171"
AMBER = "#fbbf24"


def blocks(lines):
    """Each card's path and its console block's lines, fences out."""
    out, want = [], None
    i = 0
    while i < len(lines):
        m = MARKER.match(lines[i].strip())
        if m:
            if want:
                sys.exit("console_cards: %s has no console block before the next card" % want)
            want = m.group(1)
        elif want and lines[i].strip() == "```console":
            j = i + 1
            while j < len(lines) and lines[j].strip() != "```":
                j += 1
            if j == len(lines):
                sys.exit("console_cards: the console block for %s is never closed" % want)
            out.append((want, lines[i + 1 : j]))
            want, i = None, j
        i += 1
    if want:
        sys.exit("console_cards: %s has no console block below it" % want)
    return out


def esc(s):
    """XML text, each space a no-break space: SVG viewers fold runs of
    ordinary ones into one, and thresh lines its output up with two."""
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace(" ", "&#160;")


def fields(line):
    """A CSV line's fields as written, quotes kept, split at commas outside them."""
    out, cur, quoted = [], "", False
    for ch in line:
        if ch == '"':
            quoted = not quoted
        if ch == "," and not quoted:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


def reject_row(line, header):
    """A row of a rejects file: its bad value in red, its line in gold, the reason in amber."""
    f = fields(line)
    if len(f) < len(header):
        return [(line, TEXT, False)]
    # A wide row's own fields run past the header's columns, so its
    # trailers are counted from the end: _row, _errors, _extra.
    row_at, err_at, extra_at = len(f) - 3, len(f) - 2, len(f) - 1
    reason = f[err_at]
    bad = set()
    for part in reason.split(";"):
        col = part.split(":", 1)[0]
        if col == "*":
            bad.add(extra_at)
        elif col in header[:-3]:
            bad.add(header.index(col))
    out = []
    for i, v in enumerate(f):
        if i:
            out.append((",", TEXT, False))
        if i == row_at:
            out.append((v, GOLD, True))
        elif i == err_at:
            out.append((v, AMBER, True))
        elif i in bad:
            out.append((v, RED, True))
        else:
            out.append((v, TEXT, False))
    return out


def spans(line, state):
    """A line as (text, colour, bold) runs, and what it says about the lines after it."""
    if line.startswith("$ "):
        cmd = line[2:]
        state["rejects"] = None
        state["cat_rejects"] = cmd.startswith("cat ") and cmd.endswith(".rejects.csv")
        word, _, rest = cmd.partition(" ")
        return [("$ ", GOLD, True), (word, BRIGHT, True), ((" " + rest) if rest else "", TEXT, False)]
    if re.fullmatch(r"\[exit \d+\]", line):
        return [(line, DIM, False)]
    if state.get("cat_rejects") and state.get("rejects") is None and line.endswith("_row,_errors,_extra"):
        state["rejects"] = fields(line)
        return [(line, DIM, False)]
    if state.get("rejects"):
        return reject_row(line, state["rejects"])
    m = re.match(r"(pass|fail|error)(\s.*)", line)
    if m:
        out = [(m.group(1), GREEN if m.group(1) == "pass" else RED, True)]
        rest = m.group(2)
        r = re.search(r"\b([1-9]\d*) rejected\b", rest)
        if r:
            out += [(rest[: r.start()], TEXT, False), (r.group(0), RED, True), (rest[r.end() :], TEXT, False)]
        else:
            out.append((rest, TEXT, False))
        return out
    if line.startswith("thresh: "):
        return [("thresh: ", DIM, False), (line[8:], AMBER, False)]
    return [(line, TEXT, False)]


def card(body):
    lines = [re.sub(r"  \d+ MB/s$", "", ln) for ln in body]
    width = max(MIN_WIDTH, round(PAD * 2 + ADVANCE * max(len(ln) for ln in lines)))
    height = TOP + LINE * len(lines) + 22
    state = {}
    out = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" role="img">' % (width, height, width, height),
        "  <!-- Drawn by tools/console_cards.py from a console block; edit the block and run it. -->",
        '  <rect width="%d" height="%d" rx="14" fill="#17120b"/>' % (width, height),
        '  <rect x="0.75" y="0.75" width="%g" height="%g" rx="13.5" fill="none" stroke="%s" stroke-opacity="0.35" stroke-width="1.5"/>' % (width - 1.5, height - 1.5, GOLD),
        '  <circle cx="24" cy="21" r="6.5" fill="#f87171"/>',
        '  <circle cx="45" cy="21" r="6.5" fill="#fbbf24"/>',
        '  <circle cx="66" cy="21" r="6.5" fill="#4ade80"/>',
        '  <path d="M0 40.5 H%d" stroke="%s" stroke-opacity="0.18"/>' % (width, GOLD),
        '  <g font-family="%s" font-size="%d">' % (FONT, SIZE),
    ]
    for n, ln in enumerate(lines):
        y = TOP + LINE * (n + 1) - 6
        runs = []
        for text, colour, bold in spans(ln, state):
            if not text:
                continue
            weight = ' font-weight="700"' if bold else ""
            runs.append('<tspan fill="%s"%s>%s</tspan>' % (colour, weight, esc(text)))
        out.append('    <text x="%d" y="%d">%s</text>' % (PAD, y, "".join(runs)))
    out += ["  </g>", "</svg>", ""]
    return "\n".join(out)


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv[1:]
    if len(args) != 1:
        sys.exit(__doc__)
    page = os.path.abspath(args[0])
    lines = open(page, encoding="utf-8").read().split("\n")
    stale = []
    for path, body in blocks(lines):
        target = os.path.join(os.path.dirname(page), path)
        svg = card(body)
        try:
            have = open(target, encoding="utf-8", newline="").read()
        except FileNotFoundError:
            have = None
        if have == svg:
            continue
        if check:
            stale.append(path)
        else:
            with open(target, "w", encoding="utf-8", newline="") as f:
                f.write(svg)
            print("console_cards: wrote %s" % path)
    if stale:
        sys.exit(
            "console_cards: %s no longer matches its console block in %s; run python3 -I tools/console_cards.py %s"
            % (", ".join(stale), os.path.basename(page), args[0])
        )


main()
