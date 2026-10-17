"""docs/styling-pass-plan.md Y2-Y9, §3: the skin's routes, held where no scene
can see them go.

grounds.steps, shapes.steps, cards.steps, tracks.steps and dock.steps read
what each arm drew. But a gradient whose stop is a literal colour draws the
same header on the lane's one album, a hover painted in kaya's own grey
passes the nearest-candidate read, an `overlay` drawn as a flat dark fill
reads as overlay over the art, a reader that answers from the node agrees
with every write, and a gradient sent to the arm unclamped looks fine in the
light appearance. A backend whose depth stubs go must take a row in BACKENDS.
"""

import importlib
import re

from content_type_routes import flat
from kaya_gate import ROOT
from reveal_routes import blocks

HARNESS = "crates/kaya/src/harness.rs"
SCENE = "crates/kaya/src/scene.rs"
BRAND = "crates/kaya/src/brand.rs"
DOMINANT = "crates/kaya/src/dominant.rs"
SWIFT = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
WINUI_SKIN = "crates/kaya/src/winui/skin.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
FEATURES = ("grounds", "shapes", "cards", "tracks", "dock")
STUBBED = {
    GTK: [f'depth_stub("{f}")' for f in FEATURES],
    WINUI: [f'depth_stub("{f}")' for f in FEATURES],
    COMPOSE: [f'depthStub("{f}")' for f in FEATURES],
}
BACKENDS = {SWIFT: "the SwiftUI arm"}
# One module per widget backend's arm, each exporting REL, LABEL,
# findings(text) -> [str] and CUTS [(label, pattern, replacement, want)].
ARM_MODULES = {GTK: "skin_gtk", WINUI: "skin_winui", COMPOSE: "skin_compose"}


def arm_modules():
    return {rel: importlib.import_module(name) for rel, name in ARM_MODULES.items()
            if (ROOT / "tools/lib" / f"{name}.py").exists()}


def source_key(rel, mod):
    """The text a module reads: its backend's file, or the files it names in
    SOURCES joined in order (an arm split across a file of its own)."""
    return "+".join(getattr(mod, "SOURCES", (rel,)))
