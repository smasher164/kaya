"""docs/network-images-plan.md N4, N5, N9, N10, N13-N15: the WinUI arm's doors,
loaded by tools/lib/netimage_routes.py (run from tools/check-verbs.py).

A decode moved back onto the UI thread draws the same pictures, a late result
installed without its generation passes every scene that never races two
sources, a cache keyed off the content passes until two albums collide, a
failed decode that leaves the previous picture up passes every scene whose
bad bytes land on a fresh image (N14), a band move whose image_needed waits
for the next transaction passes every scene that clicks after scrolling, and
a phase read off the prop agrees with every write."""

import re

from content_type_routes import flat
from reveal_routes import blocks

REL = "crates/kaya/src/winui/mod.rs"
LABEL = "the WinUI arm"

# (label, opener, what the block must hold, what it may never name)
DOORS = [
    ("source arm", "(Prop::Source, Value::Blob(blob)) => {",
     ["arm.content = crate::content_id::of(&blob.0);", "request(core, id);"],
     ["SetSource", "BitmapImage::new", "StoreAsync"]),
    ("off-main door", "fn serve(core: &mut CoreState, id: WidgetId) -> windows_core::Result<()> {",
     ["arm.generation += 1;", "let key = (arm.content, target.map_or(0, |(_, long)| long));",
      "if let Some(hit) = PICTURES.with_borrow_mut(|cache| cache.get(key)) {",
      "return install(core, id, Some(hit), false);", "written(bytes, move |stream| {"],
     ["StoreAsync", "SetSource"]),
    ("stream writer", "fn written(",
     ["std::thread::spawn(move || {", "writer.StoreAsync()?.join()?;"], []),
    ("decode", "fn decode(\n",
     ["if core.image_arms.get(&id).is_none_or(|arm| arm.generation != generation) {",
      "Some((true, long)) => bitmap.SetDecodePixelWidth(long as i32)?,",
      "Some((false, long)) => bitmap.SetDecodePixelHeight(long as i32)?,",
      "on_ui(move |core| opened(core, id, generation, &bitmap, key));",
      "bitmap.ImageFailed(&ExceptionRoutedEventHandler::new(move |_, _| {\n on_ui(move |core| failed(core, id, generation));",
      "bitmap.SetSourceAsync(stream)?.when(move |done| {\n if done.is_err() {\n on_ui(move |core| failed(core, id, generation));",
      "arm.decoding = Some(bitmap);"],
     [".SetSource("]),
    ("opened picture", "fn opened(",
     ["if core.image_arms.get(&id).is_none_or(|arm| arm.generation != generation) {",
      "PICTURES.with_borrow_mut(|cache| cache.put(key, bitmap.clone(), cost));",
      "install(core, id, Some(bitmap.clone()), false)"], []),
    ("failed decode (N14)", "fn failed(core: &mut CoreState, id: WidgetId, generation: u64)",
     ["if core.image_arms.get(&id).is_none_or(|arm| arm.generation != generation) {",
      "install(core, id, None, true)"], []),
    ("install", "fn install(",
     ["Some(bitmap) => image.SetSource(bitmap)?,", "None => image.SetSource(None::<&ImageSource>)?,",
      "arm.undecodable = undecodable;", "arm.picture = picture;"], []),
    ("look decision", "fn refresh_look(",
     ["arm.phase == crate::wire::IMAGE_PHASE_FAILED || (arm.picture.is_none() && arm.undecodable)",
      "&& arm.picture.is_none()\n && (arm.phase == crate::wire::IMAGE_PHASE_LOADING || arm.pending);",
      "glyph.SetGlyph(&windows_core::HSTRING::from(missing_glyph()))?;",
      'glyph.SetForeground(&theme_resource::<Brush>("TextFillColorSecondaryBrush")?)?;',
      "AutomationProperties::SetAccessibilityView(&glyph, AccessibilityView::Raw)?;",
      "glyph.SetVisibility(shown(arm.width.min(arm.height) >= 2.0 * GLYPH))?;",
      "image.SetOpacity(if failed { 0.0 } else { 1.0 })"],
     ["SolidColorBrush", "Color {"]),
    ("look's fill", "fn look(width: f64, height: f64)",
     ['look.SetBackground(&theme_resource::<Brush>("ControlFillColorSecondaryBrush")?)?;',
      "AutomationProperties::SetAccessibilityView(&look, AccessibilityView::Raw)?;"],
     ["SolidColorBrush", "Color {"]),
    ("decoded cache", "impl Pictures {",
     ["2 * screen * 4", "if key.0 == 0 {\n return None;", "while self.cost > budget && self.entries.len() > 1 {",
      "self.entries.clear();"], []),
    ("memory watch", "fn watch_memory() {",
     ["CreateMemoryResourceNotification(LowMemoryResourceNotification)",
      "PICTURES.with_borrow_mut(Pictures::empty);"], ["MemoryManager"]),
    ("band report", "fn table_band_to(",
     ["core.scene.window_moved(id, visible.0, visible.1)",
      "for occ in core.scene.take_asks() {\n core.occurrences.send(occ);"], []),
]
READS = [
    ("expect_image_phase's reader", "pub(super) fn phase_drawn(",
     ["e.Visibility()? == Visibility::Visible && e.ActualWidth()? > 0.0", "children.GetAt(i)?.cast::<Border>()",
      "look.Child()", "return Ok(\"failed without its glyph\".into());", "bitmap.PixelWidth().unwrap_or(0) > 0"]),
    ("expect_image_phase on WinUI", "fn image_phase(&self, t: crate::harness::Target) -> String {",
     ["images::phase_drawn(core, &core.images[i])"]),
]
MODEL = r"image_arms|ImageArm|\barm\.|IMAGE_PHASE_"
CALLS = [
    ("the image's props reach its arm first", "if images::set_prop(core, id, prop, &value)? {\n return Ok(());"),
    ("every batch serves its pictures", "refresh_bleeds(core)?;\n images::serve_requested(core)"),
    ("a torn-down image forgets its decode", "let widget = core.widgets.remove(&id).expect(\"scene validated the id\");\n images::forget(core, id);"),
    ("the Image keeps the accessible identity", "NativeWidget::Image { image, .. } => image.cast(),"),
    ("the failed glyph's one spelling", 'S::ImageMissing => FluentIcon::Glyph("\\u{E91B}"),'),
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
            out.append(f"netimage: {LABEL}'s {label} is defined {len(found)} times in {REL}, wanted once ({opener!r})")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"netimage: {LABEL}'s {label} lacks {need.splitlines()[0][:80]} — a decode on the UI "
                           f"thread, a late picture installed, an old picture left up, a cache that could paint "
                           f"the wrong bytes, or a look the user would not see")
        for name in never:
            if name in found[0]:
                out.append(f"netimage: {LABEL}'s {label} names {name}")
    asyncs = len(re.findall(r"\.SetSourceAsync\(", src))
    in_door = sum(len(re.findall(r"\.SetSourceAsync\(", b)) for b in blocks(src, "fn decode(\n"))
    syncs = len(re.findall(r"\.SetSource\(&stream\)", src))
    in_mark = sum(len(re.findall(r"\.SetSource\(&stream\)", b)) for b in blocks(src, "fn caption_mark_bitmap("))
    if asyncs != 1 or in_door != 1 or syncs != in_mark:
        out.append(f"netimage: {LABEL} decodes outside its door — SetSourceAsync appears {asyncs} times "
                   f"({in_door} in decode), the synchronous SetSource {syncs} times ({in_mark} in the caption mark)")
    for label, opener, needs in READS:
        found = blocks(src, opener)
        if len(found) != 1:
            out.append(f"netimage: {LABEL}'s {label} is gone — {REL} lacks {opener}")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"netimage: {LABEL}'s {label} lacks {need}")
        if re.search(MODEL, found[0]):
            out.append(f"netimage: {LABEL}'s {label} reaches the image's state, so it could answer from what "
                       f"the app wrote instead of what the arm drew")
    for label, call in CALLS:
        if flat(call) not in flat(src):
            out.append(f"netimage: {LABEL}: {label} no longer holds — {REL} lacks {call.splitlines()[0]}")
    return out


