"""docs/media-player-plan.md M20 (2); called by check-sugar-surface.

Each row is the widest-width surface in one binding, read out of that
binding's own file: the live zone's setter on a widget handle (a label's and
a container's, since the handle is one type in every binding but Haskell,
whose attribute class row is the live one) and the template zone's on a
node. The wire record reaches every binding through the generator whether or
not a guest can spell it on a label, so only these rows, with the core's own
legality line and the C floor's packer beside them, see one missing."""

import re

from kaya_gate import ROOT, Gate

RS = "crates/kaya/src/app.rs"
CORE = "crates/kaya/src/scene.rs"
C = "bindings/c/kaya_wire.h"
PY = "bindings/python/kaya/__init__.py"
JS = "bindings/js/kaya/index.ts"
GO = "bindings/go/app.go"
CS = "bindings/csharp/KayaApp.cs"
JV = "bindings/java/dev/kaya/KayaApp.java"
SW = "bindings/swift/KayaApp.swift"
ML = "bindings/ocaml/kaya_app.mli"
HS = "bindings/haskell/KayaApp.hs"

# (label, file, pattern, the name inside it a rename cuts)
ROWS = [
    ("core legality", CORE,
     r"Prop::MaxWidth => matches!\(\n\s+kind,\n\s+WidgetKind::Image \| WidgetKind::Slider \| WidgetKind::Label \| WidgetKind::Row \| WidgetKind::Column\n\s+\),",
     "MaxWidth"),
    ("c floor", C, r"static inline void kaya_tx_set_max_width\(KayaTx \*tx, uint64_t widget_id, double max_width\)", "max_width"),
    ("rust live max_width", RS, r"pub fn max_width\(self, points: f64\) -> Self \{", "max_width"),
    ("rust template max_width", RS, r"pub fn max_width\(&mut self, node: TemplateNodeId, points: f64\) \{\n\s+self\.set\(node, Prop::MaxWidth, points\);", "max_width"),
    ("python live max_width", PY, r"def max_width\(self: H, points: float\) -> H:", "max_width"),
    ("python template max_width", PY, r"_records\(\)\.append\(wire\.tx_set_max_width\(self\.id, _bound_value\(\"max_width\", points\)\)\)", "max_width"),
    ("js live max_width", JS, r"^  maxWidth\(points: number\): this \{", "maxWidth"),
    ("js template max_width", JS, r"records\(\)\.push\(wire\.tx_set_max_width\(this\.id, boundValue\(\"maxWidth\", points\)\)\);", "maxWidth"),
    ("go live max_width", GO, r"func \(w Widget\) MaxWidth\(points float64\) Widget \{", "MaxWidth"),
    ("go template max_width", GO, r"func \(t \*Tpl\) SetMaxWidth\(n Node, points float64\) \{", "SetMaxWidth"),
    ("csharp live max_width", CS, r"public void SetMaxWidth\(Widget w, double points\) =>", "SetMaxWidth"),
    ("csharp template max_width", CS, r"public void SetMaxWidth\(Node n, double points\) =>", "SetMaxWidth"),
    ("java live max_width", JV, r"public Widget maxWidth\(double points\) \{", "maxWidth"),
    ("java template max_width", JV, r"public void setMaxWidth\(Node n, double points\) \{\n\s+tx\.emit\(KayaWire\.txSetMaxWidth\(n\.id, points\)\);", "setMaxWidth"),
    ("swift live max_width", SW, r"public func setMaxWidth\(_ w: KayaWidget, _ points: Double\) \{", "setMaxWidth"),
    ("swift template max_width", SW, r"public func setMaxWidth\(_ n: KayaNodeHandle, _ points: Double\) \{", "setMaxWidth"),
    ("ocaml live max_width", ML, r"^val set_max_width : widget -> float -> unit", "set_max_width"),
    ("ocaml template max_width", ML, r"^  val set_max_width : node -> float -> unit", "set_max_width"),
    ("haskell live max_width", HS, r"^  MaxWidth :: Double -> Attr c$", "MaxWidth"),
    ("haskell template max_width", HS, r"^  TplMaxWidth :: Double -> TplAttr$", "TplMaxWidth"),
]
FLOOR = 18
LANGS = ("rust", "python", "js", "go", "csharp", "java", "swift", "ocaml", "haskell")
PARTS = ("live max_width", "template max_width")
FAKE = "kayaFakeWidest"


def findings(texts, rows=ROWS):
    if len(rows) < FLOOR:
        return [f"max_width census read fewer than {FLOOR} surfaces"]
    out = [f"max_width {label} absent in {rel}"
           for label, rel, pattern, _token in rows if not re.search(pattern, texts[rel], re.M)]
    for lang in LANGS:
        mine = [label[len(lang) + 1:] for label, *_ in rows if label.startswith(lang + " ")]
        for part in PARTS:
            if part not in mine:
                out.append(f"max_width census holds no {part} row for {lang}")
    return out


def run():
    """Answers its status, as skin_surface does."""
    gate = Gate("check-maxwidth-surface")
    texts = {rel: (ROOT / rel).read_text(encoding="utf-8") for _, rel, _, _ in ROWS}
    baseline = findings(texts)
    for problem in baseline:
        gate.finding(problem)
    if baseline:
        print("check-maxwidth-surface: FINDINGS ABOVE")
        return gate.status
    fake_rows = [(label, rel, pattern.replace(re.escape(token), FAKE).replace(token, FAKE), token)
                 for label, rel, pattern, token in ROWS]
    fired = sum(1 for line in findings(texts, fake_rows) if " absent in " in line)
    print(f"check-maxwidth-surface: fake names fired {fired}/{len(ROWS)}")
    if fired != len(ROWS):
        gate.finding(f"check-maxwidth-surface: {len(ROWS) - fired} fake-name rows still matched — a pattern "
                     f"that does not depend on its own name holds nothing")
    for label, rel, pattern, token in ROWS:
        count = len(re.findall(pattern, texts[rel], re.M))
        broken = gate.doctor(label, texts[rel], pattern,
                             lambda m, token=token: m.group(0).replace(token, "kayaCut"),
                             want=count, flags=re.M)
        gate.negative(label, lambda rel=rel, broken=broken: findings({**texts, rel: broken}),
                      want=f"max_width {label} absent")
    gate.negative("empty reader", lambda: findings(texts, []), want=f"fewer than {FLOOR}")
    withheld = [row for row in ROWS if row[0] != "ocaml template max_width"]
    gate.negative("a binding's row withheld", lambda: findings(texts, withheld),
                  want="no template max_width row for ocaml")
    gate.negatives_ran(len(ROWS) + 2)
    if gate.status == 0:
        print(f"check-maxwidth-surface: OK ({len(ROWS)} widest-width surfaces: nine bindings, the core and the C floor)")
    return gate.status
