"""docs/styling-pass-plan.md Y2-Y9, §3's WinUI row: the WinUI arm's doors,
loaded by tools/lib/skin_routes.py (run from tools/check-verbs.py).

A gradient whose bottom stop is a literal draws the same header on the lane's
light VM, a High Contrast arm that paints the album anyway is seen by no lane
(no lane runs High Contrast), an overlay drawn in kaya's own alpha reads as
overlay over the art, a hover painted by kaya passes the nearest-candidate
read, a tint applied inside a fill is invisible on a pale card, and a reader
that answers from what the app wrote agrees with every write."""

import re

from content_type_routes import flat
from reveal_routes import blocks

REL = "crates/kaya/src/winui/mod.rs"
SKIN = "crates/kaya/src/winui/skin.rs"
SOURCES = (REL, SKIN)
LABEL = "the WinUI arm"

# A reader may never answer from what the app wrote.
MODEL = r"shape_of\(|\.shapes\b|\.tints\b|\.selected\b|holds_widget\("
# (label, opener, what the block must hold, what it may never name)
DOORS = [
    ("gradient", "fn gradient_brush(dark: bool, packed: i64) -> windows_core::Result<Brush> {",
     ["if high_contrast() {", r'Color=\"{ThemeResource SystemColorWindowColor}\"',
      'let ground = rgb_of(resolve("ApplicationPageBackgroundThemeBrush", dark)?);',
      "packed & 0xFF_FFFF", "(packed >> 24) & 0xFF_FFFF", r'StartPoint=\"0,0\" EndPoint=\"0,1\"'],
     ["SolidColorBrush", "Colors::", "Color {"]),
    ("ground's paint", "fn paint_ground(core: &CoreState, id: WidgetId) -> windows_core::Result<()> {",
     ["gradient_brush(dark_of(core, Some(&fe)), packed)", "ImageBrush::new()",
      "brush.SetStretch(Stretch::UniformToFill)", "grid.ActualThemeChanged(",
      "images::on_ui(move |core| paint_ground(core, id));"],
     ["SolidColorBrush"]),
    ("image ground's bytes", "(Prop::Source, Value::Blob(blob)) if is_container => {",
     ["images::picture(core, bytes, move |core, picture| {", "if g.generation != generation {"],
     ["BitmapImage::new", "SetSourceAsync"]),
    ("overlay's arm", "(Prop::Filled, Value::I64(tint)) if is_container && *tint == i64::from(crate::wire::TINT_OVERLAY) => {",
     ["grid.SetStyle(&overlay_style()?)?;", "grid.SetRequestedTheme(ElementTheme::Dark)?;"], ["Opacity"]),
    ("overlay panel", "fn overlay_style() -> windows_core::Result<Style> {",
     ["{ThemeResource AcrylicInAppFillColorDefaultBrush}", "{ThemeResource OverlayCornerRadius}"],
     ["Opacity", "#"]),
    ("activatable host", "fn wrap(core: &mut CoreState, id: WidgetId) -> windows_core::Result<()> {",
     ["ItemContainer::new()", "AutomationProperties::SetAutomationControlType(&host, AutomationControlType::Button)?;",
      "inner.PointerPressed(", "inner.PointerReleased(", "host.PointerCaptureLost(",
      "if !armed.swap(false, std::sync::atomic::Ordering::Relaxed) || !pointer_inside(id) {",
      "press(&tapped_sink, id, &tapped_tag);", "host.PreviewKeyDown(",
      "if key == VirtualKey::Enter || key == VirtualKey::Space {", "press(&sink, id, &tag);",
      "reseat_element(core, id, &inner, &host.cast()?)?;", "host.SetChild(&frame)?;",
      "for key in ITEM_RING_KEYS {", "XamlReader::Load(&HSTRING::from(ITEM_FRAME_XAML))?", "paint_selected(id)?;\nstamp_container_padding(core, id)"],
     ["SetBackground", "PointerEntered", "PointerExited", "SolidColorBrush", "GoToState", "SetIsSelected(true)"]),
    # docs/styling-pass-plan.md Y4, AMENDED 2026-10-17: the pick, guarded, first.
    ("press door", "pub(super) fn press(sink: &OccSink, id: WidgetId, tag: &[u8]) {",
     ["restore_selected(id);\nif !SKIN.with_borrow(|s| s.selected.get(&id.0).copied().unwrap_or(false)) {\n"
      "sink.send_selection_changed_tag(tag);\n}\nsink.send_activated_tag(tag);"],
     []),
    ("item's corner and hit area", "fn round_host(core: &CoreState, id: WidgetId, host: &ItemContainer) -> windows_core::Result<()> {",
     ['theme_resource::<IReference<CornerRadius>>("OverlayCornerRadius")?.Value()?',
      'grid.SetBackground(&theme_resource::<Brush>("SubtleFillColorTransparentBrush")?)?;'],
     ["SolidColorBrush", "Colors::"]),
    ("selected surface", "fn paint_selected(id: WidgetId) -> windows_core::Result<()> {",
     ["children.GetAt(0)?.SetVisibility(vis(on))?;", "children.GetAt(2)?.SetVisibility(vis(on && !table))?;"],
     ["SolidColorBrush", "SetBackground"]),
    ("release inside", "fn pointer_inside(id: WidgetId) -> bool {",
     ["GetCursorPos(&mut at)", "widget_screen_rect(core, id.0)"], []),
    ("shaped picture", "pub(super) fn reshape(core: &mut CoreState, id: WidgetId) -> windows_core::Result<()> {",
     ["for look in images::looks(core, id) {\nlook.SetCornerRadius(radius)?;", "shaper.SetCornerRadius(radius)?;",
      "let brush = ImageBrush::new()?;", "brush.SetImageSource(&source)?;"], []),
    ("shape's corner", "fn corner(shape: i64, width: f64, height: f64) -> windows_core::Result<CornerRadius> {",
     ['theme_resource::<IReference<CornerRadius>>("OverlayCornerRadius")?.Value()?', "width.min(height) / 2.0"],
     ["8.0", "12.0", "4.0"]),
    ("standalone colours", "fn standalone_key(tint: i64) -> Option<&'static str> {",
     ['"AccentTextFillColorPrimaryBrush"', '"SystemFillColorSuccessBrush"', '"SystemFillColorCautionBrush"',
      '"SystemFillColorCriticalBrush"'], ["BackgroundBrush", "AccentFillColor"]),
    ("label's tint", "pub(super) fn paint_tint(core: &CoreState, id: WidgetId) -> windows_core::Result<()> {",
     ["let key = standalone_key(tint).filter(|_| !in_fill(core, id));",
      'Some(key) => block.SetStyle(&themed_foreground_style("TextBlock", role, key)?),'], ["SetForeground"]),
    ("dock", "pub(super) fn attach_dock(core: &mut CoreState, window: u64, dock: u64) -> windows_core::Result<()> {",
     ["{ThemeResource LayerFillColorDefaultBrush}", "Grid::SetRow(&host, 1)?;", "GridUnitType::Star",
      "window_ground(&winui_window(core, window)?)?"], ["SolidColorBrush"]),
    ("batch's end", "pub(super) fn sync(core: &CoreState) -> windows_core::Result<()> {",
     ["let shown = root.is_some_and(|r| holds_widget(core, r));", "spoken(core, WidgetId(id), &mut words);"], []),
    ("hover", "fn hover(&self, t: crate::harness::Target) {",
     ['Self::foreground_guest("hover");', "SetCursorPos(px, py);", "mouse_event("], []),
]
# (label, opener, what the block must hold) -- and never MODEL
READS = [
    ("expect_ground's reader", "pub(in super::super) fn ground(core: &CoreState, t: crate::harness::Target)",
     ["Shot::take(core)", "let ratio = contrast(mid, shot.text);", "&& ratio >= 4.5", "gap(bottom, shot.ground) <= TOLERANCE",
      "picture_at(id, fw - 4.0, 4.0, fw, fh)"]),
    ("expect_shape's reader", "pub(in super::super) fn shape(core: &CoreState, t: crate::harness::Target)",
     ["Shot::take(core)", "shot.at(fx - 4.0, fy + fh / 2.0)", "shot.at(fx + 1.0, fy + 1.0)", "shot.at(fx + 6.0, fy + 6.0)"]),
    ("expect_tint's reader", "pub(in super::super) fn tint(core: &CoreState, t: crate::harness::Target)",
     ["Shot::take(core)", 'vec![("none", shot.text)]', "standalone_key(i64::from(tint))"]),
    ("expect_selected's reader", "pub(in super::super) fn selected(core: &CoreState, t: crate::harness::Target)",
     ["FrameworkElementAutomationPeer::CreatePeerForElement(&fe)?", "peer.cast::<ISelectionItemProvider>()",
      "item.IsSelected()?"]),
    ("expect_dock's reader", "pub(in super::super) fn dock(core: &CoreState) -> windows_core::Result<String> {",
     ["if !is_dock_host(&child) {", "spans && at_foot && above",
      "if let Some(fault) = dock_content_fault(core, &ground_el, y)? {"]),
    ("expect_dock's content half",
     "fn dock_content_fault(core: &CoreState, ground: &UIElement, dock_top: f64) -> windows_core::Result<Option<String>> {",
     ["core.mounted_roots.get(&0)", ".TransformToVisual(ground)", "if w < 1.0 || h < 1.0 {",
      "if top + h > dock_top + 1.0 {"]),
    ("expect_fill's skin readings", "fn fill_tint(&self, t: crate::harness::Target) -> String {",
     ['layered("ItemContainerPointerOverBackground", bare)?', 'layered("ItemContainerPointerOverBackground", card)?',
      "own < 0.06 && own < theirs / 2.0", "skin::read::picture_at(pictured,",
      'resolve("ListViewItemSelectionIndicatorBrush")?', 'layered("ListViewItemBackgroundSelected", bare)?',
      "let pilled = is_pill(fx + 1.5, fy + fh / 2.0)\n&& !is_pill(fx + 1.5, fy + 1.5)\n&& !is_pill(fx + fw - 1.5, fy + fh / 2.0);",
      "let marked = pilled || id.is_some_and(|id| skin::is_table_row(id.0));",
      "let filled = skin::read::gap(sample, fill) < skin::read::gap(sample, ground);", "if marked && filled {"]),
]
CALLS = [
    ("a parent lays out an activatable container's host", "let inner = skin::host_of(&inner).unwrap_or(inner);"),
    ("the skin's props reach the arm", "if skin::set_prop(core, id, prop, &value)? {\nreturn Ok(());"),
    ("attach_dock reaches the arm", "ApplyOp::AttachDock { window, dock } => skin::attach_dock(core, window.0, dock.0)?,"),
    ("a dock is a mount target", "} else if skin::is_dock(window.0) {\nskin::mount_dock(core, window.0, root, &element)?;"),
    ("a window's new content keeps its dock", "children.Append(element)?;\nskin::keep_dock(core, window)"),
    ("the batch's end syncs the skin", "images::serve_requested(core)?;\nskin::sync(core)"),
    ("a destroyed widget leaves the skin", "skin::forget(core, id);"),
    ("an activatable container takes the filled inset",
     "if core.filled.contains_key(&id) || skin::is_activatable(id) && !in_declared_table(core, id) {\nFILLED_DEFAULT_INSET"),
    ("the caption follows the content's theme", "follow_caption(core, mode == crate::canvas::Mode::Dark);"),
    ("expect_appearance reads the caption back from DWM",
     "if (caption != 0) != dark {\nreturn Ok(format!(\"mixed (content {mode} {source}, the caption {})\""),
    ("a row reaching its parent restamps its inset",
     "if skin::is_activatable(child) {\nstamp_container_padding(core, child)?;\nskin::seat_in_table(child, in_declared_table(core, child))?;"),
    ("expect_ax reads the host", "let element = skin::ax_element(&element);"),
    ("a click reaches an activatable container", "match skin::activation_tag(core, WidgetId(id)) {\nSome(tag) => skin::press(&core.occurrences, WidgetId(id), &tag),"),
    ("a shaped image hides its Image behind its picture",
     "image.SetOpacity(if failed || super::skin::shaped(id) { 0.0 } else { 1.0 })"),
    ("a shaped image's picture is reshaped when it lands",
     "if super::skin::shaped(id) {\nreturn super::skin::reshape(core, id);"),
    ("the ground's art shares the images' cache", "if let Some(hit) = PICTURES.with_borrow_mut(|cache| cache.get(key)) {\nreturn then(core, Some(hit));"),
]
# Both looks take the shape (the loading and the failed one).
LOOK_CORNER = "look.SetCornerRadius(super::skin::look_corner(id, arm.width, arm.height)?)?;"
# A raw colour in the gradient: a `#FF` followed by hex digits rather than the
# data colour's `{top:06X}`.
RAW = re.compile(r"#FF[0-9A-Fa-f]{6}")