CUTS = [
    ("WinUI: the decode back in the source arm",
     r"arm\.bytes = Some\(blob\.0\.clone\(\)\);\n(\s+)request\(core, id\);",
     r"arm.bytes = Some(blob.0.clone());\n\1let _ = BitmapImage::new();\n\1request(core, id);",
     "source arm names BitmapImage::new"),
    ("WinUI: the synchronous SetSource back",
     r"bitmap\.SetSourceAsync\(stream\)\?\.when",
     "bitmap.SetSource(stream)?; bitmap.SetSourceAsync(stream)?.when",
     "decode names .SetSource("),
    ("WinUI: a late picture installed",
     r"(fn opened\(.*?\n)(\s+)if core\.image_arms\.get\(&id\)\.is_none_or\(\|arm\| arm\.generation != generation\) \{",
     r"\1\2if false {", "opened picture lacks if core.image_arms"),
    ("WinUI: the generation never moved", r"\n(\s+)arm\.generation \+= 1;\n", "\n",
     "off-main door lacks arm.generation += 1;"),
    ("WinUI: the old picture left up on a failed decode (N14)",
     r"None => image\.SetSource\(None::<&ImageSource>\)\?,", "None => {}",
     "install lacks None => image.SetSource"),
    ("WinUI: ImageFailed unheard",
     r"bitmap\.ImageFailed\(&ExceptionRoutedEventHandler::new\(move \|_, _\| \{\n(\s+)on_ui\(move \|core\| failed\(core, id, generation\)\);",
     r"bitmap.ImageFailed(&ExceptionRoutedEventHandler::new(move |_, _| {\n\1let _ = generation;",
     "decode lacks bitmap.ImageFailed"),
    ("WinUI: the decode at full size",
     r"Some\(\(true, long\)\) => bitmap\.SetDecodePixelWidth\(long as i32\)\?,",
     "Some((true, _)) => {}", "decode lacks Some((true, long))"),
    ("WinUI: the cache keyed off the content",
     r"let key = \(arm\.content, target", "let key = (0, target", "off-main door lacks let key"),
    ("WinUI: the cache kept under pressure",
     r"PICTURES\.with_borrow_mut\(Pictures::empty\);", "let _ = Pictures::empty;", "memory watch lacks PICTURES"),
    ("WinUI: the decoding picture dropped", r"\n(\s+)arm\.decoding = Some\(bitmap\);\n", "\n",
     "decode lacks arm.decoding = Some(bitmap);"),
    ("WinUI: undecodable bytes drawn empty",
     r"arm\.phase == crate::wire::IMAGE_PHASE_FAILED \|\| \(arm\.picture\.is_none\(\) && arm\.undecodable\)",
     "arm.phase == crate::wire::IMAGE_PHASE_FAILED", "look decision lacks arm.phase =="),
    ("WinUI: the failed look without its glyph",
     r"glyph\.SetGlyph\(&windows_core::HSTRING::from\(missing_glyph\(\)\)\)\?;", "",
     "look decision lacks glyph.SetGlyph"),
    ("WinUI: a literal fill",
     r'look\.SetBackground\(&theme_resource::<Brush>\("ControlFillColorSecondaryBrush"\)\?\)\?;',
     "look.SetBackground(&SolidColorBrush::new()?)?;", "look's fill lacks look.SetBackground"),
    ("WinUI: a look announced", r"AutomationProperties::SetAccessibilityView\(&look, AccessibilityView::Raw\)\?;",
     "", "look's fill lacks AutomationProperties"),
    ("WinUI: the phase read off the prop",
     r"(pub\(super\) fn phase_drawn\(core: &CoreState, image: &Image\) -> windows_core::Result<String> \{\n)",
     r'\1        if core.image_arms.values().any(|arm| arm.phase == 1) { return Ok("loading".into()); }\n',
     "reaches the image's state"),
    ("WinUI: a band move's asks left queued",
     r"(transaction\.\n)\s+for occ in core\.scene\.take_asks\(\) \{\n\s+core\.occurrences\.send\(occ\);\n\s+\}\n",
     r"\1", "band report lacks for occ"),
]
