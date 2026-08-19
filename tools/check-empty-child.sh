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
# ONE NODE IS ONE WIDGET, EVEN WHEN ITS CONTENT WILL NOT DECODE — and no
# layout indexes a child it has not checked for.
#
# The two WIDGET backends have the first half by construction. The two
# DECLARATIVE backends have to say it out loud, because "render nothing"
# there means the node LEAVES THE TREE and everything above it that
# counts children positionally reads the wrong child. The crash and the
# fix: docs/deferred.md, "swiftui, KayaCell, Layout, subviews".
#
# THE CLAUSES:
#
#   A  RUNTIME, macOS only — tools/checks/swiftui-empty-child.swift
#      compiled INTO the interpreter's own module and run in an
#      NSHostingView. SKIPPED AND SAID SO on any other host.
#   B  STATIC, all four backends: the image source's failure branch
#      still produces a widget, and cannot panic.
#   C  STATIC, SwiftUI only: KayaCell subscripts no subview collection
#      it has not checked (`subviews.first`, never `subviews[0]`).
#
# Deliberately not one clause: A needs a GUI toolkit, B and C run
# anywhere, and a lane that can only do B and C should still do them.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

GTK=crates/kaya/src/gtk.rs
WINUI=crates/kaya/src/winui/mod.rs
SWIFTUI=swift/KayaSwiftUI.swift
COMPOSE=android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt
PROBE=tools/checks/swiftui-empty-child.swift

