"""docs/number-field-plan.md §10; called by check-sugar-surface."""

import re

from kaya_gate import ROOT, Gate


ROWS = [
    ("rust live", "crates/kaya/src/app.rs", r"pub fn format\(self, format: crate::fmt::NumberFormat\)", "format"),
    ("rust update", "crates/kaya/src/app.rs", r"pub fn number_format\(&mut self, widget: WidgetId, format: crate::fmt::NumberFormat\)", "number_format"),
    ("rust template", "crates/kaya/src/app.rs", r"pub fn format\(&mut self, node: TemplateNodeId, format: crate::fmt::NumberFormat\)", "format"),
    ("python constructor", "bindings/python/kaya/__init__.py", r"def number_field\([^)]*\bformat: NumberFormat", "format"),
    ("python shared setter", "bindings/python/kaya/__init__.py", r"def number_format\(self: H, format: NumberFormat\)", "number_format"),
    ("go live", "bindings/go/app.go", r"func \(w Widget\) Format\(format NumberFormat\)", "Format"),
    ("go update", "bindings/go/app.go", r"func \(tx \*Tx\) SetFormat\(w Widget, format NumberFormat\)", "SetFormat"),
    ("go template", "bindings/go/app.go", r"func \(t \*Tpl\) SetFormat\(n Node, format NumberFormat\)", "SetFormat"),
    ("csharp live", "bindings/csharp/KayaApp.cs", r"public Widget NumberField\([^)]*NumberFormat\? format = null", "format"),
    ("csharp template constant", "bindings/csharp/KayaApp.cs", r"public Node NumberField\(double value[^)]*NumberFormat\? format = null", "format"),
("csharp template signal", "bindings/csharp/KayaApp.cs", r"public Node NumberField\(Signal value[^)]*NumberFormat\? format = null", "format"),
("csharp template field", "bindings/csharp/KayaApp.cs", r"public Node NumberField\(Field<double> value[^)]*NumberFormat\? format = null", "format"),
    ("csharp parse validation", "bindings/csharp/KayaFmt.cs", r"public static long\? ParseTimecode\([^)]*\)\s*\{\s*(?:_ = )?Timecode\(0, rate\);", "Timecode"),
    ("java live", "bindings/java/dev/kaya/KayaApp.java", r"public Widget format\(NumberFormat format\)", "format"),
    ("java template", "bindings/java/dev/kaya/KayaApp.java", r"public void setFormat\(Node n, NumberFormat format\)", "setFormat"),
    ("swift live", "bindings/swift/KayaApp.swift", r"func numberField\(\s*value: Double[^)]*format: KayaNumberFormat", "format"),
    ("swift template constant", "bindings/swift/KayaApp.swift", r"func numberField\(\s*value: Double[^)]*format: KayaNumberFormat", "format"),
    ("swift template signal", "bindings/swift/KayaApp.swift", r"func numberField\(\s*value s: KayaSignal[^)]*format: KayaNumberFormat", "format"),
    ("swift template field", "bindings/swift/KayaApp.swift", r"func numberField\(\s*value f: KayaField<Double>[^)]*format: KayaNumberFormat", "format"),
    ("ocaml live", "bindings/ocaml/kaya_app.ml", r"^let number_field [\s\S]{0,400}?\?\(format = Number\)", "format"),
    ("ocaml template", "bindings/ocaml/kaya_app.ml", r"^  let number_field [\s\S]{0,400}?\?\(format = Number\)", "format"),
    ("haskell live", "bindings/haskell/KayaApp.hs", r"^  NumberFormat :: NumberFormat -> Attr 'LeafW", "NumberFormat"),
    ("haskell template", "bindings/haskell/KayaApp.hs", r"^  TplNumberFormat :: NumberFormat -> TplAttr", "TplNumberFormat"),
    ("js constructor", "bindings/js/kaya/index.ts", r"NumberFieldOptions = [^\n]*\bformat\?: NumberFormat", "format"),
    ("js shared setter", "bindings/js/kaya/index.ts", r"numberFormat\(format: NumberFormat\): this", "numberFormat"),
]


def region(text, label):
    if not label.startswith("swift "):
        return 0, len(text)
    anchor = "public final class " + ("KayaAppTx" if label == "swift live" else "KayaTpl") + " {"
    start = text.find(anchor)
    if start < 0:
        return 0, 0
    start = text.index("{", start)
    depth = 0
    for end in range(start, len(text)):
        if text[end] == "{":
            depth += 1
        elif text[end] == "}":
            depth -= 1
            if depth == 0:
                return start, end + 1
    return 0, 0


def findings(texts, rows=ROWS):
    if len(rows) < 25:
        return ["timecode format census read fewer than 25 surfaces"]
    return [f"timecode format {label} absent in {rel}"
            for label, rel, pattern, _token in rows
            if not re.search(pattern, texts[rel][slice(*region(texts[rel], label))], re.M)]


def run():
    gate = Gate("check-timecode-surface")
    texts = {rel: (ROOT / rel).read_text(encoding="utf-8") for _, rel, _, _ in ROWS}
    baseline = findings(texts)
    for problem in baseline:
        gate.fail(problem)
    if baseline:
        gate.verdict("timecode format surface")
    for label, rel, pattern, token in ROWS:
        start, end = region(texts[rel], label)
        source = texts[rel][start:end]
        count = len(re.findall(pattern, source, re.M))
        broken_region = gate.doctor(label, source, pattern,
                             lambda m: m.group(0).replace(token, "kayaMissingTimecodeFormat"),
                             want=count, flags=re.M)
        broken = texts[rel][:start] + broken_region + texts[rel][end:]
        gate.negative(label, lambda: findings({**texts, rel: broken}),
                      want=f"timecode format {label} absent")
    gate.negative("empty reader", lambda: findings(texts, []), want="fewer than 25")
    gate.negatives_ran(len(ROWS) + 1)
    gate.verdict(f"{len(ROWS)} timecode format surfaces")
