#!/usr/bin/env bash

# Everything runs inside the dev shell; the marker carries the flake
# fingerprint the shell was built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# The interpreter-coverage gate. The SwiftUI and Compose backends
# re-implement the harness verbs and carry private copies of the wire
# constants — string-matched layers the compiler cannot hold to the
# Rust source, and the layer where "landed everywhere except..." bugs
# have twice reached a device suite (GTK child_texts, Kotlin
# expect_order). This gate holds them structurally: every harness verb,
# every APPLY/KIND/PROP/COMMAND constant (with its value), and every
# value type reachable through the spec's PROPS must appear in BOTH
# interpreter files, as is every MENU_KIND/MPROP menu constant. A new
# widget, prop, verb, menu item kind, or value type that misses an
# interpreter fails here, in seconds, not on an emulator.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'EOF'
import pathlib
import re
import sys

harness = open("crates/kaya/src/harness.rs").read()
wire = open("crates/kaya/src/wire.rs").read()
spec = open("crates/kaya/src/spec.rs").read()
swift = open("swift/KayaSwiftUI.swift").read()
kotlin = open("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt").read()

failures = []


def fail(msg):
    failures.append(msg)


# --- Harness verbs: the parse() match arms are the grammar. ----------
parse_body = harness[harness.index("pub fn parse(") : harness.index("fn parse_target(")]
verbs = sorted(set(re.findall(r'"([a-z_]+)" =>', parse_body)) - {"on", "off"})
if not verbs:
    fail("no verbs extracted from harness.rs parse() — the gate itself broke")
for verb in verbs:
    for name, text in (("KayaSwiftUI.swift", swift), ("KayaCompose.kt", kotlin)):
        if f'"{verb}"' not in text:
            fail(f'verb "{verb}" missing from {name}')

# --- Scene substitutions: the THIRD vocabulary. ----------------------
# Verbs and wire constants are not the only thing the interpreters
# mirror. A scene path may carry `$TMP` or `$PID`, and an interpreter
# that does not expand a token uses it as a LITERAL PATH SEGMENT — a
# directory that cannot exist, which on macOS means the picker quietly
# falls back to its last-used location and the scene asserts against
# whatever that was (docs/traps.md). Silent on every platform.
#
# When this was written the expansion lived in KayaSwiftUI.swift ALONE,
# and nothing anywhere said so; wiring the filedialog scene onto android
# would have shipped the literal. Same shape as the verbs above, same
# reason: the interpreters are the historic miss layer.
#
# THREE SITES, NOT TWO. harness.rs is the third implementation of these
# verbs — the one the GTK and WinUI backends run — and the first cut of
# this rule checked only the two interpreter files, which is the very
# hole it was written to close, one file over. Nothing else in this gate
# looks at harness.rs as a MIRROR (it is the source the verbs are
# extracted FROM), so the omission read as correct.
subs = sorted(
    set(
        tok
        for f in pathlib.Path("tools/scenes").glob("*.steps")
        for tok in re.findall(r"\$([A-Z_]+)", f.read_text())
    )
)
for sub in subs:
    for name, text in (
        ("KayaSwiftUI.swift", swift),
        ("KayaCompose.kt", kotlin),
        ("harness.rs", harness),
    ):
        if f'"{sub}"' not in text:
            fail(
                f'scene substitution "${sub}" has no expansion in {name} — '
                f"it would be used as a literal path segment"
            )

# --- Wire constants the interpreters mirror privately. ---------------
# APPLY/KIND/PROP/COMMAND/MENU_KIND/MPROP: all of them. VALUE: only the
# types reachable through the spec's PROPS PropKinds (the scene's prop
# typing keeps the rest off the pump).
rows = re.findall(r"pub const ((?:APPLY|KIND|PROP|COMMAND|VALUE|MENU_KIND|MPROP)_[A-Z_0-9]+): u\d+ = (\d+);", wire)
props_block = spec[spec.index("pub const PROPS") : spec.index("];", spec.index("pub const PROPS"))]
prop_kinds = set(re.findall(r"PropKind::(\w+)", props_block))
required_values = {"VALUE_" + k.upper() for k in prop_kinds}


def swift_name(const):
    group, rest = const.split("_", 1)
    return group.lower() + "".join(w.capitalize() for w in rest.split("_"))


for const, value in rows:
    if const.startswith("VALUE_") and const not in required_values:
        continue
    sname = swift_name(const)
    if not re.search(rf"let {re.escape(sname)}\b[^=\n]*= {value}\b", swift):
        fail(f"{const} = {value}: expected `{sname} ... = {value}` in KayaSwiftUI.swift")
    if not re.search(rf"\b{const}\b\s*(?::\s*\w+\s*)?=\s*{value}\b", kotlin):
        fail(f"{const} = {value}: expected `{const} = {value}` in KayaCompose.kt")

# --- The spec hash: the one constant whose staleness a runtime assert
# --- must also hold (a stale compiled dylib/APK bypasses source gates),
# --- but the SOURCE copy is pinned here like every other constant.
wire_h = open("bindings/c/kaya_wire.h").read()
m = re.search(r"#define KAYA_SPEC_HASH 0x([0-9a-fA-F]+)ULL", wire_h)
if not m:
    fail("KAYA_SPEC_HASH not found in bindings/c/kaya_wire.h — the gate itself broke")