# A reader may never answer from what the app wrote.
MODEL = r"node\.shape\b|node\.labelTint\b|node\.selected\b|node\.activatable\b|\.dock\?\.hidden"
# (label, opener, what the block must hold, what it may never name)
DOORS = [
    ("the gradient ground", "struct KayaGroundSurface: ViewModifier {",
     ["LinearGradient(", "colors: [kayaPackedRGB(top), kayaWindowGround()]", "startPoint: .top, endPoint: .bottom",
      "node.groundTops & 0xFF_FFFF", "(node.groundTops >> 24) & 0xFF_FFFF", ".resizable().scaledToFill()", ".clipped()"],
     ["Color(red:", "Color(white:", "node.color"]),
    ("the window ground", "func kayaWindowGround() -> Color {",
     ["Color(nsColor: .windowBackgroundColor)", "Color(uiColor: .systemBackground)"], ["Color(red:"]),
    ("the image's clip", "struct KayaImageShape: ViewModifier {",
     ["content.clipShape(Circle())", "RoundedRectangle(cornerRadius: kayaFilledRadius, style: .continuous)"], []),
    ("the activatable container", "struct KayaActivatable: ViewModifier {",
     [".onTapGesture { KayaHost.emitActivated(node.tag) }", ".accessibilityAction { KayaHost.emitActivated(node.tag) }",
      ".accessibilityAddTraits(node.selected ? [.isButton, .isSelected] : .isButton)", ".onHover { inside in",
      "shape.fill(kayaHoverFill())", "shape.fill(kayaSelectedPair().fill)", ".hoverEffect(.highlight)"],
     ["Color(red:", "Color(white:", "Color.gray", ".opacity("]),
    ("the selected surface", "func kayaSelectedPair() -> (fill: Color, fore: Color) {",
     ["Color(nsColor: .selectedContentBackgroundColor)", "Color(nsColor: .alternateSelectedControlTextColor)",
      "Color(uiColor: .systemFill)"], ["Color(red:"]),
    ("the mac hover layer", "func kayaHoverFill() -> Color {",
     ["Color(nsColor: .quaternarySystemFill)", "Color(nsColor: .quaternaryLabelColor)"], ["Color(red:", ".opacity("]),
    ("the overlay panel", "struct KayaFilledSurface: ViewModifier {",
     ["Rectangle().fill(.regularMaterial)", "Color.black.opacity(kayaOverlayScrim)", ".environment(\\.colorScheme, .dark)"],
     []),
    ("a label's tint", "struct KayaLabelTint: ViewModifier {", ["if !inFill, let colour = kayaStandalone(tint) {"], []),
    ("the standalone colours", "func kayaStandalone(_ tint: Int64) -> Color? {",
     ["dark ? brand[8] : brand[3]", "Color.accentColor", "case tintSuccess: return .green"], ["Color(red:"]),
    ("the dock", "struct KayaDockHost: ViewModifier {",
     [".safeAreaInset(edge: .bottom, spacing: 0)", ".background(.bar, ignoresSafeAreaEdges: .bottom)",
      "kayaHoldsWidget(dock)"], []),
]
# (label, opener, what the block must hold) -- and never MODEL
READS = [
    ("the window's pixels", "func kayaWindowPixels() -> KayaWindowPixels? {",
     ["content.cacheDisplay(in: content.bounds, to: rep)", "window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)",
      "rgba(.windowBackgroundColor)", "rgba(.systemBackground)"]),
    ("expect_ground's reader", "func kayaGroundRead(_ node: KayaNode) -> String {",
     ["kayaWindowPixels()", "kayaContrast(mid, shot.text)", "contrast >= 4.5", "kayaColourGap(bottom, shot.ground)"]),
    ("expect_shape's reader", "func kayaShapeRead(_ node: KayaNode) -> String {",
     ["kayaWindowPixels()", "kayaAnchoredFrame(node.id)", "CGPoint(x: box.minX + 1, y: box.minY + 1)", "CGPoint(x: box.minX + 6, y: box.minY + 6)",
      "shot.at(CGPoint(x: frame.minX - 4, y: frame.midY))"]),
    ("expect_fill's overlay reading", "func kayaFillRead(_ node: KayaNode) -> String {",
     ["kayaPictureAt(pictured,", "mine < 0.06 && mine < theirs / 2"]),
    ("expect_tint's reader", "func kayaLabelTintRead(_ node: KayaNode) -> String {",
     ["kayaWindowPixels()", "kayaAnchoredFrame(node.id)", "shot.text", "tone(.systemGreen)"]),
    ("the platform's frame for a skinned node", "func kayaAnchoredFrame(_ id: UInt64) -> CGRect? {",
     ["kayaHarnessRect(view.bounds, in: view)", "view.convert(view.bounds, to: nil)"]),
    ("expect_selected's readers", "func kayaAxSelectedRead(_ identifier: String, at centre: CGPoint?) -> String {", []),
    ("expect_dock's reader", "func kayaDockRead() -> String {", ["kayaDockFrame", "kayaFindSplitView(content)"]),
    ("hover's route", "func kayaHoverTarget(_ spec: Substring) -> String? {",
     ["window.sendEvent(event)", "owner.mouseEntered(with: enter)", "owner.mouseMoved(with: event)",
      "trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque())", "kayaHovered.contains(node.id)"]),
]
CALLS = [
    (SWIFT, "the container arm wears its ground", ".modifier(KayaGroundSurface(node: node))"),
    (SWIFT, "the container arm takes a click", ".modifier(KayaActivatable(node: node))"),
    (SWIFT, "the boxed image and its looks take the shape",
     "KayaImageBox(node: node)\n.background(KayaLabelFrameReader(id: node.id))\n.modifier(KayaImageShape(shape: node.shape))"),
    (SWIFT, "the label arm wears its tint", ".modifier(KayaLabelTint(tint: node.labelTint))"),
    (SWIFT, "the primary window carries its dock", ".modifier(KayaDockHost(windowId: 0))"),
    (SWIFT, "a target in the dock resolves",
     "for window in kayaScene.windows.values { if let dock = window.dock { stack.append(dock) } }"),
    (SWIFT, "the mac reads AXSelected", "kayaAxCopy(hit, kAXSelectedAttribute as String) as? Bool"),
    (SWIFT, "iOS reads the selected trait", "hit.accessibilityTraits.contains(.selected)"),
    (SWIFT, "a click reaches an activatable container",
     "?? kayaTarget(parts[1], \"row\", kayaScene.rows), node.activatable\n{\nKayaHost.emitActivated(node.tag)"),
    (SWIFT, "the hover layer is the platform's own callback",
     "if inside { kayaHovered.insert(node.id) } else { kayaHovered.remove(node.id) }"),
    (SWIFT, "the mac native table's row takes its tallest cell (Y5)", "height = max(height, content > kayaNativeRowHeight ? content + kayaNativeRowPadding : content)"),
    (SWIFT, "the mac native table asks the core for each row's height (Y5)",
     "let extent = KayaHost.rowExtent(node.id, row)\nreturn extent > 0 ? CGFloat(extent) : kayaNativeRowHeight"),
    (SWIFT, "a height correction keeps the mac table's scroll anchor (Y5)",
     "inProgrammaticScroll = true\ntableView.noteHeightOfRows(\nwithIndexesChanged: IndexSet(\nintegersIn: visible.location..<(visible.location + visible.length)))\ninProgrammaticScroll = false\nreparkAnchor()"),
    (SWIFT, "only the user's own scroll drops the mac table's anchor (Y5)",
     "if !inProgrammaticScroll, let event = NSApp.currentEvent,\n[.scrollWheel, .leftMouseDragged, .leftMouseDown, .keyDown, .swipe].contains(event.type)"),
    (SWIFT, "the mac native table measures only rows AppKit has made (docs/traps.md)",
     "guard self.row(at: row) != nil, let measured = measuredHeight(row) else { continue }"),
    (SWIFT, "the mac native table's first band waits for measured rows (docs/traps.md)",
     "if reported == nil, KayaHost.rowExtent(node.id, presumed.location) == 0 {\nmeasureRows(presumed)"),
    (SWIFT, "a reused view leaves the node it drew before (docs/traps.md)",
     "for (other, views) in kayaSkinAnchors where other != id && views.contains(where: { $0.view === view.view }) {"),
    (SWIFT, "a skinned node's frame anchor is hidden from accessibility and hit testing (docs/traps.md)",
     "KayaSkinFrameAnchor(id: id).accessibilityHidden(true).allowsHitTesting(false)"),
    (SWIFT, "a mac table cell's content settling its size asks for a report (docs/traps.md)",
     "override func invalidateIntrinsicContentSize() {\nsuper.invalidateIntrinsicContentSize()\nonContentSized?()"),
    (SWIFT, "every mac table cell is wired to the report",
     "cell.onContentSized = { [weak self] in self?.scheduleReport() }"),
    (SWIFT, "the skin readers take the newest anchor still in a window",
     "kayaSkinAnchors[id]?.reversed().lazy.compactMap(\\.view).first(where: { $0.window != nil })"),
    (SCENE, "the core lowers every gradient's colour",
     "let (light, dark) = crate::brand::gradient_tops(rgb);\n*packed = (i64::from(light) << 24) | i64::from(dark);"),
    (SCENE, "a transaction's ops pass the lowering", "crate::links::flush_early();\nself.lower_skin(&mut out);"),
    (SCENE, "a band move's ops pass the lowering", "self.assert_bands_hold();\nself.lower_skin(&mut out);\nout"),
    (BRAND, "the dark clamp", "pub(crate) const GRADIENT_DARK_MAX_LSTAR: f64 = 48.0;"),
    (BRAND, "the light clamp", "pub(crate) const GRADIENT_LIGHT_MIN_LSTAR: f64 = 75.0;"),
    (DOMINANT, "one quantizer over the core's decoder", "crate::reader::decode_straight(bytes)"),
    (HARNESS, "harness.rs reads the ground the backend drew", "word_reading(&stage.ground_read(*t), want,"),
    (HARNESS, "harness.rs reads the shape the backend drew", "word_reading(&stage.shape_read(*t), want,"),
    (HARNESS, "harness.rs reads the tint the backend drew", "word_reading(&stage.label_tint(*t), want,"),
    (HARNESS, "harness.rs reads the tree's selected state", "word_reading(&stage.selected_read(*t), want,"),
]

