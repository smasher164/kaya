"""docs/styling-pass-plan.md §3's GTK row: the skin's doors in the GTK arm,
loaded by tools/lib/skin_routes.py (run from tools/check-verbs.py).

grounds.steps, shapes.steps, cards.steps, tracks.steps and dock.steps read what
the arm drew. But a gradient whose bottom stop is a literal draws the same
header on the lane's one window colour, a hover painted in kaya's grey passes
the nearest-candidate read, a panel drawn as kaya's dark fill reads as overlay
over the art, a reader that answers from the arm's own classes agrees with
every write, and a wayland hover that lets its pointer go reads only until GTK
hears the pointer leave."""

import re

from content_type_routes import flat
from reveal_routes import blocks

REL = "crates/kaya/src/gtk.rs"
LABEL = "the GTK arm"

# (label, opener, what the block must hold, what it may never name)
DOORS = [
    ("the ground stylesheet", "pub fn ground_css(grounds: &BTreeMap<u64, Ground>, dark: bool) -> String {",
     ["let stop = if dark { tops & 0xFF_FFFF } else { (tops >> 24) & 0xFF_FFFF };",
      "linear-gradient(to bottom, #{stop:06x}, var(--window-bg-color));",
      "var(--window-bg-color)); \\ background-origin: border-box;"],
     ["rgb(", "rgba(", "#000", "#fff", "url(", "base64"]),
    ("the image ground", "fn set_ground(core: &mut CoreState, id: u64, widget: &gtk4::Widget, change: impl FnOnce(&mut skin::Ground)) {",
     ["picture.set_data(GROUND_PICTURE_KEY, true)", "picture.set_content_fit(gtk4::ContentFit::Cover);",
      "container.insert_child_after(picture, None::<&gtk4::Widget>);", "image_source(picture, &bytes);", "ensure_flex(widget);"],
     ["Texture::from_bytes", "base64"]),
    ("the ground picture's allocation", "fn allocate_ground_picture(container: &gtk4::Widget, width: i32, height: i32) {",
     ["c.allocate(width + left + right, height + top + bottom, -1, Some(transform));"], []),
    ("the activatable container", "fn set_activatable(core: &mut CoreState, id: u64, widget: &gtk4::Widget, on: bool) {",
     ['widget.add_css_class("activatable");', "widget.set_accessible_role(gtk4::AccessibleRole::Button);",
      "Rc::new(move || sink.send_activated_tag(&tag))", "press.connect_released(", "activate();",
      "gtk4::StateFlags::ACTIVE"],
     ["RGBA", "add_css_provider"]),
    ("the selected surface", "fn set_selected(widget: &gtk4::Widget, on: bool) {",
     ["widget.set_state_flags(gtk4::StateFlags::SELECTED, false);",
      "widget.update_state(&[gtk4::accessible::State::Selected(Some(on))]);"], ["RGBA"]),
    ("the image's clip", "fn push_image_shape(",
     ["crate::wire::SHAPE_ROUNDED => 12.0,", "crate::wire::SHAPE_CIRCLE => w.min(h) / 2.0,", "snap.push_rounded_clip("],
     []),
    ("an image's shape", "fn set_shape(picture: &gtk4::Picture, shape: i64) {",
     ["picture.set_data(IMAGE_SHAPE_KEY, shape)", "render_image(picture);", "gtk4::Overflow::Hidden"], []),
    ("a label's tint", "fn set_label_tint(widget: &gtk4::Widget, tint: i64) {",
     ["crate::wire::TINT_ACCENT => LABEL_TINT_CLASSES[0],", "crate::wire::TINT_CRITICAL => LABEL_TINT_CLASSES[3],"],
     ["RGBA", "set_markup"]),
    ("the batch's end", "fn skin_refresh(core: &mut CoreState) {",
     ["load_kaya_css(&core.skin.css, \"grounds\", &css, &core.css_error);",
      "widget.update_property(&[gtk4::accessible::Property::Label(&words.join(\", \"))]);",
      "let holds = skin::holds_widget_below(root);", "root.set_visible(holds);"], []),
    ("the wayland pointer's hold", "fn hold_wayland_pointer(located: &str) {",
     ["libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);", '.args(["set", x, y, "sleep", "600000"])',
      "let _ = old.kill();"], []),
]
# The readers answer from the window's pixels or the bus, never from what
# the arm stamped on its own widgets.
READS = [
    ("expect_ground's reader", "fn ground_read(&self, t: crate::harness::Target) -> String {",
     ["skin::shot_of(&widget)", "shot.at(x, fy + 4.0)", "shot.at(x, fy + fh - 4.0)", "skin::contrast(mid, shot.text)",
      "&& contrast >= 4.5", "skin::gap(bottom, shot.ground) <= SKIN_TOLERANCE",
      "skin::picture_at(&t, (fw - 4.0, 4.0), (fw, fh))", "ground_texture(core, id)"]),
    ("expect_shape's reader", "fn shape_read(&self, t: crate::harness::Target) -> String {",
     ["skin::shot_of(&widget)", "shot.at(fx - 4.0, fy + fh / 2.0)", "shot.at(fx + 1.0, fy + 1.0)",
      "shot.at(fx + 6.0, fy + 6.0)", "image_box_rect(fw, fh,"]),
    ("expect_selected's reader", "fn selected_read(&self, t: crate::harness::Target) -> String {",
     ["atspi_rank(&core.window, &widget)", "atspi_states(atspi::Role::Button, rank)",
      "states.contains(atspi::State::Selected)"]),
    ("expect_tint's reader", "fn label_tint(&self, t: crate::harness::Target) -> String {",
     ["skin::shot_of(&widget)", '("accent", "accent_color")', '("critical", "error_color")',
      'vec![("none", shot.text)]']),
    ("expect_dock's reader", "fn dock_read(&self) -> String {",
     ["root.compute_bounds(&view)", "view.content().and_then(|c| c.compute_bounds(&view))",
      "let spans = x <= 2.0 && x + w >= vw - 2.0;", "if let Some(fault) = dock_content_fault(core, &view, y) {"]),
    ("expect_dock's content half",
     "fn dock_content_fault(core: &CoreState, view: &adw::ToolbarView, dock_top: f64) -> Option<String> {",
     ["let content = window_content(core, 0)?;", "w.compute_bounds(view)", "!w.is_mapped()",
      "f64::from(f.y() + f.height()) > dock_top + 1.0"]),
    ("expect_fill's skin readings", "fn fill_tint(&self, t: crate::harness::Target) -> String {",
     ['("hovered", layer(fg, 0.04, bare))', '("hovered", layer(card_fg, 0.03, on_card))',
      '("selected", layer(accent_bg, 0.25, bare))', "skin::picture_at(",
      "lm < SKIN_OVERLAY_DARKEST && lm < lt / 2.0"]),
    ("hover's route", "fn hover(&self, t: crate::harness::Target) {",
     ['.args([if wayland { "locate" } else { "move" }, if wayland { "wayland" } else { "x11" }])',
      "hold_wayland_pointer(&String::from_utf8_lossy(&out.stdout));"]),
]
MODEL = (r"image_shape\(|IMAGE_SHAPE_KEY|has_css_class|css_classes\(\)|state_flags\(|LABEL_TINT_CLASSES|"
         r"SHAPE_CLASSES|ACTIVATABLE_CLASS|skin\.activations")
