#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# The universal-props guard on the LOWERING side: every backend applies
# a11y_id and a11y_label to every widget kind. (check-sugar-surface is
# the same rule on the construction side.) The failure it catches is a
# value applied to thirteen kinds and forgotten on the fourteenth, which
# no compiler and no linter can see.
#
# Each backend is checked in the shape it uses:
#
#   Compose  per-kind: every `when (node.kind)` arm threads the modifier.
#   SwiftUI  central: NO path around KayaRender.body's one wrapper.
#   GTK      kind-agnostic: the apply arm matches the PROP alone, so
#            nobody may narrow the binder to one NativeWidget variant.
#   WinUI    kind-agnostic, same as GTK.
#
# Kinds come from the GENERATED python wire file, so the list tracks the
# spec by construction.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

COMPOSE=android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt
SWIFTUI=swift/KayaSwiftUI.swift
GTK=crates/kaya/src/gtk.rs
WINUI=crates/kaya/src/winui/mod.rs
WIRE=bindings/python/kaya/wire.py

check() {
    # $1..$5: compose, swiftui, gtk, winui, wire. Prints offenders,
    # returns 1 on any.
    python3 - "$@" <<'PY'
import re
import sys

compose, swiftui, gtk, winui, wire = sys.argv[1:6]
read = lambda p: open(p, encoding="utf-8").read()
bad = []

kinds = re.findall(r"^KIND_([A-Z_]+)", read(wire), re.M)
if not kinds:
    bad.append(f"{wire}: no KIND_* constants — the spec list is empty")

# COMPOSE. Each `when (node.kind)` arm must mention the modifier.
text = read(compose)
start = text.find("private fun KayaRenderCore(")
if start < 0:
    bad.append(f"{compose}: no KayaRenderCore — the render switch moved")
    arms = {}
else:
    end = text.find("\n}\n", start)
    body = text[start:end if end > 0 else len(text)]
    heads = list(re.finditer(r"^        KayaCompose\.KIND_([A-Z_]+) ->", body, re.M))
    arms = {
        m.group(1): body[m.start():(heads[i + 1].start() if i + 1 < len(heads) else len(body))]
        for i, m in enumerate(heads)
    }
for kind in kinds:
    if kind not in arms:
        bad.append(f"{compose}: no render arm for KIND_{kind}")
        continue
    arm = arms[kind]
    # `a11y` carries BOTH props. An arm may take the identity half
    # alone (`a11yTag`) only if it hands the NAME to the composable's
    # own parameter — Image is that case.
    if not (re.search(r"\ba11y\b", arm)
            or (re.search(r"\ba11yTag\b", arm) and re.search(r"\ba11yLabel\b", arm))):
        bad.append(
            f"{compose}: the KIND_{kind} arm never applies `a11y` — "
            "the universal props reach every other kind and not this one")

# SWIFTUI. Every mention of `widget` inside KayaRender.body must be
# inside a kayaA11y call, or some path publishes a view with no props.
text = read(swiftui)
start = text.find("struct KayaRender: View {")
if start < 0:
    bad.append(f"{swiftui}: no KayaRender view — the render entry moved")
else:
    body_at = text.find("var body: some View {", start)
    end = text.find("\n    @ViewBuilder private var widget", start)
    if body_at < 0 or end < 0:
        bad.append(f"{swiftui}: KayaRender's body/widget pair moved")
    else:
        for i, line in enumerate(text[body_at:end].splitlines(), 1):
            code = line.split("//")[0]
            if re.search(r"\bwidget\b", code) and "kayaA11y(" not in code:
                bad.append(
                    f"{swiftui}: KayaRender.body renders `widget` without "
                    f"kayaA11y on it: {line.strip()!r}")

# GTK and WINUI. A binder that names a NativeWidget variant would
# silently scope the props to one kind.
for path in (gtk, winui):
    text = read(path)
    for prop in ("A11yId", "A11yLabel"):
        arms = re.findall(rf"^\s*\(([^,]+), Prop::{prop}\b", text, re.M)
        if not arms:
            bad.append(f"{path}: no apply arm for Prop::{prop}")
        for binder in arms:
            if not re.fullmatch(r"[a-z_][a-z0-9_]*", binder.strip()):
                bad.append(
                    f"{path}: the Prop::{prop} arm binds {binder.strip()!r} — "
                    "the universal props must match the prop alone, never one kind")

print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

# Negative test against DOCTORED COPIES OF THE REAL FILES, not synthetic
# samples: the patterns must still bite on the sources as written today.
SELFTEST_DIR="$(mktemp -d)"
trap 'rm -rf "$SELFTEST_DIR"' EXIT
python3 - "$SELFTEST_DIR" "$COMPOSE" "$SWIFTUI" "$GTK" "$WINUI" <<'PY'
import os
import re
import sys

out, compose, swiftui, gtk, winui = sys.argv[1:6]
sub = lambda pat, repl, path: re.sub(pat, repl, open(path, encoding="utf-8").read())
write = lambda name, text: open(os.path.join(out, name), "w", encoding="utf-8").write(text)

# Each doctored copy carries exactly the defect this gate exists for.
write("compose.kt", sub(r"\ba11y\b", "kayaUnappliedProps", compose))
write("swiftui.swift", sub(r"\bkayaA11y\b", "kayaUnappliedProps", swiftui))
write("gtk.rs", sub(r"\(w, Prop::A11y", "(NativeWidget::Button(w), Prop::A11y", gtk))
write("winui.rs", sub(r"\(w, Prop::A11y", "(NativeWidget::Button(w), Prop::A11y", winui))
PY
for doctored in compose.kt swiftui.swift gtk.rs winui.rs; do
    case "$doctored" in
        compose.kt) args=("$SELFTEST_DIR/$doctored" "$SWIFTUI" "$GTK" "$WINUI") ;;
        swiftui.swift) args=("$COMPOSE" "$SELFTEST_DIR/$doctored" "$GTK" "$WINUI") ;;
        gtk.rs) args=("$COMPOSE" "$SWIFTUI" "$SELFTEST_DIR/$doctored" "$WINUI") ;;
        winui.rs) args=("$COMPOSE" "$SWIFTUI" "$GTK" "$SELFTEST_DIR/$doctored") ;;
    esac
    if check "${args[@]}" "$WIRE" >/dev/null 2>&1; then
        echo "check-universal-props: self-test failed — a copy of $doctored with" \
            "the universal props unapplied still passed"
        exit 1
    fi
done

if ! offenders="$(check "$COMPOSE" "$SWIFTUI" "$GTK" "$WINUI" "$WIRE")"; then
    echo "$offenders"
    echo "check-universal-props: FAIL"
    exit 1
fi
echo "check-universal-props: OK"
