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
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
SPEC = "crates/kaya/src/spec.rs"

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

status = 0
findings = private_findings(block) + prop_findings(texts, props)
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

if status == 0:
    print(f"check-doctabs: OK (the Mac document block uses public API; {len(props)} document "
          f"props applied or depth-stubbed on 4 backends; 2 watched negatives red)")
sys.exit(status)