def code(text):
    """The text with every `//` comment cut (not a URL's), so prose naming a
    call is not one."""
    return "\n".join(re.sub(r"(?<!:)//.*", "", line) for line in text.splitlines())


def findings(text):
    out = []
    src = code(text)
    for label, opener, needs, never in DOORS:
        found = blocks(src, opener)
        if len(found) != 1:
            out.append(f"skin: {LABEL}'s {label} is defined {len(found)} times, wanted once ({opener!r})")
            continue
        body = flat(found[0])
        for need in needs:
            if flat(need) not in body:
                out.append(f"skin: {LABEL}'s {label} lacks {need.splitlines()[0][:90]}")
        for name in never:
            if name in found[0]:
                out.append(f"skin: {LABEL}'s {label} names {name}, kaya's own where the platform has a token")
        if label == "gradient" and RAW.search(found[0]):
            out.append(f"skin: {LABEL}'s gradient carries a raw colour {RAW.search(found[0]).group(0)}, "
                       f"a stop that is neither the data colour nor a token")
    for label, opener, needs in READS:
        found = blocks(src, opener)
        if len(found) != 1:
            out.append(f"skin: {LABEL}'s {label} is defined {len(found)} times, wanted once ({opener!r})")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"skin: {LABEL}'s {label} lacks {need}")
        if re.search(MODEL, found[0]):
            out.append(f"skin: {LABEL}'s {label} reaches kaya's model, so it could answer from what the app "
                       f"wrote instead of what the arm drew")
    for label, call in CALLS:
        if flat(call) not in flat(src):
            out.append(f"skin: {LABEL}: {label} no longer holds — lacks {call.splitlines()[0]}")
    for call in ("send_activated_tag(", "send_selection_changed_tag("):
        sites = src.count(call)
        if sites != 1:
            out.append(f"skin: {LABEL}: {call[:-1]} is sent from {sites} sites, wanted one, the press door's "
                       f"(docs/styling-pass-plan.md Y4)")
    looks = flat(src).count(flat(LOOK_CORNER))
    if looks != 2:
        out.append(f"skin: {LABEL}'s looks take the shape {looks} times, wanted 2 (loading and failed)")
    return out


