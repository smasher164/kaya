#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# THE MACOS PANE LADDER (docs/multicolumn-plan.md MECHANICS AMENDMENTS).
# macOS has no compact mode to defer to, so kaya's own arithmetic
# decides how many of a three-pane window's columns fit — and no shared
# scene can pin the middle rung, because the platforms legitimately
# disagree at every width inside check-steps' panes band. This gate is
# where the ladder lives or dies:
#
#   A  STATIC, any host: the interpreter never declares a column
#      MINIMUM to SwiftUI. A declared minimum becomes the WINDOW's
#      floor — the collapse rule can then never fire and resize_window
#      turns into a silent no-op (measured; amendment 1). Ideal widths
#      are fine.
#   B  RUNTIME, macOS only — tools/checks/swiftui-pane-ladder.swift
#      compiled INTO the interpreter's own module and run: the rung
#      arithmetic (including content+detail < 600, which is what keeps
#      the bare expect_panes invariant true at every regular width),
#      the edge-triggered command rule the sidebar toggle depends on,
#      and the REAL NSSplitView walked 1400 -> 700 -> 1400 with its
#      visible columns counted at each rung. SKIPPED AND SAID SO on any
#      other host.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

SWIFTUI=swift/KayaSwiftUI.swift
PROBE=tools/checks/swiftui-pane-ladder.swift

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# --- Clause A: no declared column minimum, anywhere. -----------------
scan_min() {
    # Prints offenders; exits 1 on any. Comments are not exempt: a
    # commented example is what the next reader pastes.
    python3 - "$1" <<'PY'
import sys

path = sys.argv[1]
bad = []
for n, line in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
    if "navigationSplitViewColumnWidth(min" in line.replace(" ", ""):
        bad.append(f"{path}:{n}: {line.strip()}")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
}

if ! out="$(scan_min "$SWIFTUI")"; then
    echo "check-pane-ladder: FAIL — a column MINIMUM is declared to SwiftUI." >&2
    echo "$out" >&2
    echo "  A declared minimum becomes the WINDOW's floor: collapse can never" >&2
    echo "  fire and resize_window silently no-ops (docs/multicolumn-plan.md" >&2
    echo "  MECHANICS AMENDMENTS 1). Declare ideal widths only; the minimums" >&2
    echo "  live in kayaPaneMin* and are handed to nobody." >&2
    exit 1
fi

# The guard guards itself: a doctored copy carrying a min: declaration
# must fail, and the perturbation must be PROVEN applied.
python3 - "$SWIFTUI" "$T/doctored.swift" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = ".navigationSplitViewColumnWidth(ideal: 220)"
count = text.count(needle)
print(f"check-pane-ladder: self-test perturbation applied {count} time(s)")
if count != 1:
    print(f"check-pane-ladder: SELF-TEST FAIL — wanted exactly 1 site for "
          f"{needle!r}, found {count}; the negative no longer perturbs what "
          f"it thinks it does", file=sys.stderr)
    sys.exit(1)
open(dst, "w", encoding="utf-8").write(
    text.replace(needle, ".navigationSplitViewColumnWidth(min: 180, ideal: 220)"))
PY
rc=$?
if [ "$rc" -ne 0 ]; then
    exit 1
fi
if scan_min "$T/doctored.swift" >/dev/null; then
    echo "check-pane-ladder: SELF-TEST FAIL — a doctored min: declaration passed the scan" >&2
    exit 1
fi

# --- Clause B: the runtime ladder, where a GUI toolkit exists. -------
if [ "$(uname -s)" != "Darwin" ]; then
    echo "check-pane-ladder: OK (static clause; the runtime ladder needs macOS and was SKIPPED)"
    exit 0
fi

# shellcheck source=tools/lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"
if [ ! -f target/debug/libkaya.dylib ]; then
    echo "check-pane-ladder: target/debug/libkaya.dylib is not built — the probe" \
        "links against it. Run tools/gates.sh, which builds what its gates read." >&2
    exit 1
fi
# The probe compiles the interpreter's OWN source, so there is no
# interpreter artifact in this path to go stale.
if ! kaya_swiftc \
    -import-objc-header crates/kaya/include/kaya.h \
    "$SWIFTUI" "$PROBE" \
    -L target/debug -lkaya \
    -framework AppKit -framework Foundation \
    -o "$T/swiftui-pane-ladder"; then
    echo "check-pane-ladder: the ladder probe did not compile" >&2
    exit 1
fi
DYLD_LIBRARY_PATH="$ROOT/target/debug" "$T/swiftui-pane-ladder"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "check-pane-ladder: FAIL — the ladder probe exited $rc (its own output" >&2
    echo "  names the rung that did not materialize)." >&2
    exit 1
fi
echo "check-pane-ladder: OK"