CALLS = [
    ("the ground arms", "(NativeWidget::Column(c) | NativeWidget::Row(c), Prop::Ground, Value::I64(kind)) => {\n"
     "let widget = c.clone().upcast::<gtk4::Widget>();\nset_ground(core, id.0, &widget, |g| g.kind = kind);"),
    ("the gradient's colour reaches the ground",
     "set_ground(core, id.0, &widget, |g| g.tops = Some(tops));"),
    ("the picture reaches the ground", "set_ground(core, id.0, &widget, move |g| g.image = Some(bytes));"),
    ("an appearance flip rewrites the grounds",
     'load_kaya_css(&ground_css, "grounds", &skin::ground_css(&grounds.borrow(), manager.is_dark()), &error);'),
    ("the overlay is libadwaita's panel over media", '"kaya-tint-critical", "card", "osd"];'),
    ("the skin's rules are libadwaita's own row and card values",
     ".kaya-activatable:not(.card):hover { background-color: color-mix(in srgb, currentColor 4%, transparent); }"),
    ("the selected surface is libadwaita's selected row",
     ".kaya-activatable:not(.card):selected { background-color: color-mix(in srgb, var(--accent-bg-color) 25%, "
     "transparent); }"),
    ("a card's hover is libadwaita's own .card.activatable", 'widget.add_css_class("activatable");'),
    ("an activatable container takes the filled inset",
     "if !widget.css_classes().iter().any(|c| c.starts_with(INSET_CLASS)) {\nwidget.add_css_class(ACTIVATABLE_PAD_CLASS);\n}\nlet Some(tag)"),
    ("the activatable inset is the filled one, off a declared table's row",
     ".kaya-activatable-pad { padding: 12px; }\n.kaya-table-body > viewport > box > .kaya-activatable-pad { padding: 0px; }"),
    ("a tinted label inside a filled container keeps the fill's foreground",
     ".kaya-filled label.accent, .kaya-filled label.success, .kaya-filled label.warning, "
     ".kaya-filled label.error { color: inherit; }"),
    ("the boxed picture is clipped where it is drawn",
     "let clipped = super::push_image_shape(snap, (x, y, w, h), self.shape.get());"),
    ("the loading and failed looks take the shape",
     "let clipped = super::push_image_shape(snap, (x, y, width, height), super::image_shape(&widget));"),
    ("the decoded picture carries the shape", "rtl,\nimage_shape(picture),\n)));"),
    ("the dock is the window's bottom bar under every pane", "view.add_bottom_bar(&root_widget);"),
    ("the batch ends in the skin's refresh", "refresh_bleeds(core);\nskin_refresh(core);"),
    ("a click reaches an activatable container", "Some(activate) => activate(),"),
    ("an activatable container is a button on the bus",
     "if w.is::<gtk4::Box>() && w.accessible_role() == gtk4::AccessibleRole::Button {\nreturn Some(atspi::Role::Button);"),
    ("a name never demotes the button", ") && widget.accessible_role() != gtk4::AccessibleRole::Button"),
    ("a table's row is in view when its viewport holds it (Y5)",
     "if top >= adj.value() - 2.0 && bottom <= adj.value() + adj.page_size() + 2.0 {"),
    ("a nested cell reads as its labels joined (Y5)", '(!words.is_empty()).then(|| words.join("/"))'),
    ("a widget in the dock is safe against the dock", ".find(|root| widget.is_ancestor(*root))"),
    ("the ground picture stays out of the flex layout",
     "if c.is_visible() && !super::is_ground_picture(&c) {\nlet weight = super::grow_weight(&c);"),
    ("the flex layout lays the ground picture under the children", "super::allocate_ground_picture(widget, width, height);"),
    ("the ground picture stays out of every read of a container's children", "if !is_ground_picture(&w) {\nout.push(w);"),
    ("the ground picture is drawn first, behind the children",
     "if container.first_child().as_ref() != Some(picture.upcast_ref()) {\ncontainer.reorder_child_after(picture, None::<&gtk4::Widget>);"),
]