# A pixel reader reads only what the user sees: a target its parents clip is
# refused, never sampled (docs/traps.md, the shape read of a clipped row; no
# scene can tell a refusal from a lucky read of the pixels under the clip).
# (file, label, what must stand, how many times)
VISIBLE = [
    (HARNESS, "the readers' refusal of a clipped probe",
     "let holds = vx <= x + tol && vy <= y + tol && vx + vw >= x + w - tol && vy + vh >= y + h - tol;\n"
     "if !holds {\nreturn Some(format!(\"<clipped by its parents", 1),
    (HARNESS, "the readers' refusal of a probe with nothing on screen",
     "let Some([vx, vy, vw, vh]) = visible.filter(|v| v[2] > 0.0 && v[3] > 0.0) else {", 1),
    (GTK, "GTK's ground, shape and tint readers refuse what their parents clip",
     "if let Some(why) = unseen_in_shot(&widget, &shot.content,", 3),
    (GTK, "GTK's visible part is its ancestors' clip and the window's",
     "clipped_by_ancestors(widget, content, gtk4::graphene::Rect::new(x, y, w, h))\n.and_then(|r| r.intersection(&whole))", 1),
    (WINUI_SKIN, "WinUI's ground, shape and tint readers refuse what their parents clip",
     "if let Some(why) = shot.unseen(&element,", 3),
    (WINUI_SKIN, "WinUI's ground, shape and tint readers read what the element draws, cut by its own slot",
     "let Some((fx, fy, fw, fh)) = shot.drawn(&element) else", 3),
    (WINUI_SKIN, "WinUI's visible part walks every ancestor's viewport and slot",
     "crate::winui::ancestors_cut(&fe, &root, rtl, [x, y, x + w, y + h])?", 1),
    (SWIFT, "SwiftUI's ground, shape and tint readers refuse what their parents clip",
     "if let why = kayaSkinUnseen(node,", 3),
    (SWIFT, "SwiftUI's visible part is its scrolls', its root's and its anchor's clips",
     "var shown = kayaVisibleFrame(node, probed).shown", 1),
    (SWIFT, "SwiftUI's visible part takes its anchor's clipping views",
     "shown = shown.intersection(kayaAnchorClips(view, probed))", 1),
    (SWIFT, "the mac clip view's visible part leaves its content insets, where a table's header floats",
     "let i = clip.contentInsets", 1),
    (COMPOSE, "Compose's ground, shape and tint readers refuse what their parents clip",
     "onUi(activity) { kayaSkinUnseen(", 3),
    (COMPOSE, "Compose's visible part is the node's bounds in the window", "val visible = kayaNodeVisible[id]", 1),
]


