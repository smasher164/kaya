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
# interpreter files. A new widget, prop, verb, or value type that
# misses an interpreter fails here, in seconds, not on an emulator.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - <<'EOF'
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

# --- Wire constants the interpreters mirror privately. ---------------
# APPLY/KIND/PROP/COMMAND: all of them. VALUE: only the types reachable
# through the spec's PROPS PropKinds (the scene's prop typing keeps the
# rest off the pump).
rows = re.findall(r"pub const ((?:APPLY|KIND|PROP|COMMAND|VALUE)_[A-Z_0-9]+): u\d+ = (\d+);", wire)
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

if failures:
    for f in failures:
        print(f"check-verbs: {f}", file=sys.stderr)
    sys.exit(1)
print(f"check-verbs: OK ({len(verbs)} verbs, {len(rows)} constants against 2 interpreters)")
EOF