CUTS = [
    ("WinUI: the gradient's bottom stop a literal",
     r'let ground = rgb_of\(resolve\("ApplicationPageBackgroundThemeBrush", dark\)\?\);', "let ground = 0x202020u32;",
     "gradient lacks let ground"),
    ("WinUI: the album painted in High Contrast", r"if high_contrast\(\) \{", "if false {", "gradient lacks if high_contrast"),
    ("WinUI: a SolidColorBrush in the gradient",
     r"(fn gradient_brush\(dark: bool, packed: i64\) -> windows_core::Result<Brush> \{\n)",
     r"\1    let _ = SolidColorBrush::new();\n", "gradient names SolidColorBrush"),
    ("WinUI: a raw bottom stop", r'Color=\\"#FF\{ground:06X\}\\"', r'Color=\\"#FF202020\\"', "raw colour #FF202020"),
    ("WinUI: the overlay in kaya's alpha", r"\{ThemeResource AcrylicInAppFillColorDefaultBrush\}", "#99000000",
     "overlay panel lacks {ThemeResource AcrylicInAppFillColorDefaultBrush}"),
    ("WinUI: the overlay's text left light-themed", r"\n(\s+)grid\.SetRequestedTheme\(ElementTheme::Dark\)\?;", "",
     "overlay's arm lacks grid.SetRequestedTheme"),
    ("WinUI: kaya paints the hover", r"(let host = ItemContainer::new\(\)\?;\n)",
     r"\1    host.SetBackground(None::<&Brush>)?;\n", "activatable host names SetBackground"),
    ("WinUI: an activatable container no button to UIA",
     r"\n(\s+)AutomationProperties::SetAutomationControlType\(&host, AutomationControlType::Button\)\?;", "",
     "activatable host lacks AutomationProperties::SetAutomationControlType"),
    ("WinUI: a tap that activates nothing", r"press\(&tapped_sink, id, &tapped_tag\);", "let _ = &tapped_tag;",
     "activatable host lacks press(&tapped_sink"),
    ("WinUI: a press that keeps the item's own selection", r"(pub\(super\) fn press\(sink: &OccSink, id: WidgetId, tag: &\[u8\]\) \{\n)\s+restore_selected\(id\);\n",
     r"\1", "press door lacks restore_selected(id);"),
    ("WinUI: the pick sent over the app's selection",
     r"if !SKIN\.with_borrow\(\|s\| s\.selected\.get\(&id\.0\)\.copied\(\)\.unwrap_or\(false\)\) \{\n(\s+)sink\.send_selection_changed_tag\(tag\);\n\s+\}",
     r"sink.send_selection_changed_tag(tag);", "press door lacks restore_selected(id);"),
    ("WinUI: the pick sent after the activation",
     r"(\s+)if !SKIN(.*)\n(\s+)sink\.send_selection_changed_tag\(tag\);\n(\s+)\}\n\s+sink\.send_activated_tag\(tag\);",
     r"\1sink.send_activated_tag(tag);\1if !SKIN\2\n\3sink.send_selection_changed_tag(tag);\n\4}",
     "press door lacks restore_selected(id);"),
    ("WinUI: a press beside the door", r"\n(\s+)press\(&sink, id, &tag\);", r"\n\1sink.send_activated_tag(&tag);",
     "send_activated_tag is sent from 2 sites"),
    ("WinUI: the shaped picture left square", r"\n(\s+)shaper\.SetCornerRadius\(radius\)\?;", "",
     "shaped picture lacks shaper.SetCornerRadius"),
    ("WinUI: the loading look left square",
     r"look\.SetCornerRadius\(super::skin::look_corner\(id, arm\.width, arm\.height\)\?\)\?;\n(\s+)host\.Children\(\)\?\.Append\(&look\)\?;\n(\s+)arm\.loading",
     r"host.Children()?.Append(&look)?;\n\2arm.loading", "looks take the shape 1 times"),
    ("WinUI: kaya's own radius",
     r'(SHAPE_ROUNDED \{\n\s+)theme_resource::<IReference<CornerRadius>>\("OverlayCornerRadius"\)\?\.Value\(\)\?',
     r"\1CornerRadius { TopLeft: 8.0, TopRight: 8.0, BottomRight: 8.0, BottomLeft: 8.0 }", "shape's corner names 8.0"),
    ("WinUI: a tint inside a fill", r"\.filter\(\|_\| !in_fill\(core, id\)\)", "", "label's tint lacks let key"),
    ("WinUI: the tint the fill's colour", r'"AccentTextFillColorPrimaryBrush"', '"AccentFillColorDefaultBrush"',
     'standalone colours lacks "AccentTextFillColorPrimaryBrush"'),
    ("WinUI: expect_dock blind to the content", r"if let Some\(fault\) = dock_content_fault\(core, &ground_el, y\)\? \{",
     "if let Some(fault) = None::<String> {", "expect_dock's reader lacks if let Some(fault)"),
    ("WinUI: expect_dock's content half blind to the dock's top", r"if top \+ h > dock_top \+ 1\.0 \{",
     "if false {", "expect_dock's content half lacks if top"),
    ("WinUI: the dock inside the content", r"\n(\s+)Grid::SetRow\(&host, 1\)\?;", "", "dock lacks Grid::SetRow"),
    ("WinUI: a dock that never collapses", r"root\.is_some_and\(\|r\| holds_widget\(core, r\)\)", "root.is_some()",
     "batch's end lacks let shown"),
    ("WinUI: the shape read off the prop",
     r"(pub\(in super::super\) fn shape\(core: &CoreState, t: crate::harness::Target\) -> windows_core::Result<String> \{\n)",
     r'\1        if shape_of(WidgetId(0)) == 2 { return Ok("circle".into()); }\n', "expect_shape's reader reaches"),
    ("WinUI: the tint read off the prop",
     r"(pub\(in super::super\) fn tint\(core: &CoreState, t: crate::harness::Target\) -> windows_core::Result<String> \{\n)",
     r"\1        let _ = SKIN.with_borrow(|s| s.tints.len());\n", "expect_tint's reader reaches"),
    ("WinUI: selected read off the prop",
     r"(pub\(in super::super\) fn selected\(core: &CoreState, t: crate::harness::Target\) -> windows_core::Result<String> \{\n)",
     r"\1        let _ = SKIN.with_borrow(|s| s.selected.len());\n", "expect_selected's reader reaches"),
    ("WinUI: the dock read off the tree's model",
     r"(pub\(in super::super\) fn dock\(core: &CoreState\) -> windows_core::Result<String> \{\n)",
     r"\1        let _ = holds_widget(core, WidgetId(0));\n", "expect_dock's reader reaches"),
    ("WinUI: the gradient's contrast unread", r"&& ratio >= 4\.5", "", "expect_ground's reader lacks && ratio >= 4.5"),
    ("WinUI: the overlay rule gone", r"own < 0\.06 && own < theirs / 2\.0", "true",
     "expect_fill's skin readings lacks own < 0.06"),
    ("WinUI: the caption left to the system's mode", r"\n(\s+)follow_caption\(core, mode == crate::canvas::Mode::Dark\);", "",
     "the caption follows the content's theme"),
    ("WinUI: expect_appearance blind to the caption", r"if \(caption != 0\) != dark \{", "if false {",
     "expect_appearance reads the caption back"),
    ("WinUI: the selection read without its pill",
     r"let marked = pilled \|\| ", "let marked = true || ",
     "expect_fill's skin readings lacks let marked"),
    ("WinUI: ItemContainer's ring read as the pill", r"\n(\s+)&& !is_pill\(fx \+ fw - 1\.5, fy \+ fh / 2\.0\);", ";",
     "expect_fill's skin readings lacks let pilled"),
    ("WinUI: the bare ground read as the selected fill",
     r"skin::read::gap\(sample, fill\) < skin::read::gap\(sample, ground\)", "skin::read::gap(sample, fill) <= 0.06",
     "expect_fill's skin readings lacks let filled"),
    ("WinUI: the selection left as ItemContainer's ring", r"\n(\s+)for key in ITEM_RING_KEYS \{", "\n\\1for key in [] as [&str; 0] {",
     "activatable host lacks for key in ITEM_RING_KEYS"),
    ("WinUI: the pill never shown", r"SetVisibility\(vis\(on && !table\)\)", "SetVisibility(vis(false))",
     "selected surface lacks children.GetAt(2)"),
    ("WinUI: an activatable container flush against its surface",
     r"core\.filled\.contains_key\(&id\) \|\| skin::is_activatable\(id\) && !in_declared_table\(core, id\)", "core.filled.contains_key(&id)",
     "an activatable container takes the filled inset"),
    ("WinUI: a release outside the item taken as a click",
     r"\|\| !pointer_inside\(id\)", "", "activatable host lacks if !armed.swap"),
    ("WinUI: the unfilled child's box left to the item",
     r'\n(\s+)grid\.SetBackground\(&theme_resource::<Brush>\("SubtleFillColorTransparentBrush"\)\?\)\?;', "",
     "item's corner and hit area lacks grid.SetBackground"),
    ("WinUI: kaya keeps the item's own selection",
     r"(fn wrap\(core: &mut CoreState, id: WidgetId\) -> windows_core::Result<\(\)> \{\n)",
     r"\1    let _ = |h: &ItemContainer| h.SetIsSelected(true);\n", "activatable host names SetIsSelected(true)"),
    ("WinUI: hover without the real pointer", r"\n(\s+)SetCursorPos\(px, py\);", "", "hover lacks SetCursorPos"),
    ("WinUI: the host left out of the layout", r"let inner = skin::host_of\(&inner\)\.unwrap_or\(inner\);", "",
     "a parent lays out an activatable container's host"),
    ("WinUI: the skin's props never reach the arm", r"if skin::set_prop\(core, id, prop, &value\)\? \{", "if false {",
     "the skin's props reach the arm"),
    ("WinUI: the ground's art decoded apart from the images' cache", r"images::picture\(core, bytes, move",
     "images::picture_fresh(core, bytes, move", "image ground's bytes lacks images::picture"),
]
