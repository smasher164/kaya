"""docs/styling-pass-plan.md Y2-Y9, §3: the Compose arm's skin doors, loaded by
tools/lib/skin_routes.py (run from tools/check-verbs.py).

A gradient whose stop is a literal draws the same header on the lane's one
album, a hover or selection painted in kaya's own colours passes the
nearest-candidate read, an overlay drawn as a flat dark fill reads as overlay
over the art, a shape left off the loading look is read by no scene that
loads first and then shows, and a reader that answers from the node agrees
with every write."""

import re

from content_type_routes import flat
from reveal_routes import blocks

REL = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
LABEL = "the Compose arm"

# (label, opener, what the block must hold, what it may never name)
DOORS = [
    ("gradient and image ground", "fun kayaGroundSurface(node: KayaNode): Modifier = when (node.ground) {",
     ["val stops = listOf(Color(0xFF00_0000L or top), scheme.background)",
      "Modifier.background(Brush.verticalGradient(stops))", "Brush.verticalGradient(stops, startY = -up,",
      "if (scheme.background.luminance() < 0.5f) node.groundTops and 0xFF_FFFF",
      "else (node.groundTops shr 24) and 0xFF_FFFF", "KayaPictureDoor(node)", "ContentScale.Crop.computeScaleFactor(painter.intrinsicSize, area)",
      "sized.then(if (reach == null) Modifier.clipToBounds() else Modifier).drawBehind {"],
     ["node.color", "Color.Black", "Color.Gray", "Color(red", "Color(0xFF1"]),
    ("container surface", "fun kayaFilledSurface(node: KayaNode): Modifier {",
     [".then(kayaGroundSurface(node))",
      "surface.background(MaterialTheme.colorScheme.secondaryContainer, MaterialTheme.shapes.medium)",
      "surface.then(kayaActivatable(node))"], ["Color("]),
    ("activatable container", "fun kayaActivatable(node: KayaNode): Modifier {",
     ["remember(node) { { kayaPress(node) } }", "kayaActivators[node.id] = activate",
      "Modifier.selectable(", "selected = node.selected,", "indication = androidx.compose.material3.ripple(),",
      "role = Role.Button,\nonClick = activate,\n)\n} else {", "role = Role.Button,\nonClick = activate,\n)\n}\nreturn",
      ".semantics(mergeDescendants = true)"],
     [".background(", "Color(", "hoverable", ".alpha(", "indication = null"]),
    # docs/styling-pass-plan.md Y4, AMENDED 2026-10-17: the pick, guarded, first.
    ("press door", "fun kayaPress(node: KayaNode) {",
     ["if (!node.selected) KayaPresent.emitSelectionChanged(node.tag)\nKayaPresent.emitActivated(node.tag)"], []),
    ("filled foreground", "inline fun KayaFilledContent(node: KayaNode, crossinline content: @Composable () -> Unit) {",
     ["if (node.selected) MaterialTheme.colorScheme.onSecondaryContainer"], []),
    ("overlay pair", "fun kayaTintPair(tint: Long): Pair<Color, Color> {",
     ["6L -> Pair(\nscheme.scrim.copy(alpha = KAYA_OVERLAY_SCRIM),\n"
      "if (scheme.background.luminance() < 0.5f) scheme.onSurface else scheme.inverseOnSurface,"], ["Color("]),
    ("image shape", "fun kayaImageShape(node: KayaNode): Modifier = when (node.shape) {",
     ["KayaCompose.SHAPE_ROUNDED -> Modifier.clip(MaterialTheme.shapes.medium)",
      "KayaCompose.SHAPE_CIRCLE -> Modifier.clip(CircleShape)"], ["RoundedCornerShape("]),
    ("boxed image", "internal fun KayaImageBox(node: KayaNode, a11yTag: Modifier, label: String) {",
     [".onGloballyPositioned { kayaImageDrawn[node.id] = Pair(it.size.width / density, it.size.height / density) }\n"
      ".then(kayaImageShape(node))"], []),
    ("dock bar", "internal fun KayaDockBar(consumesBottom: Boolean) {",
     ["if (root == null || !kayaHoldsWidget(root)) {", ".background(MaterialTheme.colorScheme.surfaceContainer)",
      ".onGloballyPositioned { kayaDockFrame = it.boundsInWindow() }", ".windowInsetsPadding(edges)",
      ".padding(KayaSceneModel.windowInset.dp)"], ["Color("]),
    ("docked surface", "private fun KayaDocked(content: @Composable (Boolean) -> Unit) {",
     ["if (KayaSceneModel.dockId == 0L) {\ncontent(false)\nreturn\n}", "content(docked)",
      "KayaDockBar(consumesBottom = true)", "kayaDockAbove = it.boundsInWindow()"], []),
    ("skin tokens", "fun KayaRecordSkinTokens() {",
     ["hover = scheme.onSurface.copy(alpha = KAYA_HOVER_LAYER).toArgb()",
      "selected = scheme.secondaryContainer.toArgb()", "ground = scheme.background.toArgb()"], ["Color("]),
]
# (label, opener, what the block must hold) -- and never MODEL
READS = [
    ("expect_ground's reader", "private fun kayaGroundRead(activity: ComponentActivity, spec: String): String? {",
     ["kayaSkinShot(activity)", "kayaContrast(mid, kayaRgb(tokens.text))", "contrast >= 4.5",
      "kayaGap(bottom, ground) <= KAYA_SKIN_TOLERANCE", "kayaPictureAt(nodeId, got.second,"]),
    ("expect_shape's reader", "private fun kayaShapeRead(activity: ComponentActivity, spec: String): String? {",
     ["kayaSkinShot(activity)", "shot.at(box.left + 1 * u, box.top + 1 * u)", "shot.at(box.left + 6 * u, box.top + 6 * u)",
      "shot.at(box.left - 4 * u, box.center.y)", "shot.at(box.left - 4 * u, box.top + 1 * u)",
      "shot.at(box.left - 4 * u, box.top + 6 * u)", "art(c1, under1), art(c6, under6), art(centre, under)"]),
    ("expect_tint's reader", "private fun kayaLabelTintRead(activity: ComponentActivity, spec: String): String? {",
     ["kayaSkinShot(activity)", "tokens.standalone", "\"none\" to kayaRgb(tokens.text)"]),
    ("expect_selected's reader",
     "private fun kayaSelectedRead(activity: ComponentActivity, spec: String): String? = onUi(activity) {",
     ["root.measureAndLayoutForTest()", "SemanticsProperties.Selected", "it.boundsInWindow.contains("]),
    ("expect_dock's reader", "private fun kayaDockRead(activity: ComponentActivity): String = onUi(activity) {",
     ["val frame = kayaDockFrame", "val above = kayaDockAbove", "above.bottom <= frame.top + 1",
      "val fault = kayaDockContentFault(frame)\nif (fault != null) \"misplaced ($fault; $detail)\""]),
    ("expect_dock's content half", "private fun kayaDockContentFault(dock: androidx.compose.ui.geometry.Rect): String? {",
     ["KayaSceneModel.root", "kayaNodeFrames[n.id]", "kayaNodeVisible[n.id]", "f.bottom > dock.top + 1"]),
    ("expect_fill's skin reading", "private fun kayaFillRead(activity: ComponentActivity, spec: String): String {",
     ["\"hovered\" to overOn(skin.hover, rgb(ground))", "\"selected\" to over(skin.selected)",
      "kayaContrast(sample, kayaRgb(skin.overlayText)) >= 4.5", "art != null && legible && mine < kayaLum(art) / 2", "KayaSceneModel.nodes[holder]?.ground != GROUND_IMAGE"]),
]
MODEL = r"node\.shape\b|node\.labelTint\b|node\.selected\b|node\.activatable\b|node\.selectedDeclared\b"
CALLS = [
    ("the container arm wears its skin", ".then(kayaFilledSurface(node)).padding(kayaFilledInset(node).dp)"),
    ("a click presses an activatable container through its composition",
     "kayaContainerTarget(parts[1])\n?.let { kayaActivators[it.id] }\n?.also { it() } != null"),
    ("the bare image takes the shape", ".then(kayaFrame(node.id)).then(kayaImageShape(node)).onGloballyPositioned {"),
    ("the plain label wears its tint", "color = kayaLabelTintColor(node),\nmaxLines = kayaLabelMaxLines(node), overflow = kayaLabelOverflow(node),\nonTextLayout = { kayaTypefaceSites[\"label\"] = it;"),
    ("the dock rides above the section bar", "Column {\nKayaDockBar(consumesBottom = false)\nNavigationBar("),
    ("the dock is a mount target", "KayaSceneModel.dockRoot = KayaSceneModel.nodes[root]"),
    ("an activatable container takes the filled inset",
     "else if (node.filled != 0L || node.activatable && !kayaInDeclaredTable(node)) KAYA_FILLED_DEFAULT_INSET else node.inset"),
    ("a horizontal slider takes the fader length as its natural width in a row",
     "slider(boxFill.then(capped).then(KayaSliderNatural).then(a11y))"),
    ("the slider's natural width is the fader length",
     "): Int = maxOf(KAYA_FADER_LENGTH.roundToPx(), measurable.maxIntrinsicWidth(height))"),
    ("expect_rows reads nested cells (Y5)", ".mapNotNull { kayaCellText(it) }"),
    ("the overlay's scrim is Material's at 60%", "const val KAYA_OVERLAY_SCRIM = 0.6f"),
    ("a label's tint is its standalone colour outside a fill",
     "if (LocalKayaOnFill.current == null && node.labelTint in 1L..4L) kayaTintPair(node.labelTint).first"),
    ("the theme records the skin tokens", "KayaRecordSkinTokens()\ncontent()"),
    ("a park clamped at the end re-parks when the end grows (Y5)",
     "if (node.scrollState.maxValue != endMax) {\nKayaVTrace.note(\"window\", \"re-park table=${node.id} row=$endPark: the end moved from $endMax to ${node.scrollState.maxValue}\")\nanchorRow = endPark"),
    ("a park clamped by a dip of its end re-parks (Y5)", "} else if (scroll != endScroll && endLow < endScroll) {"),
    ("the table's content measure feeds the end park", "window.measuredContent(contentH)\nwindow.schedule()"),
    ("a table row's surface reaches past its cells (M16 (8))",
     "m.measure(kayaFixedRepresentable(innerW + 2 * groundOut, rowExtents.getOrElse(r) { 0 }))"),
    ("a pushed page is covered inside a section too (M16 (10))", "val covered = kayaCovers()"),
    ("a pushed page whose top is a ground floats a clear bar with its back arrow (M16 (10))",
     "Box(modifier = Modifier.fillMaxSize()) {\nKayaSurface(topConsumed = false)\nKayaMenuTopBar(clear = true)\n}"),
    ("the bar's arrow shows where back reveals something (M16 (9), (10))",
     "navigationIcon = {\nif (kayaCovers()) {"),
    ("a toggle is lit while on (M16 (15))",
     "checkedContainerColor = MaterialTheme.colorScheme.secondaryContainer,"),
    ("a table row's surface starts before its first cell (M16 (8))",
     "p.place(padX - groundOut, rowsTop + tops[r] - rowGapPx / 2)"),
]


