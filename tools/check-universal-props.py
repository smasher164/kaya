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


# (file, the block that owns the flex row, the min-content read inside it).
FLEX_LINKS = (
    (SWIFTUI, "struct KayaFlex: Layout {", "kayaMinContent(nodes[i], natural: extents[i])"),
    (COMPOSE, "internal fun KayaFlexRow(", "measurables[i].minIntrinsicWidth(heightHint)"),
    (GTK, "fn main_extents(&self, widget: &gtk4::Widget, main_total: i32, cross_total: i32)",
     "crate::flex::shrink(&naturals, &minimums, f64::from(main_total - gaps))"),
    (WINUI, "fn reindex(core: &CoreState, parent: WidgetId) -> windows_core::Result<()> {",
     "def.SetMinWidth(minimum.min(natural))?;"),
)


# (file, the block that owns the arm, the window, the lines the baseline row
# keeps): a cell with no text has no baseline and is centred on the FIRST LINE
# BOX of the cell that set the row's baseline, and a column's baseline is its
# first child's (docs/flex-shrink-plan.md §9, §10) — the iOS switch was
# dropped 16pt to sit its empty label's 0 on the title's line, then sat at the
# row's top while the title's ink began a scaled ascent lower, and no scene
# reads a cell's y.
BASELINE_LINKS = (
    (SWIFTUI, "struct KayaFlex: Layout {", 24000, (
        "return (b < 1 || b > d.height - 1) ? nil : b",
        "if let b = bs[i] { return rowBaseline - b }",
        "lineBox = (rowBaseline - ascent, rowBaseline - ascent + lineHeight)",
        "return (top + bottom) / 2 - dims[i].height / 2",
        "subviews[0].dimensions(in: ProposedViewSize(width: bounds.width, height: ext[0]))",
    )),
    (SWIFTUI, "kayaLabelBaseFont(node), ground: true", 3000, (
        "kayaLineHeights[node.id] = d.height - d[.lastTextBaseline] + d[.firstTextBaseline]",
    )),
    (COMPOSE, "internal fun KayaFlexRow(", 5000, (
        "if (fb == androidx.compose.ui.layout.AlignmentLine.Unspecified) null else fb",
        "KayaCompose.ALIGN_BASELINE -> drops[i]",
        "lineCentre != null -> lineCentre - placeables[i].height / 2",
        "kayaLabelLayouts[it]",
    )),
    (GTK, "let baseline_row = !vertical && super::container_align(widget) == 4;", 3000,
     ("c.allocate(w, nat_h, placed.baselines[i], Some(transform));",)),
    (GTK, "fn baseline_row_layout(", 2500, (
        "let line = first_line_metrics(&widgets[provider]);",
        "ys_nat.push(centre_nat - cnat / 2);",
    )),
    (GTK, "fn first_line_metrics(widget: &gtk4::Widget) -> Option<(i32, i32)> {", 400, (
        "let above = layout.baseline() / gtk4::pango::SCALE;",
    )),
    (GTK, "if vertical && self.is_main(orientation) {", 600,
     ("return (minimum, natural, bmin, bnat);",)),
    (GTK, "WidgetKind::Column => {", 1200, ("layout.set_baseline_child(0);",)),
    # A TEXTLESS CELL IS CENTRED ON A HEIGHT THE ROW DID NOT GIVE IT.
    # WinUI is the one backend that reads an ARRANGED height here
    # (`ActualHeight`), and for a cell that stretches to the row that IS the
    # row's height, so centring it produced a negative top, the shift grew by
    # that much, every margin followed, the row grew and the cell with it:
    # the Inbox row's grown spacer took it 33 -> 50 -> 58 -> 62 over four
    # passes and shipped 14px taller than the same backend's TWO-line row
    # (docs/deferred.md, measured 2026-09-24). The other three ask for a
    # height the row cannot influence — SwiftUI proposes `height: nil` and
    # takes the ideal, GTK and Compose take the measured natural — so this
    # clause has one backend in it on purpose.
    (WINUI, "fn baseline_compensate(", 3500, (
        "_ => None,",
        "None if element.VerticalAlignment()?",
        "== bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch =>",
        "first_text_baseline(core, *child, &element)?",
        "None => centre - element.ActualHeight()? / 2.0,",
        "let centre = deepest + (provider.below - provider.above) / 2.0;",
    )),
    (WINUI, "fn apply_badge(item: &NavigationViewItem, count: f64)", 1200, (
        "pill.SetMaxHeight(16.0 * scale)?;",
    )),
    (WINUI, "fn clipping(&self) -> String {", 5000, (
        'named_descendant(&root, "ValueTextBlock")?',
        # A BUTTON'S CAPTION AGAINST ITS OWN ROOM, and a reader that refuses a
        # VACUOUS answer (docs/deferred.md's WinUI button clip): before the
        # tree is attached nothing is `presented`, every clause is skipped and
        # this verb answered "no clipping" on its first poll about a window
        # that had drawn nothing — three buttons with their words cut passed
        # it on the lane, 2026-09-24.
        "let room = element.ActualWidth()? - pad.Left - pad.Right;",
        "if word > room + 1.0 {",
        "if candidates > 0 && read == 0 {",
        # THE WORD IS MEASURED DIRECTLY, never off a zero-width measure: WinUI
        # clamps DesiredSize to the width it was offered, so that reading is 0
        # for any text and both this wall and the shrink floor were vacuous
        # (measured 2026-09-24, the windows flexshrink leg).
        "let word = longest_word_width(label)?;",
        "let word = longest_word_width(caption)?;",
    )),
    # THE MEASURE THE COLUMN IS SIZED FROM: a control with no template yet
    # answers its content's width and none of its chrome, so the cell comes
    # back when the platform says the template arrived.
    # THE CELL THE FLOOR IS FOR: the call sites, so the two helpers above are
    # held to being REACHED and not merely present.
    (WINUI, "fn reindex(core: &CoreState, parent: WidgetId)", 6000, (
        "remeasure_when_loaded(*child, &element)?;",
        "minimum = minimum.max(longest_word_width(&block)? + chrome);",
    )),
    (WINUI, "fn longest_word_width(block: &TextBlock)", 900, (
        "for word in text.split_whitespace() {",
        "Width: f32::INFINITY,",
    )),
    (WINUI, "fn remeasure_when_loaded(", 1200, (
        "if element.IsLoaded()? {",
        # THROUGH THE TEXT ARMS' OWN BODY, which keeps a TABLE's stamped row
        # out of the re-measure: a reindex there replaces the table's tracks
        # and its rows fall out of alignment (the windows table legs, matrix
        # 2026-09-24).
        "mark_row_for_remeasure(core, child);",
        "element.Loaded(&handler)?;",
    )),
    (WINUI, "fn text_line(block: &TextBlock, top: f64)", 800, (
        ".GetCharacterRect(bindings::Microsoft::UI::Xaml::Documents::LogicalDirection::Forward)?",
    )),
)


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

    # THE TOUCH TARGET, docs/dnd-plan.md D12. It lives in THIS gate
    # because this is the one that already reads both interpreters'
    # render wrappers, and the drag-and-drop surface is a wrapper of
    # exactly the shape `help` is — one no render path may bypass. And
    # because NO SCENE CAN SEE THE RULE: a drag source narrower than the
    # platform's touch slop presents identical bytes to every observable
    # and simply never becomes a drag, which is what the keyed-payload
    # WATCH's third sighting measured (a seven-pixel source, `op=0
    # entered=0`, docs/deferred.md).
    compose_code = code_only(read(compose))

    def block(text, head):
        at = text.find(head)
        if at < 0:
            return None
        end = text.find("\n}\n", at)
        return text[at:end if end > 0 else len(text)]

    surface = block(compose_code, "private fun kayaDragAndDropSurface(")
    if surface is None:
        bad.append(f"{compose}: no kayaDragAndDropSurface — the drag-and-drop "
                   "surface moved, and android's touch target with it (D12)")
    elif "minimumInteractiveComponentSize" in surface:
        # THE MEASURED PLACEMENT, 2026-09-06: the minimum PLACES its content
        # centred, and Compose's drag hit test then reads that placement's
        # origin with the enlarged size — a reorder aimed a quarter of the
        # way down a 48dp row hit nothing, and a text drop landed on the
        # source. It may not join this chain.
        bad.append(
            f"{compose}: minimumInteractiveComponentSize sits in the drag "
            "surface's OWN modifier chain — its centred placement desyncs "
            "Compose's drag hit test from the recorded box, which is a "
            "measured red (D12); it wraps the content inside KayaRender's "
            "box instead")
    render = block(compose_code, "fun KayaRender(")
    if render is None:
        bad.append(f"{compose}: no KayaRender — the render entry that carries "
                   "android's touch target moved (D12)")
    else:
        arm = render
        minimum = arm.find("minimumInteractiveComponentSize()")
        boxed = arm.find("Box(modifier = dnd)")
        if minimum < 0:
            bad.append(
                f"{compose}: the android drag source takes no "
                "minimumInteractiveComponentSize — a source narrower than "
                "the platform's touch slop never becomes a drag at all "
                "(D12, 48dp)")
        elif not (boxed >= 0 and boxed < minimum):
            bad.append(
                f"{compose}: android's minimum touch target is not inside "
                "the drag surface's own box — the box the `drag` verb's aim "
                "reads would then be the un-enlarged one (D12)")
        elif "kayaIsDragSource(node)" not in arm[boxed:minimum]:
            bad.append(
                f"{compose}: android's minimum touch target is not guarded "
                "by the source test — a drop target is no drag source and "
                "takes nothing from D12")

    # docs/traps.md: Android sent a drag end that Kaya did not record.
    root = block(compose_code, "fun KayaRoot()") or ""
    for required in (
        "target = dragEndTarget",
        "shouldStartDragAndDrop = { it.toAndroidDragEvent().localState is KayaDragSession }",
        "override fun onEnded(event: DragAndDropEvent)",
        "val session = event.toAndroidDragEvent().localState as? KayaDragSession",
        "if (session.ended) return",
        "KayaPresent.emitDragEnded(session.sourceTag, session.operation)",
    ):
        if required not in root:
            bad.append(f"{compose}: stable root drag-end owner lacks {required!r}; "
                       "a removed source must still receive its native end")
    if "KayaDragSession(node.id, node.identityTag.copyOf()," not in (surface or ""):
        bad.append(f"{compose}: the drag session must capture its source identity "
                   "before a drop can remove or restamp that source")
    if compose_code.count("KayaPresent.emitDragEnded(") != 1:
        bad.append(f"{compose}: the stable root must be the only drag-end reporter")

    swift_code = code_only(read(swiftui))
    at = swift_code.find("private func kayaPhoneDragDrop(")
    if at < 0:
        bad.append(f"{swiftui}: no kayaPhoneDragDrop — the iOS host of the "
                   "drag interaction moved, and its touch target with it "
                   "(D12)")
    else:
        end = swift_code.find("\n        }\n", at)
        host = swift_code[at:end if end > 0 else len(swift_code)]
        framed = host.find(
            ".frame(minWidth: kayaMinTouchTarget, minHeight: kayaMinTouchTarget)")
        hosted = host.find(".background(KayaPhoneDragDropSurface(")
        if framed < 0:
            bad.append(
                f"{swiftui}: the iOS drag host takes no minimum touch "
                "target — a source smaller than the platform's own 44pt is "
                "a drag the finger cannot start (D12)")
        elif not (hosted >= 0 and framed < hosted):
            bad.append(
                f"{swiftui}: the iOS minimum frame does not precede the "
                "drag surface's background — the KayaDragDropView behind "
                "the widget would then be the un-enlarged one (D12)")
        elif "node.dragPayload != nil || reorderIn != nil" not in host:
            bad.append(
                f"{swiftui}: the iOS minimum touch target is not guarded by "
                "the source test — a drop target is no drag source and "
                "takes nothing from D12")
    if not re.search(r"let kayaMinTouchTarget: CGFloat = 44\b", swift_code):
        bad.append(
            f"{swiftui}: kayaMinTouchTarget is not the ruled 44pt — iOS's "
            "minimum touch target is the HIG's number, pinned here rather "
            "than merely held equal to itself (D12)")

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

    # THE FLEX ROW SHRINKS TO ITS LONGEST WORD ON EVERY BACKEND
    # (docs/flex-shrink-plan.md §6): each arm names its min-content read
    # inside its own row layout, since a copy that dropped it passes the
    # flexshrink scene wherever the window is wide.
    for path, block, needle in FLEX_LINKS:
        body = code_only(read(path))
        start = body.find(block)
        if start < 0:
            bad.append(f"{path}: the flex row's block {block!r} is missing")
            continue
        if needle not in body[start:start + 12000]:
            bad.append(f"{path}: the flex row no longer reads its min-content ({needle!r} missing "
                       f"under {block!r})")
    for path, block, window, needles in BASELINE_LINKS:
        body = code_only(read(path))
        start = body.find(block)
        if start < 0:
            bad.append(f"{path}: the baseline row's block {block!r} is missing")
            continue
        for needle in needles:
            if needle not in body[start:start + window]:
                bad.append(f"{path}: the baseline row lost {needle!r} under {block!r}")
    # THE BASELINE HEIGHT IS COMPUTED LAST in KayaFlex.sizeThatFits, after the
    # shrunk pass: the plain maximum of the shrunk cells' heights ignores the
    # drops and the overhang shift, and computed first it was overwritten —
    # a two-line title under an overhanging switch got one line's height
    # (the iOS tasksrtl leg, 2026-09-24).
    body = code_only(read(swiftui))
    flex = body.find("struct KayaFlex: Layout {")
    shrunk_at = body.find("let shrunk = extents(mainExtent: offered", flex)
    baseline_at = body.find(
        "naturalCross = baselineLayout(subviews: subviews, extents: ext).height", flex)
    if flex < 0 or shrunk_at < 0 or baseline_at < 0:
        bad.append(f"{swiftui}: KayaFlex.sizeThatFits lost its shrunk pass or its baseline height")
    elif baseline_at < shrunk_at:
        bad.append(f"{swiftui}: KayaFlex.sizeThatFits computes the baseline row's height "
                   "BEFORE the shrunk pass, which then overwrites it with the plain maximum")
    bad += drag_waits(read(winui))
    return bad