def visible_findings(sources):
    out = []
    for rel, label, need, want in VISIBLE:
        got = flat(sources[rel]).count(flat(need))
        if got != want:
            out.append(f"skin: {label}: {rel} holds {need.splitlines()[0]} {got} time(s), wanted {want}")
    return out


# A platform view behind a node answers macOS's hit test at a point in place of
# the control above it (docs/traps.md, the frame anchor that took the hit).
PLATFORM_BEHIND = re.compile(r"\.(?:background|overlay)\(\s*(\w+)\(")
REPRESENTABLE = re.compile(r"struct (\w+): (?:NS|UI)ViewRepresentable")
BEHIND_EXEMPT = {
    "KayaChoiceAnchor": "under its own control, which answers the choice reads' hit test at its centre",
    "KayaExpanderAnchor": "under its own header or body; the header read's hit test answers the disclosure triangle",
    "KayaMacDragDropSurface": "the drag source and drop target's own view, which must receive the drag",
    "KayaPhoneDragDropSurface": "the drag source and drop target's own view, which must receive the drag",
    "KayaSheetAccessor": "reaches its sheet's window; behind every sheet with every sheet leg's reads green",
    "KayaSheetDismissWatcher": "reaches its sheet's controller; behind every sheet with every sheet leg's reads green",
    "KayaWindowAccessor": "reaches its window; behind every root with every hit-test read green",
}