def code(text):
    """The text with every `//` comment cut, so prose naming a call is not one."""
    return "\n".join(re.sub(r"//.*", "", line) for line in text.splitlines())


def findings(text):
    out = []
    src = code(text)
    for label, opener, needs, never in DOORS:
        found = blocks(src, opener)
        if len(found) != 1:
            out.append(f"skin: {LABEL}'s {label} is defined {len(found)} times in {REL}, wanted once ({opener})")
            continue
        body = flat(found[0])
        for need in needs:
            if flat(need) not in body:
                out.append(f"skin: {LABEL}'s {label} lacks {need[:90]}")
        for name in never:
            if flat(name) in body:
                out.append(f"skin: {LABEL}'s {label} names {name}, a colour or route of kaya's own where the "
                           f"platform has a token")
    for label, opener, needs in READS:
        found = blocks(src, opener)
        if len(found) != 1:
            out.append(f"skin: {LABEL}'s {label} is gone — {REL} lacks {opener}")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"skin: {LABEL}'s {label} lacks {need}")
        if re.search(MODEL, found[0]):
            out.append(f"skin: {LABEL}'s {label} reaches kaya's model, so it could answer from what the app "
                       f"wrote instead of what the arm drew")
    for label, call in CALLS:
        if flat(call) not in flat(src):
            out.append(f"skin: {LABEL}: {label} no longer holds — {REL} lacks {call.splitlines()[0]}")
    for call in ("KayaPresent.emitActivated(", "KayaPresent.emitSelectionChanged("):
        sites = src.count(call)
        if sites != 1:
            out.append(f"skin: {LABEL}: {call[:-1]} is sent from {sites} sites in {REL}, wanted one, the press "
                       f"door's (docs/styling-pass-plan.md Y4)")
    return out


