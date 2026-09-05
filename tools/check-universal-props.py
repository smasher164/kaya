#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# The universal-props guard on the LOWERING side (check-sugar-surface is
# the same rule on the construction side): a value applied to thirteen
# kinds and forgotten on the fourteenth is invisible to every compiler.
# Each backend is checked in the shape it uses — Compose per-kind arm,
# SwiftUI's one central wrapper with no path around it, GTK and WinUI
# kind-agnostic, so nobody may narrow the binder to one NativeWidget
# variant. Kinds come from the GENERATED wire file.
#
# HELP (the third universal prop, docs/tooltip-plan.md) takes the OTHER
# shape on Compose: a tooltip is a COMPOSABLE, not a modifier, so it
# cannot ride the per-kind `a11y` chain the way the two a11y props do.
# Its visible half is SwiftUI's shape one file over — KayaRenderHelped,
# one wrapper every render path goes through — and its READER'S half is
# a modifier in that same `a11y` chain, which the per-kind census above
# then carries to every kind for free.

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
        # An arm head may carry SEVERAL kinds (`KIND_COLUMN,
        # KayaCompose.KIND_ROW ->` — one node, two constructor
        # spellings, docs/adaptive-layout-plan.md D1); every named kind
        # owns the same arm body.
        heads = list(re.finditer(
            r"^        KayaCompose\.KIND_[A-Z_]+(?:, KayaCompose\.KIND_[A-Z_]+)* ->",
            body, re.M))
        arms = {}
        for i, m in enumerate(heads):
            span = body[m.start():(heads[i + 1].start() if i + 1 < len(heads) else len(body))]
            for kind_name in re.findall(r"KIND_([A-Z_]+)", m.group(0)):
                arms[kind_name] = span
    for kind in kinds:
        if kind not in arms:
            bad.append(f"{compose}: no render arm for KIND_{kind}")
            continue
        arm = arms[kind]
        # A DEPTH-STUB ARM IS EXEMPT ONLY BECAUSE IT CANNOT RETURN:
        # `depthStub` is `Nothing`, so there is no view for a modifier to
        # reach and no way to pass vacuously. Read from the CALL, never
        # from prose — the identifier appears in the arm's own comment.
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

    # COMPOSE'S HELP: the wrapper no render path avoids, the tooltip
    # drawing the node's own help, PLAIN only (T4), and the reader's half
    # in the chain the per-kind clause above already holds.
    text = read(compose)
    helped_at = text.find("private fun KayaRenderHelped(")
    if helped_at < 0:
        bad.append(f"{compose}: no KayaRenderHelped — the help wrapper "
                   "every render path goes through is gone, and help is "
                   "then a prop no kind draws")
    else:
        end = text.find("\n}\n", helped_at)
        helped = text[helped_at:end if end > 0 else len(text)]
        for m in re.finditer(r"\bKayaRenderAnchored\(", text):
            if helped_at <= m.start() < helped_at + len(helped):
                continue
            if text[:m.start()].endswith("private fun "):
                continue
            line = text[:m.start()].count("\n") + 1
            bad.append(
                f"{compose}:{line}: KayaRenderAnchored is called outside "
                "KayaRenderHelped — that path renders a widget whose help "
                "no tooltip draws, and no scene can see the difference")
        if "TooltipBox(" not in code_only(helped):
            bad.append(f"{compose}: KayaRenderHelped draws no TooltipBox — "
                       "kaya draws no tooltip of its own (T2), so the "
                       "platform's own box is the whole arm")
        if not re.search(r"PlainTooltip\s*\{\s*Text\(node\.help\)",
                         code_only(helped)):
            bad.append(f"{compose}: KayaRenderHelped's tooltip does not draw "
                       "PlainTooltip { Text(node.help) } — either the text "
                       "is not the node's help, or T4's plain tier is not "
                       "what draws it")
        if not re.search(r"onLongClick\(label = node\.help", code_only(helped)):
            bad.append(f"{compose}: KayaRenderHelped does not relabel the "
                       "tooltip anchor with the node's help — material's "
                       "anchor merges its descendants, so a helped LEAF is "
                       "the node a reader focuses and it would say \"show "
                       "tooltip\" (measured, docs/tooltip-plan.md §6)")
        chain = re.search(r"^\s*val a11y = .*$", code_only(text), re.M)
        if not chain:
            bad.append(f"{compose}: no `val a11y =` chain — the modifier "
                       "the per-kind census reads moved")
        elif "a11yHelp" not in chain.group(0):
            bad.append(f"{compose}: the `a11y` chain drops a11yHelp — help "
                       "then reaches the tooltip and never the assistive "
                       "reader (docs/tooltip-plan.md T2/§6)")
        if not re.search(r"val a11yHelp\b[\s\S]{0,400}?node\.help",
                         code_only(text)):
            bad.append(f"{compose}: a11yHelp does not read node.help — the "
                       "reader's half publishes something else")
    if re.search(r"\bRichTooltip\b", code_only(text)):
        bad.append(f"{compose}: names RichTooltip — titles, actions and "
                   "images inside a tooltip are refused (T4)")

    # GTK and WINUI. A binder that names a NativeWidget variant would
    # silently scope the props to one kind.
    for path in (gtk, winui):
        text = read(path)
        for prop in ("A11yId", "A11yLabel", "Help"):
            arms = re.findall(rf"^\s*\(([^,]+), Prop::{prop}\b", text, re.M)
            if not arms:
                bad.append(f"{path}: no apply arm for Prop::{prop}")
            for binder in arms:
                if not re.fullmatch(r"[a-z_][a-z0-9_]*", binder.strip()):
                    bad.append(
                        f"{path}: the Prop::{prop} arm binds {binder.strip()!r} — "
                        "the universal props must match the prop alone, never one kind")

    return bad


# Negatives against DOCTORED COPIES OF THE REAL FILES, in memory: an
# unapplied perturbation cannot pass, since the copy would then equal the
# real file and the census's acceptance IS the red below.
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

# HELP's four links, one negative each, through the prelude's doctor() so
# the substitution count is printed and a perturbation that applied
# nothing is a FAILED self-test rather than a passed one.
g = Gate("check-universal-props")
for label, pattern, repl, want in (
    ("the help wrapper bypassed",
     r"KayaRenderHelped\(node, isRoot,", "KayaRenderAnchored(node, isRoot,", 2),
    ("the tooltip drawing something other than the node's help",
     r"PlainTooltip \{ Text\(node\.help\) \}", 'PlainTooltip { Text("") }', 1),
    ("the tooltip upgraded to the rich tier (T4)",
     r"PlainTooltip \{ Text\(node\.help\) \}", "RichTooltip { Text(node.help) }", 1),
    ("the reader's half dropped out of the a11y chain",
     r"\.then\(a11yHelp\)", "", 1),
    ("the tooltip anchor left with material's own label",
     r"        modifier = Modifier\.semantics \{ onLongClick\(label = "
     r"node\.help, action = null\) \},\n", "", 1),
):
    doctored = g.doctor(label, real[COMPOSE], pattern, repl, want=want)
    if not census(load({COMPOSE: doctored})):
        print(f"check-universal-props: self-test failed — {label} still passed")
        raise SystemExit(1)

offenders = census(real)
if offenders:
    print("\n".join(offenders))
    print("check-universal-props: FAIL")
    raise SystemExit(1)
print("check-universal-props: OK")