def code(text):
    """The text with every `//` comment cut, so prose naming a call is not one."""
    return "\n".join(re.sub(r"//.*", "", line) for line in text.splitlines())


def skin_css(src):
    found = re.search(r'const SKIN_CSS: &str = "\\\n(.*?)\n";', src, re.S)
    return found.group(1) if found else None


def findings(text):
    out = []
    src = code(text)
    for label, opener, needs, never in DOORS:
        found = blocks(src, opener)
        if len(found) != 1:
            out.append(f"skin: {LABEL}'s {label} is defined {len(found)} times in {REL}, wanted once ({opener})")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"skin: {LABEL}'s {label} lacks {need.splitlines()[0][:90]}")
        for name in never:
            if name in found[0]:
                out.append(f"skin: {LABEL}'s {label} names {name}, a colour of kaya's own where libadwaita has one")
    css = skin_css(text)
    if css is None:
        out.append(f"skin: {LABEL}'s SKIN_CSS is gone from {REL}")
    elif re.search(r"#[0-9a-fA-F]{3,8}\b|rgba?\(", css):
        out.append(f"skin: {LABEL}'s SKIN_CSS names a colour of kaya's own: every layer is currentColor or a "
                   f"libadwaita variable")
    for label, opener, needs in READS:
        found = blocks(src, opener)
        if len(found) != 1:
            out.append(f"skin: {LABEL}'s {label} is gone — {REL} lacks {opener}")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"skin: {LABEL}'s {label} lacks {need}")
        if re.search(MODEL, found[0]):
            out.append(f"skin: {LABEL}'s {label} reaches kaya's model, so it could answer from what the arm "
                       f"stamped instead of what it drew")
    for label, call in CALLS:
        if flat(call) not in flat(src):
            out.append(f"skin: {LABEL}: {label} no longer holds — {REL} lacks {call.splitlines()[0][:90]}")
    return out


