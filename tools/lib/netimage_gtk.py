"""docs/network-images-plan.md N4, N5, N9, N10, N13, N15: the GTK arm's doors,
loaded by tools/lib/netimage_routes.py (run from tools/check-verbs.py).

A decode moved back into the apply arm draws the same pictures, a late result
installed without its generation passes every scene that never races two
sources, a cache keyed off the content passes until two albums collide, busy
left on a loaded image or set on a label-less one is read by no shared scene
(only GTK and WinUI have a busy state), and a phase read off the prop agrees
with every write."""

import re

from content_type_routes import flat
from reveal_routes import blocks

REL = "crates/kaya/src/gtk.rs"
LABEL = "the GTK arm"

# (label, opener, what the block must hold, what it may never name)
DOORS = [
    ("the off-main door", "fn image_source(picture: &gtk4::Picture, bytes: &std::sync::Arc<[u8]>) {",
     ["s.generation += 1;", "let id = crate::content_id::of(bytes);",
      "if let Some(hit) = picture_cache::get(picture_cache::Key { id, pixels: FULL_DECODE }) {",
      "let encoded = glib::Bytes::from_owned(bytes.clone());",
      "gio::spawn_blocking(move || gtk4::gdk::Texture::from_bytes(&encoded).ok())",
      "let Some(picture) = weak.upgrade() else { return };",
      "if with_image(&picture, |s| s.generation) != generation {\n return;\n }",
      "picture_cache::put(picture_cache::Key { id, pixels: FULL_DECODE }, texture.clone());"], []),
    ("the decoded cache", "mod picture_cache {",
     ["pub id: u64,", "pub pixels: u32,", "let monitor = gio::MemoryMonitor::dup_default();",
      "monitor.connect_low_memory_warning(|_, _| empty());", "while c.cost > budget && c.entries.len() > 1 {",
      "2 * (if screen > 0 { screen } else {", "c.entries.clear();"], []),
    ("the look decision", "fn render_image(picture: &gtk4::Picture) {",
     ["picture.update_state(&[gtk4::accessible::State::Busy(\n labelled && phase == crate::wire::IMAGE_PHASE_LOADING,",
      "let look = if phase == crate::wire::IMAGE_PHASE_FAILED || (texture.is_none() && undecodable) {",
      "BoundedPaintable::boxed(&texture, bw, bh, fit, rtl)",
      "} else if phase == crate::wire::IMAGE_PHASE_LOADING || pending {",
      ".then(|| image_missing_icon(picture))", "bw.min(bh) >= 2 * IMAGE_GLYPH"],
     ["Texture::from_bytes"]),
    ("the failed glyph", "fn image_missing_icon(picture: &gtk4::Picture) -> Option<gtk4::IconPaintable> {",
     ["symbol_icon_name(i64::from(crate::wire::SYMBOL_IMAGE_MISSING))?", "IMAGE_GLYPH,"], ['"image-missing']),
    ("the looks", "mod image_look {",
     ["let ink = widget.color();", "ink.alpha() * super::IMAGE_FILL_ALPHA", "ink.alpha() * super::IMAGE_DIM_ALPHA",
      "glyph.snapshot_symbolic("], ["RGBA::parse", "lookup_color"]),
]
# The harness reads what the arm drew, never the image's state.
READS = [
    ("expect_image_phase's reader", "fn image_drawn_phase(picture: &gtk4::Picture) -> String {",
     ["picture.paintable()", "downcast::<image_look::ImageLook>()", "look.has_glyph()"]),
    ("expect_image_phase on GTK", "fn image_phase(&self, t: crate::harness::Target) -> String {",
     ["image_drawn_phase(&core.images[i])"]),
]
MODEL = r"with_image|ImageState|\bs\.phase\b|IMAGE_PHASE_"
CALLS = [
    ("the source arm hands its bytes to the door",
     "(NativeWidget::Image(picture), Prop::Source, Value::Blob(blob)) => image_source(picture, &blob.0),"),
    ("the phase re-decides the look",
     "(NativeWidget::Image(picture), Prop::Phase, Value::I64(phase)) => {\n with_image(picture, |s| s.phase = phase);\n render_image(picture);"),
    ("fit re-decides the look",
     "(NativeWidget::Image(picture), Prop::Fit, Value::I64(fit)) => {\n with_image(picture, |s| s.fit = Some(fit));\n render_image(picture);"),
    ("a label makes a loading image busy",
     "if let NativeWidget::Image(picture) = w {\n with_image(picture, |s| s.labelled = true);\n render_image(picture);"),
    ("the failed glyph's one spelling", '(crate::wire::SYMBOL_IMAGE_MISSING, "image-missing-symbolic"),'),
    ("a band report's asks are sent",
     "table.reported = Some((first, count));\n }\n for op in ops.unwrap_or_default() {\n apply(core, op);\n }\n send_asks(core);"),
    ("a doorbell rung under a borrowed CORE waits for it (the asks above reach the guest inside "
     "park_table_row's nested main-loop turn)",
     "glib::idle_add(|| {\n drain_when_free();\n glib::ControlFlow::Break"),
    ("the doorbell's wait re-arms instead of borrowing",
     "if CORE.with(|slot| slot.try_borrow_mut().is_err()) {\n glib::timeout_add_local_once("
     "std::time::Duration::from_millis(10), drain_when_free);\n return;"),
    ("the failed glyph at GTK's large icon size (N4, 2026-10-13: the 16px glyph read faint beside the other "
     "platforms')", "const IMAGE_GLYPH: i32 = 32;"),
    ("the failed glyph dimmed as AdwStatusPage dims its icon", "const IMAGE_DIM_ALPHA: f32 = 0.55;"),
    ("a band is read only from rows that have their allocation (docs/traps.md, the GTK band read from "
     "unallocated rows)", "let laid_out = !rows.is_empty() && rows.iter().all(|(_, height)| *height > 0.0);"),
    ("a band read that found unallocated rows reads again after the frame that allocates them",
     "if !rows.is_empty() && !laid_out {\n report_after_layout(&body, &pending, &awaiting_layout, id);"),
    ("an unboxed image takes its header's size while it decodes (N9's 2026-10-13 amendment: an unboxed image laid out at 0x0 until its pixels land moves everything after it)",
     "s.pending = true;\n s.pending_natural = crate::image_header::natural(bytes);"),
    ("the reserved size is laid out", "(None, Some(natural)) => reserve_natural(picture, natural),"),
    ("a decoded picture ends the reserved size", "s.pending = false;\n s.pending_natural = None;"),
    ("a parked row's asks are sent",
     "table.reported = Some((index, count));\n }\n for op in ops.unwrap_or_default() {\n apply(core, op);\n }\n send_asks(core);"),
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
            out.append(f"netimage: {LABEL}'s {label} is defined {len(found)} times in {REL}, wanted once ({opener})")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"netimage: {LABEL}'s {label} lacks {need.splitlines()[0][:80]} — a decode on the main "
                           f"thread, a late picture installed, a cache that could paint the wrong bytes, or a look "
                           f"the user would not see")
        for name in never:
            if name in found[0]:
                out.append(f"netimage: {LABEL}'s {label} names {name}")
    decodes = len(re.findall(r"Texture::from_bytes\(", src))
    held = sum(len(re.findall(r"Texture::from_bytes\(", b))
               for opener in ("fn identity_texture(", "fn image_source(") for b in blocks(src, opener))
    if decodes != 2 or held != 2:
        out.append(f"netimage: {LABEL} decodes outside its door — Texture::from_bytes appears {decodes} times, "
                   f"{held} of them in identity_texture and image_source")
    spelled = len(re.findall(r'"image-missing', src))
    if spelled != 1:
        out.append(f"netimage: {LABEL} spells the failed glyph {spelled} times, wanted only SYMBOL_ICONS' row — "
                   f"a second spelling of the failed glyph")
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
    ("GTK: the decode back in the apply arm",
     r"Value::Blob\(blob\)\) => image_source\(picture, &blob\.0\),",
     "Value::Blob(blob)) => { let _ = gtk4::gdk::Texture::from_bytes(&gtk4::glib::Bytes::from(&blob.0[..])); "
     "image_source(picture, &blob.0) }",
     "decodes outside its door"),
    ("GTK: the decode on the main thread",
     r"gio::spawn_blocking\(move \|\| gtk4::gdk::Texture::from_bytes\(&encoded\)\.ok\(\)\)",
     "async move { gtk4::gdk::Texture::from_bytes(&encoded).ok() }",
     "the off-main door lacks gio::spawn_blocking"),
    ("GTK: the late picture installed",
     r"\n\s+if with_image\(&picture, \|s\| s\.generation\) != generation \{\n\s+return;\n\s+\}", "",
     "the off-main door lacks if with_image(&picture, |s| s.generation) != generation {"),
    ("GTK: the generation never moved", r"(let generation = with_image\(picture, \|s\| \{)\n\s+s\.generation \+= 1;", r"\1",
     "the off-main door lacks s.generation += 1;"),
    ("GTK: the cache keyed off the content",
     r"picture_cache::put\(picture_cache::Key \{ id, pixels",
     "picture_cache::put(picture_cache::Key { id: 0, pixels",
     "the off-main door lacks picture_cache::put"),
    ("GTK: the cache key without its size", r"\n\s+pub pixels: u32,", "",
     "the decoded cache lacks pub pixels: u32,"),
    ("GTK: the cache kept under pressure",
     r"monitor\.connect_low_memory_warning\(\|_, _\| empty\(\)\);",
     "monitor.connect_low_memory_warning(|_, _| {});",
     "the decoded cache lacks monitor.connect_low_memory_warning"),
    ("GTK: busy on a label-less image", r"labelled && phase == crate::wire::IMAGE_PHASE_LOADING,",
     "phase == crate::wire::IMAGE_PHASE_LOADING,", "the look decision lacks picture.update_state"),
    ("GTK: busy never cleared", r"labelled && phase == crate::wire::IMAGE_PHASE_LOADING,",
     "true,", "the look decision lacks picture.update_state"),
    ("GTK: undecodable bytes drawn empty",
     r"if phase == crate::wire::IMAGE_PHASE_FAILED \|\| \(texture\.is_none\(\) && undecodable\) \{",
     "if phase == crate::wire::IMAGE_PHASE_FAILED {",
     "the look decision lacks let look = if phase"),
    ("GTK: the failed look without its glyph", r"\.then\(\|\| image_missing_icon\(picture\)\)", ".then(|| None)",
     "the look decision lacks .then(|| image_missing_icon(picture))"),
    ("GTK: the failed glyph spelled twice",
     r"let name = symbol_icon_name\(i64::from\(crate::wire::SYMBOL_IMAGE_MISSING\)\)\?;",
     'let name = "image-missing-symbolic";', "a second spelling of the failed glyph"),
    ("GTK: a literal fill colour",
     r"let fill = gdk::RGBA::new\(ink\.red\(\), ink\.green\(\), ink\.blue\(\), ink\.alpha\(\) \* super::IMAGE_FILL_ALPHA\);",
     "let fill = gdk::RGBA::new(0.5, 0.5, 0.5, 0.1);", "the looks lacks ink.alpha() * super::IMAGE_FILL_ALPHA"),
    ("GTK: the phase read off the prop",
     r"(fn image_drawn_phase\(picture: &gtk4::Picture\) -> String \{\n)",
     r'\1    if with_image(picture, |s| s.phase) == 1 { return "loading".into(); }\n',
     "reaches the image's state"),
    ("GTK: a band report's asks left queued",
     r"(table\.reported = Some\(\(first, count\)\);\n\s+\}\n\s+for op in ops\.unwrap_or_default\(\) \{\n\s+apply\(core, op\);\n\s+\}\n)\s+send_asks\(core\);\n",
     r"\1", "a band report's asks are sent"),
    ("GTK: the doorbell borrowing CORE inside a nested turn",
     r"glib::idle_add\(\|\| \{\n(\s+)drain_when_free\(\);", r"glib::idle_add(|| {\n\1drain_transactions();",
     "a doorbell rung under a borrowed CORE waits"),
    ("GTK: the failed glyph back at the symbolic size", r"const IMAGE_GLYPH: i32 = 32;",
     "const IMAGE_GLYPH: i32 = 16;", "the failed glyph at GTK's large icon size"),
    ("GTK: a band read off the first allocated row",
     r"let laid_out = !rows\.is_empty\(\) && rows\.iter\(\)\.all\(\|\(_, height\)\| \*height > 0\.0\);",
     "let laid_out = rows.iter().any(|(_, height)| *height > 0.0);",
     "a band is read only from rows that have their allocation"),
    ("GTK: no read after the allocating frame",
     r"\n\s+report_after_layout\(&body, &pending, &awaiting_layout, id\);", "",
     "reads again after the frame that allocates them"),
    ("GTK: no header read before the decode",
     r"s\.pending_natural = crate::image_header::natural\(bytes\);", "s.pending_natural = None;",
     "an unboxed image takes its header's size"),
    ("GTK: the reserved size never laid out", r"\(None, Some\(natural\)\) => reserve_natural\(picture, natural\),",
     "(None, Some(_)) => fit_picture(picture, None),", "the reserved size is laid out"),
    ("GTK: the harness reading something else", r"\n(\s+)image_drawn_phase\(&core\.images\[i\]\)\n",
     r'\n\1"shown".to_string()\n', "expect_image_phase on GTK lacks image_drawn_phase"),
]