# THE WINDOWS DRAG RELEASES ON AN ANSWER, NEVER ON A DWELL
# (docs/measurements/win-drag-pace-2026-09-24.md). `inject_drag` drives
# blind real input, so what the destination did with it is unreadable from
# the verb — and the dwells that stood in for reading it were guesses no
# measurement stood behind: 3.66s of sleep per drag, 29s of a 32s leg,
# while the same scene ran 20/20 green at 53ms. NO SCENE CAN SEE THIS
# RULE GO: a dwell long enough is green exactly as a wait is, and short
# enough it is a flake nobody can attribute. So the shape is held here —
# the source's own DragStarting and the destination's own hover are
# waited for, the button comes up AFTER that wait, and each counter has
# one writer.
def drag_waits(winui_text):
    bad = []
    body = "\n".join(re.sub(r"//.*", "", line) for line in winui_text.splitlines())
    start = body.find("fn inject_drag(from: (i32, i32), to: (i32, i32)) {")
    if start < 0:
        return [f"{WINUI}: inject_drag is gone — the windows drag moved"]
    drag = body[start:start + 4000]
    for needle, why in (
        ("await_answers(&DRAGS_STARTED, starts, 1, STARTING_BOUND_MS)",
         "the drag no longer waits for the source's own DragStarting"),
        ("await_answers(&HOVERS_ANSWERED, hovers, 1, NUDGED_BOUND_MS)",
         "the drag no longer waits for the destination's own hover"),
    ):
        if needle not in drag:
            bad.append(f"{WINUI}: {why} ({needle!r} missing from inject_drag)")
    # THE BUTTON COMES UP AFTER THE WAIT, which is the whole point: a
    # release injected first is the guessed dwell again, spelled as a wait.
    waited = drag.find("await_answers(&HOVERS_ANSWERED")
    released = drag.find("mouse_event(LEFTUP")
    if waited >= 0 and released >= 0 and released < waited:
        bad.append(f"{WINUI}: inject_drag releases the button BEFORE it waits for the "
                   "destination's hover, so the wait decides nothing")
    # WHAT THE WAITS SAW, on every drag: the drag's own line is the only
    # record of a blind gesture, and a red drop is read from it first.
    for part in ("{start_wait}ms", "{nudged}/1 hover at the release point",
                 "{nudge_wait}ms"):
        if part not in drag:
            bad.append(f"{WINUI}: inject_drag's report no longer prints {part!r} — a drag "
                       "that waited in vain must say what it measured")
    # ONE WRITER EACH, in the handler that owns the event. A second bump
    # anywhere makes the count a number about nothing.
    for fn, owner in (("drag_started();", "the DragStarting handler"),
                      ("hover_answered();", "xaml_drag_event")):
        seen = body.count(f"\n    {fn}") + body.count(f"\n            {fn}")
        if seen != 1:
            bad.append(f"{WINUI}: {fn} is called {seen} time(s); it belongs once, in "
                       f"{owner} — the drag's wait reads that count")
    return bad


