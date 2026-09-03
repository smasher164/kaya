"""Row windowing's VARIABLE-HEIGHT scene (docs/virtualization-plan.md §5):
row 0 is 2 lines and row 1 is 5, so the correction path runs at once."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Row:
    # A field, because copies of one template node share a node id and a
    # constant a11y_id would name three hundred containers at once.
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
            # A ONE-COLUMN TABLE: this windows the mac NATIVE TABLE tier.
            for row in rows.columns("Row", a11y_id="varied", grow=1):
                with kaya.row(), kaya.column(align="stretch"):
                    # The row's ONE direct label: expect_rows reads its cells.
                    kaya.label(bind=row.name)
                    lines = kaya.collection(Line)
                    # Keyed by THE ROW'S OWN KEY, so a scene can read one
                    # row's lines whether or not it was realized.
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
