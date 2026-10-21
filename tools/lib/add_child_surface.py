"""docs/media-player-plan.md M16 (28); called by check-sugar-surface.

Each row is one binding's SUGAR for adding children to a container that is
already built, read out of that binding's own file: `within`, a block that
reopens the container so everything declared inside joins it after its
existing children. add_child itself is the floor (tools/guest-floor.py refuses
it in a sugar guest), so before this ruling a handler in a sugar guest could
not add a child in any binding; Python and JS had no public way at all."""

import re

from kaya_gate import ROOT, Gate

ROWS = [
    ("rust within", "crates/kaya/src/app.rs",
     r"^    pub fn within<R>\(&mut self, container: WidgetId, body: impl FnOnce\(&mut Self\) -> R\) -> R \{\n        self\.parents\.push\(container\.0\);", "within"),
    ("python within", "bindings/python/kaya/__init__.py", r"^def within\(container: Widget\) -> _Within:", "within"),
    ("python within appends", "bindings/python/kaya/__init__.py",
     r"^class _Within\(_Scope\[\"Widget\"\]\):(?:\n[^\n]*){0,6}?\n        _parents\.append\(self\.handle\.id\)", "_parents"),
    ("js within", "bindings/js/kaya/index.ts", r"^export function within<T = void>\(container: Widget, body: \(container: Widget\) => T\): T \{", "within"),
    ("js within appends", "bindings/js/kaya/index.ts",
     r"^export function within<T = void>\([^\n]*(?:\n[^\n]*){0,10}?\n  _parents\.push\(container\.id\);", "_parents"),
    ("go within", "bindings/go/app.go",
     r"^func \(tx \*Tx\) Within\(container Widget, body func\(\)\) \{\n\ttx\.app\.parents = append\(tx\.app\.parents, container\.id\)", "Within"),
    ("csharp within", "bindings/csharp/KayaApp.cs",
     r"^    public T Within<T>\(Widget container, Func<T> body\)\n    \{\n        App\.Parents\.Add\(container\.Id\);", "Within"),
    ("java within", "bindings/java/dev/kaya/KayaApp.java",
     r"^        public void within\(Widget container, Runnable body\) \{\n            parents\.add\(container\.id\);", "within"),
    ("swift within", "bindings/swift/KayaApp.swift",
     r"^    public func within<R>\(_ container: KayaWidget, _ body: \(\) throws -> R\) rethrows -> R \{\n        app\.childFrames\.append", "within"),
    ("ocaml within", "bindings/ocaml/kaya_app.mli", r"^val within : widget -> \(unit -> widget\) list -> unit", "within"),
    ("ocaml within appends", "bindings/ocaml/kaya_app.ml",
     r"^let within container children = List\.iter \(fun child -> add_child container \(child \(\)\)\) children", "add_child"),
    ("haskell within", "bindings/haskell/KayaApp.hs",
     r"^within :: Widget -> \[Build Widget\] -> Build \(\)\nwithin container children = mapM_ \(>>= addChild container\) children", "within"),
    ("haskell within exported", "bindings/haskell/KayaApp.hs", r"^    within,$", "within"),
]
FLOOR = 11
LANGS = ("rust", "python", "js", "go", "csharp", "java", "swift", "ocaml", "haskell")


def findings(texts, rows=ROWS):
    if len(rows) < FLOOR:
        return [f"add-child census read fewer than {FLOOR} surfaces"]
    out = [f"add-child {label} absent in {rel}"
           for label, rel, pattern, _token in rows if not re.search(pattern, texts[rel], re.M)]
    for lang in LANGS:
        if not any(label.startswith(lang + " ") for label, *_ in rows):
            out.append(f"add-child census holds no row for {lang}")
    return out


def run():
    gate = Gate("check-add-child-surface")
    texts = {rel: (ROOT / rel).read_text(encoding="utf-8") for _, rel, _, _ in ROWS}
    baseline = findings(texts)
    for problem in baseline:
        gate.finding(problem)
    if baseline:
        print("check-add-child-surface: FINDINGS ABOVE")
        return gate.status
    for label, rel, pattern, token in ROWS:
        broken = gate.doctor(label, texts[rel], pattern,
                             lambda m, token=token: m.group(0).replace(token, "kayaCut", 1), flags=re.M)
        gate.negative(label, lambda rel=rel, broken=broken: findings({**texts, rel: broken}),
                      want=f"add-child {label} absent")
    gate.negative("empty reader", lambda: findings(texts, []), want=f"fewer than {FLOOR}")
    withheld = [row for row in ROWS if not row[0].startswith("swift ")]
    gate.negative("a binding's row withheld", lambda: findings(texts, withheld), want="no row for swift")
    gate.negatives_ran(len(ROWS) + 2)
    if gate.status == 0:
        print(f"check-add-child-surface: OK ({len(ROWS)} add-child surfaces in nine bindings)")
    return gate.status