# Negatives against DOCTORED COPIES OF THE REAL FILES, in memory: an
# unapplied perturbation cannot pass, since the copy would then equal the
# real file and the census's acceptance IS the red below.
real = load()
g = Gate("check-universal-props")
RAN = 0
DECLARED = 57
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
    RAN += 1

# HELP's four links, one negative each, through the prelude's doctor() so
# the substitution count is printed and a perturbation that applied
# nothing is a FAILED self-test rather than a passed one.
for label, pattern, repl, want in (
    ("the help wrapper bypassed",
     r"KayaRenderHelped\(node, isRoot,", "KayaRenderAnchored(node, isRoot,", 3),
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
    RAN += 1

# THE STRETCHED CELL'S own: the arm removed puts the runaway back, and it
# is the shipped state the maintainer saw.
for label, pattern, repl, want in (
    ("a stretched cell centred on the height the row gave it (the shipped runaway)",
     r"            None if element\.VerticalAlignment\(\)\?\n"
     r"                == bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch =>\n"
     r"            \{\n                0\.0\n            \}\n", "", 1),
):
    doctored = g.doctor(label, real[WINUI], pattern, repl, want=want)
    if not census(load({WINUI: doctored})):
        print(f"check-universal-props: self-test failed — {label} still passed")
        raise SystemExit(1)
    RAN += 1

# THE WINDOWS DRAG'S four, one per link of the wait: the destination's
# answer replaced by a return, the button released before the wait it is
# supposed to follow, the count's one writer deleted, and the report that
# stopped saying how long it waited.
for label, pattern, repl, want in (
    ("the destination's hover no longer waited for",
     r"await_answers\(&HOVERS_ANSWERED, hovers, 1, NUDGED_BOUND_MS\)",
     "(1u64, 0u64)", 1),
    ("the button released before the wait",
     r"    let \(nudged, nudge_wait\) = await_answers\(&HOVERS_ANSWERED, hovers, 1, "
     "NUDGED_BOUND_MS\\);\\n    unsafe \\{ mouse_event\\(LEFTUP, 0, 0, 0, 0\\) \\};",
     "    unsafe { mouse_event(LEFTUP, 0, 0, 0, 0) };\n"
     "    let (nudged, nudge_wait) = await_answers(&HOVERS_ANSWERED, hovers, 1, "
     "NUDGED_BOUND_MS);", 1),
    ("the hover count's one writer deleted",
     r"\n    hover_answered\(\);", "", 1),
    ("the report no longer saying how long it waited",
     r"\{nudge_wait\}ms, \{\}ms in all", "{}ms in all", 1),
):
    doctored = g.doctor(label, real[WINUI], pattern, repl, want=want)
    if not census(load({WINUI: doctored})):
        print(f"check-universal-props: self-test failed — {label} still passed")
        raise SystemExit(1)
    RAN += 1

# THE TOUCH TARGET's five, one per link of D12: android's call gone, its
# guard weakened, the call put back on the surface's own chain (the
# measured red), iOS's frame gone, and iOS's 44 drifted.
for label, path, pattern, repl, want in (
    ("android's minimum touch target deleted", COMPOSE,
     r"\.minimumInteractiveComponentSize\(\)", "", 1),
    ("android's minimum guard weakened (a drop target enlarged too)", COMPOSE,
     r"if \(kayaIsDragSource\(node\)\) \{\n            // D12",
     "if (true) {\n            // D12", 1),
    ("android's minimum moved onto the drag surface's own chain", COMPOSE,
     r"        target = target,\n    \)\n\}",
     "        target = target,\n    ).minimumInteractiveComponentSize()\n}", 1),
    ("iOS's minimum frame deleted", SWIFTUI,
     r"\n *\.frame\(minWidth: kayaMinTouchTarget, minHeight: kayaMinTouchTarget\)",
     "", 1),
    ("iOS's 44pt drifted off the ruled number", SWIFTUI,
     r"let kayaMinTouchTarget: CGFloat = 44", "let kayaMinTouchTarget: CGFloat = 20", 1),
):
    doctored = g.doctor(label, real[path], pattern, repl, want=want)
    if not census(load({path: doctored})):
        print(f"check-universal-props: self-test failed — {label} still passed")
        raise SystemExit(1)
    RAN += 1

# The one a bare presence check cannot see: the minimum moved OUT of the
# surface's box, where the box the aim reads is still the un-enlarged one.
moved = g.doctor(
    "android's minimum lifted out of the drag surface's box", real[COMPOSE],
    r"    Box\(modifier = dnd\) \{\n        if \(kayaIsDragSource\(node\)\) \{",
    "    if (kayaIsDragSource(node)) {", want=1)
if not census(load({COMPOSE: moved})):
    print("check-universal-props: self-test failed — the android minimum "
          "outside the drag surface's box still passed")
    raise SystemExit(1)
RAN += 1

for label, pattern, repl in (
    ("root drag owner disconnected", r"target = dragEndTarget", "target = lostTarget"),
    ("root no longer accepts local drags", r"localState is KayaDragSession", "localState == null"),
    ("root native end callback removed", r"override fun onEnded\(event: DragAndDropEvent\)",
     "fun lostEnd(event: DragAndDropEvent)"),
    ("end session guessed instead of read from native event",
     r"(override fun onEnded\(event: DragAndDropEvent\) \{\n *)"
     r"val session = event.toAndroidDragEvent\(\).localState as\? KayaDragSession",
     r"\1val session = kayaDragSession"),
    ("root end deduplication removed", r"if \(session\.ended\) return", ""),
    ("end routed through a current node instead of captured identity",
     r"emitDragEnded\(session\.sourceTag,", "emitDragEnded(node.identityTag,"),
    ("source identity no longer captured", r"node\.identityTag\.copyOf\(\)", "ByteArray(0)"),
    ("second drag-end reporter planted", r"private fun kayaIsDragSource\(node: KayaNode\)",
     "private fun staleEnd() { KayaPresent.emitDragEnded(ByteArray(0), 0) }\n"
     "private fun kayaIsDragSource(node: KayaNode)"),
):
    doctored = g.doctor(label, real[COMPOSE], pattern, repl, want=1)
    findings = census(load({COMPOSE: doctored}))
    if not findings:
        raise SystemExit(f"check-universal-props: self-test failed: {label} still passed")
    print(f"check-universal-props: {label}: {findings[0]}")
    RAN += 1

# THE FLEX ROW's four: each arm's min-content read cut from a copy.
for label, path, pattern, repl in (
    ("SwiftUI's minimum read off the node deleted", SWIFTUI,
     r"kayaMinContent\(nodes\[i\], natural: extents\[i\]\)", "extents[i]"),
    ("Compose's minimum intrinsic read deleted", COMPOSE,
     r"measurables\[i\]\.minIntrinsicWidth\(heightHint\)\.toDouble\(\)", "0.0"),
    ("GTK's shrink call deleted", GTK,
     r"crate::flex::shrink\(&naturals, &minimums, f64::from\(main_total - gaps\)\)",
     "naturals"),
    ("WinUI's column floor deleted", WINUI,
     r"def\.SetMinWidth\(minimum\.min\(natural\)\)\?;", ""),
):
    doctored = g.doctor(label, real[path], pattern, repl, want=1)
    findings = census(load({path: doctored}))
    if not findings:
        raise SystemExit(f"check-universal-props: self-test failed: {label} still passed")
    print(f"check-universal-props: {label}: {findings[0]}")
    RAN += 1

# THE BASELINE ROW's nine: the textless cell handed a baseline (SwiftUI's
# every-view answer, Compose's and WinUI's bottom-edge rule, GTK's fill), the
# drop taken off a cell that has none, and each hand-written column baseline
# returned to the container's bottom.
for label, path, pattern, repl in (
    ("SwiftUI answering a baseline for every view", SWIFTUI,
     r"return \(b < 1 \|\| b > d\.height - 1\) \? nil : b", "return b"),
    ("SwiftUI dropping a textless cell onto the row's line", SWIFTUI,
     r"if let b = bs\[i\] \{ return rowBaseline - b \}",
     "return rowBaseline - (bs[i] ?? 0)"),
    ("SwiftUI's textless cell back at the row's top", SWIFTUI,
     r"return \(top \+ bottom\) / 2 - dims\[i\]\.height / 2", "return 0"),
    ("SwiftUI's line box read off the wrong label", SWIFTUI,
     r"lineBox = \(rowBaseline - ascent, rowBaseline - ascent \+ lineHeight\)",
     "lineBox = (0, lineHeight)"),
    ("SwiftUI's baseline height computed before the shrunk pass (the shipped order)", SWIFTUI,
     r"(        if !vertical, let offered = proposal\.width, offered\.isFinite, offered > 0,\n"
     r"[\s\S]*?\n        \}\n)((?:        //[^\n]*\n)*"
     r"        if !vertical && align == alignBaseline \{\n"
     r"[\s\S]*?naturalCross = baselineLayout\(subviews: subviews, extents: ext\)\.height"
     r"\n        \}\n)",
     r"\2\1"),
    ("SwiftUI's label no longer recording its line height", SWIFTUI,
     r"kayaLineHeights\[node\.id\] = d\.height - d\[\.lastTextBaseline\] "
     r"\+ d\[\.firstTextBaseline\]",
     "kayaLineHeights[node.id] = d.height"),
    ("Compose's textless cell back at the row's top", COMPOSE,
     r"lineCentre != null -> lineCentre - placeables\[i\]\.height / 2", "lineCentre != null -> 0"),
    ("GTK's line box no longer read off the provider", GTK,
     r"let line = first_line_metrics\(&widgets\[provider\]\);", "let line = None;"),
    ("GTK's textless cell back at the row's top", GTK,
     r"ys_nat\.push\(centre_nat - cnat / 2\);", "ys_nat.push(0);"),
    ("WinUI's textless cell back at the row's top", WINUI,
     r"None => centre - element\.ActualHeight\(\)\? / 2\.0,", "None => 0.0,"),
    ("WinUI's badge capped at the platform's 16 again (the shipped state)", WINUI,
     r"pill\.SetMaxHeight\(16\.0 \* scale\)\?;", "pill.SetMaxHeight(16.0)?;"),
    ("WinUI's clipping read no longer measuring the badge's digit", WINUI,
     r'named_descendant\(&root, "ValueTextBlock"\)\?', 'named_descendant(&root, "NoSuchBlock")?'),
    ("WinUI's clipping read no longer measuring a button's caption", WINUI,
     r"if word > room \+ 1\.0 \{", "if false {"),
    ("WinUI's shrink floor back on the clamped zero-width measure", WINUI,
     r"minimum = minimum\.max\(longest_word_width\(&block\)\? \+ chrome\);",
     "minimum = minimum.max(chrome);"),
    ("WinUI's clipping read agreeing about a window it never read", WINUI,
     r"if candidates > 0 && read == 0 \{", "if false {"),
    ("WinUI's cell never coming back for a measure with its template", WINUI,
     r"element\.Loaded\(&handler\)\?;", "let _ = handler;"),
    ("WinUI's line box read off the character rectangle no more", WINUI,
     r"\.GetCharacterRect\(bindings::Microsoft::UI::Xaml::Documents::LogicalDirection::Forward\)\?",
     ".GetCharacterRect(bindings::Microsoft::UI::Xaml::Documents::LogicalDirection::Backward)?"),
    ("SwiftUI's column answering no baseline of its own", SWIFTUI,
     r"return Self\.textBaseline\(\n\s*subviews\[0\]\.dimensions\(in: ProposedViewSize\("
     r"width: bounds\.width, height: ext\[0\]\)\)\)", "return nil"),
    ("Compose's bottom-edge rule for a textless cell", COMPOSE,
     r"AlignmentLine\.Unspecified\) null else fb", "AlignmentLine.Unspecified) p.height else fb"),
    ("Compose dropping a textless cell onto the row's line", COMPOSE,
     r"KayaCompose\.ALIGN_BASELINE -> drops\[i\]",
     "KayaCompose.ALIGN_BASELINE -> baselineRow - (baselines[i] ?: 0)"),
    ("GTK handing a baseline row's cells to GTK's own valign again", GTK,
     r"c\.allocate\(w, nat_h, placed\.baselines\[i\], Some\(transform\)\);",
     "c.allocate(w, h, placed.baseline_nat, Some(transform));"),
    ("GTK's column answering no baseline of its own", GTK,
     r"return \(minimum, natural, bmin, bnat\);", "return (minimum, natural, -1, -1);"),
    ("GTK's plain column box answering no baseline (the shipped state)", GTK,
     r"layout\.set_baseline_child\(0\);", "layout.set_baseline_child(-1);"),
    ("WinUI's bottom-edge rule for a textless cell", WINUI,
     r"(fn baseline_compensate\([\s\S]*?)_ => None,", r"\1_ => Some(element.ActualHeight()?),"),
    ("WinUI's column answering its bottom", WINUI,
     r"first_text_baseline\(core, \*child, &element\)\?", "Some(element.ActualHeight()?)"),
):
    doctored = g.doctor(label, real[path], pattern, repl, want=1)
    findings = census(load({path: doctored}))
    if not findings:
        raise SystemExit(f"check-universal-props: self-test failed: {label} still passed")
    print(f"check-universal-props: {label}: {findings[0]}")
    RAN += 1

print(f"check-universal-props: {RAN} watched negative(s) ran")
if RAN != DECLARED:
    print(f"check-universal-props: REFUSAL — {RAN} watched negative(s) ran, "
          f"but {DECLARED} are declared — a self-test that did not run is "
          f"not a self-test", file=sys.stderr)
    raise SystemExit(1)

offenders = census(real)
if offenders:
    print("\n".join(offenders))
    print("check-universal-props: FAIL")
    raise SystemExit(1)
print("check-universal-props: OK")