CUTS = [
    ("GTK: the gradient's bottom stop a literal", r"var\(--window-bg-color\)\); \\",
     r"#242424); \\", "the ground stylesheet lacks linear-gradient"),
    ("GTK: the top stop one appearance's", r"let stop = if dark \{ tops & 0xFF_FFFF \} else \{ \(tops >> 24\) & 0xFF_FFFF \};",
     "let stop = tops & 0xFF_FFFF;", "the ground stylesheet lacks let stop"),
    ("GTK: the image ground decoded on the main thread", r"\n\s+image_source\(picture, &bytes\);",
     "\n        let _ = gtk4::gdk::Texture::from_bytes(&gtk4::glib::Bytes::from(&bytes[..]));",
     "the image ground lacks image_source"),
    ("GTK: the ground picture laid out as a child", r"if c\.is_visible\(\) && !super::is_ground_picture\(&c\) \{\n(\s+)let weight",
     r"if c.is_visible() {\n\1let weight", "the ground picture stays out of the flex layout"),
    ("GTK: the ground tiling inside the inset", r"(var\(--window-bg-color\)\); \\\n\s+)background-origin: border-box; ",
     r"\1", "the ground stylesheet lacks var(--window-bg-color)); \\ background-origin"),
    ("GTK: the hover layer kaya's grey", r"currentColor 4%, transparent\); \}", "#ededed); }",
     "SKIN_CSS names a colour of kaya's own"),
    ("GTK: the selected surface kaya's own", r"var\(--accent-bg-color\) 25%, transparent\); \}\n\.kaya-activatable\.card",
     "#3584e4 25%, transparent); }\n.kaya-activatable.card", "SKIN_CSS names a colour of kaya's own"),
    ("GTK: an activatable container no button to the tree",
     r"\n\s+widget\.set_accessible_role\(gtk4::AccessibleRole::Button\);", "",
     "the activatable container lacks widget.set_accessible_role"),
    ("GTK: an activation sent as a click", r"Rc::new\(move \|\| sink\.send_activated_tag\(&tag\)\)",
     "Rc::new(move || sink.send_click_tag(&tag))", "the activatable container lacks Rc::new"),
    ("GTK: selected painted without the tree's state",
     r"\n\s+widget\.update_state\(&\[gtk4::accessible::State::Selected\(Some\(on\)\)\]\);", "",
     "the selected surface lacks widget.update_state"),
    ("GTK: the overlay a flat dark fill", r'"card", "osd"\];', '"card", "kaya-tint-dark"];',
     "the overlay is libadwaita's panel over media"),
    ("GTK: the circle clip cut", r"crate::wire::SHAPE_CIRCLE => w\.min\(h\) / 2\.0,", "crate::wire::SHAPE_CIRCLE => 0.0,",
     "the image's clip lacks crate::wire::SHAPE_CIRCLE"),
    ("GTK: the looks left unshaped",
     r"super::push_image_shape\(snap, \(x, y, width, height\), super::image_shape\(&widget\)\)",
     "super::push_image_shape(snap, (x, y, width, height), crate::wire::SHAPE_RECT)",
     "the loading and failed looks take the shape"),
    ("GTK: a tinted label over its fill", r"\.kaya-filled label\.accent, [^\n]*\{ color: inherit; \}\n", "",
     "a tinted label inside a filled container keeps"),
    ("GTK: expect_dock blind to the content", r"if let Some\(fault\) = dock_content_fault\(core, &view, y\) \{",
     "if let Some(fault) = None::<String> {", "expect_dock's reader lacks if let Some(fault)"),
    ("GTK: expect_dock's content half blind to the dock's top", r"f64::from\(f\.y\(\) \+ f\.height\(\)\) > dock_top \+ 1\.0",
     "false", "expect_dock's content half lacks f64::from"),
    ("GTK: an activatable container flush against its surface",
     r"(if !widget\.css_classes\(\)\.iter\(\)\.any\(\|c\| c\.starts_with\(INSET_CLASS\)\) \{\n\s+)widget\.add_css_class\(ACTIVATABLE_PAD_CLASS\);(\n\s+\}\n\s+let Some\(tag\))",
     r"\1\2", "an activatable container takes the filled inset"),
    ("GTK: the dock inside the panes", r"view\.add_bottom_bar\(&root_widget\);", "view.set_content(Some(&root_widget));",
     "the dock is the window's bottom bar"),
    ("GTK: a dock that never collapses", r"\n\s+root\.set_visible\(holds\);", "", "the batch's end lacks root.set_visible"),
    ("GTK: the shape read off the arm's own data", r"(fn shape_read\(&self, t: crate::harness::Target\) -> String \{\n)",
     r'\1        if false { let _ = IMAGE_SHAPE_KEY; }\n', "reaches kaya's model"),
    ("GTK: the tint read off the arm's own classes", r"(fn label_tint\(&self, t: crate::harness::Target\) -> String \{\n)",
     r'\1        let _ = LABEL_TINT_CLASSES;\n', "reaches kaya's model"),
    ("GTK: the selection read off the arm's own state", r"(fn selected_read\(&self, t: crate::harness::Target\) -> String \{\n)",
     r'\1        let _ = |w: &gtk4::Widget| w.state_flags();\n', "reaches kaya's model"),
    ("GTK: the gradient's contrast unread", r"&& contrast >= 4\.5", "", "expect_ground's reader lacks &&"),
    ("GTK: the wayland pointer let go", r"\n\s+hold_wayland_pointer\(&String::from_utf8_lossy\(&out\.stdout\)\);", "",
     "hover's route lacks hold_wayland_pointer"),
    ("GTK: an appearance flip leaving the grounds",
     r'\n\s+load_kaya_css\(&ground_css, "grounds", &skin::ground_css\(&grounds\.borrow\(\), manager\.is_dark\(\)\), &error\);',
     "", "an appearance flip rewrites the grounds"),
]
