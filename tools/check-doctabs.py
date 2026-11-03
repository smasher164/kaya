#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# Document tabs (docs/doctabs-plan.md §7; docs/gates.md): the Mac's native tab
# strip through PUBLIC API ONLY (the ruling, docs/native-tabs-study.md Q1), and
# every document prop applied by every backend or that backend's depth stub.
# No scene sees either: a private class read works until the next macOS, and a
# dropped prop arm is a tooltip or mark nobody's leg reads.

import re

SWIFT = "swift/KayaSwiftUI.swift"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
GTK = "crates/kaya/src/gtk/doctabs.rs"
WINUI = "crates/kaya/src/winui/doctabs.rs"
SPEC = "crates/kaya/src/spec.rs"
HEADER = "crates/kaya/include/kaya.h"

# Every binding spells the four calls and hears every document occurrence
# (docs/doctabs-plan.md §2; invariant 2). The occurrences come from the
# generated header, so a new one is wanted everywhere the day it lands.
CALLS = ["add_document", "select_document", "close_document", "add_region"]


def _camel(n):
    head, *rest = n.split("_")
    return head + "".join(p.capitalize() for p in rest)


def _pascal(n):
    return "".join(p.capitalize() for p in n.split("_"))


BINDINGS = {
    "rust": ("crates/kaya/src/app.rs", lambda n: rf"pub fn {n}\(",
             lambda o: rf"Occurrence::{_pascal(o)}\b"),
    "python": ("bindings/python/kaya/__init__.py", lambda n: rf"def {n}\(",
               lambda o: rf"wire\.OCC_{o.upper()}\b"),
    "js": ("bindings/js/kaya/index.ts",
           lambda n: rf"(export function {_camel(n)}\(|^  {_camel(n)}<T>\()",
           lambda o: rf"wire\.OCC_{o.upper()}\b"),
    "go": ("bindings/go/app.go", lambda n: rf"func \(tx \*Tx\) {_pascal(n)}\(",
           lambda o: rf"\bocc{_pascal(o)}\b"),
    "csharp": ("bindings/csharp/KayaApp.cs", lambda n: rf"public void {_pascal(n)}\(",
               lambda o: rf"KayaWire\.OccKind{_pascal(o)}\b"),
    "java": ("bindings/java/dev/kaya/KayaApp.java", lambda n: rf"public \w+ {_camel(n)}\(",
             lambda o: rf"KayaWire\.OCC_KIND_{o.upper()}\b"),
    "swift": ("bindings/swift/KayaApp.swift", lambda n: rf"public func {_camel(n)}\(",
              lambda o: rf"KAYA_OCCURRENCE_{o.upper()}\b"),
    "ocaml": ("bindings/ocaml/kaya_app.ml", lambda n: rf"^let {n} ",
              lambda o: rf"Kaya_wire\.occ_kind_{o}\b"),
    "haskell": ("bindings/haskell/KayaApp.hs", lambda n: rf"^{_camel(n)} ::",
                lambda o: rf"W\.occKind{_pascal(o)}\b"),
}

BLOCK_START = "// MARK: - Documents on the Mac (docs/doctabs-plan.md"
BLOCK_END = "// MARK: - Media (docs/media-plan.md)"

# AppKit's private tab-strip classes and the doors to private API.
PRIVATE = ["NSTabBar", "NSTabButton", "NSTitlebarAccessoryClipView", "NSSelectorFromString",
           "value(forKey", "setValue(", "perform(Selector", "method_exchange",
           "class_replaceMethod"]

gate = Gate("check-doctabs")


def mac_block(text):
    a = text.find(BLOCK_START)
    b = text.find(BLOCK_END, a + 1)
    return None if a < 0 or b < 0 else text[a:b]


def private_findings(block):
    return [f"{SWIFT}'s document block names {name!r}: the Mac tab strip is public API only "
            f"(docs/native-tabs-study.md Q1); read the tab group and the public accessibility "
            f"protocol instead" for name in PRIVATE if name in block]


def doc_props(spec):
    m = re.search(r"pub const DOCUMENT_PROPS[^=]*= &\[(.*?)\];", spec, re.S)
    return re.findall(r'\("([a-z_]+)", \d+', m.group(1)) if m else []


def camel(name, upper_first):
    parts = name.split("_")
    head = parts[0].capitalize() if upper_first else parts[0]
    return head + "".join(p.capitalize() for p in parts[1:])


def prop_findings(texts, props):
    out = []
    for prop in props:
        for path, text in texts.items():
            # THE ARM, never the constant: every interpreter declares all
            # four constants, so a bare name would agree with anything.
            if path == SWIFT:
                ok = f"(dprop{camel(prop, True)}, value" in text
            elif path == COMPOSE:
                ok = (f"DPROP_{prop.upper()} ->" in text
                      or re.search(r'APPLY_SET_DOCUMENT_PROP[^\n]*\n?[^\n]*depthStub\("doctabs"\)',
                                   text) is not None)
            else:
                ok = f"DocumentProp::{camel(prop, True)}" in text or 'depth_stub("doctabs")' in text
            if not ok:
                out.append(f"{path} applies no document prop {prop!r} and is not "
                           f"depth-stubbed for doctabs")
    return out