# --- Clauses B and C, as one reader over the four backends. ----------
check() {
    # $1..$4: gtk.rs, winui/mod.rs, KayaSwiftUI.swift, KayaCompose.kt.
    # Prints offenders on stdout, returns 1 on any.
    python3 - "$@" <<'PY'
import re
import sys

gtk, winui, swiftui, compose = sys.argv[1:5]
# Every read is STRIPPED — see `strip` below.
read = lambda p: strip(open(p, encoding="utf-8").read())
bad = []


def span(text, i, opener="{", closer="}"):
    """From the bracket at `i` to its match, skipping comments and
    string literals so a bracket inside either cannot end it early."""
    depth, j, n = 0, i, len(text)
    while j < n:
        c = text[j]
        if c == "/" and j + 1 < n and text[j + 1] == "/":
            j = text.find("\n", j)
            if j < 0:
                break
            continue
        if c == "/" and j + 1 < n and text[j + 1] == "*":
            j = text.find("*/", j)
            if j < 0:
                break
            j += 2
            continue
        if c == '"':
            j += 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j += 1
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
        j += 1
    return None


def strip(text):
    """Code only: line comments, block comments and string literals
    blanked out. Every search below runs on this, and the reason is
    measured — the fix for the crash this gate guards DESCRIBES the
    crash in a doc comment ("`subviews[0]` then traps"), and the first
    run of clause C matched that sentence and failed the file that had
    already been fixed. A gate that reads prose is a gate that fails on
    documentation."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i)
            j = n if j < 0 else j + 2
            out.append(" " * (j - i))
            i = j
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def body(text, pattern, opener="{", closer="}"):
    """The braced body following the first match of `pattern`, or None.
    None is a FAILURE at every callsite below: a gate that stops finding
    what it reads reports a clean bill about nothing."""
    m = re.compile(pattern).search(text)
    if not m:
        return None
    i = text.find(opener, m.end() - 1)
    if i < 0:
        return None
    return span(text, i, opener, closer)


# --- B, GTK: the Err arm keeps the picture and cannot panic. ---------
text = read(gtk)
arm = body(text, r"\(NativeWidget::Image\(picture\), Prop::Source, Value::Blob\(blob\)\)\s*=>")
if arm is None:
    bad.append(f"{gtk}: the image Prop::Source arm is not where this gate looks — "
               "it moved or was renamed, and an unread arm is not a checked one")
else:
    if "Err(_) => picture.set_paintable" not in arm:
        bad.append(f"{gtk}: the image decode's Err arm must leave the GtkPicture in "
                   "place with its paintable cleared (`Err(_) => picture.set_paintable"
                   "(gtk4::gdk::Paintable::NONE)`). A widget backend keeps its widget: "
                   "that is what the declarative backends are held to.")
    for hazard in (".unwrap()", ".expect(", "panic!"):
        if hazard in arm:
            bad.append(f"{gtk}: the image Prop::Source arm contains `{hazard}` — a "
                       "failed decode is the placeholder class, never a panic.")

# --- B, WinUI: the error path logs and leaves the Image alone. -------
text = read(winui)
arm = body(text, r"\(NativeWidget::Image\(image\), Prop::Source, Value::Blob\(blob\)\)\s*=>")
if arm is None:
    bad.append(f"{winui}: the image Prop::Source arm is not where this gate looks — "
               "it moved or was renamed, and an unread arm is not a checked one")
else:
    if "if let Err(e) = result" not in arm:
        bad.append(f"{winui}: the image Prop::Source arm must funnel every failure "
                   "(decode included) into one Err branch that leaves the Image element "
                   "in place with no Source — image_size then reads 0x0.")
    for hazard in (".unwrap()", ".expect(", "panic!"):
        if hazard in arm:
            bad.append(f"{winui}: the image Prop::Source arm contains `{hazard}` — a "
                       "failed decode is the placeholder class, never a panic.")

# --- B, SwiftUI: the failed decode renders a view, not EmptyView. ----
text = read(swiftui)
# The arm runs from `case kindImage:` to the next label at the same
# indent.
m = re.search(r"\n(\s*)case kindImage:\n", text)
if not m:
    bad.append(f"{swiftui}: no `case kindImage:` render arm — the kind was renamed and "
               "this gate went vacuous")
else:
    indent = m.group(1)
    rest = text[m.end():]
    nxt = re.search(r"\n" + indent + r"(case |default:)", rest)
    arm = rest[: nxt.start()] if nxt else rest
    if re.search(r"\}\s*else\s*\{\s*EmptyView\(\)", arm) or "EmptyView()" in arm:
        bad.append(f"{swiftui}: the kindImage arm renders `EmptyView()` when the decode "
                   "fails. An EmptyView contributes NO subview, so the node leaves the "
                   "view tree and KayaCell traps on `subviews[0]` "
                   "(docs/deferred.md). The placeholder must be present and empty — a "
                   "0x0 view — which is what GTK and WinUI have by construction.")
    if not re.search(r"\}\s*else\s*\{", arm):
        bad.append(f"{swiftui}: the kindImage arm has no `else` for the failed decode. "
                   "Every path through the arm must produce a view.")

# --- B, Compose: same rule, said in Kotlin. --------------------------
text = read(compose)
m = re.search(r"\n(\s*)KayaCompose\.KIND_IMAGE ->", text)
if not m:
    bad.append(f"{compose}: no `KayaCompose.KIND_IMAGE ->` render arm — the kind was "
               "renamed and this gate went vacuous")
else:
    i = text.find("{", m.end() - 1)
    arm = span(text, i) if i >= 0 else None
    if arm is None:
        bad.append(f"{compose}: the KIND_IMAGE render arm has no braced body. A bare "
                   "`node.imageBitmap?.let { … }` emits NOTHING when the bitmap is null, "
                   "which removes the node from the composition — the grid arm then "
                   "pairs `placeables[i]` with the wrong `node.children[i]`.")
    elif not re.search(r"\}\s*else\s*\{", arm):
        bad.append(f"{compose}: the KIND_IMAGE arm has no `else` for a null bitmap. The "
                   "failed decode must still compose something (a 0x0 Box), so the node "
                   "keeps its slot — GTK's and WinUI's behaviour, which the declarative "
                   "backends have to write down.")

# --- C, SwiftUI: KayaCell checks before it subscripts. ---------------
text = read(swiftui)
cell = body(text, r"struct KayaCell: Layout\s*")
if cell is None:
    bad.append(f"{swiftui}: no `struct KayaCell: Layout` — the cell was renamed and this "
               "gate went vacuous")
elif re.search(r"subviews\[", cell):
    bad.append(f"{swiftui}: KayaCell subscripts `subviews[…]`. A cell whose child "
               "rendered nothing has a Subviews collection of COUNT ZERO — a kind this "
               "interpreter does not know reaches that by itself — and the subscript "
               "TRAPS (EXC_BREAKPOINT), killing the process during layout. Use "
               "`subviews.first` with a zero fallback.")

for line in bad:
    print(line)
sys.exit(1 if bad else 0)
PY
}

# --- The self-test: every clause above WATCHED GOING RED. ------------
# Perturbations are applied to COPIES; the substitution count is printed
# and an unchanged copy is a FAILED self-test.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

perturb() {
    # <src> <python-regex> <replacement> <dest>; prints the count.
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import re
import sys
src, pat, repl, dest = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
out, n = re.subn(pat, repl.replace("\\", "\\\\"), text, count=1)
open(dest, "w", encoding="utf-8").write(out)
print(n)
PY
}

applied() {
    # <count> <what>: the count is PRINTED, because "the negative test
    # passed" and "it never touched the file" look identical otherwise.
    echo "check-empty-child: self-test — $2 applied (${1:-0} substitution)"
    if [ "${1:-0}" -lt 1 ]; then
        echo "check-empty-child: SELF-TEST BROKEN — $2 changed nothing." \
            "The pattern no longer matches the file, so the red below would" \
            "have been a green about an unperturbed copy." >&2
        exit 1
    fi
}

refuses() {
    # <gtk> <winui> <swiftui> <compose> <expected-substring> <what>
    local out
    if out="$(check "$1" "$2" "$3" "$4")"; then
        echo "check-empty-child: SELF-TEST FAILED — $6 was ACCEPTED." >&2
        exit 1
    fi
    if ! grep -qF "$5" <<<"$out"; then
        echo "check-empty-child: SELF-TEST FAILED — $6 was refused, but not for the" \
            "stated reason. Wanted a sentence containing:" >&2
        echo "  $5" >&2
        echo "got:" >&2
        echo "$out" >&2
        exit 1
    fi
}

hits="$(perturb "$SWIFTUI" 'Color\.clear\.frame\(width: 0, height: 0\)' 'EmptyView()' \
    "$T/swiftui-emptyview.swift")"
applied "$hits" "the SwiftUI EmptyView perturbation"
refuses "$GTK" "$WINUI" "$T/swiftui-emptyview.swift" "$COMPOSE" \
    "renders \`EmptyView()\` when the decode fails" \
    "a SwiftUI image arm that renders nothing"

hits="$(perturb "$SWIFTUI" 'let natural = subviews\.first\?\.sizeThatFits\(\.unspecified\) \?\? \.zero' \
    'let natural = subviews[0].sizeThatFits(.unspecified)' "$T/swiftui-subscript.swift")"
applied "$hits" "the KayaCell subscript perturbation"
refuses "$GTK" "$WINUI" "$T/swiftui-subscript.swift" "$COMPOSE" \
    "KayaCell subscripts" "a KayaCell that indexes an unchecked child"

hits="$(perturb "$SWIFTUI" 'struct KayaCell: Layout' 'struct KayaTrack: Layout' \
    "$T/swiftui-renamed.swift")"
applied "$hits" "the KayaCell rename perturbation"
refuses "$GTK" "$WINUI" "$T/swiftui-renamed.swift" "$COMPOSE" \
    "the cell was renamed and this gate went vacuous" \
    "a KayaCell this gate can no longer find"

hits="$(perturb "$COMPOSE" '\} else \{\n(\s*)Box\(modifier = a11yTag\)\n\s*\}\n' '}
' "$T/compose-noelse.kt")"
applied "$hits" "the Compose else-drop perturbation"
refuses "$GTK" "$WINUI" "$SWIFTUI" "$T/compose-noelse.kt" \
    "has no \`else\` for a null bitmap" "a Compose image arm that composes nothing"

hits="$(perturb "$GTK" 'Err\(_\) => picture\.set_paintable' 'Err(_) => drop_paintable' \
    "$T/gtk-dropped.rs")"
applied "$hits" "the GTK paintable-drop perturbation"
refuses "$T/gtk-dropped.rs" "$WINUI" "$SWIFTUI" "$COMPOSE" \
    "must leave the GtkPicture in place" "a GTK arm that loses its picture"

hits="$(perturb "$WINUI" 'if let Err\(e\) = result' 'let _ = result.unwrap(); if false' \
    "$T/winui-panics.rs")"
applied "$hits" "the WinUI unwrap perturbation"
refuses "$GTK" "$T/winui-panics.rs" "$SWIFTUI" "$COMPOSE" \
    "never a panic" "a WinUI arm that panics on a failed decode"

# --- Clause A: the runtime negative, where a GUI toolkit exists. -----
if [ "$(uname -s)" = "Darwin" ]; then
    # shellcheck source=tools/lib/swift-toolchain.sh
    source "$ROOT/tools/lib/swift-toolchain.sh"
    if [ ! -f target/debug/libkaya.dylib ]; then
        echo "check-empty-child: target/debug/libkaya.dylib is not built — the probe" \
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
        -o "$T/swiftui-empty-child"; then
        echo "check-empty-child: the layout probe did not compile" >&2
        exit 1
    fi
    # The status is read on the line RIGHT AFTER the command (CLAUDE.md
    # `$?` rule): here it is the difference between reporting SIGTRAP
    # and reporting nothing.
    DYLD_LIBRARY_PATH="$ROOT/target/debug" "$T/swiftui-empty-child"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-empty-child: FAIL — the SwiftUI layout probe exited $rc." >&2
        if [ "$rc" -ge 128 ]; then
            echo "  Signal $((rc - 128)): the process was KILLED during layout, which is" \
                "the crash this gate exists for. The last line above names the case that" \
                "reached it." >&2
        fi
        exit 1
    fi
else
    echo "check-empty-child: clause A (the SwiftUI layout probe) SKIPPED — it needs" \
        "macOS and AppKit. Clauses B and C ran."
fi

if ! offenders="$(check "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE")"; then
    echo "$offenders"
    echo "check-empty-child: FAIL"
    exit 1
fi
echo "check-empty-child: OK"
