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
     ["LinearGradient(", "colors: [kayaPackedRGB(top), kayaWindowGround(grouped: grouped)]", "startPoint: .top, endPoint: .bottom",
      "node.groundTops & 0xFF_FFFF", "(node.groundTops >> 24) & 0xFF_FFFF", ".resizable().scaledToFill()", ".clipped()"],
     ["Color(red:", "Color(white:", "node.color"]),
    ("the window ground", "func kayaWindowGround(grouped: Bool = false) -> Color {",
     ["Color(nsColor: .windowBackgroundColor)",
      "Color(uiColor: grouped ? .systemGroupedBackground : .systemBackground)"], ["Color(red:"]),
    ("the image's clip", "struct KayaImageShape: ViewModifier {",
     ["content.clipShape(Circle())", "RoundedRectangle(cornerRadius: kayaFilledRadius, style: .continuous)"], []),
    ("the activatable container", "struct KayaActivatable: ViewModifier {",
     [".onTapGesture { KayaHost.emitPress(node) }", ".accessibilityAction { KayaHost.emitPress(node) }",
      ".accessibilityAddTraits(node.selected ? [.isButton, .isSelected] : .isButton)", ".onHover { inside in",
      "shape.fill(kayaHoverFill())", "shape.fill(kayaSelectedPair().fill)", ".hoverEffect(.highlight)"],
     ["Color(red:", "Color(white:", "Color.gray", ".opacity("]),
    ("the selected surface", "func kayaSelectedPair() -> (fill: Color, fore: Color) {",
     ["Color(nsColor: .selectedContentBackgroundColor)", "Color(nsColor: .alternateSelectedControlTextColor)",
      "Color(uiColor: .systemGray4)"], ["Color(red:", "Color(uiColor: .systemFill)"]),
    ("the mac hover layer", "func kayaHoverFill() -> Color {",
     ["Color(nsColor: .quaternarySystemFill)", "Color(nsColor: .quaternaryLabelColor)"], ["Color(red:", ".opacity("]),
    ("the overlay panel", "struct KayaFilledSurface: ViewModifier {",
     ["Rectangle().fill(.regularMaterial)", "Color.black.opacity(kayaOverlayScrim)", ".environment(\\.colorScheme, .dark)"],
     []),
    ("a label's tint", "struct KayaLabelTint: ViewModifier {", ["if !inFill, let colour = kayaStandalone(tint) {"], []),
    ("the standalone colours", "func kayaStandalone(_ tint: Int64) -> Color? {",
     ["dark ? brand[8] : brand[3]", "Color.accentColor", "case tintSuccess: return .green"], ["Color(red:"]),
    ("the dock", "struct KayaDockHost: ViewModifier {",
     # macOS stacks the bar under the content, since a NavigationSplitView's
     # columns ignore a bottom inset (docs/traps.md, the panes the dock covered).
     ["VStack(spacing: 0) {\ncontent.frame(maxWidth: .infinity, maxHeight: .infinity)\nbar",
      "content.safeAreaInset(edge: .bottom, spacing: 0) { bar }",
      ".background(.bar, ignoresSafeAreaEdges: .bottom)",
      "kayaHoldsWidget(dock)", "KayaRender(node: dock, isRoot: true)\n.fixedSize(horizontal: false, vertical: true)",
      "@ViewBuilder private var bar: some View {\nif let dock = scene.windows[windowId]?.dock"], []),
    # docs/media-player-plan.md M18: iOS's accessory sets the dock's vertical
    # rhythm, caps its pictures and adds no side padding of its own.
    ("the phone dock", "struct KayaTabAccessory: ViewModifier {",
     [".environment(\\.kayaPhoneDockArt, kayaPhoneDockArt)", ".padding(.vertical, kayaPhoneDockPadY)",
      ".frame(maxWidth: .infinity, maxHeight: .infinity)"], [".padding(.horizontal"]),
    ("the phone dock's containers", "struct KayaInsetPadding: ViewModifier {",
     ["if phoneDock != nil {\ncontent.padding(.horizontal, node.insetSet ? node.inset : 0)",
      "content.padding(kayaFilledInset(node))"], []),
    ("the phone dock's boxed picture", "private struct KayaImageBox: View {",
     ["let box = kayaDockClamp(CGSize(width: node.maxWidth, height: node.maxHeight), dockArt)"], []),
]
# Y4 on the macOS native tier (AMENDED 2026-10-17): a user's click and arrows
# move the NSTableView's own selection and the app is told by selection_changed;
# `on_activate` is its double-click action and Return; the app's `selected`
# WRITES move the selection, held across a reload, which empties it
# (docs/traps.md, the native table's selection). The harness reaches the
# table's own doors rather than the emits. Elsewhere one press door tells the
# pick before the activation. tracks.steps reads none of these routes.
# (label, opener, what the block must hold, what it may never name)
NATIVE_TABLE = [
    ("the press door", "static func emitPress(_ node: KayaNode) {",
     ["if !node.selected { emitSelectionChanged(node.tag) }", "emitActivated(node.tag)"], []),
    ("the user's pick told", "func tableViewSelectionDidChange(_ notification: Notification) {",
     ["guard !applyingSelection, let pick = userPick else { return }", "userPick = nil", "held = [stamped.tag]",
      "guard stamped.activatable else", "KayaHost.emitSelectionChanged(stamped.tag)"], ["emitActivated"]),
    ("the table holding the keyboard", "func holdsKeyboard() -> NSWindow? {", ["window.firstResponder === tableView"], []),
    ("the native table's wiring", "func build() -> NSScrollView {",
     ["tableView.target = self", "tableView.doubleAction = #selector(rowDoubleClicked(_:))", "tableView.onReturn = {",
      "return self.activate(row: self.tableView.selectedRow)",
      "tableView.setAccessibilityIdentifier(kayaNativeTableAxId(node.id))"], []),
    ("the native table's double-click action", "@objc func rowDoubleClicked(_ sender: NSTableView) {",
     ["_ = activate(row: sender.clickedRow)"], []),
    ("the native table's activation door", "func activate(row index: Int) -> Bool {",
     ["guard stamped.activatable else", "KayaHost.emitActivated(stamped.tag)"], []),
    ("Return on the native table", "final class KayaNativeTableView: NSTableView {",
     ["if [36, 76].contains(event.keyCode), onReturn?() == true { return }",
      "override var clickedRow: Int { harnessClickedRow ?? super.clickedRow }"], []),
    ("the native table's selection", "private func applySelection() {",
     ["if was != stamped.selected, was != nil || stamped.selected {",
      "if stamped.selected { held.insert(stamped.tag) } else { held.remove(stamped.tag) }",
      "if held.contains(stamped.tag) { want.insert(base + offset) }",
      "tableView.selectRowIndexes(want, byExtendingSelection: false)"], []),
    ("a user's selection on the native table", "selectionIndexesForProposedSelection proposed: IndexSet",
     ["if applyingSelection { return proposed }", "if proposed.isEmpty || proposed == current {", "userPick = pick",
      "return pick"], []),
    ("the harness's click", "func userClick(_ stamped: KayaNode, clicks: Int) -> String? {",
     ["tableView.window?.makeFirstResponder(tableView)",
      "tableView.setValue([axRows[index]], forKey: \"accessibilitySelectedRows\")",
      "sent = tableView.sendAction(action, to: tableView.target)", "tableView.harnessClickedRow = index"],
     ["emitActivated", "emitSelectionChanged", "selectRowIndexes"]),
    ("the synthesized table row's ground", "private struct KayaTableRowGround: View {",
     [".onTapGesture { KayaHost.emitPress(row) }", "kayaSelectedPair().fill",
      ".accessibilityIdentifier(row.a11yId)", ".accessibilityAddTraits(row.selected ? [.isButton, .isSelected] : .isButton)",
      ".background(KayaSkinFrameReader(id: row.id))"], ["Color(red:", "Color.gray"]),
    ("a synthesized row's cells", "private struct KayaTableRowPress: ViewModifier {",
     [".onTapGesture { KayaHost.emitPress(row) }", "kayaSelectedPair().fore",
      ".environment(\\.kayaInFill, row.selected && kayaSelectionTakesText)"], []),
]


