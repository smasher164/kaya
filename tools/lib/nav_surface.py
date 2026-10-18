"""DESIGN.md, Sections: a push and a pop name the surface whose stack they
drive, in all nine. Python, JS and Haskell could reach only the primary's
stack until the media player's playlist pushed inside a phone's section
(docs/media-player-plan.md §6 step 5); called by check-sugar-surface."""

import re

from kaya_gate import ROOT, Gate


ROWS = [
    ("rust push", "crates/kaya/src/app.rs",
     r"pub fn push_entry_in\(&mut self, window: WindowId, entry: WindowId\)[^{]*\{\s*self\.ops\.push\(TxOp::PushEntry \{ window, entry \}\)",
     "window, entry }"),
    ("rust pop", "crates/kaya/src/app.rs",
     r"pub fn pop_entry_in\(&mut self, window: WindowId\) \{\s*self\.ops\.push\(TxOp::PopEntry \{ window \}\)",
     "PopEntry { window }"),
    ("go push", "bindings/go/app.go",
     r"func \(tx \*Tx\) PushEntryIn\(window, id uint64\) EntryRef \{\s*tx\.emit\(TxPushEntry\(window, id\)\)",
     "TxPushEntry(window"),
    ("go pop", "bindings/go/app.go",
     r"func \(tx \*Tx\) PopEntryIn\(window uint64\) \{\s*tx\.emit\(TxPopEntry\(window\)\)",
     "TxPopEntry(window"),
    ("java push", "bindings/java/dev/kaya/KayaApp.java",
     r"public EntryRef pushEntryIn\(long window, long id\) \{\s*emit\(KayaWire\.txPushEntry\(window, id\)\)",
     "txPushEntry(window"),
    ("java pop", "bindings/java/dev/kaya/KayaApp.java",
     r"public void popEntryIn\(long window\) \{\s*emit\(KayaWire\.txPopEntry\(window\)\)",
     "txPopEntry(window"),
    ("swift push", "bindings/swift/KayaApp.swift",
     r"window: UInt64 = 0\s*\) \{\s*tx\.pushEntry\(window, id\)",
     "pushEntry(window"),
    ("swift pop", "bindings/swift/KayaApp.swift",
     r"public func popEntry\(window: UInt64 = 0\) \{\s*tx\.popEntry\(window\)",
     "popEntry(window"),
    ("csharp push", "bindings/csharp/KayaApp.cs",
     r"ulong window = 0\)\s*\{\s*Records\.Add\(KayaWire\.TxPushEntry\(window, id\)\)",
     "TxPushEntry(window"),
    ("csharp pop", "bindings/csharp/KayaApp.cs",
     r"public void PopEntry\(ulong window = 0\) => Records\.Add\(KayaWire\.TxPopEntry\(window\)\)",
     "TxPopEntry(window"),
    ("ocaml push", "bindings/ocaml/kaya_app.ml",
     r"^let push_entry \?\(window = 0L\)[\s\S]{0,200}?Kaya_wire\.tx_push_entry window id",
     "tx_push_entry window"),
    ("ocaml pop", "bindings/ocaml/kaya_app.ml",
     r"^let pop_entry \?\(window = 0L\) \(\) = emit \(the_tx \(\)\) \(Kaya_wire\.tx_pop_entry window\)",
     "tx_pop_entry window"),
    ("haskell push", "bindings/haskell/KayaApp.hs",
     r"^pushEntryIn :: Word64 -> Word64 -> \[EntryAttr\] -> Build \(\)\npushEntryIn w n attrs = do\n  emitB \(W\.txPushEntry w n\)",
     "txPushEntry w"),
    ("haskell pop", "bindings/haskell/KayaApp.hs",
     r"^popEntryIn :: Word64 -> Build \(\)\npopEntryIn w = emitB \(W\.txPopEntry w\)",
     "txPopEntry w"),
    ("haskell export", "bindings/haskell/KayaApp.hs",
     r"^    pushEntryIn,\n[\s\S]{0,400}?^    popEntryIn,$",
     "pushEntryIn,"),
    ("python push", "bindings/python/kaya/__init__.py",
     r"window: int = 0\) -> _TxScope:[\s\S]{0,1200}?push=True, parent=window,",
     "parent=window"),
    ("python push record", "bindings/python/kaya/__init__.py",
     r"wire\.tx_push_entry\(self\._parent, self\._window\)",
     "self._parent"),
    ("python pop", "bindings/python/kaya/__init__.py",
     r"^def pop_entry\(window: int = 0\) -> None:[\s\S]{0,300}?wire\.tx_pop_entry\(int\(window\)\)",
     "int(window)"),
    ("js push option", "bindings/js/kaya/index.ts",
     r"^export type EntryOptions = \{[^}\n]*\bwindow\?: number",
     "window?:"),
    ("js push record", "bindings/js/kaya/index.ts",
     r"wire\.tx_push_entry\(opts\.window \?\? 0, entryId\)",
     "opts.window"),
    ("js pop", "bindings/js/kaya/index.ts",
     r"^export function popEntry\(window = 0\): void \{\s*records\(\)\.push\(wire\.tx_pop_entry\(window\)\)",
     "tx_pop_entry(window"),
]

FLOOR = 21


def findings(texts, rows=ROWS):
    if len(rows) < FLOOR:
        return [f"surface stack census read fewer than {FLOOR} surfaces"]
    return [f"surface stack {label} absent in {rel}"
            for label, rel, pattern, _token in rows
            if not re.search(pattern, texts[rel], re.M)]


def run():
    """Answers the sub-gate's status rather than leaving through a verdict:
    a verdict here ended check-sugar-surface's own run (docs/traps.md)."""
    gate = Gate("check-nav-surface")
    texts = {rel: (ROOT / rel).read_text(encoding="utf-8") for _, rel, _, _ in ROWS}
    baseline = findings(texts)
    for problem in baseline:
        gate.finding(problem)
    if baseline:
        print("check-nav-surface: FINDINGS ABOVE")
        return gate.status
    for label, rel, pattern, token in ROWS:
        count = len(re.findall(pattern, texts[rel], re.M))
        broken = gate.doctor(label, texts[rel], pattern,
                             lambda m, token=token: m.group(0).replace(token, "kayaNoSurface"),
                             want=count, flags=re.M)
        gate.negative(label, lambda broken=broken, rel=rel: findings({**texts, rel: broken}),
                      want=f"surface stack {label} absent")
    gate.negative("empty reader", lambda: findings(texts, []), want="fewer than")
    gate.negatives_ran(len(ROWS) + 1)
    if gate.status == 0:
        print(f"check-nav-surface: OK ({len(ROWS)} surface stack spellings)")
    return gate.status
