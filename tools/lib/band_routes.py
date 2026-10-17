"""The iOS synthesized table's band report (docs/traps.md, the band placed
under the core's newer index).

window_moved's applies reach the tier's children through the apply queue, so
the core's band leads them. varied.steps goes red only when a report lands in
that gap under load, one run in many, so this reads the wall: the core's band
is published only when the children's own first row IS its first, and nothing
is measured, reported or re-parked from a placement that did not place those
children under their own index."""

from content_type_routes import flat
from kaya_gate import ROOT
from reveal_routes import blocks

SWIFT = "swift/KayaSwiftUI.swift"
REPORT = "private func report(_ node: KayaNode) {"
LAYOUT = "private struct KayaTableLayout: Layout {"
TABLE = "private struct KayaSynthesizedTable: View {"
ASK = "let drawnIndex = drawnRow.flatMap { KayaHost.windowRowOf(node.id, $0) }"
BAND = ": drawnIndex == Int(geometry.first) && node.children.count == Int(geometry.count)"
PUBLISH = "if childrenAreBand {"
PLACED = "let placementIsChildren = placement.bandRow == drawnRow\n&& (drawnRow == nil || drawnIndex == placement.bandFirst)"
HOLD = "guard childrenAreBand, placementIsChildren else {"
AFTER = [
    "measure(node, first: drawnFirst, pitches: pitches)",
    "KayaHost.windowMoved(node.id, claim.first, claim.count)",
    "repark(",
    "visible = measured",
]


def findings(src):
    out = []
    report = blocks(src, REPORT)
    if len(report) != 1:
        return [f"band report: {REPORT} is defined {len(report)} times in {SWIFT}, wanted once"]
    body = flat(report[0])
    for label, need in (
        ("the children's own index is asked of the core", ASK),
        ("the children are the core's band only at its first and count", BAND),
        ("the placement must have placed these children under their index", PLACED),
    ):
        if flat(need) not in body:
            out.append(f"band report: {label} no longer holds — the report lacks {need.splitlines()[0]}")
    publish = body.find(flat(PUBLISH + "\nlet band = Int(geometry.first)"))
    first_publish = body.find(flat("publish(\nwindowed: true"))
    if publish < 0 or first_publish < publish:
        out.append("band report: the core's band is published before the children are it")
    hold = body.find(flat(HOLD))
    if hold < 0:
        out.append("band report: nothing holds the report while the children or the placement lag")
    else:
        for call in AFTER:
            at = body.find(flat(call))
            if at < 0 or at < hold:
                out.append(f"band report: {call.split('(')[0]} runs before the lag is held")
    layout = blocks(src, LAYOUT)
    if len(layout) != 1 or flat("placement.bandFirst = first\nplacement.bandRow = firstRow") not in flat(layout[0]):
        out.append("band report: the layout no longer records which row it placed first")
    table = blocks(src, TABLE)
    if len(table) != 1 or flat("firstRow: node.children.first?.id") not in flat(table[0]):
        out.append("band report: the table no longer hands the layout its first child")
    return out


def run(g):
    src = (ROOT / SWIFT).read_text(encoding="utf-8")
    g.counted("band report clauses held", 3 + 1 + 1 + len(AFTER) + 2, floor=9)
    for line in findings(src):
        g.finding(line)
    cuts = [
        ("the core's band published whatever the children are, as shipped",
         r"if childrenAreBand \{\n(\s+let band = Int\(geometry\.first\))", r"do {\n\1",
         "published before the children are it"),
        ("a placement of other children read",
         r"guard childrenAreBand, placementIsChildren else \{", "guard childrenAreBand else {",
         "nothing holds the report"),
        ("the children's index taken from the core's band",
         r"let drawnIndex = drawnRow\.flatMap \{ KayaHost\.windowRowOf\(node\.id, \$0\) \}",
         "let drawnIndex: Int? = Int(geometry.first)", "the children's own index is asked"),
        ("the layout's first row unrecorded",
         r"\n\s+placement\.bandRow = firstRow", "", "records which row it placed first"),
    ]
    for label, pattern, repl, want in cuts:
        broken = g.doctor(f"band report: {label}", src, pattern, repl)
        g.negative(f"band report: {label}", lambda broken=broken: findings(broken), want=want)