def behind_findings(swift):
    reps = set(REPRESENTABLE.findall(swift))
    used = {m.group(1) for m in PLATFORM_BEHIND.finditer(swift) if m.group(1) in reps}
    out = [f"skin: {name}, a platform view, sits behind a node with accessibility and hit testing on, so "
           f"macOS's hit test at a point can answer it instead of the control above it; wrap it the way "
           f"KayaSkinFrameReader wraps KayaSkinFrameAnchor, or name it in tools/lib/skin_routes.py's "
           f"BEHIND_EXEMPT with a reason" for name in sorted(used - set(BEHIND_EXEMPT))]
    out += [f"skin: BEHIND_EXEMPT names {name}, which no longer sits behind a node"
            for name in sorted(set(BEHIND_EXEMPT) - used)]
    return out


def findings(sources, backends=None):
    arms_held = arm_modules()
    backends = {**BACKENDS, **{rel: m.LABEL for rel, m in arms_held.items()}} if backends is None else backends
    out = []
    for rel, mod in arms_held.items():
        if rel in backends:
            out.extend(mod.findings(sources[source_key(rel, mod)]))
    swift = sources[SWIFT]
    out.extend(behind_findings(swift))
    out.extend(visible_findings(sources))
    for label, opener, needs, never in DOORS:
        found = blocks(swift, opener)
        if len(found) != 1:
            out.append(f"skin: {label} is defined {len(found)} times in {SWIFT}, wanted once ({opener})")
            continue
        body = flat(found[0])
        for need in needs:
            if flat(need) not in body:
                out.append(f"skin: {label} lacks {need}")
        for name in never:
            if flat(name) in body:
                out.append(f"skin: {label} names {name}, a colour of kaya's own where the platform has a token")
    for label, opener, needs in READS:
        found = blocks(swift, opener)
        if not found:
            out.append(f"skin: {label} is gone — {SWIFT} lacks {opener}")
            continue
        for body in found:
            for need in needs:
                if flat(need) not in flat(body):
                    out.append(f"skin: {label} lacks {need}")
            if re.search(MODEL, body):
                out.append(f"skin: {label} reaches kaya's model, so it could answer from what the app wrote "
                           f"instead of what the arm drew")
    for rel, label, call in CALLS:
        if flat(call) not in flat(sources[rel]):
            out.append(f"skin: {label} no longer holds — {rel} lacks {call.splitlines()[0]}")
    for rel, stubs in STUBBED.items():
        gone = [stub for stub in stubs if stub not in sources[rel]]
        if gone and rel not in backends:
            out.append(f"skin: {rel} no longer stubs {', '.join(gone)} and has no row in "
                       f"tools/lib/skin_routes.py's BACKENDS")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8")
               for rel in [HARNESS, SCENE, BRAND, DOMINANT, SWIFT, WINUI_SKIN, *STUBBED]}
    for rel, mod in arm_modules().items():
        key = source_key(rel, mod)
        sources.setdefault(key, "\n".join((ROOT / one).read_text(encoding="utf-8") for one in key.split("+")))
    still = [rel for rel, stubs in STUBBED.items() if all(stub in sources[rel] for stub in stubs)]
    g.counted("skin clauses held",
              sum(len(n) + len(v) + 1 for *_, n, v in DOORS) + sum(len(n) + 2 for *_, n in READS) + len(CALLS)
              + len(VISIBLE),
              floor=70)
    g.counted("skin backends still stubbed", len(still), floor=0)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        ("the gradient's top stop a literal", SWIFT, r"colors: \[kayaPackedRGB\(top\), kayaWindowGround\(\)\]",
         "colors: [Color(red: 0.4, green: 0.2, blue: 0.6), kayaWindowGround()]", "the gradient ground lacks colors:"),
        ("the bottom stop a literal", SWIFT, r"colors: \[kayaPackedRGB\(top\), kayaWindowGround\(\)\]",
         "colors: [kayaPackedRGB(top), Color(white: 0.12)]", "the gradient ground lacks colors:"),
        ("the hover layer kaya's grey", SWIFT, r"shape\.fill\(kayaHoverFill\(\)\)", "shape.fill(Color.gray.opacity(0.1))",
         "the activatable container lacks shape.fill(kayaHoverFill())"),
        ("the selected surface kaya's own", SWIFT, r"shape\.fill\(kayaSelectedPair\(\)\.fill\)",
         "shape.fill(Color(red: 0, green: 0.4, blue: 0.9))", "the activatable container lacks shape.fill(kayaSelectedPair().fill)"),
        ("an activatable container no button to the tree", SWIFT,
         r"\.accessibilityAddTraits\(node\.selected \? \[\.isButton, \.isSelected\] : \.isButton\)",
         ".accessibilityAddTraits([])", "the activatable container lacks .accessibilityAddTraits("),
        ("the overlay a flat dark fill", SWIFT, r"Rectangle\(\)\.fill\(\.regularMaterial\)", "Rectangle().fill(Color.black)",
         "the overlay panel lacks Rectangle().fill(.regularMaterial)"),
        ("the circle clip cut", SWIFT, r"content\.clipShape\(Circle\(\)\)", "content", "the image's clip lacks content.clipShape(Circle())"),
        ("the looks left unshaped", SWIFT,
         r"(KayaImageBox\(node: node\)\n\s+\.background\(KayaLabelFrameReader\(id: node\.id\)\))\n(\s+)\.modifier\(KayaImageShape\(shape: node\.shape\)\)",
         r"\1", "the boxed image and its looks take the shape"),
        ("a tinted label over its fill", SWIFT, r"if !inFill, let colour = kayaStandalone\(tint\) \{",
         "if let colour = kayaStandalone(tint) {", "a label's tint lacks"),
        ("the dock inside the panes", SWIFT, r"\.modifier\(KayaDockHost\(windowId: 0\)\)\n", "",
         "the primary window carries its dock"),
        ("the dock left out of the live census", SWIFT,
         r"for window in kayaScene\.windows\.values \{ if let dock = window\.dock \{ stack\.append\(dock\) \} \}", "",
         "a target in the dock resolves"),
        ("the dock's bar short of the edge", SWIFT, r"\.background\(\.bar, ignoresSafeAreaEdges: \.bottom\)",
         ".background(.bar)", "the dock lacks .background(.bar, ignoresSafeAreaEdges: .bottom)"),
        ("the shape read off the prop", SWIFT, r"(func kayaShapeRead\(_ node: KayaNode\) -> String \{\n)",
         r'\1    if node.shape == shapeCircle { return "circle" }\n', "reaches kaya's model"),
        ("the tint read off the prop", SWIFT, r"(func kayaLabelTintRead\(_ node: KayaNode\) -> String \{\n)",
         r'\1    if node.labelTint != 0 { return "accent" }\n', "reaches kaya's model"),
        ("the gradient's contrast unread", SWIFT, r"&& contrast >= 4\.5", "", "expect_ground's reader lacks contrast >= 4.5"),
        ("hover's verdict off kaya's model", SWIFT,
         r"if inside \{ kayaHovered\.insert\(node\.id\) \} else \{ kayaHovered\.remove\(node\.id\) \}", "",
         "the hover layer is the platform's own callback"),
        ("any clip move read as the user's scroll", SWIFT,
         r"if !inProgrammaticScroll, let event = NSApp\.currentEvent,",
         "if !inProgrammaticScroll, true, let event = NSApp.currentEvent as NSEvent??,",
         "only the user's own scroll drops the mac table's anchor"),
        ("the mac table's rows held at the floor", SWIFT, r"height = max\(height, content > kayaNativeRowHeight \? content \+ kayaNativeRowPadding : content\)",
         "height = max(height, kayaNativeRowHeight)", "the mac native table's row takes its tallest cell"),
        ("the frame anchor open to the hit test", SWIFT,
         r"KayaSkinFrameAnchor\(id: id\)\.accessibilityHidden\(true\)\.allowsHitTesting\(false\)",
         "KayaSkinFrameAnchor(id: id)", "hidden from accessibility and hit testing"),
        ("a bare platform anchor behind a container", SWIFT,
         r"(\.modifier\(KayaActivatable\(node: node\)\)\n\s+)\.background\(KayaSkinFrameReader\(id: node\.id\)\)",
         r"\1.background(KayaSkinFrameAnchor(id: node.id))", "KayaSkinFrameAnchor, a platform view, sits behind a node"),
        ("an exemption that no longer sits behind a node", SWIFT,
         r"\.background\(KayaWindowAccessor\(windowId: (\w+)\)\)", r".onAppear { _ = \1 }",
         "BEHIND_EXEMPT names KayaWindowAccessor", 2),
        ("a cell's resize left unheard", SWIFT,
         r"(super\.invalidateIntrinsicContentSize\(\)\n)\s+onContentSized\?\(\)\n", r"\1",
         "content settling its size asks for a report"),
        ("a cell left unwired", SWIFT,
         r"\s+cell\.onContentSized = \{ \[weak self\] in self\?\.scheduleReport\(\) \}\n", "\n",
         "every mac table cell is wired to the report"),
        ("a height correction read as the user's scroll", SWIFT,
         r"inProgrammaticScroll = true\n(\s+)tableView\.noteHeightOfRows\(",
         r"tableView.noteHeightOfRows(", "a height correction keeps the mac table's scroll anchor"),
        ("an unmade row measured at the floor", SWIFT,
         r"guard self\.row\(at: row\) != nil, let measured = measuredHeight\(row\) else \{ continue \}",
         "guard self.row(at: row) != nil else { continue }\n                let measured = measuredHeight(row) ?? kayaNativeRowHeight",
         "the mac native table measures only rows AppKit has made"),
        ("the first band sized at the floor", SWIFT,
         r"if reported == nil, KayaHost\.rowExtent\(node\.id, presumed\.location\) == 0 \{",
         "if false {", "the mac native table's first band waits for measured rows"),
        ("a reused view kept by the node it drew before", SWIFT,
         r"    for \(other, views\) in kayaSkinAnchors where other != id && views\.contains\(where: \{ \$0\.view === view\.view \}\) \{\n        kayaSkinAnchors\[other\] = views\.filter \{ \$0\.view != nil && \$0\.view !== view\.view \}\n    \}\n",
         "", "a reused view leaves the node it drew before"),
        ("the clamp removed", SCENE,
         r"let \(light, dark\) = crate::brand::gradient_tops\(rgb\);",
         "let (light, dark) = (rgb, rgb);", "the core lowers every gradient's colour"),
        ("a band move's ops unlowered", SCENE, r"self\.assert_bands_hold\(\);\n(\s+)self\.lower_skin\(&mut out\);\n(\s+)out",
         r"self.assert_bands_hold();\n\2out", "a band move's ops pass the lowering"),
        ("the dark clamp loosened", BRAND, r"GRADIENT_DARK_MAX_LSTAR: f64 = 48\.0;", "GRADIENT_DARK_MAX_LSTAR: f64 = 60.0;",
         "the dark clamp"),
        ("the readers sampling a clipped probe", HARNESS,
         r"let holds = vx <= x \+ tol && vy <= y \+ tol && ", "let holds = true || vx <= x + tol && vy <= y + tol && ",
         "the readers' refusal of a clipped probe"),
        ("GTK's shape read of a clipped row, as shipped", GTK,
         r"if let Some\(why\) = unseen_in_shot\(&widget, &shot\.content, \[fx, fy, fw, fh\]\) \{\n(\s+)return why;\n(\s+)\}\n(\s+)let Some\(under\)",
         r"if let Some(why) = None::<String> {\n\1return why;\n\2}\n\3let Some(under)", "GTK's ground, shape and tint readers refuse"),
        ("GTK's visible part blind to the window's edge", GTK, r"\n\s+\.and_then\(\|r\| r\.intersection\(&whole\)\)",
         "", "GTK's visible part is its ancestors' clip and the window's"),
        ("WinUI's ground, shape and tint reads of a clipped target", WINUI_SKIN,
         r"if let Some\(why\) = shot\.unseen\(&element, \[fx, fy, fw, fh\]\)\? \{",
         "if let Some(why) = None::<String> {", "WinUI's ground, shape and tint readers refuse", 3),
        ("WinUI's shape read over the wide picture's whole box, as first written", WINUI_SKIN,
         r"let Some\(\(fx, fy, fw, fh\)\) = shot\.drawn\(&element\) else \{ return Ok\(\"<no laid-out frame>\"\.into\(\)\) \};\n(\s+)if fw <= 12\.0",
         r"let Some((fx, fy, fw, fh)) = shot.frame(&element) else { return Ok(\"<no laid-out frame>\".into()) };\n\1if fw <= 12.0",
         "WinUI's ground, shape and tint readers read what the element draws"),
        ("WinUI's visible part walking no ancestor", WINUI_SKIN,
         r"crate::winui::ancestors_cut\(&fe, &root, rtl, \[x, y, x \+ w, y \+ h\]\)\?", "[x, y, x + w, y + h]",
         "WinUI's visible part walks every ancestor"),
        ("SwiftUI's shape read of a clipped row", SWIFT,
         r"if let why = kayaSkinUnseen\(node, frame\) \{ return why \}\n(\s+)guard let shot = kayaWindowPixels\(\) else \{ return \"<no window pixels>\" \}\n(\s+)// What the image sits on",
         r"guard let shot = kayaWindowPixels() else { return \"<no window pixels>\" }\n\2// What the image sits on",
         "SwiftUI's ground, shape and tint readers refuse"),
        ("SwiftUI's visible part blind to its anchor's clip views", SWIFT,
         r"shown = shown\.intersection\(kayaAnchorClips\(view, probed\)\)", "_ = view",
         "SwiftUI's visible part takes its anchor's clipping views"),
        ("the mac table's header read as visible, as first written", SWIFT, r"let i = clip\.contentInsets",
         "let i = NSEdgeInsets()", "the mac clip view's visible part leaves its content insets"),
        ("Compose's shape read of a clipped row", COMPOSE,
         r"onUi\(activity\) \{ kayaSkinUnseen\(frame\.second, box, u\) \}", "null",
         "Compose's ground, shape and tint readers refuse"),
        ("Compose's visible part the unclipped frame", COMPOSE, r"val visible = kayaNodeVisible\[id\]",
         "val visible = kayaNodeFrames[id]", "Compose's visible part is the node's bounds"),
        ("harness.rs reading the model", HARNESS, r"word_reading\(&stage\.shape_read\(\*t\), want,",
         'word_reading("rect", want,', "harness.rs reads the shape the backend drew"),
    ]
    for rel, mod in arm_modules().items():
        cuts.extend((label, source_key(rel, mod), pattern, repl, want) for label, pattern, repl, want in mod.CUTS)
    for label, rel, pattern, repl, want, *count in cuts:
        broken = g.doctor(f"skin: {label}", sources[rel], pattern, repl, want=count[0] if count else 1)
        g.negative(f"skin: {label}", lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want=want)
    for rel in [rel for rel in STUBBED if rel not in still]:
        g.negative(f"skin: {rel}'s row withheld", lambda: findings(sources, backends=BACKENDS),
                   want=f"{rel} no longer stubs")
    for rel in still:
        broken = sources[rel]
        for stub in STUBBED[rel]:
            broken = g.doctor(f"skin: {rel}'s {stub} gone without a row", broken, re.escape(stub), "todo!()",
                              want=sources[rel].count(stub))
        g.negative(f"skin: {rel}'s stubs gone without a row",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want="no longer stubs")
