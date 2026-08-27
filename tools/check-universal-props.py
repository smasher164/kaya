#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

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

import re

COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
SWIFTUI = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
WIRE = "bindings/python/kaya/wire.py"
SOURCES = (COMPOSE, SWIFTUI, GTK, WINUI, WIRE)


def load(over=None):
    files = {p: (ROOT / p).read_text(encoding="utf-8") for p in SOURCES}
    if over:
        files.update(over)
    return files


def census(files):
    compose, swiftui, gtk, winui, wire = COMPOSE, SWIFTUI, GTK, WINUI, WIRE
    read = files.__getitem__
    bad = []

    kinds = re.findall(r"^KIND_([A-Z_]+)", read(wire), re.M)
    if not kinds:
        bad.append(f"{wire}: no KIND_* constants — the spec list is empty")

    def code_only(text):
        """The arm with its comments stripped. A rule the arm's own comment
        can satisfy is a text match, not a rule (check-table-card's
        flatness clause reads its block the same way)."""
        out = []
        for line in text.splitlines():
            stripped = re.sub(r"//.*", "", line)
            out.append(stripped)
        return "\n".join(out)


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
        # A DEPTH-STUB ARM IS EXEMPT, AND ONLY BECAUSE IT CANNOT RETURN.
        # check-verbs' `records_or_refuses` carries the same carve-out for
        # the same reason: `depthStub` is `Nothing`, so there is no view for
        # a modifier to reach and no way for the arm to pass vacuously. The
        # exemption is read from the CALL, never from prose — without this
        # the gate was satisfied by the identifier appearing in the arm's
        # own pointer comment, which is a text match and not a rule.
        if re.search(r'\bdepthStub\("[a-z_]+"\)', code_only(arm)):
            continue
        # `a11y` carries BOTH props. An arm may take the identity half
        # alone (`a11yTag`) only if it hands the NAME to the composable's
        # own parameter — Image is that case.
        if not (re.search(r"\ba11y\b", code_only(arm))
                or (re.search(r"\ba11yTag\b", code_only(arm))
                    and re.search(r"\ba11yLabel\b", code_only(arm)))):
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

    return bad


# Negative test against DOCTORED COPIES OF THE REAL FILES, not synthetic
# samples: the patterns must still bite on the sources as written today.
# In memory rather than in a mktemp dir — nothing is written to the tree,
# so the EXIT trap the shell body carried has nothing left to clean up.
# An unapplied perturbation cannot pass this: the copy would then equal
# the real file, the census would accept it, and that IS the red below.
real = load()
for path, pattern, repl in (
    (COMPOSE, r"\ba11y\b", "kayaUnappliedProps"),
    (SWIFTUI, r"\bkayaA11y\b", "kayaUnappliedProps"),
    (GTK, r"\(w, Prop::A11y", "(NativeWidget::Button(w), Prop::A11y"),
    (WINUI, r"\(w, Prop::A11y", "(NativeWidget::Button(w), Prop::A11y"),
):
    if not census(load({path: re.sub(pattern, repl, real[path])})):
        print(f"check-universal-props: self-test failed — a copy of {path} with"
              " the universal props unapplied still passed")
        raise SystemExit(1)

offenders = census(real)
if offenders:
    print("\n".join(offenders))
    print("check-universal-props: FAIL")
    raise SystemExit(1)
print("check-universal-props: OK")