else:
    h = m.group(1).lower()
    if not re.search(rf"let kayaSpecHash: UInt64 = 0x{h}\b", swift):
        fail(f"spec hash 0x{h}: expected `let kayaSpecHash: UInt64 = 0x{h}` in KayaSwiftUI.swift")
    if not re.search(rf"SPEC_HASH: ULong = 0x{h}uL\b", kotlin):
        fail(f"spec hash 0x{h}: expected `SPEC_HASH: ULong = 0x{h}uL` in KayaCompose.kt")

# --- Every expect arm must RECORD what it observed. ------------------
# A verb that appends a failure on mismatch and nothing on a match
# verifies nothing when it passes: the leg prints PASS with that
# assertion silently absent from the observation list. Measured
# 2026-07-25 — the Compose expect_ax arm did exactly this, and the only
# reason it surfaced is that EVERY step in that scene was expect_ax, so
# the whole-script "script has no expects" fallback fired. One
# non-accessibility expect in the same scene and it would have shipped
# a verb that never checked anything.
#
# The observation list is also the byte-compared verdict text, so
# "recorded nothing" and "reported the wrong thing" are the same defect
# class. String-matched per arm, the house style of this gate.
def expect_arms(text, pattern, end_marker):
    """(verb, body) for each expect_* arm of an interpreter's switch."""
    heads = list(re.finditer(pattern, text))
    for i, m in enumerate(heads):
        stop = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        end = text.find(end_marker, m.start(), stop)
        yield m.group(1), text[m.start() : end if end > 0 else stop]


for verb, body in expect_arms(swift, r'case "(expect[a-z_]*)":', "\n            case "):
    if "observed.append(" not in body:
        fail(f'KayaSwiftUI.swift\'s "{verb}" arm never appends to `observed` — '
             "an expect that records nothing passes without verifying anything")
for verb, body in expect_arms(kotlin, r'"(expect[a-z_]*)" ->', "\n                    \""):
    if "observed.add(" not in body:
        fail(f'KayaCompose.kt\'s "{verb}" arm never adds to `observed` — '
             "an expect that records nothing passes without verifying anything")

# The vtable rule: the SwiftUI interpreter reaches the host ONLY
# through KayaHost's function-pointer table. A direct C-symbol call
# (kaya_emit_*, kaya_next_*, ...) typechecks and even links, then
# dies at dlopen against a static-rust or RTLD_LOCAL host ("symbol
# not found in flat namespace" — the confirm slice hit it live).
# C symbols are exactly the kaya_ + underscore namespace; Swift-side
# helpers are camelCase and never match.
for m in re.finditer(r"\bkaya_[a-z_]+\s*\(", swift):
    fail(f"KayaSwiftUI.swift calls C symbol `{m.group(0).strip('( ')}` directly — "
         "route it through KayaHost's api table (the vtable pins the one "
         "live kaya instance; direct symbols die on static/RTLD_LOCAL hosts)")

# THE STAMPED-OBSERVATION RULE. A field the harness READS must be
# written on every platform the interpreter serves, and the way that
# breaks is silent: the write sits inside a platform conditional, the
# other platform leaves the field at its initial value, and the verb
# reads a default that looks like an answer.
#
# It happened. `formFactor` was written only by the menu chrome, which
# lives inside `#if !os(macOS)` and reads `horizontalSizeClass` — a
# thing macOS does not have. Every desktop window carried `unknown`
# from the day form factor landed, and nothing noticed for two
# milestones because macOS answers the MENU verb off the real NSMenu
# instead of the model. The second lowering to ask the model got
# `unknown` and took the wrong arm.
#
# So: each of these fields must have at least one write OUTSIDE every
# platform conditional. Nesting is tracked rather than grepped,
# because a write is "conditional" whenever ANY enclosing #if is.
STAMPED = ["formFactor", "splitPresentation"]
lines = swift.splitlines()
depths, depth = [], 0
for line in lines:
    t = line.strip()
    if t.startswith("#endif"):
        depth = max(0, depth - 1)
    depths.append(depth)
    if t.startswith("#if"):
        depth += 1
for field in STAMPED:
    writes = [(n, d) for n, (line, d) in enumerate(zip(lines, depths), 1)
              if re.search(rf"\.{field}\s*=[^=]", line)]
    if not writes:
        fail(f"KayaSwiftUI.swift never writes `{field}`, which the harness reads")
    elif all(d > 0 for _, d in writes):
        where = ", ".join(str(n) for n, _ in writes)
        fail(f"every write to `{field}` in KayaSwiftUI.swift sits inside a platform "
             f"conditional (lines {where}) — the platforms it excludes read the "
             "field's initial value as if it were an observation")

# (THE PANE PROPORTION pin lived here: protocol::leading_pane_width's
# 25%/180..280 served the GTK and WinUI arms, and the Compose arm
# restated the same numbers in Kotlin because it cannot call Rust, so
# this pinned the two copies together. There is one copy again. Each
# backend that adopted its platform's list-detail wrapper adopted that
# wrapper's proportions with it — libadwaita's sidebar-width-fraction,
# which is where the 25%/180..280 came from in the first place, and
# Material's own pane sizing — leaving WinUI the only caller, because
# TwoPaneView's default is the down-the-middle split no platform
# ships. A single Rust function needs no cross-language pin, and
# scene.rs unit-tests its rule directly.)

if failures:
    for f in failures:
        print(f"check-verbs: {f}", file=sys.stderr)
    sys.exit(1)
print(f"check-verbs: OK ({len(verbs)} verbs, {len(rows)} constants + spec hash against 2 interpreters)")
EOF