def kept_selection_findings(text):
    """docs/traps.md, the WinUI tab close that selected another tab: forget()
    puts the active tab back after removing another, before the TabView's own
    SelectionChanged is read as the user's."""
    body = text[text.find("fn forget("):]
    body = body[:body.find("\n}\n")]
    remove = body.find("items.RemoveAt(at)?;")
    restore = body.find("tabs.view.SetSelectedItem(&kept.item")
    if remove < 0 or not remove < restore:
        return [f"{WINUI}: forget() removes a tab without putting the active tab's "
                "selection back, so WinUI's own move reads as the user selecting another"]
    return []


def document_occurrences(header):
    return [m.lower() for m in re.findall(r"#define KAYA_OCCURRENCE_(\w*DOCUMENT\w*) \d+", header)]


def binding_findings(texts, occurrences):
    out = []
    for lang, (path, call, arm) in BINDINGS.items():
        code = texts[path]
        for name in CALLS:
            if not re.search(call(name), code, re.M):
                out.append(f"{path} ({lang}) spells no {name}: every binding builds documents "
                           f"(docs/doctabs-plan.md §2)")
        for occ in occurrences:
            if not re.search(arm(occ), code):
                out.append(f"{path} ({lang}) has no arm for {occ}: its handlers would never "
                           f"hear it")
    return out


swift = gate.read(SWIFT)
block = mac_block(swift)
if block is None:
    print(f"check-doctabs: REFUSED A VERDICT: {SWIFT} has no document block between "
          f"{BLOCK_START!r} and {BLOCK_END!r}, so this gate would read nothing", file=sys.stderr)
    sys.exit(2)
props = doc_props(gate.read(SPEC))
if len(props) < 4:
    print(f"check-doctabs: REFUSED A VERDICT: {SPEC}'s DOCUMENT_PROPS read {props}, fewer than "
          f"the four it holds", file=sys.stderr)
    sys.exit(2)
texts = {SWIFT: swift, COMPOSE: gate.read(COMPOSE), GTK: gate.read(GTK), WINUI: gate.read(WINUI)}

occurrences = document_occurrences(gate.read(HEADER))
if len(occurrences) < 7:
    print(f"check-doctabs: REFUSED A VERDICT: {HEADER} names {occurrences}, fewer than the "
          f"seven document occurrences", file=sys.stderr)
    sys.exit(2)
bindings = {path: gate.read(path) for path, _, _ in BINDINGS.values()}

status = 0
winui_doctabs = gate.read(WINUI)
findings = (private_findings(block) + prop_findings(texts, props)
            + binding_findings(bindings, occurrences) + kept_selection_findings(winui_doctabs))
for f in findings:
    print(f"check-doctabs: {f}", file=sys.stderr)
    status = 1

# Watched negatives, perturbed in memory with the count printed.
n1 = gate.doctor("N1 (a private tab class read)", block,
                 r"func kayaActiveStrip\(\)", "func kayaActiveStrip(_ bar: NSTabBar? = nil)")
if not private_findings(n1):
    print("check-doctabs: self-test N1 passed a private class in the block", file=sys.stderr)
    status = 1
n2 = gate.doctor("N2 (the tooltip arm dropped)", swift, r"\(dpropTooltip, valueStr\)",
                 "(dpropTitle, valueStr)")
if not prop_findings({SWIFT: n2}, props):
    print("check-doctabs: self-test N2 passed a backend with no tooltip arm", file=sys.stderr)
    status = 1

n3 = gate.doctor("N3 (python's close_document gone)", bindings[BINDINGS["python"][0]],
                 r"\ndef close_document\(", "\ndef close_documents(")
if not binding_findings({**bindings, BINDINGS["python"][0]: n3}, occurrences):
    print("check-doctabs: self-test N3 passed a binding with no close_document", file=sys.stderr)
    status = 1
n4 = gate.doctor("N4 (haskell's moved arm dropped)", bindings[BINDINGS["haskell"][0]],
                 r"kind == W\.occKindDocumentMoved ->", "kind == W.occKindDocumentMovd ->")
if not binding_findings({**bindings, BINDINGS["haskell"][0]: n4}, occurrences):
    print("check-doctabs: self-test N4 passed a binding with no document_moved arm",
          file=sys.stderr)
    status = 1

n5 = gate.doctor("N5 (the kept selection not put back)", winui_doctabs,
                 r"tabs\.view\.SetSelectedItem\(&kept\.item", "let _ = (&kept.item")
if not kept_selection_findings(n5):
    print("check-doctabs: self-test N5 passed a forget() that leaves WinUI's selection move",
          file=sys.stderr)
    status = 1

if status == 0:
    print(f"check-doctabs: OK (the Mac document block uses public API; {len(props)} document "
          f"props applied or depth-stubbed on 4 backends; {len(BINDINGS)} bindings spell "
          f"{len(CALLS)} calls and hear {len(occurrences)} occurrences; 5 watched negatives red; "
          f"WinUI keeps the active tab on a close)")
sys.exit(status)
