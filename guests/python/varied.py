"""Row windowing's VARIABLE-HEIGHT scene (docs/virtualization-plan.md
§5): 300 rows whose heights differ by STRUCTURE, not by typography.

Every row's template holds an inner For of k lines, k = 1..5 from the
row's own index — so the same row is the same number of lines on every
platform, while its pixel height is whatever that platform's text
metrics make it. That is what lets one scene drive the correction path
deterministically: the FIRST row is 2 lines, the SECOND is 5, so the
presumption taken from row 0 is wrong by row 1 and the For moves to the
corrected path immediately and permanently (plan §2).

Nothing here is windowing code. There is no height to declare, no
prototype to nominate and no callback to implement; this guest inserts
1,200 rows of data and reads none of them back.

AND ITS INNER LISTS ARE WRITTEN TO UNREALIZED ROWS: the table is seeded
at a screenful, so every row past it has no widgets while this build
runs and `lines.at("r200")` addresses model data alone (the ruling that
closed docs/deferred.md's nested-collection-instance entry).

Build the library first (cargo build), then:
    KAYA_SELFTEST=varied python3 guests/python/varied.py
"""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Row:
    # The row's key, carried as a field so the row's OWN inner For can be
    # addressed by it: the copies of one template node share a node id, so
    # a constant a11y_id would name three hundred containers at once.
    key: str
    name: str


@dataclass
class Line:
    text: str


N = 300


def lines_in(index):
    """k for row `index`: 1..5, on a period of ELEVEN.

    The period is deliberately coprime with the round indices a scene
    scrolls to: `(index * 3 + 1) % 5` gave every multiple of five the
    same height, so r100, r150 and r200 were all the same two lines and
    the scene would have sampled one height at every stop.

    ROW 0 IS NOT THE MODE either. A rule whose first row happened to be
    the common height would leave the presumption right for most rows
    and the corrected path barely exercised; here row 0 is 1 line and
    row 1 is 3, so the very first verification fails and the For is on
    the corrected path from its second realized row onward.
    """
    return 1 + (index * 7 % 11) % 5


app = kaya.App()

with app.window(title="varied", width=520, height=600):
    census = kaya.signal("")
    with kaya.row():
        with kaya.column(grow=1, align="stretch"):
            kaya.label(bind=census)  # label#0
            rows = kaya.collection(Row)
            # A ONE-COLUMN TABLE, not a plain For: §6.2 windows the mac
            # NATIVE TABLE tier, and a variable-height row exercises the
            # delegate-height path exactly where correction lives. The
            # plain-For band joins at breadth (§6.3).
            for row in rows.columns("Row", a11y_id="varied", grow=1):
                # The table wall wants a Row of one cell; the cell is
                # the variable-height column of lines.
                with kaya.row(), kaya.column(align="stretch"):
                    # The row's ONE direct label: expect_rows reads a
                    # row's own cells, so the band reads out as a list
                    # of row identities WITH their line counts — band
                    # membership by identity, which is the fact the
                    # correction may not disturb.
                    kaya.label(bind=row.name)
                    lines = kaya.collection(Line)
                    # The inner container's automation key is THE ROW'S OWN
                    # KEY, so a scene can read one row's lines
                    # (`expect_order column@r200 ...`) whether that row was
                    # realized at build time or arrived with the band.
                    for line in lines.rows(a11y_id=row.key):
                        kaya.label(bind=line.text)
    for i in range(N):
        key = f"r{i:03d}"
        rows.insert(key, Row(key=key, name=f"{key} x{lines_in(i)}"))
        inner = lines.at(key)
        for j in range(lines_in(i)):
            inner.insert(f"l{j}", Line(text=f"{key} line {j + 1}"))
    census.set(f"{N} rows, {sum(lines_in(i) for i in range(N))} lines")

sys.exit(app.run())