CUTS = [
    ("Compose: a pushed page in a section without its bar", r"val covered = kayaCovers\(\)",
     "val covered = KayaSceneModel.sections.isEmpty() && kayaCovers()", "a pushed page is covered inside a section too"),
    ("Compose: the toggle unlit while on", r"checkedContainerColor = MaterialTheme\.colorScheme\.secondaryContainer,",
     "", "a toggle is lit while on"),
    ("Compose: the row's surface at its cells' edge", r"p\.place\(padX - groundOut, ", "p.place(padX, ",
     "a table row's surface starts before its first cell"),
    ("Compose: a press beside the door", r"remember\(node\) \{ \{ kayaPress\(node\) \} \}",
     "remember(node) { { KayaPresent.emitActivated(node.tag) } }", "KayaPresent.emitActivated is sent from 2 sites"),
    ("Compose: the pick sent over the app's selection", r"if \(!node\.selected\) KayaPresent\.emitSelectionChanged",
     "KayaPresent.emitSelectionChanged", "press door lacks if (!node.selected)"),
    ("Compose: the pick sent after the activation",
     r"if \(!node\.selected\) KayaPresent\.emitSelectionChanged\(node\.tag\)\n(\s+)KayaPresent\.emitActivated\(node\.tag\)",
     r"KayaPresent.emitActivated(node.tag)\n\1if (!node.selected) KayaPresent.emitSelectionChanged(node.tag)",
     "press door lacks if (!node.selected)"),
    ("Compose: the gradient's top stop a literal", r"listOf\(Color\(0xFF00_0000L or top\), scheme\.background\)",
     "listOf(Color(0xFF5B2A86), scheme.background)", "gradient and image ground lacks"),
    ("Compose: the bottom stop a literal", r"listOf\(Color\(0xFF00_0000L or top\), scheme\.background\)",
     "listOf(Color(0xFF00_0000L or top), Color(0xFF141218))", "gradient and image ground lacks"),
    ("Compose: the gradient's stop unclamped", r"node\.groundTops and 0xFF_FFFF", "node.color and 0xFF_FFFF",
     "gradient and image ground lacks"),
    ("Compose: the image ground stretched", r"ContentScale\.Crop\.computeScaleFactor\(painter\.intrinsicSize, area\)",
     "ContentScale.FillBounds.computeScaleFactor(painter.intrinsicSize, area)", "gradient and image ground lacks"),
    ("Compose: the image ground through paint, which fills its constraints",
     r"Modifier\.clipToBounds\(\) else Modifier\)\.drawBehind \{",
     "Modifier.clipToBounds() else Modifier).paint(painter).drawBehind {",
     "gradient and image ground lacks"),
    ("Compose: the hover layer kaya's grey",
     r"indication = androidx\.compose\.material3\.ripple\(\),\n(\s+)role = Role\.Button,\n(\s+)onClick = activate,\n(\s+)\)\n(\s+)\} else \{",
     "indication = null,\n\\1role = Role.Button,\n\\2onClick = activate,\n\\3).background(Color.Gray)\n\\4} else {",
     "activatable container"),
    ("Compose: the selected surface kaya's own",
     r"surface\.background\(MaterialTheme\.colorScheme\.secondaryContainer, MaterialTheme\.shapes\.medium\)",
     "surface.background(Color(0xFF3355AA), MaterialTheme.shapes.medium)", "container surface"),
    ("Compose: an activatable container no button to the tree", r"role = Role\.Button,\n(\s+)onClick = activate,\n(\s+)\)\n(\s+)\} else \{",
     "onClick = activate,\n\\2)\n\\3} else {", "activatable container lacks role = Role.Button"),
    ("Compose: the selected state unpublished", r"selected = node\.selected,", "selected = false,",
     "activatable container lacks selected = node.selected"),
    ("Compose: the overlay a flat dark fill",
     r"scheme\.scrim\.copy\(alpha = KAYA_OVERLAY_SCRIM\),", "Color(0xCC000000),", "overlay pair"),
    ("Compose: the overlay's text dark in the dark", r"if \(scheme\.background\.luminance\(\) < 0\.5f\) scheme\.onSurface else scheme\.inverseOnSurface,",
     "scheme.inverseOnSurface,", "overlay pair lacks"),
    ("Compose: a tall row's park left short of the grown end", r"if \(node\.scrollState\.maxValue != endMax\) \{",
     "if (false) {", "a park clamped at the end re-parks when the end grows"),
    ("Compose: a park clamped by a dip of its end left short", r"scroll != endScroll && endLow < endScroll\)",
     "scroll != endScroll && false)", "a park clamped by a dip of its end re-parks"),
    ("Compose: the content measure unread by the park", r"window\.measuredContent\(contentH\)\n",
     "", "the table's content measure feeds the end park"),
    ("Compose: the circle clip cut", r"KayaCompose\.SHAPE_CIRCLE -> Modifier\.clip\(CircleShape\)",
     "KayaCompose.SHAPE_CIRCLE -> Modifier", "image shape lacks"),
    ("Compose: the looks left unshaped",
     r"(\.onGloballyPositioned \{ kayaImageDrawn\[node\.id\] = Pair\(it\.size\.width / density, it\.size\.height / density\) \})\n\s+\.then\(kayaImageShape\(node\)\)",
     r"\1", "boxed image lacks"),
    ("Compose: a tinted label over its fill", r"LocalKayaOnFill\.current == null && node\.labelTint in 1L\.\.4L\)",
     "node.labelTint in 1L..4L)", "a label's tint is its standalone colour outside a fill"),
    ("Compose: the dock inside the surface", r"KayaDockBar\(consumesBottom = true\)", "Unit",
     "docked surface lacks"),
    ("Compose: the dock's bar short of the edge", r"\.windowInsetsPadding\(edges\)\n(\s+)\.padding\(KayaSceneModel\.windowInset\.dp\),",
     ".padding(KayaSceneModel.windowInset.dp),", "dock bar lacks"),
    ("Compose: the slider's natural width Material's thumb", r"slider\(boxFill\.then\(capped\)\.then\(KayaSliderNatural\)\.then\(a11y\)\)",
     "slider(boxFill.then(capped).then(a11y))", "a horizontal slider takes the fader length"),
    ("Compose: expect_dock blind to the content", r"if \(fault != null\) \"misplaced \(\$fault; \$detail\)\"\n(\s+)else ",
     "", "expect_dock's reader lacks val fault"),
    ("Compose: expect_dock's content half blind to the dock's top", r"if \(f\.bottom > dock\.top \+ 1\) \{",
     "if (false) {", "expect_dock's content half lacks f.bottom"),
    ("Compose: an activatable container flush against its surface",
     r"node\.filled != 0L \|\| node\.activatable && !kayaInDeclaredTable\(node\)\) KAYA_FILLED_DEFAULT_INSET", "node.filled != 0L) KAYA_FILLED_DEFAULT_INSET",
     "an activatable container takes the filled inset"),
    ("Compose: the shape read off the prop",
     r"(private fun kayaShapeRead\(activity: ComponentActivity, spec: String\): String\? \{\n)",
     r"\1        if (KayaSceneModel.images.any { node -> node.shape == SHAPE_CIRCLE }) return \"circle\"\n",
     "reaches kaya's model"),
    ("Compose: the tint read off the prop",
     r"(private fun kayaLabelTintRead\(activity: ComponentActivity, spec: String\): String\? \{\n)",
     r"\1        if (KayaSceneModel.labels.any { node -> node.labelTint != 0L }) return \"accent\"\n",
     "reaches kaya's model"),
    ("Compose: the gradient's contrast unread", r" &&\n(\s+)contrast >= 4\.5\n", "\n", "lacks contrast >= 4.5"),
    ("Compose: the selected state read off the prop",
     r"when \(chosen\[0\]\.config\.getOrNull\(SemanticsProperties\.Selected\)\) \{",
     "when (if (node.selected) true else null) {", "expect_selected's reader lacks SemanticsProperties.Selected"),
]