def native_table_findings(swift):
    out = []
    for label, opener, needs, never in NATIVE_TABLE:
        found = blocks(swift, opener)
        if len(found) != 1:
            out.append(f"skin: {label} is defined {len(found)} times in {SWIFT}, wanted once ({opener})")
            continue
        body = flat(found[0])
        out += [f"skin: {label} lacks {need}" for need in needs if flat(need) not in body]
        out += [f"skin: {label} names {name}, which the platform's own route replaces"
                for name in never if flat(name) in body]
    return out


# (label, opener, what the block must hold) -- and never MODEL
READS = [
    ("the window's pixels", "func kayaWindowPixels() -> KayaWindowPixels? {",
     ["content.cacheDisplay(in: content.bounds, to: rep)", "window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)",
      "rgba(.windowBackgroundColor)", "rgba(.systemBackground)"]),
    ("expect_ground's reader", "func kayaGroundRead(_ node: KayaNode) -> String {",
     ["kayaWindowPixels()", "kayaContrast(mid, shot.text)", "contrast >= 4.5", "kayaColourGap(bottom, page)",
      "kayaScene.groupedGrounds.contains(node.id) ? shot.groupedGround : shot.ground"]),
    ("expect_shape's reader", "func kayaShapeRead(_ node: KayaNode) -> String {",
     ["kayaWindowPixels()", "kayaAnchoredFrame(node.id)", "CGPoint(x: box.minX + 1, y: box.minY + 1)", "CGPoint(x: box.minX + 6, y: box.minY + 6)",
      "shot.at(CGPoint(x: box.minX - 4, y: box.midY))", "shot.at(CGPoint(x: box.minX - 4, y: box.minY + 1))",
      "shot.at(CGPoint(x: box.minX - 4, y: box.minY + 6))", "art(c1, under1), art(c6, under6), art(centre, under)"]),
    ("expect_fill's overlay reading", "func kayaFillRead(_ node: KayaNode) -> String {",
     ["kayaPictureAt(pictured,", "1.05 / (mine + 0.05) >= 4.5 && mine < theirs / 2"]),
    ("expect_tint's reader", "func kayaLabelTintRead(_ node: KayaNode) -> String {",
     ["kayaWindowPixels()", "kayaAnchoredFrame(node.id)", "shot.text", "tone(.systemGreen)"]),
    ("the platform's frame for a skinned node", "func kayaAnchoredFrame(_ id: UInt64) -> CGRect? {",
     ["kayaHarnessRect(view.bounds, in: view)", "view.convert(view.bounds, to: nil)"]),
    ("expect_selected's readers", "func kayaAxSelectedRead(_ identifier: String, at centre: CGPoint?) -> String {", []),
    ("expect_selected's native table reader", "func kayaAxTableRowSelected(_ table: String, _ index: Int) -> String {",
     ["kayaAxFindAll(app, table, 0, &matches)", "kayaAxCopy(hit, kAXRowsAttribute as String)",
      "kayaAxCopy(rows[index], kAXSelectedAttribute as String) as? Bool"]),
    ("expect_dock's reader", "func kayaDockRead() -> String {",
     ["kayaDockFrame", "kayaFindSplitView(content)", "if let fault = kayaDockContentFault(frame)"]),
    ("expect_dock_height's reader", "func kayaDockHeightRead() -> String {",
     ["guard let frame = kayaDockFrame, frame.height > 1", "String(format: \"%.1f\", frame.height)"]),
    # docs/media-player-plan.md M19: a declared table row's selection surface
    # clears its cells by the tier's cell padding, and its cells sit on its centre.
    ("expect_row_inset's reader", "@MainActor func kayaRowInsetRead(_ spec: Substring) -> String? {",
     ["kayaRowBoxes(row)", "lead + 0.5 >= boxes.pad && trail + 0.5 >= boxes.pad",
      "guard let drawn = kayaRowFillDrawn(fill, boxes.cells) else { return \"\" }"]),
    ("expect_row_inset's pixel half", "@MainActor func kayaRowFillDrawn(_ fill: CGRect, _ cells: [CGRect]) -> String? {",
     ["kayaWindowPixels()", "shot.at(CGPoint(x: fill.minX + 2, y: y))", "shot.at(CGPoint(x: fill.maxX - 2, y: y))",
      "if kayaColourGap(between, outside) <= 0.02 { return nil }",
      "if kayaColourGap(lead, between) <= 0.02 && kayaColourGap(trail, between) <= 0.02 { return \"\" }"]),
    ("expect_row_centered's reader", "@MainActor func kayaRowCenteredRead(_ spec: Substring) -> String? {",
     ["kayaRowBoxes(row)", "abs(worst.1) > 2 else"]),
    ("the row readers' boxes",
     "@MainActor func kayaRowBoxes(_ row: KayaNode) -> (fill: CGRect?, cells: [CGRect], pad: CGFloat, native: Bool)? {",
     ["driver.rowGeometry(of: row)", "table.tableCellFrames[kayaTableCellKey(row, $0.offset, $0.element)]?.frame",
      "return (kayaAnchoredFrame(row.id), cells, kayaTableCardInsetX, false)"]),
    ("expect_dock's content half", "func kayaDockContentFault(_ dock: CGRect) -> String? {",
     ["kayaScene.windows[0], let root = window.root", "if let shown = window.entries.last?.root { walk(shown) }",
      "let collection = n.children.contains { $0.id >= 1 << 63 }",
      "kayaPlatformFrame(n)", "kayaVisibleFrame(n, f).shown", "f.maxY > dock.minY + 1"]),
    ("hover's route", "func kayaHoverTarget(_ spec: Substring) -> String? {",
     ["window.sendEvent(event)", "owner.mouseEntered(with: enter)", "owner.mouseMoved(with: event)",
      "trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque())", "kayaHovered.contains(node.id)"]),
]
CALLS = [
    (SWIFT, "a stacked root whose top is a picture takes the inline title (M16 (27))",
     ".navigationTitle(kayaWindowCaption(windowId))\n.modifier(KayaPictureTopTitle(root: scene.windows[windowId]?.root))"),
    (SWIFT, "the primary root whose top is a picture takes the inline title (M16 (27))",
     ".navigationTitle(kayaWindowCaption(0))\n.modifier(KayaPictureTopTitle(root: scene.root))"),
    (SWIFT, "the inline title is iOS's own (M16 (27))",
     "if let root, kayaTopIsPicture(root) {\ncontent.navigationBarTitleDisplayMode(.inline)"),
    (SWIFT, "a picture is an image ground or a bled image (M16 (27))",
     "if node.ground == groundImage || (node.kind == kindImage && node.bleed) { return true }"),
    (SWIFT, "a grid of cards stands bare in a grouped flow (M16 (5))",
     "} else if kayaIsShelf(node) {"),
    (SWIFT, "a grouped flow's shelf is drawn uncarded (M16 (5))",
     "case .shelf(let grid):\nKayaRender(node: grid, flexVertical: true, flexStretch: true)"),
    (SWIFT, "a shelf is a grid whose every cell is a card (M16 (5))",
     "node.kind == kindGrid && !node.children.isEmpty\n&& node.children.allSatisfy { $0.filled != 0 || $0.activatable }"),
    (SWIFT, "the container arm takes a click", ".modifier(KayaActivatable(node: node))"),
    (SWIFT, "the boxed image and its looks take the shape",
     "KayaImageBox(node: node)\n.background(KayaLabelFrameReader(id: node.id))\n.modifier(KayaImageShape(shape: node.shape))"),
    (SWIFT, "the label arm wears its tint", ".modifier(KayaLabelTint(tint: node.labelTint))"),
    (SWIFT, "the primary window carries its dock", ".modifier(KayaDockHost(windowId: 0))"),
    (SWIFT, "the phone dock's rhythm (M18)", "let kayaPhoneDockArt: CGFloat = 32\nlet kayaPhoneDockPadY: CGFloat = 8"),
    (SWIFT, "a container pads through the phone dock's rule (M18)",
     ".background(KayaInsetReader(id: node.id, outer: false))\n.modifier(KayaInsetPadding(node: node))"),
    (SWIFT, "an activatable container takes the filled inset",
     "(node.filled != 0 || node.activatable && !kayaInDeclaredTable(node)) && !node.insetSet"),
    (SWIFT, "iOS's neutral selection keeps a tinted label's colour",
     "let kayaSelectionTakesText: Bool = {\n#if os(macOS)\ntrue\n#else\nfalse\n#endif\n}()"),
    (SWIFT, "a target in the dock resolves",
     "for window in kayaScene.windows.values { if let dock = window.dock { stack.append(dock) } }"),
    (SWIFT, "the mac reads AXSelected", "kayaAxCopy(hit, kAXSelectedAttribute as String) as? Bool"),
    (SWIFT, "iOS reads the selected trait", "hit.accessibilityTraits.contains(.selected)"),
    (SWIFT, "a click reaches an activatable container",
     "?? kayaTarget(parts[1], \"row\", kayaScene.rows), node.activatable\n{\nKayaHost.emitPress(node)"),
    (SWIFT, "a click on a native table's row takes the table's own click, before the emit (Y4)",
     "refused = driver.userClick(node, clicks: 1)\nreturn refused == nil\n}\n#endif\n"
     "// An activatable row or column takes the click as a whole"),
    (SWIFT, "a double-click on a native table's row takes the table's own (Y4)",
     "refused = driver.userClick(node, clicks: 2)\nreturn refused == nil"),
    (SWIFT, "a press tells the pick before the activation (Y4)",
     "if !node.selected { emitSelectionChanged(node.tag) }\nemitActivated(node.tag)"),
    (SWIFT, "a reload keeps the native table's selection (Y4)", "tableView.reloadData()\napplySelection()"),
    (SWIFT, "a key at a native table holding the keyboard goes to it (Y4)",
     "kayaTableDrivers.values.lazy.compactMap({ $0.holdsKeyboard() }).first\nelse { return false }\n"
     "return kayaSendNamedKey(String(parts[1]), to: window)"),
    (SWIFT, "expect_selected on a native table's row reads the table's AXRows (Y4)",
     "if let found, let index = found.2 { return kayaAxTableRowSelected(found.0, index) }"),
    (SWIFT, "every report puts the app's selection on the native table (Y4)",
     "refresh()\napplySelection()\nlayoutColumns()"),
    (SWIFT, "a synthesized row's cells pass their press to the row (Y4)", ".modifier(KayaTableRowPress(row: row))"),
    (SWIFT, "the synthesized table stamps one ground per row (Y4)",
     "ForEach(node.children) { row in\nKayaTableRowGround(row: row)\n}"),
    (SWIFT, "the synthesized table's layout knows its grounds (Y4)", "rowCount: node.children.count"),
    (SWIFT, "the synthesized table's layout places each row's ground across the card (Y4, M19)",
     "grounds[r].place(\nat: CGPoint(x: bounds.minX - kayaTableCardInsetX, y: y - rowGap / 2),\nanchor: .topLeading,"),
    (SWIFT, "a synthesized row's cells sit on the row's centre (M19)",
     "at: CGPoint(x: colX[c], y: y + (rowH - cellH) / 2), anchor: .topLeading,"),
    (SWIFT, "the columns' clip lets the row grounds reach the card (M19)",
     ".clipShape(KayaRowGroundClip(outset: kayaTableCardInsetX))"),
    (SWIFT, "the iOS card clips its rows' grounds at its corners (M19)",
     ".background(kayaCardShape())\n.clipShape(.rect(cornerRadius: kayaTableCardRadius, style: .continuous))"),
    (COMPOSE, "the Compose table stamps one ground per row under its cells (Y4)",
     "rows.forEach { row -> KayaTableRowGround(row) }\nrows.forEach { row ->"),
    (COMPOSE, "the Compose table's cells are counted past the grounds (Y4)",
     "val cells = measurables.subList(nFolded + cols + 1 + nRows, measurables.size - 3)"),
    (COMPOSE, "a Compose table row's ground is the activatable surface (Y4)",
     "Box(if (row.activatable) tag.then(kayaFilledSurface(row)) else Modifier)"),
    (WINUI, "WinUI's table rows read through an activatable row's ItemContainer (Y4)",
     "let held = skin::inner_of(&child).unwrap_or_else(|| child.clone());"),
    (WINUI, "WinUI's scroll walk crosses an ItemContainer's template (Y4)",
     "Err(_) => match VisualTreeHelper::GetParent(&current) {"),
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
    (SWIFT, "the mac native table's first band is not reported over a stamped row with no cell (docs/traps.md)",
     "if reported == nil, firstBandWaits(visible) {\nrecordGeometry(visible)\nreturn"),
    (SWIFT, "the first band's wait counts every stamped row with no height (docs/traps.md)",
     "if self.row(at: row) != nil, KayaHost.rowExtent(node.id, row) == 0 { unmade.append(row) }"),
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
    (BRAND, "the light clamp keeps the data colour's chroma (docs/media-player-plan.md M15)",
     "let mut top = lift_keeping_chroma(rgb, target);"),
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
    # Four on GTK, WinUI and Compose: the ground colour's top read is the fourth
    # (docs/media-player-plan.md M16 (35)); SwiftUI's spells its refusal inline.
    (GTK, "GTK's ground, shape and tint readers refuse what their parents clip",
     "if let Some(why) = unseen_in_shot(&widget, &shot.content,", 4),
    (GTK, "GTK's visible part is its ancestors' clip and the window's",
     "clipped_by_ancestors(widget, content, gtk4::graphene::Rect::new(x, y, w, h))\n.and_then(|r| r.intersection(&whole))", 1),
    (WINUI_SKIN, "WinUI's ground, shape and tint readers refuse what their parents clip",
     "if let Some(why) = shot.unseen(&element,", 4),
    (WINUI_SKIN, "WinUI's ground, shape and tint readers read what the element draws, cut by its own slot",
     "let Some((fx, fy, fw, fh)) = shot.drawn(&element) else", 4),
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
     "onUi(activity) { kayaSkinUnseen(", 4),
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
    out.extend(native_table_findings(swift))
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
              + sum(len(n) + len(v) + 1 for *_, n, v in NATIVE_TABLE)
              + len(VISIBLE),
              floor=70)
    g.counted("skin backends still stubbed", len(still), floor=0)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        ("a picture-topped root left with its large title (M16 (27))", SWIFT,
         r"content\.navigationBarTitleDisplayMode\(\.inline\)\n(\s+)\} else \{\n(\s+)content\n(\s+)\}\n(\s+)#else",
         "content\n\\1} else {\n\\2content\n\\3}\n\\4#else", "the inline title is iOS's own"),
        ("a grid of cards carded in a grouped flow (M16 (5))", SWIFT,
         r"\} else if kayaIsShelf\(node\) \{", "} else if false {", "a grid of cards stands bare in a grouped flow"),
        ("the shape probes against one ground", SWIFT,
         r"art\(c1, under1\), art\(c6, under6\), art\(centre, under\)",
         "art(c1, under), art(c6, under), art(centre, under)", "expect_shape's reader lacks"),
        ("the gradient's top stop a literal", SWIFT, r"colors: \[kayaPackedRGB\(top\), kayaWindowGround\(grouped: grouped\)\]",
         "colors: [Color(red: 0.4, green: 0.2, blue: 0.6), kayaWindowGround(grouped: grouped)]", "the gradient ground lacks colors:"),
        ("the bottom stop a literal", SWIFT, r"colors: \[kayaPackedRGB\(top\), kayaWindowGround\(grouped: grouped\)\]",
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
        ("a selected synthesized row dropping its tint", SWIFT,
         r"\.environment\(\\\.kayaInFill, row\.selected && kayaSelectionTakesText\)",
         ".environment(\\.kayaInFill, row.selected)", "a synthesized row's cells lacks .environment"),
        ("iOS's selection taking the text", SWIFT, r"(#if os\(macOS\)\n\s+true\n\s+#else\n\s+)false",
         r"\1true", "iOS's neutral selection keeps a tinted label's colour"),
        ("an activatable container flush against its surface", SWIFT,
         r"\(node\.filled != 0 \|\| node\.activatable && !kayaInDeclaredTable\(node\)\) && !node\.insetSet", "node.filled != 0 && !node.insetSet",
         "an activatable container takes the filled inset"),
        ("the mac dock as the inset the panes ignore, as first built", SWIFT,
         r"VStack\(spacing: 0\) \{\n(\s+)content\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)\n\s+bar\n",
         r"content.safeAreaInset(edge: .bottom, spacing: 0) {\n\1bar\n", "the dock lacks VStack(spacing: 0)"),
        ("expect_dock's content half blind to the shown entry", SWIFT,
         r"\n\s+if let shown = window\.entries\.last\?\.root \{ walk\(shown\) \}", "",
         "expect_dock's content half lacks if let shown"),
        ("the dock's root filling the window", SWIFT,
         r"(KayaRender\(node: dock, isRoot: true\))\n\s+\.fixedSize\(horizontal: false, vertical: true\)", r"\1",
         "the dock lacks KayaRender(node: dock, isRoot: true)"),
        ("expect_dock blind to the content", SWIFT,
         r"\n\s+if let fault = kayaDockContentFault\(frame\) \{ return \"misplaced \(\\\(fault\); \\\(detail\)\)\" \}", "",
         "expect_dock's reader lacks if let fault"),
        ("expect_dock's content half blind to the dock's top", SWIFT, r"if f\.maxY > dock\.minY \+ 1 \{",
         "if false {", "expect_dock's content half lacks f.maxY"),
        ("the phone dock's art edge to edge, as first built (M18)", SWIFT,
         r"\n\s+\.environment\(\\\.kayaPhoneDockArt, kayaPhoneDockArt\)\n\s+\.padding\(\.vertical, kayaPhoneDockPadY\)", "",
         "the phone dock lacks .environment"),
        ("the phone dock's own side padding back (M18)", SWIFT,
         r"(\.environment\(\\\.kayaPhoneDockArt, kayaPhoneDockArt\)\n)", r"\1.padding(.horizontal, 12)\n",
         "the phone dock names .padding(.horizontal"),
        ("the phone dock's art back to 48 (M18)", SWIFT, r"let kayaPhoneDockArt: CGFloat = 32", "let kayaPhoneDockArt: CGFloat = 48",
         "the phone dock's rhythm (M18) no longer holds"),
        ("a container padded all round in the phone dock (M18)", SWIFT,
         r"\.modifier\(KayaInsetPadding\(node: node\)\)", ".padding(kayaFilledInset(node))",
         "a container pads through the phone dock's rule"),
        ("the synthesized row's ground back at the cells' box (M19)", SWIFT,
         r"at: CGPoint\(x: bounds\.minX - kayaTableCardInsetX, y: y - rowGap / 2\),", "at: CGPoint(x: bounds.minX, y: y - rowGap / 2),",
         "the synthesized table's layout places each row's ground across the card (Y4, M19) no longer holds"),
        ("the synthesized row's cells back at the row's top (M19)", SWIFT, r"y: y \+ \(rowH - cellH\) / 2\)", "y: y)",
         "a synthesized row's cells sit on the row's centre (M19) no longer holds"),
        ("the iOS card's corners unclipped (M19)", SWIFT,
         r"\n\s+\.clipShape\(\.rect\(cornerRadius: kayaTableCardRadius, style: \.continuous\)\)", "",
         "the iOS card clips its rows' grounds at its corners (M19) no longer holds"),
        ("the columns' clip back at the cells' box (M19)", SWIFT,
         r"\.clipShape\(KayaRowGroundClip\(outset: kayaTableCardInsetX\)\)", ".clipped()",
         "the columns' clip lets the row grounds reach the card (M19) no longer holds"),
        ("expect_row_inset blind to the drawn fill (M19)", SWIFT,
         r"guard let drawn = kayaRowFillDrawn\(fill, boxes\.cells\) else \{ return \"\" \}", 'return ""',
         "expect_row_inset's reader lacks"),
        ("expect_row_inset's pixel half passing a clipped fill (M19)", SWIFT,
         r"if kayaColourGap\(lead, between\) <= 0\.02 && kayaColourGap\(trail, between\) <= 0\.02 \{ return \"\" \}",
         'if kayaColourGap(lead, between) <= 200 && kayaColourGap(trail, between) <= 200 { return "" }',
         "expect_row_inset's pixel half lacks"),
        ("expect_row_inset passing a flush fill (M19)", SWIFT,
         r"if lead \+ 0\.5 >= boxes\.pad && trail \+ 0\.5 >= boxes\.pad \{", "if lead + 0.5 >= 0 && trail + 0.5 >= 0 {",
         "expect_row_inset's reader lacks"),
        ("expect_row_centered passing an off-centre cell (M19)", SWIFT,
         r"guard let worst, abs\(worst\.1\) > 2 else \{ return \"\" \}", 'guard let worst, abs(worst.1) > 200 else { return "" }',
         "expect_row_centered's reader lacks"),
        ("the phone dock's boxed picture uncapped (M18)", SWIFT,
         r"let box = kayaDockClamp\(CGSize\(width: node\.maxWidth, height: node\.maxHeight\), dockArt\)\n(\s+)Group",
         r"let box = CGSize(width: node.maxWidth, height: node.maxHeight)\n\1Group", "the phone dock's boxed picture lacks"),
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
        ("the first band reported over unmade cells", SWIFT,
         r"if reported == nil, firstBandWaits\(visible\) \{",
         "if false {", "not reported over a stamped row with no cell"),
        ("the first band's wait blind to unmade rows", SWIFT,
         r"if self\.row\(at: row\) != nil, KayaHost\.rowExtent\(node\.id, row\) == 0 \{ unmade\.append\(row\) \}",
         "", "counts every stamped row with no height"),
        ("a reused view kept by the node it drew before", SWIFT,
         r"    for \(other, views\) in kayaSkinAnchors where other != id && views\.contains\(where: \{ \$0\.view === view\.view \}\) \{\n        kayaSkinAnchors\[other\] = views\.filter \{ \$0\.view != nil && \$0\.view !== view\.view \}\n    \}\n",
         "", "a reused view leaves the node it drew before"),
        ("the native table's doubleAction unwired", SWIFT,
         r"\n\s+tableView\.doubleAction = #selector\(rowDoubleClicked\(_:\)\)", "",
         "the native table's wiring lacks tableView.doubleAction"),
        ("the double-click action reading no row", SWIFT, r"_ = activate\(row: sender\.clickedRow\)",
         "_ = sender", "the native table's double-click action lacks"),
        ("Return passed through", SWIFT, r"if \[36, 76\]\.contains\(event\.keyCode\), onReturn\?\(\) == true \{ return \}",
         "", "Return on the native table lacks if [36, 76]"),
        ("Return wired to nothing", SWIFT, r"return self\.activate\(row: self\.tableView\.selectedRow\)",
         "return false", "the native table's wiring lacks return self.activate"),
        ("the door blind to on_activate", SWIFT,
         r"guard stamped\.activatable else \{(\n[^\n]*declares no on_activate)", r"guard true else {\1",
         "the native table's activation door lacks guard stamped.activatable"),
        ("a pick told for a row with no handler", SWIFT,
         r"guard stamped\.activatable else \{(\n[^\n]*declares no on_select)", r"guard true else {\1",
         "the user's pick told lacks guard stamped.activatable"),
        ("the door publishing nothing", SWIFT, r"\n\s+KayaHost\.emitActivated\(stamped\.tag\)", "",
         "the native table's activation door lacks KayaHost.emitActivated"),
        ("the selection ignoring `selected`", SWIFT,
         r"if stamped\.selected \{ held\.insert\(stamped\.tag\) \} else \{ held\.remove\(stamped\.tag\) \}",
         "held.insert(stamped.tag)", "the native table's selection lacks if stamped.selected"),
        ("the app's selection re-applied over the user's pick every report", SWIFT,
         r"if was != stamped\.selected, was != nil \|\| stamped\.selected \{", "if true {",
         "the native table's selection lacks if was != stamped.selected"),
        ("a reload dropping the selection", SWIFT, r"tableView\.reloadData\(\)\n\s+applySelection\(\)\n",
         "tableView.reloadData()\n", "a reload keeps the native table's selection"),
        ("a user's pick never told", SWIFT, r"\n\s+KayaHost\.emitSelectionChanged\(stamped\.tag\)", "",
         "the user's pick told lacks KayaHost.emitSelectionChanged"),
        ("a pick told for a change nobody proposed", SWIFT, r"\n\s+userPick = pick\n", "\n",
         "a user's selection on the native table lacks userPick = pick"),
        ("a press telling the pick after the activation", SWIFT,
         r"if !node\.selected \{ emitSelectionChanged\(node\.tag\) \}\n(\s+)emitActivated\(node\.tag\)",
         r"emitActivated(node.tag)\n\1if !node.selected { emitSelectionChanged(node.tag) }",
         "a press tells the pick before the activation"),
        ("a press re-telling a selected row's pick", SWIFT, r"if !node\.selected \{ emitSelectionChanged",
         "if true { emitSelectionChanged", "the press door lacks if !node.selected"),
        ("a container's tap around the press door", SWIFT, r"\.onTapGesture \{ KayaHost\.emitPress\(node\) \}",
         ".onTapGesture { KayaHost.emitActivated(node.tag) }", "the activatable container lacks .onTapGesture"),
        ("a key at the native table sent elsewhere", SWIFT,
         r"return kayaSendNamedKey\(String\(parts\[1\]\), to: window\)", "return false",
         "a key at a native table holding the keyboard goes to it"),
        ("the harness's click a shortcut to the selection", SWIFT,
         r'tableView\.setValue\(\[axRows\[index\]\], forKey: "accessibilitySelectedRows"\)',
         "tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)",
         "the harness's click lacks tableView.setValue"),
        ("a report leaving the selection behind", SWIFT, r"(refresh\(\))\n\s+applySelection\(\)\n(\s+)layoutColumns\(\)",
         r"\1\n\2layoutColumns()", "every report puts the app's selection on the native table"),
        ("the harness's double-click a shortcut to the emit", SWIFT,
         r"sent = tableView\.sendAction\(action, to: tableView\.target\)",
         "sent = true; KayaHost.emitActivated(stamped.tag); activations += 1",
         "the harness's click names emitActivated"),
        ("a click on a native row taking the emit", SWIFT, r"refused = driver\.userClick\(node, clicks: 1\)",
         "refused = nil; KayaHost.emitPress(node)", "a click on a native table's row takes the table's own click"),
        ("a double-click on a native row taking the emit", SWIFT, r"refused = driver\.userClick\(node, clicks: 2\)",
         "refused = nil; KayaHost.emitPress(node)", "a double-click on a native table's row takes the table's own"),
        ("the native row's selected read off the cells", SWIFT,
         r"if let found, let index = found\.2 \{ return kayaAxTableRowSelected\(found\.0, index\) \}", "",
         "expect_selected on a native table's row reads the table's AXRows"),
        ("the native reader reading no AXRows", SWIFT, r"kayaAxCopy\(hit, kAXRowsAttribute as String\)",
         "kayaAxCopy(hit, kAXChildrenAttribute as String)", "expect_selected's native table reader lacks"),
        ("the synthesized row's ground unnamed to the tree", SWIFT,
         r"\n\s+\.accessibilityIdentifier\(row\.a11yId\)", "",
         "the synthesized table row's ground lacks .accessibilityIdentifier"),
        ("the synthesized row's selected surface kaya's own", SWIFT,
         r"AnyShapeStyle\(kayaSelectedPair\(\)\.fill\) : AnyShapeStyle\(Color\.clear\)",
         "AnyShapeStyle(Color.gray) : AnyShapeStyle(Color.clear)", "the synthesized table row's ground lacks"),
        ("the synthesized layout blind to its grounds", SWIFT, r"rowCount: node\.children\.count", "rowCount: 0",
         "the synthesized table's layout knows its grounds"),
        ("the synthesized cells keeping their press", SWIFT, r"\n\s+\.modifier\(KayaTableRowPress\(row: row\)\)", "",
         "KayaTableRowPress"),
        ("the Compose table's grounds gone", COMPOSE, r"rows\.forEach \{ row -> KayaTableRowGround\(row\) \}\n", "",
         "the Compose table stamps one ground per row"),
        ("the Compose cells counted from the grounds", COMPOSE, r"nFolded \+ cols \+ 1 \+ nRows, measurables", "nFolded + cols + 1, measurables",
         "the Compose table's cells are counted past the grounds"),
        ("a Compose ground with no press", COMPOSE, r"tag\.then\(kayaFilledSurface\(row\)\)", "tag",
         "a Compose table row's ground is the activatable surface"),
        ("WinUI's table rows read off the items", WINUI,
         r"let held = skin::inner_of\(&child\)\.unwrap_or_else\(\|\| child\.clone\(\)\);", "let held = child.clone();",
         "WinUI's table rows read through an activatable row's ItemContainer"),
        ("WinUI's scroll walk stopping at the template", WINUI,
         r"Err\(_\) => match VisualTreeHelper::GetParent\(&current\) \{", "Err(_) => match Err::<i32, ()>(()) {",
         "WinUI's scroll walk crosses an ItemContainer's template"),
        ("the clamp removed", SCENE,
         r"let \(light, dark\) = crate::brand::gradient_tops\(rgb\);",
         "let (light, dark) = (rgb, rgb);", "the core lowers every gradient's colour"),
        ("a band move's ops unlowered", SCENE, r"self\.assert_bands_hold\(\);\n(\s+)self\.lower_skin\(&mut out\);\n(\s+)out",
         r"self.assert_bands_hold();\n\2out", "a band move's ops pass the lowering"),
        ("the light clamp mixing with white, as shipped", BRAND, r"let mut top = lift_keeping_chroma\(rgb, target\);",
         "let mut top = set_lstar(rgb, target);", "the light clamp keeps the data colour's chroma (docs/media-player-plan.md M15)"),
        ("the dark clamp loosened", BRAND, r"GRADIENT_DARK_MAX_LSTAR: f64 = 48\.0;", "GRADIENT_DARK_MAX_LSTAR: f64 = 60.0;",
         "the dark clamp"),
        ("the readers sampling a clipped probe", HARNESS,
         r"let holds = vx <= x \+ tol && vy <= y \+ tol && ", "let holds = true || vx <= x + tol && vy <= y + tol && ",
         "the readers' refusal of a clipped probe"),
        ("GTK's shape read of a clipped row, as shipped", GTK,
         r"if let Some\(why\) = unseen_in_shot\(&widget, &shot\.content, \[fx, fy, fw, fh\]\) \{\n(\s+)return why;\n(\s+)\}\n(\s+)// Each probe",
         r"if let Some(why) = None::<String> {\n\1return why;\n\2}\n\3// Each probe", "GTK's ground, shape and tint readers refuse"),
        ("GTK's visible part blind to the window's edge", GTK, r"\n\s+\.and_then\(\|r\| r\.intersection\(&whole\)\)",
         "", "GTK's visible part is its ancestors' clip and the window's"),
        ("WinUI's ground, shape and tint reads of a clipped target", WINUI_SKIN,
         r"if let Some\(why\) = shot\.unseen\(&element, \[fx, fy, fw, fh\]\)\? \{",
         "if let Some(why) = None::<String> {", "WinUI's ground, shape and tint readers refuse", 4),
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
