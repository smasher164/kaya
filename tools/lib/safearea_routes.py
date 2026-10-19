"""docs/safe-area-plan.md A3-A5, A9, A10: the safe area's and the keyboard's
routes, held where no scene can see them go.

safearea.steps reads a bled widget's frame and the iOS keyboard scripts read
the keyboard and the focused field, so an arm that stopped bleeding or a field
left under the keyboard is red on its lane. But a reading that answered from
kaya's own pan agrees with every pan, a typing verb that lost the wall types
into a hidden field green, a bleed that took the keyboard's region along is
green on every leg with no keyboard up, a lane that stopped raising the keyboard
meets only the wall's refusal, and the bled canvas that grew itself every frame
read `bleeds` until the reading refused a frame past the window. A backend whose
`depth_stub("safearea")` goes must take a row in BACKENDS."""

import re

from content_type_routes import flat
from kaya_gate import ROOT
from reveal_routes import blocks

HARNESS = "crates/kaya/src/harness.rs"
SWIFT = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
RUNSIM = "tools/ios/run-sim.py"
IOS_LANE = "tools/lib/lanes/ios.py"
MEDIA = "android/kaya/src/main/kotlin/dev/kaya/KayaMedia.kt"
HELPER = "tools/android/cliphelper/app/src/main/kotlin/dev/kaya/cliphelper/Helper.kt"
EMULATOR = "tools/android/run-emulator.py"
STUBBED = {GTK: 'depth_stub("safearea")', WINUI: 'depth_stub("safearea")', COMPOSE: 'depthStub("safearea")'}
BACKENDS = {SWIFT: "the SwiftUI arm", GTK: "the GTK arm", WINUI: "the WinUI arm", COMPOSE: "the Compose arm"}
# THE BREADTH'S ARMS (docs/safe-area-plan.md §3, the breadth): (file, label,
# what must stand). A desktop has no safe area, so its bleed is the window
# inset's half alone; Compose consumes each bar's side per bar (A2), pans a
# covered field (A4), keeps the section bar under the keyboard (A6) and reads
# the platform's own insets (A9).
NATIVE = [
    (GTK, "GTK's bleed leaves the root's padding by its margins",
     '.kaya-root {{ padding: {px}px; }} .kaya-bleed-top {{ margin-top: -{px}px; }}'),
    (GTK, "GTK's touching sides refresh at every drain", "presentation_report(core);\n refresh_bleeds(core);"),
    (GTK, "GTK's touching sides refresh when the inset moves",
     "&root_inset_css(units.round() as i64),\n &core.css_error,\n );\n refresh_bleeds(core);"),
    (GTK, "GTK reads a container's axis off its flex manager first",
     ".and_then(|l| l.downcast_ref::<flex::FlexLayout>().map(|f| f.orientation() == gtk4::Orientation::Vertical))"),
    (GTK, "GTK's bled picture keeps no width of its own", "if self.cover.get() { 0 } else { self.size.get().0 }"),
    (GTK, "GTK's bled picture re-takes its slot's width", "if picture.is_some() {\n widget.set_halign(gtk4::Align::Fill);"),
    (GTK, "GTK's expect_safe reads the content's border box",
     "let area = content\n .compute_bounds(&content)"),
    (GTK, "GTK has no software keyboard", "fn keyboard(&self) -> Result<bool, String> {\n Ok(false)"),
    # A19's crop is about the centre; no scene reads which part of a bled
    # picture shows (docs/traps.md, an element's own maxima crop an overflowing fill).
    (GTK, "GTK's bled picture crops about its centre",
     "snap.translate(&gtk4::graphene::Point::new(((width - dw) / 2.0) as f32, ((height - dh) / 2.0) as f32));"),
    (SWIFT, "SwiftUI's bled picture crops about its centre",
     "Color.clear\n .overlay {\n #if os(macOS)\n Image(nsImage: image).resizable().scaledToFill()\n #else\n"
     " Image(uiImage: image).resizable().scaledToFill()\n #endif\n }\n .clipped()"),
    (WINUI, "WinUI's bled picture crops about its centre",
     "image.SetHorizontalAlignment(bindings::Microsoft::UI::Xaml::HorizontalAlignment::Center)?;\n"
     " image.SetVerticalAlignment(bindings::Microsoft::UI::Xaml::VerticalAlignment::Center)?;"),
    (WINUI, "WinUI's bled picture's slot is its column's row, never its own MaxHeight",
     "image.SetMaxHeight(f64::INFINITY)?;\n row.SetHeight(GridLength { Value: fit, GridUnitType: GridUnitType::Pixel })?;"),
    (WINUI, "WinUI's bled picture reads its slot's cut as its frame",
     "if bled && b > t {\n (frame[1], frame[3]) = (shown[1], b - t);"),
    # A9: the readings hold what the user sees, the frame cut by every
    # ancestor's clip (docs/traps.md, the landscape composer that read safe
    # while hidden; the desktops' half of it).
    (WINUI, "WinUI's expect_safe starts from what its own slot leaves",
     "let shown = [frame[0] + l, frame[1] + t, frame[0] + r, frame[1] + b];"),
    (WINUI, "WinUI's expect_safe walks every ancestor to the root",
     "let mut up = VisualTreeHelper::GetParent(&element).ok();\n while let Some(node) = up {"),
    (WINUI, "WinUI's expect_safe cuts by each scroll viewer's viewport and each ancestor's slot",
     "let [l, t, r, b] = if node.cast::<ScrollViewer>().is_ok() {\n"
     " [0.0, 0.0, ancestor.ActualWidth()?, ancestor.ActualHeight()?]\n } else {\n slot_cut(&ancestor, rtl)?\n };"),
    (WINUI, "WinUI's expect_safe hands the verdict what shows", "frame,\n visible,\n (root.ActualWidth()?, root.ActualHeight()?),"),
    (GTK, "GTK's expect_safe reads what its ancestors clip", "let shown = clipped_by_ancestors(&widget, &content, frame);"),
    (GTK, "GTK's clip is every ancestor that clips its children",
     "if ancestor.overflow() == gtk4::Overflow::Hidden || ancestor.is::<gtk4::ScrolledWindow>() {"),
    (GTK, "GTK's unmapped widget shows nothing", "if !widget.is_mapped() {\n return None;\n }\n let mut shown = frame;"),
    (HARNESS, "the desktops' verdict refuses a frame with nothing on screen",
     "if vw <= 0.0 || vh <= 0.0 {\n return Err(format!(\"{spec} has nothing on screen, its parents clip all of it: {facts}\"));"),
    (HARNESS, "the desktops' verdict refuses a frame clipped on any side",
     "if vx > x + tol || vy > y + tol || vx + vw < x + w - tol || vy + vh < y + h - tol {"),
    (WINUI, "WinUI's touching sides refresh at every batch", "flush_container_tracks(core)?;\n refresh_bleeds(core)"),
    (WINUI, "WinUI's bleed leaves the root's padding by its margins",
     "element.SetMargin(Thickness { Left: out(leading), Top: out(top), Right: out(trailing), Bottom: out(bottom) })?;"),
    (WINUI, "WinUI's bled canvas is drawn past its slot",
     "f64::from(slot.Width) - m.Left - m.Right, f64::from(slot.Height) - m.Top - m.Bottom"),
    (WINUI, "WinUI's expect_inset reads the first child's slot",
     "let slot = LayoutInformation::GetLayoutSlot(&child)?;"),
    (WINUI, "WinUI has no software keyboard on the lanes", "fn keyboard(&self) -> Result<bool, String> {\n Ok(false)"),
    (COMPOSE, "Compose's top bar consumes its own side",
     "windowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Top),"),
    (COMPOSE, "Compose's section bar consumes its own side, never the keyboard's",
     "NavigationBar(\n windowInsets = WindowInsets.systemBars.union(WindowInsets.displayCutout)\n .only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom),"),
    (COMPOSE, "Compose's section bar stays under the keyboard",
     "val room = if (imeShown) h else (h - bar.height).coerceAtLeast(0)"),
    (COMPOSE, "Compose's content is measured against the section bar in the same pass",
     "val bar = measurables[1].measure(constraints.copy(minWidth = 0, minHeight = 0))\n"
     " val room = if (imeShown) h else (h - bar.height).coerceAtLeast(0)\n"
     " val body = measurables[0].measure(Constraints.fixed(w, room))"),
    (COMPOSE, "Compose's pane takes the keyboard's side while the bar is under it",
     "KayaContentBox(topConsumed, bottomConsumed = !imeShown, rides = kayaRidesNow(shown), root = shown)"),
    (COMPOSE, "Compose's single surface rides by the same rule",
     "KayaContentBox(topConsumed, bottomConsumed = docked, rides = kayaRidesNow(shown),\n"
     " root = shown.takeIf { KayaSceneModel.panes < 2 })"),
    (COMPOSE, "Compose's content takes what the bars left",
     ".windowInsetsPadding(pads.content)\n .onGloballyPositioned {\n kayaContentTop = it.positionInWindow().y\n"
     " kayaPanSoon()\n }\n .then(if (pan > 0f || natural) Modifier.clipToBounds() else Modifier)"),
    # A squeezed Column gives what is left to its children in order, so the
    # landscape chat composer and the autofill form's last fields came out 0
    # high and read safe (docs/traps.md, the landscape composer): once a
    # focused field is shorter than its caret line the root stops riding,
    # keeps its natural height and pans, until the keyboard goes.
    (COMPOSE, "Compose's root stops riding once a focused field is squeezed",
     "root != null && kayaRides(root) && !KayaSceneModel.keyboardOverflow"),
    # A5: a grown text area gives up its room like a grown scroll, so what
    # follows it stays above the keyboard (editor.steps' status line; iOS
    # has it from SwiftUI's keyboard region).
    # SwiftUI lays a copy of the root out in the window's opening frame and
    # drops it; its records outlived it and expect_safe read a label 30 pt
    # past the window (docs/traps.md, the dropped copy's frames).
    (SWIFT, "SwiftUI's track reader retires a dropped copy's record",
     ".task(id: tableGeneration) { record(geo.size, geo.frame(in: .global)) }\n"
     " .onDisappear { kayaTrackRecords.retire(id, token) }"),
    (SWIFT, "SwiftUI's cell reader retires a dropped copy's record",
     ".onChange(of: global.origin) { _, _ in record(frame, geo.frame(in: .global)) }\n"
     " .onDisappear { kayaCellRecords.retire(id, token) }"),
    (SWIFT, "SwiftUI's retired record hands the node back to its newest survivor",
     "if newest, let survivor = list.last { survivor.apply() }"),
    (COMPOSE, "Compose's grown text area rides the keyboard",
     "if (node.kind == KayaCompose.KIND_SCROLL || node.kind == KayaCompose.KIND_TEXTAREA) return node.grow > 0"),
    (COMPOSE, "Compose's squeeze is detected on the focused field",
     "if (!inSheet && !KayaSceneModel.keyboardOverflow && kayaSqueezed(field, frame)) {\n"
     " KayaSceneModel.keyboardOverflow = true"),
    (COMPOSE, "Compose's overflow ends with the keyboard",
     "if (insets != null && !imeShown && KayaSceneModel.keyboardOverflow) KayaSceneModel.keyboardOverflow = false"),
    (COMPOSE, "Compose's overflowing root keeps its natural height",
     ".then(if (natural) Modifier.layout { measurable, constraints ->\n val placeable = measurable.measure(\n"
     " constraints.copy(minHeight = constraints.maxHeight, maxHeight = Constraints.Infinity))"),
    # A20: a focused textarea shrinks to the room above the keyboard, down to
    # one line; no scene can tell a cap without its floor from one with it
    # while the room is a line or more.
    (COMPOSE, "Compose's focused textarea is capped at the room above the keyboard, a line at least",
     "return maxOf(kayaOneLineHeight(field, frame), keyboardTop - kayaKeyboardRoomTop(field, insets) - gap)"),
    (COMPOSE, "Compose's pan caps by A20's room", "val want = kayaFieldRoom(field, frame, decor, insets)"),
    # The verb owes A20's room read from the window, so a cap the pan left
    # behind is red (docs/traps.md, the grown textarea's one-line floor).
    (COMPOSE, "Compose's expect_fills owes a focused textarea A20's room",
     "val room = kayaOwedRoom(activity, widget)\n if (room != null && room < track - 2.0) {\n"
     " if (kotlin.math.abs(drawn - room) <= 2.0) \"\""),
    (COMPOSE, "Compose's owed room is read from the window", "return kayaFieldRoom(widget, frame, decor, insets)?.toDouble()"),
    (COMPOSE, "Compose's cap is written", "KayaSceneModel.keyboardFieldCap = field.id to want"),
    (COMPOSE, "Compose's cap ends with the keyboard or the focus",
     "if (capped != null && (!imeShown || capped.first != field?.id)) KayaSceneModel.keyboardFieldCap = null"),
    # A grown textarea's viewport is its own lines, not its frame less its
    # chrome (docs/traps.md, the grown textarea's one-line floor).
    (COMPOSE, "Compose's one line is the decoration's padding around its first line",
     "return 2f * (top - frame.top) + (layout.getLineBottom(0) - layout.getLineTop(0))"),
    (COMPOSE, "Compose's viewport top is read unclipped", "kayaTextTops[node.id] = it.positionInWindow().y"),
    (SWIFT, "SwiftUI's expect_fills owes a focused textarea A20's room",
     "if let room = kayaOwedRoom(widget.id), room < track - 2 {\n if abs(drawn - room) <= 2 { return \"\" }"),
    (COMPOSE, "Compose's capped textarea's floor is one line",
     "else if (cap != null) TextFieldLineLimits.MultiLine(\n minHeightInLines = 1,"),
    (COMPOSE, "Compose's cap bounds the field before its fill",
     ".then(if (cap != null) Modifier.sizeIn(maxHeight = with(LocalDensity.current) { cap.toDp() }) else Modifier)\n"
     " .then(fill)"),
    (COMPOSE, "Compose's pan measures its room under the top bar",
     "else maxOf(safeTop.toFloat(), kayaContentTop)"),
    (COMPOSE, "Compose's sheet pans within its own content",
     "return if (inSheet) maxOf(safeTop.toFloat(), kayaSheetTops[kayaRootIdOf(field.id)] ?: 0f)"),
    # The pan's dead zone kept a field set against a lower content top 8 px
    # above its room once the sheet settled (docs/traps.md, the quick-add
    # field panned above its sheet's top).
    (COMPOSE, "Compose's pan brings a field that fits back below its room's top",
     "val above = frame.height <= room && frame.top < roomTop - 0.5f\n"
     " if (covered > 0.5f) {\n next = current + covered + margin\n"
     " } else if (current > 0f && (covered < -2 * margin || above)) {"),
    # docs/traps.md, the quick-add field panned above its sheet's top.
    (COMPOSE, "Compose's pan aims a field that fits with its top inside its room",
     "val need = if (frame.height <= room) frame.height else caret.height\n"
     " val target = if (frame.height <= room) frame.bottom else caret.bottom\n"
     " val margin = minOf(gap, maxOf(0f, room - need))"),
    (COMPOSE, "Compose's expect_safe failure names the pan's inputs",
     'got == null -> failures.add(why + (onUi(activity) { kayaPanReading(activity) } ?: ""))'),
    (COMPOSE, "Compose's sheet keeps its layout while typing", "val keeps = detented || typing"),
    (COMPOSE, "Compose's cramped sheet drops its handle and its top inset",
     "dragHandle = if (cramped) null else"),
    (COMPOSE, "Compose's cramped sheet is measured against the keyboard's top",
     "kayaKeyboardTop(hostView) - top < field.height"),
    # The readings hold what the user sees: the frame clipped by every
    # ancestor, and a field's caret line unclamped (docs/traps.md, the
    # landscape composer that read safe while hidden).
    (COMPOSE, "Compose's frames record what their ancestors leave on screen",
     "kayaNodeVisible[id] = it.boundsInWindow()"),
    (COMPOSE, "Compose's expect_safe refuses a frame its parents clip",
     'kayaClipped(node, frame, visible, tol)?.let { return Pair(null, "$spec $it: $facts") }'),
    (COMPOSE, "Compose's clip test reads all four sides",
     "visible.left > frame.left + tol || visible.top > frame.top + tol ||\n"
     " visible.right < frame.right - tol || visible.bottom < frame.bottom - tol"),
    (COMPOSE, "Compose's expect_safe holds a field's caret line to what shows",
     "val caret = kayaCaretLine(node, frame)\n if (caret.top < visible.top - tol || caret.bottom > visible.bottom + tol) {"),
    (COMPOSE, "Compose's wall holds the caret line to what shows",
     "val caret = kayaCaretLine(field, frame)\n val visible = kayaNodeVisible[field.id] ?: androidx.compose.ui.geometry.Rect.Zero\n"
     " val shown = caret.top >= visible.top - 0.5f && caret.bottom <= visible.bottom + 0.5f\n"
     " if (shown && caret.bottom <= keyboardTop + 0.5f && caret.top >= safeTop - 0.5f) return null"),
    (COMPOSE, "Compose's bled picture spans its slot",
     "modifier = boxFill.then(if (node.bleed) kayaBleed(node, fit) else bound)"),
    (COMPOSE, "Compose's bled canvas", "modifier = boxFill.then(kayaBleed(node)).then(kayaFrame(node.id))"),
    (MEDIA, "Compose's bled video view", "modifier = sized.then(kayaBleed(node)).clipToBounds()"),
    (COMPOSE, "Compose's bleed never counts the keyboard", "val bleedBottom = if (keyboard) null else bottom"),
    (COMPOSE, "Compose's bleed reads the safe area at layout",
     "return Modifier.layout { measurable, constraints ->\n val ltr = layoutDirection == LayoutDirection.Ltr\n"
     " val left = pads?.getLeft(this, layoutDirection) ?: 0\n val right = pads?.getRight(this, layoutDirection) ?: 0"),
    (COMPOSE, "Compose's pan is written", "KayaSceneModel.keyboardPan = next"),
    (COMPOSE, "Compose's root gives up its height to the keyboard only where it rides",
     "keyboard && !rides -> bars.only(WindowInsetsSides.Bottom)"),
    (COMPOSE, "Compose's detented sheet pans", "val pan = kayaPanFor(root.id)"),
    (COMPOSE, "Compose's keys reach a sheet's window",
     "if (host != null && host !== activity.window.decorView) host.dispatchKeyEvent(key)"),
    (COMPOSE, "Compose's expect_keyboard reads the root's insets",
     "?.isVisible(WindowInsetsCompat.Type.ime()) == true"),
    (COMPOSE, "Compose's expect_safe reads the platform frame", "val frame = kayaNodeFrames[node.id]"),
    (COMPOSE, "Compose's wall holds type", 'if (why == null) kayaKeyboardWall(activity, "type")?.let { failures.add(it) }'),
    (COMPOSE, "Compose's wall holds type_secret",
     'if (why == null) kayaKeyboardWall(activity, "type_secret")?.let { failures.add(it) }'),
    (COMPOSE, "Compose's wall holds press",
     'if (why == null) kayaKeyboardWall(activity, "press ${parts[1]}")?.let { failures.add(it) }'),
    (COMPOSE, "Compose's landscape leg pins its app",
     "activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE"),
    (COMPOSE, "a turning first instance admits no harness", "if (selftestPending && !turning) {"),
    (HELPER, "the pool's keyboard shows when a field asks", "override fun onEvaluateInputViewShown(): Boolean = true"),
    (EMULATOR, "the cutout overlay goes off when its leg ends, whatever the verdict",
     "finally:\n if cutout and not cutout_overlay(serial, cutout, False, log):\n ok = False"),
    (EMULATOR, "the cutout overlay is read back", 'if f"{mark} {pkg}" in listed:'),
    (EMULATOR, "a dead lane's teardown turns the cutout off", "for serial, name in list(CUTOUT_ON):"),
    # docs/traps.md, the status bar one overlay behind: SystemUI keeps the bar
    # of the cutout before the latest change, and only the leg AFTER the
    # cutout leg on that device, on a screen with no slack, can see it.
    (EMULATOR, "the cutout's change waits for SystemUI's bar",
     "return settle_status_bar(serial, log, f\"cutout {name} {'on' if on else 'off'}\", on)"),
    (EMULATOR, "the display is upright before the cutout goes",
     "if not on and not upright_for_cutout(serial, log):\n return False"),
    (EMULATOR, "the lane start reads each phone's own bar",
     "if serial != TABLET_SERIAL and not upright_bar_at_lane_start(serial, sys.stdout):\n BAR_REFUSED.append(serial)"),
    (EMULATOR, "a phone's bar unread refuses the lane's verdict",
     'a bar of unknown height (docs/traps.md, the status bar one overlay behind)")\n status = 1'),
    (EMULATOR, "the nudge awaits its scale in the configuration",
     "if global_font_scale(serial) == float(other):\n break"),
    (EMULATOR, "the bar settles laid out and upright alike, under the cutout asked for",
     "def wanted(now, upright, rotation, cut):\n return rotation == 0 and (cut > 0) == on and now == upright == max(own, cut)\n"
     " reading, nudged = settle_until(serial, log, wanted)"),
    (EMULATOR, "the android lane reads the display's rotation after a landscape leg",
     "if pinned or serial in LANDSCAPE_RAN:\n if not leg_rotation(serial, log, pinned):"),
    # A2: a ground runs under the bars it touches and the bars' icons read on
    # what is drawn behind them. The phone tails read the album header's reach
    # and the icons with the header up and after it is popped, but in both
    # appearances the clamped header and the page agree on the icons, so a
    # claim that outlived its screen is green on every leg.
    (COMPOSE, "Compose's gradient ground runs through the safe area it touches",
     "val reach = kayaGroundReach(node) { Pair(stops[0].toArgb(), stops[1].toArgb()) }"),
    # docs/media-player-plan.md M15: an image ground does as a gradient does, and
    # claims the bars with what its picture shows under them; the grounds phone
    # tails read the reach and the icons.
    (COMPOSE, "Compose's image ground runs through the safe area it touches",
     "val reach = kayaGroundReach(node) { ext ->\n if (picture == null || box == IntSize.Zero) Pair(null, null)\n"
     " else Pair(kayaPictureStrip(picture, box, boxX, windowW, page, ext, status = true),"),
    (COMPOSE, "Compose's reaching picture is drawn over the grown area", "kayaGroundGrowth[node.id] = grow"),
    (COMPOSE, "Compose's picture readers place the picture where it is drawn",
     "val grow = kayaGroundGrowth[id] ?: FloatArray(4)"),
    (SWIFT, "SwiftUI's image ground reaches the bars only where the window gives no inset",
     "guard (kayaScene.windows[0]?.inset ?? 16) == 0 else { return [] }\n return kayaBleedEdges(node)"),
    (SWIFT, "SwiftUI's image ground ignores the safe area on the sides it touches",
     ".onChange(of: node.image) { _, _ in kayaGroundDrawn(node, inner: geo.frame(in: .global)) }\n }\n )\n"
     " .ignoresSafeArea(.container, edges: reach)"),
    (SWIFT, "SwiftUI's status bar answers an image ground's claim",
     "class_replaceMethod(cls, sel, imp_implementationWithBlock(answer), method_getTypeEncoding(method))"),
    (SWIFT, "SwiftUI's root keeps the status bar question while a claim stands",
     "kayaStatusOverride == 0 ? original(me, child) : nil"),
    (SWIFT, "SwiftUI's image ground's claim ends when it goes", ".onDisappear { kayaGroundUnder(node.id, nil) }"),
    # A bar split between a picture and the page (the grounds hero on Android,
    # whose column hugs its content) reads at both ends: the claim and the
    # readers each take both, and the page where the picture is not drawn.
    (COMPOSE, "Compose's claim reads the page where the picture is not drawn",
     "val c = if (x < 0f || x >= w) ground else {"),
    (COMPOSE, "Compose's expect_system_bars reads both ends of a bar",
     "val far = shot.at(shot.bitmap.width - 4 * shot.density, y)"),
    (SWIFT, "SwiftUI's claim reads the page where the picture is not drawn",
     "let share = over.isNull ? 0 : Double(over.width / third.width)"),
    (SWIFT, "SwiftUI's expect_system_bars reads both ends of a bar",
     "let far = shot.at(CGPoint(x: window.bounds.width - 4, y: y))"),
    (SWIFT, "SwiftUI's picture readers place the picture where it is drawn",
     "let (gl, gt, gr, gb) = kayaGroundGrowth(node.id)"),
    (COMPOSE, "Compose's reaching gradient is drawn past its box",
     "Brush.verticalGradient(stops, startY = -up, endY = size.height + down),\n topLeft = Offset(-left, -up),"),
    (COMPOSE, "Compose's ground reaches the bars only where the window gives no inset",
     "val edges = if (pads == null || KayaSceneModel.windowInset != 0.0) null\n else kayaBleedEdges(node)"),
    (COMPOSE, "Compose's ground's claim on the bars ends with its composition",
     "onDispose { kayaBarGrounds.remove(node.id) }"),
    (COMPOSE, "Compose's bar icons follow what is drawn behind them",
     "controller.isAppearanceLightStatusBars = kayaDarkIconsOn(status)\n"
     " controller.isAppearanceLightNavigationBars = kayaDarkIconsOn(nav)"),
    (COMPOSE, "Compose's bar icons are set from the root",
     "KayaToastHost(Modifier.align(Alignment.BottomCenter))\n KayaSystemBarIcons()"),
    (COMPOSE, "Compose's expect_system_bars reads the controller against the strip's pixel",
     "val strip = shot.at(4 * shot.density, y)"),
    (SWIFT, "SwiftUI's expect_system_bars reads the scene's status bar style", "let style = manager.statusBarStyle"),
    (HARNESS, "harness.rs reads the system bars", "Step::ExpectSystemBars(want) => Some(poll(|| match stage.system_bars() {"),
    (HARNESS, "harness.rs reads a ground's reach", "word_reading(&stage.ground_reach(*t), want,"),
]
# What a backend's read may never name: its own model of the answer.
NEVER = [
    (COMPOSE, "fun kayaSafeReading(", ["keyboardPan", "windowInset"]),
    (COMPOSE, "fun kayaWallReading(", ["keyboardPan", "kayaCaretRect("]),
    (COMPOSE, "internal fun kayaClipped(", ["kayaCaretRect(", "kayaNodeFrames"]),
    (COMPOSE, "fun KayaRoot()", ["safeDrawingPadding"]),
    # The content's safe area is read at layout, never in composition: a
    # composition read reaches the layout a frame after the window's insets,
    # and an app's opening scroll landed short by them (docs/traps.md, the
    # content box that padded a frame late).
    (COMPOSE, "private fun kayaContentPads(", ["getTop(", "getBottom(", "getLeft(", "getRight(", "asPaddingValues"]),
    (COMPOSE, "private fun KayaContentBox(", ["asPaddingValues", "PaddingValues(", ".padding(pads"]),
    (COMPOSE, "fun KayaSectionsScaffold(", ["padding(bottom", "sectionBarHeight.roundToPx", "sectionBarHeight.toPx"]),
    (SWIFT, "@MainActor func kayaVisibleFrame(", ["keyboardPan", "kayaNodeFrames"]),
    (SWIFT, "@MainActor func kayaUIKitClips(", ["keyboardPan", "kayaNodeFrames"]),
]
PREF = ('"com.apple.keyboard.preferences"', '"AutomaticMinimizationEnabled"')
# (label, opener, which definition, what it must hold, what it may never name)
BLOCKS = [
    ("the bleed", "struct KayaBleed<Content: View>: View {", 0,
     ["let edges = kayaBleedEdges(node)", "KayaBleedLayout(edges: edges, inset: inset, slotHeight: slotHeight)",
      "kayaBleedFrames[node.id] = f }\n }\n )\n .ignoresSafeArea(.container, edges: edges)"],
     [".keyboard", ".all"]),
    ("the bleed's slot", "struct KayaBleedLayout: Layout {", 0,
     ["let grown = ProposedViewSize(width: proposal.width.map { $0 + dx }, height: proposal.height.map { $0 + dy })",
      "return CGSize(width: max(0, answer.width - dx), height: max(0, answer.height - dy))"],
     ["sizeThatFits(proposal)"]),
    ("the touching sides", "@MainActor func kayaBleedEdges(_ node: KayaNode) -> Edge.Set {", 0,
     ["kayaScene.parents[child]", "kayaFilledInset(parent) == 0",
      "if !first { edges.remove(vertical ? .top : .leading) }",
      "if !last { edges.remove(vertical ? .bottom : .trailing) }", "return kayaIsMountedRoot(child) ? edges : []"],
     []),
    ("expect_safe's reading", "@MainActor func kayaSafeReading(", 0,
     ["kayaSafeWindowRects()", "kayaPlatformFrame(node)", "kayaKeyboardInWindow()",
      "frame.maxY > keyboard.minY + tol", "runs past the window's edge", "stops short of the window's edge",
      "lies outside the safe area", "let (visible, cuts) = kayaVisibleFrame(node, frame)",
      "if visible.width <= 0 || visible.height <= 0 {",
      "visible.minX > frame.minX + tol || visible.minY > frame.minY + tol || visible.maxX < frame.maxX - tol\n"
      " || visible.maxY < frame.maxY - tol",
      "caret.view === kayaPlatformTextView(node),\n"
      " caret.caret.minY < visible.minY - tol || caret.caret.maxY > visible.maxY + tol"],
     ["keyboardPan", "node.inset"]),
    ("the visible frame", "@MainActor func kayaVisibleFrame(", 0,
     ["let read = kayaUIKitClips(view, in: window)", "ancestor.kind == kindScroll",
      "let next = shown.intersection(ancestor.scrollViewportGlobal)",
      "if let root = kayaRootFrames[current] {\n let next = shown.intersection(root)",
      "cuts.append(\"scroll \\(ancestor.id)'s viewport", "cuts.append(\"root \\(current)'s frame"], []),
    ("a UIKit view's visible frame", "@MainActor func kayaUIKitClips(", 0,
     ["if v.clipsToBounds || v.layer.masksToBounds {", "if let mask = v.layer.mask {",
      "if v.next is UIViewController {", "v.bounds.inset(by: v.safeAreaInsets)"], []),
    ("the frame a reading reads", "@MainActor func kayaPlatformFrame(", 0,
     ["kayaBleedFrames[node.id]", "kayaPlatformTextView(node)", "kayaNodeFrames[node.id]"],
     ["keyboardPan"]),
    ("a text control's UIKit view", "@MainActor func kayaPlatformTextView(", 0,
     ["kayaUITextViews[node.id]?.view", "kayaFirstResponderView()"], ["keyboardPan"]),
    ("the iOS insets", "@MainActor func kayaInsetWords()", 0,
     ["window.safeAreaInsets", "statusBarManager?.isStatusBarHidden", '"cutout"'], ["fullscreen"]),
    ("the keyboard's frame", "@MainActor func kayaWatchKeyboard() {", 0,
     ["UIResponder.keyboardWillChangeFrameNotification", "UIResponder.keyboardFrameEndUserInfoKey",
      "UIResponder.keyboardWillHideNotification", "kayaKeyboardScreenFrame = end", "kayaKeyboardMoved()",
      "kayaPanAfterCommit()"], []),
    ("the keyboard over the window", "@MainActor func kayaKeyboardInWindow() -> CGRect? {\n        guard", 0,
     ["window.convert(kayaKeyboardScreenFrame, from: window.screen.coordinateSpace)", "r.intersection(window.bounds)"],
     ["keyboardPan"]),
    ("the pan", "@MainActor func kayaPanEvaluate() {", 0,
     ["kayaRevealInScroll(rects.view, above: keyboard, in: rects.window)",
      "kayaKeyboardInWindow()", "kayaFocusedFieldRects()", "kayaRootOf", "covered > 0.5",
      "kayaScene.keyboardPan = [root: next]",
      # A20: the focused textarea's cap, a line at least, under the root's top.
      "if !kayaScene.keyboardFieldCap.isEmpty { kayaScene.keyboardFieldCap = [:] }",
      "if let node = focused, let want = kayaFieldRoom(keyboard: keyboard, rects: rects) {",
      "kayaScene.keyboardFieldCap = [node.id: want]",
      # docs/traps.md, the quick-add field panned above its sheet's top.
      "let roomTop = kayaPanRoomTop(root, rects.window)",
      "let above = rects.field.height <= room && rects.field.minY < roomTop - 0.5",
      "} else if current > 0, above {\n next = max(0, current + min(covered + margin, rects.field.minY - roomTop))",
      "if let aimed = kayaPanAimed, abs(aimed.pan - current) < 0.5, abs(aimed.fieldTop - rects.field.minY) < 0.5 {\n"
      " kayaPanQueued = true\n return",
      "kayaPanAimed = (next, rects.field.minY)"],
     ["asyncAfter"]),
    ("the pan's room", "@MainActor func kayaPanRoomTop(", 0,
     ["max(window.safeAreaInsets.top, kayaRootFrames[root]?.minY ?? 0)"], []),
    ("the pan's queue", "@MainActor func kayaKeyboardMoved() {", 0,
     ["kayaPanQueued = true", "CFRunLoopWakeUp(CFRunLoopGetMain())"], ["asyncAfter", "DispatchQueue"]),
    # An evaluation read the field where the last pan had not moved it yet and
    # the pan ran away to 874 pt; reads after the commit still lag up to nine
    # turns, so a pan the field has not answered is not re-read (docs/traps.md,
    # the quick-add field panned above its sheet's top).
    ("the pan after the commit", "@MainActor func kayaPanAfterCommit() {", 0,
     ["CFRunLoopActivity.beforeWaiting.rawValue, true, 2_001_100", "guard kayaPanQueued else { return }",
      "kayaPanEvaluate()", "CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)"], ["DispatchQueue"]),
    ("A20's room", "@MainActor func kayaFieldRoom(", 0,
     ["node.kind == kindTextarea",
      "let top = max(rects.window.safeAreaInsets.top, kayaRootFrames[root]?.minY ?? 0)",
      "let floor = line + text.textContainerInset.top + text.textContainerInset.bottom",
      "return max(floor, keyboard.minY - top - margin)"], []),
    ("the owed room", "@MainActor func kayaOwedRoom(_ id: UInt64) -> CGFloat? {\n        guard", 0,
     ["kayaScene.focusedId == id", "kayaKeyboardInWindow()", "kayaFocusedFieldRects()",
      "return kayaFieldRoom(keyboard: keyboard, rects: rects)"], ["keyboardFieldCap"]),
    ("the wall's reading", "@MainActor func kayaWallReading(", 0,
     ["kayaFocusedFieldRects()", "kayaKeyboardInWindow()", "rects.caret.maxY <= keyboard.minY + 0.5",
      "let (visible, cuts) = kayaUIKitClips(rects.view, in: rects.window)",
      "rects.caret.minY >= visible.minY - 0.5 && rects.caret.maxY <= visible.maxY + 0.5",
      "if shown, rects.caret.maxY <= keyboard.minY + 0.5",
      "if kayaKeyboardFrames == 0 {", 'UserDefaults(suiteName: ' + PREF[0] + ')',
      ".object(forKey: " + PREF[1] + ") as? Bool", "if pref == false {",
      '"(docs/safe-area-plan.md A4, A9)" + kayaFieldScrollReading(rects)'],
     ["keyboardPan"]),
    # SwiftUI's own scroll to a focused field stops once part of it shows
    # (docs/traps.md, the clipped notes field).
    ("the scroll's reveal", "@MainActor func kayaRevealInScroll(", 0,
     ["while let v = at, !(v is UIScrollView) { at = v.superview }",
      "let roomBottom = min(port.maxY - scroll.adjustedContentInset.bottom, keyboard.minY)",
      "guard field.height <= roomBottom - roomTop, field.minY < roomTop - 0.5 || field.maxY > roomBottom + 0.5",
      "scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)"], ["keyboardPan"]),
    ("the caret line", "@MainActor func kayaFocusedFieldRects()", 0,
     ["input.caretRect(for: at)", "view is UITextField || view is UITextView"], []),
    # docs/traps.md, the iOS caret below its text view's estimated content.
    ("the caret kept in its text view", "@MainActor func kayaKeepCaretShown(", 0,
     ["guard view.isFirstResponder", "NSMaxRange(view.selectedRange)",
      "layout.ensureLayout(for: laid)\n view.layoutIfNeeded()\n"
      " UIView.performWithoutAnimation { view.scrollRangeToVisible(view.selectedRange) }"],
     ["asyncAfter", "DispatchQueue"]),
    ("the wall's own-space reading", "@MainActor func kayaFieldScrollReading(", 0,
     ["scroll.contentSize.height", "rects.view.convert(rects.caret, from: rects.window)",
      "scroll.adjustedContentInset", "kayaScene.keyboardFieldCap[$0]", "kayaScene.keyboardPan[root]"], []),
]
CALLS = [
    (SWIFT, "the app's bleed reaches the arm",
     "case (propBleed, valueBool):\n kayaScene.nodes[id]!.bleed = raw[body + 24] != 0"),
    (SWIFT, "a bled picture is drawn through the bleed",
     "if node.bleed, let natural = node.image?.size ?? node.imagePendingNatural {\n let fit = kayaImageFit(natural: natural, node: node) ?? natural\n let image = node.image ?? kayaBlankPicture\n KayaBleed(node: node, slotHeight: fit.height)"),
    (SWIFT, "a bled canvas is drawn through the bleed",
     ".background(kayaHarnessDrivesFrames ? nil : KayaCanvasTicker())\n .modifier(KayaBleedIfAsked(node: node))"),
    # docs/traps.md, the grown canvas that could not shrink: with no minimum
    # the frame keeps its last blit's size in a smaller offer.
    (SWIFT, "a grown canvas takes its offer below its last blit",
     ".frame(\n minWidth: node.grow > 0 ? 0 : nil,\n maxWidth: node.grow > 0 ? .infinity : nil,\n"
     " minHeight: node.grow > 0 ? 0 : nil,\n maxHeight: node.grow > 0 ? .infinity : nil)\n .clipped()\n"
     " .background(KayaCanvasReader(id: node.id))"),
    (SWIFT, "a bled video view is drawn through the bleed",
     ".accessibilityAction(named: actions[1].0, actions[1].1)\n .modifier(KayaBleedIfAsked(node: node))"),
    (SWIFT, "a bled self-view is drawn through the bleed",
     ".accessibilityAddTraits(.isImage)\n .modifier(KayaBleedIfAsked(node: node))\n } else {"),
    (SWIFT, "the bleed when asked", "if node.bleed {\n KayaBleed(node: node) { content }"),
    (SWIFT, "the iOS textarea is framed by its cap",
     "maxLines: node.maxLines, cap: kayaScene.keyboardFieldCap[node.id])"),
    (SWIFT, "a capped textarea's floor gives way to its cap",
     "minHeight: grows_lines ? nil : min(96, cap ?? 96),\n maxHeight: cap ?? (grows_lines ? nil : (fillsHeight ? .infinity : 96))"),
    (SWIFT, "a capped growing textarea answers its cap",
     "return CGSize(width: width, height: min(text + insets, cap ?? .infinity))"),
    (SWIFT, "the root alone pans", "let pan = isRoot ? kayaScene.keyboardPan[node.id] ?? 0 : 0\n kayaAnchored.offset(y: -pan).clipShape(KayaTopEdgeClip(active: pan > 0))"),
    (SWIFT, "the iOS root's frame is recorded outside its pan",
     "kayaAnchored.offset(y: -pan).clipShape(KayaTopEdgeClip(active: pan > 0))\n"
     " .background(isRoot ? KayaRootFrameReader(id: node.id) : nil)"),
    (SWIFT, "the mac root's frame is recorded", "kayaAnchored.background(isRoot ? KayaRootFrameReader(id: node.id) : nil)"),
    (SWIFT, "the root's frame is the platform's",
     ".onChange(of: geo.frame(in: .global)) { _, f in\n kayaRootFrames[id] = f\n kayaFrameMoved()"),
    # A layout that moved after the pan's last reading re-reads it, with no
    # clock (docs/traps.md, the quick-add field panned above its sheet's top).
    (SWIFT, "SwiftUI's track reader re-reads the pan", "kayaNodeFrames[id] = frame\n kayaFrameMoved()"),
    (SWIFT, "SwiftUI's cell reader re-reads the pan", "kayaNodeFrames[id] = global\n kayaDrainRowScrolls()\n kayaFrameMoved()"),
    (SWIFT, "SwiftUI's expect_safe failure names the pan's inputs",
     'failures.append(safeRead.why + (DispatchQueue.main.sync { kayaPanReading() } ?? ""))'),
    (SWIFT, "the keyboard is watched from the primary root", "kayaArmSelftestStartupDeadline()\n #if os(iOS)\n kayaWatchKeyboard()"),
    (SWIFT, "a following scroll keeps its end as the keyboard rises",
     "if node.followsEnd, !sideways, size.height < old.height - 0.5, wasAtEnd {"),
    (SWIFT, "the iOS textarea keeps its caret in view as its text moves",
     "func textViewDidChange(_ textView: UITextView) {\n kayaKeepCaretShown(textView)"),
    (SWIFT, "the wall holds type", 'kayaAwaitAnswer(answered)\n if let walled = kayaKeyboardWall("type") { failures.append(walled) }'),
    (SWIFT, "the wall holds type_secret",
     'kayaAwaitAnswer(secretAnswered)\n if let walled = kayaKeyboardWall("type_secret") { failures.append(walled) }'),
    (SWIFT, "the wall holds press return",
     'kayaAwaitAnswer(pressAnswered)\n if let walled = kayaKeyboardWall("press return") { failures.append(walled) }'),
    (SWIFT, "the wall holds press tab and space",
     'if let walled = kayaKeyboardWall("press \\(parts[1])") { failures.append(walled) }'),
    (SWIFT, "expect_keyboard reads the platform", "let keyboardUp = DispatchQueue.main.sync { kayaKeyboardInWindow() != nil }"),
    (SWIFT, "expect_safe reads the platform", "let safeRead = DispatchQueue.main.sync { kayaSafeReading(parts[1]) }"),
    (SWIFT, "expect_insets reads the platform", "DispatchQueue.main.sync(execute: { kayaInsetWords() })"),
    (SWIFT, "the mac has no software keyboard", "@MainActor func kayaKeyboardInWindow() -> CGRect? { nil }"),
    (HARNESS, "harness.rs reads the keyboard", "Step::ExpectKeyboard(want) => Some(poll(|| match stage.keyboard() {"),
    (HARNESS, "harness.rs reads the safe area", "Step::ExpectSafe(t, want) => Some(poll(|| match stage.safe(*t) {"),
    (HARNESS, "harness.rs reads the insets", "Step::ExpectInsets(want) => Some(poll(|| match stage.insets() {"),
    (RUNSIM, "the iOS lane raises the keyboard before any leg",
     "boot_pool()\n_keyboard_wrong = software_keyboard([*UDIDS, PAD_UDID], True)\nif _keyboard_wrong:\n die("),
    (RUNSIM, "the iOS lane puts the keyboard setting back", "wrong = software_keyboard(restored, False)"),
    (RUNSIM, "the setting is read back", 'if got != want:\n wrong.append('),
    (IOS_LANE, "the lane's one spelling of the setting", "SOFTWARE_KEYBOARD_PREF = (" + ", ".join(PREF) + ")"),
]


def findings(sources, backends=None):
    backends = BACKENDS if backends is None else backends
    out = []
    flats = {}

    def flattened(rel):
        if rel not in flats:
            flats[rel] = flat(sources[rel])
        return flats[rel]
    swift = sources[SWIFT]
    for label, opener, at, wants, never in BLOCKS:
        found = blocks(swift, opener)
        if len(found) <= at:
            out.append(f"safearea: {label} is gone — {SWIFT} lacks {opener.splitlines()[0]}")
            continue
        for want in wants:
            if flat(want) not in flat(found[at]):
                out.append(f"safearea: {label} lacks {want[:80]}")
        for name in never:
            if name in found[at]:
                out.append(f"safearea: {label} names {name}")
    bleed = blocks(swift, BLOCKS[0][1])
    if bleed and bleed[0].count(".ignoresSafeArea(") != 1:
        out.append(f"safearea: the bleed names .ignoresSafeArea( {bleed[0].count('.ignoresSafeArea(')} times, "
                   f"wanted once — a frame reader that ignores the safe area itself reads its own "
                   f"extended frame, and a bleed that stopped at the safe area read as bleeding")
    walls = swift.count("kayaKeyboardWall(")
    if walls != 5:
        out.append(f"safearea: the wall is called from {walls - 1} typing verb site(s), wanted 4 "
                   f"(type, type_secret, press return, press tab and space)")
    for rel, label, call in CALLS:
        if flat(call) not in flattened(rel):
            out.append(f"safearea: {label} no longer holds — {rel} lacks {call.splitlines()[0]}")
    for rel, label, call in NATIVE:
        if flat(call) not in flattened(rel):
            out.append(f"safearea: {label} no longer holds — {rel} lacks {call.splitlines()[0][:70]}")
    for rel, opener, names in NEVER:
        found = blocks(sources[rel], opener)
        if not found:
            out.append(f"safearea: {rel} lacks {opener}")
        for name in names:
            if found and name in found[0]:
                out.append(f"safearea: {rel}'s {opener} names {name}")
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in backends:
            out.append(f"safearea: {rel} no longer stubs the safe area and has no row in "
                       f"tools/lib/safearea_routes.py's BACKENDS")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8")
               for rel in [HARNESS, SWIFT, RUNSIM, IOS_LANE, MEDIA, HELPER, EMULATOR, *STUBBED]}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("safearea clauses held",
              sum(len(w) + len(n) + 1 for *_, w, n in BLOCKS) + len(CALLS) + 1 + len(NATIVE)
              + sum(len(n) for *_, n in NEVER), floor=95)
    g.counted("safearea backends still stubbed", len(still), floor=0)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        ("a bleed taking the keyboard's region", SWIFT, r"\.ignoresSafeArea\(\.container, edges: edges\)",
         ".ignoresSafeArea(.all, edges: edges)", "the bleed names .all"),
        ("a bleed that stops at the safe area", SWIFT,
         r"(kayaBleedFrames\[node\.id\] = f \}\n\s+\}\n\s+\))\n\s+\.ignoresSafeArea\(\.container, edges: edges\)",
         r"\1", "the bleed lacks kayaBleedFrames[node.id] = f }"),
        ("the bleed's reader outside the ignore", SWIFT,
         r"(\n\s+)content\n\s+\.background\(\n((?:.*\n){5}\s+\))\n\s+\.ignoresSafeArea\(\.container, edges: edges\)\n",
         r"\1content\1.ignoresSafeArea(.container, edges: edges)\1.background(\n\2\n",
         "the bleed lacks kayaBleedFrames[node.id] = f }"),
        ("the bleed's reader extending itself", SWIFT,
         r"(\.onChange\(of: geo\.frame\(in: \.global\)\) \{ _, f in kayaBleedFrames\[node\.id\] = f \}\n\s+\})\n",
         r"\1\n                    .ignoresSafeArea(.container, edges: edges)\n",
         "the bleed names .ignoresSafeArea( 2 times"),
        ("a bleed that stops at the inset", SWIFT,
         r"KayaBleedLayout\(edges: edges, inset: inset, slotHeight: slotHeight\)",
         "KayaBleedLayout(edges: edges, inset: 0, slotHeight: slotHeight)", "the bleed lacks KayaBleedLayout(edges: edges, inset: inset"),
        ("the slot passed through, the runaway", SWIFT,
         r"let answer = subviews\.first\?\.sizeThatFits\(grown\) \?\? \.zero\n\s+return CGSize\(width: max\(0, answer\.width - dx\), height: max\(0, answer\.height - dy\)\)",
         "return subviews.first?.sizeThatFits(proposal) ?? .zero", "the bleed's slot names sizeThatFits(proposal)"),
        ("a grown canvas that keeps its last blit's size", SWIFT,
         r"\n\s+minWidth: node\.grow > 0 \? 0 : nil,(\n\s+maxWidth: node\.grow > 0 \? \.infinity : nil,)"
         r"\n\s+minHeight: node\.grow > 0 \? 0 : nil,",
         r"\1", "a grown canvas takes its offer below its last blit"),
        ("touching through a padded container", SWIFT, r"kayaFilledInset\(parent\) == 0", "true",
         "the touching sides lacks kayaFilledInset(parent) == 0"),
        ("expect_safe blind to a runaway", SWIFT, r'return \(nil, "\\\(spec\) runs past the window\'s edge: \\\(facts\)"\)',
         'return ("bleeds", facts)', "expect_safe's reading lacks runs past the window's edge"),
        ("expect_safe answering from the pan", SWIFT, r"let keyboard = kayaKeyboardInWindow\(\)\n(\s+)let tol: CGFloat = 1",
         r"let keyboard = kayaScene.keyboardPan.isEmpty ? nil : kayaKeyboardInWindow()\n\1let tol: CGFloat = 1",
         "expect_safe's reading names keyboardPan"),
        ("expect_safe ignoring the keyboard", SWIFT, r"frame\.maxY > keyboard\.minY \+ tol", "false",
         "expect_safe's reading lacks frame.maxY > keyboard.minY + tol"),
        ("the iOS insets off the fullscreen prop", SWIFT,
         r"let barHidden = window\.windowScene\?\.statusBarManager\?\.isStatusBarHidden \?\? false",
         "let barHidden = kayaScene.windows[0]?.fullscreen ?? false", "the iOS insets names fullscreen"),
        ("the keyboard frame never kept", SWIFT, r"kayaKeyboardScreenFrame = end\n", "_ = end\n",
         "the keyboard's frame lacks kayaKeyboardScreenFrame = end"),
        ("the pan never written", SWIFT, r"kayaScene\.keyboardPan = \[root: next\]", "_ = next",
         "the pan lacks kayaScene.keyboardPan = [root: next]"),
        ("the pan never applied", SWIFT, r"kayaAnchored\.offset\(y: -pan\)\.clipShape\(KayaTopEdgeClip\(active: pan > 0\)\)",
         "kayaAnchored", "the root alone pans"),
        ("the pan as a branch, which rebuilt the root and dropped the focus", SWIFT,
         r"kayaAnchored\.offset\(y: -pan\)\.clipShape\(KayaTopEdgeClip\(active: pan > 0\)\)",
         "if pan > 0 { kayaAnchored.offset(y: -pan) } else { kayaAnchored }", "the root alone pans"),
        ("the keyboard never watched", SWIFT, r"(#if os\(iOS\)\n\s+)kayaWatchKeyboard\(\)", r"\1_ = 0",
         "the keyboard is watched from the primary root"),
        ("the wall's caret read off the field", SWIFT, r"rects\.caret\.maxY <= keyboard\.minY \+ 0\.5",
         "rects.field.minY <= keyboard.minY + 0.5", "the wall's reading lacks rects.caret.maxY"),
        ("type without the wall", SWIFT, r'\n\s+if let walled = kayaKeyboardWall\("type"\) \{ failures\.append\(walled\) \}', "",
         "the wall holds type"),
        ("press return without the wall", SWIFT,
         r'\n\s+if let walled = kayaKeyboardWall\("press return"\) \{ failures\.append\(walled\) \}', "",
         "the wall holds press return"),
        ("the wall's sentence blaming the keyboard setting whatever it saw", SWIFT,
         r"if kayaKeyboardFrames == 0 \{", "if true {", "the wall's reading lacks if kayaKeyboardFrames == 0 {"),
        ("the wall's sentence blaming the setting it read as false", SWIFT,
         r"if pref == false \{", "if false {", "the wall's reading lacks if pref == false {"),
        ("a following scroll losing its end", SWIFT, r"if node\.followsEnd, !sideways, size\.height < old\.height - 0\.5, wasAtEnd \{",
         "if false {", "a following scroll keeps its end"),
        ("the mac answering a keyboard", SWIFT, r"@MainActor func kayaKeyboardInWindow\(\) -> CGRect\? \{ nil \}",
         "@MainActor func kayaKeyboardInWindow() -> CGRect? { .zero }", "the mac has no software keyboard"),
        ("harness.rs not reading the keyboard", HARNESS, r"match stage\.keyboard\(\) \{", "match Ok::<bool, String>(false) {",
         "harness.rs reads the keyboard"),
        ("the lane never raising the keyboard", RUNSIM,
         r"_keyboard_wrong = software_keyboard\(\[\*UDIDS, PAD_UDID\], True\)", "_keyboard_wrong = []",
         "the iOS lane raises the keyboard"),
        ("the lane leaving the setting behind", RUNSIM, r"wrong = software_keyboard\(restored, False\)", "wrong = []",
         "the iOS lane puts the keyboard setting back"),
        ("the setting never read back", RUNSIM, r"if got != want:\n(\s+)wrong\.append\(", r"if False:\n\1wrong.append(",
         "the setting is read back"),
        ("the lane spelling another setting", IOS_LANE, r'"AutomaticMinimizationEnabled"\)', '"HardwareKeyboardLastSeen")',
         "the lane's one spelling of the setting"),
    ]
    cuts += [
        ("Compose's gradient stopping at the safe area, as shipped", COMPOSE,
         r"val reach = kayaGroundReach\(node\) \{ Pair\(stops\[0\]\.toArgb\(\), stops\[1\]\.toArgb\(\)\) \}",
         "val reach: Pair<WindowInsets, BooleanArray>? = null", "Compose's gradient ground runs through"),
        ("Compose's image ground stopping at the safe area, as shipped", COMPOSE,
         r"val reach = kayaGroundReach\(node\) \{ ext ->",
         "val reach: Pair<WindowInsets, BooleanArray>? = null; val unused = { ext: IntArray ->",
         "Compose's image ground runs through the safe area it touches"),
        ("Compose's growth unrecorded", COMPOSE, r"kayaGroundGrowth\[node\.id\] = grow\n", "\n",
         "Compose's reaching picture is drawn over the grown area"),
        ("Compose's readers placing the picture over the box", COMPOSE,
         r"val grow = kayaGroundGrowth\[id\] \?: FloatArray\(4\)", "val grow = FloatArray(4)",
         "Compose's picture readers place the picture where it is drawn"),
        ("SwiftUI's image ground reaching through the window's inset", SWIFT,
         r"guard \(kayaScene\.windows\[0\]\?\.inset \?\? 16\) == 0 else \{ return \[\] \}",
         "guard true else { return [] }", "SwiftUI's image ground reaches the bars only"),
        ("SwiftUI's image ground stopping at the safe area, as shipped", SWIFT,
         r"(kayaGroundDrawn\(node, inner: geo\.frame\(in: \.global\)\) \}\n\s+\}\n\s+\)\n\s+)\.ignoresSafeArea\(\.container, edges: reach\)",
         r"\1.ignoresSafeArea(.container, edges: [])", "SwiftUI's image ground ignores the safe area"),
        ("SwiftUI's status bar left to the interface style, as shipped", SWIFT,
         r"class_replaceMethod\(cls, sel, imp_implementationWithBlock\(answer\), method_getTypeEncoding\(method\)\)",
         "_ = answer", "SwiftUI's status bar answers an image ground's claim"),
        ("SwiftUI's root handing the question to its child, as first built", SWIFT,
         r"kayaStatusOverride == 0 \? original\(me, child\) : nil", "original(me, child)",
         "SwiftUI's root keeps the status bar question"),
        ("Compose's claim taking the picture across the whole bar", COMPOSE,
         r"val c = if \(x < 0f \|\| x >= w\) ground else \{", "val c = if (false) ground else {",
         "Compose's claim reads the page where the picture is not drawn"),
        ("Compose's bar read at one end, as first built", COMPOSE,
         r"val far = shot\.at\(shot\.bitmap\.width - 4 \* shot\.density, y\)", "val far = strip",
         "Compose's expect_system_bars reads both ends of a bar"),
        ("SwiftUI's claim taking the picture across the whole bar", SWIFT,
         r"let share = over\.isNull \? 0 : Double\(over\.width / third\.width\)", "let share = 1.0",
         "SwiftUI's claim reads the page where the picture is not drawn"),
        ("SwiftUI's bar read at one end, as first built", SWIFT,
         r"let far = shot\.at\(CGPoint\(x: window\.bounds\.width - 4, y: y\)\)", "let far = Optional(strip)",
         "SwiftUI's expect_system_bars reads both ends of a bar"),
        ("SwiftUI's claim outliving its screen", SWIFT, r"\.onDisappear \{ kayaGroundUnder\(node\.id, nil\) \}",
         ".onDisappear { }", "SwiftUI's image ground's claim ends when it goes"),
        ("SwiftUI's readers placing the picture over the box", SWIFT,
         r"let \(gl, gt, gr, gb\) = kayaGroundGrowth\(node\.id\)", "let (gl, gt, gr, gb) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))",
         "SwiftUI's picture readers place the picture where it is drawn"),
        ("Compose's ground reaching through the window's inset", COMPOSE,
         r"KayaSceneModel\.windowInset != 0\.0\) null", "false) null",
         "Compose's ground reaches the bars only where the window gives no inset"),
        ("Compose's claim outliving a popped screen", COMPOSE,
         r"onDispose \{ kayaBarGrounds\.remove\(node\.id\) \}", "onDispose { }",
         "Compose's ground's claim on the bars ends with its composition"),
        ("Compose's status icons left to the system, as shipped", COMPOSE,
         r"controller\.isAppearanceLightStatusBars = kayaDarkIconsOn\(status\)\n", "Unit\n",
         "Compose's bar icons follow what is drawn behind them"),
        ("Compose's bar icons never set", COMPOSE, r"\n(\s+)KayaSystemBarIcons\(\)\n(\s+)\}\n", r"\n\2}\n",
         "Compose's bar icons are set from the root"),
        ("SwiftUI's status bar read off the interface style alone", SWIFT,
         r"let style = manager\.statusBarStyle", "let style = UIStatusBarStyle.default",
         "SwiftUI's expect_system_bars reads the scene's status bar style"),
        ("harness.rs answering its own system bars", HARNESS, r"match stage\.system_bars\(\) \{",
         "match Ok::<String, String>(want.clone()) {", "harness.rs reads the system bars"),
        ("GTK's bleed margins gone", GTK, r"\.kaya-bleed-top \{\{ margin-top: -\{px\}px; \}\}", "",
         "GTK's bleed leaves the root's padding"),
        ("GTK's drain not refreshing the bleed", GTK, r"presentation_report\(core\);\n(\s+)refresh_bleeds\(core\);",
         r"presentation_report(core);\n\1let _ = 0;", "GTK's touching sides refresh at every drain"),
        ("GTK reading GtkBox::orientation under a flex manager", GTK,
         r"\.and_then\(\|l\| l\.downcast_ref::<flex::FlexLayout>\(\)\.map\(\|f\| f\.orientation\(\) == gtk4::Orientation::Vertical\)\)",
         ".and_then(|_l| None)", "GTK reads a container's axis"),
        ("GTK's bled picture left at its align's width", GTK,
         r"if picture\.is_some\(\) \{\n(\s+)widget\.set_halign\(gtk4::Align::Fill\);", r"if false {\n\1widget.set_halign(gtk4::Align::Fill);",
         "GTK's bled picture re-takes its slot's width"),
        ("GTK's safe read in the content box's coordinates", GTK, r"let area = content\n(\s+)\.compute_bounds\(&content\)",
         r"let area = content\n\1.compute_bounds(&widget)", "GTK's expect_safe reads the content's border box"),
        ("WinUI's batch not refreshing the bleed", WINUI, r"flush_container_tracks\(core\)\?;\n(\s+)refresh_bleeds\(core\)",
         r"flush_container_tracks(core)?;\n\1Ok(())", "WinUI's touching sides refresh"),
        ("WinUI's bled canvas tracked at its slot", WINUI, r"f64::from\(slot\.Width\) - m\.Left - m\.Right",
         "f64::from(slot.Width)", "WinUI's bled canvas is drawn past its slot"),
        ("WinUI's inset read off the bled child's own origin", WINUI,
         r"let slot = LayoutInformation::GetLayoutSlot\(&child\)\?;", "let slot = child.ActualOffset()?;",
         "WinUI's expect_inset reads the first child's slot"),
        ("WinUI's bled picture cropped from the top", WINUI,
         r"image\.SetVerticalAlignment\(bindings::Microsoft::UI::Xaml::VerticalAlignment::Center\)\?;",
         "image.SetVerticalAlignment(bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch)?;",
         "WinUI's bled picture crops about its centre"),
        ("WinUI's bled picture cropped from the left", WINUI,
         r"image\.SetHorizontalAlignment\(bindings::Microsoft::UI::Xaml::HorizontalAlignment::Center\)\?;",
         "image.SetHorizontalAlignment(bindings::Microsoft::UI::Xaml::HorizontalAlignment::Stretch)?;",
         "WinUI's bled picture crops about its centre"),
        ("WinUI's bled picture bounded by its own MaxHeight, as shipped", WINUI,
         r"image\.SetMaxHeight\(f64::INFINITY\)\?;", "image.SetMaxHeight(fit)?;",
         "WinUI's bled picture's slot is its column's row"),
        ("WinUI's expect_safe reading the overflowing fill", WINUI,
         r"if bled && b > t \{", "if false {", "WinUI's bled picture reads its slot's cut as its frame"),
        ("WinUI's expect_safe blind to its scroll viewers", WINUI, r"if node\.cast::<ScrollViewer>\(\)\.is_ok\(\) \{",
         "if false {", "WinUI's expect_safe cuts by each scroll viewer's viewport"),
        ("WinUI's expect_safe walking no ancestor, as shipped", WINUI,
         r"let mut up = VisualTreeHelper::GetParent\(&element\)\.ok\(\);",
         "let mut up = VisualTreeHelper::GetParent(&element).ok().filter(|_| false);",
         "WinUI's expect_safe walks every ancestor"),
        ("WinUI's own slot cut left out of what shows", WINUI,
         r"let shown = \[frame\[0\] \+ l, frame\[1\] \+ t, frame\[0\] \+ r, frame\[1\] \+ b\];",
         "let shown = [frame[0], frame[1], frame[0] + frame[2], frame[1] + frame[3]];",
         "WinUI's expect_safe starts from what its own slot leaves"),
        ("WinUI's verdict handed the unclipped frame", WINUI, r"frame,\n(\s+)visible,\n", r"frame,\n\1frame,\n",
         "WinUI's expect_safe hands the verdict what shows"),
        ("GTK's expect_safe reading the unclipped frame, as shipped", GTK,
         r"let shown = clipped_by_ancestors\(&widget, &content, frame\);", "let shown = Some(frame);",
         "GTK's expect_safe reads what its ancestors clip"),
        ("GTK's clip blind to its scrolled windows", GTK,
         r"if ancestor\.overflow\(\) == gtk4::Overflow::Hidden \|\| ancestor\.is::<gtk4::ScrolledWindow>\(\) \{",
         "if false {", "GTK's clip is every ancestor that clips"),
        ("GTK's unmapped widget read as shown", GTK, r"if !widget\.is_mapped\(\) \{\n(\s+)return None;",
         r"if false {\n\1return None;", "GTK's unmapped widget shows nothing"),
        ("the desktops' verdict blind to a clipped top", HARNESS, r"vx > x \+ tol \|\| vy > y \+ tol \|\| ",
         "vx > x + tol || ", "the desktops' verdict refuses a frame clipped on any side"),
        ("the desktops' verdict passing a frame with nothing on screen", HARNESS, r"if vw <= 0\.0 \|\| vh <= 0\.0 \{",
         "if false {", "the desktops' verdict refuses a frame with nothing on screen"),
        ("SwiftUI's expect_safe reading the unclipped frame, as shipped", SWIFT,
         r"let \(visible, cuts\) = kayaVisibleFrame\(node, frame\)", "let (visible, cuts) = (frame, [String]())",
         "expect_safe's reading lacks let (visible, cuts) = kayaVisibleFrame"),
        ("SwiftUI's clip test blind to a clipped top", SWIFT, r"visible\.minY > frame\.minY \+ tol \|\| ", "",
         "expect_safe's reading lacks visible.minX > frame.minX"),
        ("SwiftUI's expect_safe passing an empty visible frame", SWIFT,
         r"if visible\.width <= 0 \|\| visible\.height <= 0 \{", "if false {",
         "expect_safe's reading lacks if visible.width <= 0"),
        ("SwiftUI's expect_safe ignoring a field's caret line", SWIFT, r"caret\.view === kayaPlatformTextView\(node\),",
         "false,", "expect_safe's reading lacks caret.view === kayaPlatformTextView(node)"),
        ("SwiftUI's visible frame blind to its scrolls", SWIFT, r"ancestor\.kind == kindScroll \{\n(\s+)let next = shown",
         r"false {\n\1let next = shown", "the visible frame lacks ancestor.kind == kindScroll"),
        ("SwiftUI's visible frame blind to its root", SWIFT,
         r"if let root = kayaRootFrames\[current\] \{", "if let root = Optional<CGRect>.none {",
         "the visible frame lacks if let root = kayaRootFrames[current]"),
        ("the mac root's frame never recorded", SWIFT,
         r"kayaAnchored\.background\(isRoot \? KayaRootFrameReader\(id: node\.id\) : nil\)", "kayaAnchored",
         "the mac root's frame is recorded"),
        ("the iOS root's frame never recorded", SWIFT,
         r"(clipShape\(KayaTopEdgeClip\(active: pan > 0\)\))\n\s+\.background\(isRoot \? KayaRootFrameReader\(id: node\.id\) : nil\)",
         r"\1", "the iOS root's frame is recorded outside its pan"),
        ("the root's frame read from kaya's pan", SWIFT, r"\{ _, f in\n(\s+)kayaRootFrames\[id\] = f\n",
         r"{ _, f in\n\1kayaRootFrames[id] = f.offsetBy(dx: 0, dy: kayaScene.keyboardPan[id] ?? 0)\n",
         "the root's frame is the platform's"),
        ("UIKit's visible frame blind to the bars", SWIFT, r"if v\.next is UIViewController \{", "if false {",
         "a UIKit view's visible frame lacks if v.next is UIViewController"),
        ("UIKit's visible frame blind to a clipping superview", SWIFT,
         r"if v\.clipsToBounds \|\| v\.layer\.masksToBounds \{", "if false {",
         "a UIKit view's visible frame lacks if v.clipsToBounds"),
        ("SwiftUI's focused field left part-scrolled, as shipped", SWIFT,
         r"\n\s+kayaRevealInScroll\(rects\.view, above: keyboard, in: rects\.window\)", "",
         "the pan lacks kayaRevealInScroll"),
        ("SwiftUI's reveal blind to the keyboard", SWIFT,
         r"min\(port\.maxY - scroll\.adjustedContentInset\.bottom, keyboard\.minY\)",
         "port.maxY - scroll.adjustedContentInset.bottom", "the scroll's reveal lacks let roomBottom"),
        ("SwiftUI's wall blind to what its parents clip, as shipped", SWIFT,
         r"if shown, rects\.caret\.maxY <= keyboard\.minY \+ 0\.5", "if rects.caret.maxY <= keyboard.minY + 0.5",
         "the wall's reading lacks if shown, rects.caret.maxY"),
        ("GTK's bled picture drawn from its corner", GTK,
         r"Point::new\(\(\(width - dw\) / 2\.0\) as f32, \(\(height - dh\) / 2\.0\) as f32\)",
         "Point::new(0.0, 0.0)", "GTK's bled picture crops about its centre"),
        ("SwiftUI's bled picture pinned to its top", SWIFT,
         r"(Color\.clear\n\s+)\.overlay \{(\n\s+#if os\(macOS\)\n\s+Image\(nsImage: image\)\.resizable\(\)\.scaledToFill\(\))",
         r"\1.overlay(alignment: .top) {\2", "SwiftUI's bled picture crops about its centre"),
        ("Compose's root padding the whole surface again", COMPOSE,
         r"Box\(modifier = Modifier\.fillMaxSize\(\)\.dragAndDropTarget\(",
         "Box(modifier = Modifier.fillMaxSize().safeDrawingPadding().dragAndDropTarget(", "names safeDrawingPadding"),
        ("Compose's section bar riding the keyboard", COMPOSE, r"bottomConsumed = !imeShown,",
         "bottomConsumed = true,", "Compose's pane takes the keyboard's side"),
        ("Compose's top bar at Material's own insets", COMPOSE,
         r"windowInsets = WindowInsets\.safeDrawing\.only\(WindowInsetsSides\.Horizontal \+ WindowInsetsSides\.Top\),\n",
         "", "Compose's top bar consumes its own side"),
        ("Compose squeezing every root into the room above the keyboard", COMPOSE,
         r"keyboard && !rides -> bars\.only\(WindowInsetsSides\.Bottom\)", "false -> null",
         "Compose's root gives up its height"),
        ("Compose's pan never written", COMPOSE, r"KayaSceneModel\.keyboardPan = next", "next.toString()",
         "Compose's pan is written"),
        ("Compose's bleed under the keyboard", COMPOSE, r"val bleedBottom = if \(keyboard\) null else bottom",
         "val bleedBottom = bottom", "Compose's bleed never counts the keyboard"),
        ("Compose's content padded by a composition read, the shipped late frame", COMPOSE,
         r"\.windowInsetsPadding\(pads\.content\)", ".padding(pads.content.asPaddingValues())",
         "private fun KayaContentBox( names asPaddingValues"),
        ("Compose's content pads read in composition", COMPOSE, r"(\n\s+)val around = safe\.only\(",
         r"\1val top = safe.getTop(LocalDensity.current)\1val around = safe.only(",
         "private fun kayaContentPads( names getTop("),
        ("Compose's section bar's height from a previous frame, as shipped", COMPOSE,
         r"Layout\(modifier = Modifier\.fillMaxSize\(\), content = \{\n(\s+)Box \{",
         r"Layout(modifier = Modifier.fillMaxSize(), content = {\n\1Box(modifier = Modifier.fillMaxSize()"
         r".padding(bottom = if (imeShown) 0.dp else KayaSceneModel.sectionBarHeight)) {",
         "names padding(bottom"),
        ("Compose's section bar's room off the reported height", COMPOSE,
         r"\(h - bar\.height\)\.coerceAtLeast\(0\)",
         "(h - KayaSceneModel.sectionBarHeight.roundToPx()).coerceAtLeast(0)",
         "Compose's content is measured against the section bar in the same pass"),
        ("Compose's bleed read before its layout", COMPOSE,
         r"val left = pads\?\.getLeft\(this, layoutDirection\) \?: 0",
         "val left = leftBefore", "Compose's bleed reads the safe area at layout"),
        ("Compose's expect_safe answering from the pan", COMPOSE, r"val frame = kayaNodeFrames\[node\.id\]\n",
         "val frame = kayaNodeFrames[node.id]?.translate(0f, KayaSceneModel.keyboardPan)\n", "names keyboardPan"),
        ("Compose's expect_safe reading the unclipped frame, as shipped", COMPOSE,
         r'\n\s+kayaClipped\(node, frame, visible, tol\)\?\.let \{ return Pair\(null, "\$spec \$it: \$facts"\) \}', "",
         "Compose's expect_safe refuses a frame its parents clip"),
        ("Compose's visible rect as the unclipped frame", COMPOSE,
         r"kayaNodeVisible\[id\] = it\.boundsInWindow\(\)", "kayaNodeVisible[id] = kayaNodeFrames.getValue(id)",
         "Compose's frames record what their ancestors leave on screen"),
        ("Compose's clip test blind to a clipped top", COMPOSE,
         r"visible\.left > frame\.left \+ tol \|\| visible\.top > frame\.top \+ tol \|\|",
         "visible.left > frame.left + tol ||", "Compose's clip test reads all four sides"),
        ("Compose's wall reading the caret clamped into the frame, as shipped", COMPOSE,
         r"val caret = kayaCaretLine\(field, frame\)", "val caret = kayaCaretRect(field, frame)",
         "kayaWallReading( names kayaCaretRect("),
        ("Compose's wall blind to what its parents clip", COMPOSE,
         r"if \(shown && caret\.bottom <= keyboardTop", "if (caret.bottom <= keyboardTop",
         "Compose's wall holds the caret line to what shows"),
        ("Compose's every root riding, the squeezed composer as shipped", COMPOSE,
         r"kayaRides\(root\) && !KayaSceneModel\.keyboardOverflow", "kayaRides(root)",
         "Compose's root stops riding once a focused field is squeezed"),
        ("SwiftUI's track reader leaving a dropped copy's record, as shipped", SWIFT,
         r"\n\s+\.onDisappear \{ kayaTrackRecords\.retire\(id, token\) \}", "",
         "SwiftUI's track reader retires a dropped copy's record"),
        ("SwiftUI's cell reader leaving a dropped copy's record, as shipped", SWIFT,
         r"\n\s+\.onDisappear \{ kayaCellRecords\.retire\(id, token\) \}", "",
         "SwiftUI's cell reader retires a dropped copy's record"),
        ("SwiftUI's retired record handing back nothing", SWIFT,
         r"if newest, let survivor = list\.last \{ survivor\.apply\(\) \}", "_ = newest",
         "SwiftUI's retired record hands the node back to its newest survivor"),
        ("Compose's grown text area holding its column under the keyboard, as shipped", COMPOSE,
         r"node\.kind == KayaCompose\.KIND_SCROLL \|\| node\.kind == KayaCompose\.KIND_TEXTAREA\) return",
         "node.kind == KayaCompose.KIND_SCROLL) return", "Compose's grown text area rides the keyboard"),
        ("Compose's squeeze never noticed", COMPOSE, r"KayaSceneModel\.keyboardOverflow = true\n", "Unit\n",
         "Compose's squeeze is detected on the focused field"),
        ("Compose's overflow outliving the keyboard", COMPOSE,
         r"if \(insets != null && !imeShown && KayaSceneModel\.keyboardOverflow\) KayaSceneModel\.keyboardOverflow = false\n",
         "", "Compose's overflow ends with the keyboard"),
        ("Compose's overflowing root squeezed after all", COMPOSE,
         r"constraints\.copy\(minHeight = constraints\.maxHeight, maxHeight = Constraints\.Infinity\)\)\n(\s+)layout\(placeable\.width, constraints\.maxHeight\) \{ placeable\.place\(0, 0\) \}\n(\s+)\} else Modifier\)\n(\s+)\.offset \{ androidx\.compose\.ui\.unit\.IntOffset\(0, -pan\.toInt\(\)\) \}\n(\s+)// The OUTER",
         r"constraints)\n\1layout(placeable.width, constraints.maxHeight) { placeable.place(0, 0) }\n\2} else Modifier)\n\3.offset { androidx.compose.ui.unit.IntOffset(0, -pan.toInt()) }\n\4// The OUTER",
         "Compose's overflowing root keeps its natural height"),
        ("Compose's focused textarea at its three lines, as shipped", COMPOSE,
         r"\n\s+\.then\(if \(cap != null\) Modifier\.sizeIn\(maxHeight = [^\n]*", "",
         "Compose's cap bounds the field"),
        ("Compose's cap below one line", COMPOSE,
         r"maxOf\(kayaOneLineHeight\(field, frame\), keyboardTop - kayaKeyboardRoomTop\(field, insets\) - gap\)",
         "keyboardTop - kayaKeyboardRoomTop(field, insets) - gap", "Compose's focused textarea is capped"),
        ("Compose's one line as the frame less its own lines, as shipped", COMPOSE,
         r"return 2f \* \(top - frame\.top\) \+", "return frame.height - (top - frame.top) +",
         "the decoration's padding around its first line"),
        ("Compose's viewport top read clipped", COMPOSE, r"kayaTextTops\[node\.id\] = it\.positionInWindow\(\)\.y",
         "kayaTextTops[node.id] = it.boundsInWindow().top", "Compose's viewport top is read unclipped"),
        ("Compose's expect_fills trusting the track under a keyboard", COMPOSE,
         r"val room = kayaOwedRoom\(activity, widget\)", "val room: Double? = null",
         "Compose's expect_fills owes a focused textarea A20's room"),
        ("Compose's owed room read off the cap", COMPOSE,
         r"return kayaFieldRoom\(widget, frame, decor, insets\)\?\.toDouble\(\)",
         "return KayaSceneModel.keyboardFieldCap?.second?.toDouble()", "Compose's owed room is read from the window"),
        ("SwiftUI's expect_fills trusting the track under a keyboard", SWIFT,
         r"if let room = kayaOwedRoom\(widget\.id\), room < track - 2 \{",
         "if let room = Optional<CGFloat>.none, room < track - 2 {",
         "SwiftUI's expect_fills owes a focused textarea A20's room"),
        ("SwiftUI's owed room read off the cap", SWIFT,
         r"return kayaFieldRoom\(keyboard: keyboard, rects: rects\)\n",
         "return kayaScene.keyboardFieldCap[id]\n", "the owed room lacks return kayaFieldRoom"),
        ("Compose's capped textarea keeping three lines", COMPOSE,
         r"(else if \(cap != null\) TextFieldLineLimits\.MultiLine\(\n\s+)minHeightInLines = 1,",
         r"\1minHeightInLines = 3,", "Compose's capped textarea's floor is one line"),
        ("Compose's cap never written", COMPOSE, r"KayaSceneModel\.keyboardFieldCap = field\.id to want",
         "Unit", "Compose's cap is written"),
        ("Compose's cap outliving the keyboard", COMPOSE,
         r"\n\s+if \(capped != null && \(!imeShown \|\| capped\.first != field\?\.id\)\) KayaSceneModel\.keyboardFieldCap = null",
         "", "Compose's cap ends with the keyboard"),
        ("SwiftUI's textarea at its 96 pt, as shipped", SWIFT,
         r"maxLines: node\.maxLines, cap: kayaScene\.keyboardFieldCap\[node\.id\]\)", "maxLines: node.maxLines)",
         "the iOS textarea is framed by its cap"),
        ("SwiftUI's cap held up by the 96 pt floor", SWIFT, r"min\(96, cap \?\? 96\)", "96",
         "a capped textarea's floor gives way"),
        ("SwiftUI's growing textarea past its cap", SWIFT, r"min\(text \+ insets, cap \?\? \.infinity\)",
         "text + insets", "a capped growing textarea answers its cap"),
        ("SwiftUI's cap below one line", SWIFT, r"max\(floor, keyboard\.minY - top - margin\)",
         "keyboard.minY - top - margin", "A20's room lacks return max(floor"),
        ("SwiftUI's cap measured under the status bar", SWIFT,
         r"let top = max\(rects\.window\.safeAreaInsets\.top, kayaRootFrames\[root\]\?\.minY \?\? 0\)",
         "let top = rects.window.safeAreaInsets.top", "A20's room lacks let top = max("),
        ("SwiftUI's cap outliving the keyboard", SWIFT,
         r"\n\s+if !kayaScene\.keyboardFieldCap\.isEmpty \{ kayaScene\.keyboardFieldCap = \[:\] \}", "",
         "the pan lacks if !kayaScene.keyboardFieldCap.isEmpty"),
        ("Compose's pan room under the status bar, as shipped", COMPOSE,
         r"else maxOf\(safeTop\.toFloat\(\), kayaContentTop\)", "else safeTop.toFloat()",
         "Compose's pan measures its room under the top bar"),
        ("Compose's sheet pan room under the status bar, as shipped", COMPOSE,
         r"maxOf\(safeTop\.toFloat\(\), kayaSheetTops\[kayaRootIdOf\(field\.id\)\] \?: 0f\)", "safeTop.toFloat()",
         "Compose's sheet pans within its own content"),
        ("Compose's pan leaving a field above its room inside the dead zone, as shipped", COMPOSE,
         r"\(covered < -2 \* margin \|\| above\)", "covered < -2 * margin",
         "Compose's pan brings a field that fits back below its room's top"),
        ("Compose's pan aiming the bottom alone, a field near its room's height left above it", COMPOSE,
         r"val margin = minOf\(gap, maxOf\(0f, room - need\)\)", "val margin = gap",
         "Compose's pan aims a field that fits with its top inside its room"),
        ("Compose's pan aiming a field that fits by its caret", COMPOSE,
         r"val need = if \(frame\.height <= room\) frame\.height else caret\.height", "val need = caret.height",
         "Compose's pan aims a field that fits with its top inside its room"),
        ("Compose's expect_safe failure without the pan, as shipped", COMPOSE,
         r'failures\.add\(why \+ \(onUi\(activity\) \{ kayaPanReading\(activity\) \} \?: ""\)\)',
         "failures.add(why)", "Compose's expect_safe failure names the pan's inputs"),
        ("SwiftUI's pan leaving a field above its room inside the dead zone, as shipped", SWIFT,
         r"\} else if current > 0, above \{\n\s+next = max\(0, current \+ min\(covered \+ margin, rects\.field\.minY - roomTop\)\)\n\s+",
         "", "the pan lacks } else if current > 0, above"),
        ("SwiftUI's pan room under the status bar alone, as shipped", SWIFT,
         r"max\(window\.safeAreaInsets\.top, kayaRootFrames\[root\]\?\.minY \?\? 0\)\n",
         "window.safeAreaInsets.top\n", "the pan's room lacks max(window.safeAreaInsets.top"),
        ("SwiftUI's pan on a clock, as shipped", SWIFT,
         r"kayaPanQueued = true\n(\s+)CFRunLoopWakeUp\(CFRunLoopGetMain\(\)\)\n",
         r"DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { kayaPanEvaluate() }\n",
         "the pan's queue lacks kayaPanQueued = true"),
        ("SwiftUI's pan read before the commit", SWIFT,
         r"CFRunLoopActivity\.beforeWaiting\.rawValue, true, 2_001_100", "CFRunLoopActivity.beforeWaiting.rawValue, true, 0",
         "the pan after the commit lacks CFRunLoopActivity"),
        ("SwiftUI's pan reading a field its last pan has not moved yet", SWIFT,
         r"\n\s+kayaPanAimed = \(next, rects\.field\.minY\)", "",
         "the pan lacks kayaPanAimed = (next"),
        ("the pan's commit observer never installed", SWIFT,
         r"kayaKeyboardWatching = true\n\s+kayaPanAfterCommit\(\)\n", "kayaKeyboardWatching = true\n",
         "the keyboard's frame lacks kayaPanAfterCommit()"),
        ("SwiftUI's cell reader leaving the pan unread", SWIFT,
         r"(kayaNodeFrames\[id\] = global\n\s+kayaDrainRowScrolls\(\))\n\s+kayaFrameMoved\(\)", r"\1",
         "SwiftUI's cell reader re-reads the pan"),
        ("SwiftUI's track reader leaving the pan unread", SWIFT,
         r"(kayaNodeFrames\[id\] = frame)\n\s+kayaFrameMoved\(\)", r"\1",
         "SwiftUI's track reader re-reads the pan"),
        ("SwiftUI's root reader leaving the pan unread", SWIFT,
         r"(kayaRootFrames\[id\] = f)\n\s+kayaFrameMoved\(\)", r"\1",
         "the root's frame is the platform's"),
        ("SwiftUI's caret scrolled against TextKit 2's estimate, as shipped", SWIFT,
         r"\n\s+layout\.ensureLayout\(for: laid\)\n(\s+view\.layoutIfNeeded\(\))", r"\n\1",
         "the caret kept in its text view lacks layout.ensureLayout"),
        ("SwiftUI's caret left to UIKit's own scroll, as shipped", SWIFT,
         r"(func textViewDidChange\(_ textView: UITextView\) \{)\n\s+kayaKeepCaretShown\(textView\)", r"\1",
         "the iOS textarea keeps its caret in view"),
        ("SwiftUI's caret kept only while the layout has caught up", SWIFT,
         r"UIView\.performWithoutAnimation \{ view\.scrollRangeToVisible\(view\.selectedRange\) \}\n(\s+\})",
         r"if view.contentSize.height < 0 { view.scrollRangeToVisible(view.selectedRange) }\n\1",
         "the caret kept in its text view lacks layout.ensureLayout"),
        ("the wall's refusal without the text view's own scroll, as shipped", SWIFT,
         r'"\(docs/safe-area-plan\.md A4, A9\)" \+ kayaFieldScrollReading\(rects\)',
         '"(docs/safe-area-plan.md A4, A9)"', "the wall's reading lacks"),
        ("SwiftUI's expect_safe failure without the pan, as shipped", SWIFT,
         r'failures\.append\(safeRead\.why \+ \(DispatchQueue\.main\.sync \{ kayaPanReading\(\) \} \?\? ""\)\)',
         "failures.append(safeRead.why)", "SwiftUI's expect_safe failure names the pan's inputs"),
        ("Compose's undetented sheet squeezed by Material's keyboard padding, as shipped", COMPOSE,
         r"val keeps = detented \|\| typing", "val keeps = detented", "Compose's sheet keeps its layout while typing"),
        ("Compose's cramped sheet keeping its handle, as shipped", COMPOSE,
         r"dragHandle = if \(cramped\) null else", "dragHandle = if (false) null else",
         "Compose's cramped sheet drops its handle"),
        ("Compose's cramped sheet measured against its window's bottom", COMPOSE,
         r"kayaKeyboardTop\(hostView\) - top < field\.height", "hostView.rootView.height - top < field.height",
         "Compose's cramped sheet is measured against the keyboard's top"),
        ("Compose's type without the wall", COMPOSE,
         r'\n\s+if \(why == null\) kayaKeyboardWall\(activity, "type"\)\?\.let \{ failures\.add\(it\) \}', "",
         "Compose's wall holds type"),
        ("Compose's keys to the activity only", COMPOSE,
         r"if \(host != null && host !== activity\.window\.decorView\) host\.dispatchKeyEvent\(key\)",
         "if (false) host?.dispatchKeyEvent(key)", "Compose's keys reach a sheet's window"),
        ("a turning first instance admitted", COMPOSE, r"if \(selftestPending && !turning\) \{",
         "if (selftestPending) {", "a turning first instance admits no harness"),
        ("the pool's keyboard shows nothing", HELPER, r"override fun onEvaluateInputViewShown\(\): Boolean = true",
         "override fun onEvaluateInputViewShown(): Boolean = false", "the pool's keyboard shows"),
        ("the cutout left on after its leg", EMULATOR,
         r"finally:\n(\s+)if cutout and not cutout_overlay\(serial, cutout, False, log\):",
         r"finally:\n\1if False:", "the cutout overlay goes off"),
        ("the cutout overlay never read back", EMULATOR, r'if f"\{mark\} \{pkg\}" in listed:',
         "if True:", "the cutout overlay is read back"),
        ("the android lane trusting a landscape leg's device", EMULATOR, r"if pinned or serial in LANDSCAPE_RAN:",
         "if pinned:", "the android lane reads the display's rotation"),
        ("the cutout's bar left as SystemUI first laid it, as shipped", EMULATOR,
         r"return settle_status_bar\(serial, log, f\"cutout \{name\} \{'on' if on else 'off'\}\", on\)",
         "return True", "the cutout's change waits for SystemUI's bar"),
        ("the cutout turned off on a turned display", EMULATOR,
         r"if not on and not upright_for_cutout\(serial, log\):", "if False:",
         "the display is upright before the cutout goes"),
        ("no phone's bar read at lane start", EMULATOR,
         r"if serial != TABLET_SERIAL and not upright_bar_at_lane_start\(serial, sys\.stdout\):",
         "if False:", "the lane start reads each phone's own bar"),
        ("a phone's bar unread and the lane still green", EMULATOR,
         r"(overlay behind\)\"\)\n)    status = 1\n", r"\1", "a phone's bar unread refuses the lane's verdict"),
        ("the nudge's put back racing the scale it undoes", EMULATOR,
         r"if global_font_scale\(serial\) == float\(other\):\n\s+break", "break",
         "the nudge awaits its scale in the configuration"),
        ("a bar SystemUI never laid out again accepted", EMULATOR,
         r"(def wanted\(now, upright, rotation, cut\):\n\s+return rotation == 0 and \(cut > 0\) == on and )now == upright == ",
         r"\1upright == ", "the bar settles laid out and upright alike"),
    ]
    for label, rel, pattern, repl, want in cuts:
        broken = g.doctor(f"safearea: {label}", sources[rel], pattern, repl)
        g.negative(f"safearea: {label}", lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want=want)
    for rel in STUBBED:
        if STUBBED[rel] not in sources[rel]:
            continue
        n = sources[rel].count(STUBBED[rel])
        broken = g.doctor(f"safearea: {rel}'s stubs gone without a row", sources[rel],
                          re.escape(STUBBED[rel]), "todo!()", want=n)
        g.negative(f"safearea: {rel}'s stubs gone without a row",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want="has no row")
