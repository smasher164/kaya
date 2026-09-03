//! GTK4 backend: an interpreter of resolved apply-ops. The core owns the
//! main thread and the GLib main loop; glib::idle_add (g_idle_add) is the
//! doorbell and carries no data.

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::mpsc::Receiver;

use gtk4::gdk;
use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;

use crate::protocol::{
    ApplyOp, CommandKind, MenuItemKind, MenuProp, OccSink, Occurrence, Prop, Transaction, Value,
    WidgetId, WidgetKind, WindowProp, WindowId,
};
use crate::scene::Scene;

/// A diagnostic line as ONE write. Rust's stderr is unbuffered and
/// `eprintln!` issues a write per format fragment, so under host load
/// another thread's line lands INSIDE this one — a torn
/// `KAYA_DIAG app identity: class` line put the route name on the wrong
/// line and the identity class witness failed a green leg, twice on the
/// matrix before the 300-sample probe caught it mid-tear
/// (docs/deferred.md, the identity-x11 flake entry).
macro_rules! kaya_diag {
    ($($arg:tt)*) => {{
        use std::io::Write as _;
        let mut line = format!($($arg)*);
        line.push('\n');
        let _ = std::io::stderr().write_all(line.as_bytes());
    }};
}

/// Where a child's grow weight is parked so the layout manager can find
/// it.
const GROW_KEY: &str = "kaya-grow";

/// Where the flex manager parks the main-axis extent it handed a child —
/// THE TRACK, before GTK adjusts the allocation for the child's own align
/// and margins. `expect_fills` needs the number the layout GAVE beside the
/// number the widget TOOK; nothing else reads it.
const TRACK_KEY: &str = "kaya-track";

// --- The semantic icon vocabulary onto Adwaita (docs/styling-plan.md D6) ---
// EVERY NAME BELOW IS COPIED FROM THE CATALOG REPORT, NOT RECALLED: the
// obvious spellings read right and draw wrong and an unresolvable name falls
// back SILENTLY (docs/traps.md: "GTK's Adwaita icon names read right and
// draw wrong"). Full `-symbolic` names, never an `-rtl` suffix; column order
// is crate::wire::SYMBOLS.
const SYMBOL_ICONS: &[(u32, &str)] = &[
    (crate::wire::SYMBOL_ADD, "list-add-symbolic"),
    (crate::wire::SYMBOL_REMOVE, "list-remove-symbolic"),
    // NOT `edit-delete-symbolic`, which is an X in a circle (§4.3).
    (crate::wire::SYMBOL_DELETE, "user-trash-symbolic"),
    (crate::wire::SYMBOL_EDIT, "document-edit-symbolic"),
    // NOT `emblem-ok-symbolic`: deleted from the theme at 48 (§4.5).
    (crate::wire::SYMBOL_DONE, "object-select-symbolic"),
    (crate::wire::SYMBOL_CLOSE, "window-close-symbolic"),
    // The name GTK's own GtkSearchEntry reaches for (§7).
    (crate::wire::SYMBOL_SEARCH, "system-search-symbolic"),
    // NOT `preferences-system-symbolic` (wrench+screwdriver, §4.4) and
    // NOT `emblem-system-symbolic` (a hole at 48, §4.5).
    (crate::wire::SYMBOL_SETTINGS, "applications-system-symbolic"),
    (crate::wire::SYMBOL_REFRESH, "view-refresh-symbolic"),
    // NOT `dialog-information-symbolic`, which is a LIGHTBULB (§4.2).
    (crate::wire::SYMBOL_INFO, "help-about-symbolic"),
    (crate::wire::SYMBOL_WARNING, "dialog-warning-symbolic"),
    // Chevrons at 45 AND 50, unlike `pan-start`/`pan-end`, which changed
    // metaphor mid-range (§4.6). RTL-aware without a suffix.
    (crate::wire::SYMBOL_BACK, "go-previous-symbolic"),
    (crate::wire::SYMBOL_FORWARD, "go-next-symbolic"),
    // The VERTICAL ellipsis; `view-more-horizontal-symbolic` is the
    // other one (§7).
    (crate::wire::SYMBOL_MORE, "view-more-symbolic"),
    (crate::wire::SYMBOL_COPY, "edit-copy-symbolic"),
    (crate::wire::SYMBOL_PASTE, "edit-paste-symbolic"),
    // NOT `emblem-favorite-symbolic`, which is a HEART and is gone (§4.5).
    (crate::wire::SYMBOL_STAR, "starred-symbolic"),
    (crate::wire::SYMBOL_LOCK, "changes-prevent-symbolic"),
    (crate::wire::SYMBOL_PERSON, "avatar-default-symbolic"),
    // The ACTION (`go-home-symbolic`), not the place
    // (`user-home-symbolic`) — §7.
    (crate::wire::SYMBOL_HOME, "go-home-symbolic"),
];

const _: () = assert!(
    SYMBOL_ICONS.len() == crate::wire::SYMBOLS.len(),
    "every spec symbol needs an Adwaita name in SYMBOL_ICONS (crates/kaya/src/gtk.rs)"
);

/// The Adwaita name for a wire symbol value, or None when the table has
/// no row for it.
fn symbol_icon_name(value: i64) -> Option<&'static str> {
    u32::try_from(value)
        .ok()
        .and_then(|v| SYMBOL_ICONS.iter().find(|(id, _)| *id == v))
        .map(|(_, name)| *name)
}

/// The reverse: the SEMANTIC name behind an Adwaita name — what the
/// harness read answers with, so every backend prints the same sentence.
fn symbol_name_of_icon(icon: &str) -> Option<&'static str> {
    SYMBOL_ICONS
        .iter()
        .find(|(_, name)| *name == icon)
        .and_then(|(value, _)| crate::wire::symbol_name(*value as i64))
}

/// THE SILENT-BLANK WALL, run once per process the first time any app
/// declares any symbol. GTK's icon lookup does not fail — it ends at
/// `icon_paintable_new("image-missing", ...)`, noticed only behind
/// `GTK_DEBUG=iconfallback` — and a GtkStackSwitcher then paints NOTHING,
/// zero ink in its whole box (docs/traps.md: "GTK's Adwaita icon names read
/// right and draw wrong").
fn assert_symbol_icons_resolve(display: &gdk::Display) {
    use std::cell::Cell;
    thread_local! {
        static CHECKED: Cell<bool> = const { Cell::new(false) };
    }
    if CHECKED.with(|c| c.replace(true)) {
        return;
    }
    let theme = gtk4::IconTheme::for_display(display);
    // The SPEC's list drives the walk, not the table's: a row with a wrong
    // or duplicated value would leave a spec symbol uncovered.
    let mut missing: Vec<String> = Vec::new();
    for (value, semantic) in crate::wire::SYMBOLS {
        match symbol_icon_name(*value as i64) {
            None => missing.push(format!(
                "  {semantic} — no row in SYMBOL_ICONS (crates/kaya/src/gtk.rs)"
            )),
            Some(icon) if !theme.has_icon(icon) => missing.push(format!(
                "  {semantic} -> {icon} — not in this machine's icon theme"
            )),
            Some(_) => {}
        }
    }
    if !missing.is_empty() {
        panic!(
            "kaya: {} of {} semantic icons do not resolve on this machine. GTK does \
             not fail on an unresolvable icon name — it falls back silently, and \
             the only notice is behind GTK_DEBUG=iconfallback (measured on GTK \
             4.18 / Adwaita 48: a stack switcher button then paints nothing at \
             all). Searched icon theme {:?}:\n{}\nInstall the theme that carries \
             them (Debian: adwaita-icon-theme) or fix the SYMBOL_ICONS row.",
            missing.len(),
            crate::wire::SYMBOLS.len(),
            theme.theme_name(),
            missing.join("\n"),
        );
    }
}

/// The CSS class prefix a container's own inset rides on (prop 17): one
/// class per DISTINCT value, `kaya-inset-8` and friends, defined in
/// `CoreState::container_inset_css`.
const INSET_CLASS: &str = "kaya-inset-";

/// Guest-visible text uses LF on every platform, so text is normalized
/// wherever it escapes toward the guest. GTK's Entry/TextView store a
/// pasted CR or CRLF verbatim.
fn lf(s: String) -> String {
    if s.contains('\r') {
        s.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        s
    }
}

/// kaya AS AN INPUT METHOD — the harness `compose` verb's engine.
///
/// A preedit is not text and there is no setter for it: GTK's widgets render
/// the string their `GtkIMContext` hands back, and the preedit never enters
/// the buffer at all (measured — `char_count` stayed at 4 with a live
/// preedit). The only party that can produce marked text on GTK is an input
/// method.
#[cfg(feature = "harness")]
mod kaya_im {
    use gtk4::glib;
    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;

    // Every kaya input method GTK has constructed, by the widget it was
    // given. GTK creates the delegate itself and exposes no getter, so the
    // instance registers ITSELF in `set_client_widget`.
    thread_local! {
        static LIVE: std::cell::RefCell<Vec<(gtk4::Widget, KayaIMContext)>> =
            const { std::cell::RefCell::new(Vec::new()) };
    }

    /// The kaya input method serving this widget, if GTK has made one.
    pub fn for_widget(widget: &gtk4::Widget) -> Option<KayaIMContext> {
        LIVE.with_borrow(|live| {
            live.iter().find(|(w, _)| w == widget).map(|(_, c)| c.clone())
        })
    }

    #[derive(Default)]
    pub struct KayaIMContextInner {
        pub preedit: std::cell::RefCell<String>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for KayaIMContextInner {
        const NAME: &'static str = "KayaIMContext";
        type Type = KayaIMContext;
        type ParentType = gtk4::IMContext;
    }

    impl ObjectImpl for KayaIMContextInner {}

    impl IMContextImpl for KayaIMContextInner {
        /// What the widget renders as marked text. The caret goes at the
        /// END of the composition, the rule the scene's frozen offset uses.
        fn preedit_string(&self) -> (glib::GString, gtk4::pango::AttrList, i32) {
            let text = self.preedit.borrow().clone();
            let caret = text.chars().count() as i32;
            (glib::GString::from(text), gtk4::pango::AttrList::new(), caret)
        }

        /// THE CANCELLATION PATH, and it is GTK that walks it. A
        /// programmatic cursor or selection move resets the input method
        /// unconditionally — even for the range already selected, even for
        /// the caret's existing position (all three measured).
        fn reset(&self) {
            let had = !self.preedit.borrow().is_empty();
            self.preedit.replace(String::new());
            if had {
                self.obj().emit_by_name::<()>("preedit-changed", &[]);
                self.obj().emit_by_name::<()>("preedit-end", &[]);
            }
            self.parent_reset();
        }

        /// GTK hands the delegate the widget it serves; the multicontext
        /// never hands its delegate out, so this is the one tie-point.
        fn set_client_widget<P: IsA<gtk4::Widget>>(&self, widget: Option<&P>) {
            let me = self.obj().clone();
            LIVE.with_borrow_mut(|live| match widget {
                Some(widget) => {
                    let widget = widget.as_ref().clone();
                    live.retain(|(w, _)| *w != widget);
                    live.push((widget, me));
                }
                None => live.retain(|(_, c)| *c != me),
            });
            self.parent_set_client_widget(widget);
        }
    }

    glib::wrapper! {
        pub struct KayaIMContext(ObjectSubclass<KayaIMContextInner>)
            @extends gtk4::IMContext;
    }

    impl Default for KayaIMContext {
        fn default() -> Self {
            glib::Object::new()
        }
    }

    impl KayaIMContext {
        /// Put marked text in front of the widget, through the signals a
        /// real input method emits and in the order it emits them.
        pub fn set_preedit(&self, text: &str) {
            let starting = self.imp().preedit.borrow().is_empty();
            self.imp().preedit.replace(text.to_owned());
            if starting {
                self.emit_by_name::<()>("preedit-start", &[]);
            }
            self.emit_by_name::<()>("preedit-changed", &[]);
        }
    }
}

/// The name kaya's input method answers to on GTK's `gtk-im-module`
/// extension point.
#[cfg(feature = "harness")]
const KAYA_IM_ID: &str = "kaya";

/// Install kaya's input method as this view's, and answer with it. GTK
/// creates the delegate, which is why the instance comes back out of the
/// multicontext rather than being constructed here.
#[cfg(feature = "harness")]
fn install_kaya_im(view: &gtk4::TextView) -> Option<kaya_im::KayaIMContext> {
// Registering is idempotent by GIO's contract:
// `g_io_extension_point_register` answers with the existing point.
    static REGISTERED: std::sync::Once = std::sync::Once::new();
    REGISTERED.call_once(|| {
        use glib::translate::IntoGlib;
// SAFETY: both calls take a NUL-terminated name (C string literals)
// and a GType registered by the glib::wrapper! above.
        unsafe {
            let point = gio::ffi::g_io_extension_point_register(c"gtk-im-module".as_ptr());
            gio::ffi::g_io_extension_point_set_required_type(
                point,
                gtk4::IMContext::static_type().into_glib(),
            );
// THE LOWEST PRIORITY IN THE POINT: GTK picks a DEFAULT input method
// off this same list when nothing names one, so an entry above the
// platform's own would silently become every text widget's.
            gio::ffi::g_io_extension_point_implement(
                c"gtk-im-module".as_ptr(),
                kaya_im::KayaIMContext::static_type().into_glib(),
                c"kaya".as_ptr(),
                i32::MIN,
            );
        }
    });

    let controllers = view.observe_controllers();
    for i in 0..controllers.n_items() {
        let Some(controller) = controllers.item(i) else { continue };
        let Ok(keys) = controller.downcast::<gtk4::EventControllerKey>() else {
            continue;
        };
        let Some(context) = keys.im_context() else { continue };
        let Ok(multi) = context.downcast::<gtk4::IMMulticontext>() else {
            continue;
        };
        if multi.context_id() != KAYA_IM_ID {
            multi.set_context_id(Some(KAYA_IM_ID));
        }
        // FORCE THE DELEGATE TO EXIST: a multicontext creates it lazily on
        // the next key event, and the verb needs something to set now.
        multi.focus_in();
        return kaya_im::for_widget(view.upcast_ref::<gtk4::Widget>());
    }
    None
}

/// Put marked text in the view, through the input method installed above.
#[cfg(feature = "harness")]
fn set_kaya_preedit(view: &gtk4::TextView, text: &str) {
    if let Some(context) = install_kaya_im(view) {
        context.set_preedit(text);
    }
}

/// The ONE tag every declared range wears, named so it can be found
/// again in the buffer's tag table rather than remembered in a map.
const HIGHLIGHT_TAG: &str = "kaya-highlight";

/// The mark REVEAL scrolls to. A mark and not an iterator: GTK computes
/// line heights in an idle handler and documents `scroll_to_mark` as the
/// form that finishes after line validation — measured as the difference
/// between landing at y=264 of a 5600px target and landing at 5560
/// (docs/deferred.md, ranges-on-gtk).
const REVEAL_MARK: &str = "kaya-reveal";

/// The buffer's highlight tag, created on first use. ONE TAG FOR THE WHOLE
/// SET: re-declaring is `remove_all_tags` plus one `apply_tag` per range,
/// measured at 570us for 400 ranges over a 19k buffer with no `changed`
/// emission. The COLOUR is not assertable on this widget — it truncates each
/// channel before scaling (docs/probes/range-probe-linux.md) — which is why
/// `highlights` keys on the attribute's PRESENCE.
fn highlight_tag(buffer: &gtk4::TextBuffer) -> gtk4::TextTag {
    use gtk4::prelude::{TextBufferExt, TextTagExt};
    let table = buffer.tag_table();
    if let Some(tag) = table.lookup(HIGHLIGHT_TAG) {
        return tag;
    }
    let tag = gtk4::TextTag::new(Some(HIGHLIGHT_TAG));
    tag.set_background(Some("#ffe066"));
    table.add(&tag);
    tag
}

/// THE OTHER COORDINATE DIVERGENCE. `lf()` collapses a `\r\n` into the
/// single `\n` the guest is told about and GTK's buffer keeps BOTH, so after
/// one CRLF a declared range lands one position early. Three walks, one rule,
/// each with a free fast path for a buffer holding no CR.
///
/// A GUEST CHARACTER offset -> the buffer character offset to apply at.
fn buffer_offset(buffer_text: &str, guest_chars: u64) -> i32 {
    if !buffer_text.contains('\r') {
        return guest_chars as i32;
    }
    let (mut seen, mut at) = (0u64, 0i32);
    let mut chars = buffer_text.chars().peekable();
    while seen < guest_chars {
        let Some(c) = chars.next() else { break };
        at += 1;
        if c == '\r' && chars.peek() == Some(&'\n') {
            chars.next();
            at += 1;
        }
        seen += 1;
    }
    at
}

/// A GUEST BYTE offset -> the buffer character offset to apply at. The
/// same walk, counting the guest's bytes instead of its characters.
fn buffer_offset_of_byte(buffer_text: &str, guest_byte: u64) -> i32 {
    let (mut bytes, mut at) = (0u64, 0i32);
    let mut chars = buffer_text.chars().peekable();
    while bytes < guest_byte {
        let Some(c) = chars.next() else { break };
        at += 1;
        if c == '\r' {
            if chars.peek() == Some(&'\n') {
                chars.next();
                at += 1;
            }
            bytes += 1;
        } else {
            bytes += c.len_utf8() as u64;
        }
    }
    at
}

/// And the READING direction: a buffer character offset -> the GUEST
/// byte offset the harness spelling is written in.
fn guest_byte_of(buffer_text: &str, buffer_chars: i32) -> u64 {
    if !buffer_text.contains('\r') {
        return buffer_text
            .char_indices()
            .nth(buffer_chars.max(0) as usize)
            .map(|(byte, _)| byte as u64)
            .unwrap_or(buffer_text.len() as u64);
    }
    let (mut at, mut bytes) = (0i32, 0u64);
    let mut chars = buffer_text.chars().peekable();
    while at < buffer_chars {
        let Some(c) = chars.next() else { break };
        at += 1;
        if c == '\r' {
            if chars.peek() == Some(&'\n') {
                chars.next();
                at += 1;
            }
            // The guest sees one LF wherever the buffer holds either.
            bytes += 1;
        } else {
            bytes += c.len_utf8() as u64;
        }
    }
    bytes
}

/// D2's drop, in the buffer's own `changed` handler — the one place on this
/// backend that cannot be late. A COMPARE rather than a blanket drop:
/// `apply_tag` fires no `changed` (measured — 20 full re-declare cycles
/// produced 0 emissions), so declaring a set can never trip this.
fn drop_stale_highlights(
    declared: &std::rc::Rc<RefCell<HashMap<u64, String>>>, id: u64, buffer: &gtk4::TextBuffer,
) {
    use gtk4::prelude::TextBufferExt;
    let stale = {
        let map = declared.borrow();
        match map.get(&id) {
            Some(text) => {
                *text != lf(buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string())
            }
            None => false,
        }
    };
    if !stale {
        return;
    }
    declared.borrow_mut().remove(&id);
    buffer.remove_all_tags(&buffer.start_iter(), &buffer.end_iter());
}

fn grow_weight(widget: &gtk4::Widget) -> f64 {
    // SAFETY: the key is private to this module and only ever set to an
    // f64 by set_grow_weight below.
    unsafe {
        widget
            .data::<f64>(GROW_KEY)
            .map(|p| *p.as_ref())
            .unwrap_or(0.0)
    }
}

fn set_grow_weight(widget: &gtk4::Widget, weight: f64) {
    // SAFETY: as above — this is the only writer of the key.
    unsafe { widget.set_data(GROW_KEY, weight) }
}

fn child_track(widget: &gtk4::Widget) -> Option<f64> {
// SAFETY: the key is private to this module. `None` is "never laid out
// by the flex manager", a different answer from "was given zero".
    unsafe { widget.data::<f64>(TRACK_KEY).map(|p| *p.as_ref()) }
}

fn set_child_track(widget: &gtk4::Widget, extent: f64) {
    // SAFETY: as above — this is the only writer of the key.
    unsafe { widget.set_data(TRACK_KEY, extent) }
}

/// A container's align mode (the align spec enum's wire values), same
/// object-data pattern as the grow weight.
const ALIGN_KEY: &str = "kaya-align";

fn container_align(widget: &gtk4::Widget) -> i64 {
    // SAFETY: the key is private to this module and only ever set to
    // an i64 by set_container_align below.
    unsafe {
        widget
            .data::<i64>(ALIGN_KEY)
            .map(|p| *p.as_ref())
            .unwrap_or(0)
    }
}

fn set_container_align(widget: &gtk4::Widget, mode: i64) {
    // SAFETY: as above — this is the only writer of the key.
    unsafe { widget.set_data(ALIGN_KEY, mode) }
}

/// A container's declared inter-child gap — what kaya believes it set. Both
/// the layout (ensure_flex) and `expect_fills` read it HERE and not off the
/// GtkBox: once ensure_flex swaps the layout manager, GtkBox's own spacing
/// getter and setter both assert GTK_IS_BOX_LAYOUT and the value is lost
/// (docs/deferred.md's always-8 GAP).
const SPACING_KEY: &str = "kaya-spacing";

/// The normalized default every Column and Row is created with, and so the
/// gap a container that never took the prop is laid out with.
const CONTAINER_SPACING: i32 = 8;

fn container_spacing(widget: &gtk4::Widget) -> i32 {
    // SAFETY: the key is private to this module and only ever set to an i32
    // by set_container_spacing below.
    unsafe {
        widget
            .data::<i32>(SPACING_KEY)
            .map(|p| *p.as_ref())
            .unwrap_or(CONTAINER_SPACING)
    }
}

fn set_container_spacing(widget: &gtk4::Widget, gap: i32) {
    // SAFETY: as above — this is the only writer of the key.
    unsafe { widget.set_data(SPACING_KEY, gap) }
}

/// A kaya container's OWN main axis, stamped at creation. Two readings are
/// unavailable here: `GtkBox::orientation` (ensure_flex replaces the layout
/// that owns the property — see reconcile_grow_align), and the child's
/// layout manager (it answers for every GtkBox kaya composes for itself,
/// and a radio group is a vertical one).
const AXIS_KEY: &str = "kaya-axis";

/// The natural width a wrapping label asks for, in characters. GTK needs a
/// NUMBER here: `max-width-chars` is what bounds a wrapping label's
/// requisition, and without it the label asks for its whole text on one
/// line and the window grows to match. 60 is a line of prose — wide enough
/// that ordinary labels never wrap when there is room (the natural width is
/// a MAXIMUM, not a target), narrow enough that a long one stops dragging
/// its container off the screen.
const KAYA_LABEL_MAX_WIDTH_CHARS: i32 = 60;

fn container_vertical(widget: &gtk4::Widget) -> Option<bool> {
    // SAFETY: the key is private to this module and only ever set to a
    // bool by set_container_vertical below.
    unsafe { widget.data::<bool>(AXIS_KEY).map(|p| *p.as_ref()) }
}

fn set_container_vertical(widget: &gtk4::Widget, vertical: bool) {
    // SAFETY: as above — this is the only writer of the key.
    unsafe { widget.set_data(AXIS_KEY, vertical) }
}

/// The scroll KIND, by a key of its own: a textarea's flex child is a
/// GtkScrolledWindow too, and the breadth rule below is the scroll's alone.
const SCROLL_KEY: &str = "kaya-scroll-kind";
fn is_scroll_kind(widget: &gtk4::Widget) -> bool {
    // SAFETY: the key is private to this module and only ever set to
    // `true` by set_scroll_kind below.
    unsafe { widget.data::<bool>(SCROLL_KEY).is_some() }
}
fn set_scroll_kind(widget: &gtk4::Widget) {
    // SAFETY: as above — this is the only writer of the key.
    unsafe { widget.set_data(SCROLL_KEY, true) }
}

/// A row in a column, or a column in a row — the child's main axis IS the
/// parent's cross axis, so its own breadth is what the parent's cross box
/// hands out.
fn crosses_container(child: &gtk4::Widget, vertical_container: bool) -> bool {
    container_vertical(child) == Some(!vertical_container)
}

/// Install the flex layout manager the first time one of a container's
/// children grows. Lazy: containers that never grow keep GtkBox's own
/// behaviour, and the manager takes the DECLARED spacing with it — the
/// box's own is what the swap makes unreadable (see SPACING_KEY).
fn ensure_flex(container: &gtk4::Widget) {
    let Some(container_box) = container.downcast_ref::<gtk4::Box>() else {
        return;
    };
    if container_box
        .layout_manager()
        .and_then(|l| l.downcast::<flex::FlexLayout>().ok())
        .is_some()
    {
        return;
    }
    let orientation = container_box.orientation();
    container_box.set_layout_manager(Some(flex::FlexLayout::new(
        orientation,
        container_spacing(container),
    )));
}

/// Stamp one child's CROSS-axis alignment from its container's align mode.
/// Grow reconciliation owns the MAIN axis, so the two never fight. Baseline
/// maps to GTK's native baseline valign (rows only).
fn apply_cross_align(child: &gtk4::Widget, vertical_container: bool, mode: i64) {
    use gtk4::prelude::WidgetExt;
    let mut align = match mode {
        1 => gtk4::Align::Center,
        2 => gtk4::Align::End,
        3 => gtk4::Align::Fill,
        4 => gtk4::Align::Baseline,
        _ => gtk4::Align::Start,
    };
    // THE BREADTH RULE (the stretch ruling's second slice, 2026-08-22): a
    // nested CROSSING container spans its parent's inner breadth under every
    // align mode, so the mode never reaches one. Baseline is the exception
    // that isn't: GTK spells it BASELINE_FILL and it already spans, AND the
    // allocated baseline it hands out is the one discriminator cross_mode
    // has that spanning geometry cannot fake.
    if align != gtk4::Align::Baseline && crosses_container(child, vertical_container) {
        align = gtk4::Align::Fill;
    }
    // A SCROLL SPANS ITS PARENT'S CROSS AXIS under the default mode and
    // under stretch (ruled 2026-09-02): a viewport is a region, not
    // content, and every platform's own scrolling surface fills its
    // container — hugging left a 79pt pannable strip in a 375pt window
    // on iOS and an 84px one here (docs/traps.md). Center and end still
    // POSITION a hugging scroll; the scene's expect_breadth holds this.
    if is_scroll_kind(child) && matches!(mode, 0 | 3) {
        align = gtk4::Align::Fill;
    }
    if vertical_container {
        // A column's cross axis is horizontal.
        child.set_halign(align);
    } else {
        child.set_valign(align);
    }
}

fn reconcile_grow_align(child: &gtk4::Widget) {
    let Some(parent) = child.parent() else { return };
// The axis comes from our own manager, never from GtkBox::orientation:
// ensure_flex has replaced the box layout that owned that property.
    let Some(layout) = parent.layout_manager() else {
        return;
    };
    let Some(flex) = layout.downcast_ref::<flex::FlexLayout>() else {
        return;
    };
    let fill_or_start = if grow_weight(child) > 0.0 {
        gtk4::Align::Fill
    } else {
        gtk4::Align::Start
    };
    match flex.orientation() {
        gtk4::Orientation::Vertical => child.set_valign(fill_or_start),
        _ => child.set_halign(fill_or_start),
    }
    // A GROWN CANVAS TAKES THE WHOLE OFFERED BOX ON BOTH AXES
    // (docs/canvas-plan.md §3.2.1). Without it a `redraw` canvas never
    // starts: it is sized by a blit it cannot have until a track is
    // reported, and Start clamps its allocation to that zero
    // (docs/traps.md, "A canvas sized by its own blit NEVER STARTS").
    if grow_weight(child) > 0.0 && child.is::<KayaCanvas>() {
        child.set_halign(gtk4::Align::Fill);
        child.set_valign(gtk4::Align::Fill);
    }
}

/// The flex layout manager: GTK's half of the `grow` contract. GtkBox cannot
/// express it — its only knob is the boolean `hexpand`/`vexpand` and extra
/// space is split EQUALLY, so a 1:3 request is unrepresentable. The policy is
/// the one on [`Prop::Grow`].
mod flex {
    use gtk4::glib;
    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;

    fn normalized_weights(weights: &[f64]) -> (Vec<f64>, f64) {
        let scale = weights
            .iter()
            .fold(0.0_f64, |largest, weight| largest.max(*weight));
        assert!(scale.is_finite() && scale > 0.0);
        let normalized: Vec<f64> = weights.iter().map(|weight| weight / scale).collect();
        let pool = normalized.iter().sum();
        (normalized, pool)
    }

    fn grow_shares(total: i32, weights: &[f64]) -> Vec<i32> {
        if weights.is_empty() {
            return Vec::new();
        }
        let total = total.max(0);
        let (weights, pool) = normalized_weights(weights);
        let mut spent = 0;
        weights
            .iter()
            .enumerate()
            .map(|(i, weight)| {
                if i + 1 == weights.len() {
                    total - spent
                } else {
                    let share = ((f64::from(total) * weight / pool).round() as i32)
                        .clamp(0, total - spent);
                    spent += share;
                    share
                }
            })
            .collect()
    }

    // docs/traps.md, "GTK flex measurement must invert its own weighted allocation".
    fn required_grow_pool(growers: &[(f64, i32)]) -> i32 {
        if growers.is_empty() {
            return 0;
        }
        let raw_weights: Vec<f64> = growers.iter().map(|(weight, _)| *weight).collect();
        let (weights, pool) = normalized_weights(&raw_weights);
        let rounding_error = (growers.len().saturating_sub(1) as f64) / 2.0;
        let last = growers.len() - 1;
        let mut total = 0;
        for (i, ((_, required), weight)) in growers.iter().zip(weights).enumerate() {
            let required = (*required).max(0);
            let candidate = if required == 0 {
                0
            } else if i == last {
                let strict = (f64::from(required - 1) + rounding_error) * pool / weight;
                (strict.floor() + 1.0) as i32
            } else {
                (f64::from(required) * pool / weight).ceil() as i32
            };
            total = total.max(candidate);
        }
        loop {
            let shares = grow_shares(total, &raw_weights);
            if shares
                .iter()
                .zip(growers)
                .all(|(share, (_, required))| *share >= (*required).max(0))
            {
                return total;
            }
            let next = total.saturating_add(1);
            if next == total {
                return total;
            }
            total = next;
        }
    }

    fn main_axis_measure(children: &[(f64, i32, i32)], spacing: i32) -> (i32, i32) {
        let mut fixed = 0_i32;
        let mut minimum_growers = Vec::new();
        let mut natural_growers = Vec::new();
        for (weight, minimum, natural) in children {
            if *weight > 0.0 {
                minimum_growers.push((*weight, *minimum));
                natural_growers.push((*weight, *natural));
            } else {
                fixed = fixed.saturating_add(*natural);
            }
        }
        let count = i32::try_from(children.len()).unwrap_or(i32::MAX);
        let gaps = spacing.saturating_mul(count.saturating_sub(1));
        (
            fixed
                .saturating_add(required_grow_pool(&minimum_growers))
                .saturating_add(gaps),
            fixed
                .saturating_add(required_grow_pool(&natural_growers))
                .saturating_add(gaps),
        )
    }

    #[cfg(test)]
    mod tests {
        use super::{grow_shares, main_axis_measure, required_grow_pool};

        #[test]
        fn gtk_flex_measure_holds_grower_requirements() {
            let unequal = [(1.0, 145), (1.0, 100), (1.0, 70)];
            let pool = required_grow_pool(&unequal);
            assert_eq!(pool, 435);
            assert!(grow_shares(pool, &[1.0, 1.0, 1.0])
                .iter()
                .zip(unequal.iter())
                .all(|(share, (_, required))| share >= required));

            let rounding_dust = [(1.0, 1), (1.0, 1), (2.0, 3)];
            let pool = required_grow_pool(&rounding_dust);
            assert_eq!(pool, 7);
            assert_eq!(grow_shares(pool, &[1.0, 1.0, 2.0]), [2, 2, 3]);

            let four_equal = [(1.0, 1), (1.0, 1), (1.0, 1), (1.0, 1)];
            let pool = required_grow_pool(&four_equal);
            assert_eq!(pool, 7);
            for total in pool..=pool + 16 {
                assert!(grow_shares(total, &[1.0; 4])
                    .iter()
                    .zip(four_equal.iter())
                    .all(|(share, (_, required))| share >= required));
            }

            let skewed = [
                (0.57, 22),
                (61_377.0, 56),
                (0.107, 98),
                (0.826, 76),
                (0.02475, 45),
                (0.02476, 60),
            ];
            let pool = required_grow_pool(&skewed);
            assert!((152_000_000..153_000_000).contains(&pool));
            assert!(grow_shares(pool, &skewed.map(|(weight, _)| weight))
                .iter()
                .zip(skewed.iter())
                .all(|(share, (_, required))| share >= required));

            let floating_edge = [(3.0, 1), (1.0, 4)];
            let pool = required_grow_pool(&floating_edge);
            assert_eq!(pool, 15);
            assert_eq!(grow_shares(pool, &[3.0, 1.0]), [11, 4]);

            assert_eq!(
                main_axis_measure(&[(0.0, 10, 100), (1.0, 50, 70)], 8),
                (158, 178)
            );
        }

        #[test]
        fn gtk_flex_allocator_never_negative() {
            for total in 0..=16 {
                let shares = grow_shares(total, &[1.0; 4]);
                assert_eq!(shares.iter().sum::<i32>(), total);
                assert!(shares.iter().all(|share| *share >= 0));
            }
            assert_eq!(grow_shares(2, &[1.0; 4]), [1, 1, 0, 0]);
        }

        #[test]
        fn gtk_table_viewport_rejects_overflow() {
            assert!(super::super::table_content_fits(102.0, 100.0));
            assert!(!super::super::table_content_fits(102.1, 100.0));
            use super::super::{table_horizontal_issue, TableHorizontalIssue as Issue};
            assert_eq!(
                table_horizontal_issue(0.0, 100.0, 100.0, 100.0, 100.0, 0.0),
                None
            );
            assert_eq!(
                table_horizontal_issue(0.0, 100.0, 103.0, 100.0, 100.0, 0.0),
                Some(Issue::ContentUnreachable)
            );
            assert_eq!(
                table_horizontal_issue(0.0, 97.0, 100.0, 100.0, 100.0, 0.0),
                Some(Issue::ContentUnderfill)
            );
            assert_eq!(
                table_horizontal_issue(0.0, 100.0, 100.0, 100.0, 120.0, 0.0),
                Some(Issue::TrackUnderfill)
            );
            assert_eq!(
                table_horizontal_issue(0.0, 100.0, 100.0, 120.0, 100.0, 0.0),
                Some(Issue::TrackOverflow)
            );
            assert_eq!(
                table_horizontal_issue(-2.0, 100.0, 100.0, 100.0, 100.0, 0.0),
                None
            );
            assert_eq!(
                table_horizontal_issue(-2.1, 100.0, 100.0, 100.0, 100.0, 0.0),
                Some(Issue::ContentLeftOverflow)
            );
            assert_eq!(
                table_horizontal_issue(2.0, 100.0, 100.0, 100.0, 100.0, 0.0),
                None
            );
            assert_eq!(
                table_horizontal_issue(2.1, 100.0, 100.0, 100.0, 100.0, 0.0),
                Some(Issue::ContentLeftUnderfill)
            );

            // THE RULING'S OWN CASE (2026-08-29): columns wider than the
            // track are what a scrolling table looks like, and they convict
            // only when the surface cannot reach them. Same three cell
            // numbers, three different scroll ranges.
            assert_eq!(
                table_horizontal_issue(0.0, 160.0, 160.0, 100.0, 100.0, 60.0),
                None,
                "a table that can scroll to its last column is correct"
            );
            assert_eq!(
                table_horizontal_issue(0.0, 160.0, 160.0, 100.0, 100.0, 40.0),
                Some(Issue::ContentUnreachable),
                "20px of columns nothing can scroll to is the defect"
            );
            assert_eq!(
                table_horizontal_issue(0.0, 160.0, 160.0, 100.0, 100.0, 0.0),
                Some(Issue::ContentUnreachable),
                "a clipping table is the pre-ruling behaviour and is refused"
            );

            // PRECEDENCE where several hold at once, which is the ordinary
            // case: the ROOT is reported, never its symptom. This order is
            // the one all four backends carry (docs/deferred.md, the
            // leading-edge UNDERFILL entry) — the leading edge outranks the
            // end, because a table displaced at its start also ends in the
            // wrong place.
            assert_eq!(
                table_horizontal_issue(40.0, 60.0, 60.0, 100.0, 120.0, 0.0),
                Some(Issue::TrackUnderfill)
            );
            assert_eq!(
                table_horizontal_issue(40.0, 60.0, 60.0, 100.0, 100.0, 0.0),
                Some(Issue::ContentLeftUnderfill)
            );
            assert_eq!(
                table_horizontal_issue(-40.0, 60.0, 140.0, 100.0, 100.0, 0.0),
                Some(Issue::ContentLeftOverflow)
            );
            assert_eq!(
                table_horizontal_issue(0.0, 60.0, 140.0, 100.0, 100.0, 0.0),
                Some(Issue::ContentUnderfill)
            );
        }

        /// A PADDED CARD CONVICTS NOTHING, and the basis is the whole reason
        /// (docs/deferred.md's table-card entry): the card's padding is a
        /// CONTENT-BOX inset, so cells stay at 0 and only the assigned TRACK
        /// needs the card's span subtracted. This pins both directions — the
        /// corrected basis is silent, and the basis that FORGETS to subtract
        /// convicts a correct table.
        #[test]
        fn gtk_table_padded_card_convicts_nothing() {
            use super::super::{table_horizontal_issue, TableHorizontalIssue as Issue};
            // The measured frame: an 800px parent, a 12px-per-side card,
            // cells flush at 0 inside the 776px content box.
            let (parent, span) = (800.0, 24.0);
            let viewport = parent - span;
            assert_eq!(
                table_horizontal_issue(0.0, viewport, viewport, viewport, parent - span, 0.0),
                None,
                "a padded card is a correct table"
            );
            assert_eq!(
                table_horizontal_issue(0.0, viewport, viewport, viewport, parent, 0.0),
                Some(Issue::TrackUnderfill),
                "a track basis that forgets the card's own padding \
                 convicts every padded table"
            );
            // And the padding may not be paid for twice: an UNPADDED
            // table's track is its parent's width untouched.
            assert_eq!(
                table_horizontal_issue(0.0, parent, parent, parent, parent, 0.0),
                None
            );
        }
    }

    pub struct FlexLayoutInner {
        pub orientation: std::cell::Cell<gtk4::Orientation>,
        pub spacing: std::cell::Cell<i32>,
    }

// Hand-written rather than derived: gtk4::Orientation has no Default and
// ObjectSubclass requires one, GObject constructing before our code runs.
    impl Default for FlexLayoutInner {
        fn default() -> Self {
            Self {
                orientation: std::cell::Cell::new(gtk4::Orientation::Vertical),
                spacing: std::cell::Cell::new(0),
            }
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for FlexLayoutInner {
        const NAME: &'static str = "KayaFlexLayout";
        type Type = FlexLayout;
        type ParentType = gtk4::LayoutManager;
    }

    impl ObjectImpl for FlexLayoutInner {}

    impl FlexLayoutInner {
        fn is_main(&self, orientation: gtk4::Orientation) -> bool {
            orientation == self.orientation.get()
        }
    }

    impl LayoutManagerImpl for FlexLayoutInner {
        fn measure(
            &self,
            widget: &gtk4::Widget,
            orientation: gtk4::Orientation,
            for_size: i32,
        ) -> (i32, i32, i32, i32) {
            let (mut minimum, mut natural) = (0, 0);
            let mut main_children = Vec::new();
            let mut child = widget.first_child();
            while let Some(c) = child {
                if c.is_visible() {
                    let (cmin, cnat, _, _) = c.measure(orientation, for_size);
                    if self.is_main(orientation) {
                        let weight = super::grow_weight(&c);
                        main_children.push((weight, cmin, cnat));
                    } else {
                        minimum = minimum.max(cmin);
                        natural = natural.max(cnat);
                    }
                }
                child = c.next_sibling();
            }
            if self.is_main(orientation) {
                (minimum, natural) = main_axis_measure(&main_children, self.spacing.get());
            }
            (minimum, natural, -1, -1)
        }

        fn allocate(&self, widget: &gtk4::Widget, width: i32, height: i32, baseline: i32) {
            let vertical = self.orientation.get() == gtk4::Orientation::Vertical;
            let (main_total, cross_total) = if vertical {
                (height, width)
            } else {
                (width, height)
            };

            // Pass 1: what the non-growers need, and the weight pool.
            let mut children = Vec::new();
            let mut child = widget.first_child();
            while let Some(c) = child {
                if c.is_visible() {
                    let weight = super::grow_weight(&c);
                    let natural = if weight > 0.0 {
                        // A grower's own natural size is deliberately not
                        // consulted: the contract is flex-basis 0.
                        0
                    } else {
                        c.measure(self.orientation.get(), cross_total).1
                    };
                    children.push((c.clone(), weight, natural));
                }
                child = c.next_sibling();
            }
            if children.is_empty() {
                return;
            }
            let gaps = self.spacing.get() * (children.len() as i32 - 1);
            let fixed: i32 = children.iter().map(|(_, _, nat)| *nat).sum();
            let leftover = (main_total - fixed - gaps).max(0);
            let weights: Vec<f64> = children
                .iter()
                .filter_map(|(_, weight, _)| (*weight > 0.0).then_some(*weight))
                .collect();
            let mut shares = grow_shares(leftover, &weights).into_iter();

// Pass 2: place them. The growers' shares are handed out exactly,
// WITHOUT clamping to their minimum sizes — a clamp would silently
// turn 1:3 into something else in a tight window, and the overflow
            // policy is one DESIGN still defers.
            let mut offset = 0;
            for (c, weight, natural) in &children {
                let extent = if *weight > 0.0 {
                    shares.next().expect("a grower has a computed share")
                } else {
                    *natural
                };
                let (w, h, x, y) = if vertical {
                    (cross_total, extent, 0, offset)
                } else {
                    (extent, cross_total, offset, 0)
                };
                let transform = gtk4::gsk::Transform::new()
                    .translate(&gtk4::graphene::Point::new(x as f32, y as f32));
// The track, recorded BEFORE the allocate: what GTK stores on the
// child afterwards is the box its own align and margins shrank it to.
                super::set_child_track(c, f64::from(extent));
                c.allocate(w, h, baseline, Some(transform));
                offset += extent + self.spacing.get();
            }
        }
    }

    glib::wrapper! {
        pub struct FlexLayout(ObjectSubclass<FlexLayoutInner>)
            @extends gtk4::LayoutManager;
    }

    impl FlexLayout {
        pub fn new(orientation: gtk4::Orientation, spacing: i32) -> Self {
            let this: Self = glib::Object::new();
            this.imp().orientation.set(orientation);
            this.imp().spacing.set(spacing);
            this
        }

        /// The axis this manager stacks on — the authority, since the
        /// GtkBoxLayout that owned the property has been replaced.
        pub fn orientation(&self) -> gtk4::Orientation {
            self.imp().orientation.get()
        }

        /// The gap, for a manager already installed. `GtkBox::set_spacing`
        /// cannot reach it — the box forwards to its layout manager and the
        /// forward asserts GTK_IS_BOX_LAYOUT.
        pub fn set_spacing(&self, spacing: i32) {
            if self.imp().spacing.replace(spacing) != spacing {
                self.layout_changed();
            }
        }
    }

    /// Read a child's main-axis extent as the manager allocated it. The
    /// allocation, not `width()`/`height()`: those report the CSS box, which
    /// the theme insets inside the allocation — Adwaita takes 10pt out of a
    /// button's height — and reading them turned an exactly correct 25/75
    /// split into 27/73.
    pub fn child_extent(child: &gtk4::Widget, vertical: bool) -> f64 {
        let allocation = child.allocation();
        if vertical {
            f64::from(allocation.height())
        } else {
            f64::from(allocation.width())
        }
    }
}

enum NativeWidget {
    Column(gtk4::Box),
    Button(gtk4::Button),
    Label(gtk4::Label),
    Entry(gtk4::Entry),
    Row(gtk4::Box),
    Checkbox(gtk4::CheckButton),
    Slider(gtk4::Scale),
    Image(gtk4::Picture),
    Scroll(gtk4::ScrolledWindow),
    Progress(gtk4::ProgressBar),
    Select(gtk4::DropDown),
    Radio(gtk4::Box),
    Grid(gtk4::Grid),
    /// THE ONE COMPOSITE KIND WITH A CONTROL INSIDE IT: a `GtkTextView` in a
    /// `GtkScrolledWindow`, in that order (viewport, control). Both halves
    /// have to be reachable — see `widget` and `control` below.
    Textarea(gtk4::ScrolledWindow, gtk4::TextView),
    /// The blit's widget: a `KayaCanvas` over a `GdkMemoryTexture`, the
    /// raw-pixel sibling of `Image`'s encoded decode
    /// (docs/canvas-plan.md §8).
    Canvas(KayaCanvas),
}

impl NativeWidget {
    /// The widget the LAYOUT sees: what gets parented, ordered, unparented,
    /// grown and measured. The control itself for every kind but the textarea.
    fn widget(&self) -> gtk4::Widget {
        match self {
            NativeWidget::Column(w) => w.clone().upcast(),
            NativeWidget::Button(w) => w.clone().upcast(),
            NativeWidget::Label(w) => w.clone().upcast(),
            NativeWidget::Entry(w) => w.clone().upcast(),
            NativeWidget::Row(w) => w.clone().upcast(),
            NativeWidget::Checkbox(w) => w.clone().upcast(),
            NativeWidget::Slider(w) => w.clone().upcast(),
            NativeWidget::Image(w) => w.clone().upcast(),
            NativeWidget::Scroll(w) => w.clone().upcast(),
            NativeWidget::Progress(w) => w.clone().upcast(),
            NativeWidget::Select(w) => w.clone().upcast(),
            NativeWidget::Radio(w) => w.clone().upcast(),
            NativeWidget::Grid(w) => w.clone().upcast(),
            NativeWidget::Textarea(scroller, _) => scroller.clone().upcast(),
            NativeWidget::Canvas(w) => w.clone().upcast(),
        }
    }

    /// The widget the USER sees: the control that takes focus, holds the
    /// text, and publishes the accessible role a scene names it by — the
    /// textarea's `GtkTextView` inside its viewport, the layout widget itself
    /// for every other kind. THE TWO ANSWERS DIVERGED silently in four
    /// places: the accessible label, hint and id (`expect_ax textarea#0` read
    /// `field/`), focus, and `set_text`'s reverse lookup from widget to id.
    fn control(&self) -> gtk4::Widget {
        match self {
            NativeWidget::Textarea(_, view) => view.clone().upcast(),
            other => other.widget(),
        }
    }
}

/// The table's column gap — the one number every synthesized tier
/// spells (docs/tables-plan.md decision 6; SwiftUI and Compose say 24
/// too). The ROW gap is the For container's own spacing.
const TABLE_COL_GAP: i32 = 24;

/// The classes kaya's own header row wears. The reads find the header
/// again by class rather than by a map, so all four table verbs are
/// tree reads and none of them can agree with a model copy.
const TABLE_HEADER_CLASS: &str = "kaya-table-header";
const TABLE_CELL_CLASS: &str = "kaya-table-header-cell";
/// The tier's own viewport and the two spacers inside it, found by class
/// like the header above so the table verbs stay tree reads.
const TABLE_BODY_CLASS: &str = "kaya-table-body";
const TABLE_SPACER_CLASS: &str = "kaya-table-spacer";
/// The stacked fold's marker (docs/adaptive-layout-plan.md D7): a folded
/// child rides inside the table's content box, above the top spacer, and
/// every reader of that box skips this class exactly as it skips the
/// spacers'.
const KAYA_FOLDED_CLASS: &str = "kaya-folded";
/// THE FOLD SEAM (docs/adaptive-layout-plan.md D7): the gap under each
/// folded child — a SECTION gap, not the table's internal spacing, so
/// the folded summary and the rows read as two surfaces (the
/// maintainer's 2026-08-30 read of the phone captures). One number,
/// four backends.
const KAYA_FOLD_SEAM_GAP: i32 = 16;

/// How much of an UNGROWN table this tier shows before the rest scrolls —
/// GTK's spelling of "a table is a viewport". It is also what puts X11's
/// 16-bit window geometry out of reach: with no declared window size a For's
/// natural height IS the toplevel's, and the un-windowed one crossed
/// 32,767px at 1,361 rows (docs/measurements/choke-linux-2026-08-24.txt).
/// A GROWN table never reaches this number; its parent's track decides.
const TABLE_MAX_CONTENT: i32 = 600;

/// A TABLE BOUNDS ITS OWN EXTENT (docs/deferred.md's table-card entry;
/// ruled 2026-08-25). GTK's spelling is Adwaita's boxed-list reading.
const TABLE_CARD_CLASS: &str = "kaya-table-card";

/// The table card and its header cells. THE CARD'S STROKE IS PAINT, NEVER
/// BOX — `outline`, since a container inset is already a border on this very
/// widget — and flat by the ruling. THE PADDING IS THE CARD'S INTERIOR: GTK4
/// puts the origin at the CONTENT box, so cells stay at 0 and only the
/// assigned TRACK needs the span added back (`table_horizontal_track`).
/// 12 horizontal is Adwaita's own (docs/traps.md: "A GTK table card is paint,
/// never box").
const TABLE_CSS: &str = "\
.kaya-table-header-cell { padding: 0px; border: 0px; min-width: 0px; min-height: 0px; }
.kaya-table-header-cell label { font-weight: bold; }
.kaya-table-card { background-color: @card_bg_color; border-radius: 12px; \
outline: 1px solid @borders; outline-offset: -1px; padding: 8px 12px; }
";

/// One declared table (docs/tables-plan.md decision 6): the header row this
/// backend composed, the size groups that make a column's cells one width,
/// and the sort tag a header click hands back verbatim. GtkColumnView IS NOT
/// USABLE HERE, measured rather than assumed: a `GtkListItem` OWNS its child,
/// so a widget the stamp already parented fails `parent == NULL` and renders
/// nothing (docs/traps.md: "GtkColumnView cannot host kaya's stamped
/// children").
struct GtkTable {
    /// The header's own scroller, sharing `body`'s horizontal adjustment so
    /// the titles translate with the cells under them (the overflow
    /// ruling). It is what hangs on the container — `header` is its child.
    head: gtk4::ScrolledWindow,
    header: gtk4::Box,
    divider: gtk4::Separator,
    /// One horizontal size group per column. Every member REQUESTS the
    /// widest member's width — that is the content floor — and GtkBox
    /// hands its leftover out equally among hexpanding children, so
    /// floor-plus-distribute and the shared x positions are the
    /// toolkit's arithmetic and not kaya's (both measured at two widths
    /// before this landed).
    groups: Vec<gtk4::SizeGroup>,
    /// Shared with the click handlers so a re-declaration replaces the
    /// tag without rebuilding the buttons.
    tag: Rc<RefCell<Vec<u8>>>,
    /// THE SCROLL CONTAINER THIS TIER OWNS (docs/virtualization-plan.md
    /// §4): the realized band scrolls inside it while the header stays
    /// put, and its GtkAdjustment is where the report loop starts.
    body: gtk4::ScrolledWindow,
    /// The scroller's one child — top spacer, the band's rows in order,
    /// bottom spacer. Every stamped row of this For is parented HERE and
    /// not on the container, which is why `table_rows` reads it.
    content: gtk4::Box,
    /// The two spacers. Their heights are the CORE's arithmetic
    /// (`kaya_window_geometry`), never this tier's: a tier that computed
    /// its own would be the second estimator §2 exists to remove.
    top: gtk4::Box,
    bottom: gtk4::Box,
    /// The last range handed to the core. A layout that moved nothing
    /// reports nothing, so report -> stamp -> layout cannot run away.
    reported: Option<(usize, usize)>,
    /// One report per main-loop turn, however many adjustment signals
    /// asked for it.
    pending: Rc<std::cell::Cell<bool>>,
    /// §2.4's anchor, this tier's half: the ROW the viewport is parked
    /// on. Every correction cycle re-parks it at its corrected position,
    /// so a taller row realized ABOVE moves the scrollbar and not the
    /// content under the reader's eyes. A scroll this tier did not issue
    /// clears it — free scrolling is the reader's.
    anchor: Rc<std::cell::Cell<Option<usize>>>,
    /// Set while this tier is moving the adjustment itself, so its own
    /// scroll is not read back as the reader's.
    programmatic: Rc<std::cell::Cell<bool>>,
}

/// A container's children, in the toolkit's own order.
fn children_of(widget: &impl IsA<gtk4::Widget>) -> Vec<gtk4::Widget> {
    let mut out = Vec::new();
    let mut child = widget.as_ref().first_child();
    while let Some(w) = child {
        child = w.next_sibling();
        out.push(w);
    }
    out
}

/// The header row kaya composed on this For container, or None when no
/// columns were declared on it. A TREE READ: the header leads the
/// container's children and wears its class — inside the scroller that
/// locks it to the body's horizontal offset (the overflow ruling).
fn table_header(column: &gtk4::Box) -> Option<gtk4::Box> {
    let first = column.first_child()?;
    let header = scrolled_box(&first.downcast::<gtk4::ScrolledWindow>().ok()?)?;
    header.has_css_class(TABLE_HEADER_CLASS).then_some(header)
}

/// A scroller's own Box child. GTK4 unwraps the viewport it inserts for a
/// non-scrollable child; the second arm is there because believing that is
/// a read nobody would have watched fail.
fn scrolled_box(scroller: &gtk4::ScrolledWindow) -> Option<gtk4::Box> {
    let inner = scroller.child()?;
    if let Ok(content) = inner.clone().downcast::<gtk4::Box>() {
        return Some(content);
    }
    inner.downcast::<gtk4::Viewport>().ok()?.child()?.downcast::<gtk4::Box>().ok()
}

#[cfg(any(feature = "harness", test))]
// docs/traps.md, "A table viewport contains rows".
fn table_content_fits(content: f64, viewport: f64) -> bool {
    content <= viewport + 2.0
}

/// ONE CAUSE PER SENTENCE for `column_edges`' horizontal half, and the
/// REFERENCE SET the winui and Compose siblings carry (docs/deferred.md, the
/// leading-edge UNDERFILL entry). THE ORDER IS ROOT-BEFORE-SYMPTOM in all
/// four backends: track, the LEADING edge, then the trailing one. CELLS PAST
/// THE VIEWPORT CONVICT NOTHING since the 2026-08-29 overflow ruling — hence
/// `reach`, which is the toolkit's own scroll range.
#[cfg(any(feature = "harness", test))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TableHorizontalIssue {
    TrackUnderfill,
    TrackOverflow,
    ContentLeftUnderfill,
    ContentLeftOverflow,
    ContentUnderfill,
    ContentUnreachable,
}

#[cfg(any(feature = "harness", test))]
fn table_horizontal_issue(
    min_start: f64,
    min_end: f64,
    max_end: f64,
    viewport: f64,
    assigned: f64,
    reach: f64,
) -> Option<TableHorizontalIssue> {
    if assigned > 0.0 && viewport < assigned - 2.0 {
        Some(TableHorizontalIssue::TrackUnderfill)
    } else if assigned > 0.0 && viewport > assigned + 2.0 {
        Some(TableHorizontalIssue::TrackOverflow)
    } else if min_start > 2.0 {
        Some(TableHorizontalIssue::ContentLeftUnderfill)
    } else if min_start < -2.0 {
        Some(TableHorizontalIssue::ContentLeftOverflow)
    } else if min_end < viewport - 2.0 {
        Some(TableHorizontalIssue::ContentUnderfill)
    } else if max_end > viewport + reach + 2.0 {
        Some(TableHorizontalIssue::ContentUnreachable)
    } else {
        None
    }
}

/// The card's own horizontal padding, MEASURED off the widget rather than
/// read back from the number that wrote it: `compute_bounds(w, w)` is the
/// BORDER box in a space whose origin GTK4 puts at the CONTENT box
/// (css_inset_of's read), so the two widths differ by exactly the inset's
/// span. 0 for a table with no card, which is what keeps this honest for
/// every other caller.
#[cfg(feature = "harness")]
fn css_inset_span(column: &gtk4::Box) -> f64 {
    use gtk4::prelude::WidgetExt;
    column
        .compute_bounds(column)
        .map(|b| (f64::from(b.width()) - f64::from(column.width())).max(0.0))
        .unwrap_or(0.0)
}

/// THE ASSIGNED TRACK, IN THE VIEWPORT'S OWN BASIS. Every arm below reads
/// an OUTER box — a flex track, a parent's content width — while the
/// caller compares against `column.width()`, which is the CONTENT width;
/// the card's interior padding is the difference and comes off here.
/// Without that, a padded card underfills its own track by its own
/// padding and expect_column_edges convicts a correct table
/// (docs/deferred.md's table-card entry).
#[cfg(feature = "harness")]
fn table_horizontal_track(column: &gtk4::Box) -> f64 {
    let viewport = f64::from(column.width());
    let inset = css_inset_span(column);
    let target: gtk4::Widget = column.clone().upcast();
    let Some(parent) = target.parent() else { return viewport };
    let Some(manager) = parent.layout_manager() else { return viewport };
    if let Some(layout) = manager.downcast_ref::<flex::FlexLayout>() {
        return if layout.orientation() == gtk4::Orientation::Horizontal {
            child_track(&target).map_or(viewport, |track| track - inset)
        } else {
            f64::from(parent.width()) - inset
        };
    }
    if let Some(layout) = manager.downcast_ref::<gtk4::BoxLayout>() {
        return if layout.orientation() == gtk4::Orientation::Vertical {
            f64::from(parent.width()) - inset
        } else {
            viewport
        };
    }
    viewport
}

/// The stamped rows of a table container: everything after the header
/// and its divider (all the children when no table was declared).
fn table_rows(column: &gtk4::Box) -> Vec<gtk4::Widget> {
    // A declared table's rows live in its own viewport, and what that
    // holds is the REALIZED BAND (docs/virtualization-plan.md §5:
    // expect_rows reads realized widgets). The spacers are geometry, not
    // rows.
    if let Some(content) = table_body(column) {
        return children_of(&content)
            .into_iter()
            .filter(|w| {
                !w.has_css_class(TABLE_SPACER_CLASS) && !w.has_css_class(KAYA_FOLDED_CLASS)
            })
            .collect();
    }
    match table_header(column) {
        None => children_of(column),
        Some(header) => {
            let mut out = Vec::new();
            // The divider sits between the header and the first row.
            let mut child = header.next_sibling().and_then(|d| d.next_sibling());
            while let Some(w) = child {
                child = w.next_sibling();
                out.push(w);
            }
            out
        }
    }
}

/// The label inside a header cell — the widget that actually DRAWS the
/// title. Reading the button instead would leave the stylesheet
/// unobserved: with TABLE_CSS lost the theme's padding puts every title
/// 10px right of its column while the buttons themselves stay exactly
/// aligned, and no lane could see it.
fn header_cell_label(cell: &gtk4::Widget) -> Option<gtk4::Label> {
    cell.downcast_ref::<gtk4::Button>()?
        .child()?
        .downcast::<gtk4::Label>()
        .ok()
}

/// The box `column_edges` measures for ONE cell, header or body: the widget
/// that draws, unwrapping the button kaya's own header cell wraps its title
/// in. ONE RULE FOR BOTH LINES — a header label and a body cell coincide to
/// the pixel only while every body cell draws its own content, and a table
/// of buttons would have compared edges off by the theme's padding.
fn cell_ink(cell: &gtk4::Widget) -> gtk4::Widget {
    header_cell_label(cell).map_or_else(|| cell.clone(), |l| l.upcast())
}

/// The title a header cell is DRAWING, and its indicator — read off the
/// button's own label, never the declaration.
fn header_cell_text(cell: &gtk4::Widget) -> String {
    header_cell_label(cell).map(|l| l.text().to_string()).unwrap_or_default()
}

/// Build the header row for a table of `cols` columns. Each cell is a
/// REAL GtkButton, so `header_click` drives the same `clicked` a user's
/// press does (the `emit_clicked` route `press` already uses).
fn build_table(sink: &OccSink, cols: usize, tag: Rc<RefCell<Vec<u8>>>, id: u64) -> GtkTable {
    let header = gtk4::Box::new(gtk4::Orientation::Horizontal, TABLE_COL_GAP);
    header.add_css_class(TABLE_HEADER_CLASS);
    header.set_halign(gtk4::Align::Fill);
    for index in 0..cols {
        let label = gtk4::Label::new(None);
        label.set_xalign(0.0);
        label.set_halign(gtk4::Align::Fill);
        let button = gtk4::Button::new();
        button.set_child(Some(&label));
        button.set_has_frame(false);
        button.add_css_class(TABLE_CELL_CLASS);
        button.set_hexpand(true);
        button.set_halign(gtk4::Align::Fill);
        let sink = sink.clone();
        let tag = tag.clone();
        let column = index as u32;
        button.connect_clicked(move |_| {
            // A REQUEST and nothing else (decision 3): the tag goes back
            // verbatim with the column, this backend sorts nothing, and
            // the indicator moves only when the guest re-declares.
            let tag = tag.borrow();
            sink.send_sort_tag(&tag, column);
        });
        header.append(&button);
    }
    let divider = gtk4::Separator::new(gtk4::Orientation::Horizontal);
    divider.set_halign(gtk4::Align::Fill);
    let groups = (0..cols)
        .map(|_| gtk4::SizeGroup::new(gtk4::SizeGroupMode::Horizontal))
        .collect();
    // THE WINDOW'S GEOMETRY, one rule five spellings
    // (docs/virtualization-plan.md §4): top spacer, the realized band's
    // real widgets, bottom spacer, inside the scroll container this tier
    // owns. The content box carries the CONTAINER's own row gap, so a
    // row's top-to-top pitch here is its box plus that gap and the
    // spacers can be measured in the same units the core answers in.
    let content = gtk4::Box::new(gtk4::Orientation::Vertical, CONTAINER_SPACING);
    content.set_halign(gtk4::Align::Fill);
    content.set_valign(gtk4::Align::Start);
    let top = build_spacer();
    let bottom = build_spacer();
    content.append(&top);
    content.append(&bottom);
    let body = gtk4::ScrolledWindow::new();
    body.add_css_class(TABLE_BODY_CLASS);
    // A TABLE WHOSE COLUMNS DO NOT FIT SCROLLS SIDEWAYS (docs/tables-plan.md,
    // the 2026-08-29 overflow ruling): it does not compress and it does not
    // clip. AUTOMATIC is what drops this tier's minimum width from the
    // content floor to the bar's own, which is the whole mechanism — under
    // NEVER the parent could never hand a table less than its columns need,
    // so the overflow the ruling describes was unreachable. The vertical
    // half is set_table_scrolling's.
    body.set_policy(gtk4::PolicyType::Automatic, gtk4::PolicyType::Automatic);
    // OVERLAY, BOTH BARS, and stated rather than inherited: a bar that took
    // width would take it off the ROWS and not off the header, and
    // column_edges — which compares the two lines' right edges — would
    // read that as content underfill.
    body.set_overlay_scrolling(true);
    // Natural size propagates so a table that FITS is byte-identical to
    // the un-windowed one; the cap is what a table that does not fit
    // stops at (TABLE_MAX_CONTENT).
    body.set_propagate_natural_width(true);
    body.set_propagate_natural_height(true);
    body.set_max_content_height(TABLE_MAX_CONTENT);
    body.set_hexpand(true);
    body.set_vexpand(true);
    body.set_halign(gtk4::Align::Fill);
    body.set_valign(gtk4::Align::Fill);
    body.set_child(Some(&content));
    // THE HEADER TRACKS THE BODY THROUGH ONE ADJUSTMENT, GtkColumnView's own
    // mechanism (docs/probes/table-overflow-2026.md §5.3). EXTERNAL is GTK's
    // policy for a scroller that shares another's bar: it draws none and,
    // unlike NEVER, does not force its size to follow the header's content,
    // so the header shrinks with the body instead of holding the window open.
    let head = gtk4::ScrolledWindow::new();
    head.set_policy(gtk4::PolicyType::External, gtk4::PolicyType::Never);
    head.set_propagate_natural_width(true);
    head.set_propagate_natural_height(true);
    head.set_hexpand(true);
    head.set_halign(gtk4::Align::Fill);
    head.set_child(Some(&header));
    head.set_hadjustment(Some(&body.hadjustment()));
    let pending = Rc::new(std::cell::Cell::new(false));
    let anchor = Rc::new(std::cell::Cell::new(None));
    let programmatic = Rc::new(std::cell::Cell::new(false));
    // THE REPORT'S TWO SOURCES, both on the adjustment: `value-changed`
    // is the scroll, `changed` is every resize and the first layout (the
    // viewport publishes page-size and upper there). Neither reports
    // inline — see schedule_window_report.
    let adjustment = body.vadjustment();
    {
        let pending = pending.clone();
        let anchor = anchor.clone();
        let programmatic = programmatic.clone();
        adjustment.connect_value_changed(move |_| {
            if !programmatic.get() {
                anchor.set(None);
            }
            schedule_window_report(&pending, id);
        });
    }
    {
        let pending = pending.clone();
        adjustment.connect_changed(move |adj| {
            eprintln!(
                "KAYA_DIAG vadjustment changed for={id} upper={:.1} page_size={:.1} \
                 pending={}",
                adj.upper(),
                adj.page_size(),
                pending.get()
            );
            schedule_window_report(&pending, id);
        });
    }
    // A TABLE JUST LAID OUT SHOWS ITS FIRST COLUMN. Without this
    // `expect_at_end` can pass before anything scrolled — measured on the
    // mac tier, where the clip view parks at its trailing edge
    // (docs/deferred.md). The trigger is a CHANGED extent and not a draw:
    // `changed` carries every relayout, and resetting on all of them would
    // throw away a scroll the reader made.
    {
        let extents = std::cell::Cell::new((f64::NAN, f64::NAN));
        body.hadjustment().connect_changed(move |adj| {
            let now = (adj.upper(), adj.page_size());
            if extents.get() != now {
                extents.set(now);
                adj.set_value(adj.lower());
            }
        });
    }
    GtkTable {
        head,
        header,
        divider,
        groups,
        tag,
        body,
        content,
        top,
        bottom,
        reported: None,
        pending,
        anchor,
        programmatic,
    }
}

/// A kind's registry as plain widgets, in creation order — the harness's
/// `kind#index` space and the candidate list a `kind@id[key.path]`
/// target resolves over. HARNESS ONLY, like its two callers: the
/// non-harness build of this backend is compiled by tools/check-gtk.py
/// alone, which the gate sweep excludes, so an ungated item here is
/// invisible until someone runs it.
#[cfg(feature = "harness")]
fn kind_registry(core: &CoreState, kind: crate::harness::TargetKind) -> Vec<gtk4::Widget> {
    use crate::harness::TargetKind as K;
    use gtk4::prelude::Cast;
    match kind {
        K::Button => core.buttons.iter().map(|w| w.clone().upcast()).collect(),
        K::Checkbox => core.checkboxes.iter().map(|w| w.clone().upcast()).collect(),
        K::Slider => core.sliders.iter().map(|w| w.clone().upcast()).collect(),
        K::Entry => core.entries.iter().map(|w| w.clone().upcast()).collect(),
        K::Label => core.labels.iter().map(|w| w.clone().upcast()).collect(),
        K::Column => core.columns.iter().map(|w| w.clone().upcast()).collect(),
        K::Row => core.rows.iter().map(|w| w.clone().upcast()).collect(),
        K::Image => core.images.iter().map(|w| w.clone().upcast()).collect(),
        K::Scroll => core.scrolls.iter().map(|w| w.clone().upcast()).collect(),
        K::Progress => core.progresses.iter().map(|w| w.clone().upcast()).collect(),
        K::Select => core.selects.iter().map(|w| w.clone().upcast()).collect(),
        K::Radio => core.radios.iter().map(|w| w.clone().upcast()).collect(),
        K::Grid => core.grids.iter().map(|w| w.clone().upcast()).collect(),
        K::Textarea => core.textareas.iter().map(|w| w.clone().upcast()).collect(),
        K::Canvas => core.canvases.iter().map(|w| w.clone().upcast()).collect(),
    }
}

fn build_spacer() -> gtk4::Box {
    let spacer = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    spacer.add_css_class(TABLE_SPACER_CLASS);
    // A visible zero-height child would still cost the content box one
    // row gap, which is exactly the number the spacer arithmetic below
    // subtracts; hidden, GtkBox lays out no gap beside it at all.
    spacer.set_visible(false);
    spacer
}

/// The content box of a table's own viewport, read out of the tree the
/// way `table_header` reads the header: by class, so no table verb can
/// agree with a model copy.
fn table_body(column: &gtk4::Box) -> Option<gtk4::Box> {
    scrolled_box(&table_body_view(column)?)
}

/// The scroll container itself — the widget whose adjustments ARE the
/// table's two axes, read by class like everything else here.
fn table_body_view(column: &gtk4::Box) -> Option<gtk4::ScrolledWindow> {
    let mut child = column.first_child();
    while let Some(w) = child {
        child = w.next_sibling();
        let Ok(scroller) = w.downcast::<gtk4::ScrolledWindow>() else {
            continue;
        };
        if scroller.has_css_class(TABLE_BODY_CLASS) {
            return Some(scroller);
        }
    }
    None
}

/// THE AXIS THE THREE SCROLL VERBS DRIVE, decided by the target's KIND: a
/// `scroll` target's vertical one, a TABLE target's horizontal one. A
/// table's rows already answer expect_window and scroll_to_row, so the
/// kind is unambiguous and no axis word is needed (docs/tables-plan.md,
/// the overflow ruling).
#[cfg(feature = "harness")]
fn scroll_axis(core: &CoreState, t: crate::harness::Target) -> Option<gtk4::Adjustment> {
    if t.kind == crate::harness::TargetKind::Column {
        let i = crate::harness::try_resolve(t.index, core.columns.len())?;
        // Pending resizes must land before the extents mean anything —
        // column_edges' own first line, for the same reason: the first
        // read after mount sees a zero page size, and every one of the
        // three verbs then answers about a table nothing laid out.
        while glib::MainContext::default().iteration(false) {}
        return Some(table_body_view(&core.columns[i])?.hadjustment());
    }
    let i = crate::harness::try_resolve(t.index, core.scrolls.len())?;
    Some(core.scrolls[i].vadjustment())
}

/// One report per main-loop turn, and never from inside the signal
/// itself: a harness read pumps the main context WHILE IT HOLDS the CORE
/// borrow, so a report that took a mutable one there would panic. Busy
/// means later, on a TIMEOUT rather than another idle — `while
/// iteration(false)` dispatches only sources that are already ready, so
/// re-arming as an idle would spin that loop forever.
fn schedule_window_report(pending: &Rc<std::cell::Cell<bool>>, id: u64) {
    if pending.get() {
        return;
    }
    pending.set(true);
    let pending = pending.clone();
    glib::idle_add_local_once(move || run_scheduled_report(pending, id));
}

fn run_scheduled_report(pending: Rc<std::cell::Cell<bool>>, id: u64) {
    let ran = CORE.with(|slot| match slot.try_borrow_mut() {
        Ok(mut core) => {
            if let Some(core) = core.as_mut() {
                window_report(core, id);
                reflow_table(core, id);
            }
            true
        }
        Err(_) => false,
    });
    if ran {
        pending.set(false);
        return;
    }
    eprintln!("KAYA_DIAG window_report for={id} deferred: the core is borrowed");
    glib::timeout_add_local(std::time::Duration::from_millis(1), move || {
        run_scheduled_report(pending.clone(), id);
        glib::ControlFlow::Break
    });
}

/// THE WINDOW'S SCALE AND APPEARANCE, reported to the core, which re-rasters
/// every canvas at them (docs/canvas-plan.md §5, §6). Only these two numbers
/// cross. THE DOUBLE, NEVER THE INTEGER (§5 rule 1): GTK is the one backend
/// that hands back a fraction and `gtk_widget_get_scale_factor` rounds UP, so
/// `gdk_surface_get_scale` is the reading. The appearance is
/// `AdwStyleManager:dark`, the same reading the accent and `canvas_ink` take.
fn presentation_report(core: &mut CoreState) {
    use gtk4::prelude::{NativeExt, WidgetExt};
    let scale = core
        .window
        .native()
        .and_then(|native| native.surface())
        .map_or(crate::canvas::CANONICAL_SCALE, |surface| surface.scale());
    let mode = if adw::StyleManager::default().is_dark() {
        crate::canvas::Mode::Dark
    } else {
        crate::canvas::Mode::Light
    };
    let scene = &mut core.scene;
    let ops = crate::fault::guard("reporting the window's scale and appearance", || {
        scene.set_presentation(crate::canvas::Presentation { scale, mode })
    });
    for op in ops.unwrap_or_default() {
        apply(core, op);
    }
}

/// The window's content size into the scene's breakpoint evaluation
/// (docs/adaptive-layout-plan.md D3) — canvas_track_report's shape: the
/// scene answers with the setter/revert ops and they apply right here.
fn window_metrics_report(core: &mut CoreState) {
    use gtk4::prelude::{GtkWindowExt, WidgetExt};
    let (width, _height) = core.window.default_size();
    if width <= 0 {
        return;
    }
    // The wayland resize trap's instrument (docs/traps.md): the width
    // this report hands the core beside what the toplevel actually holds
    // at that moment, so a fold read against the wrong width names it.
    eprintln!(
        "KAYA_DIAG window_metrics default={}x{} allocated={}x{} mapped={}",
        width,
        _height,
        core.window.width(),
        core.window.height(),
        core.window.is_mapped()
    );
    let scene = &mut core.scene;
    let Some(ops) = crate::fault::guard("reporting the window's content size", || {
        scene.set_window_metrics(
            crate::protocol::WindowId(0),
            f64::from(width),
            i64::from(crate::wire::SIZE_CLASS_NONE),
        )
    }) else {
        return;
    };
    for op in ops {
        apply(core, op);
    }
}

/// Deferred past whatever holds CORE (the notify can fire inside
/// resize_window's on_main); busy means one more idle, the
/// run_scheduled_report rule.
fn schedule_window_metrics() {
    glib::idle_add_local_once(|| {
        CORE.with(|slot| {
            let Ok(mut core) = slot.try_borrow_mut() else {
                glib::timeout_add_local_once(
                    std::time::Duration::from_millis(8),
                    schedule_window_metrics,
                );
                return;
            };
            let Some(core) = core.as_mut() else { return };
            window_metrics_report(core);
        });
    });
}

/// WHAT LAYOUT ASSIGNED EACH CANVAS, reported to the core — and what the core
/// does with it IS the size policy (docs/canvas-plan.md §3.2.1). A canvas GTK
/// has not laid out yet is SKIPPED rather than reported as zero: sending it
/// would be this backend saying something it has not measured.
fn canvas_track_report(core: &mut CoreState) {
    let canvases: Vec<(KayaCanvas, WidgetId)> =
        core.canvases.iter().cloned().zip(core.canvas_ids.iter().copied()).collect();
    let mut asks = Vec::new();
    for (canvas, id) in canvases {
        let track = (f64::from(canvas.width()), f64::from(canvas.height()));
        if track.0 <= 0.0 || track.1 <= 0.0 {
            continue;
        }
        let scene = &mut core.scene;
        let Some((ops, mut asked)) =
            crate::fault::guard("reporting a canvas's assigned track", || {
                scene.set_canvas_track(id, track)
            })
        else {
            continue;
        };
        for op in ops {
            apply(core, op);
        }
        asks.append(&mut asked);
    }
    for occ in asks {
        core.occurrences.send(occ);
    }
}

/// A FRAME (docs/canvas-plan.md §15.4): every `tick` canvas is handed the
/// track it was assigned and this time, in seconds.
fn drive_frame(core: &mut CoreState, time: f64) {
    let scene = &mut core.scene;
    let ticks = crate::fault::guard("driving a frame", || scene.frame(time)).unwrap_or_default();
    for occ in ticks {
        core.occurrences.send(occ);
    }
}

/// The harness owns the clock while it is running (§15.4) — the same
/// discriminator the startup deadline reads.
fn harness_drives_frames() -> bool {
    std::env::var_os("KAYA_SELFTEST").is_some()
}

/// THE WINDOW'S FRAME CLOCK: the one reader of every canvas's track, and the
/// platform's frame drive outside the harness. ONE PER WINDOW, never one per
/// canvas — GTK has a frame clock per surface, so a second callback would
/// measure every canvas as many times as there are canvases. THE TRACK HALF
/// RUNS IN BOTH MODES AND THE FRAME HALF DOES NOT: a scene's frame count is
/// what its `frame` verbs advanced, never a fact about the machine's load.
fn attach_canvas_clock(core: &mut CoreState) {
    if core.canvas_clock {
        return;
    }
    core.canvas_clock = true;
    core.window.add_tick_callback(|_, clock| {
        // THE CORE BORROW CAN ALREADY BE HELD: a harness read pumps the
        // main context without releasing it (`run_scheduled_report`), and
        // the frame clock is a source that pump dispatches. A frame is
        // periodic, so the answer to a busy borrow is the next one.
        CORE.with(|slot| {
            let Ok(mut core) = slot.try_borrow_mut() else { return };
            let Some(core) = core.as_mut() else { return };
            canvas_track_report(core);
            if !harness_drives_frames() {
                // The clock's own timestamp, in microseconds — never one
                // read here, which is the jitter it was fixed to remove.
                drive_frame(core, clock.frame_time() as f64 / 1_000_000.0);
            }
        });
        glib::ControlFlow::Continue
    });
}

/// `run_scheduled_report`'s try-then-retry, for the same reason: a scale
/// or appearance notify can arrive in a main-loop turn that already holds
/// the CORE borrow, and a harness read pumps the context while holding
/// it. Busy means later, on a TIMEOUT rather than another idle.
fn schedule_presentation_report() {
    glib::idle_add_local_once(run_presentation_report);
}

fn run_presentation_report() {
    let ran = CORE.with(|slot| match slot.try_borrow_mut() {
        Ok(mut core) => {
            if let Some(core) = core.as_mut() {
                presentation_report(core);
            }
            true
        }
        Err(_) => false,
    });
    if ran {
        return;
    }
    glib::timeout_add_local(std::time::Duration::from_millis(1), || {
        run_presentation_report();
        glib::ControlFlow::Break
    });
}

/// Re-hang a declared table's header and re-tie its size groups. Runs
/// after every transaction, because the rows a table is made of arrive
/// (and move, and leave) in ops of their own: nothing about a stamped
/// row's own AddChild says which table it lands in.
fn reflow_table(core: &mut CoreState, id: u64) {
    let Some(NativeWidget::Column(column)) = core.widgets.get(&WidgetId(id)) else {
        return;
    };
    let column = column.clone();
    let Some(table) = core.tables.get(&id) else { return };
    // The HEAD hangs on the container; the header itself is its child.
    let head = table.head.clone();
    let header = table.header.clone();
    let divider = table.divider.clone();
    let groups = table.groups.clone();
    let body = table.body.clone();
    let content = table.content.clone();
    let top = table.top.clone();
    let bottom = table.bottom.clone();
    // The composed header leads the container's children whatever order
    // the rows arrived in, and the divider follows it.
    if head.parent().is_none() {
        column.prepend(&head);
    } else {
        column.reorder_child_after(&head, None::<&gtk4::Widget>);
    }
    if divider.parent().is_none() {
        column.insert_child_after(&divider, Some(&head));
    } else {
        column.reorder_child_after(&divider, Some(&head));
    }
    if body.parent().is_none() {
        column.insert_child_after(&body, Some(&divider));
    } else {
        column.reorder_child_after(&body, Some(&divider));
    }
    // A ROW THAT LANDED ON THE CONTAINER MOVES INTO THE VIEWPORT. The
    // children-first sugars (OCaml, Haskell) can stamp rows before the
    // columns record declares the table, and those rows were parented
    // before there was a body to parent them to.
    for stray in children_of(&column) {
        if stray == head.clone().upcast::<gtk4::Widget>()
            || stray == divider.clone().upcast::<gtk4::Widget>()
            || stray == body.clone().upcast::<gtk4::Widget>()
        {
            continue;
        }
        column.remove(&stray);
        content.append(&stray);
    }
    // The spacers bracket the band whatever order the moves left behind:
    // MoveChild's "before: None" appends at the very end, which is past
    // the bottom spacer until this puts it back. The FOLDED children
    // (D7) lead everything, above the top spacer, in their own preserved
    // order.
    content.reorder_child_after(&top, None::<&gtk4::Widget>);
    let mut folded_anchor: Option<gtk4::Widget> = None;
    for w in children_of(&content) {
        if w.has_css_class(KAYA_FOLDED_CLASS) {
            content.reorder_child_after(&w, folded_anchor.as_ref());
            folded_anchor = Some(w);
        }
    }
    let last = content.last_child();
    if last.as_ref() != Some(bottom.upcast_ref::<gtk4::Widget>()) {
        content.reorder_child_after(&bottom, last.as_ref());
    }
    // Fresh membership every pass: a row that left takes its cells out
    // of the groups with it, and a stale member would hold a width the
    // table no longer draws.
    for group in &groups {
        for widget in group.widgets() {
            group.remove_widget(&widget);
        }
    }
    for (c, cell) in children_of(&header).into_iter().enumerate() {
        if let Some(group) = groups.get(c) {
            group.add_widget(&cell);
        }
    }
    for row in table_rows(&column) {
        let Some(row_box) = row.downcast_ref::<gtk4::Box>() else {
            continue;
        };
        // A table row spans the table, and the gap between cells is the
        // TABLE's, not the row template's.
        row_box.set_halign(gtk4::Align::Fill);
        row_box.set_spacing(TABLE_COL_GAP);
        for (c, cell) in children_of(row_box).into_iter().enumerate() {
            let Some(group) = groups.get(c) else { continue };
            cell.set_hexpand(true);
            cell.set_halign(gtk4::Align::Fill);
            if let Some(label) = cell.downcast_ref::<gtk4::Label>() {
                label.set_xalign(0.0);
            }
            group.add_widget(&cell);
        }
    }
}

/// A spacer's height, written only when it moved: an equal size request
/// still costs a resize, and this runs on every scroll frame.
fn set_spacer(spacer: &gtk4::Box, visible: bool, height: f64) {
    use gtk4::prelude::WidgetExt;
    let want = height.round().clamp(0.0, f64::from(i32::MAX)) as i32;
    if spacer.height_request() != want {
        spacer.set_size_request(-1, want);
    }
    if spacer.is_visible() != visible {
        spacer.set_visible(visible);
    }
}

/// One row's top in the collection's own coordinates, summed from the CORE's
/// per-row extents off the band's own offset — never from this tier's
/// allocations, which would be a second estimator (§2). It carries its own
/// guard rather than leaning on its callers', because a helper whose safety
/// lives at the callsite is the shape fault::tests' census cannot read.
fn row_position(
    scene: &mut Scene,
    id: u64,
    index: usize,
    band: &crate::scene::WindowGeometry,
) -> Option<f64> {
    crate::fault::guard("reading a row's extent", || {
        let mut at = band.offset;
        if index >= band.first {
            for i in band.first..index {
                at += scene.row_extent(id, i);
            }
        } else {
            for i in index..band.first {
                at -= scene.row_extent(id, i);
            }
        }
        at
    })
}

/// THE DRIVE LOOP, this tier's half (docs/virtualization-plan.md §3): what
/// the reader can SEE goes to the core, the extents this tier laid out follow
/// it, and the two spacers come back from the core's arithmetic. Answers the
/// pair `expect_window` compares. NEVER FROM INSIDE A LAYOUT PASS — the
/// applies it makes create and destroy widgets, so every caller is an idle, a
/// harness step, or the end of a drained batch.
fn window_report(core: &mut CoreState, id: u64) -> (usize, usize) {
    use gtk4::prelude::{AdjustmentExt, Cast, WidgetExt};
    // Read before the scene borrow below: a GROWN table's height is its
    // parent's business, and set_table_scrolling needs to know.
    let grown = match core.widgets.get(&WidgetId(id)) {
        Some(NativeWidget::Column(column)) => {
            grow_weight(column.upcast_ref::<gtk4::Widget>()) > 0.0
        }
        _ => false,
    };
    let Some(table) = core.tables.get(&id) else {
        return (0, 0);
    };
    let content = table.content.clone();
    let body = table.body.clone();
    let top = table.top.clone();
    let bottom = table.bottom.clone();
    let last = table.reported;
    let anchor = table.anchor.clone();
    let programmatic = table.programmatic.clone();
    let adjustment = body.vadjustment();
    let spacing = f64::from(CONTAINER_SPACING);

    let scene = &mut core.scene;
    let Some(band) = crate::fault::guard("reading a window's geometry", || {
        scene.window_geometry(id)
    }) else {
        return (0, 0);
    };
    let total = band.total;

    // §2.4, THE RE-PARK: the anchored row goes back to the top of the
    // viewport at its CORRECTED position, so heights that landed above
    // it move the scrollbar rather than the reader's place. A scroll
    // clamped at the collection's end simply does not land, and the
    // reading below is then the honest one.
    if let Some(index) = anchor.get().filter(|i| *i < total) {
        // row_position speaks the COLLECTION's coordinates; the folded
        // children above the top spacer (D7) shift every allocation down
        // by their own extent, so the adjustment write adds it back. THE
        // TOP SPACER'S OWN Y IS THAT EXTENT — heights, spacing, and the
        // seam margins, all measured at once, and 0 with nothing folded.
        let folded_extra = f64::from(top.allocation().y());
        let want = row_position(scene, id, index, &band);
        if let Some(want) = want.map(|w| w + folded_extra) {
            if (adjustment.value() - want).abs() > 0.5 {
                programmatic.set(true);
                adjustment.set_value(want);
                programmatic.set(false);
            }
        }
    }
    let value = adjustment.value();
    let page = adjustment.page_size().max(f64::from(body.height()));

    // The band's rows, in band order, with the boxes this tier gave them.
    let rows: Vec<(f64, f64)> = children_of(&content)
        .into_iter()
        .filter(|w| {
            !w.has_css_class(TABLE_SPACER_CLASS) && !w.has_css_class(KAYA_FOLDED_CLASS)
        })
        .map(|w| {
            let allocation = w.allocation();
            (f64::from(allocation.y()), f64::from(allocation.height()))
        })
        .collect();

    // THE VERIFY HALF (§2.2), reported only where this tier's extent
    // DISAGREES with what the core already holds — exactly, no tolerance,
    // which is also what stops this loop repeating. A row's extent is its
    // PITCH: its own box plus the gap the content box lays out after it.
    let mut heights = Vec::new();
    for (_, height) in &rows {
        if *height <= 0.0 {
            break;
        }
        heights.push(*height + spacing);
    }
    if !heights.is_empty() {
        let moved = crate::fault::guard("reading a row's extent", || {
            heights
                .iter()
                .enumerate()
                .any(|(i, h)| scene.row_extent(id, band.first + i) != *h)
        });
        if moved == Some(true) {
            crate::fault::guard("reporting measured row heights", || {
                scene.rows_measured(id, band.first, &heights);
            });
        }
    }

    let laid_out = rows.iter().any(|(_, height)| *height > 0.0);
    // THE PASS THAT MEASURES DERIVES FROM WHAT IT MEASURED (2026-09-01,
    // docs/traps.md's wayland resize entry, the table sibling):
    // `band` was read before the rows were, so the first laid-out pass
    // used to derive count 0 from an extent of 0 and leave the page to
    // whichever relayout signal came next — and under matrix load that
    // signal did not come for 15s. The extent is re-read here instead.
    let extent = if heights.is_empty() {
        band.extent
    } else {
        crate::fault::guard("reading a window's geometry", || scene.window_geometry(id).extent)
            .unwrap_or(band.extent)
    };
    let average = if total > 0 && extent > 0.0 {
        extent / total as f64
    } else {
        0.0
    };
    let count = if average > 0.0 && page > 0.0 {
        ((page / average).ceil() as usize).max(1)
    } else {
        0
    };
    let first = if !laid_out {
        // Nothing drawn yet: the honest answer is where we already said
        // we were, and the band's own rule keeps one row realized so
        // there is something to measure next pass. The FIRST report of a
        // For's life is this one, and (0, 0) is what narrows the
        // unbounded band before anything measures a box holding every
        // row of the collection.
        last.map_or(0, |(first, _)| first)
    } else {
        let top_edge = rows[0].0;
        let bottom_edge = rows[rows.len() - 1].0 + rows[rows.len() - 1].1;
        if value + 0.5 < top_edge || value + 0.5 >= bottom_edge {
            // The scrollbar jumped clean past the band — the reader's own
            // route on a long collection. Step from the band's own edge by
            // the mean pitch; the next pass reads real rows, and on the
            // exact path this is already the answer.
            let step = |gap: f64| {
                if average > 0.0 {
                    (gap / average).floor().max(0.0) as usize
                } else {
                    0
                }
            };
            if value < top_edge {
                band.first.saturating_sub(step(top_edge - value).max(1))
            } else {
                let past = band.first + rows.len() + step(value - bottom_edge);
                past.min(total.saturating_sub(1))
            }
        } else {
            rows.iter()
                .position(|(y, height)| y + height > value + 0.5)
                .map_or(band.first, |i| band.first + i)
        }
    };

    // The same WATCH's instrument for a table: EVERY pass with the
    // inputs it derived the range from, and whether the range moved.
    let sent = last != Some((first, count));
    eprintln!(
        "KAYA_DIAG window_report for={id} first={first} count={count} page={page:.1} \
         average={average:.1} total={total} laid_out={laid_out} value={value:.1} \
         rows={} sent={sent}",
        rows.len()
    );
    if sent {
        let scene = &mut core.scene;
        let ops = crate::fault::guard("reporting a window range", || {
            scene.window_moved(id, first, count)
        });
        if let Some(table) = core.tables.get_mut(&id) {
            table.reported = Some((first, count));
        }
        for op in ops.unwrap_or_default() {
            apply(core, op);
        }
    }

    // THE SPACERS, sized by the core and by nothing here. The content
    // box lays a gap between the top spacer and the band's first row, so
    // the spacer is the band's offset LESS that gap and the first row's
    // own top lands exactly on the core's position for it.
    let scene = &mut core.scene;
    let settled = crate::fault::guard("reading a window's geometry", || {
        let band = scene.window_geometry(id);
        let mut realized = 0.0;
        for index in band.first..(band.first + band.count) {
            realized += scene.row_extent(id, index);
        }
        (band, realized)
    });
    if let Some((band, realized)) = settled {
        let above = (band.offset - spacing).max(0.0);
        let below = (band.extent - band.offset - realized).max(0.0);
        eprintln!(
            "KAYA_DIAG spacers for={id} above={above:.1} below={below:.1} \
             extent={:.1} realized={realized:.1}",
            band.extent
        );
        set_spacer(&top, band.first > 0 && above > 0.5, above);
        set_spacer(&bottom, below > 0.5, below);
        set_table_scrolling(&body, grown || band.extent > f64::from(TABLE_MAX_CONTENT));
    }
    (first, total)
}

/// A TABLE HUGS WHAT IT HOLDS (docs/deferred.md's viewport-floor entry).
/// A VERTICAL SCROLLBAR'S OWN MINIMUM IS THE FLOOR — 58px on the lane's GTK,
/// folded into `GtkScrolledWindow`'s own minimum wherever the policy may show
/// a bar, so a one-row table was allocated 58px (measured 2026-08-25,
/// docs/traps.md). The policy IS the toolkit's way to say "this does not
/// scroll"; a GROWN table keeps AUTOMATIC, since its parent's track decides.
fn set_table_scrolling(body: &gtk4::ScrolledWindow, scrolls: bool) {
    let want = if scrolls {
        gtk4::PolicyType::Automatic
    } else {
        gtk4::PolicyType::Never
    };
    // Written only when it moved: this runs on every scroll frame. The
    // horizontal half is the overflow ruling's and is not this function's
    // to decide, so it goes back exactly as read.
    if body.policy().1 != want {
        body.set_policy(body.policy().0, want);
    }
}

/// One navigation entry: a pushed scene root, retained while covered
/// (the widget refs here keep it alive), destroyed at pop.
struct GtkNavEntry {
    window: u64,
    title: String,
    /// The close-veto class transplanted to POP.
    intercept_back: bool,
    root: Option<gtk4::Widget>,
}

/// One section's materialized state: the stack page's container Box
/// (the mount target), its title, its own mounted root, and the
/// hosting window.
struct GtkSectionPage {
    window: u64,
    page: gtk4::Box,
    title: String,
    /// The semantic icon's wire value (0 = none), held so the page's
    /// `icon-name` survives a chrome rebuild. Not an observation: the harness
    /// reads the switcher's own GtkImage.
    symbol: i64,
    root: Option<gtk4::Widget>,
}

struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    widgets: HashMap<WidgetId, NativeWidget>,
    // Per-kind registries in creation order (stamped copies included): the
    // harness names targets as kind#index.
    buttons: Vec<gtk4::Button>,
    checkboxes: Vec<gtk4::CheckButton>,
    labels: Vec<gtk4::Label>,
    /// Every tagged widget's occurrence tag (the on_click_node encoding:
    /// the template node and the copy's key path), by widget id — what a
    /// `kind@id[key.path]` target resolves through for every tagged kind,
    /// not the table's sort tag alone (docs/deferred.md, the keyed-target
    /// entry, 2026-09-01).
    widget_tags: HashMap<u64, Vec<u8>>,
    entries: Vec<gtk4::Entry>,
    sliders: Vec<gtk4::Scale>,
    images: Vec<gtk4::Picture>,
    /// The canvases, and their CORE ids beside them: `canvas_probe` asks
    /// the core about a widget id, and `kind#index` is the only address
    /// the harness has (the `column_ids` shape).
    canvases: Vec<KayaCanvas>,
    canvas_ids: Vec<WidgetId>,
    /// Whether this window's frame clock is attached — the canvas track
    /// reader and the frame drive (`attach_canvas_clock`). ONE per
    /// window, so it is a flag rather than a handle per canvas.
    canvas_clock: bool,
    scrolls: Vec<gtk4::ScrolledWindow>,
    progresses: Vec<gtk4::ProgressBar>,
    selects: Vec<gtk4::DropDown>,
    radios: Vec<gtk4::Box>,
    grids: Vec<gtk4::Grid>,
    textareas: Vec<gtk4::TextView>,
    /// Grid layout state: ordered children + column count. Children can
    /// arrive BEFORE the columns prop (children-first sugars), so both paths
    /// re-flow the attach positions.
    grid_children: HashMap<u64, Vec<gtk4::Widget>>,
    grid_cols: HashMap<u64, i32>,
    /// Radio plumbing, the select_options shape: label id -> (its
    /// radio's id, its row); the row's REAL widget is the grouped
    /// CheckButton in radio_buttons.
    radio_options: HashMap<u64, (u64, u32)>,
    radio_buttons: HashMap<u64, Vec<gtk4::CheckButton>>,
    radio_tags: HashMap<u64, Vec<u8>>,
    /// Option-label plumbing: label widget id -> (its select's id, its option
    /// row). A select's label children are OPTIONS — rows of the DropDown's
    /// StringList — so they leave the harness's label registry.
    select_options: HashMap<u64, (u64, u32)>,
    /// The AUTHORED accessible name per widget: GtkLabel (and the
    /// caption kinds) re-derive their accessible label from every text
    /// write, so a `text` that lands after `a11y_label` clobbered the
    /// authored name — measured 2026-09-02 on the a11y scene's OCaml leg,
    /// whose constructor sets the props before the text. The text arms
    /// re-apply it from here.
    a11y_labels: HashMap<u64, String>,
    /// The DropDown's string model per select id (rows appended at
    /// AddChild; text arrives via the label's SetProp).
    select_models: HashMap<u64, gtk4::StringList>,
    /// Echo guard for EVERY interactive kind: GTK's change signals cannot
    /// tell a user act from a programmatic write, and only the USER path may
    /// emit. Armed around every SetProp write and the select's model appends
    /// (GTK auto-selects row 0 when the first item lands); commands and the
    /// stage's direct writes stay unguarded ON PURPOSE.
    apply_quiet: std::rc::Rc<std::cell::Cell<bool>>,
    /// Q2's bracket, spelled GTK (docs/undo-plan.md §3): while this is set a
    /// text change still EMITS but is NOT banked, because this backend routed
    /// the undo and reports it through `note_native_undo`.
    ///
    /// A FLAG AND NOT THE MAC ARM'S TEXT-MATCHED ECHO: GTK's `changed` fires
    /// SYNCHRONOUSLY inside the undo activation (measured).
    ledger_quiet: std::rc::Rc<std::cell::Cell<bool>>,
    /// A4's answer for the ENTRY, which GTK gives no getter for: the text
    /// widgets whose NATIVE undo stack has something in it. A GtkTextBuffer
    /// publishes `can-undo`; the GtkText behind a GtkEntry publishes nothing
    /// and its muxer is private (measured: `activate_action("text.undo")`
    /// answers TRUE on an empty history), so the model is kept here — only
    /// input and a programmatic write move that stack.
    native_dirty: std::rc::Rc<RefCell<std::collections::HashSet<u64>>>,
    /// D2 SPELLED GTK: per textarea, the text its declared highlight set was
    /// validated against (docs/ranges-plan.md D2); membership IS the
    /// "declared" flag. A GtkTextTag range is anchored to the TEXT — typing
    /// three characters ahead of a tagged range MOVES it (measured) — so the
    /// set is dropped the moment the recorded text stops being the buffer's.
    highlight_text: std::rc::Rc<RefCell<HashMap<u64, String>>>,
    /// The LIVE input-method preedit per textarea, off GTK's own
    /// `GtkTextView::preedit-changed`. It answers the D4 question and is the
    /// second half of the `selection` read: GTK renders the preedit out of
    /// the LAYOUT and never puts it in the buffer (measured — `char_count`
    /// stayed at 4 with a live preedit).
    preedit: std::rc::Rc<RefCell<HashMap<u64, String>>>,
    /// Indeterminate bars pulse on a shared ticker (GTK's activity mode is
    /// pulse-driven, not a property); membership here IS the flag the
    /// observation reads.
    indeterminate: std::rc::Rc<RefCell<std::collections::HashSet<u64>>>,
    columns: Vec<gtk4::Box>,
    #[cfg(feature = "harness")]
    column_ids: Vec<WidgetId>,
    rows: Vec<gtk4::Box>,
    /// The declared tables, by For-container id (see GtkTable).
    tables: HashMap<u64, GtkTable>,
    /// The stacked fold's memory (D7): folded child id -> its table's id,
    /// kept because the unfold op carries table 0 and the widget must go
    /// back before the table it came out of.
    folded_into: HashMap<u64, u64>,
    window: gtk4::Window,
    /// Auxiliary surfaces by kaya window id (the primary is
    /// `window`); created hidden, presented at mount.
    aux_windows: HashMap<u64, gtk4::Window>,
    /// veto_close per window id (primary included; default false).
    window_veto: std::rc::Rc<RefCell<HashMap<u64, bool>>>,
    /// Live navigation entries by surface id, and per-window stacks bottom
    /// to top (DESIGN.md, Navigation).
    nav_entries: HashMap<u64, GtkNavEntry>,
    nav_stacks: HashMap<u64, Vec<u64>>,
    /// The declared pane CEILING per window (wprop 6;
    /// docs/multicolumn-plan.md D2): how many side-by-side stack
    /// surfaces this window asks for. How many it GETS is GNOME's
    /// answer, resolved in refresh_nav's breakpoints.
    panes: HashMap<u64, i64>,
    /// The presentation refresh_nav ACTUALLY rendered, per window — stamped
    /// by the arm that ran, never derived from the ceiling or the width.
    split_presentation: HashMap<u64, &'static str>,
    /// The live AdwNavigationSplitView per window. It answers whether it
    /// collapsed, the only honest reading once GNOME owns that decision.
    split_views: HashMap<u64, adw::NavigationSplitView>,
    /// The INNER split view at a ceiling of three — the nested pair is
    /// the three-pane construct (the priority IS the nesting), and the
    /// panes reading needs both views' four booleans at once.
    inner_splits: HashMap<u64, adw::NavigationSplitView>,
    /// Sections (DESIGN.md, Sections): per-window ordered sets, page
    /// containers by section id, the GtkStack that materializes the switcher,
    /// and the selection mirror. A section's page swaps between its own root
    /// and its stack's top entry.
    sections: HashMap<u64, Vec<u64>>,
    section_pages: HashMap<u64, GtkSectionPage>,
    section_stacks: HashMap<u64, gtk4::Stack>,
    /// The assembled chrome per window: (presentation it was built
    /// for, the container) — rebuilt only when the hint changes.
    section_chrome: HashMap<u64, (i64, gtk4::Box)>,
    /// The arm that ACTUALLY assembled that chrome, per window — stamped
    /// inside each branch of refresh_sections, never derived from the hint.
    sections_rendered: HashMap<u64, &'static str>,
    selected_sections: HashMap<u64, u64>,
    sections_presentation: HashMap<u64, i64>,
    /// The window's OWN mounted root and title, restored on pop.
    window_roots: HashMap<u64, gtk4::Widget>,
    window_titles: HashMap<u64, String>,
    /// The windows whose title the APP wrote, as opposed to the one this
    /// backend built its primary with (docs/app-identity-plan.md I9): the
    /// primary's placeholder "kaya milestone 2" would otherwise be
    /// indistinguishable from a title an app chose.
    app_titled: std::collections::HashSet<u64>,
    /// The app's declared identity NAME (docs/app-identity-plan.md I9): a
    /// window's DEFAULT caption, filling the blank and never overriding one.
    identity_name: Option<String>,
    /// WHAT THIS PROCESS DID WITH THE DECLARED ICON BLOB — not what the
    /// platform holds, which is the read's job. The two together tell "kaya
    /// never set an icon" from "kaya set one and it did not survive"
    /// (docs/app-identity-plan.md I8).
    identity_icon: IdentityIcon,
    /// The windows whose `GdkToplevel` was handed the icon list — a record of
    /// calls this process made, stated as such wherever it is printed, since
    /// no GDK call reads it back.
    identity_icon_on: BTreeSet<u64>,
    /// THE WINDOW'S SHELL, one per window (docs/chrome-plan.md C2): the
    /// AdwToolbarView that IS the window's child, the AdwHeaderBar it carries
    /// as its top bar, and the box inside that header holding the promoted
    /// actions. `window_content`/`set_window_content` route through it.
    toolbar_views: HashMap<u64, adw::ToolbarView>,
    header_bars: HashMap<u64, adw::HeaderBar>,
    /// The promotion group: one box packed into the header after the back
    /// button, holding one button per promoted catalog action. MEASURED
    /// (2026-08-17, the lane image): a button inside this box is allocated
    /// 34x34 on a 40px pitch and carries the `image-button` class,
    /// pixel-identical to one packed directly into the header.
    toolbar_groups: HashMap<u64, gtk4::Box>,
    /// The header-bar back button per window, visible only while the window's
    /// stack has entries.
    back_buttons: HashMap<u64, gtk4::Button>,
    /// The unsaved-work marker per window — the bullet label beside the
    /// header-bar title (install_nav_chrome), shown exactly while `dirty` is
    /// true. THE WIDGET IS THE STATE: there is deliberately no `dirty` map
    /// beside it, and the read goes to the accessibility tree.
    dirty_markers: HashMap<u64, gtk4::Label>,
    /// The window content inset (wprop 8, docs/styling-plan.md D3): the value
    /// behind the `.kaya-root` CSS padding, kept because TWO consumers need
    /// the number and the stylesheet cannot be read back.
    inset: f64,
    /// The provider holding the `.kaya-root` padding, kept to rewrite
    /// when the inset moves.
    inset_css: gtk4::CssProvider,
    /// A CONTAINER's own inset (prop 17): its own provider, one
    /// `kaya-inset-N` rule per distinct value, and the set those rules cover.
    /// Separate from `inset_css`, which the window arm rewrites whole.
    container_inset_css: gtk4::CssProvider,
    container_insets: BTreeSet<i64>,
    /// THE BRAND ACCENT (docs/styling-plan.md D1): its own provider —
    /// separate from `inset_css`, which the inset arm rewrites whole — and
    /// the derived values, since the stylesheet holds ONE appearance's
    /// numbers at a time. Shared with the `dark` notify handler, hence Rc.
    brand: Rc<RefCell<Option<crate::brand::BrandAccent>>>,
    brand_css: gtk4::CssProvider,
    /// THE BRAND TYPEFACE (docs/styling-plan.md Slice 2b). ITS OWN PROVIDER,
    /// and never `brand_css`: that one is rewritten from scratch by the
    /// appearance notify handler, so a `font-family` parked there would vanish
    /// the first time the session flipped light/dark, with no error anywhere.
    typeface_css: gtk4::CssProvider,
    /// The family THIS platform asked for (the `linux` row of the request, or
    /// its default), kept because the read needs BOTH numbers: a resolved
    /// family that is not the request means either "the rule applied and
    /// fontconfig has no such family" or "the rule never reached the widget".
    typeface_request: Option<String>,
    /// The last typeface diagnosis this process printed. `expect_typeface`
    /// polls for 15 seconds at 20ms, so an undeduplicated one would bury the
    /// failing verdict under ~750 identical lines.
    #[cfg(feature = "harness")]
    typeface_said: RefCell<Option<String>>,
    /// Where kaya's own stylesheets report their parse errors, read by
    /// `load_kaya_css` immediately after each load.
    css_error: Rc<RefCell<Option<String>>>,
    /// The live modal alert (one per process): the request's identity plus
    /// the REAL dialog object for the runner's reads.
    live_alert: std::rc::Rc<RefCell<Option<GtkLiveAlert>>>,
    /// The live file picker, and the directory the next one opens on. THE
    /// DIRECTORY IS ARMED, NOT SET: a dialog's initial folder is read when it
    /// is PRESENTED, so the harness's file_dialog_goto stores it here and the
    /// apply arm applies it. Setting it on a dialog already on screen is
    /// silently ignored.
    live_file_dialog: std::rc::Rc<RefCell<Option<GtkLiveFileDialog>>>,
    pending_dialog_dir: std::rc::Rc<RefCell<Option<String>>>,
    /// The command-catalog registry (DESIGN.md, Menus). Rc'd so the
    /// GSimpleAction handlers reach the mirror without borrowing CORE.
    menus: Rc<RefCell<MenuRegistry>>,
    /// The GMenu model per window — what the PopoverMenuBar renders and
    /// menu_count reads; rebuilt in place on catalog mutations.
    menu_models: HashMap<u64, gio::Menu>,
    /// The bar strip per window: (strip, content slot). Present only
    /// once a catalog anchored; set_window_content routes through it.
    menu_strips: HashMap<u64, (gtk4::Box, gtk4::Box)>,
    /// Auxiliary windows' "win"-prefixed action groups (the primary is
    /// a GtkApplicationWindow and exports "win" itself).
    menu_action_groups: HashMap<u64, gio::SimpleActionGroup>,
    /// Context attachments by anchor widget id.
    context_menus: HashMap<u64, GtkContextMenu>,
    /// The OPEN context menu's anchor, cleared by activation or chrome
    /// dismissal. While set it owns path resolution EXCLUSIVELY. Rc'd: the
    /// popover's closed handler clears it without borrowing CORE.
    open_context: Rc<RefCell<Option<u64>>>,
    /// EVERY TOUCH OF THE CLAIM ABOVE, so that a failure can say what cleared
    /// it and when: menus-java-wayland flaked once with `no such menu item
    /// Remove`, eighty-six attempts to reproduce it failed and two mechanisms
    /// were DISPROVED, so the next occurrence has to answer the question
    /// itself — five places touch the claim and the panic prints the trail.
    #[cfg(feature = "harness")]
    context_trail: Rc<RefCell<Vec<(std::time::Instant, &'static str, Option<u64>)>>>,
    /// The clipboard hub (see ClipboardHub). Rc'd to reach it without
    /// borrowing CORE.
    clipboard: Rc<ClipboardHub>,
    // None when attached... not yet on GTK; the app quits the loop.
    app: Option<gtk4::Application>,
}

impl Drop for CoreState {
    fn drop(&mut self) {
        self.occurrences.send(Occurrence::Shutdown);
    }
}

thread_local! {
    static CORE: RefCell<Option<CoreState>> = const { RefCell::new(None) };
}

static EXIT_CODE: AtomicI32 = AtomicI32::new(0);

/// Wake the main loop so it drains pending transactions. Safe to call
/// from any thread; the idle source carries no data.
pub(crate) fn ring_doorbell() {
    glib::idle_add(|| {
        drain_transactions();
        glib::ControlFlow::Break
    });
}

fn drain_transactions() {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        // THE UNWIND STOPS HERE: a glib idle source is a C callback, so
        // a panic out of `Scene::apply`'s app-misuse assertions aborts
        // rather than reddening the leg (crates/kaya/src/fault.rs).
        crate::fault::guard("draining a transaction", || {
            while let Ok(tx) = core.transactions.try_recv() {
                for op in core.scene.apply(tx) {
                    apply(core, op);
                }
                // A canvas that became a redraw one with its track
                // already known (docs/canvas-plan.md §3.2.1) — the ask the
                // track report itself cannot make, because the policy
                // arrived after the geometry did.
                for occ in core.scene.take_asks() {
                    core.occurrences.send(occ);
                }
            }
            // A transaction can be an undo GROUP, and a group is a ledger
            // entry: Edit>Undo's enablement moved with it.
            refresh_roles(core);
            // THE BAND IS NARROWED BEFORE ANYTHING MEASURES IT. Every For
            // starts under the unbounded band (the plan's §1 bridge), so
            // the batch that declares a 15,000-row table stamps all of it;
            // reporting HERE — inside the same idle, before GTK has laid
            // anything out and before the size groups below are re-tied —
            // is what keeps the O(cells^2) reflow and the toplevel's size
            // negotiation off the whole collection.
            let tables: Vec<u64> = core.tables.keys().copied().collect();
            for id in &tables {
                window_report(core, *id);
            }
            // The rows a declared table is made of arrive, move and leave
            // in ops of their own, so the table is reconciled once the
            // batch has landed rather than inside any one of them.
            for id in tables {
                reflow_table(core, id);
            }
            // AND THE PRESENTATION, so the first canvas of the first
            // transaction rasters at this display's real density
            // (docs/canvas-plan.md §5). The realize hook and the two
            // notifies carry every LATER change; this is the belt that
            // does not depend on which of them ran first. An unchanged
            // report emits no op.
            presentation_report(core);
        });
    });
}

/// The live file dialog: what the harness needs to find it in the
/// accessibility tree. The TITLE is the handle — GTK publishes it as
/// `role=dialog name=<title>` and sets no accessible-id (docs/traps.md).
#[derive(Clone)]
struct GtkLiveFileDialog {
    title: String,
}

struct GtkLiveAlert {
    id: u64,
    window: u64,
    actions: usize,
    /// Button labels in presentation order (actions first, cancel
    /// last) — how choose_alert names the button to press.
    labels: Vec<String>,
    dialog: gtk4::AlertDialog,
}

/// Depth-first search for a button with the given label under a widget:
/// gtk::AlertDialog exposes no press API.
fn find_button(widget: &gtk4::Widget, label: &str) -> Option<gtk4::Button> {
    use gtk4::prelude::{ButtonExt, Cast, WidgetExt};
    if let Ok(button) = widget.clone().downcast::<gtk4::Button>() {
        if button.label().as_deref() == Some(label) {
            return Some(button);
        }
    }
    let mut child = widget.first_child();
    while let Some(c) = child {
        if let Some(found) = find_button(&c, label) {
            return Some(found);
        }
        child = c.next_sibling();
    }
    None
}

fn wire_close(
    window: &gtk4::Window,
    id: u64,
    veto: std::rc::Rc<RefCell<HashMap<u64, bool>>>,
    sink: OccSink,
) {
    use gtk4::glib;
    use gtk4::prelude::GtkWindowExt;
    window.connect_close_request(move |_| {
        if veto.borrow().get(&id).copied().unwrap_or(false) {
            sink.send(Occurrence::CloseRequested {
                window: WindowId(id),
            });
            return glib::Propagation::Stop;
        }
        if id != 0 {
            sink.send(Occurrence::WindowClosed {
                window: WindowId(id),
            });
        }
        glib::Propagation::Proceed
    });
}

/// Every window this process is really holding, for the sentences below. A
/// resolver miss prints WHAT IT SAW — an id that never appears is a typo;
/// one that appears a moment later was a race.
fn live_windows(core: &CoreState) -> String {
    let mut ids: Vec<u64> = std::iter::once(0).chain(core.aux_windows.keys().copied()).collect();
    ids.sort_unstable();
    ids.iter()
        .map(|id| format!("#{id}"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// What a read answers for a window this process does not hold. No title,
/// size class or presentation can equal it, so the harness keeps polling
/// and prints this sentence at the deadline.
#[cfg(feature = "harness")]
fn not_materialized(core: &CoreState, window: u64) -> String {
    format!(
        "<window#{window} is not materialized; live windows: {}>",
        live_windows(core)
    )
}

/// The OBSERVATION flavor, and the one every Stage read must use: a window
/// that is not in the map yet is a MISS, never a panic. Materialization is
/// asynchronous and the harness polls to a deadline; panicking here killed
/// five language legs on linux and two on windows (measured 2026-08-16), and
/// on GTK a panic inside a main-context closure cannot unwind, so the process
/// ABORTS and the harness reports `RecvError`.
fn gtk_window_read(core: &CoreState, id: u64) -> Option<gtk4::Window> {
    if id == 0 {
        Some(core.window.clone())
    } else {
        core.aux_windows.get(&id).cloned()
    }
}

/// The APPLY flavor: same lookup, but a miss is a bug and says so. THE
/// `&mut CoreState` IS THE WALL — `apply` is the only path that holds one,
/// and every Stage observation runs through `on_main`, which hands out
/// `&CoreState`, so a read cannot reach this panic even by writing the wrong
/// resolver name.
fn gtk_window(core: &mut CoreState, id: u64) -> gtk4::Window {
    match gtk_window_read(core, id) {
        Some(window) => window,
        // The list is built only on the failure path: this runs on
        // every reconcile.
        None => panic!(
            "kaya: an apply targeted window#{id}, which this process does \
             not hold (live windows: {}). Applies are ordered — the create \
             reaches this backend before anything that names the window — \
             so this is a core-side ordering bug, not a race.",
            live_windows(core)
        ),
    }
}

/// What this process did with the declared icon blob
/// (docs/app-identity-plan.md I4a). Three states and not two: "the app
/// declared nothing", "the decoder refused the bytes" and "a texture went to
/// the toplevels" all look identical from outside, and the second is the
/// silent fallback this scene exists to catch.
#[cfg_attr(not(feature = "harness"), allow(dead_code))]
enum IdentityIcon {
    /// No identity with an icon has reached this backend.
    Undeclared,
    /// The blob decoded, and the texture every toplevel is handed. Kept for
    /// the WHOLE process lifetime: a window created later gets the same one.
    Texture(gtk4::gdk::Texture),
    /// GDK's own decoder refused the bytes. The platform's own icon stays in
    /// place — only the platform's decoder can answer — and the read says so
    /// rather than reporting a default as a success.
    Refused { bytes: usize, why: String },
}

impl IdentityIcon {
    /// One clause, in this process's own words, for every sentence the icon
    /// read can print. It states what KAYA DID, never what the platform
    /// holds, so the toplevel count is a count of CALLS MADE.
    #[cfg(feature = "harness")]
    fn lowering(&self, on: &BTreeSet<u64>) -> String {
        let windows = || {
            on.iter().map(|id| format!("#{id}")).collect::<Vec<_>>().join(", ")
        };
        match self {
            Self::Undeclared => {
                "kaya set no icon here: no app identity carrying icon bytes reached \
                 this backend"
                    .to_owned()
            }
            Self::Refused { bytes, why } => format!(
                "kaya set no icon here: GDK's own decoder refused the declared {bytes} \
                 bytes ({why}), so the platform's own icon was left in place"
            ),
            Self::Texture(texture) => {
                use gtk4::prelude::TextureExt;
                if on.is_empty() {
                    format!(
                        "kaya decoded the declared blob to a {}x{} texture and handed it \
                         to NO toplevel — every window was still unrealized when the \
                         identity arrived and none has been presented since",
                        texture.width(),
                        texture.height(),
                    )
                } else {
                    format!(
                        "kaya decoded the declared blob to a {}x{} texture and called \
                         gdk_toplevel_set_icon_list with it on window {} (that call \
                         returns nothing and GDK reads no icon back, so this clause is \
                         a record of what this process did, not of what the platform \
                         kept)",
                        texture.width(),
                        texture.height(),
                        windows(),
                    )
                }
            }
        }
    }
}

/// Hand the declared mark to one window's `GdkToplevel`
/// (docs/app-identity-plan.md I4a). STRAIGHT TO `gdk_toplevel_set_icon_list`,
/// never through a NAME: the name-based calls carry two measured traps
/// (docs/app-identity-plan.md), and `gtk_window_set_icon` is gone in GTK4.
/// NO `#[cfg]`: GTK 4.20 feeds this identical list into xdg-toplevel-icon-v1.
/// A window with no surface is not an error — GTK realizes lazily.
fn apply_identity_icon(core: &mut CoreState, window: u64) {
    use gtk4::prelude::{Cast, NativeExt};
    let IdentityIcon::Texture(texture) = &core.identity_icon else {
        return;
    };
    let texture = texture.clone();
    let Some(target) = gtk_window_read(core, window) else {
        return;
    };
    let Some(surface) = target.surface() else {
        return;
    };
    let Ok(toplevel) = surface.dynamic_cast::<gtk4::gdk::Toplevel>() else {
        return;
    };
    toplevel.set_icon_list(std::slice::from_ref(&texture));
    core.identity_icon_on.insert(window);
}

/// What a re-class did to ONE window, in this process's own words. Four
/// outcomes and not two (invariant 3): the class moved, there was no surface
/// yet, this display has no route, the route refused. Only the last two are
/// failures.
enum ClassMove {
    /// `XSetClassHint` wrote `WM_CLASS` on this window's xid.
    X11,
    /// `xdg_toplevel.set_app_id` was sent for this window's toplevel.
    Wayland,
    /// The window has no `GdkSurface` yet, which is NOT a miss: GDK writes
    /// the class at surface creation from `g_get_prgname()`, which this same
    /// apply has already moved.
    Unrealized,
    /// Neither an X11 nor a Wayland surface (Broadway is the live example).
    /// The class stays whatever the launcher gave it and no `.desktop` entry
    /// can match this window.
    NoRoute { display: String, surface: String },
}

/// Move EXISTING toplevels' class to the app's declared name
/// (docs/app-identity-plan.md I9; docs/deferred.md's `g_set_prgname` entry
/// carries the measurements). `g_set_prgname` reaches only surfaces NOT YET
/// CREATED, and this backend presents its primary before the first
/// transaction drains. TWO PROTOCOLS, TWO ROUTES: Wayland has a GDK call,
/// X11 does not and `WM_CLASS` is ICCCM `STRING`, so that arm goes to Xlib.
fn reclass_toplevels(core: &CoreState, name: &str) -> Vec<(u64, ClassMove)> {
    let live: Vec<u64> = std::iter::once(0).chain(core.aux_windows.keys().copied()).collect();
    live.into_iter()
        .filter_map(|id| gtk_window_read(core, id).map(|window| (id, window)))
        .map(|(id, window)| {
            use gtk4::prelude::NativeExt;
            let Some(surface) = window.surface() else {
                return (id, ClassMove::Unrealized);
            };
            (id, reclass_surface(&surface, name))
        })
        .collect()
}

/// One surface, whichever protocol it turns out to be sitting on. THE
/// PROTOCOL IS READ OFF THE OBJECT, never off `GDK_BACKEND`: the environment
/// variable is a REQUEST and which backend GDK opened is the fact. A failed
/// downcast is the `NoRoute` sentence, naming both types.
fn reclass_surface(surface: &gtk4::gdk::Surface, name: &str) -> ClassMove {
    use gtk4::glib::prelude::{Cast, ObjectExt};

    if let Ok(toplevel) = surface.clone().downcast::<gdk4_wayland::WaylandToplevel>() {
        toplevel.set_application_id(name);
        return ClassMove::Wayland;
    }

    let x11_surface = surface.clone().downcast::<gdk4_x11::X11Surface>();
    let x11_display = surface.display().downcast::<gdk4_x11::X11Display>();
    if let (Ok(x11_surface), Ok(x11_display)) = (x11_surface, x11_display) {
// The Xlib entry points are dlopen'd rather than linked: that is
// gdk4-x11's own `xlib` feature, so the `Display` pointer `xdisplay()`
// hands back and the one `XSetClassHint` wants are the SAME type by
// construction.
        let xlib = match x11_dl::xlib::Xlib::open() {
            Ok(xlib) => xlib,
            Err(why) => {
                return ClassMove::NoRoute {
                    display: format!("GdkX11Display, but libX11 could not be opened: {why}"),
                    surface: x11_surface.type_().name().to_string(),
                };
            }
        };
        // A NUL in the middle would make Xlib see a shorter name than
        // the app declared, so the name is refused rather than truncated
        // — the class a desktop matches on is not a place to guess.
        let Ok(class) = std::ffi::CString::new(name) else {
            return ClassMove::NoRoute {
                display: "GdkX11Display, but the declared name contains a NUL byte and \
                          WM_CLASS is two NUL-TERMINATED words"
                    .to_owned(),
                surface: x11_surface.type_().name().to_string(),
            };
        };
        let mut hint = x11_dl::xlib::XClassHint {
            res_name: class.as_ptr().cast_mut(),
            res_class: class.as_ptr().cast_mut(),
        };
// SAFETY: `xdisplay()` is the display GDK opened and lives as long as
// the GdkX11Display; `xid()` is that surface's window on it; `hint`
// outlives the call and Xlib only reads it. The flush is required:
// this runs inside an apply, and the property would otherwise sit in
// GDK's output buffer until the next frame.
        unsafe {
            let xdisplay = x11_display.xdisplay();
            (xlib.XSetClassHint)(xdisplay, x11_surface.xid(), &mut hint);
            (xlib.XFlush)(xdisplay);
        }
        return ClassMove::X11;
    }

    ClassMove::NoRoute {
        display: surface.display().type_().name().to_string(),
        surface: surface.type_().name().to_string(),
    }
}

/// The re-class, in one sentence per outcome, and WHO SEES IT. The failure
/// branch is printed by every build: an app whose windows cannot carry its
/// declared class will never group under its `.desktop` entry and nothing
/// else says so. The success branch is a harness-only record, and it is what
/// the linux legs grep for.
fn report_class_moves(moves: &[(u64, ClassMove)], name: &str) {
    let listed = |want: fn(&ClassMove) -> bool| {
        moves
            .iter()
            .filter(|(_, how)| want(how))
            .map(|(id, _)| format!("#{id}"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    for (id, how) in moves {
        if let ClassMove::NoRoute { display, surface } = how {
            kaya_diag!(
                "KAYA_DIAG app identity: window#{id} keeps the class its launcher gave \
                 it — kaya has no route to move a class on this display ({display}, \
                 surface {surface}), so no .desktop entry naming \"{name}\" can match \
                 this window"
            );
        }
    }
    #[cfg(feature = "harness")]
    {
        let x11 = listed(|how| matches!(how, ClassMove::X11));
        let wayland = listed(|how| matches!(how, ClassMove::Wayland));
        let later = listed(|how| matches!(how, ClassMove::Unrealized));
// THE FOURTH BUCKET IS COUNTED HERE TOO. Without it the four outcomes
// shared three clauses, so a run where EVERY window took the no-route
// branch printed "this app holds no window at all" — false on the one
// path a reader would be reading it (invariant 3).
        let stuck = listed(|how| matches!(how, ClassMove::NoRoute { .. }));
        let mut clauses = Vec::new();
        if !x11.is_empty() {
            clauses.push(format!("XSetClassHint rewrote WM_CLASS on window {x11}"));
        }
        if !wayland.is_empty() {
            clauses.push(format!("xdg_toplevel.set_app_id was sent for window {wayland}"));
        }
        if !later.is_empty() {
            clauses.push(format!(
                "window {later} had no surface yet, so GDK writes the class at realize \
                 from the program name this apply already moved"
            ));
        }
        if !stuck.is_empty() {
            clauses.push(format!(
                "window {stuck} kept the class its launcher gave it, this display \
                 having no route (see the line above)"
            ));
        }
        if clauses.is_empty() {
            clauses.push("this app holds no window at all".to_owned());
        }
        kaya_diag!(
            "KAYA_DIAG app identity: class -> \"{name}\": {} (that call returns nothing \
             and GDK reads no class back, so this clause is a record of what this \
             process did, not of what the server holds)",
            clauses.join("; ")
        );
    }
    #[cfg(not(feature = "harness"))]
    let _ = listed;
}

/// The caption a window falls back to when it declares none of its own — the
/// app's declared NAME, or nothing (docs/app-identity-plan.md I9). It fills
/// the blank and NEVER overrides a window's own title, and it is keyed on
/// `app_titled` rather than on an empty GTK title string because this backend
/// builds its primary with a placeholder before any transaction exists.
fn identity_caption(core: &CoreState, window: u64) -> Option<String> {
    if core.app_titled.contains(&window) {
        return None;
    }
    core.identity_name.clone()
}

/// What this PROCESS can say about the app icon, gathered under the main
/// context so the read itself needs no GTK (docs/app-identity-plan.md I8).
/// Everything below this struct talks to the X SERVER through `xprop`, which
/// takes tens of milliseconds and is polled — holding the main context
/// across a subprocess would stall the app being read.
#[cfg(feature = "harness")]
struct IdentityProbe {
    /// The GDK display object's own GType name. MEASURED, not derived from
    /// `GDK_BACKEND`: the environment variable is a request, and which
    /// backend GDK actually opened is the fact.
    backend: String,
    /// The GTK this process is RUNNING against, not the one it was compiled
    /// with: the wayland icon route is version-shaped.
    gtk: String,
    /// What this process did with the declared blob, in its own words
    /// (`IdentityIcon::lowering`).
    lowering: String,
    /// How many of this process's windows were handed the icon list. The read
    /// holds the SERVER's count against this one — carriers agreeing with
    /// each other cannot catch a lowering that reached only some windows.
    applied: usize,
}

#[cfg(feature = "harness")]
fn identity_probe(core: &CoreState) -> IdentityProbe {
    use gtk4::glib::prelude::ObjectExt;
    IdentityProbe {
        backend: gtk4::gdk::Display::default().map_or_else(
            || "<no GdkDisplay is open in this process>".to_owned(),
            |display| display.type_().name().to_string(),
        ),
        gtk: format!(
            "{}.{}.{}",
            gtk4::major_version(),
            gtk4::minor_version(),
            gtk4::micro_version()
        ),
        lowering: core.identity_icon.lowering(&core.identity_icon_on),
        applied: core.identity_icon_on.len(),
    }
}

/// Run one of the X11 command-line tools and hand back its output, or a
/// sentence describing exactly how it failed. EVERY FAILURE MODE IS A
/// DIFFERENT SENTENCE: the tool missing from the image is not the tool
/// refusing the window, and neither is "no such property".
#[cfg(feature = "harness")]
fn x11_tool(program: &str, args: &[&str]) -> Result<String, String> {
    match std::process::Command::new(program).args(args).output() {
        Ok(out) if out.status.success() => {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        }
        Ok(out) => Err(format!(
            "`{program} {}` failed ({}): {}",
            args.join(" "),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        )),
        Err(why) => Err(format!(
            "`{program}` could not be run at all ({why}) — x11-utils is what \
             carries it, and without it this read cannot ask the X server \
             anything"
        )),
    }
}

/// Every toplevel on this display, as `(window id, name)`. THE SEARCH IS THE
/// PRICE OF HAVING NO WINDOW MANAGER: `_NET_CLIENT_LIST` is written by one
/// and the lane runs none, so the root's direct children ARE the toplevels
/// and `xwininfo -root -children` lists them. Each X11 leg owns its own Xvfb.
#[cfg(feature = "harness")]
fn x11_toplevels() -> Result<Vec<(String, String)>, String> {
    let listing = x11_tool("xwininfo", &["-root", "-children"])?;
    let mut out = Vec::new();
    for line in listing.lines() {
        let line = line.trim();
        if !line.starts_with("0x") {
            continue;
        }
        let Some(id) = line.split_whitespace().next() else {
            continue;
        };
        // `0x600007 "identity": ("identity" "Identity")  480x360+0+0`
        // — the window's name is the first quoted run, and a window
        // with none says so in words.
        let name = line
            .split_once('"')
            .and_then(|(_, rest)| rest.split_once('"'))
            .map_or_else(
                || {
                    if line.contains("has no name") {
                        "(has no name)".to_owned()
                    } else {
                        "(unnamed)".to_owned()
                    }
                },
                |(name, _)| name.to_owned(),
            );
        out.push((id.to_owned(), name));
    }
    Ok(out)
}

/// One toplevel's `_NET_WM_ICON`, as the CARDINALs the X server is holding.
/// `32c` FORCES THE FORMAT: without it xprop pretty-prints the property as
/// `Icon (64 x 64)` plus an ASCII rendering, which says nothing about colour.
/// Asking for 32-bit cardinals prints width, height, then one ARGB word per
/// pixel — EWMH's own layout.
#[cfg(feature = "harness")]
fn x11_icon_property(id: &str) -> Result<Vec<u32>, String> {
    let text = x11_tool("xprop", &["-id", id, "-notype", "32c", " $0+", "_NET_WM_ICON"])?;
    if text.contains("not found") {
        return Err("_NET_WM_ICON: not found (this window carries no icon property)".to_owned());
    }
    let mut values = Vec::new();
    let mut digits = String::new();
    for ch in text.chars() {
        if ch.is_ascii_digit() {
            digits.push(ch);
        } else if !digits.is_empty() {
            values.push(digits.parse::<u64>().unwrap_or(0) as u32);
            digits.clear();
        }
    }
    if !digits.is_empty() {
        values.push(digits.parse::<u64>().unwrap_or(0) as u32);
    }
    if values.is_empty() {
        return Err(format!(
            "_NET_WM_ICON is present but xprop printed no numbers for it: {:?}",
            text.trim()
        ));
    }
    Ok(values)
}

/// The four quadrant CENTRES of an `_NET_WM_ICON` property,
/// `RRGGBB/RRGGBB/RRGGBB/RRGGBB` in reading order — the same string the WinUI
/// arm produces from an HICON, because the scene compares it byte-for-byte
/// across every platform. CENTRES AND NOT CORNERS: any rescale between the
/// declared PNG and the size a platform rasterizes at blurs a quadrant
/// BOUNDARY, and a corner sample sits on one.
#[cfg(feature = "harness")]
fn x11_icon_quadrants(values: &[u32]) -> Result<String, String> {
    if values.len() < 3 {
        return Err(format!(
            "_NET_WM_ICON holds {} words, too few to be an icon (EWMH's layout \
             is width, height, then one ARGB word per pixel)",
            values.len()
        ));
    }
    let (w, h) = (values[0] as usize, values[1] as usize);
    let pixels = &values[2..];
    if w < 2 || h < 2 || pixels.len() < w * h {
        return Err(format!(
            "_NET_WM_ICON says {w}x{h} and carries {} words after the two size \
             words, which is not that picture",
            pixels.len()
        ));
    }
    let sample = |qx: usize, qy: usize| {
        let x = (w * (1 + 2 * qx) / 4).min(w - 1);
        let y = (h * (1 + 2 * qy) / 4).min(h - 1);
        // EWMH stores ARGB in a 32-bit CARDINAL, rows top to bottom.
        format!("{:06X}", pixels[y * w + x] & 0x00FF_FFFF)
    };
    Ok(format!(
        "{}/{}/{}/{}",
        sample(0, 0),
        sample(1, 0),
        sample(0, 1),
        sample(1, 1)
    ))
}

/// THE PICTURE THE PLATFORM ENDED UP HOLDING, in pixels
/// (docs/app-identity-plan.md I8). Reading GTK back is an ECHO and GDK offers
/// no read-back for an icon LIST at all, so `xprop -id <xid> _NET_WM_ICON`
/// asks the X SERVER and these four samples prove the CONVERSION. Every
/// failure path says what it MEASURED (invariant 3).
#[cfg(feature = "harness")]
fn read_app_icon(probe: &IdentityProbe) -> String {
    let IdentityProbe { backend, gtk, lowering, applied } = probe;
    if !backend.contains("X11") {
// THE MEASURED ABSENCE, never a skip and never a bare "none". Every
// varying part of this sentence is something this process went and read.
        return format!(
            "<no icon read on this display: GDK's display object here is \
             {backend}, and the one route that reports an app icon back to the \
             process that set it is the X server's own _NET_WM_ICON, which needs \
             an X11 display. {lowering}. This process runs GTK {gtk}; on wayland \
             the icon travels as xdg-toplevel-icon-v1, which GTK lowers from 4.20 \
             onward and which has no request that reads an icon back to a client \
             — so on this display there is nothing to ask, and the mark this \
             scene asserts is measured on the X11 ring>"
        );
    }
    let toplevels = match x11_toplevels() {
        Ok(found) => found,
        Err(why) => {
            return format!(
                "<the X11 icon read could not list this display's toplevels: \
                 {why}. {lowering}>"
            )
        }
    };
    if toplevels.is_empty() {
        return format!(
            "<this X11 display's root has no children at all, so no window this \
             process opened is mapped yet. {lowering}>"
        );
    }
    let mut carried: Vec<(String, String, String)> = Vec::new();
    let mut bare: Vec<String> = Vec::new();
    for (id, name) in &toplevels {
        match x11_icon_property(id).and_then(|values| x11_icon_quadrants(&values)) {
            Ok(samples) => carried.push((id.clone(), name.clone(), samples)),
            Err(why) => bare.push(format!("{id} {name:?} answered {why}")),
        }
    }
    if carried.is_empty() {
        return format!(
            "<no _NET_WM_ICON on any of this display's {} toplevels: {}. {lowering}>",
            toplevels.len(),
            bare.join("; ")
        );
    }
    let first = carried[0].2.clone();
    if carried.iter().any(|(_, _, samples)| *samples != first) {
// ONE APP, ONE MARK: two of this process's windows wearing different
// pictures is a lowering that reached some toplevels and not others,
// and the sentence names which is which rather than picking a winner.
        return format!(
            "<this app's toplevels carry DIFFERENT icons: {}. {lowering}>",
            carried
                .iter()
                .map(|(id, name, samples)| format!("{id} {name:?} = {samples}"))
                .collect::<Vec<_>>()
                .join("; ")
        );
    }
    // ...AND ON EVERY WINDOW THIS PROCESS SET: a lowering that reached the
    // primary and not the second window agrees with itself perfectly.
    //
    // AGAINST THE APPLY COUNT AND NOT THE TOPLEVEL COUNT, measured: an
    // identity leg's X11 root has THREE named children for two kaya windows
    // in the lane image — GTK keeps an unmapped window of its own carrying
    // the same WM_CLASS.
    if carried.len() < *applied {
        return format!(
            "<the mark is on {} of this app's toplevels but this process set it on \
             {applied} windows, so a window lost it or never got it: {}. {lowering}>",
            carried.len(),
            carried
                .iter()
                .map(|(id, name, samples)| format!("{id} {name:?} = {samples}"))
                .collect::<Vec<_>>()
                .join("; ")
        );
    }
    first
}

/// Install the window's chrome: an AdwHeaderBar carrying GTK's back
/// affordance and the unsaved-work marker beside the title. THE MARKER IS THE
/// `dirty` PROP'S WHOLE LOWERING HERE (docs/dirty-plan.md D2) — GTK4 has no
/// window-level modified affordance, so kaya draws GNOME Text Editor's shape,
/// with an accessible label because a bare bullet publishes as `name='• '`.
/// The empty invisible titlebar is GTK 4's CSD switch (docs/chrome-plan.md C2).
fn install_nav_chrome(window: &gtk4::Window, id: u64) -> WindowChrome {
    use gtk4::prelude::{ButtonExt, GtkWindowExt, ObjectExt, WidgetExt};
    let header = adw::HeaderBar::new();
    let back = gtk4::Button::from_icon_name("go-previous-symbolic");
    back.set_visible(false);
    back.connect_clicked(move |_| {
        CORE.with_borrow_mut(|core| {
            let Some(core) = core.as_mut() else { return };
            user_back(core, id);
        });
    });
    header.pack_start(&back);
// The promotion group, packed once and refilled by refresh_toolbar. 6px is
// libadwaita's own spacing inside a header bar.
    let promoted = gtk4::Box::new(gtk4::Orientation::Horizontal, 6);
    header.pack_start(&promoted);

    let marker = gtk4::Label::new(Some(DIRTY_MARKER));
    marker.set_visible(false);
    marker.update_property(&[gtk4::accessible::Property::Label(DIRTY_MARKER_NAME)]);
    let title = gtk4::Label::new(None);
    // The style class GtkHeaderBar puts on its own title label, so the
    // typography does not change by taking the slot over.
    title.add_css_class("title");
    window
        .bind_property("title", &title, "label")
        .sync_create()
        .build();
// A CenterBox and not a plain Box, which is GNOME's own trick: the marker
// EXPANDS into the space left of the title and hugs its trailing edge, so
// it does not move the title. With a Box the title stepped 7px right the
// moment the mark went up.
    let title_box = gtk4::CenterBox::new();
    title_box.set_hexpand(true);
    marker.set_hexpand(true);
    marker.set_halign(gtk4::Align::End);
    marker.set_margin_end(6);
    title_box.set_start_widget(Some(&marker));
    title_box.set_center_widget(Some(&title));
    header.set_title_widget(Some(&title_box));

    let view = adw::ToolbarView::new();
    {
        // NOT set_top_bar_style: FLAT is the constructor default
        // (docs/chrome-plan.md's GTK row). A backend that SET the default
        // would be writing down a decision it does not make.
        view.add_top_bar(&header);
    }
    // The CSD switch (see this function's doc): an invisible titlebar
    // widget, which is what AdwApplicationWindow installs internally.
    let csd = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    csd.set_visible(false);
    window.set_titlebar(Some(&csd));
    window.set_child(Some(&view));
    WindowChrome { view, header, promoted, back, marker }
}

/// One window's shell, handed back by [`install_nav_chrome`] so the caller
/// can put the pieces in CoreState.
struct WindowChrome {
    view: adw::ToolbarView,
    header: adw::HeaderBar,
    promoted: gtk4::Box,
    back: gtk4::Button,
    marker: gtk4::Label,
}

/// The glyph GNOME's own editor draws for unsaved work, and the name the
/// accessibility tree publishes in its place. The NAME is what the harness
/// matches on; neither string is ever compared across platforms.
const DIRTY_MARKER: &str = "\u{2022}";
const DIRTY_MARKER_NAME: &str = "Unsaved changes";

/// A user-driven back on the window's top entry: an intercept_back-armed top
/// emits back_requested and nothing pops; an unarmed top pops here,
/// reconciles the core-owned stack post-fact, and reports entry_popped.
fn user_back(core: &mut CoreState, window: u64) {
    // With sections present, back routes to the ACTIVE section's
    // stack — back never switches sections (DESIGN.md, Sections).
    let window = if core.sections.contains_key(&window) {
        core.selected_sections.get(&window).copied().unwrap_or(window)
    } else {
        window
    };
    let Some(&top) = core.nav_stacks.get(&window).and_then(|s| s.last()) else {
        return;
    };
    if core.nav_entries[&top].intercept_back {
        core.occurrences.send(Occurrence::BackRequested {
            entry: WindowId(top),
        });
        return;
    }
    core.nav_stacks.get_mut(&window).unwrap().pop();
    core.nav_entries.remove(&top);
    core.scene.user_popped(WindowId(top));
    refresh_nav(core, window);
    core.occurrences.send(Occurrence::EntryPopped {
        entry: WindowId(top),
    });
}

/// Reconcile the window's visible state with its stack: the top entry's root
/// and title (the entry title IS the window title while covered), or the
/// The visible stack positions at a ceiling of three, read from BOTH
/// views' four booleans in one pass (a composite recomputed from any
/// single notify names a state that is legal at some other width) plus
/// slot occupancy — an empty slot is a visible column but not a pane
/// (docs/multicolumn-plan.md D1/D4). None when no three-pane pair is up.
fn three_pane_positions(core: &CoreState, window: u64) -> Option<Vec<u64>> {
    let outer = core.split_views.get(&window)?;
    let inner = core.inner_splits.get(&window)?;
    let entries = core.nav_stacks.get(&window).map_or(0, |s| s.len()) as u64;
    let inner_positions = |v: &mut Vec<u64>| {
        if inner.is_collapsed() {
            if inner.shows_content() {
                if entries >= 2 {
                    v.push(entries);
                }
            } else if entries >= 1 {
                v.push(1);
            }
        } else {
            if entries >= 1 {
                v.push(1);
            }
            if entries >= 2 {
                v.push(entries);
            }
        }
    };
    let mut positions = Vec::new();
    if outer.is_collapsed() {
        if outer.shows_content() {
            inner_positions(&mut positions);
        } else {
            positions.push(0);
        }
    } else {
        positions.push(0);
        inner_positions(&mut positions);
    }
    Some(positions)
}

/// The back affordance at a ceiling of three: visible exactly when
/// popping the top would REVEAL a covered surface into a visible slot —
/// the surface beneath the top is not on screen. The same rule the mac
/// detail column's chevron computes for itself (its stack is non-empty
/// exactly then), so the affordance is uniform across the platforms.
fn three_pane_back_visible(core: &CoreState, window: u64) -> bool {
    let entries = core.nav_stacks.get(&window).map_or(0, |s| s.len()) as u64;
    if entries == 0 {
        return false;
    }
    match three_pane_positions(core, window) {
        Some(positions) => !positions.contains(&(entries - 1)),
        None => false,
    }
}

/// The ceiling-3 arm: pane 0 the base root, pane 1 the first entry, the
/// trailing pane the REST of the stack's top — two nested
/// AdwNavigationSplitViews, the inner in the OUTER'S CONTENT slot. The
/// nesting IS the priority: collapsing the outer sheds the SHALLOWEST pane
/// first, which is the collapsed prefix-stack (docs/multicolumn-plan.md D3).
/// Returns false when the window has no root yet.
fn refresh_three_panes(core: &mut CoreState, window: u64, target: &gtk4::Window) -> bool {
    use adw::prelude::*;
    use gtk4::prelude::{Cast, GtkWindowExt, WidgetExt};
    let Some(base) = core.window_roots.get(&window).cloned() else {
        return false;
    };
    let entries = core.nav_stacks.get(&window).cloned().unwrap_or_default();
    let first = entries.first().copied();
    let deep_top = if entries.len() >= 2 { entries.last().copied() } else { None };

    let inner = adw::NavigationSplitView::new();
    if let Some(entry) = first.and_then(|id| core.nav_entries.get(&id)) {
        if let Some(root) = entry.root.clone() {
            unparent(&root);
            let page = adw::NavigationPage::builder()
                .child(&root)
                .title(entry.title.clone())
                .tag("middle")
                .build();
            inner.set_sidebar(Some(&page));
        }
    }
    if let Some(entry) = deep_top.and_then(|id| core.nav_entries.get(&id)) {
        if let Some(root) = entry.root.clone() {
            unparent(&root);
            let page = adw::NavigationPage::builder()
                .child(&root)
                .title(entry.title.clone())
                .tag("detail")
                .build();
            inner.set_content(Some(&page));
        }
    }
    // show-content on each view is the ONE stack fact it is told —
    // measured: it defaults false, and a collapsed view then stands on
    // its sidebar whatever the stack says.
    inner.set_show_content(deep_top.is_some());

    let outer = adw::NavigationSplitView::new();
    unparent(&base);
    let list = adw::NavigationPage::builder()
        .child(&base)
        .title(core.window_titles.get(&window).cloned().unwrap_or_default())
        .tag("list")
        .build();
    outer.set_sidebar(Some(&list));
    let inner_page = adw::NavigationPage::builder()
        .child(&inner)
        .title(
            first
                .and_then(|id| core.nav_entries.get(&id))
                .map(|e| e.title.clone())
                .unwrap_or_default(),
        )
        .tag("inner")
        .build();
    outer.set_content(Some(&inner_page));
    outer.set_show_content(!entries.is_empty());

    // THE RUNG TABLE, widest first, from GNOME's own documented
    // thresholds. Each rung's setter set is the UNION of itself and
    // every wider rung BY CONSTRUCTION (the accumulating loop):
    // libadwaita applies exactly ONE breakpoint and resets unapplied
    // setters, so a non-cumulative list shows two panes at phone width
    // with no warning. This shape makes that list inexpressible.
    let bin = adw::BreakpointBin::builder()
        .width_request(1)
        .height_request(1)
        .child(&outer)
        .build();
    let rungs: [(&str, &adw::NavigationSplitView); 2] =
        [("max-width: 860sp", &outer), ("max-width: 500sp", &inner)];
    let mut cumulative: Vec<&adw::NavigationSplitView> = Vec::new();
    for (condition, view) in &rungs {
        cumulative.push(view);
        if let Ok(condition) = adw::BreakpointCondition::parse(condition) {
            let breakpoint = adw::Breakpoint::new(condition);
            for view in &cumulative {
                breakpoint.add_setter(*view, "collapsed", Some(&true.to_value()));
            }
            bin.add_breakpoint(breakpoint);
        }
    }

    // The user's back, caught where libadwaita reports it, one view at
    // a time. Each guard names the ONLY stack depth at which that
    // view's group-back is a pop of kaya's stack — the rebuild's own
    // set_show_content(false) writes arrive at other depths and must
    // not pop (the two-pane arm's rule, one view deeper).
    inner.connect_show_content_notify(move |view| {
        if view.shows_content() {
            return;
        }
        glib::idle_add_local_once(move || {
            CORE.with_borrow_mut(|core| {
                let Some(core) = core.as_mut() else { return };
                if core.nav_stacks.get(&window).is_some_and(|s| s.len() >= 2) {
                    user_back(core, window);
                }
            });
        });
    });
    outer.connect_show_content_notify(move |view| {
        if view.shows_content() {
            return;
        }
        glib::idle_add_local_once(move || {
            CORE.with_borrow_mut(|core| {
                let Some(core) = core.as_mut() else { return };
                if core.nav_stacks.get(&window).is_some_and(|s| s.len() == 1) {
                    user_back(core, window);
                }
            });
        });
    });

    // THE BACK AFFORDANCE FOLLOWS THE LADDER: recomputed from all four
    // booleans on an idle after any of them moves (a breakpoint applies
    // during allocation, and CORE may be borrowed by the apply that
    // caused it — the two-pane arm's timing, doubled).
    let refresh_back = move || {
        glib::idle_add_local_once(move || {
            CORE.with_borrow_mut(|core| {
                let Some(core) = core.as_mut() else { return };
                let visible = three_pane_back_visible(core, window);
                if let Some(back) = core.back_buttons.get(&window) {
                    use gtk4::prelude::WidgetExt;
                    back.set_visible(visible);
                }
            });
        });
    };
    outer.connect_collapsed_notify(move |_| refresh_back());
    inner.connect_collapsed_notify(move |_| refresh_back());

    set_window_content(core, window, Some(bin.upcast_ref::<gtk4::Widget>()));
    // WITH AN EMPTY STACK THE WINDOW KEEPS ITS OWN TITLE, never the
    // empty string (the two-pane arm's rule).
    let title = entries
        .last()
        .and_then(|id| core.nav_entries.get(id))
        .map(|e| e.title.clone())
        .unwrap_or_else(|| core.window_titles.get(&window).cloned().unwrap_or_default());
    target.set_title(Some(&title));
    core.split_views.insert(window, outer);
    core.inner_splits.insert(window, inner);
    let visible = three_pane_back_visible(core, window);
    if let Some(back) = core.back_buttons.get(&window) {
        back.set_visible(visible);
    }
    true
}

/// window's own when the stack is empty; the back button shows only over
/// entries.
fn refresh_nav(core: &mut CoreState, window: u64) {
    use gtk4::prelude::{GtkWindowExt, WidgetExt};
    // A section host reconciles its PAGE, not a window (stacks are
    // per-surface; DESIGN.md, Sections).
    if core.section_pages.contains_key(&window) {
        refresh_section_pane(core, window);
        return;
    }
    let target = gtk_window(core, window);
    let top = core.nav_stacks.get(&window).and_then(|s| s.last()).copied();

// ADAPTIVE PANES (DESIGN.md; docs/multicolumn-plan.md). The app asked
// once (wprop 6, a ceiling); how many panes materialize is GNOME's
// breakpoint answer, never a width kaya tested.
    let ceiling = core.panes.get(&window).copied().unwrap_or(1);
    core.inner_splits.remove(&window);
    if ceiling >= 3 {
        if refresh_three_panes(core, window, &target) {
            return;
        }
    }
    let wants_split = ceiling == 2;
// No `top.is_some()` requirement: an empty stack on a regular window shows
// the leading pane and an EMPTY trailing one (DESIGN.md). No width test
// either — AdwNavigationSplitView collapses on a BREAKPOINT, GNOME's
// documented condition rather than a number kaya invented.
    if wants_split {
        use adw::prelude::*;
        let base = core.window_roots.get(&window).cloned();
        let detail = top.and_then(|id| core.nav_entries.get(&id)).and_then(|e| e.root.clone());
        if let Some(base) = base {
            let split = adw::NavigationSplitView::new();
            unparent(&base);
// The sidebar pane is sized by libadwaita's OWN rule,
// sidebar-width-fraction with min/max, which is where
// protocol::leading_pane_width's 25%/180..280 came from.
            let list = adw::NavigationPage::builder()
                .child(&base)
                .title(core.window_titles.get(&window).cloned().unwrap_or_default())
                .tag("list")
                .build();
            split.set_sidebar(Some(&list));
            if let Some(detail) = &detail {
                unparent(detail);
                let title = top
                    .and_then(|id| core.nav_entries.get(&id))
                    .map(|e| e.title.clone())
                    .unwrap_or_default();
                let page = adw::NavigationPage::builder()
                    .child(detail)
                    .title(title)
                    .tag("detail")
                    .build();
                split.set_content(Some(&page));
            }
// show-content is the ONE stack fact the widget is told: whether a
// detail is open. Everything else stays in kaya's core, which keeps a
// pop and the widget's pop from being two different truths.
            split.set_show_content(top.is_some());

// The COLLAPSE decision, handed to GNOME. AdwNavigationSplitView has
// no default of its own, so kaya supplies the condition from
// libadwaita's own documented example rather than choosing a width. A
// BreakpointBin is what lets a plain GtkApplicationWindow carry one.
            let bin = adw::BreakpointBin::builder()
                .width_request(1)
                .height_request(1)
                .child(&split)
                .build();
            if let Ok(condition) = adw::BreakpointCondition::parse("max-width: 400sp") {
                let breakpoint = adw::Breakpoint::new(condition);
                breakpoint.add_setter(&split, "collapsed", Some(&true.to_value()));
                bin.add_breakpoint(breakpoint);
            }

            // The user's back, caught where libadwaita reports it: a
            // collapsed navigation view's pop sets show-content false,
            // while a resize moves `collapsed` and leaves show-content
            // alone (docs/traps.md).
            split.connect_show_content_notify(move |view| {
                if view.shows_content() {
                    return;
                }
                glib::idle_add_local_once(move || {
                    CORE.with_borrow_mut(|core| {
                        let Some(core) = core.as_mut() else { return };
                        if core.nav_stacks.get(&window).is_some_and(|s| !s.is_empty()) {
                            user_back(core, window);
                        }
                    });
                });
            });

            // THE BACK AFFORDANCE FOLLOWS THE COLLAPSE, driven from here
            // rather than set once below: `collapsed` is the BREAKPOINT's
            // answer and a breakpoint applies during allocation, so at build
            // time `is_collapsed` is still false. Only the button's
            // visibility, never the whole arm: this fires from inside layout.
            split.connect_collapsed_notify(move |view| {
                let collapsed = view.is_collapsed();
                // Deferred, like the handler above: this runs from
                // GTK's layout, and CORE may be borrowed by the apply
                // that caused it.
                glib::idle_add_local_once(move || {
                    CORE.with_borrow_mut(|core| {
                        let Some(core) = core.as_mut() else { return };
                        let covers =
                            core.nav_stacks.get(&window).is_some_and(|s| !s.is_empty());
                        if let Some(back) = core.back_buttons.get(&window) {
                            back.set_visible(collapsed && covers);
                        }
                    });
                });
            });

            set_window_content(core, window, Some(bin.upcast_ref::<gtk4::Widget>()));
// WITH AN EMPTY STACK THE WINDOW KEEPS ITS OWN TITLE, never the empty
// string: on macOS AppKit substitutes the PROCESS NAME for one.
            let title = top
                .and_then(|id| core.nav_entries.get(&id))
                .map(|e| e.title.clone())
                .unwrap_or_else(|| {
                    core.window_titles.get(&window).cloned().unwrap_or_default()
                });
            target.set_title(Some(&title));
            let collapsed = split.is_collapsed();
            core.split_views.insert(window, split);
            // THE SAME RULE THE SERIAL ARM FOLLOWS: a back button exactly
            // where back reveals something, so it is absent with two panes.
            // libadwaita does NOT draw one for these pages (docs/deferred.md
            // — its own button lives inside a header bar IT owns).
            // Best-effort here and authoritative in the notify handler above:
            // nothing is measured yet at build time.
            if let Some(back) = core.back_buttons.get(&window) {
                back.set_visible(collapsed && top.is_some());
            }
            return;
        }
    }
    // The serial arm stamps too: an observation only one arm writes is
    // derived-by-default in the other (docs/traps.md).
    core.split_presentation.insert(window, "stacked");

    match top.and_then(|id| core.nav_entries.get(&id)) {
        Some(entry) => {
            if let Some(root) = entry.root.clone() {
                set_window_content(core, window, Some(&root));
            }
            let title = entry.title.clone();
            target.set_title(Some(&title));
        }
        None => {
            set_window_content(core, window, core.window_roots.get(&window).cloned().as_ref());
            let own = core.window_titles.get(&window).cloned().unwrap_or_default();
            target.set_title(Some(&own));
        }
    }
    if let Some(back) = core.back_buttons.get(&window) {
        back.set_visible(top.is_some());
    }
}

/// Assemble (or reassemble on a hint change) the window's sections chrome: a
/// GtkStack of section pages under the presentation's switcher — the header
/// StackSwitcher for auto/bar, GtkStackSidebar for sidebar. The stack's
/// notify::visible-child is the USER route.
fn refresh_sections(core: &mut CoreState, window: u64) {
    use gtk4::prelude::{BoxExt, Cast, ObjectExt, WidgetExt};
    let ids = core.sections.get(&window).cloned().unwrap_or_default();
    if ids.is_empty() {
        return;
    }
    if !core.section_stacks.contains_key(&window) {
        let stack = gtk4::Stack::new();
        let quiet = core.apply_quiet.clone();
        let occurrences = core.occurrences.clone();
        stack.connect_notify_local(Some("visible-child"), move |st, _| {
            if quiet.get() {
                return;
            }
            let Some(name) = st.visible_child_name() else { return };
            let Ok(sid) = name.as_str().parse::<u64>() else { return };
            let mut changed = false;
            CORE.with_borrow_mut(|core| {
                let Some(core) = core.as_mut() else { return };
                if core.selected_sections.get(&window) == Some(&sid) {
                    return;
                }
                core.selected_sections.insert(window, sid);
                core.scene
                    .user_selected_section(WindowId(window), WindowId(sid));
                changed = true;
            });
            if changed {
                occurrences.send(Occurrence::SectionSelected {
                    window: WindowId(window),
                    section: WindowId(sid),
                });
            }
        });
        core.section_stacks.insert(window, stack);
    }
    let stack = core.section_stacks[&window].clone();
    for sid in &ids {
        let record = &core.section_pages[sid];
        if record.page.parent().is_none() {
            core.apply_quiet.set(true);
            stack.add_titled(&record.page, Some(&sid.to_string()), &record.title);
            core.apply_quiet.set(false);
        }
    }
    let hint = core
        .sections_presentation
        .get(&window)
        .copied()
        .unwrap_or(0);
    let rebuild = !matches!(core.section_chrome.get(&window), Some((h, _)) if *h == hint);
    if rebuild {
        if let Some(parent) = stack.parent() {
            if let Some(container) = parent.downcast_ref::<gtk4::Box>() {
                container.remove(&stack);
            }
        }
        stack.set_hexpand(true);
        stack.set_vexpand(true);
        let chrome = if hint == 2 {
            // sidebar: the leading-edge list spelling.
            let container = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
            let sidebar = gtk4::StackSidebar::new();
            sidebar.set_stack(&stack);
            container.append(&sidebar);
            container.append(&stack);
            // THE ARM STAMPS ITSELF, here and in the peer below: the
            // observation is what RENDERED, so both branches record it
            // and neither reader may consult the hint.
            core.sections_rendered.insert(window, "sidebar");
            container
        } else {
            // auto/bar: the header switcher, GTK's dominant idiom.
            let container = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
            let switcher = gtk4::StackSwitcher::new();
            switcher.set_stack(Some(&stack));
            switcher.set_halign(gtk4::Align::Center);
            container.append(&switcher);
            container.append(&stack);
            core.sections_rendered.insert(window, "bar");
            container
        };
        core.section_chrome.insert(window, (hint, chrome));
    }
    let chrome = core.section_chrome[&window].1.clone();
    set_window_content(core, window, Some(chrome.upcast_ref()));
    if let Some(sel) = core.selected_sections.get(&window).copied() {
        core.apply_quiet.set(true);
        stack.set_visible_child_name(&sel.to_string());
        core.apply_quiet.set(false);
    }
    // A rebuilt GtkStackSwitcher mints fresh buttons, so the accessible
    // descriptions are re-stamped every time, not once at declare time.
    refresh_section_symbols(core, window);
}

/// The sections half of the semantic icon (docs/styling-plan.md D6): each
/// page's `icon-name`, then the switcher's accessible description. TWO
/// MEASURED PLATFORM FACTS — GtkStackSwitcher renders icon OR title, never
/// both, and GtkStackSidebar ignores icon-name entirely (docs/traps.md: "GTK
/// switchers draw a section's symbol or its title"). The DESCRIPTION carries
/// the semantic name; the button's NAME is GTK's own and already the title.
fn refresh_section_symbols(core: &CoreState, window: u64) {
    use gtk4::prelude::{AccessibleExtManual, Cast, WidgetExt};
    let Some(stack) = core.section_stacks.get(&window) else {
        return;
    };
    let ids = core.sections.get(&window).cloned().unwrap_or_default();
    for sid in &ids {
        let Some(record) = core.section_pages.get(sid) else { continue };
        if record.page.parent().is_none() {
            continue;
        }
        let page = stack.page(record.page.upcast_ref::<gtk4::Widget>());
        match symbol_icon_name(record.symbol) {
            Some(icon) => page.set_icon_name(icon),
// 0 (no symbol) and nothing else: the wall already refused any value
// with no row. Cleared through the PROPERTY, not `set_icon_name("")` —
// `rebuild_child` branches on the name being NULL and an empty string
// is not NULL, so that spelling leaves an empty image on the button.
            None => {
                use gtk4::glib::prelude::ObjectExt;
                page.set_property("icon-name", None::<&str>);
            }
        }
    }
// The switcher's buttons are minted from the stack's pages IN PAGE ORDER,
// which is the order sections were added. Only the bar arm has buttons; the
// sidebar arm's rows carry no icon (fact 2 above).
    let Some((_, chrome)) = core.section_chrome.get(&window) else {
        return;
    };
    let mut child = chrome.first_child();
    while let Some(widget) = child {
        if let Some(switcher) = widget.downcast_ref::<gtk4::StackSwitcher>() {
            let mut button = switcher.first_child();
            let mut index = 0usize;
            while let Some(b) = button {
                if let Some(sid) = ids.get(index) {
                    let symbol = core.section_pages.get(sid).map_or(0, |r| r.symbol);
// THE PAIRING IS POSITIONAL, and unlike the menu read this is a
// WRITE — no assertion can catch a description that landed on the
// wrong button. So it is checked against the GtkImage
// GtkStackSwitcher built from the page's icon-name. Debug-only.
                    #[cfg(debug_assertions)]
                    if let Some(want) = symbol_icon_name(symbol) {
                        let got = first_image_icon_name(&b);
                        assert_eq!(
                            got.as_deref(),
                            Some(want),
                            "kaya: switcher button #{index} draws {got:?} while section \
                             {sid} declares {want:?} — the switcher's buttons are no \
                             longer this window's sections in order"
                        );
                    }
                    if let Some(name) = crate::wire::symbol_name(symbol) {
                        b.update_property(&[gtk4::accessible::Property::Description(name)]);
                    }
                }
                index += 1;
                button = b.next_sibling();
            }
        }
        child = widget.next_sibling();
    }
}

/// Reconcile a section page's visible child: its stack's top entry
/// root while covered (stacks are per-surface), its own mounted root
/// otherwise.
fn refresh_section_pane(core: &mut CoreState, sid: u64) {
    use gtk4::prelude::{BoxExt, WidgetExt};
    let Some(record) = core.section_pages.get(&sid) else { return };
    let top = core.nav_stacks.get(&sid).and_then(|s| s.last()).copied();
    let desired = top
        .and_then(|id| core.nav_entries.get(&id))
        .and_then(|e| e.root.clone())
        .or_else(|| record.root.clone());
    let page = record.page.clone();
    while let Some(child) = page.first_child() {
        page.remove(&child);
    }
    if let Some(widget) = desired {
        widget.set_hexpand(true);
        widget.set_vexpand(true);
        page.append(&widget);
    }
}

/// Re-attach a grid's children row-major per its current column count —
/// called when children or the columns prop arrive, in either order.
fn reflow_grid(core: &mut CoreState, grid_id: u64) {
    let Some(NativeWidget::Grid(grid)) = core.widgets.get(&crate::protocol::WidgetId(grid_id))
    else {
        return;
    };
    let cols = core.grid_cols.get(&grid_id).copied().unwrap_or(1).max(1);
    let children = core.grid_children.get(&grid_id).cloned().unwrap_or_default();
    for child in &children {
        if child.parent().is_some() {
            grid.remove(child);
        }
    }
    for (i, child) in children.iter().enumerate() {
        let i = i as i32;
        grid.attach(child, i % cols, i / cols, 1, 1);
    }
}

// --- Menus: the command vocabulary (DESIGN.md, Menus) -----------------
// One GMenu model per window in a PopoverMenuBar strip, every actionable item
// a window-scoped GSimpleAction (`win.kmi-<id>`), a context catalog a
// GtkPopoverMenu whose actions sit in a per-anchor group ("kayactx") so a
// stamped copy's occurrence carries THAT copy's key path. ONE DISPATCH PATH,
// mirroring user state FIRST (docs/traps.md's post-user-mirror rule).

/// One menu item's retained state: the props mirror, the semantic tree, and
/// every live GSimpleAction instance materialized for the item.
struct MenuItemState {
    kind: MenuItemKind,
    label: String,
    /// The item's OWN flag; what chrome and dispatch honor is the AND
    /// of this and every grouping ancestor's (docs/traps.md).
    enabled: bool,
    checked: bool,
    value: f64,
    /// The CHROME-promotion hint (DESIGN.md). `refresh_toolbar` packs them
    /// into the AdwHeaderBar in catalog preorder — all of them, since GTK's
    /// bar has no capacity.
    primary: bool,
    /// The semantic icon's wire value (0 = none). Held ONLY so the GMenu
    /// model can be rebuilt; `Stage::menu_symbol` reads the GIcon off the
    /// realized row instead.
    symbol: i64,
    /// A standard-command role from the closed vocabulary ("" = none).
    /// PLACEMENT is inert here, but the clipboard roles change BEHAVIOR:
    /// activation performs the command on the focused widget, and enablement
    /// folds in role_enabled.
    role: String,
    shortcut: String,
    parent: Option<u64>,
    children: Vec<u64>,
    actions: Vec<gio::SimpleAction>,
}

/// The command-catalog registry. Rc'd so action handlers can reach the
/// mirror without touching CORE.
#[derive(Default)]
struct MenuRegistry {
    items: HashMap<u64, MenuItemState>,
    /// Top-level grouping nodes per window, in menubar-append order.
    bars: HashMap<u64, Vec<u64>>,
    /// Root item id -> the window whose bar holds it.
    bar_of: HashMap<u64, u64>,
    /// Root item id -> every widget carrying a context attachment
    /// rooted at it (a template catalog attaches to every stamped
    /// copy; a live-widget catalog to exactly one).
    context_of: HashMap<u64, Vec<u64>>,
}

/// One widget's context attachment: its own GMenu + popover + action
/// group, and the anchor copy's key path (empty on a live widget).
struct GtkContextMenu {
    roots: Vec<u64>,
    noun: Vec<Value>,
    model: gio::Menu,
    popover: gtk4::PopoverMenu,
    group: gio::SimpleActionGroup,
    /// This attachment's action instances by item id — the ones whose
    /// tags carry this anchor's noun.
    actions: HashMap<u64, gio::SimpleAction>,
}

/// Enablement is the AND of the item's own flag and every grouping
/// ancestor's — the rule every read, render, accel and activation route
/// shares (docs/traps.md).
fn menu_effective_enabled(reg: &MenuRegistry, id: u64) -> bool {
    let mut enabled = true;
    let mut current = Some(id);
    while let Some(item) = current {
        let state = &reg.items[&item];
        enabled = enabled && state.enabled;
        current = state.parent;
    }
    enabled
}

fn menu_root_of(reg: &MenuRegistry, id: u64) -> u64 {
    let mut current = id;
    while let Some(parent) = reg.items[&current].parent {
        current = parent;
    }
    current
}

fn menu_preorder(reg: &MenuRegistry, root: u64) -> Vec<u64> {
    let mut out = Vec::new();
    let mut stack = vec![root];
    while let Some(id) = stack.pop() {
        out.push(id);
        for &child in reg.items[&id].children.iter().rev() {
            stack.push(child);
        }
    }
    out
}

/// Note a touch of the open-context claim. Bounded: an unbounded trail on a
/// long run is a leak.
#[cfg(feature = "harness")]
fn note_claim(
    trail: &Rc<RefCell<Vec<(std::time::Instant, &'static str, Option<u64>)>>>,
    why: &'static str,
    value: Option<u64>,
) {
    let mut trail = trail.borrow_mut();
    if trail.len() == 16 {
        trail.remove(0);
    }
    trail.push((std::time::Instant::now(), why, value));
}

/// The trail as one line per event, newest last, with how long ago each
/// happened — a race is a question about ORDER and INTERVAL.
#[cfg(feature = "harness")]
fn claim_trail(
    trail: &Rc<RefCell<Vec<(std::time::Instant, &'static str, Option<u64>)>>>,
) -> String {
    let now = std::time::Instant::now();
    let trail = trail.borrow();
    if trail.is_empty() {
        return "    (nothing has ever claimed it)".to_owned();
    }
    trail
        .iter()
        .map(|(at, why, value)| {
            format!(
                "    -{:>6}ms  {why} -> {}",
                now.duration_since(*at).as_millis(),
                match value {
                    Some(id) => format!("claimed by widget {id}"),
                    None => "cleared".to_owned(),
                }
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn menu_resolve_path(reg: &MenuRegistry, roots: &[u64], path: &str) -> Option<u64> {
    let mut current: Vec<u64> = roots.to_vec();
    let mut found = None;
    for seg in path.split('>') {
        let id = current
            .iter()
            .copied()
            .find(|id| reg.items[id].label == seg)?;
        found = Some(id);
        current = reg.items[&id].children.clone();
    }
    found
}

/// Push inherited enablement into the REAL actions, so native rendering,
/// native dispatch, accelerators and the harness verbs all gate on one state.
/// Grouping nodes have no GAction of their own — GtkPopoverMenuBarItem binds
/// only `label` — so their reads come from the registry.
fn menu_sync_enabled(reg: &MenuRegistry, id: u64) {
    fn walk(reg: &MenuRegistry, id: u64, inherited: bool) {
        let item = &reg.items[&id];
        let effective = inherited && item.enabled;
        for action in &item.actions {
            action.set_enabled(effective);
        }
        for &child in &item.children {
            walk(reg, child, effective);
        }
    }
    let inherited = reg.items[&id]
        .parent
        .map_or(true, |parent| menu_effective_enabled(reg, parent));
    walk(reg, id, inherited);
}

/// Mirror a radio group's selected index onto every option's action state.
/// A radio row is checked exactly when its action's state equals its target,
/// and every option targets its own index.
fn menu_sync_radio_state(reg: &MenuRegistry, group: u64) {
    use gtk4::glib::prelude::ToVariant;
    let state = (reg.items[&group].value as i32).to_variant();
    for &option in &reg.items[&group].children {
        for action in &reg.items[&option].actions {
            action.set_state(&state);
        }
    }
}

/// Create the GSimpleAction for one item — the shared dispatch path's one
/// entry. `noun` is the anchor's key path (empty for the bar and
/// live-widget anchors).
fn make_menu_action(core: &CoreState, id: u64, noun: &[Value]) -> Option<gio::SimpleAction> {
    use gtk4::glib::prelude::ToVariant;
    let reg = core.menus.borrow();
    let item = &reg.items[&id];
    // GAction names reject underscores; kmi-<id> stays inside the
    // [a-zA-Z0-9.-] floor for every id.
    let name = format!("kmi-{id}");
    debug_assert!(gio::Action::name_is_valid(&name));
    let menus = core.menus.clone();
    let sink = core.occurrences.clone();
    let tag = crate::wire::click_tag(id, noun);
    match item.kind {
        MenuItemKind::Action => {
            let action = gio::SimpleAction::new(&name, None);
            let hub = core.clipboard.clone();
            action.connect_activate(move |_, _| {
// A clipboard role PERFORMS rather than reports: the item is the
// platform's own command acting on the focused widget, so no menu
// occurrence goes up. Read at ACTIVATION time, because the prop lands
// after the action is minted.
                let role = menus.borrow().items[&id].role.clone();
                // An undo is not a clipboard command, so it has its own
                // performer — asked first, the mac arm's order.
                if perform_undo_role(&role) {
                    return;
                }
                if hub.perform_role(&role) {
                    return;
                }
                sink.send_menu_activated_tag(&tag);
            });
            Some(action)
        }
        MenuItemKind::Toggle => {
            let action = gio::SimpleAction::new_stateful(&name, None, &item.checked.to_variant());
            action.connect_activate(move |_, _| {
                // Post-user mirror FIRST (docs/traps.md): the registry and
                // every sibling instance move, then the occurrence goes up.
                let checked = {
                    let mut reg = menus.borrow_mut();
                    let item = reg.items.get_mut(&id).expect("menu items are never removed");
                    item.checked = !item.checked;
                    let checked = item.checked;
                    for action in &item.actions {
                        action.set_state(&checked.to_variant());
                    }
                    checked
                };
                sink.send_menu_toggled_tag(&tag, checked);
            });
            Some(action)
        }
        MenuItemKind::RadioOption => {
// One stateful action PER OPTION, not one per group. GTK takes a
// radio row's sensitivity from its action's enabled flag, which has
// no per-target form, so options sharing one group action could never
// gray individually.
            let group = item.parent.expect("scene validated option parentage");
            let index = reg.items[&group]
                .children
                .iter()
                .position(|option| *option == id)
                .expect("options list under their group") as i32;
            let action = gio::SimpleAction::new_stateful(
                &name,
                Some(gtk4::glib::VariantTy::INT32),
                &(reg.items[&group].value as i32).to_variant(),
            );
            // The occurrence names the GROUP — the choice contract's
            // subject — even though the activated action is the
            // option's.
            let tag = crate::wire::click_tag(group, noun);
            action.connect_activate(move |_, _| {
                // The choice contract: re-selecting the selected option
                // is NOT a change and emits nothing.
                let changed = {
                    let mut reg = menus.borrow_mut();
                    let selectable =
                        reg.items[&group].value as i32 != index && menu_effective_enabled(&reg, id);
                    if selectable {
                        reg.items
                            .get_mut(&group)
                            .expect("menu items are never removed")
                            .value = f64::from(index);
                        menu_sync_radio_state(&reg, group);
                    }
                    selectable
                };
                if changed {
                    sink.send_menu_value_tag(&tag, f64::from(index));
                }
            });
            Some(action)
        }
        MenuItemKind::Menu | MenuItemKind::RadioGroup | MenuItemKind::Separator => None,
    }
}

/// Where a window's own actions live — the read side of
/// [`add_window_action`]: the primary IS a GtkApplicationWindow (its own
/// ActionMap exports "win"), an auxiliary carries the group CreateWindow
/// inserted under the same prefix.
#[cfg(debug_assertions)]
fn action_group_for(core: &CoreState, window: u64) -> Option<gio::SimpleActionGroup> {
    if window == 0 {
        None // the primary's map is the window itself; checked below
    } else {
        core.menu_action_groups.get(&window).cloned()
    }
}

fn add_window_action(core: &CoreState, window: u64, action: &gio::SimpleAction) {
    use gtk4::gio::prelude::ActionMapExt;
    if window == 0 {
        core.window
            .clone()
            .downcast::<gtk4::ApplicationWindow>()
            .expect("the primary window is the ApplicationWindow")
            .add_action(action);
    } else {
        core.menu_action_groups
            .get(&window)
            .expect("scene validated the window id")
            .add_action(action);
    }
}

/// Give every actionable item under `root` its window-scoped
/// GSimpleAction. Items keep exactly one bar instance (single-anchor
/// rule); re-walks after later appends skip the registered ones.
fn register_bar_actions(core: &CoreState, window: u64, root: u64) {
    let ids = {
        let reg = core.menus.borrow();
        menu_preorder(&reg, root)
    };
    for id in ids {
        let registered = !core.menus.borrow().items[&id].actions.is_empty();
        if registered {
            continue;
        }
        let Some(action) = make_menu_action(core, id, &[]) else {
            continue;
        };
        add_window_action(core, window, &action);
        core.menus
            .borrow_mut()
            .items
            .get_mut(&id)
            .expect("menu items are never removed")
            .actions
            .push(action);
    }
    let reg = core.menus.borrow();
    menu_sync_enabled(&reg, root);
}

/// Give every actionable item under `root` an instance in the
/// attachment's own group — the one whose tags carry this anchor's
/// noun (stamped copies each get their own, so the keys ARE the noun).
fn register_context_actions(core: &mut CoreState, widget: u64, root: u64) {
    use gtk4::gio::prelude::ActionMapExt;
    let ids = {
        let reg = core.menus.borrow();
        menu_preorder(&reg, root)
    };
    let noun = core.context_menus[&widget].noun.clone();
    for id in ids {
        if core.context_menus[&widget].actions.contains_key(&id) {
            continue;
        }
        let Some(action) = make_menu_action(core, id, &noun) else {
            continue;
        };
        core.context_menus[&widget].group.add_action(&action);
        core.context_menus
            .get_mut(&widget)
            .expect("attachment exists")
            .actions
            .insert(id, action.clone());
        core.menus
            .borrow_mut()
            .items
            .get_mut(&id)
            .expect("menu items are never removed")
            .actions
            .push(action);
    }
    let reg = core.menus.borrow();
    menu_sync_enabled(&reg, root);
}

fn flush_menu_section(into: &gio::Menu, section: &mut gio::Menu) {
    use gtk4::gio::prelude::MenuModelExt;
    if section.n_items() > 0 {
        into.append_section(None, &*section);
        *section = gio::Menu::new();
    }
}

/// Put the item's semantic icon on a GMenu row. `G_MENU_ATTRIBUTE_ICON` is a
/// SERIALIZED GIcon rather than a name, which is why the themed icon is built
/// here. The attribute reaches the widget and GTK's menu dress then keeps the
/// image HIDDEN, so this arm claims nothing about pixels and NO accessible
/// description is stamped on a menu row (docs/traps.md: "A GMenu row's icon
/// reaches the widget and is never drawn").
fn set_row_symbol(row: &gio::MenuItem, symbol: i64) {
    if symbol == 0 {
        return;
    }
    let Some(icon) = symbol_icon_name(symbol) else {
        // Unreachable in practice: assert_symbol_icons_resolve has already
        // refused the whole process, and that panic names the fix.
        return;
    };
    row.set_icon(&gio::ThemedIcon::new(icon));
}

/// A radio group's option rows: each option carries its OWN stateful action
/// plus its index as target — GMenu renders the radio idiom from exactly
/// that shape, and the per-option action is what lets ONE option gray.
fn append_radio_options(reg: &MenuRegistry, group: u64, prefix: &str, into: &gio::Menu) {
    use gtk4::glib::prelude::ToVariant;
    for (index, &option) in reg.items[&group].children.iter().enumerate() {
        let row = gio::MenuItem::new(Some(&reg.items[&option].label), None);
        row.set_action_and_target_value(
            Some(&format!("{prefix}.kmi-{option}")),
            Some(&(index as i32).to_variant()),
        );
        set_row_symbol(&row, reg.items[&option].symbol);
        into.append_item(&row);
    }
}

/// Materialize a child list into a GMenu: plain leaves accumulate in an
/// anonymous section, a separator starts the next one, a nested menu cascades
/// as a real submenu, and a nested radio group lands INLINE as its own
/// labeled section.
fn build_menu_items(reg: &MenuRegistry, children: &[u64], prefix: &str, into: &gio::Menu) {
    let mut section = gio::Menu::new();
    for &child in children {
        let item = &reg.items[&child];
        match item.kind {
            MenuItemKind::Separator => flush_menu_section(into, &mut section),
            MenuItemKind::Action | MenuItemKind::Toggle => {
                let row = gio::MenuItem::new(
                    Some(&item.label),
                    Some(&format!("{prefix}.kmi-{child}")),
                );
                set_row_symbol(&row, item.symbol);
                section.append_item(&row);
            }
            MenuItemKind::Menu => {
                let submenu = gio::Menu::new();
                build_menu_items(reg, &item.children, prefix, &submenu);
                let row = gio::MenuItem::new_submenu(Some(&item.label), &submenu);
                set_row_symbol(&row, item.symbol);
                section.append_item(&row);
            }
            MenuItemKind::RadioGroup => {
                flush_menu_section(into, &mut section);
                let options = gio::Menu::new();
                append_radio_options(reg, child, prefix, &options);
// A nested radio group lands as a LABELED SECTION, and a GMenu
// section header is not an item — it has no icon attribute to carry a
// symbol on. `Stage::menu_symbol` says exactly that.
                into.append_section(Some(&item.label), &options);
            }
            MenuItemKind::RadioOption => {
                unreachable!("scene validated: options live under radio groups")
            }
        }
    }
    flush_menu_section(into, &mut section);
}

/// Rebuild a window's GMenu from the registry: catalogs are small and GMenu
/// items are immutable snapshots, so a full rebuild is the
/// live-label/topology path. Action state never lives in the model, so a
/// rebuild cannot revert a toggle or radio pick.
fn rebuild_menubar(core: &CoreState, window: u64) {
    let Some(model) = core.menu_models.get(&window) else {
        return;
    };
    {
        let reg = core.menus.borrow();
        model.remove_all();
        for &root in reg.bars.get(&window).map(Vec::as_slice).unwrap_or(&[]) {
            let item = &reg.items[&root];
            let submenu = gio::Menu::new();
            if item.kind == MenuItemKind::RadioGroup {
                // A bar-level radio group IS a top-level menu whose
                // options wear the checkmark idiom.
                append_radio_options(&reg, root, "win", &submenu);
            } else {
                build_menu_items(&reg, &item.children, "win", &submenu);
            }
// A TOP-LEVEL holder gets no icon, measured rather than an omission:
// PopoverMenuBar renders each as a GtkPopoverMenuBarItem binding `label`
// alone — the probe read exactly one GtkLabel and the popover.
            model.append_submenu(Some(&item.label), &submenu);
        }
    }
    assert_model_actions_resolve(core, window, model);
    refresh_menu_accels(core, window);
// The chrome's OTHER half. Promotion is recomputed from the catalog on every
// mutation (DESIGN.md), and a rebuild is where every mutation lands. The
// `primary` prop has its own call, since it moves the promoted set without
// touching the model.
    refresh_toolbar(core, window);
}

/// The promoted actions of a window's catalog, in CATALOG PREORDER. Not a
/// count — see `refresh_toolbar` for why GTK promotes all of them.
fn promoted_items(reg: &MenuRegistry, window: u64) -> Vec<u64> {
    let mut out = Vec::new();
    for &root in reg.bars.get(&window).map(Vec::as_slice).unwrap_or(&[]) {
        for id in menu_preorder(reg, root) {
            let item = &reg.items[&id];
            if item.kind == MenuItemKind::Action && item.primary {
                out.push(id);
            }
        }
    }
    out
}

/// THE PROMOTION (docs/chrome-plan.md C2's GTK row): the window's primary
/// catalog actions as real buttons in its AdwHeaderBar, in catalog preorder,
/// SYMBOL-FIRST per GNOME's HIG. THE ACCESSIBLE LABEL IS EXPLICIT — an
/// icon-only GtkButton with only an action-name publishes `name=''` — and the
/// DESCRIPTION carries the semantic name, which scopes the harness's bus walk.
/// NO CAPACITY: GTK has no k, it just raises the window's minimum width.
fn refresh_toolbar(core: &CoreState, window: u64) {
    use gtk4::prelude::{AccessibleExtManual, ActionableExt, BoxExt, WidgetExt};
    let Some(group) = core.toolbar_groups.get(&window) else {
        return;
    };
    while let Some(child) = group.first_child() {
        group.remove(&child);
    }
    let reg = core.menus.borrow();
    for id in promoted_items(&reg, window) {
        let item = &reg.items[&id];
        let (button, drew) = match symbol_icon_name(item.symbol) {
            Some(icon) => (gtk4::Button::from_icon_name(icon), symbol_name_of_icon(icon)),
            None => (gtk4::Button::with_label(&item.label), None),
        };
        button.set_action_name(Some(&format!("win.kmi-{id}")));
        button.set_tooltip_text(Some(&item.label));
        button.update_property(&[gtk4::accessible::Property::Label(&item.label)]);
// THE DESCRIPTION IS DERIVED FROM THE ICON THAT WAS SET, never from the
// item's symbol field beside it: a marker published for a button that drew
// no icon would scope the harness's bus walk onto a button with nothing to
// read.
        if let Some(name) = drew {
            button.update_property(&[gtk4::accessible::Property::Description(name)]);
        }
        group.append(&button);
    }
    drop(reg);
    warn_if_header_unshrinkable(core, window);
}

/// The unshrinkable-window signal, debug-only and printed only when it has
/// happened: GTK has no overflow at all, so a long promotion list raises the
/// window's MINIMUM width and the window silently stops resizing
/// (docs/chrome-plan.md: ~48px per button, 24 of them -> 1155px). Nothing
/// fails, which is why it says what it measured rather than asserting.
#[cfg(debug_assertions)]
fn warn_if_header_unshrinkable(core: &CoreState, window: u64) {
    use gtk4::prelude::WidgetExt;
    const NARROW: i32 = 1024;
    let Some(header) = core.header_bars.get(&window) else {
        return;
    };
    let (min, _, _, _) = header.measure(gtk4::Orientation::Horizontal, -1);
    if min > NARROW {
        let promoted = core.toolbar_groups.get(&window).map_or(0, |group| {
            let mut n = 0;
            let mut child = group.first_child();
            while let Some(c) = child {
                n += 1;
                child = c.next_sibling();
            }
            n
        });
        eprintln!(
            "kaya: window {window}'s header bar asks for {min}px minimum with \
             {promoted} promoted actions in it — GTK has no overflow, so this \
             window cannot be resized narrower than that"
        );
    }
}

#[cfg(not(debug_assertions))]
fn warn_if_header_unshrinkable(_core: &CoreState, _window: u64) {}

/// Every promoted button the window's REAL header holds, in pack order — a
/// GtkButton anywhere under the AdwHeaderBar whose action names a catalog
/// item (`win.kmi-<id>`). WALKED FROM THE HEADER, never read out of
/// `toolbar_groups`, and the action-name filter is what separates kaya's
/// promotions from the header's other buttons: measured on the real tree,
/// `AdwBackButton` on `navigation.pop`, kaya's own back button on no action
/// at all, and GtkWindowControls on `window.minimize`/`window.close`.
#[cfg(feature = "harness")]
fn chrome_buttons(core: &CoreState, window: u64) -> Vec<(u64, gtk4::Button)> {
    fn walk(node: &gtk4::Widget, out: &mut Vec<(u64, gtk4::Button)>) {
        use gtk4::prelude::{ActionableExt, Cast, WidgetExt};
        let mut child = node.first_child();
        while let Some(w) = child {
            if let Some(button) = w.downcast_ref::<gtk4::Button>() {
                if let Some(name) = button.action_name() {
                    if let Some(id) = name
                        .strip_prefix("win.kmi-")
                        .and_then(|id| id.parse::<u64>().ok())
                    {
                        out.push((id, button.clone()));
                    }
                }
            }
            walk(&w, out);
            child = w.next_sibling();
        }
    }
    use gtk4::prelude::Cast;
    let mut out = Vec::new();
    if let Some(header) = core.header_bars.get(&window) {
        walk(header.upcast_ref::<gtk4::Widget>(), &mut out);
    }
    out
}

/// Where the non-promoted catalog lives in this window, from the closed
/// set the harness contract names — READ, not asserted: the window's real
/// PopoverMenuBar over a model that really has rows.
#[cfg(feature = "harness")]
fn remainder_home(core: &CoreState, window: u64) -> &'static str {
    use gtk4::gio::prelude::MenuModelExt;
    use gtk4::prelude::{Cast, WidgetExt};
    let rows = core.menu_models.get(&window).map_or(0, gio::Menu::n_items);
    let bar = core
        .menu_strips
        .get(&window)
        .and_then(|(strip, _)| strip.first_child())
        .and_then(|child| child.downcast::<gtk4::PopoverMenuBar>().ok());
    match bar {
        Some(bar) if rows > 0 && bar.is_visible() => "menubar",
        _ => "none",
    }
}

/// What to do about an accessibility read that could not reach the bus.
/// The toolbar verbs are TOTAL, so an unreachable bus has to be a sentence
/// rather than a panic, and the sentence names the wiring.
#[cfg(feature = "harness")]
const BUS_FIX: &str = "— a leg asserting the toolbar verbs must run under \
     tools/linux/a11y-leg.sh, since GTK publishes no accessibility tree \
     without GTK_A11Y=atspi and a bus to sit on";


/// Every action a rendered ROW names must exist in the window's action group.
/// GTK draws a row whose action is missing as insensitive — a permanently
/// gray command — while a registry-side read happily reports it enabled, so a
/// typo or a stale name is invisible to a state assertion. Debug-only: a
/// BACKEND invariant, never a guest error.
#[cfg(debug_assertions)]
fn assert_model_actions_resolve(core: &CoreState, window: u64, model: &gio::Menu) {
    use gtk4::gio::prelude::ActionGroupExt;
    use gtk4::prelude::Cast;
    fn walk(core: &CoreState, window: u64, model: &gio::MenuModel) {
        use gtk4::gio::prelude::MenuModelExt;
        for i in 0..model.n_items() {
            if let Some(name) = model
                .item_attribute_value(i, gio::MENU_ATTRIBUTE_ACTION, None)
                .and_then(|v| v.get::<String>())
            {
                let bare = name.strip_prefix("win.").unwrap_or(&name);
                let known = if window == 0 {
                    core.window
                        .clone()
                        .downcast::<gtk4::ApplicationWindow>()
                        .is_ok_and(|w| w.has_action(bare))
                } else {
                    action_group_for(core, window)
                        .is_some_and(|group| group.has_action(bare))
                };
                assert!(
                    known,
                    "kaya: menu row names action {name:?}, which the window's \
                     action group does not hold — GTK would render it \
                     permanently insensitive"
                );
            }
            for link in [gio::MENU_LINK_SUBMENU, gio::MENU_LINK_SECTION] {
                if let Some(child) = model.item_link(i, link) {
                    walk(core, window, &child);
                }
            }
        }
    }
    walk(core, window, model.upcast_ref());
}

#[cfg(not(debug_assertions))]
fn assert_model_actions_resolve(_core: &CoreState, _window: u64, _model: &gio::Menu) {}

/// Every `GtkModelButton` under `root`, in tree order. The rows exist BEFORE
/// the menu is ever opened — measured in the container, `GtkModelButton ...
/// visible=1 mapped=0` inside a popover that is neither — which is what lets
/// the harness read a symbol without popping a menu the scene never opens.
#[cfg(feature = "harness")]
fn collect_model_buttons(root: &gtk4::Widget, out: &mut Vec<gtk4::Widget>) {
    use gtk4::prelude::WidgetExt;
    let mut child = root.first_child();
    while let Some(w) = child {
        if w.type_().name() == "GtkModelButton" {
            out.push(w.clone());
        }
        collect_model_buttons(&w, out);
        child = w.next_sibling();
    }
}

/// A string GObject property, or None when the widget has no such
/// property or holds NULL. Private GTK types are reachable no other way.
#[cfg(feature = "harness")]
fn widget_string_prop(widget: &gtk4::Widget, name: &str) -> Option<String> {
    use gtk4::glib::prelude::ObjectExt;
    if widget.find_property(name).is_none() {
        return None;
    }
    widget.property::<Option<String>>(name)
}

/// The `icon` GObject property (a GIcon), or None.
#[cfg(feature = "harness")]
fn widget_icon_prop(widget: &gtk4::Widget) -> Option<gio::Icon> {
    use gtk4::glib::prelude::ObjectExt;
    if widget.find_property("icon").is_none() {
        return None;
    }
    widget.property::<Option<gio::Icon>>("icon")
}

/// The icon name of the first GtkImage under `root` — what a
/// GtkStackSwitcher button actually draws, which is the only thing on that
/// button that came from the page it stands for.
#[cfg(any(debug_assertions, feature = "harness"))]
fn first_image_icon_name(root: &gtk4::Widget) -> Option<String> {
    use gtk4::prelude::{Cast, WidgetExt};
    let mut child = root.first_child();
    while let Some(w) = child {
        if let Some(image) = w.downcast_ref::<gtk4::Image>() {
            if let Some(name) = image.icon_name() {
                return Some(name.to_string());
            }
        }
        if let Some(found) = first_image_icon_name(&w) {
            return Some(found);
        }
        child = w.next_sibling();
    }
    None
}

/// The text of the first GtkLabel under `root` — how a
/// GtkPopoverMenuBarItem's caption is read, since it publishes no `label`
/// property of its own.
#[cfg(feature = "harness")]
fn first_label_text(root: &gtk4::Widget) -> Option<String> {
    use gtk4::prelude::{Cast, WidgetExt};
    let mut child = root.first_child();
    while let Some(w) = child {
        if let Some(label) = w.downcast_ref::<gtk4::Label>() {
            return Some(label.text().to_string());
        }
        if let Some(found) = first_label_text(&w) {
            return Some(found);
        }
        child = w.next_sibling();
    }
    None
}

/// What the typeface walk found: the families the text system RESOLVED,
/// the CSS-computed requests behind them, and the resolved family keyed
/// by widget type for the disagreement sentence.
#[cfg(feature = "harness")]
#[derive(Default)]
struct TypefaceSeen {
    families: BTreeSet<String>,
    requests: BTreeSet<String>,
    by_class: BTreeSet<String>,
}

/// ONE WIDGET'S TWO FONT NUMBERS: the CSS-computed REQUEST, and the family
/// Pango RESOLVED it to. Both, because a platform may resolve an absent family
/// and an unapplied rule to the same fallback. docs/styling/typeface-gtk.md
/// §2/§3 holds the measured proof; docs/traps.md holds the current lane
/// default. The honest number comes from LOADING the request and asking the
/// FONT what it is.
#[cfg(feature = "harness")]
fn widget_typeface(widget: &gtk4::Widget) -> Option<(String, String)> {
    use gtk4::pango::prelude::{FontExt, FontFaceExt, FontFamilyExt};
    use gtk4::prelude::WidgetExt;
    let ctx = widget.pango_context();
    let request = ctx.font_description()?;
    let font = ctx.load_font(&request)?;
    let described = font.describe().family()?.to_string();
    let resolved = match font.face().map(|face| face.family().name().to_string()) {
        Some(face) if face != described => {
            format!("font and face disagree: {described} vs {face}")
        }
        _ => described,
    };
    Some((request.family().map(|f| f.to_string()).unwrap_or_default(), resolved))
}

/// Every text-bearing widget under the app's windows, read the honest way.
/// THE WIDGETS AND NOT THE MODEL: every font API renders SOMETHING for a
/// family it cannot match, so a read of what kaya asked for would report a
/// perfect swap for a family that was never installed. `.monospace` IS
/// SKIPPED DELIBERATELY — it is the one slot libadwaita's stylesheet claims a
/// family for, and `:root` is chosen so that it keeps it.
#[cfg(feature = "harness")]
fn walk_typefaces(core: &CoreState) -> TypefaceSeen {
    use gtk4::prelude::{Cast, WidgetExt};
    fn walk(widget: &gtk4::Widget, seen: &mut TypefaceSeen) {
        let mut child = widget.first_child();
        while let Some(w) = child {
            let reads_text = w.is::<gtk4::Label>()
                || w.is::<gtk4::Text>()
                || w.is::<gtk4::TextView>()
                || w.is::<gtk4::EditableLabel>();
            if reads_text && !w.has_css_class("monospace") {
                if let Some((request, resolved)) = widget_typeface(&w) {
                    seen.requests.insert(request);
                    seen.by_class.insert(format!("{}={resolved}", w.type_().name()));
                    seen.families.insert(resolved);
                }
            }
            walk(&w, seen);
            child = w.next_sibling();
        }
    }
    let mut seen = TypefaceSeen::default();
// The CONTENT, not the window: a window's own chrome is not the scene's,
// exactly as the mac read walks the content view and not the title bar.
    let ids: Vec<u64> = std::iter::once(0).chain(core.aux_windows.keys().copied()).collect();
    for window in ids {
        if let Some(root) = window_content(core, window) {
            walk(root.upcast_ref::<gtk4::Widget>(), &mut seen);
        }
    }
    seen
}

/// The answer `expect_typeface` compares, and — when it is not the one the
/// app asked for — a diagnosis printed beside it. THE DIAGNOSIS PRINTS ONLY
/// WHAT THIS PROCESS MEASURED: a platform may give more than one cause the
/// same resolved family, so that family is not causal evidence
/// (docs/styling/typeface-gtk.md §3; invariant 3).
#[cfg(feature = "harness")]
fn typeface_verdict(core: &CoreState, seen: &TypefaceSeen) -> String {
    let answer = match seen.families.len() {
// A REAL ANSWER AND NOT AN EMPTY STRING: no text-bearing widget is on
// screen, a different state from a font that failed to apply.
        0 => "no text widget on screen".to_owned(),
        1 => seen.families.iter().next().cloned().unwrap_or_default(),
// Reporting the first would hide a rule that reached one widget and not
// another, so a disagreement is reported AS one, naming each widget type.
        _ => format!(
            "widgets disagree: {}",
            seen.by_class.iter().cloned().collect::<Vec<_>>().join(", ")
        ),
    };
    let Some(asked) = core.typeface_request.as_deref() else {
        // Brandless: the platform's own family is the correct answer and
        // there is nothing to diagnose.
        return answer;
    };
    if answer == asked {
        return answer;
    }
    let css: Vec<String> = seen.requests.iter().cloned().collect();
    let delivered = css.join(", ");
    // EMPTINESS IS TESTED FIRST, and the order is not a style choice:
    // `all()` over an empty set is TRUE, so with this clause second the
    // "nothing was measured" state printed a confident story about
    // fontconfig having no such family — a sentence about a lookup that
    // never happened. Caught by making the branch print (invariant 3).
    let cause = if seen.requests.is_empty() {
        "no text widget was there to be asked — nothing was measured about the rule, \
         and this sentence says only that"
    } else if seen.requests.iter().all(|r| r == asked) {
        "the rule applied and fontconfig has no such family — `fc-match` on this image \
         predicts exactly this substitution, and the platform's ramp stands"
    } else {
        "the :root rule never reached the widget — kaya's typeface provider is not on \
         this display, or a higher-priority sheet (a user's ~/.config/gtk-4.0/gtk.css \
         sits above APPLICATION) overrides it"
    };
    let said = format!(
        "KAYA_DIAG brand typeface: asked {asked:?}, css delivered {delivered:?}, \
         pango resolved {answer:?} — {cause}"
    );
// ONE LINE PER STATE CHANGE. expect_typeface polls for 15 seconds at 20ms,
// and 750 copies of one sentence would bury the verdict it explains.
    let mut last = core.typeface_said.borrow_mut();
    if last.as_deref() != Some(said.as_str()) {
        eprintln!("{said}");
        *last = Some(said);
    }
    answer
}

/// Rebuild one context attachment's model from its root list.
fn rebuild_context(core: &CoreState, widget: u64) {
    let Some(attachment) = core.context_menus.get(&widget) else {
        return;
    };
    let reg = core.menus.borrow();
    attachment.model.remove_all();
    build_menu_items(&reg, &attachment.roots, "kayactx", &attachment.model);
}

/// Rebuild whatever anchors present the tree `id` lives in — the bar
/// and/or every stamped attachment (live labels, live topology).
fn rebuild_menu_anchors(core: &CoreState, id: u64) {
    let (bar, contexts) = {
        let reg = core.menus.borrow();
        let root = menu_root_of(&reg, id);
        (
            reg.bar_of.get(&root).copied(),
            reg.context_of.get(&root).cloned().unwrap_or_default(),
        )
    };
    if let Some(window) = bar {
        rebuild_menubar(core, window);
    }
    for widget in contexts {
        rebuild_context(core, widget);
    }
}

/// The canonical shortcut spelling onto GTK's accelerator syntax:
/// `primary` IS GTK's <Primary>, and named keys map onto their keysym
/// names. Total — the root already rejected everything outside the floor.
fn menu_accel(spelling: &str) -> Option<String> {
    let mut accel = String::new();
    let mut key = None;
    for part in spelling.split('+') {
        match part {
            "primary" => accel.push_str("<Primary>"),
            "shift" => accel.push_str("<Shift>"),
            "alt" => accel.push_str("<Alt>"),
            other => key = Some(other),
        }
    }
    let keysym = match key? {
        "enter" => "Return".to_owned(),
        "escape" => "Escape".to_owned(),
        "delete" => "Delete".to_owned(),
        "left" => "Left".to_owned(),
        "right" => "Right".to_owned(),
        "up" => "Up".to_owned(),
        "down" => "Down".to_owned(),
// The punctuation set onto X keysym names (the canonical spellings
// name UNSHIFTED US positions, which is what these keysyms are).
        "comma" => "comma".to_owned(),
        "period" => "period".to_owned(),
        "slash" => "slash".to_owned(),
        "backslash" => "backslash".to_owned(),
        "minus" => "minus".to_owned(),
        "equal" => "equal".to_owned(),
        "leftbracket" => "bracketleft".to_owned(),
        "rightbracket" => "bracketright".to_owned(),
        f if f.len() > 1 && f.starts_with('f') && f[1..].chars().all(|c| c.is_ascii_digit()) => {
            f.to_uppercase()
        }
        k => k.to_owned(),
    };
    accel.push_str(&keysym);
    Some(accel)
}

/// (Re)register the window catalog's accelerators with the application, so
/// accel display and key dispatch are both native. Item ids are globally
/// unique, so registrations never collide across windows; shortcuts are
/// const-only and items never removed, so nothing needs unregistering.
fn refresh_menu_accels(core: &CoreState, window: u64) {
    let Some(app) = core.app.as_ref() else { return };
    let reg = core.menus.borrow();
    for &root in reg.bars.get(&window).map(Vec::as_slice).unwrap_or(&[]) {
        for id in menu_preorder(&reg, root) {
            let item = &reg.items[&id];
            if item.shortcut.is_empty() {
                continue;
            }
// Every LEAF command may carry a chord. An option's action takes the
// option index as target, so its accelerator names the DETAILED action
// — GTK's `win.kmi-7(1)` — which is what the rendered row activates.
            debug_assert!(item.kind.takes_shortcut(), "the root rejects chords elsewhere");
            let action = match item.kind {
                MenuItemKind::Action | MenuItemKind::Toggle => format!("win.kmi-{id}"),
                MenuItemKind::RadioOption => {
                    let group = item.parent.expect("scene validated option parentage");
                    let index = reg.items[&group]
                        .children
                        .iter()
                        .position(|option| *option == id)
                        .expect("options list under their group");
                    format!("win.kmi-{id}({index})")
                }
                MenuItemKind::Menu | MenuItemKind::RadioGroup | MenuItemKind::Separator => continue,
            };
            if let Some(accel) = menu_accel(&item.shortcut) {
                app.set_accels_for_action(&action, &[&accel]);
            }
        }
    }
}

/// Materialize the window's menu chrome on first use: the PopoverMenuBar
/// over the window's GMenu model in a strip above the content. The
/// window's current child moves into the strip's content slot, and every
/// later content change routes through set_window_content.
fn ensure_menu_strip(core: &mut CoreState, window: u64) {
    if core.menu_strips.contains_key(&window) {
        return;
    }
    let model = core
        .menu_models
        .entry(window)
        .or_insert_with(gio::Menu::new)
        .clone();
    let bar = gtk4::PopoverMenuBar::from_model(Some(&model));
    let strip = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    let content = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    content.set_hexpand(true);
    content.set_vexpand(true);
    strip.append(&bar);
    strip.append(&content);
// THE TOOLBAR VIEW'S content slot, not the window's child: since the flip
// the window's child is the shell, and the strip is one level in.
    let target = window_shell(core, window);
    if let Some(existing) = window_content(core, window) {
        set_shell_content(&target, gtk4::Widget::NONE);
        existing.set_hexpand(true);
        existing.set_vexpand(true);
        content.append(&existing);
    }
    set_shell_content(&target, Some(strip.upcast_ref::<gtk4::Widget>()));
    core.menu_strips.insert(window, (strip, content));
}

/// The window's shell — the AdwToolbarView installed by
/// `install_nav_chrome`, whose content slot holds what would otherwise be
/// the window's child. Every content route goes through this, which keeps
/// the header bar from being replaced by a mounted root.
fn window_shell(core: &CoreState, window: u64) -> adw::ToolbarView {
    core.toolbar_views
        .get(&window)
        .expect("every window gets its shell from install_nav_chrome")
        .clone()
}

fn set_shell_content(view: &adw::ToolbarView, child: Option<&gtk4::Widget>) {
    view.set_content(child);
}

/// What the window is showing under its chrome: the menu strip when one
/// exists, otherwise the mounted root / nav entry / split view. A read that
/// took the window's child would take the SHELL, which fills the window by
/// construction and would make `expect_root_fills` pass for a root that hugs.
fn window_content(core: &CoreState, window: u64) -> Option<gtk4::Widget> {
    core.toolbar_views.get(&window).and_then(adw::ToolbarView::content)
}

/// The window's live content width in pixels, read from its ALLOCATION and
/// not `default_size()`, which is the size REQUESTED: under a bare Xvfb the
/// two drift apart and the arm and the assertion disagree about the same
/// instant. Falls back to the request before the window is mapped. `None` is
/// a window this process does not hold — a fabricated 0 would read `compact`.
fn window_width(core: &CoreState, window: u64) -> Option<i32> {
    use gtk4::prelude::{GtkWindowExt, WidgetExt};
    let target = gtk_window_read(core, window)?;
    let allocated = target.width();
    Some(if allocated > 0 { allocated } else { target.default_size().0 })
}

/// Detach a widget from whatever currently holds it. GTK gives a widget
/// EXACTLY ONE parent and asserts loudly on a second
/// (`gtk_window_set_child: assertion ... failed`), and these roots move
/// between the window, the menu-strip content box and the list-detail
/// split box as the size class changes.
fn unparent(child: &gtk4::Widget) {
    use gtk4::prelude::{BoxExt, Cast, GtkWindowExt, WidgetExt};
    let Some(parent) = child.parent() else { return };
    if let Some(bx) = parent.downcast_ref::<gtk4::Box>() {
        bx.remove(child);
    } else if let Some(win) = parent.downcast_ref::<gtk4::Window>() {
        win.set_child(None::<&gtk4::Widget>);
    } else if let Some(view) = parent.downcast_ref::<adw::ToolbarView>() {
// A toolbar view owns its content through a PROPERTY, like the
// navigation page below: a bare unparent would leave the view still
// pointing at the detached widget.
        view.set_content(None::<&gtk4::Widget>);
    } else if let Some(page) = parent.downcast_ref::<adw::NavigationPage>() {
// A page owns its child through a PROPERTY, so a bare unparent leaves
// the page still pointing at it. The pane then lives in no tree the
// accessibility walk can reach, and `expect_ax` reports it absent while
// kaya's own model still has it — exactly how this presented.
        adw::prelude::NavigationPageExt::set_child(page, None::<&gtk4::Widget>);
    } else {
        child.unparent();
    }
}

fn set_window_content(core: &CoreState, window: u64, child: Option<&gtk4::Widget>) {
    if let Some((_, content)) = core.menu_strips.get(&window) {
        while let Some(old) = content.first_child() {
            content.remove(&old);
        }
        if let Some(widget) = child {
            unparent(widget);
// Expansion is opt-in inside a Box (a bare window child fills by
// construction): without it the mounted root hugs and every grow
// weight divides nothing.
            widget.set_hexpand(true);
            widget.set_vexpand(true);
            content.append(widget);
        }
    } else {
        if let Some(widget) = child {
            unparent(widget);
        }
        set_shell_content(&window_shell(core, window), child);
    }
}

/// Attach a context catalog root to a live or stamped widget: a
/// GtkPopoverMenu over the attachment's own model, opened by the platform's
/// own right-click gesture, its actions in a per-anchor group so each stamped
/// copy's occurrences carry that copy's key path.
fn context_attach(core: &mut CoreState, widget: u64, item: u64, noun: Vec<Value>) {
    if !core.context_menus.contains_key(&widget) {
        let anchor = core
            .widgets
            .get(&WidgetId(widget))
            .expect("scene validated the anchor id")
            .widget();
        let model = gio::Menu::new();
        let popover = gtk4::PopoverMenu::from_model(Some(&model));
        popover.set_parent(&anchor);
        let group = gio::SimpleActionGroup::new();
        anchor.insert_action_group("kayactx", Some(&group));
        // The platform's own gesture: right-click pops the catalog at
        // the pointer and takes the open-context claim.
        let gesture = gtk4::GestureClick::new();
        gesture.set_button(gtk4::gdk::BUTTON_SECONDARY);
        let open = core.open_context.clone();
        #[cfg(feature = "harness")]
        let trail_press = core.context_trail.clone();
        let popover_for_press = popover.clone();
        gesture.connect_pressed(move |_, _, x, y| {
            popover_for_press.set_pointing_to(Some(&gtk4::gdk::Rectangle::new(
                x as i32, y as i32, 1, 1,
            )));
            *open.borrow_mut() = Some(widget);
            #[cfg(feature = "harness")]
            note_claim(&trail_press, "right-click gesture", Some(widget));
            popover_for_press.popup();
        });
        anchor.add_controller(gesture);
// Chrome dismissal (Esc, outside click) releases the claim;
// menu_activate clears it BEFORE its popdown, so this no-ops on the
// harness path. The Rc keeps this closure off CORE.
        let open = core.open_context.clone();
        #[cfg(feature = "harness")]
        let trail_closed = core.context_trail.clone();
        popover.connect_closed(move |popover| {
            let mut open = open.borrow_mut();
            if *open != Some(widget) {
                return;
            }
            // A CLOSE THAT ARRIVES WITH THE CLAIM STILL SET IS A FAILED
            // PRESENTATION, NOT A DISMISSAL: there is no user in a scene, so
            // popup() did not keep the menu up and the answer is to put it
            // back. Measured on menus-{csharp,java}-wayland, a stamped row
            // restamped by the preceding Rename; wayland only (docs/traps.md).
            #[cfg(feature = "harness")]
            {
                note_claim(&trail_closed, "popover closed without showing — re-presenting", Some(widget));
                popover.popup();
                return;
            }
            #[cfg(not(feature = "harness"))]
            {
                *open = None;
            }
        });
        core.context_menus.insert(
            widget,
            GtkContextMenu {
                roots: Vec::new(),
                noun,
                model,
                popover,
                group,
                actions: HashMap::new(),
            },
        );
    }
    core.context_menus
        .get_mut(&widget)
        .expect("attachment exists")
        .roots
        .push(item);
    core.menus
        .borrow_mut()
        .context_of
        .entry(item)
        .or_default()
        .push(widget);
    register_context_actions(core, widget, item);
    rebuild_context(core, widget);
}

/// The widget id behind a harness target — the reverse of the kind#index
/// registries, by object identity.
#[cfg(feature = "harness")]
fn context_anchor_id(core: &CoreState, t: crate::harness::Target) -> u64 {
    use crate::harness::{resolve, TargetKind as K};
    let widget: gtk4::Widget = match t.kind {
        K::Button => core.buttons[resolve(t.index, core.buttons.len())].clone().upcast(),
        K::Checkbox => core.checkboxes[resolve(t.index, core.checkboxes.len())].clone().upcast(),
        K::Slider => core.sliders[resolve(t.index, core.sliders.len())].clone().upcast(),
        K::Label => core.labels[resolve(t.index, core.labels.len())].clone().upcast(),
        K::Column => core.columns[resolve(t.index, core.columns.len())].clone().upcast(),
        K::Row => core.rows[resolve(t.index, core.rows.len())].clone().upcast(),
        K::Image => core.images[resolve(t.index, core.images.len())].clone().upcast(),
        K::Progress => core.progresses[resolve(t.index, core.progresses.len())].clone().upcast(),
        K::Scroll => core.scrolls[resolve(t.index, core.scrolls.len())].clone().upcast(),
        K::Select => core.selects[resolve(t.index, core.selects.len())].clone().upcast(),
        K::Radio => core.radios[resolve(t.index, core.radios.len())].clone().upcast(),
        K::Grid => core.grids[resolve(t.index, core.grids.len())].clone().upcast(),
        K::Canvas => core.canvases[resolve(t.index, core.canvases.len())].clone().upcast(),
        // The harness rejects editable text before the stage sees it
        // (their native context menus are dress).
        K::Entry | K::Textarea => {
            panic!("kaya: editable text is not a context anchor (v1)")
        }
    };
    core.widgets
        .iter()
        .find_map(|(id, native)| (native.widget() == widget).then_some(id.0))
        .expect("kaya: context target is not a live widget")
}

/// The REAL activation route for a resolved item: the GSimpleAction (and the
/// option index for a radio pick). Grouping nodes and separators have none.
fn menu_activation_route(
    reg: &MenuRegistry,
    item: u64,
    attachment: Option<&GtkContextMenu>,
) -> Option<(gio::SimpleAction, Option<i32>)> {
    let instance = |id: u64| match attachment {
        Some(cm) => cm.actions.get(&id).cloned(),
        None => reg.items[&id].actions.first().cloned(),
    };
    match reg.items[&item].kind {
        MenuItemKind::Action | MenuItemKind::Toggle => instance(item).map(|a| (a, None)),
        MenuItemKind::RadioOption => {
            let group = reg.items[&item]
                .parent
                .expect("scene validated option parentage");
            let index = reg.items[&group]
                .children
                .iter()
                .position(|c| *c == item)
                .expect("options list under their group") as i32;
// The option's own action, the same object its rendered row activates
// — a disabled option refuses the verb exactly as it refuses a click.
            instance(item).map(|a| (a, Some(index)))
        }
        MenuItemKind::Menu | MenuItemKind::RadioGroup | MenuItemKind::Separator => None,
    }
}

// --- Clipboard (DESIGN.md; docs/clipboard-plan.md §5b) ----------------
// The COPY arm is one provider per populated representation, unioned; a
// SLASHLESS custom type is advertised and never served, which is why the id
// grammar is validated at the root. THE FAILURE THIS ARM CANNOT SEE: wayland
// gives the selection only with an input-event serial and a headless seat
// never delivers one, so set_content is dropped SILENTLY (ensure_serial_primed).

/// Everything a menu-role activation needs WITHOUT borrowing CORE: a stage
/// verb activates actions while it holds the core borrow.
struct ClipboardHub {
    /// Accept lists by widget id (the accepts prop; empty = unset =
    /// absent here). The paste split and Paste's enablement both read
    /// it.
    accepts: RefCell<HashMap<u64, String>>,
    /// Identity tags by widget id — the same bytes clicks ride — so a
    /// paste onto a stamped copy carries its noun without a second
    /// registry.
    tags: RefCell<HashMap<u64, Vec<u8>>>,
    /// id -> (widget, is it an editable kind), for resolving which kaya widget
    /// owns focus. Weak: destruction must not need this map's cooperation.
    widgets: RefCell<HashMap<u64, (glib::WeakRef<gtk4::Widget>, bool)>>,
    sink: OccSink,
    /// A clipboard surface appeared (accepts / copy / read): the harness
    /// primes the wayland serial only for scenes that will spend one.
    armed: std::cell::Cell<bool>,
}

impl ClipboardHub {
    fn new(sink: OccSink) -> Self {
        ClipboardHub {
            accepts: RefCell::new(HashMap::new()),
            tags: RefCell::new(HashMap::new()),
            widgets: RefCell::new(HashMap::new()),
            sink,
            armed: std::cell::Cell::new(false),
        }
    }

    /// The kaya widget that owns focus: the DEEPEST registered widget
    /// containing the toplevel's focus widget, since a GtkEntry delegates to
    /// an internal GtkText. THE ACTIVE TOPLEVEL FIRST, AND THEN EVERY OTHER
    /// ONE — window activation belongs to the WINDOW MANAGER and the lane has
    /// none, so after a modal dialog closes there may be no active toplevel at
    /// all (measured 2026-08-10, docs/traps.md).
    fn focused_widget_id(&self) -> Option<u64> {
        use gtk4::prelude::{Cast, GtkWindowExt, WidgetExt};
        let toplevels = gtk4::Window::toplevels();
        let mut candidates: Vec<gtk4::Widget> = Vec::new();
        for i in 0..gtk4::gio::prelude::ListModelExt::n_items(&toplevels) {
            let Some(window) = gtk4::gio::prelude::ListModelExt::item(&toplevels, i)
                .and_then(|o| o.downcast::<gtk4::Window>().ok())
            else {
                continue;
            };
            if let Some(f) = GtkWindowExt::focus(&window) {
                if window.is_active() {
                    candidates.insert(0, f);
                } else {
                    candidates.push(f);
                }
            }
        }
        let mut best: Option<(u64, u32)> = None;
        for focus in candidates {
            for (id, (weak, _)) in self.widgets.borrow().iter() {
                let Some(w) = weak.upgrade() else { continue };
                if focus == w || focus.is_ancestor(&w) {
                    let mut depth = 0u32;
                    let mut p = w.parent();
                    while let Some(q) = p {
                        depth += 1;
                        p = q.parent();
                    }
                    if best.is_none_or(|(_, d)| depth > d) {
                        best = Some((*id, depth));
                    }
                }
            }
            // The first toplevel that owns one of ours answers; the
            // active one is at the head, so a real session is unchanged.
            if best.is_some() {
                break;
            }
        }
        best.map(|(id, _)| id)
    }

    /// Whether a clipboard role's command can act right now; a non-role item
    /// answers true. THE SAME RULE AS THE MAC ARM (kayaRoleEnabled): paste is
    /// the INTERSECTION of what the clipboard offers and what the focused
    /// widget accepts — a widget that declared NOTHING still pastes — and cut
    /// and copy need a focused editable with a selection to give.
    fn role_enabled(&self, role: &str) -> bool {
        match role {
            "cut" | "copy" => self
                .focused_widget_id()
                .is_some_and(|id| {
                    self.widgets
                        .borrow()
                        .get(&id)
                        .is_some_and(|(_, editable)| *editable)
                }),
            "paste" => {
                let Some(id) = self.focused_widget_id() else {
                    return false;
                };
                let Some(display) = gdk::Display::default() else {
                    return false;
                };
                let formats = display.clipboard().formats();
                let accepts =
                    self.accepts.borrow().get(&id).cloned().unwrap_or_default();
                if accepts.is_empty() {
                    return clipboard_offers_text(&formats);
                }
                let (kinds, custom) = crate::wire::parse_accept_list(&accepts);
                custom.iter().any(|id| formats.contain_mime_type(id))
                    || (kinds & crate::wire::CLIP_FILES != 0
                        && formats.contain_mime_type("text/uri-list"))
                    || (kinds & crate::wire::CLIP_IMAGE != 0
                        && formats.contain_mime_type("image/png"))
                    || (kinds & crate::wire::CLIP_HTML != 0
                        && formats.contain_mime_type("text/html"))
                    || (kinds & crate::wire::CLIP_TEXT != 0
                        && clipboard_offers_text(&formats))
            }
            _ => true,
        }
    }

    /// Perform a clipboard role on the focused widget. Answers whether it WAS
    /// one, so a plain action falls through to its own dispatch.
    ///
    /// THE PASTE SPLIT (DESIGN.md): a widget that DECLARED what it accepts
    /// takes the content itself, delivered to the paste hook, while one that
    /// declared nothing gets the platform's own insertion
    /// ("clipboard.paste").
    fn perform_role(self: &Rc<Self>, role: &str) -> bool {
        use gtk4::prelude::WidgetExt;
        let focused_native = || -> Option<gtk4::Widget> {
            use gtk4::prelude::GtkWindowExt;
            let toplevels = gtk4::Window::toplevels();
            for i in 0..gtk4::gio::prelude::ListModelExt::n_items(&toplevels) {
                use gtk4::prelude::Cast;
                if let Some(f) = gtk4::gio::prelude::ListModelExt::item(&toplevels, i)
                    .and_then(|o| o.downcast::<gtk4::Window>().ok())
                    .and_then(|w| GtkWindowExt::focus(&w))
                {
                    return Some(f);
                }
            }
            None
        };
        match role {
            "cut" | "copy" => {
                if let Some(f) = focused_native() {
                    let _ = f.activate_action(&format!("clipboard.{role}"), None);
                }
                true
            }
            "paste" => {
                let Some(id) = self.focused_widget_id() else {
                    return true;
                };
                let accepts =
                    self.accepts.borrow().get(&id).cloned().unwrap_or_default();
                if accepts.is_empty() {
                    if let Some(f) = focused_native() {
                        let _ = f.activate_action("clipboard.paste", None);
                    }
                    return true;
                }
                let Some(display) = gdk::Display::default() else {
                    return true;
                };
                let Some(tag) = self.tags.borrow().get(&id).cloned() else {
                    return true;
                };
                let hub = self.clone();
                materialize_clipboard(
                    &display.clipboard(),
                    &accepts,
                    Box::new(move |clip| {
                        // A paste that delivered nothing is not an
                        // occurrence (the read owns the empty answer).
                        let Some(clip) = clip else { return };
                        let occurrence = match crate::wire::decode_click_tag(&tag) {
                            Occurrence::ButtonClicked { id } => {
                                Occurrence::Pasted { id, clip }
                            }
                            Occurrence::InstanceButtonClicked { node, path } => {
                                Occurrence::InstancePasted { node, path, clip }
                            }
                            other => panic!(
                                "kaya: a paste tag decoded to {other:?}, which is \
                                 not a widget identity"
                            ),
                        };
                        hub.sink.send(occurrence);
                    }),
                );
                true
            }
            _ => false,
        }
    }
}

/// Whether the offer includes text in any spelling a text read can take: the
/// plain mime (with or without GDK's charset aliases) or a same-process
/// string value.
fn clipboard_offers_text(formats: &gdk::ContentFormats) -> bool {
    formats.contain_mime_type("text/plain")
        || formats.contain_mime_type("text/plain;charset=utf-8")
        || formats.contains_type(glib::types::Type::STRING)
}

/// Recompute the GESTURE roles' action enablement (docs/clipboard-plan.md
/// §3): the intersection of what the clipboard offers and what the focused
/// widget accepts, both of which move long after the bar was built. Runs
/// wherever enablement can change hands, since menu_sync_enabled writes the
/// STRUCTURAL half alone. UNDO AND REDO JOIN THE SAME FILTER — theirs moves
/// with the LEDGER, so the ledger's own movers call this too.
fn refresh_roles(core: &CoreState) {
    let reg = core.menus.borrow();
    for (id, item) in &reg.items {
        if !matches!(item.role.as_str(), "cut" | "copy" | "paste" | "undo" | "redo") {
            continue;
        }
        let on = menu_effective_enabled(&reg, *id) && core.role_enabled(&item.role);
        for action in &item.actions {
            action.set_enabled(on);
        }
    }
}

// --- The undo tier (docs/undo-plan.md D6/D7/A1/A4, §3) -----------------
// GTK OWNS RAW CONTROLS: a native undo reaches kaya's model synchronously on
// the ordinary `changed` signal (measured on both kinds), so the work is to
// SUPPRESS the banking half for an undo this backend routed (ledger_quiet)
// and report it once through `note_native_undo`. D7 is free too — a
// programmatic `set_text` wipes the field's history by itself (measured).

impl CoreState {
    /// A4's ONE named query — "can the focused widget undo?" — answered in
    /// this platform's vocabulary and asked nowhere else in this file. THE TWO
    /// KINDS ANSWER DIFFERENTLY BECAUSE GTK DOES: a GtkTextBuffer publishes
    /// `can-undo`, the GtkText behind a GtkEntry publishes nothing, so the
    /// entry is answered from `native_dirty`. Where that could be stale the
    /// ACTIVATION finds out — an undo with nothing left moves nothing.
    fn focused_can_undo(&self, redo: bool) -> bool {
        // The hub already resolves the focused widget across toplevels (a
        // GtkEntry delegates to an internal GtkText).
        let Some(id) = self.clipboard.focused_widget_id() else {
            return false;
        };
        match self.widgets.get(&WidgetId(id)) {
            Some(NativeWidget::Textarea(_, view)) => {
                let buffer = view.buffer();
                if redo { buffer.can_redo() } else { buffer.can_undo() }
            }
            Some(NativeWidget::Entry(_)) => self.native_dirty.borrow().contains(&id),
            _ => false,
        }
    }

    /// Whether a text widget's NATIVE undo stack holds anything — what the
    /// typing verb needs to prove it typed for real.
    #[cfg(feature = "harness")]
    fn native_undo_filled(&self, id: WidgetId) -> bool {
        match self.widgets.get(&id) {
            Some(NativeWidget::Textarea(_, view)) => view.buffer().can_undo(),
            Some(NativeWidget::Entry(_)) => self.native_dirty.borrow().contains(&id.0),
            _ => false,
        }
    }

    /// Whether a role's command can act right now — the enablement half of
    /// every gesture role, in one place. Undo and redo ask the CORE; the
    /// clipboard roles ask the hub.
    fn role_enabled(&self, role: &str) -> bool {
        match role {
            "undo" => self.undo_route(false) != crate::scene::UndoRoute::Nothing,
            "redo" => self.undo_route(true) != crate::scene::UndoRoute::Nothing,
            _ => self.clipboard.role_enabled(role),
        }
    }

    /// Where an undo (or redo) would go RIGHT NOW. ASKED ONCE AND USED TWICE
    /// — enablement and activation are the same question (docs/undo-plan.md
    /// D6), and `Nothing` IS what a disabled Edit>Undo means. The answer is
    /// the CORE's: this backend contributes only the pair it alone can see.
    fn undo_route(&self, redo: bool) -> crate::scene::UndoRoute {
        let focused = self
            .clipboard
            .focused_widget_id()
            .map(WidgetId)
            .filter(|id| {
                matches!(
                    self.widgets.get(id),
                    Some(NativeWidget::Entry(_) | NativeWidget::Textarea(..))
                )
            });
        let window = self.undo_window();
        let can = self.focused_can_undo(redo);
        if redo {
            self.scene.route_redo(window, focused, can)
        } else {
            self.scene.route_undo(window, focused, can)
        }
    }

    /// Whose ledger an undo activation belongs to: the focused field's
    /// window, and failing that the ACTIVE toplevel's. ASKED IN ONE PLACE
    /// because enablement and activation must not disagree about which
    /// history they mean; window 0 always exists.
    fn undo_window(&self) -> WindowId {
        self.clipboard
            .focused_widget_id()
            .map(WidgetId)
            .and_then(|id| self.window_of_widget(id))
            .or_else(|| active_window_id(self))
            .unwrap_or(WindowId(0))
    }

    /// Which window's ledger a widget's edits belong to (§3 keeps one per
    /// window). Resolved from the toolkit: a widget's root IS its window.
    fn window_of_widget(&self, id: WidgetId) -> Option<WindowId> {
        use gtk4::prelude::{Cast, WidgetExt};
        let root = self.widgets.get(&id)?.widget().root()?;
        let root = root.downcast::<gtk4::Window>().ok()?;
        if root == self.window {
            return Some(WindowId(0));
        }
        self.aux_windows
            .iter()
            .find(|(_, w)| **w == root)
            .map(|(id, _)| WindowId(*id))
    }

    /// Reset ONE editable's native undo history — D7's spelling here, and
    /// A1's whole operation. Per kind, because GTK gives the two kinds
    /// different levers (both measured to clear a REAL typed history and to
    /// touch no text): the buffer takes an EMPTY irreversible-action bracket,
    /// the entry an enable-undo toggle.
    fn clear_native_undo(&self, id: WidgetId) {
        match self.widgets.get(&id) {
            Some(NativeWidget::Entry(entry)) => {
                use gtk4::prelude::EditableExt;
                entry.set_enable_undo(false);
                entry.set_enable_undo(true);
            }
            Some(NativeWidget::Textarea(_, view)) => {
                let buffer = view.buffer();
                buffer.begin_irreversible_action();
                buffer.end_irreversible_action();
            }
            _ => return,
        }
        // THE SINGLE CHOKEPOINT, which is why the model of the entry's
        // unreadable stack can live here and stay true.
        self.native_dirty.borrow_mut().remove(&id.0);
    }

    /// The text a text widget is showing, LF-normalized the way every
    /// other read out of this backend is.
    fn text_of(&self, id: WidgetId) -> Option<String> {
        match self.widgets.get(&id) {
            Some(NativeWidget::Entry(entry)) => Some(lf(entry.text().to_string())),
            Some(NativeWidget::Textarea(_, view)) => {
                let b = view.buffer();
                Some(lf(b.text(&b.start_iter(), &b.end_iter(), false).to_string()))
            }
            _ => None,
        }
    }
}

/// D7 + A3 at the quiet-write sites: a programmatic write resets THAT
/// widget's native undo history — but only when the write CHANGED the text,
/// because GTK's own `set_text` leaves the history alone when the text is
/// identical (measured) and an unconditional clear would take away the
/// typing history of an app that mirrors a field into a signal. Called from
/// the APPLY ARMS, so a core-written inverse travels the forward path.
fn note_quiet_text_write(core: &CoreState, id: WidgetId, previous: &str, next: &str) {
    if previous == next {
        return;
    }
    core.clear_native_undo(id);
}

/// The reconciliation sample (§3): what a NATIVE undo left behind — the
/// field, the text the walk landed on, and whether the field can still undo.
/// THE THIRD FACT IN BOTH DIRECTIONS is `can_undo`, deliberately: it is the
/// core's exhausted-walk test, and a redo answering `can_redo` would report
/// false at the end of a forward walk and send the core backwards.
fn note_native_undo(core: &mut CoreState, field: WidgetId, moved: bool) {
    let Some(text) = core.text_of(field) else { return };
    let window = core.window_of_widget(field).unwrap_or(WindowId(0));
// CAN-UNDO IN BOTH DIRECTIONS, never can-redo: `can_redo` answers FALSE at
// the end of a forward walk, and the core would read that as an exhausted
// BACKWARD walk and coarse-restore to the before-image.
    let can = match core.widgets.get(&field) {
        Some(NativeWidget::Textarea(_, view)) => view.buffer().can_undo(),
        _ => moved,
    };
    if let Some((ops, occurrence)) = core.scene.note_native_undo(window, field, &text, can) {
        for op in ops {
            apply(core, op);
        }
        core.occurrences.send(occurrence);
    }
}

/// Perform an undo/redo role on the focused surface. Answers whether it WAS
/// one, so a plain action falls through to its own dispatch. ROUTING IS
/// KAYA'S HERE, all of it (docs/undo-plan.md §1): GTK has no responder chain.
/// DEFERRED TO AN IDLE, this file's standing discipline — a menu action's
/// handler may run while the harness holds the CORE borrow, and both tiers of
/// an undo need `&mut CoreState`. Idle sources run FIFO.
fn perform_undo_role(role: &str) -> bool {
    let redo = match role {
        "undo" => false,
        "redo" => true,
        _ => return false,
    };
    glib::idle_add_local_once(move || {
        CORE.with_borrow_mut(|core| {
            let Some(core) = core.as_mut() else { return };
            let route = core.undo_route(redo);
            let window = core.undo_window();
            match route {
                crate::scene::UndoRoute::Native => {
                    let Some(field) = core.clipboard.focused_widget_id().map(WidgetId) else {
                        return;
                    };
                    let before = core.text_of(field).unwrap_or_default();
// THE LEDGER-QUIET BRACKET (Q2). The change this activation
// provokes still reaches the app through the widget's own `changed`
// and is banked by nobody: this function reports it once.
                    core.ledger_quiet.set(true);
                    match core.widgets.get(&field) {
                        Some(NativeWidget::Entry(entry)) => {
                            use gtk4::prelude::WidgetExt;
                            let action = if redo { "text.redo" } else { "text.undo" };
                            let delegate = gtk4::prelude::EditableExt::delegate(entry)
                                .unwrap_or_else(|| entry.clone().upcast());
                            let _ = delegate.activate_action(action, None);
                        }
                        Some(NativeWidget::Textarea(_, view)) => {
                            let buffer = view.buffer();
                            if redo {
                                buffer.redo();
                            } else {
                                buffer.undo();
                            }
                        }
                        _ => {}
                    }
                    core.ledger_quiet.set(false);
                    let moved = core.text_of(field).unwrap_or_default() != before;
                    // THE NATIVE TIER MUST ACTUALLY HAVE SOMETHING, provable
                    // under the harness: an activation that moves nothing
                    // means the keys never travelled the platform's input path
                    // or GTK stopped recording typed input, both otherwise
                    // SILENT. (No harness: a user's own Ctrl+Z can empty the
                    // stack legitimately — A6's gap.)
                    #[cfg(feature = "harness")]
                    assert!(
                        moved || redo,
                        "kaya: Edit>Undo routed to the NATIVE tier and the field's own \
                         stack had nothing — its typing did not go in as key events \
                         (harness.rs Stage::type_text, point 1), so the tier this scene \
                         exists to exercise is empty and the core would have covered \
                         for it (docs/undo-plan.md §3)"
                    );
                    if !moved {
// The stack was empty where this backend's model said it was not
// (GtkText's own Ctrl+Z is live and unintercepted, A6's gap).
// Correct the model here, and let the core finish the step.
                        core.native_dirty.borrow_mut().remove(&field.0);
                    }
// A REDO THAT MOVED NOTHING IS NOT REPORTED. The core's third fact
// is the exhausted-walk test and it runs BACKWARDS: fed a no-move
// forward it would coarse-restore to the before-image.
                    if moved || !redo {
                        note_native_undo(core, field, moved);
                    }
                }
                crate::scene::UndoRoute::Core => {
                    let stepped = if redo {
                        core.scene.redo(window)
                    } else {
                        core.scene.undo(window)
                    };
                    if let Some((ops, occurrence)) = stepped {
                        for op in ops {
                            apply(core, op);
                        }
                        core.occurrences.send(occurrence);
                    }
                }
// Inert: both tiers are empty, and the item reads disabled for
// the same reason — the route above IS the enablement.
                crate::scene::UndoRoute::Nothing => {}
            }
            refresh_roles(core);
        });
    });
    true
}

/// Bank one text edit into the ledger (§3's episode banking), off the
/// occurrence the widget just emitted. THE TAG RESOLVES THE FIELD, not a
/// captured id: the ledger keys on the widget id a programmatic write would
/// name, and `Scene::text_field_of_tag` answers None for a stamped row, whose
/// typing is therefore banked on no backend. DEFERRED; idle sources run FIFO,
/// so edits bank in the order they happened.
fn bank_text_changed(tag: Vec<u8>, text: String, focused: bool) {
    glib::idle_add_local_once(move || {
        CORE.with_borrow_mut(|core| {
            let Some(core) = core.as_mut() else { return };
            let Some(field) = core.scene.text_field_of_tag(&tag) else {
                return;
            };
            let window = core.window_of_widget(field).unwrap_or(WindowId(0));
            core.scene.note_text_changed(window, field, &text, focused);
            // A banked edit moves the ledger, and the ledger is what
            // Edit>Undo's enablement reads.
            refresh_roles(core);
        });
    });
}

/// The kaya text widget holding the keyboard focus IN ONE WINDOW — A1's
/// target, which names a window rather than a widget. Resolved from that
/// window's own focus widget rather than the hub's cross-toplevel answer: a
/// group can commit in a window that is not the active one, and clearing the
/// history of a field the user is typing in elsewhere is what D7's focus
/// guard prevents.
fn focused_text_in(core: &CoreState, window: WindowId) -> Option<WidgetId> {
    use gtk4::prelude::{GtkWindowExt, WidgetExt};
    let toplevel = if window.0 == 0 {
        core.window.clone()
    } else {
        core.aux_windows.get(&window.0)?.clone()
    };
    let focus = GtkWindowExt::focus(&toplevel)?;
    core.widgets
        .iter()
        .find(|(_, w)| {
            matches!(w, NativeWidget::Entry(_) | NativeWidget::Textarea(..))
                && (focus == w.control() || focus.is_ancestor(&w.control()))
        })
        .map(|(id, _)| *id)
}

/// The kaya window id of the ACTIVE toplevel, if one of kaya's is.
fn active_window_id(core: &CoreState) -> Option<WindowId> {
    use gtk4::prelude::GtkWindowExt;
    if core.window.is_active() {
        return Some(WindowId(0));
    }
    core.aux_windows
        .iter()
        .find(|(_, w)| w.is_active())
        .map(|(id, _)| WindowId(*id))
}

/// Whether a text widget holds the keyboard focus, read the way `is_focused`
/// reads it: a focused GtkEntry delegates to an internal GtkText, so the
/// entry itself is never the toplevel's focus widget and FOCUS_WITHIN is the
/// flag that answers.
fn widget_focused(widget: &impl IsA<gtk4::Widget>) -> bool {
    use gtk4::prelude::{Cast, GtkWindowExt, WidgetExt};
    let widget = widget.as_ref();
    if widget
        .state_flags()
        .intersects(gtk4::StateFlags::FOCUSED | gtk4::StateFlags::FOCUS_WITHIN)
    {
        return true;
    }
    // THE SECOND CLAUSE, and the one a session with no window manager needs:
    // GTK clears both flags above the moment the toplevel goes INACTIVE, while
    // `gtk_window_get_focus` still names the same widget and keystrokes still
    // land in it. Without it a modal dialog's close makes the next keystroke
    // read as a programmatic write (docs/traps.md: "GTK's focus flags clear
    // with window activation, and the lane has no window manager").
    let Some(window) = widget.root().and_then(|r| r.downcast::<gtk4::Window>().ok()) else {
        return false;
    };
    let Some(focus) = GtkWindowExt::focus(&window) else {
        return false;
    };
    &focus == widget || focus.is_ancestor(widget)
}

/// Choose the RICHEST representation the clipboard offers that the accept
/// list takes, transfer exactly that one, and answer exactly once — None for
/// no intersection or a failed transfer, the universal no. The chooser
/// consults formats(), so no transfer runs for a representation nobody asked
/// for and the unsatisfiable case answers immediately (measured §5b: 0ms).
/// Descending clip value — custom, files, image, html, text (§1).
fn materialize_clipboard(
    clipboard: &gdk::Clipboard,
    accepting: &str,
    done: Box<dyn FnOnce(Option<crate::protocol::Representation>)>,
) {
    use crate::protocol::Representation as R;
    let (kinds, custom) = crate::wire::parse_accept_list(accepting);
    let formats = clipboard.formats();
    if let Some(id) = custom
        .iter()
        .find(|id| formats.contain_mime_type(id))
        .map(|id| (*id).to_owned())
    {
        let mime = id.clone();
        read_clipboard_bytes(
            clipboard,
            &mime,
            Box::new(move |bytes| {
                done(bytes.map(|b| R::Custom {
                    id,
                    bytes: crate::protocol::Blob(std::sync::Arc::from(&b[..])),
                }));
            }),
        );
    } else if kinds & crate::wire::CLIP_FILES != 0
        && formats.contain_mime_type("text/uri-list")
    {
        read_clipboard_bytes(
            clipboard,
            "text/uri-list",
            Box::new(move |bytes| {
                let Some(bytes) = bytes else { return done(None) };
// The RFC's grammar: CRLF separators (bare LF tolerated),
// comment lines start with '#'. Only file:// URIs become files.
                let text = String::from_utf8_lossy(&bytes);
                let mut files = Vec::new();
                for line in text.lines() {
                    let line = line.trim_end_matches('\r');
                    if line.is_empty() || line.starts_with('#') {
                        continue;
                    }
                    let Ok((path, _)) = glib::filename_from_uri(line) else {
                        continue;
                    };
                    let path = path.to_string_lossy().into_owned();
                    let name = std::path::Path::new(&path)
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default();
// The picker's capability through the second door: the same
// registration the file dialog result makes, so kaya_open_picked
// redeems a pasted file identically.
                    let handle = crate::capi::picked_register(std::sync::Arc::new(
                        crate::protocol::PathSource {
                            name: name.clone(),
                            path: path.clone(),
                        },
                    ));
                    files.push(crate::protocol::PickedFile {
                        handle,
                        name,
                        local_path: path,
                    });
                }
                done((!files.is_empty()).then_some(R::Files(files)));
            }),
        );
    } else if kinds & crate::wire::CLIP_IMAGE != 0
        && formats.contain_mime_type("image/png")
    {
        read_clipboard_bytes(
            clipboard,
            "image/png",
            Box::new(move |bytes| {
                done(bytes.map(|b| {
                    R::Image(crate::protocol::Blob(std::sync::Arc::from(&b[..])))
                }));
            }),
        );
    } else if kinds & crate::wire::CLIP_HTML != 0 && formats.contain_mime_type("text/html")
    {
        // Raw UTF-8 under the bare type — measured: GDK adds no
        // charset alias for html (that aliasing is text/plain-only).
        read_clipboard_bytes(
            clipboard,
            "text/html",
            Box::new(move |bytes| {
                done(bytes
                    .map(|b| R::Html(String::from_utf8_lossy(&b).into_owned())));
            }),
        );
    } else if kinds & crate::wire::CLIP_TEXT != 0 && clipboard_offers_text(&formats) {
        clipboard.read_text_async(gtk4::gio::Cancellable::NONE, move |res| {
            done(match res {
                Ok(Some(s)) => Some(R::Text(s.to_string())),
                _ => None,
            });
        });
    } else {
        done(None);
    }
}

/// One mime type's bytes off the clipboard, whole, then the callback — None
/// for a failed transfer (GDK fails an unservable read fast, measured §5b).
fn read_clipboard_bytes(
    clipboard: &gdk::Clipboard,
    mime: &str,
    done: Box<dyn FnOnce(Option<Vec<u8>>)>,
) {
    clipboard.read_async(
        &[mime],
        glib::Priority::DEFAULT,
        gtk4::gio::Cancellable::NONE,
        move |res| match res {
            Ok((stream, _mime)) => read_stream_to_end(stream, Vec::new(), done),
            Err(_) => done(None),
        },
    );
}

fn read_stream_to_end(
    stream: gtk4::gio::InputStream,
    mut acc: Vec<u8>,
    done: Box<dyn FnOnce(Option<Vec<u8>>)>,
) {
    use gtk4::gio::prelude::InputStreamExt;
    let again = stream.clone();
    stream.read_bytes_async(
        65536,
        glib::Priority::DEFAULT,
        gtk4::gio::Cancellable::NONE,
        move |res| match res {
            Ok(bytes) if bytes.is_empty() => done(Some(acc)),
            Ok(bytes) => {
                acc.extend_from_slice(&bytes);
                read_stream_to_end(again, acc, done);
            }
            Err(_) => done(None),
        },
    );
}

/// THE CANVAS'S WIDGET: a `GdkPaintable` drawn at the size the CORE rastered
/// it for, centred in whatever track layout assigned, clipped to it. NOT A
/// `GtkPicture`, and the size policy is why (docs/canvas-plan.md §3.2.1,
/// ruling 2): the blit has to be strictly 1:1 and no member of
/// `GtkContentFit` means that (docs/traps.md, "A canvas sized by its own blit
/// NEVER STARTS"); tools/check-canvas-blit.py refuses that vocabulary.
mod canvas_view {
    use gtk4::glib;
    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;

    #[derive(Default)]
    pub struct KayaCanvasInner {
        paintable: std::cell::RefCell<Option<gtk4::gdk::Paintable>>,
        /// The blit's size in POINTS — the raster's pixels over the scale
        /// it was drawn at. Held here rather than read back off the
        /// paintable because `gdk_paintable_get_intrinsic_width` is an
        /// integer and a fractional display scale makes this one not.
        size: std::cell::Cell<(f64, f64)>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for KayaCanvasInner {
        const NAME: &'static str = "KayaCanvas";
        type Type = KayaCanvas;
        type ParentType = gtk4::Widget;

        fn class_init(klass: &mut Self::Class) {
            // `GtkPicture`'s own role, which is what a canvas answers to
            // (tools/scenes/canvas.steps' expect_ax).
            klass.set_accessible_role(gtk4::AccessibleRole::Img);
        }
    }

    impl ObjectImpl for KayaCanvasInner {}

    impl WidgetImpl for KayaCanvasInner {
        /// CONTENT IS THE FLOOR: the natural size is the drawing's own, so
        /// an ungrown canvas is its viewbox and its track IS its viewbox.
        /// The minimum is 0 — `GtkPicture::can-shrink`'s default — because
        /// a canvas given less is clipped rather than resized.
        fn measure(
            &self,
            orientation: gtk4::Orientation,
            _for_size: i32,
        ) -> (i32, i32, i32, i32) {
            let (w, h) = self.size.get();
            let natural = if orientation == gtk4::Orientation::Horizontal { w } else { h };
            (0, natural.ceil().max(0.0) as i32, -1, -1)
        }

        /// THE BLIT, 1:1 (docs/canvas-plan.md §3.2.1): the paintable at the
        /// size it was drawn for, centred, leftover as margin, anything
        /// over the edge clipped. WHICH size that is — the viewbox for
        /// `fixed`, the assigned track for everything else — is the core's
        /// decision and this arm may not have an opinion about it.
        fn snapshot(&self, snapshot: &gtk4::Snapshot) {
            let Some(paintable) = self.paintable.borrow().clone() else { return };
            let (pw, ph) = self.size.get();
            if pw <= 0.0 || ph <= 0.0 {
                return;
            }
            let (w, h) = (f64::from(self.obj().width()), f64::from(self.obj().height()));
            snapshot.push_clip(&gtk4::graphene::Rect::new(0.0, 0.0, w as f32, h as f32));
            snapshot.save();
            snapshot.translate(&gtk4::graphene::Point::new(
                ((w - pw) / 2.0).round() as f32,
                ((h - ph) / 2.0).round() as f32,
            ));
            gtk4::prelude::PaintableExt::snapshot(&paintable, snapshot, pw, ph);
            snapshot.restore();
            snapshot.pop();
        }
    }

    glib::wrapper! {
        pub struct KayaCanvas(ObjectSubclass<KayaCanvasInner>)
            @extends gtk4::Widget,
            @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
    }

    impl Default for KayaCanvas {
        fn default() -> Self {
            glib::Object::new()
        }
    }

    impl KayaCanvas {
        /// The blit and the points it covers. `None` is PRESENT AND EMPTY,
        /// never absent — the image arm's rule verbatim
        /// (tools/check-empty-child.py).
        pub fn set_blit(
            &self,
            paintable: Option<&gtk4::gdk::Paintable>,
            width: f64,
            height: f64,
        ) {
            self.imp().paintable.replace(paintable.cloned());
            let size = if paintable.is_some() { (width, height) } else { (0.0, 0.0) };
            if self.imp().size.replace(size) != size {
                self.queue_resize();
            }
            self.queue_draw();
        }
    }
}

use canvas_view::KayaCanvas;

/// THE BLIT (docs/canvas-plan.md §8): the core's premultiplied RGBA8 into a
/// `GdkMemoryTexture`, handed to the canvas at the LOGICAL size the raster's
/// own scale names. `R8g8b8a8Premultiplied` IS tiny-skia's `Pixmap` layout,
/// so this arm swizzles nothing. THE SIZE IS WHERE THE SCALE GOES (§5 rule
/// 2): a `GdkTexture` carries none, so a 2x raster handed over by its pixel
/// count would ask layout for twice the viewbox.
fn set_drawing(canvas: &KayaCanvas, width: u32, height: u32, scale: f64, pixels: &[u8]) {
    let stride = width as usize * 4;
    let want = stride * height as usize;
    if width == 0 || height == 0 || !scale.is_finite() || scale <= 0.0 || pixels.len() < want {
        canvas.set_blit(None, 0.0, 0.0);
        return;
    }
    let bytes = glib::Bytes::from(&pixels[..want]);
    let texture = gtk4::gdk::MemoryTexture::new(
        width as i32,
        height as i32,
        gtk4::gdk::MemoryFormat::R8g8b8a8Premultiplied,
        &bytes,
        stride,
    );
    let (lw, lh) = (f64::from(width) / scale, f64::from(height) / scale);
    use gtk4::prelude::Cast;
    canvas.set_blit(Some(texture.upcast_ref::<gtk4::gdk::Paintable>()), lw, lh);
}

fn apply(core: &mut CoreState, op: ApplyOp) {
    match op {
        ApplyOp::Create { id, kind, tag } => {
// The clipboard hub's copies, taken before the kind arms consume the
// tag: focus resolution wants every widget, paste delivery wants the
// identity tag, and the editable flag is cut/copy's enablement answer.
            let clip_tag = tag.clone();
            if let Some(t) = &clip_tag {
                core.widget_tags.insert(id.0, t.clone());
            }
            let clip_editable =
                matches!(kind, WidgetKind::Entry | WidgetKind::Textarea);
            let native = match kind {
                WidgetKind::Entry => {
// Uncontrolled: the widget owns its text; each edit goes up with
// the entry's identity tag. GTK fires `changed` for programmatic
// set_text too, so the USER/programmatic split rides apply_quiet —
// the stage's direct writes and the clear command emit like a user.
                    let entry = gtk4::Entry::new();
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("entries carry a tag");
                    let quiet = core.apply_quiet.clone();
                    let ledger_quiet = core.ledger_quiet.clone();
                    let dirty = core.native_dirty.clone();
                    let wid = id.0;
                    entry.connect_changed(move |e| {
                        if !quiet.get() {
                            let text = lf(e.text().to_string());
                            sink.send_text_tag(&tag, &text);
// AND THE LEDGER HEARS IT TOO (§3's episode banking),
// unless this backend routed the undo that caused it
// (Q2's bracket). The focus flag is sampled HERE.
                            if !ledger_quiet.get() {
                                dirty.borrow_mut().insert(wid);
                                bank_text_changed(tag.clone(), text, widget_focused(e));
                            }
                        }
                    });
                    core.entries.push(entry.clone());
                    NativeWidget::Entry(entry)
                }
                WidgetKind::Column => {
// Normalized layout default (uniform across backends); the box
// hugs the top-left of its parent.
                    let column = gtk4::Box::new(gtk4::Orientation::Vertical, CONTAINER_SPACING);
                    column.set_halign(gtk4::Align::Start);
                    column.set_valign(gtk4::Align::Start);
                    // The axis its PARENT will read to see it crossing.
                    set_container_vertical(column.upcast_ref::<gtk4::Widget>(), true);
// No flex manager yet, deliberately: GtkBox's own layout stays
// until a child actually carries a weight (see ensure_flex).
                    core.columns.push(column.clone());
                    #[cfg(feature = "harness")]
                    core.column_ids.push(id);
                    NativeWidget::Column(column)
                }
                WidgetKind::Row => {
                    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, CONTAINER_SPACING);
                    row.set_halign(gtk4::Align::Start);
                    row.set_valign(gtk4::Align::Start);
                    set_container_vertical(row.upcast_ref::<gtk4::Widget>(), false);
                    core.rows.push(row.clone());
                    NativeWidget::Row(row)
                }
                WidgetKind::Checkbox => {
// The box owns its checked bit; each flip goes up with the box's
// identity tag. GTK fires `toggled` for programmatic set_active
// too — the split rides apply_quiet.
                    let check = gtk4::CheckButton::new();
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("checkboxes carry a tag");
                    let quiet = core.apply_quiet.clone();
                    check.connect_toggled(move |c| {
                        if !quiet.get() {
                            sink.send_toggle_tag(&tag, c.is_active());
                        }
                    });
                    core.checkboxes.push(check.clone());
                    NativeWidget::Checkbox(check)
                }
                WidgetKind::Slider => {
// Uncontrolled, like the entry. GTK fires `value-changed` for
// programmatic set_value too — the split rides apply_quiet.
                    let scale =
                        gtk4::Scale::with_range(gtk4::Orientation::Horizontal, 0.0, 1.0, 0.01);
                    scale.set_size_request(160, -1);
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("sliders carry a tag");
                    let quiet = core.apply_quiet.clone();
                    scale.connect_value_changed(move |sc| {
                        if !quiet.get() {
                            sink.send_value_tag(&tag, sc.value());
                        }
                    });
                    core.sliders.push(scale.clone());
                    NativeWidget::Slider(scale)
                }
                WidgetKind::Button => {
                    let button = gtk4::Button::new();
                    let sink = core.occurrences.clone();
                    // The tag is the click's identity, emitted verbatim;
                    // this backend never learns what it means.
                    let tag = tag.expect("buttons carry a click tag");
                    button.connect_clicked(move |_| {
                        sink.send_click_tag(&tag);
                    });
                    core.buttons.push(button.clone());
                    NativeWidget::Button(button)
                }
                WidgetKind::Label => {
                    let label = gtk4::Label::new(None);
                    // kaya's normalized start, the leaf half of the breadth
                    // ruling: GtkLabel's 0.5 default centers the TEXT inside
                    // any box wider than it, so a grown or stretched label
                    // reads centered where WinUI, Compose and SwiftUI lead.
                    // Invisible at natural size — there the box IS the text.
                    label.set_xalign(0.0);
                    // TEXT WRAPS, the same semantics SwiftUI and Compose
                    // carry (the 2026-08-29 ruling): a label given less width
                    // than its text breaks lines instead of forcing its
                    // container wider than the screen. `wrap` alone does not
                    // wrap AT the parent's width — a requisition cannot depend
                    // on its parent — so the natural width is bounded too.
                    label.set_wrap(true);
                    label.set_wrap_mode(gtk4::pango::WrapMode::WordChar);
                    label.set_max_width_chars(KAYA_LABEL_MAX_WIDTH_CHARS);
                    core.labels.push(label.clone());
                    NativeWidget::Label(label)
                }
                WidgetKind::Scroll => {
// The vertical scroll viewport over its ONE child: its
// vadjustment is both the observation source and what
// scroll_end drives.
                    let scrolled = gtk4::ScrolledWindow::new();
                    // Vertical-only v1: no horizontal bar, ever.
                    scrolled.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);
                    // A SCROLL IS A VERTICAL CONTAINER, and saying so is what
                    // makes it SPAN a row's breadth (the 2026-08-22 crossing
                    // rule, `crosses_container`). Unmarked it took Align::Start
                    // and its NATURAL height — tiny for a scroller — so the
                    // portfolio's Transactions summary rendered as three
                    // clipped lines (measured 2026-08-30).
                    set_container_vertical(scrolled.upcast_ref::<gtk4::Widget>(), true);
                    set_scroll_kind(scrolled.upcast_ref::<gtk4::Widget>());
                    core.scrolls.push(scrolled.clone());
                    NativeWidget::Scroll(scrolled)
                }
                WidgetKind::Progress => {
// Display-only, like Label. Determinate = set_fraction;
// indeterminate = GTK's pulse mode, driven by a ticker.
                    let bar = gtk4::ProgressBar::new();
                    core.progresses.push(bar.clone());
                    NativeWidget::Progress(bar)
                }
                WidgetKind::Textarea => {
// The multi-line editor: GtkTextView, the entry's exact
// contract — the buffer's `changed` fires for programmatic
// set_text too, so the split rides apply_quiet.
                    let view = gtk4::TextView::new();
                    // THE SIZING CONTRACT: the editor takes its LAYOUT size
                    // and its content scrolls inside it. A bare GtkTextView
                    // grows to its content instead (400 lines, a 6400px widget,
                    // nothing scrollable — measured), so the TextView is the
                    // DIRECT child of the GtkScrolledWindow and wraps WordChar
                    // (docs/traps.md: "A bare GtkTextView grows to its content").
                    view.set_wrap_mode(gtk4::WrapMode::WordChar);
                    let scroller = gtk4::ScrolledWindow::new();
                    scroller.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);
                    // THE PIN THAT KEEPS THE VIEWPORT A VIEWPORT. Both
                    // default to false, and both are stated because either
                    // one set to true asks the scrolled window for its
                    // CHILD's natural size and restores the wart this arm
                    // exists to remove.
                    scroller.set_propagate_natural_width(false);
                    scroller.set_propagate_natural_height(false);
                    scroller.set_size_request(240, 96);
                    scroller.set_child(Some(&view));
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("textareas carry a tag");
                    let quiet = core.apply_quiet.clone();
                    let ledger_quiet = core.ledger_quiet.clone();
                    let dirty = core.native_dirty.clone();
                    let wid = id.0;
                    let buffer = view.buffer();
                    // A WEAK ref, not the view: the handler lives on the
                    // buffer the view owns, so a strong one would be a
                    // cycle that outlives the window.
                    let weak_view = glib::WeakRef::<gtk4::TextView>::new();
                    weak_view.set(Some(&view));
                    // THE LIVE COMPOSITION, reported by GTK itself. The
                    // signal carries the input method's string, so this is
                    // the platform saying what it is displaying — and when
                    // a programmatic selection move resets the IM context
                    // (which GTK does unconditionally, measured), it arrives
                    // here empty.
                    let composing = core.preedit.clone();
                    view.connect_preedit_changed(move |_, preedit| {
                        let mut map = composing.borrow_mut();
                        if preedit.is_empty() {
                            map.remove(&wid);
                        } else {
                            map.insert(wid, preedit.to_owned());
                        }
                    });
                    let declared = core.highlight_text.clone();
                    buffer.connect_changed(move |b| {
                        // D2 FIRST, and unconditionally — before the quiet
                        // gate, because a programmatic write invalidates a
                        // declared set exactly as a keystroke does.
                        drop_stale_highlights(&declared, wid, b);
                        if !quiet.get() {
                            let text =
                                lf(b.text(&b.start_iter(), &b.end_iter(), false).to_string());
                            sink.send_text_tag(&tag, &text);
                            if !ledger_quiet.get() {
                                let focused =
                                    weak_view.upgrade().is_some_and(|v| widget_focused(&v));
                                dirty.borrow_mut().insert(wid);
                                bank_text_changed(tag.clone(), text, focused);
                            }
                        }
                    });
                    core.textareas.push(view.clone());
                    NativeWidget::Textarea(scroller, view)
                }
                WidgetKind::Grid => {
                    // The 2D layout contract on GTK's own Grid: columns
                    // take their natural width (homogeneous off is the
                    // default), aligned across rows by the toolkit itself.
                    let grid = gtk4::Grid::new();
                    core.grid_children.insert(id.0, Vec::new());
                    core.grid_cols.insert(id.0, 1);
                    core.grids.push(grid.clone());
                    NativeWidget::Grid(grid)
                }
                WidgetKind::Radio => {
                    // The choice contract inline: GTK's radio idiom is
                    // grouped CheckButtons (set_group renders the circle) and
                    // the group's Box is the widget. Picks ride apply_quiet.
                    let group = gtk4::Box::new(gtk4::Orientation::Vertical, 4);
                    core.radio_tags
                        .insert(id.0, tag.clone().expect("radio groups carry a tag"));
                    core.radio_buttons.insert(id.0, Vec::new());
                    core.radios.push(group.clone());
                    NativeWidget::Radio(group)
                }
                WidgetKind::Select => {
                    // The dressed floor: GtkDropDown over a StringList — a
                    // select's label children are its OPTIONS, rows of this
                    // model. Programmatic writes ride the quiet guard.
                    let model = gtk4::StringList::new(&[]);
                    let dropdown =
                        gtk4::DropDown::new(Some(model.clone()), gtk4::Expression::NONE);
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("selects carry a tag");
                    let quiet = core.apply_quiet.clone();
                    dropdown.connect_selected_notify(move |dd| {
                        if !quiet.get() && dd.selected() != gtk4::INVALID_LIST_POSITION {
                            sink.send_value_tag(&tag, f64::from(dd.selected()));
                        }
                    });
                    core.select_models.insert(id.0, model);
                    core.selects.push(dropdown.clone());
                    NativeWidget::Select(dropdown)
                }
                WidgetKind::Image => {
                    // Display-only, like Label: no tag, no signal. The source
                    // arrives as a SetProp blob and decodes there.
                    let picture = gtk4::Picture::new();
                    core.images.push(picture.clone());
                    NativeWidget::Image(picture)
                }
                WidgetKind::Canvas => {
                    // The raw-pixel sibling of the arm above: a
                    // GdkMemoryTexture in a KayaCanvas, filled by the
                    // SetDrawing arm (docs/canvas-plan.md §8) and blitted
                    // 1:1 (§3.2.1, the type's own comment).
                    let canvas = KayaCanvas::default();
                    core.canvases.push(canvas.clone());
                    core.canvas_ids.push(id);
                    // The first canvas is what starts the window's frame
                    // clock: the track reader every policy needs, and the
                    // frame drive outside the harness.
                    attach_canvas_clock(core);
                    NativeWidget::Canvas(canvas)
                }
            };
            {
                // THE CONTROL: focus resolution picks the DEEPEST registered
                // widget containing the toplevel's focus widget, so the
                // textarea registers its GtkTextView, not the viewport.
                let weak = glib::WeakRef::new();
                weak.set(Some(&native.control()));
                core.clipboard
                    .widgets
                    .borrow_mut()
                    .insert(id.0, (weak, clip_editable));
                if let Some(tag) = clip_tag {
                    core.clipboard.tags.borrow_mut().insert(id.0, tag);
                }
            }
            core.widgets.insert(id, native);
        }
        ApplyOp::MoveChild {
            parent,
            child,
            before,
        } => {
            use gtk4::prelude::WidgetExt;
            let parent_box = match core.widgets.get(&parent).expect("scene validated the id") {
                // The table's rows are ordered inside its viewport, where
                // the AddChild above parented them.
                NativeWidget::Column(b) => core
                    .tables
                    .get(&parent.0)
                    .map_or_else(|| b.clone(), |t| t.content.clone()),
                NativeWidget::Row(b) => b.clone(),
                _ => panic!("kaya: move_child parent is not a container"),
            };
            let child_widget = core
                .widgets
                .get(&child)
                .expect("scene validated the id")
                .widget();
            // gtk speaks after-semantics; before(anchor) = after(anchor's
            // previous sibling), and None (end) = after the last child.
            let after = match before {
                Some(anchor) => core
                    .widgets
                    .get(&anchor)
                    .expect("scene validated the id")
                    .widget()
                    .prev_sibling(),
                None => parent_box.last_child(),
            };
            if after.as_ref() != Some(&child_widget) {
                parent_box.reorder_child_after(&child_widget, after.as_ref());
            }
        }
        ApplyOp::Fold { child, table } => {
            // The stacked fold (D7): the child moves INTO the table's
            // content box, above the top spacer, and scrolls away with
            // the rows — under this backend's pinned header, which is
            // its own idiom. Identity does not move: the widget keeps
            // its id and its registry entries; reflow_table and the
            // class filters keep it out of every row read.
            use gtk4::prelude::WidgetExt;
            let child_widget = core
                .widgets
                .get(&child)
                .expect("scene validated the id")
                .widget();
            if table.0 != 0 {
                let Some(t) = core.tables.get(&table.0) else {
                    panic!("kaya: fold into {table:?}, which declared no columns");
                };
                let content = t.content.clone();
                core.folded_into.insert(child.0, table.0);
                child_widget.add_css_class(KAYA_FOLDED_CLASS);
                if let Some(parent) = child_widget
                    .parent()
                    .and_then(|p| p.downcast::<gtk4::Box>().ok())
                {
                    parent.remove(&child_widget);
                }
                // Spanning, like a scroll viewport's one child; the
                // unfold's reconcile restores the authored alignment.
                child_widget.set_halign(gtk4::Align::Fill);
                child_widget.set_margin_bottom(KAYA_FOLD_SEAM_GAP);
                let mut after: Option<gtk4::Widget> = None;
                for w in children_of(&content) {
                    if w.has_css_class(KAYA_FOLDED_CLASS) {
                        after = Some(w);
                    }
                }
                content.insert_child_after(&child_widget, after.as_ref());
            } else if let Some(tid) = core.folded_into.remove(&child.0) {
                child_widget.remove_css_class(KAYA_FOLDED_CLASS);
                child_widget.set_margin_bottom(0);
                if let Some(t) = core.tables.get(&tid) {
                    t.content.remove(&child_widget);
                }
                // Back BEFORE the table it came out of — the rule folds
                // leading siblings only, and the ops arrive in recorded
                // order, so each lands after the one before it.
                if let Some(table_widget) =
                    core.widgets.get(&WidgetId(tid)).map(|w| w.widget())
                {
                    if let Some(parent) = table_widget
                        .parent()
                        .and_then(|p| p.downcast::<gtk4::Box>().ok())
                    {
                        parent.insert_child_after(
                            &child_widget,
                            table_widget.prev_sibling().as_ref(),
                        );
                    }
                }
                reconcile_grow_align(&child_widget);
            }
        }
        ApplyOp::Destroy { id } => {
            // The clipboard hub forgets the widget with it (the weak
            // ref would go stale on its own; the maps must not grow).
            core.clipboard.widgets.borrow_mut().remove(&id.0);
            core.clipboard.tags.borrow_mut().remove(&id.0);
            core.clipboard.accepts.borrow_mut().remove(&id.0);
            // A destroyed For container takes its composed header with
            // it; the entry would otherwise outlive the widget it holds.
            core.tables.remove(&id.0);
            core.folded_into.remove(&id.0);
            // A destroyed anchor takes its context attachment with it (menu
            // ITEMS are never destroyed): the popover unparents BEFORE the
            // widget leaves its container, and a dangling open-context claim
            // is released (docs/traps.md).
            if let Some(attachment) = core.context_menus.remove(&id.0) {
                {
                    let mut open = core.open_context.borrow_mut();
                    if *open == Some(id.0) {
                        *open = None;
                        #[cfg(feature = "harness")]
                        note_claim(&core.context_trail, "anchor destroyed", None);
                    }
                }
                let mut reg = core.menus.borrow_mut();
                for (item, action) in &attachment.actions {
                    if let Some(state) = reg.items.get_mut(item) {
                        state.actions.retain(|a| a != action);
                    }
                }
                for widgets in reg.context_of.values_mut() {
                    widgets.retain(|w| *w != id.0);
                }
                attachment.popover.unparent();
            }
            let widget = core
                .widgets
                .remove(&id)
                .expect("scene validated the id")
                .widget();
            if let Some(parent) = widget.parent() {
                if let Ok(column) = parent.downcast::<gtk4::Box>() {
                    column.remove(&widget);
                }
            }
        }
        ApplyOp::SetWindowProp { window, prop, value } => {
            use gtk4::prelude::GtkWindowExt;
            let target = gtk_window(core, window.0);
            match (prop, &value) {
                (WindowProp::Title, Value::Str(title)) => {
                    // The window's OWN title; while a navigation entry covers
                    // it the entry's title shows. AND IT IS THE APP'S, which
                    // stops a declared identity name from overriding it.
                    core.app_titled.insert(window.0);
                    core.window_titles.insert(window.0, title.clone());
                    let covered = core
                        .nav_stacks
                        .get(&window.0)
                        .is_some_and(|s| !s.is_empty());
                    if !covered {
                        target.set_title(Some(title));
                    }
                }
                // The advisory size request. GTK4's one public size verb is
                // set_default_size; the WM keeps the last word — exactly the
                // request semantics (DESIGN.md, Presentation contexts).
                (WindowProp::Width, Value::F64(w)) => {
                    let (_, h) = target.default_size();
                    target.set_default_size(*w as i32, h);
                }
                (WindowProp::Height, Value::F64(h)) => {
                    let (w, _) = target.default_size();
                    target.set_default_size(w, *h as i32);
                }
                (WindowProp::VetoClose, Value::Bool(on)) => {
                    core.window_veto.borrow_mut().insert(window.0, *on);
                }
                (WindowProp::Panes, Value::I64(n)) => {
                    core.panes.insert(window.0, *n);
                    refresh_nav(core, window.0);
                }
                // The unsaved-work marker beside the header-bar title
                // (docs/dirty-plan.md D2). THE TITLE STRING IS NOT TOUCHED
                // here or anywhere, and there is no materialization hazard:
                // the marker is built with the window's chrome.
                (WindowProp::Dirty, Value::Bool(on)) => {
                    use gtk4::prelude::WidgetExt;
                    core.dirty_markers
                        .get(&window.0)
                        .expect("every kaya window installs its chrome")
                        .set_visible(*on);
                }
                (WindowProp::Inset, Value::F64(units)) => {
                    // LAYOUT, not appearance (docs/styling-plan.md D3):
                    // rewrite the one provider the padding lives in.
                    // Whole pixels — GTK CSS padding takes integers.
                    core.inset = *units;
                    load_kaya_css(
                        &core.inset_css,
                        "root inset",
                        &format!(".kaya-root {{ padding: {}px; }}", units.round() as i64),
                        &core.css_error,
                    );
                }
                (WindowProp::SectionsPresentation, Value::I64(hint)) => {
                    // ADVISORY: bar/auto = the header StackSwitcher,
                    // sidebar = GtkStackSidebar; the chrome rebuilds
                    // if it already exists.
                    core.sections_presentation.insert(window.0, *hint);
                    if core.sections.contains_key(&window.0) {
                        refresh_sections(core, window.0);
                    }
                }
                (p, v) => unreachable!("scene validated window prop {p:?}/{v:?}"),
            }
        }
        ApplyOp::CreateWindow { window } => {
            // Materializes hidden; mounting a root presents it. The
            // normalized 540x330 default rides the primary's paths.
            use gtk4::prelude::GtkWindowExt;
            let aux = gtk4::Window::builder()
                .default_width(540)
                .default_height(330)
                .build();
            // A NEW WINDOW WITH NO TITLE WEARS THE APP'S NAME
            // (docs/app-identity-plan.md I9). Written into `window_titles`
            // too, because that map is what navigation fallbacks restore from.
            if let Some(caption) = identity_caption(core, window.0) {
                core.window_titles.insert(window.0, caption.clone());
                aux.set_title(Some(&caption));
            }
            let chrome = install_nav_chrome(&aux, window.0);
            core.toolbar_views.insert(window.0, chrome.view);
            core.header_bars.insert(window.0, chrome.header);
            core.toolbar_groups.insert(window.0, chrome.promoted);
            core.back_buttons.insert(window.0, chrome.back);
            core.dirty_markers.insert(window.0, chrome.marker);
            wire_close(
                &aux,
                window.0,
                core.window_veto.clone(),
                core.occurrences.clone(),
            );
            // Window-scoped menu actions for a PLAIN window: the primary is a
            // GtkApplicationWindow whose own ActionMap exports "win"; an
            // auxiliary needs the group inserted by hand under that prefix.
            let actions = gio::SimpleActionGroup::new();
            aux.insert_action_group("win", Some(&actions));
            core.menu_action_groups.insert(window.0, actions);
            core.aux_windows.insert(window.0, aux);
        }
        ApplyOp::DestroyWindow { window } => {
            use gtk4::prelude::GtkWindowExt;
            if let Some(aux) = core.aux_windows.remove(&window.0) {
                // destroy() skips close_request: no spurious
                // window_closed for an app-initiated close.
                aux.destroy();
            }
            core.window_veto.borrow_mut().remove(&window.0);
            // A destroyed window takes its navigation stack with it.
            for entry in core.nav_stacks.remove(&window.0).unwrap_or_default() {
                core.nav_entries.remove(&entry);
            }
            core.window_roots.remove(&window.0);
            core.window_titles.remove(&window.0);
            core.app_titled.remove(&window.0);
            core.identity_icon_on.remove(&window.0);
            core.back_buttons.remove(&window.0);
            core.dirty_markers.remove(&window.0);
            // ... and its sections, each with ITS stack (the one way
            // a section dies).
            for sid in core.sections.remove(&window.0).unwrap_or_default() {
                core.section_pages.remove(&sid);
                for entry in core.nav_stacks.remove(&sid).unwrap_or_default() {
                    core.nav_entries.remove(&entry);
                }
            }
            core.section_stacks.remove(&window.0);
            core.section_chrome.remove(&window.0);
            core.sections_rendered.remove(&window.0);
            core.selected_sections.remove(&window.0);
            core.sections_presentation.remove(&window.0);
            // ... and its menu chrome. The registry keeps the items; only
            // this window's bar list and materialization go.
            core.menu_models.remove(&window.0);
            core.menu_strips.remove(&window.0);
            core.menu_action_groups.remove(&window.0);
            // ... and its shell, which went with the destroyed window.
            core.toolbar_views.remove(&window.0);
            core.header_bars.remove(&window.0);
            core.toolbar_groups.remove(&window.0);
            {
                let mut reg = core.menus.borrow_mut();
                reg.bars.remove(&window.0);
                reg.bar_of.retain(|_, w| *w != window.0);
            }
        }
        ApplyOp::PushEntry { window, entry } => {
            // Materializes covered/incoming: on the stack now, the
            // mount fills and presents it.
            core.nav_entries.insert(
                entry.0,
                GtkNavEntry {
                    window: window.0,
                    title: String::new(),
                    intercept_back: false,
                    root: None,
                },
            );
            core.nav_stacks.entry(window.0).or_default().push(entry.0);
        }
        ApplyOp::PopEntry { window } => {
            // Programmatic pop: the core already reconciled its stack; drop
            // the top and reconcile the visible state.
            let top = core
                .nav_stacks
                .get_mut(&window.0)
                .and_then(|s| s.pop())
                .expect("scene validated the pop");
            core.nav_entries.remove(&top);
            refresh_nav(core, window.0);
        }
        ApplyOp::SetEntryProp { entry, prop, value } => {
            use crate::protocol::EntryProp;
            let record = core
                .nav_entries
                .get_mut(&entry.0)
                .expect("scene validated the entry id");
            match (prop, &value) {
                (EntryProp::Title, Value::Str(title)) => {
                    record.title = title.clone();
                }
                (EntryProp::InterceptBack, Value::Bool(on)) => {
                    record.intercept_back = *on;
                }
                (p, v) => unreachable!("scene validated entry prop {p:?}/{v:?}"),
            }
            let window = record.window;
            if core.nav_stacks.get(&window).and_then(|s| s.last()) == Some(&entry.0) {
                refresh_nav(core, window);
            }
        }
        ApplyOp::AddSection { window, section } => {
            // Append-only: a page container joins the window's stack and the
            // mount fills it. First added is selected.
            let page = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
            core.section_pages.insert(
                section.0,
                GtkSectionPage {
                    window: window.0,
                    page,
                    title: String::new(),
                    symbol: 0,
                    root: None,
                },
            );
            core.sections.entry(window.0).or_default().push(section.0);
            core.selected_sections.entry(window.0).or_insert(section.0);
            refresh_sections(core, window.0);
        }
        ApplyOp::SelectSection { window, section } => {
            // Programmatic and QUIET: the stack moves under the echo guard,
            // so notify::visible-child stays silent.
            core.selected_sections.insert(window.0, section.0);
            if let Some(stack) = core.section_stacks.get(&window.0) {
                use gtk4::prelude::WidgetExt;
                core.apply_quiet.set(true);
                stack.set_visible_child_name(&section.0.to_string());
                core.apply_quiet.set(false);
                let _ = stack; // chrome stays as-is
            }
        }
        ApplyOp::SetSectionProp { section, prop, value } => {
            use crate::protocol::SectionProp;
            let record = core
                .section_pages
                .get_mut(&section.0)
                .expect("scene validated the section id");
            match (prop, &value) {
                (SectionProp::Title, Value::Str(title)) => {
                    record.title = title.clone();
                    let window = record.window;
                    if let Some(stack) = core.section_stacks.get(&window) {
                        let page = &core.section_pages[&section.0].page;
                        use gtk4::prelude::Cast;
                        let stack_page = stack.page(page.upcast_ref::<gtk4::Widget>());
                        stack_page.set_title(&core.section_pages[&section.0].title);
                    }
                }
                // THE SEMANTIC ICON NAME (docs/styling-plan.md D6): onto
                // GtkStackPage's own `icon-name`, the slot both switcher
                // spellings read the page through.
                (SectionProp::Symbol, Value::I64(symbol)) => {
                    assert_symbol_icons_resolve(&gtk4::prelude::WidgetExt::display(&core.window));
                    record.symbol = *symbol;
                    let window = record.window;
                    refresh_section_symbols(core, window);
                }
                // Day-one slot: accepted; the switcher TITLE is the
                // harness observable (GTK's switcher shows titles).
                (SectionProp::Icon, Value::Blob(_)) => {}
                (p, v) => unreachable!("scene validated section prop {p:?}/{v:?}"),
            }
        }
        ApplyOp::MenuItemCreate { item, kind } => {
            // Registry only: actions and chrome materialize at anchor time,
            // when the item's window (or anchor widget) is known.
            core.menus.borrow_mut().items.insert(
                item.0,
                MenuItemState {
                    kind,
                    label: String::new(),
                    enabled: true,
                    checked: false,
                    value: 0.0,
                    primary: false,
                    symbol: 0,
                    role: String::new(),
                    shortcut: String::new(),
                    parent: None,
                    children: Vec::new(),
                    actions: Vec::new(),
                },
            );
        }
        ApplyOp::MenuItemAppend { parent, child } => {
            {
                let mut reg = core.menus.borrow_mut();
                reg.items
                    .get_mut(&child.0)
                    .expect("scene validated the child id")
                    .parent = Some(parent.0);
                reg.items
                    .get_mut(&parent.0)
                    .expect("scene validated the parent id")
                    .children
                    .push(child.0);
            }
            // Append-at-any-time: a subtree landing under an anchored root
            // materializes NOW.
            let (bar, contexts) = {
                let reg = core.menus.borrow();
                let root = menu_root_of(&reg, child.0);
                (
                    reg.bar_of.get(&root).copied(),
                    reg.context_of.get(&root).cloned().unwrap_or_default(),
                )
            };
            if let Some(window) = bar {
                register_bar_actions(core, window, child.0);
            }
            for widget in &contexts {
                register_context_actions(core, *widget, child.0);
            }
            rebuild_menu_anchors(core, child.0);
        }
        ApplyOp::MenubarAppend { window, item } => {
            {
                let mut reg = core.menus.borrow_mut();
                reg.bars.entry(window.0).or_default().push(item.0);
                reg.bar_of.insert(item.0, window.0);
            }
            ensure_menu_strip(core, window.0);
            register_bar_actions(core, window.0, item.0);
            rebuild_menubar(core, window.0);
        }
        ApplyOp::ContextAttach { widget, item } => {
            context_attach(core, widget.0, item.0, Vec::new());
        }
        ApplyOp::ContextAttachNode { widget, item, path } => {
            // The stamped copy's key path IS the noun: baked into the
            // attachment's action tags (the on_click_node encoding).
            context_attach(core, widget.0, item.0, path);
        }
        ApplyOp::SetMenuProp { item, prop, value } => {
            use gtk4::glib::prelude::ToVariant;
            // EXHAUSTIVE over the prop: a new MENU_PROPS row fails to
            // compile here rather than reaching a catch-all at runtime.
            match prop {
                MenuProp::Label => {
                    let label = crate::protocol::prop_str(&value);
                    core.menus
                        .borrow_mut()
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .label = label.to_owned();
                    // Labels are live: whatever chrome presents the
                    // tree re-renders (GMenu snapshots are immutable).
                    rebuild_menu_anchors(core, item.0);
                }
                MenuProp::Enabled => {
                    {
                        let mut reg = core.menus.borrow_mut();
                        reg.items
                            .get_mut(&item.0)
                            .expect("scene validated the item id")
                            .enabled = crate::protocol::prop_bool(&value);
                    }
                    // The inherited AND lands on every descendant's REAL
                    // action; enablement is live action state and never emits.
                    {
                        let reg = core.menus.borrow();
                        menu_sync_enabled(&reg, item.0);
                    }
                    // menu_sync_enabled wrote STRUCTURAL enablement alone,
                    // which would un-gray a role item whose clipboard half
                    // says no — the role factor goes back on top.
                    refresh_roles(core);
                }
                MenuProp::Checked => {
                    // QUIET (the echo doctrine): set_state never fires
                    // activate, so the write configures the native checkmark
                    // without an occurrence.
                    let on = crate::protocol::prop_bool(&value);
                    let mut reg = core.menus.borrow_mut();
                    let state = reg
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id");
                    state.checked = on;
                    for action in &state.actions {
                        action.set_state(&on.to_variant());
                    }
                }
                MenuProp::Value => {
                    // QUIET, same as checked. The state lives on the
                    // OPTIONS' actions, one per option, so the group's write
                    // fans out to all of them.
                    let mut reg = core.menus.borrow_mut();
                    reg.items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .value = crate::protocol::prop_f64(&value);
                    menu_sync_radio_state(&reg, item.0);
                }
                MenuProp::Primary => {
                    // THE CHROME PROMOTION BIT (DESIGN.md, "Chrome
                    // promotion and `primary`"). Its OWN call rather than a
                    // model rebuild — `primary` moves the promoted set
                    // without changing a single GMenu row.
                    core.menus
                        .borrow_mut()
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .primary = crate::protocol::prop_bool(&value);
                    let window = {
                        let reg = core.menus.borrow();
                        reg.bar_of.get(&menu_root_of(&reg, item.0)).copied()
                    };
                    if let Some(window) = window {
                        refresh_toolbar(core, window);
                    }
                }
                MenuProp::Shortcut => {
                    core.menus
                        .borrow_mut()
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .shortcut = crate::protocol::prop_str(&value).to_owned();
                    let window = {
                        let reg = core.menus.borrow();
                        reg.bar_of.get(&menu_root_of(&reg, item.0)).copied()
                    };
                    if let Some(window) = window {
                        refresh_menu_accels(core, window);
                    }
                }
                MenuProp::Icon => {
                    // Day-one slot: accepted; GTK's menu dress carries no item
                    // icons (DESIGN.md, Menus).
                }
                // THE SEMANTIC ICON NAME (docs/styling-plan.md D6): onto the
                // GMenu row's `icon` attribute. GMenu items are immutable
                // snapshots, so the write is a registry update plus a full
                // rebuild. The theme wall runs HERE, on the first symbol any
                // app declares: an app with no symbols must not be able to
                // die of an icon theme it never asked for.
                MenuProp::Symbol => {
                    let Value::I64(symbol) = value else {
                        unreachable!("kaya: menu symbol wants I64, the root passed {value:?}")
                    };
                    assert_symbol_icons_resolve(&gtk4::prelude::WidgetExt::display(&core.window));
                    core.menus
                        .borrow_mut()
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .symbol = symbol;
                    rebuild_menu_anchors(core, item.0);
                }
                MenuProp::Role => {
                    // PLACEMENT is a request this host has nowhere to honor —
                    // no dress-owned application menu — so the item stays
                    // where the app declared it. BEHAVIOR is not: a clipboard
                    // role's activation performs the standard command on the
                    // focused widget, so the role items resync now.
                    core.menus
                        .borrow_mut()
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .role = crate::protocol::prop_str(&value).to_owned();
                    refresh_roles(core);
                }
            }
        }

        ApplyOp::Copy(clip) => {
            core.clipboard.armed.set(true);
            // One provider per populated representation, unioned: the union
            // advertises all of them (measured §5b — it does not let the
            // last provider win).
            let mut providers: Vec<gdk::ContentProvider> = Vec::new();
            // Descending clip value — custom, files, image, html, text —
            // the canonical order (§1).
            for (id, bytes) in &clip.custom {
                providers.push(gdk::ContentProvider::for_bytes(
                    id,
                    &glib::Bytes::from(&bytes.0[..]),
                ));
            }
            if !clip.files.is_empty() {
                // text/uri-list with the RFC's CRLF separators and trailing
                // terminator (measured: the foreign reader is unbothered
                // either way, so the RFC spelling stands).
                let mut uris = String::new();
                for path in &clip.files {
                    match glib::filename_to_uri(path, None) {
                        Ok(uri) => {
                            uris.push_str(&uri);
                            uris.push_str("\r\n");
                        }
                        Err(e) => panic!(
                            "kaya: copy carries file locator {path:?} that does \
                             not name a filesystem path: {e}"
                        ),
                    }
                }
                providers.push(gdk::ContentProvider::for_bytes(
                    "text/uri-list",
                    &glib::Bytes::from_owned(uris.into_bytes()),
                ));
            }
            if let Some(png) = &clip.image {
                // RAW BYTES UNDER THE TYPE, never GdkTexture: the texture
                // re-encodes on demand and the bytes stop round-tripping (the
                // macOS writeObjects lesson, measured again here, §5b).
                providers.push(gdk::ContentProvider::for_bytes(
                    "image/png",
                    &glib::Bytes::from(&png.0[..]),
                ));
            }
            if let Some(html) = &clip.html {
                // Raw UTF-8 under the bare type; GDK adds no charset alias
                // for html (measured §5b), which is what the reader asks for.
                providers.push(gdk::ContentProvider::for_bytes(
                    "text/html",
                    &glib::Bytes::from_owned(html.clone().into_bytes()),
                ));
            }
            if let Some(text) = &clip.text {
                use gtk4::glib::prelude::ToValue;
                // A string VALUE, not bytes: GTK derives the
                // text/plain spellings and charset aliases from it.
                providers.push(gdk::ContentProvider::for_value(&text.to_value()));
            }
            let provider = if providers.len() == 1 {
                providers.remove(0)
            } else {
                gdk::ContentProvider::new_union(&providers)
            };
            let clipboard = gtk4::prelude::WidgetExt::display(&core.window).clipboard();
            if let Err(e) = clipboard.set_content(Some(&provider)) {
                // This error is LOCAL bookkeeping only. The failure that
                // matters — the compositor rejecting the selection for want of
                // an input serial — is silent BY DESIGN (§5b finding 3).
                panic!("kaya: clipboard set_content failed: {e}");
            }
            refresh_roles(core);
        }
        ApplyOp::ReadClipboard { request, accepting } => {
            core.clipboard.armed.set(true);
            let clipboard = gtk4::prelude::WidgetExt::display(&core.window).clipboard();
            let sink = core.occurrences.clone();
            materialize_clipboard(
                &clipboard,
                &accepting,
                Box::new(move |clip| {
                    // Answered exactly once; None IS an answer — the universal
                    // no (denied, absent, unfocused, nothing-accepted alike).
                    sink.send(Occurrence::ClipboardResult { request, clip });
                }),
            );
        }
        // THE THREE TEXT-RANGE PRIMITIVES (docs/ranges-plan.md D1). All three
        // arrive in GTK'S OWN UNIT — CODE POINTS, converted by the core
        // against the text it validated the byte offsets against (scene.rs
        // `native_offset`) — so there is no Unicode arithmetic below and
        // there must never be.
        ApplyOp::HighlightRanges { id, ranges } => {
            let Some(NativeWidget::Textarea(_, view)) = core.widgets.get(&id) else {
                return;
            };
            let buffer = view.buffer();
            // THE BUFFER'S OWN TEXT, read once: the D2 record needs it and so
            // does every offset below, because the buffer keeps a CR the guest
            // was never told about.
            let raw = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string();
            // DECLARATIVE: the set REPLACES the previous one, and an empty
            // list is the clear. `remove_all_tags` is safe to aim at the
            // whole buffer because kaya creates exactly one tag on it.
            buffer.remove_all_tags(&buffer.start_iter(), &buffer.end_iter());
            let tag = highlight_tag(&buffer);
            for range in &ranges {
                // THE UNIT ASSERTION. GTK is the one backend whose native unit
                // differs from everyone else's: a byte offset that reached
                // here unconverted indexes a LONGER string. The ranges scene's
                // document opens with CJK so a forwarded byte offset is six
                // characters wrong rather than accidentally right.
                assert!(
                    range.stop <= buffer.char_count() as u64,
                    "kaya: highlight_ranges on {id:?}: offset {} is past the buffer's {} \
                     CODE POINTS — GTK counts code points and the core converts byte \
                     offsets before lowering (scene.rs native_offset); an unconverted \
                     byte offset looks exactly like this",
                    range.stop,
                    buffer.char_count()
                );
                buffer.apply_tag(
                    &tag,
                    &buffer.iter_at_offset(buffer_offset(&raw, range.start)),
                    &buffer.iter_at_offset(buffer_offset(&raw, range.stop)),
                );
            }
            // AND RECORD THE TEXT IT WAS DECLARED AGAINST — D2's whole
            // mechanism here, since GTK's tags would otherwise follow the
            // next edit rather than being dropped by it.
            core.highlight_text.borrow_mut().insert(id.0, lf(raw));
        }
        ApplyOp::SelectRange { id, range } => {
            let Some(NativeWidget::Textarea(_, view)) = core.widgets.get(&id) else {
                return;
            };
            // D4, AND THIS BACKEND IS WHERE THE HAZARD WAS MEASURED.
            // `select_range` cancels an active composition UNCONDITIONALLY —
            // even for the range already selected, even for the caret's
            // existing position (all three measured). So the backend asks
            // first: a live preedit means the user is mid-word. Refused as a
            // no-op under a named reason, never a panic.
            if let Some(preedit) = core.preedit.borrow().get(&id.0) {
                kaya_diag!(
                    "KAYA_DIAG select_range refused: ime_composition (widget {}, preedit {preedit:?})",
                    id.0
                );
                return;
            }
            let buffer = view.buffer();
            let raw = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string();
            let start = buffer.iter_at_offset(buffer_offset(&raw, range.start));
            let stop = buffer.iter_at_offset(buffer_offset(&raw, range.stop));
            // The insert mark goes FIRST, so the caret lands at the end of the
            // range — the direction a search result is selected in.
            // `selection_bounds()` normalizes; the marks keep the direction.
            buffer.select_range(&stop, &start);
        }
        ApplyOp::SetDrawing { id, width, height, scale, pixels } => {
            if let Some(NativeWidget::Canvas(canvas)) = core.widgets.get(&id) {
                set_drawing(&canvas.clone(), width, height, scale, &pixels.0);
            }
        }
        ApplyOp::SetColumnHeaders { id, sorted, direction, titles, tag } => {
            // kaya's own header row over the For's stamped children
            // (docs/tables-plan.md decision 6). The whole bar is ONE
            // record, so this arm is idempotent: the cells are rebuilt
            // only when the column COUNT moves, and a sort flip is a
            // relabel plus a fresh tag.
            let Some(NativeWidget::Column(column)) = core.widgets.get(&id) else {
                return;
            };
            let column = column.clone();
            // The card: this container IS the table's extent, and the
            // class is the whole lowering (TABLE_CSS).
            column.add_css_class(TABLE_CARD_CLASS);
            let rebuild = !core
                .tables
                .get(&id.0)
                .is_some_and(|t| children_of(&t.header).len() == titles.len());
            if rebuild {
                if let Some(old) = core.tables.remove(&id.0) {
                    column.remove(&old.head);
                    column.remove(&old.divider);
                    // The rows outlive the header they were declared
                    // under; they go back on the container and the new
                    // table's reflow migrates them into its own viewport.
                    for row in table_rows(&column) {
                        old.content.remove(&row);
                        column.append(&row);
                    }
                    column.remove(&old.body);
                }
                let table = build_table(
                    &core.occurrences,
                    titles.len(),
                    Rc::new(RefCell::new(tag.clone())),
                    id.0,
                );
                core.tables.insert(id.0, table);
            }
            let table = core.tables.get(&id.0).expect("just built");
            *table.tag.borrow_mut() = tag;
            for (index, cell) in children_of(&table.header).into_iter().enumerate() {
                // The indicator rides the title, so `columns_presented`
                // reads BOTH out of the toolkit's own text.
                let mut text = titles[index].clone();
                if sorted as usize == index {
                    text.push(' ');
                    text.push(if direction == 0 { '\u{25B2}' } else { '\u{25BC}' });
                }
                if let Some(label) = cell
                    .downcast_ref::<gtk4::Button>()
                    .and_then(|b| b.child())
                    .and_then(|c| c.downcast::<gtk4::Label>().ok())
                {
                    label.set_text(&text);
                }
            }
            reflow_table(core, id.0);
        }
        ApplyOp::SetAppIdentity(identity) => {
            // THE APP'S NAME AND ITS MARK, GTK's half
            // (docs/app-identity-plan.md I4a and I9). Both halves are lowered
            // AND recorded, because the read has to tell "kaya never set one"
            // from "kaya set one and the platform did not keep it". THE NAME
            // GOES ON THE PROGRAM NAME FIRST — `g_get_prgname()` is the lever
            // for app_id, WM_CLASS and AT-SPI — so `reclass_toplevels` follows.
            if !identity.name.is_empty() {
                glib::set_prgname(Some(identity.name.as_str()));
                glib::set_application_name(&identity.name);
                core.identity_name = Some(identity.name.clone());
                let moves = reclass_toplevels(core, &identity.name);
                report_class_moves(&moves, &identity.name);
                // ...and the name fills the blank on every window that has
                // none of its own. Never over a title the app wrote:
                // `identity_caption` carries that rule.
                let live: Vec<u64> =
                    std::iter::once(0).chain(core.aux_windows.keys().copied()).collect();
                for id in live {
                    let Some(caption) = identity_caption(core, id) else {
                        continue;
                    };
                    core.window_titles.insert(id, caption.clone());
                    if let Some(target) = gtk_window_read(core, id) {
                        use gtk4::prelude::GtkWindowExt;
                        target.set_title(Some(&caption));
                    }
                }
            }
            // THE BYTES ARE THE PLATFORM'S DECODER'S BUSINESS: kaya never
            // inspects them, and whether a blob is an image is a question
            // only GDK can answer. A refusal is RECORDED rather than fatal,
            // and the observation is what says so.
            core.identity_icon = match &identity.icon {
                None => IdentityIcon::Undeclared,
                Some(blob) => {
                    let bytes = glib::Bytes::from_owned(blob.0.clone());
                    match gtk4::gdk::Texture::from_bytes(&bytes) {
                        Ok(texture) => IdentityIcon::Texture(texture),
                        Err(why) => {
                            kaya_diag!(
                                "KAYA_DIAG app identity: GDK refused the declared icon \
                                 blob ({} bytes): {why} — the platform's own icon stays \
                                 in place",
                                blob.0.len()
                            );
                            IdentityIcon::Refused {
                                bytes: blob.0.len(),
                                why: why.to_string(),
                            }
                        }
                    }
                }
            };
            core.identity_icon_on.clear();
            let live: Vec<u64> =
                std::iter::once(0).chain(core.aux_windows.keys().copied()).collect();
            for id in live {
                apply_identity_icon(core, id);
            }
        }
        ApplyOp::SetTypeface(request) => {
            // THE BRAND TYPEFACE, GTK's half (docs/styling-plan.md Slice 2b):
            // one `:root { font-family }` rule at APPLICATION priority. THE
            // ROW IS PICKED HERE because a LOWERING IS ITS PLATFORM while a
            // binding is not (the JVM says "Linux" on Android).
            let family = request.family_for(crate::wire::this_platform()).to_owned();
            // FONT BYTES: registered with the live text system BEFORE the name
            // machinery runs, and the family that registration named is what
            // the rule then asks for — register-then-resolve, so both forms of
            // the request share one lowering. NOT fontconfig's app-font API:
            // see register_font_blob.
            let family = match &request.font {
                Some(blob) => register_font_blob(core, &blob.0, &family).unwrap_or(family),
                None => family,
            };
            core.typeface_request = Some(family.clone());
            load_kaya_css(
                &core.typeface_css,
                "brand typeface",
                &typeface_css_for(&family),
                &core.css_error,
            );
        }
        ApplyOp::SetBrand { accent } => {
            // libadwaita's documented app override, written into kaya's own
            // provider. The request is recorded first: the appearance can flip
            // afterwards, and the notify handler re-lowers from this value.
            *core.brand.borrow_mut() = Some(accent);
            let dark = adw::StyleManager::default().is_dark();
            load_kaya_css(
                &core.brand_css,
                "brand accent",
                &brand_css_for(accent, dark),
                &core.css_error,
            );
        }
        ApplyOp::RevealRange { id, range } => {
            let Some(NativeWidget::Textarea(_, view)) = core.widgets.get(&id) else {
                return;
            };
            // A PURE EFFECT: it moves the viewport and nothing else — no
            // selection change, no `changed`, no interference with a
            // composition (measured: a `scroll_to_mark` mid-preedit left the
            // preedit alive and the commit intact). THE VIEWPORT IS THE
            // FOUNDATION'S: a bare GtkTextView's page size equals its content
            // height, and `scroll_to_mark` returned TRUE while moving nothing.
            let buffer = view.buffer();
            let raw = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string();
            let at = buffer.iter_at_offset(buffer_offset(&raw, range.start));
            let mark = match buffer.mark(REVEAL_MARK) {
                Some(mark) => {
                    buffer.move_mark(&mark, &at);
                    mark
                }
                None => buffer.create_mark(Some(REVEAL_MARK), &at, true),
            };
            view.scroll_to_mark(&mark, 0.0, false, 0.0, 0.0);
        }
        ApplyOp::ClearUndo { window } => {
            if let Some(id) = focused_text_in(core, window) {
                core.clear_native_undo(id);
            }
        }
        ApplyOp::PresentSaveDialog(spec) => {
            // GNOME's own save panel, and the SAME OBJECT the picker builds —
            // gtk::FileDialog asked to `save()` rather than `open()`. What
            // differs is two lines: the initial name, and the SOURCE the
            // answer is registered as.
            let parent = gtk_window(core, spec.window.0);
            let title = format!("kaya save {}", spec.dialog.0);
            let dialog = gtk4::FileDialog::builder()
                .title(&title)
                .modal(true)
                .build();

            // ADVISORY on every platform (DESIGN.md), the picker's rule
            // unchanged: a default view, never a guarantee.
            if !spec.filters.is_empty() {
                let filters = gtk4::gio::ListStore::new::<gtk4::FileFilter>();
                for (label, suffix) in &spec.filters {
                    let filter = gtk4::FileFilter::new();
                    filter.set_name(Some(label));
                    filter.add_suffix(suffix);
                    filters.append(&filter);
                }
                dialog.set_filters(Some(&filters));
            }

            // The name the panel OPENS with, in its name field. Advisory:
            // the user types over it, and the guest reads the name it GOT.
            dialog.set_initial_name(Some(spec.suggested_name.as_str()));

            // The armed directory, applied HERE for the picker's reason —
            // this is the only moment a chooser reads it.
            if let Some(dir) = core.pending_dialog_dir.borrow_mut().take() {
                dialog.set_initial_folder(Some(&gtk4::gio::File::for_path(&dir)));
            }

            *core.live_file_dialog.borrow_mut() = Some(GtkLiveFileDialog {
                title: title.clone(),
            });
            let live = core.live_file_dialog.clone();
            let sink = core.occurrences.clone();
            let dialog_id = spec.dialog.0;

            dialog.save(
                Some(&parent),
                None::<&gtk4::gio::Cancellable>,
                move |result| {
                    *live.borrow_mut() = None;
                    // A DESTINATION, NOT A PICKED FILE (docs/save-plan.md D1).
                    // GTK answers with a path to a file NOBODY HAS MADE
                    // (measured: `exists=false` when the callback runs), so
                    // registering the picker's `PathSource` would hand the
                    // guest a handle that refuses with ENOENT in every mode.
                    let picked = result
                        .ok()
                        .and_then(|f| {
                            let path = f.path().map(|p| p.to_string_lossy().into_owned())?;
                            let name = f.basename().map(|p| p.to_string_lossy().into_owned())?;
                            Some((name, path))
                        })
                        .map(|(name, path)| {
                            let handle = crate::capi::picked_register(std::sync::Arc::new(
                                crate::protocol::SaveDestination {
                                    name: name.clone(),
                                    path: path.clone(),
                                },
                            ));
                            crate::protocol::PickedFile {
                                handle,
                                name,
                                local_path: path,
                            }
                        })
                        .into_iter()
                        .collect::<Vec<_>>();
                    // Cancel is the EMPTY ANSWER: GTK reports a dismissed
                    // save panel as GTK_DIALOG_ERROR_DISMISSED, the same
                    // error the open arm maps to an empty list.
                    crate::capi::file_dialog_retire(dialog_id);
                    sink.send(Occurrence::FileDialogResult {
                        dialog: crate::protocol::FileDialogId(dialog_id),
                        files: picked,
                    });
                },
            );
        }
        ApplyOp::PresentFileDialog(spec) => {
            // GNOME's own picker: gtk::FileDialog (4.10+), answered exactly
            // once through capi::file_dialog_resolved. IN OUR PROCESS,
            // measured: with no xdg-desktop-portal installed GTK presents its
            // own chooser rather than handing off, so the harness reads it on
            // the same a11y bus as every other widget.
            let parent = gtk_window(core, spec.window.0);
            let title = format!("kaya pick {}", spec.dialog.0);
            let dialog = gtk4::FileDialog::builder()
                .title(&title)
                .modal(true)
                .build();

            // ADVISORY on every platform (DESIGN.md): a default view,
            // never a guarantee, so a guest still validates what it got.
            if !spec.filters.is_empty() {
                let filters = gtk4::gio::ListStore::new::<gtk4::FileFilter>();
                for (label, suffix) in &spec.filters {
                    let filter = gtk4::FileFilter::new();
                    filter.set_name(Some(label));
                    filter.add_suffix(suffix);
                    filters.append(&filter);
                }
                dialog.set_filters(Some(&filters));
            }

            // The armed directory, applied HERE because that is the only
            // moment it is read.
            if let Some(dir) = core.pending_dialog_dir.borrow_mut().take() {
                dialog.set_initial_folder(Some(&gtk4::gio::File::for_path(&dir)));
            }

            *core.live_file_dialog.borrow_mut() = Some(GtkLiveFileDialog {
                title: title.clone(),
            });
            let live = core.live_file_dialog.clone();
            let sink = core.occurrences.clone();
            let dialog_id = spec.dialog.0;

            // Cancel is the EMPTY LIST, faithfully: GTK reports a dismissed
            // picker as an error (DISMISSED), and no platform can confirm an
            // empty selection, so there is no sentinel to invent.
            let finish = move |files: Vec<(String, String)>| {
                *live.borrow_mut() = None;
                let picked = files
                    .into_iter()
                    .map(|(name, path)| {
                        let handle = crate::capi::picked_register(std::sync::Arc::new(
                            crate::protocol::PathSource {
                                name: name.clone(),
                                path: path.clone(),
                            },
                        ));
                        crate::protocol::PickedFile {
                            handle,
                            name,
                            local_path: path,
                        }
                    })
                    .collect::<Vec<_>>();
                crate::capi::file_dialog_retire(dialog_id);
                sink.send(Occurrence::FileDialogResult {
                    dialog: crate::protocol::FileDialogId(dialog_id),
                    files: picked,
                });
            };

            let named = |f: &gtk4::gio::File| {
                let path = f.path().map(|p| p.to_string_lossy().into_owned())?;
                let name = f.basename().map(|p| p.to_string_lossy().into_owned())?;
                Some((name, path))
            };

            // NOT file_dialog_shown here: scene.rs marks the dialog live
            // when the op is applied, for every backend at once. Calling it
            // again is a second registration and the liveness guard says so.
            if spec.multiple {
                dialog.open_multiple(
                    Some(&parent),
                    None::<&gtk4::gio::Cancellable>,
                    move |result| {
                        let mut out = Vec::new();
                        if let Ok(list) = result {
                            for i in 0..list.n_items() {
                                if let Some(f) = list
                                    .item(i)
                                    .and_then(|o| o.downcast::<gtk4::gio::File>().ok())
                                {
                                    out.extend(named(&f));
                                }
                            }
                        }
                        finish(out);
                    },
                );
            } else {
                dialog.open(
                    Some(&parent),
                    None::<&gtk4::gio::Cancellable>,
                    move |result| {
                        let out = result.ok().and_then(|f| named(&f)).into_iter().collect();
                        finish(out);
                    },
                );
            }
        }
        ApplyOp::PresentAlert(spec) => {
            // The platform's REAL modal dialog: gtk::AlertDialog maps the
            // vocabulary 1:1. Answered exactly once through
            // capi::alert_resolved.
            let parent = gtk_window(core, spec.window.0);
            let mut labels: Vec<String> = spec.actions.clone();
            labels.push(spec.cancel.clone());
            let actions_n = spec.actions.len();
            let dialog = gtk4::AlertDialog::builder()
                .message(&spec.title)
                .detail(&spec.message)
                .buttons(labels.iter().map(String::as_str).collect::<Vec<_>>())
                .cancel_button(actions_n as i32)
                .default_button(0)
                .modal(true)
                .build();
            let alert_id = spec.alert.0;
            *core.live_alert.borrow_mut() = Some(GtkLiveAlert {
                id: alert_id,
                window: spec.window.0,
                actions: actions_n,
                labels,
                dialog: dialog.clone(),
            });
            let live = core.live_alert.clone();
            // The result must ride THIS backend's sink (the guest listens
            // there); capi::alert_retire is only the liveness gate.
            let sink = core.occurrences.clone();
            dialog.choose(
                Some(&parent),
                None::<&gtk4::gio::Cancellable>,
                move |result| {
                    // Esc/close resolve to the cancel index; any
                    // index at or past the action count IS the
                    // cancel slot.
                    let index = result.unwrap_or(actions_n as i32);
                    let choice = if (index as usize) < actions_n {
                        crate::protocol::AlertChoice::Action(index as u32)
                    } else {
                        crate::protocol::AlertChoice::Cancel
                    };
                    *live.borrow_mut() = None;
                    crate::capi::alert_retire(alert_id);
                    sink.send(Occurrence::AlertResult {
                        alert: crate::protocol::AlertId(alert_id),
                        choice,
                    });
                },
            );
        }
        ApplyOp::SetProp { id, prop, value } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match (widget, prop, value) {
                (NativeWidget::Button(button), Prop::Text, Value::Str(s)) => {
                    button.set_label(&s);
                }
                (NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {
                    label.set_text(&s);
                    // The authored name outlives the text write (see
                    // CoreState::a11y_labels).
                    if let Some(name) = core.a11y_labels.get(&id.0) {
                        use gtk4::prelude::{AccessibleExt, AccessibleExtManual};
                        label.reset_relation(gtk4::AccessibleRelation::LabelledBy);
                        label.update_property(&[gtk4::accessible::Property::Label(name.as_str())]);
                    }
                    // An option label's text lands in its DropDown row — the
                    // model both the popup and the collapsed button render —
                    // or its radio row's CheckButton label.
                    if let Some((select, row)) = core.select_options.get(&id.0) {
                        core.apply_quiet.set(true);
                        core.select_models[select].splice(*row, 1, &[&s]);
                        core.apply_quiet.set(false);
                    }
                    if let Some((radio, row)) = core.radio_options.get(&id.0) {
                        core.radio_buttons[radio][*row as usize].set_label(Some(&s));
                    }
                }
                (NativeWidget::Entry(entry), Prop::Text, Value::Str(s)) => {
                    // Quiet: a property write is configuration, not a user
                    // edit. The before-image is read one line before the write,
                    // the last moment it exists — D7's clear is gated on it
                    // having CHANGED (A3).
                    let previous = lf(entry.text().to_string());
                    core.apply_quiet.set(true);
                    entry.set_text(&s);
                    core.apply_quiet.set(false);
                    note_quiet_text_write(core, id, &previous, &s);
                }
                (NativeWidget::Textarea(_, view), Prop::Text, Value::Str(s)) => {
                    let buffer = view.buffer();
                    let previous =
                        lf(buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string());
                    core.apply_quiet.set(true);
                    buffer.set_text(&s);
                    core.apply_quiet.set(false);
                    note_quiet_text_write(core, id, &previous, &s);
                }
                (NativeWidget::Checkbox(check), Prop::Text, Value::Str(s)) => {
                    check.set_label(Some(&s));
                }
                (NativeWidget::Checkbox(check), Prop::Checked, Value::Bool(b)) => {
                    core.apply_quiet.set(true);
                    check.set_active(b);
                    core.apply_quiet.set(false);
                }
                (NativeWidget::Slider(scale), Prop::Value, Value::F64(v)) => {
                    core.apply_quiet.set(true);
                    scale.set_value(v);
                    core.apply_quiet.set(false);
                }
                (NativeWidget::Select(dropdown), Prop::Value, Value::F64(v)) => {
                    // A programmatic write is quiet (uniform
                    // semantics: only the user path emits).
                    core.apply_quiet.set(true);
                    dropdown.set_selected(v as u32);
                    core.apply_quiet.set(false);
                }
                // THE UNIVERSAL PROPS: every other arm keys on a (kind, prop)
                // pair, these on the prop ALONE, reaching the widget through
                // NativeWidget::control. THE CONTROL AND NOT THE LAYOUT WIDGET
                // — route this to `widget` and `expect_ax textarea#0` reads
                // `field/` instead of `field/Notes`. The LABEL OVERRIDES what
                // the control derived, so an unset label must never be "".
                (w, Prop::A11yLabel, Value::Str(label)) => {
                    use gtk4::prelude::{AccessibleExt, AccessibleExtManual};
                    if !label.is_empty() {
                        core.a11y_labels.insert(id.0, label.clone());
                        let widget = w.control();
                        // Promote a CONTAINER to a semantic group: GTK made
                        // GtkBox's role GENERIC in 4.12, so a label set on one
                        // does not surface as an AT-SPI name. EVERY container
                        // kind — measured 2026-07-25, a named grid and a named
                        // radio group both stayed role `panel` with an EMPTY
                        // name, and a named scroll stayed `scroll pane`.
                        if matches!(
                            w,
                            NativeWidget::Column(_)
                                | NativeWidget::Row(_)
                                | NativeWidget::Grid(_)
                                | NativeWidget::Scroll(_)
                                | NativeWidget::Radio(_)
                        ) {
                            widget.set_accessible_role(gtk4::AccessibleRole::Group);
                        }
                        // AN AUTHORED NAME MUST WIN. GTK's name computation
                        // reads the LABELLED_BY relation FIRST and the label
                        // property second (gtkatcontext.c), so a control
                        // pointing a relation at its own content outranks
                        // anything an app sets: a named select read back as
                        // `combo box name='Red'`, its selected option, with
                        // the authored "Color" ignored (measured 2026-07-25).
                        widget.reset_relation(gtk4::AccessibleRelation::LabelledBy);
                        widget.update_property(&[gtk4::accessible::Property::Label(
                            label.as_str(),
                        )]);
                    }
                }
                // (The IDENTIFIER has no GTK setter and no reader below
                // 4.22; this build pins v4_10 and Debian trixie ships 4.18,
                // so it goes on the widget NAME instead.)
                //
                // The HINT: GTK's DESCRIPTION property, which AT-SPI
                // publishes as the description. Same empty-means-unset rule
                // as the label.
                (w, Prop::A11yHint, Value::Str(hint)) => {
                    use gtk4::prelude::AccessibleExtManual;
                    if !hint.is_empty() {
                        w.control().update_property(&[
                            gtk4::accessible::Property::Description(hint.as_str()),
                        ]);
                    }
                }
                (w, Prop::A11yId, Value::Str(id)) => {
                    use gtk4::prelude::WidgetExt;
                    w.control().set_widget_name(id.as_str());
                }
                // ACCEPTANCE IS PER-WIDGET (DESIGN.md, Clipboard): the list
                // drives the paste split and Paste's enablement, both read
                // off the hub. Empty means unset, the universal prop rule.
                (_, Prop::Accepts, Value::Str(list)) => {
                    if list.is_empty() {
                        core.clipboard.accepts.borrow_mut().remove(&id.0);
                    } else {
                        core.clipboard.accepts.borrow_mut().insert(id.0, list);
                    }
                    core.clipboard.armed.set(true);
                    refresh_roles(core);
                }
                // SEMANTIC EMPHASIS (docs/styling-plan.md D4): what the widget
                // MEANS, lowered to libadwaita's own documented style classes
                // — inventing a `.brand-action` would mean writing colors,
                // which is leaving the tier. Both classes come off before one
                // goes on: they are mutually exclusive in the stylesheet, and a
                // re-applied role would leave the previous one underneath.
                (NativeWidget::Button(button), Prop::Role, Value::I64(role @ (1 | 2))) => {
                    use gtk4::prelude::WidgetExt;
                    button.remove_css_class("destructive-action");
                    button.remove_css_class("suggested-action");
                    button.add_css_class(if role == 1 {
                        "destructive-action"
                    } else {
                        "suggested-action"
                    });
                }
                // THE HEADING ROLE IS TWO FACTS AT ONCE: the platform's
                // heading TEXT STYLE and its heading ACCESSIBLE role.
                // `.heading` and not `.title-1`..`.title-4`, which are a SIZE
                // ladder, and a style class does not touch the accessible role
                // (measured: a `.title-1` label still publishes `label`), so
                // without this line the role is invisible to `expect_ax`.
                (NativeWidget::Label(label), Prop::Role, Value::I64(3)) => {
                    use gtk4::prelude::{AccessibleExt, WidgetExt};
                    label.add_css_class("heading");
                    label.set_accessible_role(gtk4::AccessibleRole::Heading);
                }
                // The caption role, the heading's counterpart: Adwaita's
                // caption type tier plus dim-label for the secondary
                // colour — and GTK is the ONE platform with a caption
                // ACCESSIBLE role to publish beside the style (Apple and
                // UIA have none; a11yrows.steps records the carve-out).
                (NativeWidget::Label(label), Prop::Role, Value::I64(4)) => {
                    use gtk4::prelude::{AccessibleExt, WidgetExt};
                    label.add_css_class("caption");
                    label.add_css_class("dim-label");
                    label.set_accessible_role(gtk4::AccessibleRole::Caption);
                }
                (NativeWidget::Grid(grid), Prop::Columns, Value::F64(cols)) => {
                    core.grid_cols.insert(id.0, cols as i32);
                    let grid = grid.clone();
                    let _ = grid;
                    reflow_grid(core, id.0);
                }
                (NativeWidget::Grid(grid), Prop::Spacing, Value::F64(gap)) => {
                    grid.set_row_spacing(gap as u32);
                    grid.set_column_spacing(gap as u32);
                }
                (NativeWidget::Radio(_), Prop::Value, Value::F64(v)) => {
                    core.apply_quiet.set(true);
                    if let Some(check) = core
                        .radio_buttons
                        .get(&id.0)
                        .and_then(|b| b.get(v as usize))
                    {
                        check.set_active(true);
                    }
                    core.apply_quiet.set(false);
                }
                (NativeWidget::Progress(bar), Prop::Value, Value::F64(v)) => {
                    bar.set_fraction(v);
                }
                (NativeWidget::Progress(bar), Prop::Indeterminate, Value::Bool(on)) => {
                    // GTK's activity mode is pulse-driven, not a property:
                    // a ticker pulses every armed bar, and the membership
                    // set is also what the observation reads.
                    let key = id.0;
                    let mut armed = core.indeterminate.borrow_mut();
                    if on {
                        if armed.insert(key) {
                            let bar = bar.clone();
                            let set = core.indeterminate.clone();
                            glib::timeout_add_local(
                                std::time::Duration::from_millis(100),
                                move || {
                                    if set.borrow().contains(&key) {
                                        bar.pulse();
                                        glib::ControlFlow::Continue
                                    } else {
                                        glib::ControlFlow::Break
                                    }
                                },
                            );
                        }
                    } else {
                        armed.remove(&key);
                        bar.set_fraction(bar.fraction());
                    }
                }
                (NativeWidget::Slider(scale), Prop::Min, Value::F64(v)) => {
                    scale.adjustment().set_lower(v);
                }
                (NativeWidget::Slider(scale), Prop::Max, Value::F64(v)) => {
                    scale.adjustment().set_upper(v);
                }
                // Kind-agnostic, like the prop itself: the weight rides
                // on the widget and the parent's flex manager reads it
                // at allocate time.
                (w, Prop::Grow, Value::F64(weight)) => {
                    let widget = w.widget();
                    set_grow_weight(&widget, weight);
                    // The first positive weight in this container is what
                    // takes the layout away from GtkBox.
                    if weight > 0.0 {
                        if let Some(parent) = widget.parent() {
                            ensure_flex(&parent);
                        }
                    }
                    reconcile_grow_align(&widget);
                    // The split belongs to the whole sibling set, so the
                    // parent re-runs, not just this child.
                    if let Some(parent) = widget.parent() {
                        parent.queue_resize();
                    }
                }
                (NativeWidget::Column(container), Prop::Spacing, Value::F64(gap))
                | (NativeWidget::Row(container), Prop::Spacing, Value::F64(gap)) => {
                    use gtk4::prelude::{Cast, WidgetExt};
                    let gap = gap.round() as i32;
                    let widget = container.upcast_ref::<gtk4::Widget>();
                    set_container_spacing(widget, gap);
                    // TWO LAYOUT PATHS, TWO WRITES, and the write is why the
                    // stored value exists: GtkBox owns the gap until a child
                    // grows, and forwarding to it AFTER ensure_flex asserts
                    // GTK_IS_BOX_LAYOUT and drops the write. The bindings
                    // differ on which case a scene hits, so both arms carry
                    // real legs (docs/deferred.md's always-8 GAP).
                    match widget
                        .layout_manager()
                        .and_then(|m| m.downcast::<flex::FlexLayout>().ok())
                    {
                        Some(flex) => flex.set_spacing(gap),
                        None => container.set_spacing(gap),
                    }
                }
                // THE CONTAINER'S OWN PADDING (prop 17), all three kinds the
                // root allows it on. The CSS box carries it, not the layout:
                // GTK hands a layout manager the CONTENT size, so both layout
                // paths inset their children with no code here (measured,
                // docs/styling-plan.md D3).
                (NativeWidget::Column(container), Prop::Inset, Value::F64(pad))
                | (NativeWidget::Row(container), Prop::Inset, Value::F64(pad)) => {
                    // Cloned out of `core.widgets` first: the helper
                    // wants the whole core (the grid-columns arm above
                    // does the same dance for the same reason).
                    let widget = container.clone().upcast::<gtk4::Widget>();
                    set_container_inset(core, &widget, pad);
                }
                (NativeWidget::Grid(grid), Prop::Inset, Value::F64(pad)) => {
                    let widget = grid.clone().upcast::<gtk4::Widget>();
                    set_container_inset(core, &widget, pad);
                }
                // The arrangement axis (docs/adaptive-layout-plan.md D1):
                // the GtkBox IS one orientable node, so the flip is the
                // toolkit's own property — the axis-as-data precedent.
                (NativeWidget::Column(container), Prop::Axis, Value::I64(mode))
                | (NativeWidget::Row(container), Prop::Axis, Value::I64(mode)) => {
                    // DEFERRED past the core borrow: on wayland,
                    // set_orientation relayouts synchronously and the
                    // resize path re-borrows CORE — "RefCell already
                    // borrowed" on the second flip, with x11 green (the
                    // connect_dark_notify comment above records the same
                    // rule; the harness's poll absorbs the idle hop).
                    let container = container.clone();
                    let mode = mode;
                    glib::idle_add_local_once(move || {
                        use gtk4::prelude::OrientableExt;
                        container.set_orientation(if mode == 1 {
                            gtk4::Orientation::Vertical
                        } else {
                            gtk4::Orientation::Horizontal
                        });
                    });
                }
                (NativeWidget::Column(container), Prop::Align, Value::I64(mode)) => {
                    use gtk4::prelude::WidgetExt;
                    let container = container.clone().upcast::<gtk4::Widget>();
                    set_container_align(&container, mode);
                    let mut child = container.first_child();
                    while let Some(widget) = child {
                        apply_cross_align(&widget, true, mode);
                        child = widget.next_sibling();
                    }
                }
                (NativeWidget::Row(container), Prop::Align, Value::I64(mode)) => {
                    use gtk4::prelude::WidgetExt;
                    let container = container.clone().upcast::<gtk4::Widget>();
                    set_container_align(&container, mode);
                    let mut child = container.first_child();
                    while let Some(widget) = child {
                        apply_cross_align(&widget, false, mode);
                        child = widget.next_sibling();
                    }
                }
                (NativeWidget::Image(picture), Prop::Source, Value::Blob(blob)) => {
                    // Encoded bytes in, native decode:
                    // gdk::Texture::from_bytes reads encoded PNG/JPEG. A
                    // failed decode yields the placeholder class (no
                    // paintable, image_size reads 0x0).
                    let bytes = gtk4::glib::Bytes::from(&blob.0[..]);
                    match gtk4::gdk::Texture::from_bytes(&bytes) {
                        Ok(texture) => picture.set_paintable(Some(&texture)),
                        Err(_) => picture.set_paintable(gtk4::gdk::Paintable::NONE),
                    }
                }
                (_, prop, value) => {
                    panic!("kaya: gtk cannot apply {prop:?} = {value:?} here")
                }
            }
        }
        ApplyOp::AddChild { parent, child } => {
            // A select's label children are its OPTIONS: rows of the
            // DropDown's model, never widgets in a container. The native label
            // stays unparented and leaves the harness's label registry, so
            // options do not shift every later label's index. The append rides
            // the quiet guard: GTK auto-selects row 0 on the first item.
            if let NativeWidget::Grid(_) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let child_widget = core
                    .widgets
                    .get(&child)
                    .expect("scene validated the id")
                    .widget();
                child_widget.set_halign(gtk4::Align::Start);
                child_widget.set_valign(gtk4::Align::Start);
                core.grid_children
                    .get_mut(&parent.0)
                    .expect("grid created")
                    .push(child_widget);
                reflow_grid(core, parent.0);
                return;
            }
            if let NativeWidget::Radio(group) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                // A radio's label children are its OPTIONS: grouped
                // CheckButton rows, never standalone widgets. The label
                // leaves the harness's label registry.
                let group = group.clone();
                let text = match core.widgets.get(&child).expect("scene validated the id") {
                    NativeWidget::Label(l) => {
                        let l = l.clone();
                        core.labels.retain(|x| x != &l);
                        l.text().to_string()
                    }
                    _ => String::new(),
                };
                let check = gtk4::CheckButton::with_label(&text);
                let buttons = core.radio_buttons.get_mut(&parent.0).expect("radio created");
                if let Some(first) = buttons.first() {
                    check.set_group(Some(first));
                }
                let row = buttons.len() as u32;
                let sink = core.occurrences.clone();
                let tag = core.radio_tags[&parent.0].clone();
                let quiet = core.apply_quiet.clone();
                check.connect_toggled(move |c| {
                    if c.is_active() && !quiet.get() {
                        sink.send_value_tag(&tag, f64::from(row));
                    }
                });
                group.append(&check);
                buttons.push(check);
                core.radio_options.insert(child.0, (parent.0, row));
                return;
            }
            if let NativeWidget::Select(_) = core.widgets.get(&parent).expect("scene validated the id")
            {
                // The row initializes from the label's CURRENT text:
                // children-first sugars (OCaml, Haskell) set the text
                // BEFORE this AddChild, so an empty-row default would
                // miss it (caught live on linux, 2026-07-22 — every
                // ocaml/haskell row read ""). The splice in SetProp
                // covers writes that arrive after.
                let text = match core.widgets.get(&child).expect("scene validated the id") {
                    NativeWidget::Label(l) => {
                        let l = l.clone();
                        core.labels.retain(|x| x != &l);
                        l.text().to_string()
                    }
                    _ => String::new(),
                };
                let model = &core.select_models[&parent.0];
                let row = model.n_items();
                core.apply_quiet.set(true);
                model.append(&text);
                core.apply_quiet.set(false);
                core.select_options.insert(child.0, (parent.0, row));
                return;
            }
            let child_widget = core
                .widgets
                .get(&child)
                .expect("scene validated the id")
                .widget();
            // Normalized layout default: children sit at natural size on the
            // leading edge. GtkWidget's default halign is Fill, which stretches
            // a child to the full cross-axis extent; Start pins it instead.
            child_widget.set_halign(gtk4::Align::Start);
            child_widget.set_valign(gtk4::Align::Start);
            // ... then the container's align mode overrides the cross
            // axis for children arriving after the prop did — and the
            // breadth rule overrides the mode in turn for a crossing
            // container (apply_cross_align).
            match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(c) => apply_cross_align(
                    &child_widget,
                    true,
                    container_align(c.clone().upcast_ref::<gtk4::Widget>()),
                ),
                NativeWidget::Row(c) => apply_cross_align(
                    &child_widget,
                    false,
                    container_align(c.clone().upcast_ref::<gtk4::Widget>()),
                ),
                _ => {}
            }
            match core.widgets.get(&parent).expect("scene validated the id") {
                // A DECLARED TABLE'S ROWS GO IN ITS OWN VIEWPORT
                // (docs/virtualization-plan.md §4): the container keeps
                // the header, the divider and the scroller, and the band
                // lives inside. reflow_table migrates the rows that a
                // children-first sugar parented before the table existed.
                NativeWidget::Column(column) => {
                    match core.tables.get(&parent.0).map(|t| t.content.clone()) {
                        Some(content) => content.append(&child_widget),
                        None => column.append(&child_widget),
                    }
                }
                NativeWidget::Row(row) => row.append(&child_widget),
                // The viewport's one child (the scene rejects a
                // second): the content fills the viewport's width and
                // scrolls on its own height.
                NativeWidget::Scroll(scrolled) => {
                    child_widget.set_halign(gtk4::Align::Fill);
                    scrolled.set_child(Some(&child_widget));
                }
                _ => panic!("kaya: add_child parent is not a container"),
            }
            // Only now is the parent — and so the main axis — known, so
            // a weight that arrived before the child was attached gets
            // its manager and alignment here rather than being dropped.
            if grow_weight(&child_widget) > 0.0 {
                match core.widgets.get(&parent).expect("scene validated the id") {
                    NativeWidget::Column(c) => ensure_flex(c.upcast_ref()),
                    NativeWidget::Row(r) => ensure_flex(r.upcast_ref()),
                    _ => {}
                }
            }
            reconcile_grow_align(&child_widget);
        }
        ApplyOp::Mount { window, root } => {
            let root_widget = core
                .widgets
                .get(&root)
                .expect("scene validated the id")
                .widget();
            // The root fills its window, as on every other backend — a GTK
            // child obeys its own align and would otherwise hug its content,
            // leaving no leftover space for a grow weight to divide.
            root_widget.set_halign(gtk4::Align::Fill);
            root_widget.set_valign(gtk4::Align::Fill);
            root_widget.add_css_class("kaya-root");
            // The target is a SURFACE: a navigation entry presents in-window,
            // the primary is the window's own root, an auxiliary presents its
            // window.
            if core.section_pages.contains_key(&window.0) {
                // A section presents in-window: added to the set
                // already; the mount fills its page.
                core.section_pages.get_mut(&window.0).unwrap().root =
                    Some(root_widget);
                refresh_section_pane(core, window.0);
                // ... AND SO DOES ITS WINDOW, when that window is an
                // auxiliary: a window that presents sections mounts into its
                // SECTIONS and never into a root, so the "mounting presents"
                // arm below cannot fire for it. A section's mount is that
                // window's mounting-presents moment.
                let owner = core.section_pages[&window.0].window;
                if owner != 0 {
                    use gtk4::prelude::GtkWindowExt;
                    gtk_window(core, owner).present();
                    // THE SECOND OF TWO PLACES A WINDOW IS FIRST SHOWN, and
                    // the app's mark goes on at both: a toplevel has no
                    // GdkSurface until it is realized
                    // (docs/app-identity-plan.md I4a).
                    apply_identity_icon(core, owner);
                }
            } else if let Some(entry) = core.nav_entries.get_mut(&window.0) {
                entry.root = Some(root_widget);
                let host = entry.window;
                if core.nav_stacks.get(&host).and_then(|s| s.last()) == Some(&window.0) {
                    refresh_nav(core, host);
                }
            } else if window.0 == 0 {
                set_window_content(core, 0, Some(&root_widget));
                core.window_roots.insert(0, root_widget);
            } else {
                use gtk4::prelude::GtkWindowExt;
                set_window_content(core, window.0, Some(&root_widget));
                // Mounting presents.
                gtk_window(core, window.0).present();
                // ...and a presented window is a REALIZED one, which is the
                // first moment it has a GdkToplevel to carry the app's mark
                // (docs/app-identity-plan.md I4a).
                apply_identity_icon(core, window.0);
                core.window_roots.insert(window.0, root_widget);
            }
        }
        ApplyOp::Command { id, command } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match command {
                CommandKind::Clear => {
                    // A command ACTS LIKE THE USER (unlike a property write):
                    // apply_quiet stays off here on purpose, so GTK's
                    // `changed` carries the empty edit to the app. It is still
                    // a PROGRAMMATIC write for D7's purposes — what it
                    // destroys is widget-owned text the user did not delete.
                    let previous = core.text_of(id).unwrap_or_default();
                    match widget {
                        NativeWidget::Entry(entry) => entry.set_text(""),
                        NativeWidget::Textarea(_, view) => view.buffer().set_text(""),
                        _ => panic!("kaya: clear on a non-text widget (scene validates kinds)"),
                    }
                    note_quiet_text_write(core, id, &previous, "");
                }
                CommandKind::Focus => {
                    // grab_focus is per-window, so parallel tiled legs cannot
                    // steal each other's focus assertions. The materialization
                    // class (docs/traps.md): an unmapped widget cannot take
                    // focus and the bool is discarded, so it takes a one-shot
                    // re-grab from its own map signal. THE CONTROL, not the
                    // layout widget — `expect_focused textarea#0` reads the view.
                    let w = widget.control();
                    if w.is_mapped() {
                        w.grab_focus();
                    } else {
                        // One-shot: map re-fires on every re-map, and
                        // a stale handler must not steal focus later.
                        let armed = Rc::new(RefCell::new(None));
                        let armed2 = armed.clone();
                        let handler = w.connect_map(move |w| {
                            w.grab_focus();
                            if let Some(id) = armed2.borrow_mut().take() {
                                w.disconnect(id);
                            }
                        });
                        *armed.borrow_mut() = Some(handler);
                    }
                }
            }
        }
    }
}

/// Load one of kaya's OWN generated stylesheets, with a parse error made
/// FATAL rather than silent. `GtkCssProvider::parsing-error` is NECESSARY AND
/// NOT SUFFICIENT, measured both ways: `var(--kaya-no-such-variable)` raises
/// nothing and silently inherits. The panic is raised HERE and not in the
/// handler, since `load_from_data` calls it synchronously and unwinding
/// through GTK's C frames for a diagnostic is not worth it.
fn load_kaya_css(
    provider: &gtk4::CssProvider, what: &str, css: &str,
    error: &Rc<RefCell<Option<String>>>,
) {
    error.borrow_mut().take();
    provider.load_from_data(css);
    if let Some(why) = error.borrow_mut().take() {
        panic!(
            "kaya: gtk refused its own {what} stylesheet: {why}\n{css}\n\
             (custom properties, `:root` and var() are GTK 4.16+; this \
             build's GTK is older, or the generated string is malformed)"
        );
    }
}

/// A CONTAINER's own inset (prop 17): the space between its bounds and its
/// children, on the container's CSS box. A TRANSPARENT BORDER, NOT `padding`:
/// this backend mounts the root with no wrapper, so `.kaya-root`'s WINDOW
/// inset sits on the same widget, and two `padding` declarations do not add —
/// the later provider simply wins (measured; a border adds, 16 + 8 = 24).
/// ONE RULE PER DISTINCT VALUE, so a thousand inset rows share one.
fn set_container_inset(core: &mut CoreState, widget: &gtk4::Widget, pad: f64) {
    use gtk4::prelude::WidgetExt;
    // Whole pixels, the window arm's rule — the value is a CSS length,
    // and the measurement answers in whole layout units. Negative and
    // non-finite died at the root (scene.rs's check_prop).
    let px = pad.round().max(0.0) as i64;
    // Exactly one of these classes at a time: a second write to the same
    // container must not leave the first value behind it.
    for class in widget.css_classes() {
        if class.starts_with(INSET_CLASS) {
            widget.remove_css_class(&class);
        }
    }
    widget.add_css_class(&format!("{INSET_CLASS}{px}"));
    if core.container_insets.insert(px) {
        let sheet: String = core
            .container_insets
            .iter()
            .map(|n| format!(".{INSET_CLASS}{n} {{ border: {n}px solid transparent; }}\n"))
            .collect();
        load_kaya_css(
            &core.container_inset_css,
            "container inset",
            &sheet,
            &core.css_error,
        );
    }
}

/// Arm one of kaya's providers to record its parse errors into the shared
/// cell `load_kaya_css` reads.
fn watch_css_errors(provider: &gtk4::CssProvider, error: &Rc<RefCell<Option<String>>>) {
    let error = error.clone();
    provider.connect_parsing_error(move |_, section, err| {
        *error.borrow_mut() = Some(format!("{err} at {section}"));
    });
}

/// THE BRAND ACCENT, GTK's half (docs/styling-plan.md D1): libadwaita's
/// documented app-override route, carrying the values the CORE derived.
/// Three variables and no fourth, all out of `DerivedAccent` — never
/// libadwaita's per-widget oklab recipe, which measured out of gamut for a
/// saturated seed. CUSTOM PROPERTIES ONLY, NEVER `@name`: `@accent_bg_color`
/// still resolves to the SYSTEM accent under the override (docs/styling-plan.md
/// D1). One appearance at a time; the `dark` notify rewrites it.
fn brand_css_for(accent: crate::brand::BrandAccent, dark: bool) -> String {
    let a = if dark { accent.dark } else { accent.light };
    format!(
        ":root {{\n  --accent-bg-color: #{:06x};\n  --accent-fg-color: #{:06x};\n  \
         --accent-color: #{:06x};\n}}\n",
        a.fill, a.on_fill, a.standalone
    )
}

/// THE BRAND TYPEFACE, GTK's half (docs/styling-plan.md Slice 2b): one
/// inherited `font-family`, and nothing else in the sheet. `:root`, NEVER `*`
/// — `*` matches the `.monospace` element itself and beats libadwaita's own
/// rule for it, swapping the face of every monospace surface. THE FAMILY AND
/// NOT THE SCALE: `GtkSettings:gtk-font-name` moves every size with the
/// family and stomps a session-global setting from inside an app.
fn typeface_css_for(family: &str) -> String {
    format!(":root {{\n  font-family: {};\n}}\n", css_string(family))
}

/// A family name as a CSS string token. The name is the APP's — the one
/// string in kaya's stylesheets this process did not write — and an
/// unescaped `"` would end the token and let the rest become declarations.
/// A family kaya cannot escape correctly dies in `load_kaya_css`'s
/// `parsing-error` watcher; one that is merely NOT INSTALLED is valid CSS
/// and raises nothing, which is what the resolved-family read is for.
fn css_string(family: &str) -> String {
    let mut out = String::with_capacity(family.len() + 2);
    out.push('"');
    for c in family.chars() {
        match c {
            '"' | '\\' => {
                out.push('\\');
                out.push(c);
            }
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                out.push_str(&format!("\\{:x} ", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// FONT BYTES, GTK's half: register the blob with the live text system and
/// answer with the family it registered under (register-then-resolve).
/// PANGO'S ROUTE AND NOT FONTCONFIG'S — `FcConfigAppFontAddFile` returns
/// success and does nothing once GTK has started, while
/// `pango_font_map_add_font_file` lands at any time
/// (docs/styling/typeface-gtk-arm.md).
fn register_font_blob(core: &CoreState, bytes: &[u8], named: &str) -> Option<String> {
    use gtk4::pango::prelude::{FontFamilyExt, FontMapExt};
    use gtk4::prelude::WidgetExt;
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    let path = std::env::temp_dir().join(format!("kaya-font-{hash:016x}"));
    // NEVER TRUNCATE THE SHARED NAME IN PLACE: the path is content-named and
    // shared by every process shipping these bytes, freetype MAPS it, and an
    // `fs::write` (open(O_TRUNC)) drops it to zero length under a process that
    // then dies of SIGBUS. Skip when the bytes are already there, otherwise
    // write a UNIQUE temp name and rename() it in (docs/traps.md: "A per-app
    // font is never in the system font collection").
    let already = std::fs::read(&path).is_ok_and(|have| have == bytes);
    if !already {
        let staged = path.with_extension(format!("stage-{}", std::process::id()));
        let write_then_rename = std::fs::write(&staged, bytes)
            .and_then(|()| std::fs::rename(&staged, &path));
        if let Err(why) = write_then_rename {
            // A DIAGNOSIS AND NOT A PANIC: the app's brand is chrome, and a
            // read-only temp directory is the host's problem. The sentence
            // names the path and the OS error, and the resolved-family read
            // still reports the truth.
            let _ = std::fs::remove_file(&staged);
            kaya_diag!(
                "KAYA_DIAG brand typeface: {} bytes could not be written to {} ({why}) \
                 — the family name is all this platform has left to go on",
                bytes.len(),
                path.display()
            );
            return None;
        }
    }
    // THE MAP COMES FROM THE CALLER'S `core`, never from a fresh
    // `CORE.with_borrow`: this runs inside an apply, which already holds
    // that RefCell mutably, and a nested borrow is a panic.
    let map = core.window.pango_context().font_map()?;
    let before: std::collections::BTreeSet<String> =
        map.list_families().iter().map(|f| f.name().to_string()).collect();
    if let Err(why) = map.add_font_file(&path) {
        kaya_diag!(
            "KAYA_DIAG brand typeface: pango refused {} ({} bytes): {why}",
            path.display(),
            bytes.len()
        );
        return None;
    }
    let after: std::collections::BTreeSet<String> =
        map.list_families().iter().map(|f| f.name().to_string()).collect();
    // WHICH FAMILY DID THE FILE BRING? Three answers, each saying which it is:
    // the app's own family row if the file put it in the map; the one family
    // that appeared, when the app named none; or nothing nameable, and the
    // caller falls back to the app's name with the numbers printed.
    if after.contains(named) && !before.contains(named) {
        return Some(named.to_owned());
    }
    let mut fresh = after.difference(&before);
    match (fresh.next(), fresh.next()) {
        (Some(one), None) => Some(one.clone()),
        (Some(one), Some(two)) => {
            kaya_diag!(
                "KAYA_DIAG brand typeface: {} added {} families ({one}, {two}, …) and the \
                 request names {named:?}, which is not among them — kaya asks for {named:?} \
                 and the resolved-family read reports what the text system does with it",
                path.display(),
                after.difference(&before).count()
            );
            None
        }
        (None, _) => {
            kaya_diag!(
                "KAYA_DIAG brand typeface: pango accepted {} ({} bytes) and the font map's \
                 {} families did not change — the file carries a family this process \
                 already had, or none it could read",
                path.display(),
                bytes.len(),
                after.len()
            );
            None
        }
    }
}

fn request_exit(code: i32) {
    EXIT_CODE.store(code, Ordering::Relaxed);
    CORE.with_borrow(|core| {
        let Some(core) = core.as_ref() else { return };
        match &core.app {
            Some(app) => app.quit(),
            None => std::process::exit(code),
        }
    });
}

/// The main-thread half, independent of who owns the app thread. Returns
/// the exit code; the host process decides how to exit.
pub(crate) fn run_core(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> i32 {
    let app = gtk4::Application::builder()
        .application_id("dev.kaya.Milestone2")
        .build();

    // activate can fire more than once; the core is set up once.
    let ends = Rc::new(RefCell::new(Some((occ_tx, tx_rx))));
    app.connect_activate(move |app| {
        // libadwaita has to be initialised before any Adw widget is
        // constructed, and the list-detail arm constructs one. Safe to call
        // more than once, and it must come after GTK is up.
        adw::init().expect("libadwaita init");
        // The harness appearance, BEFORE the first widget: libadwaita's own
        // app-level override, which outranks the session preference the
        // container does not express (nothing here pins light — the image
        // ships no portal and no gsettings value, so Adwaita's default IS
        // light). Every `StyleManager::is_dark()` reading in this file then
        // answers the forced scheme, including the one presentation_report
        // sends (tools/check-appearance.py).
        if let Some(mode) = crate::canvas::appearance_override() {
            adw::StyleManager::default().set_color_scheme(match mode {
                crate::canvas::Mode::Dark => adw::ColorScheme::ForceDark,
                crate::canvas::Mode::Light => adw::ColorScheme::ForceLight,
            });
        }
        let Some((occ_tx, tx_rx)) = ends.borrow_mut().take() else {
            return;
        };
        let window = gtk4::ApplicationWindow::builder()
            .application(app)
            .title("kaya milestone 2")
            .default_width(540)
            .default_height(330)
            .build();
        // THE BREAKPOINT CHANNEL (docs/adaptive-layout-plan.md D3): the
        // window's content size, into THIS BACKEND'S OWN scene — the capi
        // presentation slot is the interpreters', and a report there reaches a
        // scene this backend never reads. SCHEDULED, never inline: the notify
        // fires inside resize_window's on_main with CORE borrowed.
        {
            use gtk4::prelude::GtkWindowExt;
            window.connect_default_width_notify(|_| schedule_window_metrics());
            window.connect_default_height_notify(|_| schedule_window_metrics());
            schedule_window_metrics();
        }
        // The normalized root inset: 16 units INSIDE the root, via the CSS box
        // (padding sits inside the allocation, so the root still fills its
        // window and expect_root_fills holds). Stamped in the Mount arm.
        let css_error: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
        let css = gtk4::CssProvider::new();
        watch_css_errors(&css, &css_error);
        load_kaya_css(&css, "root inset", ".kaya-root { padding: 16px; }", &css_error);
        // The brand's own provider, EMPTY until a SetBrand arrives.
        // APPLICATION priority (600) for both, the whole vocabulary's position
        // on Linux: it outranks libadwaita's own stylesheet (THEME, 200) and
        // the settings-derived values (400), and LOSES to the user's
        // `~/.config/gtk-4.0/gtk.css` (USER, 800) — D2 holding structurally.
        let brand_css = gtk4::CssProvider::new();
        watch_css_errors(&brand_css, &css_error);
        // The brand TYPEFACE's provider, EMPTY until a SetTypeface arrives.
        // ADDED ONCE and rewritten in place rather than replaced: the probe
        // measured the alternative — create-and-swap a provider per change —
        // silently failing to apply on one pass of a seven-pass sequence,
        // reproducibly, with `parsing-error` never firing.
        let typeface_css = gtk4::CssProvider::new();
        watch_css_errors(&typeface_css, &css_error);
        // The container inset's provider, EMPTY until some container
        // asks for one — a scene where nothing is inset contributes no
        // rule at all (see set_container_inset).
        let container_inset_css = gtk4::CssProvider::new();
        watch_css_errors(&container_inset_css, &css_error);
        // The table header's rules are STATIC, so this provider is loaded
        // once and never held: the display owns it. Its own provider and
        // never `css`, which the window-inset arm rewrites whole (the
        // hazard typeface_css already carries).
        let table_css = gtk4::CssProvider::new();
        watch_css_errors(&table_css, &css_error);
        load_kaya_css(&table_css, "table header", TABLE_CSS, &css_error);
        if let Some(display) = gtk4::gdk::Display::default() {
            gtk4::style_context_add_provider_for_display(
                &display,
                &css,
                gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
            gtk4::style_context_add_provider_for_display(
                &display,
                &brand_css,
                gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
            gtk4::style_context_add_provider_for_display(
                &display,
                &container_inset_css,
                gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
            gtk4::style_context_add_provider_for_display(
                &display,
                &typeface_css,
                gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
            gtk4::style_context_add_provider_for_display(
                &display,
                &table_css,
                gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }
        let inset_css = css.clone();
        // The accent is written for the appearance the session is in RIGHT
        // NOW, so a session that flips has to be re-lowered. The handler holds
        // the derived values and the provider directly rather than reaching
        // for CORE: a notify can arrive at any point in a main-loop turn,
        // including one where CORE is already borrowed.
        let brand = Rc::new(RefCell::new(None));
        {
            let brand = brand.clone();
            let provider = brand_css.clone();
            let error = css_error.clone();
            adw::StyleManager::default().connect_dark_notify(move |manager| {
                let accent = *brand.borrow();
                if let Some(accent) = accent {
                    load_kaya_css(
                        &provider,
                        "brand accent",
                        &brand_css_for(accent, manager.is_dark()),
                        &error,
                    );
                }
                // The appearance bit is the ONE thing a platform gives a
                // drawing (docs/canvas-plan.md §6), and the core
                // re-rasters on it exactly as it does on a scale change.
                schedule_presentation_report();
            });
        }
        let primary_chrome = {
            use gtk4::prelude::Cast;
            install_nav_chrome(window.upcast_ref::<gtk4::Window>(), 0)
        };
        window.present();
        // THE SCALE, once the surface exists to be asked (§5): a window
        // has no GdkSurface before it is realized, and a canvas declared
        // in the first transaction must already be rastering at the right
        // density. The notify keeps it true across a monitor move, which
        // is the transition every core-buffer framework gets wrong.
        {
            use gtk4::prelude::{IsA, NativeExt, WidgetExt};
            fn watch_presentation(widget: &impl IsA<gtk4::Widget>) {
                if let Some(surface) = widget.as_ref().native().and_then(|n| n.surface()) {
                    surface.connect_scale_notify(|_| schedule_presentation_report());
                }
                schedule_presentation_report();
            }
            if window.is_realized() {
                watch_presentation(&window);
            } else {
                window.connect_realize(watch_presentation);
            }
        }

        #[cfg(feature = "harness")]
        if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
            crate::harness::spawn(&scene, GtkStage, |line| println!("{line}"));
        }
        // A build WITHOUT the harness feature must not silently ignore
        // KAYA_SELFTEST: a runner that forgets `--features harness` would
        // otherwise start the app, run no steps and hang. Fail loudly.
        #[cfg(not(feature = "harness"))]
        if std::env::var("KAYA_SELFTEST").is_ok() {
            panic!(
                "kaya: KAYA_SELFTEST is set but this build has no harness \
                 — rebuild with `--features harness` (it is off by default \
                 so shipped apps do not carry the scene interpreter)"
            );
        }


        CORE.with_borrow_mut(|core| {
            *core = Some(CoreState {
                transactions: tx_rx,
                // THIS BACKEND WINDOWS ROWS (docs/deferred.md, the
                // declares-windowing entry): every declared table gets
                // the spacer+band tier, so a table's band starts at a
                // screenful instead of at the whole collection.
                scene: {
                    let mut scene = Scene::new();
                    scene.declare_windowing();
                    scene
                },
                occurrences: occ_tx.clone(),
                aux_windows: HashMap::new(),
                nav_entries: HashMap::new(),
                nav_stacks: HashMap::new(),
                panes: HashMap::new(),
                inner_splits: HashMap::new(),
                split_presentation: HashMap::new(),
                split_views: HashMap::new(),
                sections: HashMap::new(),
                section_pages: HashMap::new(),
                section_stacks: HashMap::new(),
                section_chrome: HashMap::new(),
                sections_rendered: HashMap::new(),
                selected_sections: HashMap::new(),
                sections_presentation: HashMap::new(),
                window_roots: HashMap::new(),
                window_titles: {
                    use gtk4::prelude::GtkWindowExt;
                    let mut titles = HashMap::new();
                    titles.insert(
                        0,
                        window.title().map(String::from).unwrap_or_default(),
                    );
                    titles
                },
                // EMPTY, and that is the point: the title the builder
                // just set is kaya's placeholder, not one an app wrote,
                // so a declared identity name may replace it.
                app_titled: std::collections::HashSet::new(),
                identity_name: None,
                identity_icon: IdentityIcon::Undeclared,
                identity_icon_on: BTreeSet::new(),
                toolbar_views: HashMap::from([(0, primary_chrome.view)]),
                header_bars: HashMap::from([(0, primary_chrome.header)]),
                toolbar_groups: HashMap::from([(0, primary_chrome.promoted)]),
                back_buttons: {
                    let mut buttons = HashMap::new();
                    buttons.insert(0, primary_chrome.back);
                    buttons
                },
                inset: 16.0,
                inset_css,
                container_inset_css,
                container_insets: BTreeSet::new(),
                brand,
                brand_css,
                typeface_css,
                typeface_request: None,
                #[cfg(feature = "harness")]
                typeface_said: RefCell::new(None),
                css_error,
                dirty_markers: {
                    let mut markers = HashMap::new();
                    markers.insert(0, primary_chrome.marker);
                    markers
                },
                live_alert: std::rc::Rc::new(RefCell::new(None)),
                live_file_dialog: std::rc::Rc::new(RefCell::new(None)),
                pending_dialog_dir: std::rc::Rc::new(RefCell::new(None)),
                menus: Rc::new(RefCell::new(MenuRegistry::default())),
                menu_models: HashMap::new(),
                menu_strips: HashMap::new(),
                menu_action_groups: HashMap::new(),
                context_menus: HashMap::new(),
                open_context: Rc::new(RefCell::new(None)),
                #[cfg(feature = "harness")]
                context_trail: Rc::new(RefCell::new(Vec::new())),
                clipboard: {
                    let hub = Rc::new(ClipboardHub::new(occ_tx.clone()));
                    // Enablement moves when the clipboard or the focus does
                    // (the mac finding, §3), and BOTH signals can fire
                    // mid-apply while CORE is borrowed — so each defers.
                    let defer = || {
                        glib::idle_add_local_once(|| {
                            CORE.with_borrow(|core| {
                                if let Some(core) = core.as_ref() {
                                    refresh_roles(core);
                                }
                            });
                        });
                    };
                    if let Some(display) = gtk4::gdk::Display::default() {
                        let refresh = defer;
                        display.clipboard().connect_changed(move |_| refresh());
                    }
                    {
                        use gtk4::prelude::ObjectExt;
                        let refresh = defer;
                        window
                            .connect_notify_local(Some("focus-widget"), move |_, _| {
                                refresh()
                            });
                    }
                    hub
                },
                window_veto: {
                    let veto = std::rc::Rc::new(RefCell::new(HashMap::new()));
                    {
                        use gtk4::prelude::Cast;
                        wire_close(
                            window.upcast_ref::<gtk4::Window>(),
                            0,
                            veto.clone(),
                            occ_tx.clone(),
                        );
                    }
                    veto
                },
                widgets: HashMap::new(),
                widget_tags: HashMap::new(),
                buttons: Vec::new(),
                checkboxes: Vec::new(),
                labels: Vec::new(),
                entries: Vec::new(),
                sliders: Vec::new(),
                images: Vec::new(),
                canvases: Vec::new(),
                canvas_ids: Vec::new(),
                canvas_clock: false,
                scrolls: Vec::new(),
                progresses: Vec::new(),
                selects: Vec::new(),
                radios: Vec::new(),
                grids: Vec::new(),
                textareas: Vec::new(),
                grid_children: HashMap::new(),
                grid_cols: HashMap::new(),
                radio_options: HashMap::new(),
                radio_buttons: HashMap::new(),
                radio_tags: HashMap::new(),
                select_options: HashMap::new(),
                a11y_labels: HashMap::new(),
                select_models: HashMap::new(),
                apply_quiet: std::rc::Rc::new(std::cell::Cell::new(false)),
                ledger_quiet: std::rc::Rc::new(std::cell::Cell::new(false)),
                native_dirty: std::rc::Rc::new(RefCell::new(std::collections::HashSet::new())),
                highlight_text: std::rc::Rc::new(RefCell::new(HashMap::new())),
                preedit: std::rc::Rc::new(RefCell::new(HashMap::new())),
                indeterminate: std::rc::Rc::new(RefCell::new(std::collections::HashSet::new())),
                columns: Vec::new(),
                #[cfg(feature = "harness")]
                column_ids: Vec::new(),
                rows: Vec::new(),
                tables: HashMap::new(),
                folded_into: HashMap::new(),
                window: window.upcast(),
                app: Some(app.clone()),
            });
        });

        // The first transaction may already be queued; drain now.
        drain_transactions();
    });

    let _ = app.run_with_args::<&str>(&[]);

    // GTK teardown is orderly; dropping CoreState here announces shutdown
    // through its Drop impl.
    CORE.with_borrow_mut(|core| {
        core.take();
    });
    EXIT_CODE.load(Ordering::Relaxed)
}

/// The harness stage: GTK's native calls, each hopping to the main
/// context. Programmatic set_text/set_active/set_value fire the real
/// signals, so every step travels the path a user's gesture would.
#[cfg(feature = "harness")]
struct GtkStage;

/// Which session this process is presenting on — mirrors GDK's own
/// choice at startup: an explicit GDK_BACKEND wins, else wayland when
/// a display is offered.
#[cfg(feature = "harness")]
fn linux_wayland_session() -> bool {
    match std::env::var("GDK_BACKEND") {
        Ok(b) if b.contains("wayland") => true,
        Ok(b) if !b.is_empty() => false,
        _ => std::env::var("WAYLAND_DISPLAY").is_ok(),
    }
}

/// The foreign clipboard WRITER: wl-copy / xclip, a child process with
/// its own connection. `mime` None lets the tool declare its own
/// standard text targets. Content rides stdin — no quoting layer.
#[cfg(feature = "harness")]
fn foreign_clip_write(mime: Option<&str>, bytes: Vec<u8>) {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let mut command = if linux_wayland_session() {
        let mut c = Command::new("wl-copy");
        if let Some(mime) = mime {
            c.args(["-t", mime]);
        }
        c
    } else {
        let mut c = Command::new("xclip");
        c.args(["-selection", "clipboard"]);
        if let Some(mime) = mime {
            c.args(["-t", mime]);
        }
        c
    };
    // ALL THREE DESCRIPTORS SET EXPLICITLY, never inherited: a host runtime
    // may mark its own standard descriptors close-on-exec — node does — and a
    // child that inherits one starts with it CLOSED (measured on the js legs
    // 2026-09-01, docs/traps.md). stderr goes to a FILE, never a pipe: the
    // serving child both tools fork would inherit it and reading to EOF waits
    // on a daemon that never exits.
    let err_path = std::env::temp_dir().join(format!(
        "kaya-clip-seed-{}-{}.err",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    let err_file = std::fs::File::create(&err_path)
        .expect("kaya: clipboard_seed cannot open a file for the writer's stderr");
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::from(err_file))
        .spawn()
        .unwrap_or_else(|e| {
            panic!(
                "kaya: clipboard_seed cannot run the foreign writer: {e} — the lane \
                 image installs wl-clipboard and xclip"
            )
        });
    child
        .stdin
        .take()
        .expect("stdin was piped")
        .write_all(&bytes)
        .expect("kaya: the foreign clipboard writer closed its stdin early");
    let status = child.wait().expect("kaya: the foreign clipboard writer vanished");
    let said = std::fs::read_to_string(&err_path).unwrap_or_default();
    let _ = std::fs::remove_file(&err_path);
    assert!(
        status.success(),
        "kaya: the foreign clipboard writer exited {status}; it said: {said:?}"
    );
}

/// The foreign TARGETS list, for seed verification: what another
/// process can see is offered, not what anyone's bookkeeping claims.
#[cfg(feature = "harness")]
fn foreign_clip_targets() -> String {
    let out = if linux_wayland_session() {
        std::process::Command::new("wl-paste")
            .arg("--list-types")
            .output()
    } else {
        std::process::Command::new("xclip")
            .args(["-selection", "clipboard", "-t", "TARGETS", "-o"])
            .output()
    };
    match out {
        Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
        Err(_) => String::new(),
    }
}

/// The foreign clipboard READER, one type's bytes; empty on a failed
/// transfer or an empty clipboard.
#[cfg(feature = "harness")]
fn foreign_clip_read(mime: &str) -> Vec<u8> {
    let out = if linux_wayland_session() {
        std::process::Command::new("wl-paste")
            .args(["-n", "-t", mime])
            .output()
    } else {
        std::process::Command::new("xclip")
            .args(["-selection", "clipboard", "-t", mime, "-o"])
            .output()
    };
    match out {
        Ok(o) if o.status.success() => o.stdout,
        _ => Vec::new(),
    }
}

/// The first freshening tap of this process has completed (its slow
/// press-hold-release form; later taps take the quick form).
#[cfg(feature = "harness")]
static CLIPBOARD_TAPPED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// The typing verb's twin of CLIPBOARD_TAPPED: the first run of keys
/// into a process meets GDK's late wl_keyboard bind and holds the
/// warm-up key longer for it.
#[cfg(feature = "harness")]
static TYPED_ONCE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// Wayland charges an input-event serial for TAKING the selection, and the
/// charge is NOT ONE-TIME (docs/clipboard-plan.md §5b finding 3): a headless
/// seat earns none, wlroots rejects a stale serial silently, and one dropped
/// copy leaves the guest deaf for the rest of its life. So the harness taps a
/// virtual-keyboard F24 before every step that can copy, press-hold-release
/// the first time, and the keyboard lives only for the tap (2026-08-03).
#[cfg(feature = "harness")]
fn freshen_wayland_serial() {
    use std::sync::atomic::Ordering;
    if !linux_wayland_session() {
        return;
    }
    let first = !CLIPBOARD_TAPPED.swap(true, Ordering::SeqCst);
    let args: &[&str] = if first {
        &["-P", "F24", "-s", "800", "-p", "F24"]
    } else {
        &["-k", "F24"]
    };
    let out = std::process::Command::new("wtype")
        .args(args)
        .output()
        .unwrap_or_else(|e| {
            panic!(
                "kaya: the wayland serial tap needs wtype: {e} — the lane image \
                 installs it (docs/clipboard-plan.md §5b finding 3)"
            )
        });
    assert!(
        out.status.success(),
        "kaya: wtype failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[cfg(feature = "harness")]
impl GtkStage {
    /// Freshen the wayland serial before a step that can lead to a
    /// copy — but only in scenes that will SPEND one (the hub arms
    /// when a clipboard surface appears), so the other two hundred
    /// legs pay nothing.
    fn prime_if_clipboard_scene() {
        if Self::on_main(|core| core.clipboard.armed.get()) {
            freshen_wayland_serial();
        }
    }

    /// The mutable twin of on_main, for stage actions that reconcile
    /// core-owned state (select_section's user route).
    fn on_main_mut<T: Send + 'static>(
        f: impl FnOnce(&mut CoreState) -> T + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        let cell = std::cell::Cell::new(Some((f, tx)));
        glib::idle_add(move || {
            if let Some((f, tx)) = cell.take() {
                CORE.with_borrow_mut(|core| {
                    let core = core.as_mut().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            glib::ControlFlow::Break
        });
        rx.recv().expect("the main context applied the step")
    }

    /// Resolve a range verb's target to the two things every one of them
    /// needs: the ordinal to ask the accessibility bus for, and the live
    /// preedit GTK has reported for that widget. TOTAL, like `menu_state`:
    /// every miss is a short description rather than a panic.
    fn range_target(target: crate::harness::Target) -> Result<RangeTarget, String> {
        if target.kind != crate::harness::TargetKind::Textarea {
            return Err(format!("<{:?} is not a textarea>", target.kind));
        }
        Self::on_main(move |core| {
            let Some(widget) = target_widget(core, target) else {
                return Err("<no such target>".to_owned());
            };
            let Some(rank) = atspi_rank(&core.window, &widget) else {
                return Err("<not in the accessibility tree>".to_owned());
            };
            let preedit = core
                .widgets
                .iter()
                .find(|(_, w)| w.control() == widget)
                .and_then(|(id, _)| core.preedit.borrow().get(&id.0).cloned())
                .unwrap_or_default();
            Ok(RangeTarget { rank, preedit })
        })
    }

    fn on_main<T: Send + 'static>(
        f: impl FnOnce(&CoreState) -> T + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        let cell = std::cell::Cell::new(Some((f, tx)));
        glib::idle_add(move || {
            if let Some((f, tx)) = cell.take() {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            glib::ControlFlow::Break
        });
        rx.recv().expect("the main context applied the step")
    }
}

/// The For CONTAINER a window verb names: `None` for a target that
/// resolves to nothing, `Some(None)` for a container this tier draws no
/// viewport for (no columns declared on it), `Some(Some(id))` otherwise.
#[cfg(feature = "harness")]
fn for_container_id(core: &CoreState, t: crate::harness::Target) -> Option<Option<u64>> {
    use crate::harness::TargetKind as K;
    match t.kind {
        K::Column => {
            let i = crate::harness::try_resolve(t.index, core.columns.len())?;
            let id = core.column_ids[i].0;
            Some(core.tables.contains_key(&id).then_some(id))
        }
        K::Row => {
            crate::harness::try_resolve(t.index, core.rows.len())?;
            Some(None)
        }
        _ => None,
    }
}

/// How many children a container is holding — the whole collection for a
/// For nothing has windowed.
#[cfg(feature = "harness")]
fn container_children(core: &CoreState, t: crate::harness::Target) -> usize {
    use crate::harness::TargetKind as K;
    let registry = if t.kind == K::Column { &core.columns } else { &core.rows };
    crate::harness::try_resolve(t.index, registry.len())
        .map_or(0, |i| children_of(&registry[i]).len())
}

#[cfg(feature = "harness")]
impl crate::harness::Stage for GtkStage {
    fn menu_activate(&self, path: &str) {
        // A role item may cut or copy, which spends the wayland
        // serial (see prime_if_clipboard_scene).
        Self::prime_if_clipboard_scene();
        let path = path.to_owned();
        Self::on_main(move |core| {
            use gtk4::gio::prelude::ActionExt;
            use gtk4::glib::prelude::ToVariant;
            // THE HARNESS-ACTIVATION REFRESH (the mac finding, §3):
            // enablement is recomputed at the two moments it can change
            // hands — chrome about to present, and a harness activation.
            // The GAction's enabled flag refuses a disabled activation
            // natively, so it must be CURRENT before the route resolves.
            refresh_roles(core);
            // An OPEN context menu owns resolution EXCLUSIVELY while
            // presented — no bar fallback (the interpreters' rule).
            let open = *core.open_context.borrow();
            if let Some(anchor) = open {
                let attachment = core
                    .context_menus
                    .get(&anchor)
                    .expect("kaya: the open context menu lost its attachment");
                let route = {
                    let reg = core.menus.borrow();
                    let item = menu_resolve_path(&reg, &attachment.roots, &path)
                        .unwrap_or_else(|| panic!("kaya: no such context item {path:?}"));
                    menu_activation_route(&reg, item, Some(attachment))
                };
                // A leaf fires exactly once and the menu closes: the
                // claim clears BEFORE popdown (the closed handler's
                // equality check no-ops), and the REAL per-anchor
                // action carries the noun.
                *core.open_context.borrow_mut() = None;
                note_claim(&core.context_trail, "context item activated", None);
                attachment.popover.popdown();
                match route {
                    Some((action, None)) => action.activate(None),
                    Some((action, Some(index))) => action.activate(Some(&index.to_variant())),
                    None => {}
                }
                return;
            }
            // The bar route: resolve SEMANTICALLY over the model tree, then
            // drive the REAL window-scoped GAction — the same object bar chrome
            // and the accelerator hit. A disabled action refuses natively.
            let route = {
                let reg = core.menus.borrow();
                let roots = reg.bars.get(&0).cloned().unwrap_or_default();
                let item = menu_resolve_path(&reg, &roots, &path).unwrap_or_else(|| {
                    // REACHING HERE MEANS THE CLAIM WAS NONE, which for a
                    // context item is the whole bug: the bar cannot contain
                    // it, so the useful question is never "which item" but
                    // "what cleared the claim, and when". The trail answers.
                    panic!(
                        "kaya: no such menu item {path:?} on the BAR route — the \
                         open-context claim was None, so this resolved against the \
                         menu bar. If {path:?} is a CONTEXT item, the claim was \
                         taken and lost between context_open and here. What touched \
                         it, newest last:\n{}",
                        claim_trail(&core.context_trail)
                    )
                });
                menu_activation_route(&reg, item, None)
            };
            match route {
                Some((action, None)) => action.activate(None),
                Some((action, Some(index))) => action.activate(Some(&index.to_variant())),
                None => {}
            }
        });
    }

    fn context_open(&self, t: crate::harness::Target) {
        Self::on_main(move |core| {
            let anchor = context_anchor_id(core, t);
            let attachment = core
                .context_menus
                .get(&anchor)
                .unwrap_or_else(|| panic!("kaya: no context menu attached to {t:?}"));
            // The claim, then the REAL chrome: the same popover the
            // right-click gesture presents.
            *core.open_context.borrow_mut() = Some(anchor);
            note_claim(&core.context_trail, "harness context_open", Some(anchor));
            attachment.popover.popup();
        });
    }

    fn menu_count(&self) -> usize {
        Self::on_main(|core| {
            use gtk4::gio::prelude::MenuModelExt;
            // The REAL materialized bar: the GMenu model the
            // PopoverMenuBar renders — its top-level submenus ARE the
            // catalog's grouping roots.
            core.menu_models
                .get(&0)
                .map(|model| model.n_items() as usize)
                .unwrap_or(0)
        })
    }

    fn ax(&self, target: crate::harness::Target) -> String {
        // Correspondence is ORDINAL: the Nth element of the matching role in
        // the app's AT-SPI tree, which is what `kind#index` already means. GTK
        // <= 4.21 publishes no settable accessible id (verified:
        // set_widget_name does NOT surface as one), unlike macOS.
        #[cfg(feature = "harness")]
        {
            // THE ROLE COMES FROM THE WIDGET, NOT FROM ITS KIND: the styling
            // pass's heading role makes a LABEL publish ATSPI heading, and
            // atspi_role_of is what atspi_rank ranks by. AND THE ORDINAL IS
            // NOT kaya's INDEX — the bus's Nth Label counts the captions
            // inside buttons too (`label#0` read `label/Save`, measured
            // 2026-07-25), so kaya's index resolves a WIDGET and its rank
            // among the same bus role, walked DEPTH-FIRST, is the ordinal.
            let Some((want, index)) = Self::on_main(move |core| {
                target_widget(core, target).and_then(|widget| {
                    let want = atspi_role_of(&widget)?;
                    atspi_rank(&core.window, &widget).map(|rank| (want, rank))
                })
            }) else {
                return "<not in the accessibility tree>".to_owned();
            };
            let role = match want {
                atspi::Role::Button => "button",
                atspi::Role::CheckBox => "checkbox",
                atspi::Role::Text => "field",
                atspi::Role::Label => "label",
                // The heading role, spelled the way every other backend
                // spells it: `heading/<the label's text>`.
                atspi::Role::Heading => "heading",
                atspi::Role::Slider => "slider",
                atspi::Role::Image => "image",
                atspi::Role::ProgressBar => "progress",
                atspi::Role::ComboBox => "combobox",
                // The closed set normalizes a scroll pane to `group`,
                // exactly as macOS normalizes AXScrollArea.
                atspi::Role::Grouping | atspi::Role::ScrollPane => "group",
                _ => "unknown",
            };
            return match atspi_collect(want, index, false) {
                Some(name) => format!("{role}/{name}"),
                None => atspi_miss("<not in the accessibility tree>"),
            };
        }
        #[allow(unreachable_code)]
        {
            let _ = target;
        // FAN-OUT PENDING (the depth slice is SwiftUI on mac). Declared
        // so the trait is satisfied and the remaining work stays
        // VISIBLE — a sentinel that can never equal a valid
        // `<role>/<label>` spelling, so any scene asserting on this
        // backend fails loudly instead of quietly passing. Reads GtkAccessible / AT-SPI when it lands.
            "<the GTK accessibility read is not implemented yet>".to_owned()
        }
    }

    /// THE THREE RANGE READS, all three off the ACCESSIBILITY BUS — the same
    /// tree `ax` reads and the same correspondence rules. Nothing here
    /// consults what kaya declared: a leg that passed because the backend
    /// remembered its own intent would prove nothing about the GtkTextTag,
    /// the selection or the viewport.
    fn highlights(&self, target: crate::harness::Target) -> String {
        match Self::range_target(target) {
            Ok(at) => atspi_range_read(at.rank, RangeRead::Highlights)
                .unwrap_or_else(|| atspi_miss("<the accessibility tree did not answer>")),
            Err(why) => why,
        }
    }

    fn selection(&self, target: crate::harness::Target) -> String {
        match Self::range_target(target) {
            Ok(at) => atspi_range_read(at.rank, RangeRead::Selection { preedit: at.preedit })
                .unwrap_or_else(|| atspi_miss("<the accessibility tree did not answer>")),
            Err(why) => why,
        }
    }

    fn revealed(
        &self, target: crate::harness::Target, range: crate::harness::TextRange,
    ) -> String {
        match Self::range_target(target) {
            Ok(at) => atspi_range_read(
                at.rank,
                RangeRead::Revealed { start: range.start, stop: range.stop },
            )
            .unwrap_or_else(|| atspi_miss("<the accessibility tree did not answer>")),
            Err(why) => why,
        }
    }

    /// Start a real input-method composition in the textarea. THE ONLY DOOR
    /// GTK LEAVES OPEN: `gtk_im_context_set_preedit` does not exist and the
    /// preedit never enters the buffer, so kaya BECOMES the input method for
    /// the duration and everything downstream is the platform's — including
    /// the RESET on any programmatic cursor or selection move, which is the
    /// D4 hazard this scene proves.
    fn compose(&self, target: crate::harness::Target, text: &str) {
        let text = text.to_owned();
        let marked = text.clone();
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(target.index, core.textareas.len()) else {
                return;
            };
            let view = core.textareas[i].clone();
            set_kaya_preedit(&view, &marked);
        });
        // Like `type_text`: block until the composition is LIVE, read back
        // through GTK's own signal rather than assumed from the call. A
        // composition the view never rendered is not a composition.
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(2000);
        loop {
            let live = Self::on_main(move |core| {
                crate::harness::try_resolve(target.index, core.textareas.len())
                    .and_then(|i| {
                        let view = &core.textareas[i];
                        core.widgets
                            .iter()
                            .find(|(_, w)| {
                                w.control() == view.clone().upcast::<gtk4::Widget>()
                            })
                            .map(|(id, _)| id.0)
                    })
                    .and_then(|id| core.preedit.borrow().get(&id).cloned())
                    .unwrap_or_default()
            });
            if live == text {
                return;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "kaya: compose {text:?} never reached the view — GTK reported the preedit \
                 as {live:?}. The IM context is installed through the gtk-im-module \
                 extension point (install_kaya_im); a miss there means the view's key \
                 controller published no GtkIMMulticontext."
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    fn ax_hint(&self, target: crate::harness::Target) -> String {
        // The HINT rides AT-SPI's DESCRIPTION — GTK's
        // `Property::Description`, the slot for "what does acting on this
        // do", on the same node `ax` resolves.
        #[cfg(feature = "harness")]
        {
            use crate::harness::TargetKind as K;
            let want = match target.kind {
                K::Button => atspi::Role::Button,
                K::Checkbox => atspi::Role::CheckBox,
                K::Select => atspi::Role::ComboBox,
                K::Radio => atspi::Role::Grouping,
                // The root admits a11y_hint on activation kinds only
                // (scene.rs), so anything else asking for one is a
                // scene bug, said out loud rather than answered.
                _ => return "<the hint prop applies to activation kinds only>".to_owned(),
            };
            let index = match Self::on_main(move |core| {
                target_widget(core, target)
                    .and_then(|widget| atspi_rank(&core.window, &widget))
            }) {
                Some(rank) => rank,
                None => return "<not in the accessibility tree>".to_owned(),
            };
            return match atspi_collect(want, index, true) {
                Some(description) => description,
                None => atspi_miss("<not in the accessibility tree>"),
            };
        }
        #[allow(unreachable_code)]
        {
            let _ = target;
            "<the GTK accessibility read is not implemented yet>".to_owned()
        }
    }

    fn resize_window(&self, window: u64, width: f64, height: f64) {
        // The REAL resize path: the size a user's drag would set. AN ACTION,
        // so a miss IS a bug — but it dies on the HARNESS thread, not inside
        // the main-context closure, where a panic cannot unwind and the runner
        // would record `RecvError` instead of this sentence.
        let missing = Self::on_main_mut(move |core| {
            use gtk4::prelude::GtkWindowExt;
            match gtk_window_read(core, window) {
                Some(target) => {
                    target.set_default_size(width as i32, height as i32);
                    None
                }
                None => Some(live_windows(core)),
            }
        });
        if let Some(live) = missing {
            panic!(
                "kaya: resize_window targeted window#{window}, which this \
                 process does not hold (live windows: {live})"
            );
        }
        // WAIT FOR THE ALLOCATION, then re-run the arm: set_default_size
        // returns before GTK has laid out (docs/traps.md). Polled from the
        // HARNESS thread, never by pumping the main loop inside a CoreState
        // borrow, and for the SAME SIDE OF THE BOUNDARY rather than equality,
        // since a window manager may grant another size. RE-ISSUED EVERY HALF
        // SECOND AND LOUD AT FIVE (docs/traps.md's wayland resize entry).
        let want_regular = width >= 600.0;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut requested = std::time::Instant::now();
        let mut holds = None;
        loop {
            let now = Self::on_main(move |core| window_width(core, window));
            holds = now;
            if matches!(now, Some(w) if (f64::from(w) >= 600.0) == want_regular) {
                break;
            }
            if std::time::Instant::now() >= deadline {
                panic!(
                    "kaya: resize_window {width}x{height} on window#{window} never landed: \
                     the surface holds width {holds:?} after 5s of re-requests — on wayland \
                     the compositor decides the size, and a request racing its configure \
                     can be dropped (docs/traps.md, the wayland resize entry)"
                );
            }
            if requested.elapsed() >= std::time::Duration::from_millis(500) {
                eprintln!(
                    "KAYA_DIAG resize_window {width}x{height} on window#{window} re-requested: \
                     the surface holds width {holds:?}"
                );
                Self::on_main_mut(move |core| {
                    use gtk4::prelude::GtkWindowExt;
                    if let Some(target) = gtk_window_read(core, window) {
                        target.set_default_size(width as i32, height as i32);
                    }
                });
                requested = std::time::Instant::now();
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let _ = holds;
        Self::on_main_mut(move |core| {
            refresh_nav(core, window);
        });
    }

    fn split_presentation(&self) -> String {
        Self::on_main(|core| {
            use gtk4::prelude::GtkWindowExt;
            // The class from the window's real width, the same 600 boundary
            // menu_presentation draws; the presentation from the arm that
            // actually ran, off the SAME source the arm used.
            let Some(width) = window_width(core, 0) else {
                return "<the primary window is not materialized>".to_owned();
            };
            let class = if width >= 600 { "regular" } else { "compact" };
            // THE WIDGETS' OWN ANSWER, not a value the arm stamped about
            // itself: GNOME decides where this collapses. At a ceiling of
            // three the answer is the nested pair's four booleans read in
            // one pass; a window that never requested panes has no widget
            // and falls back to the serial arm's stamp.
            let presentation = match (core.split_views.get(&0), core.inner_splits.get(&0)) {
                (Some(outer), Some(inner)) => {
                    match (outer.is_collapsed(), inner.is_collapsed(), outer.shows_content()) {
                        (false, false, _) => "split3",
                        (false, true, _) | (true, false, true) => "split",
                        (true, _, false) | (true, true, true) => "stacked",
                    }
                }
                (Some(view), None) => {
                    if view.is_collapsed() {
                        "stacked"
                    } else {
                        "split"
                    }
                }
                _ => core.split_presentation.get(&0).copied().unwrap_or("stacked"),
            };
            format!("{class}/{presentation}")
        })
    }

    fn panes_reading(&self) -> String {
        Self::on_main(|core| {
            let Some(width) = window_width(core, 0) else {
                return "<the primary window is not materialized>".to_owned();
            };
            let class = if width >= 600 { "regular" } else { "compact" };
            // The three-pane pair's REAL arrangement when one is up;
            // the two-pane and serial worlds keep the derivation, which
            // is exact there (root + top, or the top alone).
            match three_pane_positions(core, 0) {
                Some(positions) => {
                    let spelled = if positions.is_empty() {
                        "-".to_owned()
                    } else {
                        positions
                            .iter()
                            .map(u64::to_string)
                            .collect::<Vec<_>>()
                            .join(",")
                    };
                    format!("{class}/{spelled}")
                }
                None => {
                    let presentation = match core.split_views.get(&0) {
                        Some(view) => {
                            if view.is_collapsed() {
                                "stacked"
                            } else {
                                "split"
                            }
                        }
                        None => {
                            core.split_presentation.get(&0).copied().unwrap_or("stacked")
                        }
                    };
                    let entries = core.nav_stacks.get(&0).map_or(0, |s| s.len());
                    format!(
                        "{class}/{}",
                        crate::harness::panes_positions(presentation, entries)
                    )
                }
            }
        })
    }

    fn menu_presentation(&self) -> String {
        Self::on_main(|core| {
            use gtk4::prelude::GtkWindowExt;
            // GTK4 has no size-class API of its own, so the class comes from
            // the window's real content width against the same 600 boundary
            // the other platforms draw, on the PRIMARY window.
            let width = core.window.default_size().0;
            let class = if width >= 600 { "regular" } else { "compact" };
            // The presentation is read off the REAL chrome — a
            // PopoverMenuBar exists or it does not. GTK has only the bar
            // lowering, so there is no arm to disagree with the class.
            let bar = core
                .menu_models
                .get(&0)
                .map(|model| {
                    use gtk4::gio::prelude::MenuModelExt;
                    model.n_items() > 0
                })
                .unwrap_or(false);
            format!("{class}/{}", if bar { "bar" } else { "none" })
        })
    }

    fn menu_state(&self, path: &str, aspect: crate::harness::MenuAspect) -> String {
        let path = path.to_owned();
        Self::on_main(move |core| {
            use crate::harness::MenuAspect;
            use gtk4::gio::prelude::ActionExt;
            // THE HARNESS-READ REFRESH — the mac arm's finding 2: enablement
            // is recomputed at the moments it can change hands, and a harness
            // READ is one of them. Without this `expect_menu "Edit>Undo"
            // enabled` answers with whatever the item was born with.
            refresh_roles(core);
            // TOTAL, the try_resolve style: a missing item is a retryable
            // miss — expect_menu doubles as the wait for a catalog rebuild —
            // never a panic. The OPEN context menu owns resolution
            // exclusively while presented.
            let reg = core.menus.borrow();
            let open = *core.open_context.borrow();
            let roots = match open {
                Some(anchor) => match core.context_menus.get(&anchor) {
                    Some(attachment) => attachment.roots.clone(),
                    None => return "no such item".to_owned(),
                },
                None => reg.bars.get(&0).cloned().unwrap_or_default(),
            };
            let Some(id) = menu_resolve_path(&reg, &roots, &path) else {
                return "no such item".to_owned();
            };
            let item = &reg.items[&id];
            match aspect {
                MenuAspect::Enablement => {
                    // The REAL action's flag where one exists (it carries
                    // the inherited AND), including a radio option's own
                    // action. Grouping nodes have no GAction, so the
                    // registry's same AND answers for them.
                    let enabled = match item.actions.first() {
                        Some(action) => action.is_enabled(),
                        None => menu_effective_enabled(&reg, id),
                    };
                    if enabled { "enabled" } else { "disabled" }.to_owned()
                }
                MenuAspect::Checkedness => {
                    // The stateful action's own bool — what GMenu
                    // renders as the checkmark.
                    match item
                        .actions
                        .first()
                        .and_then(|action| action.state())
                        .and_then(|state| state.get::<bool>())
                    {
                        Some(true) => "checked".to_owned(),
                        Some(false) => "unchecked".to_owned(),
                        None => "not a toggle".to_owned(),
                    }
                }
                MenuAspect::Value => {
                    // The state lives on the OPTIONS' actions, one per option
                    // and all carrying the group's selected index, which is
                    // what each row compares its target against. A group with
                    // no options yet has no such state to read.
                    match item
                        .children
                        .first()
                        .and_then(|option| reg.items[option].actions.first())
                        .and_then(|action| action.state())
                        .and_then(|state| state.get::<i32>())
                    {
                        Some(index) => format!("value {index}"),
                        None => "not a radio group".to_owned(),
                    }
                }
            }
        })
    }

    fn menu_symbol(&self, path: &str) -> String {
        // THE REAL ROW GTK BUILT, never the registry's mirror. GtkModelButton
        // is private to GTK, so the row is found by GType NAME and read
        // through GObject properties — which is why every step below states
        // what it measured: a walk that finds nothing must not answer like a
        // row that carries nothing. TOTAL, the menu_state style.
        let path = path.to_owned();
        Self::on_main(move |core| {
            use gtk4::prelude::{Cast, WidgetExt};
            let reg = core.menus.borrow();
            // Open-context EXCLUSIVITY, the state read's rule verbatim.
            let open = *core.open_context.borrow();
            let roots = match open {
                Some(anchor) => match core.context_menus.get(&anchor) {
                    Some(attachment) => attachment.roots.clone(),
                    None => return "no such item".to_owned(),
                },
                None => reg.bars.get(&0).cloned().unwrap_or_default(),
            };
            let Some(id) = menu_resolve_path(&reg, &roots, &path) else {
                return "no such item".to_owned();
            };
            let label = reg.items[&id].label.clone();

            // The chrome that presents this item's tree.
            let popover: gtk4::Widget = match open {
                Some(anchor) => core.context_menus[&anchor].popover.clone().upcast(),
                None => {
                    let root = menu_root_of(&reg, id);
                    if root == id {
                        // MEASURED, not assumed: PopoverMenuBar gives a
                        // top-level holder a GtkPopoverMenuBarItem whose only
                        // content is a GtkLabel, so there is no icon slot on
                        // the bar at all.
                        return "a top-level menu on GTK's bar carries no icon".to_owned();
                    }
                    // BY LABEL, not by ordinal: a drifted ordinal answers with
                    // a DIFFERENT menu's icon instead of failing, and
                    // menu_resolve_path already makes a byte-for-byte label
                    // the identity of a menu.
                    let want = reg.items[&root].label.clone();
                    let bar = core
                        .menu_strips
                        .get(&0)
                        .and_then(|(strip, _)| strip.first_child())
                        .and_then(|w| w.downcast::<gtk4::PopoverMenuBar>().ok());
                    let Some(bar) = bar else {
                        return "the window has no menu bar chrome".to_owned();
                    };
                    let mut shown: Vec<String> = Vec::new();
                    let mut found = None;
                    let mut child = bar.first_child();
                    while let Some(w) = child {
                        let text = first_label_text(&w).unwrap_or_default();
                        if found.is_none() && text == want {
                            found = Some(w.clone());
                        }
                        shown.push(text);
                        child = w.next_sibling();
                    }
                    let Some(item_widget) = found else {
                        return format!("the bar shows {shown:?}, none of them {want:?}");
                    };
                    item_widget
                }
            };

            let mut rows = Vec::new();
            collect_model_buttons(&popover, &mut rows);
            let matching: Vec<&gtk4::Widget> = rows
                .iter()
                .filter(|w| widget_string_prop(w, "text").as_deref() == Some(label.as_str()))
                .collect();
            let row = match matching.len() {
                0 => {
                    // The registry has the item and the chrome has no row for
                    // it. TWO causes reach here — a rebuild still pending,
                    // and a kind that mints no row at all (a nested radio
                    // GROUP renders as a labeled GMenu *section*, and a
                    // section header has no icon attribute) — and this reader
                    // cannot tell them apart. So it prints the KIND.
                    return format!(
                        "no menu row is materialized for {label:?} (kind {:?})",
                        reg.items[&id].kind
                    );
                }
                1 => matching[0],
                n => {
                    return format!("{n} menu rows carry the label {label:?}");
                }
            };

            let Some(icon) = widget_icon_prop(row) else {
                // WHAT THIS MEASURED: the row exists in the real chrome and
                // GTK holds no GIcon for it. Deliberately NOT "no symbol":
                // this reader cannot tell "the app declared none" from
                // "declared and never lowered" (invariant 3).
                return "no icon on the menu row".to_owned();
            };
            // GThemedIcon carries a fallback chain (GIO appends the
            // non-symbolic spelling of a `-symbolic` name), so every
            // name is tried; only kaya's own `-symbolic` spellings are
            // in the table, and the bare fallbacks cannot collide.
            if let Some(themed) = icon.downcast_ref::<gio::ThemedIcon>() {
                for name in &themed.names() {
                    if let Some(semantic) = symbol_name_of_icon(name.as_str()) {
                        return semantic.to_owned();
                    }
                }
            }
            // ONE sentence for both ways this can fail — an icon that is not
            // themed at all, and a themed one naming something the table does
            // not hold — because the useful half is the same in both: GIcon's
            // own serialization, which is what was actually on the row.
            let shown = gio::prelude::IconExt::to_string(&icon)
                .map(|s| s.to_string())
                .unwrap_or_else(|| "<not serializable>".to_owned());
            format!("the row's icon is {shown:?}, which is not in this backend's symbol table")
        })
    }

    /// THE expect_toolbar READ on GTK: `<promoted found>/<promoted in the
    /// catalog>/<buttons the header holds>/<remainder's home>`. THREE
    /// DIFFERENT SIDES on purpose — the model, the REAL AdwHeaderBar, and the
    /// ACCESSIBILITY BUS, which is the one reading that fails when the
    /// accessible name is missing. THE REMAINDER'S HOME IS THE MENU BAR
    /// because this backend renders the whole catalog as one.
    fn toolbar_chrome(&self) -> String {
        let (title, promoted, held, home) = Self::on_main(|core| {
            let promoted: Vec<String> = {
                let reg = core.menus.borrow();
                promoted_items(&reg, 0)
                    .iter()
                    .map(|id| reg.items[id].label.clone())
                    .collect()
            };
            (
                core.window_titles.get(&0).cloned().unwrap_or_default(),
                promoted,
                chrome_buttons(core, 0).len(),
                remainder_home(core, 0),
            )
        });
        let published = match atspi_promoted_buttons(&title) {
            Ok(published) => published,
            // NOT `0/n/m/menubar`: that spelling would print "0 of the 2
            // promoted actions are among them", blaming a promotion that may
            // well be there — a diagnostic saying what it did not measure
            // (invariant 3).
            Err(why) => return format!("the accessibility bus did not answer ({}) {}", why.why, BUS_FIX),
        };
        let mut found = 0;
        for (name, _) in &published {
            if found < promoted.len() && name.as_bytes() == promoted[found].as_bytes() {
                found += 1;
            }
        }
        format!("{found}/{}/{held}/{home}", promoted.len())
    }

    /// THE expect_toolbar_item READ on GTK: one aspect of the real header
    /// button, addressed by the name the ACCESSIBILITY BUS publishes — never
    /// by kaya's promotion list and never by the tooltip, which fills the same
    /// name. ENABLEMENT IS `sensitive`, measured: ENABLED is false for every
    /// node on this stack while SENSITIVE tracks the action. The bus and
    /// widget halves pair BY POSITION, and a length mismatch is REPORTED.
    fn toolbar_item(&self, label: &str, aspect: &str) -> String {
        let (title, drawn, held) = Self::on_main(|core| {
            use gtk4::prelude::Cast;
            let buttons = chrome_buttons(core, 0);
            let held = buttons.len();
            // The buttons that DRAW a kaya symbol, in pack order — the
            // same set the bus walk scopes to by description, so the two
            // lists pair position by position.
            let drawn: Vec<String> = buttons
                .iter()
                .filter_map(|(_, button)| {
                    first_image_icon_name(button.upcast_ref::<gtk4::Widget>())
                })
                .filter(|icon| symbol_name_of_icon(icon).is_some())
                .collect();
            (
                core.window_titles.get(&0).cloned().unwrap_or_default(),
                drawn,
                held,
            )
        });
        let published = match atspi_promoted_buttons(&title) {
            Ok(published) => published,
            Err(why) => return format!("the accessibility bus did not answer ({}) {}", why.why, BUS_FIX),
        };
        let matches: Vec<usize> = published
            .iter()
            .enumerate()
            .filter(|(_, (name, _))| name.as_bytes() == label.as_bytes())
            .map(|(i, _)| i)
            .collect();
        let index = match matches[..] {
            [index] => index,
            [] => {
                let shown: Vec<&str> = published.iter().map(|(n, _)| n.as_str()).collect();
                return format!(
                    "no toolbar item labelled {label} (the header holds {held} buttons; \
                     the promoted ones publish: {shown:?})"
                );
            }
            _ => {
                return format!(
                    "{} toolbar buttons publish the name {label}, so which one this \
                     step means is ambiguous",
                    matches.len()
                );
            }
        };
        if aspect == "enabled" || aspect == "disabled" {
            return if published[index].1 { "enabled" } else { "disabled" }.to_owned();
        }
        if drawn.len() != published.len() {
            return format!(
                "the bus published {} promoted buttons and the header draws {} kaya \
                 symbols, so the two cannot be paired",
                published.len(),
                drawn.len()
            );
        }
        match symbol_name_of_icon(&drawn[index]) {
            Some(name) => name.to_owned(),
            None => format!(
                "the toolbar button {label} draws {:?}, which is not in this \
                 backend's symbol table",
                drawn[index]
            ),
        }
    }

    fn shortcut(&self, spelling: &str) {
        // Same two reasons as menu_activate: the chord may land on a
        // role item.
        Self::prime_if_clipboard_scene();
        let spelling = spelling.to_owned();
        Self::on_main(move |core| {
            refresh_roles(core);
            // The platform's own table: the application accelerator map
            // set_accels_for_action filled — the exact table
            // GtkApplicationWindow's accel controller walks for a real key
            // press, which gates an unowned chord to a SILENT no-op.
            let Some(app) = core.app.as_ref() else { return };
            let accel = menu_accel(&spelling)
                .unwrap_or_else(|| panic!("kaya: shortcut {spelling:?}: unmappable spelling"));
            let want = gtk4::accelerator_parse(&accel).unwrap_or_else(|| {
                panic!("kaya: shortcut {spelling:?}: GTK rejected accelerator {accel:?}")
            });
            for description in app.list_action_descriptions() {
                let owns = app
                    .accels_for_action(&description)
                    .iter()
                    .any(|a| gtk4::accelerator_parse(a) == Some(want));
                if !owns {
                    continue;
                }
                // The action machinery end to end: resolve the detailed name
                // through the owning window's muxer, so the SAME
                // GSimpleAction handler emits the SAME menu_activated. A
                // DETAILED name carries an option's target (`win.kmi-7(1)`).
                let Ok((name, param)) = gio::Action::parse_detailed_name(&description) else {
                    continue;
                };
                let target = name
                    .strip_prefix("win.kmi-")
                    .and_then(|id| id.parse::<u64>().ok())
                    .and_then(|id| {
                        let reg = core.menus.borrow();
                        reg.bar_of.get(&menu_root_of(&reg, id)).copied()
                    })
                    // The read flavor and the primary as the fallback:
                    // a catalog entry whose window has already gone
                    // takes the same route as one with no window at all.
                    .and_then(|window| gtk_window_read(core, window))
                    .unwrap_or_else(|| core.window.clone());
                let _ = target.activate_action(&name, param.as_ref());
                return;
            }
            // Nothing in the catalog owns this chord — a script error,
            // said out loud rather than passing as a no-op (the WinUI
            // lesson, docs/traps.md).
            panic!(
                "kaya: shortcut {spelling:?}: no catalog item owns this chord \
                 (the leaf kinds that may carry one are action, toggle, and \
                 radio option)"
            );
        });
    }

    fn click(&self, t: crate::harness::Target) {
        // A click's handler may copy, and a copy spends the wayland
        // serial the headless session never delivered on its own.
        Self::prime_if_clipboard_scene();
        Self::on_main(move |core| {
            // A click on a TEXT KIND focuses it — what a native click does to
            // a field, and the only way a scene can focus a STAMPED copy.
            // grab_focus lands on the entry's inner GtkText exactly as a
            // pointer click would, which is why is_focused reads FOCUS_WITHIN.
            match t.kind {
                crate::harness::TargetKind::Entry => {
                    let i = crate::harness::resolve(t.index, core.entries.len());
                    core.entries[i].grab_focus();
                }
                crate::harness::TargetKind::Textarea => {
                    let i = crate::harness::resolve(t.index, core.textareas.len());
                    core.textareas[i].grab_focus();
                }
                _ => {
                    let i = crate::harness::resolve(t.index, core.buttons.len());
                    core.buttons[i].emit_clicked();
                }
            }
        });
    }

    fn toggle(&self, t: crate::harness::Target, on: bool) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.checkboxes.len());
            core.checkboxes[i].set_active(on);
        });
    }

    fn set_value(&self, t: crate::harness::Target, value: f64) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.sliders.len());
            core.sliders[i].set_value(value);
        });
    }

    /// The real-keystroke typing verb (docs/undo-plan.md A8), to harness.rs's
    /// six-point contract: the PLATFORM'S OWN INPUT PATH (`wtype` or
    /// `xdotool`), delivered to whatever holds focus, APPENDING at the end
    /// with nothing selected, blocking until the text has landed, one key
    /// event per character. THE FIRST KEYSTROKE IS LOST WITHOUT A WARM-UP on
    /// wayland (docs/traps.md: "A fresh wtype keyboard loses its first key").
    fn type_text(&self, text: &str) {
        assert!(
            !text.starts_with('-'),
            "kaya: type {text:?} begins with '-', which both injection tools read as an \
             option — type text that does not, or teach this verb a tool that takes a \
             payload on stdin"
        );
        // FIRST, LET THE PREVIOUS STEP'S CONSEQUENCES LAND: an ACTION returns
        // as soon as it is delivered, so a `focus` transaction can still be in
        // flight, and GTK's grab_focus SELECTS THE ENTRY'S CONTENTS — turning
        // an append into a REPLACE (measured under an eight-wide pool
        // 2026-08-04). Quiescence, bounded: several consecutive empty drains
        // before typing, then type anyway.
        let settle = std::time::Instant::now() + std::time::Duration::from_millis(500);
        let mut quiet = 0;
        while quiet < 3 && std::time::Instant::now() < settle {
            let applied = Self::on_main_mut(|core| {
                // THE SECOND NOUNWIND BOUNDARY IN THIS FILE, and it is
                // easy to miss: `on_main_mut` runs this inside
                // `glib::idle_add`, so it is a C callback exactly like
                // `drain_transactions`, and this is a SECOND copy of the
                // drain rather than a call to it (crates/kaya/src/fault.rs).
                crate::fault::guard("draining a transaction", || {
                    let mut n = 0usize;
                    while let Ok(tx) = core.transactions.try_recv() {
                        for op in core.scene.apply(tx) {
                            apply(core, op);
                        }
                        for occ in core.scene.take_asks() {
                            core.occurrences.send(occ);
                        }
                        n += 1;
                    }
                    if n > 0 {
                        refresh_roles(core);
                    }
                    n
                })
                // A FAULT IS NOT QUIESCENCE, but it ends the wait the
                // same way: nothing more will be applied, and the
                // harness reddens at the next step.
                .unwrap_or(0)
            });
            quiet = if applied == 0 { quiet + 1 } else { 0 };
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        // Point 3, on the main context: a caret move, which is not an
        // edit and spends no native undo step.
        let target = Self::on_main(move |core| {
            let id = core.clipboard.focused_widget_id().map(WidgetId)?;
            match core.widgets.get(&id) {
                Some(NativeWidget::Entry(entry)) => {
                    gtk4::prelude::EditableExt::set_position(entry, -1);
                }
                Some(NativeWidget::Textarea(_, view)) => {
                    let buffer = view.buffer();
                    buffer.place_cursor(&buffer.end_iter());
                }
                // Nothing editable focused: the keys still go where the
                // platform sends them (point 2), and a following
                // assertion reports the mismatch (point 4's contract).
                _ => return None,
            }
            Some((id, core.text_of(id).unwrap_or_default()))
        });
        let hold = if TYPED_ONCE.swap(true, std::sync::atomic::Ordering::SeqCst) {
            "150"
        } else {
            // The first invocation in a process meets the same late
            // bind the clipboard tap does; later ones meet only the
            // per-invocation keyboard race, which any hold covers.
            "800"
        };
        // THE CARET MOVE RIDES THE SAME INPUT STREAM as the characters, ahead
        // of them: Ctrl+End is a real key event that goes to the end and
        // collapses any selection. The characters follow with the SMALLEST
        // inter-key delay each tool takes (wtype refuses 0 — "Invalid sleep
        // time", measured), keeping the burst inside GDK's event reading.
        let pid_arg;
        let window_arg;
        let (tool, args): (&str, Vec<&str>) = if linux_wayland_session() {
            (
                "wtype",
                vec![
                    "-P", "F24", "-s", hold, "-p", "F24", "-s", "20", "-M", "ctrl", "-k",
                    "End", "-m", "ctrl", "-s", "10", "-d", "1", text,
                ],
            )
        } else {
            // THE POINTER IS PARKED OVER THE PRIMARY WINDOW FIRST, and focus
            // re-asserted: with no window manager a closing dialog's X focus
            // reverts to POINTERROOT, so growing the Xvfb screen put the
            // centred pointer on the ROOT and post-dialog typing landed
            // nowhere (docs/traps.md: "The x11 lane has NO window manager, so
            // X focus reverts to POINTERROOT"). The window id is by pid first.
            ("xdotool", {
                pid_arg = std::process::id().to_string();
                let found = std::process::Command::new("xdotool")
                    .args(["search", "--onlyvisible", "--pid", pid_arg.as_str()])
                    .output()
                    .ok()
                    .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
                    .unwrap_or_default();
                window_arg = found.split_whitespace().next().unwrap_or("").to_owned();
                if window_arg.is_empty() {
                    vec!["key", "ctrl+End", "type", "--delay", "0", text]
                } else {
                    vec![
                        "mousemove", "--window", &window_arg, "40", "40",
                        "windowfocus", &window_arg, "key", "ctrl+End", "type",
                        "--delay", "0", text,
                    ]
                }
            })
        };
        let send = || {
            let out = std::process::Command::new(tool)
                .args(&args)
                .output()
                .unwrap_or_else(|e| {
                    panic!(
                        "kaya: the typing verb needs {tool}: {e} — the lane image installs it \
                         (tools/linux/Dockerfile; docs/undo-plan.md A8)"
                    )
                });
            assert!(
                out.status.success(),
                "kaya: {tool} failed: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        };
        send();
        // Point 4: every character delivered AND processed.
        let Some((id, before)) = target else { return };
        let want = format!("{before}{text}");
        // THE SEND IS RETRIED ONCE: a GTK dialog's X teardown can reset input
        // focus AFTER the focus-then-keys chain ran, later the more pixels the
        // software renderer pushes (measured 2026-08-20). The retry is taken
        // ONLY when the field provably holds exactly the pre-send text — a
        // partial landing means the keys are arriving, and a resend would
        // append twice.
        let mut resent = false;
        let mut deadline = std::time::Instant::now() + std::time::Duration::from_millis(2000);
        loop {
            let now = Self::on_main(move |core| core.text_of(id).unwrap_or_default());
            if !resent && now == before && std::time::Instant::now() >= deadline {
                eprintln!(
                    "KAYA_UNDO_TRACE: type {text:?} did not land within 2s and the field \
                     is untouched — re-asserting focus and sending once more"
                );
                resent = true;
                send();
                deadline = std::time::Instant::now() + std::time::Duration::from_millis(2000);
                continue;
            }
            if now == want {
                // AND THE KEYS FILLED THE NATIVE HISTORY, the one thing a
                // stand-in cannot fake: a `set_text` here would satisfy every
                // assertion in tools/scenes/undo.steps while the native tier
                // went untested and the leg went green.
                let filled = Self::on_main(move |core| core.native_undo_filled(id));
                assert!(
                    filled,
                    "kaya: type {text:?} landed but the field's NATIVE undo history is \
                     still empty — the characters did not travel the platform's own \
                     input path (harness.rs Stage::type_text, point 1), and a \
                     native-tier scene would pass having observed nothing"
                );
                return;
            }
            if std::time::Instant::now() >= deadline {
                // NOT a verdict — the contract says a following assertion
                // reports the mismatch — but never silent either. And it
                // prints WHAT IT MEASURED (the diagnostics rule): every
                // toplevel's active state and focus widget, plus X's own
                // focus window — the discriminators between keys that
                // went to the wrong window and keys GTK routed away.
                let toplevels = Self::on_main(|_| {
                    use gtk4::gio::prelude::ListModelExt;
                    use gtk4::prelude::{GtkWindowExt, WidgetExt};
                    let list = gtk4::Window::toplevels();
                    let mut out = Vec::new();
                    for i in 0..list.n_items() {
                        let Some(window) = list
                            .item(i)
                            .and_then(|o| o.downcast::<gtk4::Window>().ok())
                        else {
                            continue;
                        };
                        out.push(format!(
                            "{:?}(visible={} active={} focus={})",
                            window.title().unwrap_or_default(),
                            window.is_visible(),
                            window.is_active(),
                            GtkWindowExt::focus(&window)
                                .map(|f| f.type_().name().to_owned())
                                .unwrap_or_else(|| "<none>".to_owned()),
                        ));
                    }
                    out.join(", ")
                });
                let xfocus = std::process::Command::new("xdotool")
                    .args(["getwindowfocus", "getwindowname"])
                    .output()
                    .map(|o| {
                        String::from_utf8_lossy(&o.stdout).trim().to_owned()
                    })
                    .unwrap_or_else(|e| format!("<{e}>"));
                let pid = std::process::id().to_string();
                let mine = std::process::Command::new("xdotool")
                    .args(["search", "--onlyvisible", "--pid", &pid])
                    .output()
                    .map(|o| {
                        String::from_utf8_lossy(&o.stdout)
                            .split_whitespace()
                            .map(String::from)
                            .collect::<Vec<_>>()
                            .join(" ")
                    })
                    .unwrap_or_else(|e| format!("<{e}>"));
                eprintln!(
                    "KAYA_UNDO_TRACE: type {text:?} never landed: the field holds {now:?}, \
                     expected {want:?} after {tool} reported success; toplevels: \
                     [{toplevels}]; x focus window: {xfocus:?}; this pid's visible x \
                     windows: [{mine}]"
                );
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    fn set_text(&self, t: crate::harness::Target, text: &str) {
        let text = text.to_owned();
        Self::on_main(move |core| {
            // The user path per kind: the buffer/entry change signal
            // fires and emits (the quiet guard is off).
            let widget = if t.kind == crate::harness::TargetKind::Textarea {
                let i = crate::harness::resolve(t.index, core.textareas.len());
                core.textareas[i].buffer().set_text(&text);
                core.textareas[i].clone().upcast::<gtk4::Widget>()
            } else {
                let i = crate::harness::resolve(t.index, core.entries.len());
                core.entries[i].set_text(&text);
                core.entries[i].clone().upcast::<gtk4::Widget>()
            };
            // IT EMITS LIKE THE USER AND IT WRITES LIKE THE APP: a
            // programmatic write wipes a GTK field's undo history (measured),
            // so the model of that stack is corrected here. BY CONTROL, not by
            // layout widget — a lookup keyed on the viewport would find
            // nothing and leave the model uncorrected.
            if let Some((id, _)) = core.widgets.iter().find(|(_, w)| w.control() == widget) {
                let id = *id;
                core.clear_native_undo(id);
            }
        });
    }

    fn read_label(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.labels.len()) else {
                return "<no such target>".to_string();
            };
            core.labels[i].text().to_string()
        })
    }

    fn read_text(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            if t.kind == crate::harness::TargetKind::Textarea {
                let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len()) else {
                    return "<no such target>".to_string();
                };
                let b = core.textareas[i].buffer();
                return lf(b.text(&b.start_iter(), &b.end_iter(), false).to_string());
            }
            let Some(i) = crate::harness::try_resolve(t.index, core.entries.len()) else {
                return "<no such target>".to_string();
            };
            lf(core.entries[i].text().to_string())
        })
    }

    fn image_size(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.images.len()) else {
                return "<no such target>".to_string();
            };
            // The paintable's intrinsic size, in pixels for a texture;
            // no paintable is the placeholder class, "0x0".
            match core.images[i].paintable() {
                Some(paintable) => format!(
                    "{}x{}",
                    paintable.intrinsic_width(),
                    paintable.intrinsic_height()
                ),
                None => "0x0".into(),
            }
        })
    }

    fn is_focused(&self, t: crate::harness::Target) -> bool {
        Self::on_main(move |core| {
            // A focused GtkEntry delegates to its internal GtkText, so
            // the entry itself is never the toplevel's focus widget
            // (is_focus() stays false) — FOCUS_WITHIN is the flag GTK
            // sets on the ancestors of the focus widget.
            match t.kind {
                crate::harness::TargetKind::Entry => {
                    let Some(i) = crate::harness::try_resolve(t.index, core.entries.len()) else {
                        return false;
                    };
                    widget_focused(&core.entries[i])
                }
                crate::harness::TargetKind::Textarea => {
                    let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len())
                    else {
                        return false;
                    };
                    widget_focused(&core.textareas[i])
                }
                other => panic!("kaya: is_focused not wired for {other:?} on gtk"),
            }
        })
    }


    // The table verbs (docs/tables-plan.md). All four are TREE READS of
    // the header this backend composed and the rows the stamp parented,
    // so none of them can agree with a model copy.
    fn columns_presented(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.columns.len()) else {
                return "<no such target>".to_string();
            };
            // Empty when no table rendered — the header row is what this
            // reads, and a container with no columns declared has none.
            let Some(header) = table_header(&core.columns[i]) else {
                return String::new();
            };
            let mut titles = Vec::new();
            let mut indicator = String::new();
            for (index, cell) in children_of(&header).into_iter().enumerate() {
                let text = header_cell_text(&cell);
                if let Some(title) = text.strip_suffix(" \u{25B2}") {
                    titles.push(title.to_string());
                    indicator = format!(" ^{index}");
                } else if let Some(title) = text.strip_suffix(" \u{25BC}") {
                    titles.push(title.to_string());
                    indicator = format!(" v{index}");
                } else {
                    titles.push(text);
                }
            }
            format!("{}{indicator}", titles.join("|"))
        })
    }

    fn row_cells(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.columns.len()) else {
                return "<no such target>".to_string();
            };
            // Child order as the toolkit holds it, both levels — the
            // registries are creation-ordered and cannot see a move.
            table_rows(&core.columns[i])
                .into_iter()
                .map(|row| {
                    children_of(&row)
                        .into_iter()
                        .filter_map(|cell| {
                            let label = cell.downcast::<gtk4::Label>().ok()?;
                            core.labels
                                .iter()
                                .any(|l| l == &label)
                                .then(|| label.text().to_string())
                        })
                        .collect::<Vec<_>>()
                        .join(",")
                })
                .collect::<Vec<_>>()
                .join("|")
        })
    }

    fn column_edges(&self, t: crate::harness::Target, want: usize) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.columns.len()) else {
                return "<no such target>".to_string();
            };
            let column = core.columns[i].clone();
            // Pending resizes must land before any of this means
            // anything; the first read after mount otherwise sees zeros.
            while glib::MainContext::default().iteration(false) {}
            let Some(header) = table_header(&column) else {
                return "no columns declared on this container".to_string();
            };
            // kaya composes this header, so its cells are IN the claim
            // (the native mac path, whose header is NSTableView's own,
            // clusters cells alone). Header and body go through the SAME
            // unwrap — see cell_ink.
            let ink = |cells: Vec<gtk4::Widget>| -> Vec<gtk4::Widget> {
                cells.iter().map(cell_ink).collect()
            };
            let mut lines = vec![ink(children_of(&header))];
            lines.extend(table_rows(&column).iter().map(|row| ink(children_of(row))));
            let target: gtk4::Widget = column.clone().upcast();
            let mut edges: Vec<f64> = Vec::new();
            let mut min_drawn = f64::MAX;
            let mut max_drawn = f64::MIN;
            for line in &lines {
                let mut end = None;
                for cell in line {
                    let Some(rect) = cell.compute_bounds(&target) else {
                        return "the toolkit places no cell here yet".to_string();
                    };
                    edges.push(f64::from(rect.x()));
                    let cell_end = f64::from(rect.x()) + f64::from(rect.width());
                    end = Some(end.map_or(cell_end, |line_end: f64| line_end.max(cell_end)));
                }
                if let Some(end) = end {
                    min_drawn = min_drawn.min(end);
                    max_drawn = max_drawn.max(end);
                }
            }
            if edges.is_empty() {
                return "no cells".to_string();
            }
            edges.sort_by(|a, b| a.total_cmp(b));
            let min_start = edges[0];
            let mut clusters: Vec<f64> = Vec::new();
            for x in edges {
                match clusters.last() {
                    Some(last) if x - last <= 2.0 => {}
                    _ => clusters.push(x),
                }
            }
            if clusters.len() != want {
                let at: Vec<i64> = clusters.iter().map(|x| x.round() as i64).collect();
                return format!(
                    "{} cell edge clusters at {at:?}px, wanted {want}",
                    clusters.len()
                );
            }
            let viewport = f64::from(column.width());
            let assigned = table_horizontal_track(&column);
            // HOW FAR THE SURFACE CAN GO, off the toolkit's own adjustment:
            // columns past the viewport are the ruling's normal state and
            // convict nothing while the table can scroll to them.
            let reach = table_body_view(&column).map_or(0.0, |view| {
                let adj = view.hadjustment();
                (adj.upper() - adj.page_size()).max(0.0)
            });
            let issue =
                table_horizontal_issue(min_start, min_drawn, max_drawn, viewport, assigned, reach);
            match issue {
                Some(TableHorizontalIssue::TrackUnderfill) => {
                    return format!(
                        "viewport draws {}px of its assigned {}px track",
                        viewport.round(),
                        assigned.round()
                    );
                }
                Some(TableHorizontalIssue::TrackOverflow) => {
                    return format!(
                        "viewport spans {}px outside its assigned {}px track",
                        viewport.round(),
                        assigned.round()
                    );
                }
                Some(TableHorizontalIssue::ContentLeftUnderfill) => {
                    return format!(
                        "cells start at {}px inside a {}px viewport",
                        min_start.round(),
                        viewport.round()
                    );
                }
                Some(TableHorizontalIssue::ContentLeftOverflow) => {
                    return format!(
                        "cells start at {}px outside a {}px viewport",
                        min_start.round(),
                        viewport.round()
                    );
                }
                Some(TableHorizontalIssue::ContentUnderfill) => {
                    return format!(
                        "draws {}px of a {}px viewport",
                        min_drawn.round(),
                        viewport.round()
                    );
                }
                Some(TableHorizontalIssue::ContentUnreachable) => {
                    return format!(
                        "cells end at {}px past a {}px viewport that scrolls {}px",
                        max_drawn.round(),
                        viewport.round(),
                        reach.round()
                    );
                }
                None => {}
            }
            String::new()
        })
    }


    /// The first VISIBLE row and the collection's declared total, driven
    /// off a fresh report so a poll that finds the band mid-move drives
    /// it one step further rather than freezing it.
    fn window_band(&self, t: crate::harness::Target) -> String {
        Self::on_main_mut(move |core| {
            let Some(id) = for_container_id(core, t) else {
                return "<no such target>".to_owned();
            };
            let Some(id) = id else {
                // A For this tier draws no viewport for — no columns were
                // declared on it — realizes every row it holds, and its
                // first row is the visible one at rest. Truthful, and
                // exactly what an unreported window answers.
                let rows = container_children(core, t);
                return format!("0 {rows}");
            };
            let (first, total) = window_report(core, id);
            reflow_table(core, id);
            format!("{first} {total}")
        })
    }

    /// The core maps the KEY to a position in the collection's current
    /// order and this tier parks that row at the viewport's TOP. An
    /// ACTION: the expect_window after it is the observable, so the only
    /// answer here is a sentence about what stopped it.
    fn scroll_to_row(&self, t: crate::harness::Target, key: &str) -> String {
        let key = key.to_owned();
        Self::on_main_mut(move |core| {
            let Some(id) = for_container_id(core, t) else {
                return "<no such target>".to_owned();
            };
            let Some(id) = id else {
                return "this container declares no columns, so this tier gives it \
                        no viewport to park a row in (docs/virtualization-plan.md §6.3)"
                    .to_owned();
            };
            let scene = &mut core.scene;
            let Some(index) = crate::fault::guard("resolving scroll_to_row", || {
                scene.scroll_to_row(id, &crate::protocol::Value::Str(key.clone()))
            }) else {
                return format!("no row of this collection carries the key {key:?}");
            };
            // THE BAND FOLLOWS THE ROW BEFORE THE PIXELS DO: the range is
            // reported from the index the CORE resolved rather than from
            // an estimate off the scrollbar, which is the one reading that
            // is exact on the corrected path too. Parking is then
            // window_report's re-park, on the anchor set here.
            let count = core.tables.get(&id).and_then(|t| t.reported).map_or(1, |(_, c)| c.max(1));
            if let Some(table) = core.tables.get(&id) {
                table.anchor.set(Some(index));
            }
            let scene = &mut core.scene;
            let ops = crate::fault::guard("reporting a window range", || {
                scene.window_moved(id, index, count)
            });
            if let Some(table) = core.tables.get_mut(&id) {
                table.reported = Some((index, count));
            }
            for op in ops.unwrap_or_default() {
                apply(core, op);
            }
            // The entering rows have to exist before the scroll can land
            // on one, and the spacers above them have to be the core's
            // before the adjustment's upper covers the row at all.
            window_report(core, id);
            reflow_table(core, id);
            while glib::MainContext::default().iteration(false) {}
            window_report(core, id);
            reflow_table(core, id);
            String::new()
        })
    }
    fn header_click(&self, t: crate::harness::Target, column: u32) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.columns.len());
            let header = table_header(&core.columns[i]).unwrap_or_else(|| {
                panic!("kaya: header_click on {t:?}, which declares no columns")
            });
            let cells = children_of(&header);
            let cell = cells.get(column as usize).unwrap_or_else(|| {
                panic!(
                    "kaya: header_click column {column} on {t:?}, which presents {} columns",
                    cells.len()
                )
            });
            // The user's own route: a header cell IS a GtkButton, so
            // this is `press`'s emit_clicked and the handler that emits
            // sort_requested is the one the pointer would have run.
            cell.downcast_ref::<gtk4::Button>()
                .expect("kaya composed the header from buttons")
                .emit_clicked();
        });
    }

    fn resolve_id(
        &self,
        kind: crate::harness::TargetKind,
        id: &str,
        keys: Option<&str>,
    ) -> Option<isize> {
        // The a11y_id arm wrote the authored key onto the WIDGET NAME
        // (set_widget_name, the AT-SPI accessible-id lowering), so the
        // records this reads are the backend's own applied prop.
        let id = id.to_owned();
        let keys = keys.map(str::to_owned);
        Self::on_main(move |core| {
            use gtk4::prelude::{Cast, WidgetExt};
            use crate::harness::TargetKind as K;
            fn table_tag(core: &CoreState, widget: WidgetId) -> Option<Vec<u8>> {
                core.widgets.contains_key(&widget).then(|| ())?;
                core.tables
                    .get(&widget.0)
                    .map(|table| table.tag.borrow().clone())
            }
            fn find(names: Vec<gtk4::Widget>, id: &str) -> Option<isize> {
                names
                    .iter()
                    .position(|w| w.widget_name() == id)
                    .map(|i| i as isize)
            }
            if let Some(keys) = keys.as_deref() {
                if kind == K::Column {
                    let node = core
                        .columns
                        .iter()
                        .zip(&core.column_ids)
                        .filter(|(column, _)| column.widget_name() == id)
                        .find_map(|(_, widget)| table_tag(core, *widget))
                        .and_then(|tag| crate::harness::table_tag_node(&tag))?;
                    return core
                        .columns
                        .iter()
                        .zip(&core.column_ids)
                        .position(|(_, widget)| {
                            table_tag(core, *widget).is_some_and(|tag| {
                                crate::harness::table_tag_matches_keys(&tag, node, keys)
                            })
                        })
                        .map(|i| i as isize);
                }
                // EVERY OTHER TAGGED KIND resolves through its occurrence
                // tag, the same node-and-keys encoding the table's sort
                // tag carries: the template node is read off any copy
                // carrying the authored id, then the copy whose key path
                // matches is the target (a stamped button by key —
                // docs/deferred.md's keyed-target entry, 2026-09-01).
                let candidates = kind_registry(core, kind);
                let tag_of = |w: &gtk4::Widget| -> Option<Vec<u8>> {
                    core.widgets
                        .iter()
                        .find(|(_, native)| native.widget() == *w)
                        .and_then(|(wid, _)| core.widget_tags.get(&wid.0).cloned())
                };
                let Some(node) = candidates
                    .iter()
                    .filter(|w| w.widget_name() == id)
                    .find_map(|w| tag_of(w))
                    .and_then(|tag| crate::harness::table_tag_node(&tag))
                else {
                    // The miss says what the registry held: one sentence
                    // for every cause is what cost a stale-interpreter run
                    // on the mac (docs/traps.md, 2026-09-01).
                    let with_id = candidates.iter().filter(|w| w.widget_name() == id).count();
                    let tagged = candidates.iter().filter(|w| tag_of(w).is_some()).count();
                    eprintln!(
                        "KAYA_DIAG keyed target {kind:?}@{id}[{keys}] unresolved: {} live, {with_id} carrying the id, {tagged} tagged",
                        candidates.len()
                    );
                    return None;
                };
                return candidates
                    .iter()
                    .position(|w| {
                        tag_of(w).is_some_and(|tag| {
                            crate::harness::table_tag_matches_keys(&tag, node, keys)
                        })
                    })
                    .map(|i| i as isize);
            }
            // A DESTROYED WIDGET MAY NOT ANSWER A TARGET. These registries
            // are push-only, so a stamped copy that left the band is still
            // in `columns` carrying its authored key — and a windowed row's
            // copy dies on every scroll (docs/virtualization-plan.md §1).
            // The keyed arm above already filters this way; `column_ids` is
            // the only id vector the harness keeps, so this is the Column
            // arm's clause.
            if kind == K::Column {
                return core
                    .columns
                    .iter()
                    .zip(&core.column_ids)
                    .position(|(w, wid)| {
                        w.widget_name() == id && core.widgets.contains_key(wid)
                    })
                    .map(|i| i as isize);
            }
            find(kind_registry(core, kind), &id)
        })
    }

    fn child_texts(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::{Cast, WidgetExt};
            let registry = if matches!(t.kind, crate::harness::TargetKind::Column) {
                &core.columns
            } else {
                &core.rows
            };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return "<no such target>".to_string();
            };
            // Child order as the toolkit holds it — the registries are
            // creation-ordered and cannot observe a move.
            let mut texts = Vec::new();
            let mut child = registry[i].first_child();
            while let Some(widget) = child {
                if let Some(label) = widget.downcast_ref::<gtk4::Label>() {
                    if core.labels.iter().any(|l| l == label) {
                        texts.push(label.text().to_string());
                    }
                }
                child = widget.next_sibling();
            }
            texts.join("|")
        })
    }

    fn child_shares(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::WidgetExt;
            // Kind picks the registry and the axis: a column's
            // children split its height, a row's its width (the runner
            // rejects any other kind before it gets here).
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return "<no such target>".to_string();
            };
            let container = &registry[i];
            // Pending resizes must land before the sizes mean anything;
            // otherwise the first read after mount sees zeros.
            while glib::MainContext::default().iteration(false) {}
            let mut extents = Vec::new();
            let mut child = container.first_child();
            while let Some(widget) = child {
                extents.push(flex::child_extent(&widget, vertical));
                child = widget.next_sibling();
            }
            crate::harness::shares(&extents)
        })
    }

    fn container_fills(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::{Cast, WidgetExt};
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return "<no such target>".to_string();
            };
            let container = &registry[i];
            while glib::MainContext::default().iteration(false) {}
            // A GROWN CONTAINER IS A FLEX CHILD TOO: its own box spans the
            // track its weight earned before its children can span anything
            // (the ruling of 2026-08-22; docs/deferred.md's nested-container
            // GAP, tools/scenes/align.steps). widget_fills' reading, one level
            // up — one-sided, and skipped when the flex manager recorded no
            // track (a root, or a child of a plain GtkBox).
            let widget = container.clone().upcast::<gtk4::Widget>();
            let own = widget
                .parent()
                .and_then(|p| p.layout_manager())
                .and_then(|m| m.downcast::<flex::FlexLayout>().ok())
                .and_then(|manager| {
                    let main_vertical = manager.orientation() == gtk4::Orientation::Vertical;
                    child_track(&widget).map(|track| (track, main_vertical))
                });
            if let Some((track, main_vertical)) = own {
                let drawn = flex::child_extent(&widget, main_vertical);
                if drawn < track - 2.0 {
                    return format!(
                        "draws {}px of its own {}px track",
                        drawn.round(),
                        track.round()
                    );
                }
            }
            // width()/height() are ALREADY the content box on GTK4 — CSS
            // padding lives outside the widget's own coordinate space, unlike
            // every other backend here. Subtracting the .kaya-root padding on
            // top of that read a filling root as 259px spanning 227px on the
            // first Wayland run.
            let inner = if vertical {
                container.height()
            } else {
                container.width()
            };
            // A verdict is never built from geometry nobody laid out: an
            // unallocated container reads 0 against 0-extent children and the
            // slack test passes on zeros (the ruling's clause 4b in this
            // backend's spelling — GTK has real allocations to sum, so there
            // are no unrecorded child tracks to mistake for a leftover).
            if inner <= 0 {
                return "no container layout recorded".to_owned();
            }
            // THE BREADTH CLAUSE (the ruling's second slice, 2026-08-22): a
            // CROSSING container spans its parent's inner breadth under EVERY
            // align mode, read off its ALLOCATION rather than width()/height().
            // The parent's axis comes from its LAYOUT MANAGER — never
            // GtkBox::orientation, whose owner ensure_flex replaces, and never
            // the AXIS_KEY the lowering stamps, which would copy the model.
            if let Some(parent) = widget.parent() {
                let parent_vertical = parent.layout_manager().and_then(|m| {
                    m.downcast_ref::<flex::FlexLayout>()
                        .map(|f| f.orientation() == gtk4::Orientation::Vertical)
                        .or_else(|| {
                            m.downcast_ref::<gtk4::BoxLayout>()
                                .map(|b| b.orientation() == gtk4::Orientation::Vertical)
                        })
                });
                if parent_vertical == Some(!vertical) {
                    let breadth = flex::child_extent(&widget, vertical).round() as i32;
                    let across = if vertical { parent.height() } else { parent.width() };
                    if across > 0 && breadth < across - 2 {
                        return format!("spans {breadth}px of its parent's {across}px breadth");
                    }
                }
            }
            // THE CHILDREN, in SwiftUI's shape (its expect_fills container
            // arm): extents SUMMED plus the DECLARED gaps, against the content
            // box. min_start..max_end could not serve — that span IS
            // sum(extents) + the gap the layout ACTUALLY used, so the declared
            // value cancels out and no spacing prop can make it fail
            // (docs/deferred.md's always-8 GAP; grow.steps calls its 12-unit
            // gap the spacing prop's conformance exercise).
            let mut span = 0;
            let mut count = 0;
            let mut child = container.first_child();
            while let Some(w) = child {
                child = w.next_sibling();
                // Invisible children are the ones flex::allocate skips; their
                // stale 0x0 allocation is not a measurement of this layout,
                // and no gap is laid out beside them either.
                if !w.is_visible() {
                    continue;
                }
                // The ALLOCATION, not TRACK_KEY: only a flex container stamps
                // a track, and on the main axis the two agree anyway — the
                // manager hands a grower its whole track and a non-grower
                // exactly its natural, leaving GTK's align adjustment nothing
                // to take away.
                span += flex::child_extent(&w, vertical).round() as i32;
                count += 1;
            }
            if count == 0 {
                return "no children".to_owned();
            }
            span += container_spacing(&widget) * (count - 1);
            if table_header(container).is_some() {
                return if table_content_fits(f64::from(span), f64::from(inner)) {
                    String::new()
                } else {
                    format!("children span {span}px inside a {inner}px viewport")
                };
            }
            if (span - inner).abs() <= 2 {
                String::new()
            } else {
                format!("children span {span}px of {inner}px")
            }
        })
    }

    fn widget_fills(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::{Cast, WidgetExt};
            // The LAYOUT widget, not the control: a textarea's flex child is
            // its GtkScrolledWindow, and target_widget hands out the
            // GtkTextView inside it. Asking the view about its track would
            // find none — it is not the box the flex manager placed.
            let Some(control) = target_widget(core, t) else {
                return "<no such target>".to_string();
            };
            let widget = core
                .widgets
                .values()
                .find(|w| w.control() == control)
                .map_or(control, |w| w.widget());
            while glib::MainContext::default().iteration(false) {}
            // The container's own manager decides the axis — the same
            // authority reindex uses, never the widget's shape.
            let Some(parent) = widget.parent() else {
                return "no parent — not a flex child".to_string();
            };
            let Some(flex) = parent
                .layout_manager()
                .and_then(|m| m.downcast::<flex::FlexLayout>().ok())
            else {
                return "parent is not a flex container".to_string();
            };
            let vertical = flex.orientation() == gtk4::Orientation::Vertical;
            let Some(track) = child_track(&widget) else {
                return "no track recorded — not a flex child".to_string();
            };
            // The allocation is what the widget DREW at: GTK adjusts it for
            // the child's align and margins on the way in, while the track
            // above stays what the layout handed out.
            let drawn = flex::child_extent(&widget, vertical);
            if drawn >= track - 2.0 {
                String::new()
            } else {
                format!("draws {}px of a {}px track", drawn.round(), track.round())
            }
        })
    }

    fn widget_spans_breadth(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::{Cast, WidgetExt};
            // The LAYOUT widget, as widget_fills reads it.
            let Some(control) = target_widget(core, t) else {
                return "<no such target>".to_string();
            };
            let widget = core
                .widgets
                .values()
                .find(|w| w.control() == control)
                .map_or(control, |w| w.widget());
            while glib::MainContext::default().iteration(false) {}
            let Some(parent) = widget.parent() else {
                return "no parent — not a flex child".to_string();
            };
            // The parent's axis from its LAYOUT MANAGER, container_fills'
            // breadth clause's rule — never the AXIS_KEY the lowering
            // stamps, which would copy the model this is here to check.
            let Some(parent_vertical) = parent.layout_manager().and_then(|m| {
                m.downcast_ref::<flex::FlexLayout>()
                    .map(|f| f.orientation() == gtk4::Orientation::Vertical)
                    .or_else(|| {
                        m.downcast_ref::<gtk4::BoxLayout>()
                            .map(|b| b.orientation() == gtk4::Orientation::Vertical)
                    })
            }) else {
                return "parent is not a flex container".to_string();
            };
            // The ALLOCATION is the breadth (the CSS box would be the
            // content box); the parent's width()/height() IS its content
            // box on GTK4.
            let breadth = flex::child_extent(&widget, !parent_vertical).round() as i32;
            let across = if parent_vertical { parent.width() } else { parent.height() };
            if across <= 0 {
                return "no container layout recorded".to_owned();
            }
            if breadth >= across - 2 {
                String::new()
            } else {
                format!("spans {breadth}px of its parent's {across}px breadth")
            }
        })
    }

    fn container_axis(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::OrientableExt;
            use gtk4::prelude::WidgetExt;
            // Addressed by CREATION KIND (docs/adaptive-layout-plan.md D1);
            // the answer is the toolkit's own orientation read back, never
            // the model — a backend that ignored the write must fail.
            let from_columns = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if from_columns { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return "<no such target>".to_string();
            };
            let container = &registry[i];
            // NO PUMP HERE (the 1630 rule): the deferred axis idle runs
            // between the harness's polls on the loop's own turns, and a
            // pump under this borrow dispatches relayout handlers that
            // hard-borrow CORE — measured as the x11 leg's abort.
            if container.width() <= 0 && container.height() <= 0 {
                return "no container layout recorded".to_owned();
            }
            match container.orientation() {
                gtk4::Orientation::Vertical => "vertical".to_owned(),
                _ => "horizontal".to_owned(),
            }
        })
    }

    fn fold_state(&self, child: crate::harness::Target, table: Option<crate::harness::Target>) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::WidgetExt;
            // Measured off the TREE, both halves (D7): the class the fold
            // stamps, and the ancestry that says which viewport the child
            // actually renders in — never the core's model, which would
            // echo the Fold op back.
            let Some(child_widget) = target_widget(core, child) else {
                return "<no such child target>".to_owned();
            };
            let stamped = child_widget.has_css_class(KAYA_FOLDED_CLASS);
            let Some(want) = table else {
                return if stamped { "folded" } else { "not folded" }.to_owned();
            };
            if !matches!(want.kind, crate::harness::TargetKind::Column) {
                return "<the fold target is not a column>".to_owned();
            }
            let Some(i) = crate::harness::try_resolve(want.index, core.columns.len()) else {
                return "<no such table target>".to_owned();
            };
            let Some(gtk_table) = core.tables.get(&core.column_ids[i].0) else {
                return "that column declared no columns, so it has no viewport".to_owned();
            };
            let content = gtk_table.content.clone().upcast::<gtk4::Widget>();
            let mut at = child_widget.parent();
            let mut inside = false;
            while let Some(w) = at {
                if w == content {
                    inside = true;
                    break;
                }
                at = w.parent();
            }
            match (stamped, inside) {
                (true, true) => "folded".to_owned(),
                (false, _) => "not folded".to_owned(),
                (true, false) => "stamped folded, but rendered outside that table's viewport".to_owned(),
            }
        })
    }

    fn cross_mode(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::WidgetExt;
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return "<no such target>".to_string();
            };
            let container = &registry[i];
            while glib::MainContext::default().iteration(false) {}
            // Cross axis: horizontal for a column, vertical for a row.
            // width()/height() are the content box and child allocations are
            // content-relative, so the cross box is 0..inner.
            let inner = if vertical { container.width() } else { container.height() };
            // Zeros classify as stretch (every child spans a 0px box), so an
            // unallocated container must be said, never classified.
            if inner <= 0 {
                return "no container layout recorded".to_owned();
            }
            let mut rects: Vec<(i32, i32)> = Vec::new();
            let mut baselines: Vec<i32> = Vec::new();
            let mut child = container.first_child();
            while let Some(widget) = child {
                child = widget.next_sibling();
                // As in container_fills: the layout skips invisible children,
                // so their stale 0x0 allocation is not geometry to classify.
                if !widget.is_visible() {
                    continue;
                }
                let alloc = widget.allocation();
                let (start, extent) = if vertical {
                    (alloc.x(), alloc.width())
                } else {
                    (alloc.y(), alloc.height())
                };
                rects.push((start, extent));
                if !vertical {
                    let b = widget.allocated_baseline();
                    if b >= 0 {
                        baselines.push(alloc.y() + b);
                    }
                }
            }
            if rects.is_empty() {
                return "no children".to_owned();
            }
            let all = |f: &dyn Fn(&(i32, i32)) -> bool| rects.iter().all(f);
            // Baseline first: GTK 4.12 spells it BASELINE_FILL, so the boxes
            // fill the row too, but a child is handed an allocated baseline
            // ONLY under baseline alignment (plain fill reads -1). PARTICIPATION
            // is the whole check — the values are not comparable across kinds
            // (37 vs 27 for a visually ALIGNED label and button).
            if !vertical && baselines.len() >= 2 {
                return "baseline".to_owned();
            }
            // THEN STRETCH, before the positional modes and alone: spanning
            // geometry is DEGENERATE, since a child at (0, inner) satisfies
            // start, center and end too (the ruling of 2026-08-22;
            // tools/scenes/align.steps carries the separability burden).
            // BASELINE STILL OUTRANKS IT HERE, unlike the other backends,
            // because BASELINE_FILL spans the row as well.
            if all(&|r| r.0.abs() <= 2 && (r.1 - inner).abs() <= 2) {
                return "stretch".to_owned();
            }
            // A container with at least one non-spanning child is what the
            // positional modes classify; more than one match means the
            // scene's geometry cannot distinguish them, and a first-match
            // answer would let such a scene pass while proving nothing.
            let mut matches = Vec::new();
            if all(&|r| r.0.abs() <= 2) {
                matches.push("start");
            }
            if all(&|r| ((2 * r.0 + r.1) - inner).abs() <= 4) {
                matches.push("center");
            }
            if all(&|r| ((r.0 + r.1) - inner).abs() <= 2) {
                matches.push("end");
            }
            match matches.as_slice() {
                [one] => (*one).to_owned(),
                // A baseline-looking row reading mixed is usually the
                // observation, not the geometry — name the allocated
                // count in the verdict (participation is GTK's
                // baseline signal).
                [] => {
                    let allocated = if vertical {
                        String::new()
                    } else {
                        format!("; {} baselines allocated", baselines.len())
                    };
                    format!("mixed (cross rects {rects:?} in {inner}px{allocated})")
                }
                many => format!("ambiguous ({})", many.join("|")),
            }
        })
    }

    fn window_title(&self, window: u64) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::GtkWindowExt;
            match gtk_window_read(core, window) {
                Some(target) => target.title().map(String::from).unwrap_or_default(),
                // A DESCRIPTION, in the brackets no title wears, so the
                // poll re-asks and the deadline's failure text names the
                // cause instead of reporting an empty title.
                None => not_materialized(core, window),
            }
        })
    }

    fn window_content_size(&self, window: u64) -> (f64, f64) {
        Self::on_main(move |core| {
            use gtk4::prelude::GtkWindowExt;
            // On a mapped toplevel default_size tracks the current content
            // size (X11; a Wayland compositor keeps its own last word).
            // NOT-A-NUMBER FOR A WINDOW THIS PROCESS DOES NOT HOLD, the WinUI
            // backend's spelling: every comparison against NaN is false, so
            // the harness keeps polling.
            match gtk_window_read(core, window) {
                Some(target) => {
                    let (w, h) = target.default_size();
                    (f64::from(w), f64::from(h))
                }
                None => (f64::NAN, f64::NAN),
            }
        })
    }

    fn window_dirty(&self, window: u64) -> bool {
        // THE CHROME, OVER THE BUS — the read D5's table names for this
        // backend, since kaya's own model would only agree with itself. The
        // window is identified by its frame's NAME (the title GTK publishes,
        // which `dirty` never touches); two windows wearing one title is
        // ambiguous. UNREADABLE IS ITS OWN FAILURE, NEVER `false`: a leg wired
        // without tools/linux/a11y-leg.sh publishes no tree at all.
        use std::time::{Duration, Instant};
        let title = self.window_title(window);
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            match atspi_window_marker(&title, DIRTY_MARKER_NAME) {
                Ok(marked) => return marked,
                Err(why) => {
                    if why.retryable && Instant::now() < deadline {
                        std::thread::sleep(Duration::from_millis(100));
                        continue;
                    }
                    panic!(
                        "kaya: the dirty read cannot answer for window#{window} \
                         (title {title:?}): {}. The marker is a header-bar label \
                         the AT-SPI walk matches by its accessible name, so a leg \
                         asserting expect_dirty must run under \
                         tools/linux/a11y-leg.sh — GTK publishes no accessibility \
                         tree without GTK_A11Y=atspi and a bus to sit on.",
                        why.why
                    );
                }
            }
        }
    }

    fn close_window(&self, window: u64) {
        // An ACTION, so a miss is a bug — reported from the harness
        // thread, where the panic can unwind and the runner records the
        // sentence (see resize_window).
        let missing = Self::on_main(move |core| {
            use gtk4::prelude::GtkWindowExt;
            // The REAL chrome path: close() runs close_request, so
            // the veto grammar fires exactly as a user click would.
            match gtk_window_read(core, window) {
                Some(target) => {
                    target.close();
                    None
                }
                None => Some(live_windows(core)),
            }
        });
        if let Some(live) = missing {
            panic!(
                "kaya: close_window targeted window#{window}, which this \
                 process does not hold (live windows: {live})"
            );
        }
    }

    fn window_count(&self) -> usize {
        Self::on_main(move |core| 1 + core.aux_windows.len())
    }

    fn alert_title(&self, window: u64) -> Option<String> {
        Self::on_main(move |core| {
            let live = core.live_alert.borrow();
            live.as_ref()
                .filter(|a| a.window == window)
                // The REAL dialog object's message, never the
                // request's copy.
                .map(|a| a.dialog.message().to_string())
        })
    }

    fn choose_alert(&self, choice: u32) {
        // `Some(sentence)` is "the live alert names a window this process does
        // not hold", reported from the harness thread (see resize_window).
        // Without it the miss would be reported as a different bug.
        let missing = Self::on_main(move |core| {
            use gtk4::prelude::{Cast, GtkWindowExt, WidgetExt};
            let live = core.live_alert.borrow();
            let Some(alert) = live.as_ref() else {
                return None;
            };
            let label = if choice == crate::wire::ALERT_CHOICE_CANCEL {
                alert.labels.last().cloned()
            } else {
                alert
                    .labels
                    .get(choice as usize)
                    .filter(|_| (choice as usize) < alert.actions)
                    .cloned()
            };
            let Some(label) = label else {
                return None;
            };
            // The REAL button inside the presented dialog window: find the
            // alert's own toplevel (transient-for our window, not one of ours)
            // and activate its button — a user's click's signal path.
            let Some(parent) = gtk_window_read(core, alert.window) else {
                return Some((alert.window, live_windows(core)));
            };
            for toplevel in gtk4::Window::list_toplevels() {
                let Ok(window) = toplevel.downcast::<gtk4::Window>() else {
                    continue;
                };
                if window.transient_for().as_ref() != Some(&parent) {
                    continue;
                }
                if let Some(button) = find_button(window.upcast_ref(), &label) {
                    use gtk4::prelude::WidgetExt as _;
                    let _ = button.activate();
                    return None;
                }
            }
            None
        });
        if let Some((window, live)) = missing {
            panic!(
                "kaya: the live alert is over window#{window}, which this \
                 process does not hold (live windows: {live})"
            );
        }
        // AND WAIT FOR IT TO ACTUALLY GO, which is what makes this verb mean
        // the same thing here as everywhere else: activating the button only
        // ASKS, and `AlertDialog::choose`'s async callback is what runs
        // capi::alert_retire. Until it lands the core still holds the one live
        // slot, so the next show_alert is refused (measured 2026-08-10, both
        // protocols). A stuck alert dies LOUDLY rather than giving up.
        let deadline = std::time::Instant::now() + crate::harness::POLL_DEADLINE;
        loop {
            if Self::on_main(move |core| core.live_alert.borrow().is_none()) {
                return;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "kaya: the alert was answered but never resolved — its \
                 AlertDialog::choose callback has not run, so the core still \
                 holds it in the one live slot and the next alert this app \
                 shows will abort the process"
            );
            std::thread::sleep(crate::harness::POLL_INTERVAL);
        }
    }

    fn entry_count(&self, window: u64) -> usize {
        Self::on_main(move |core| {
            core.nav_stacks.get(&window).map_or(0, Vec::len)
        })
    }

    fn back(&self, window: u64) {
        Self::on_main(move |core| {
            // The REAL affordance: activate the header bar's back button, whose
            // click handler runs the same user-pop path a pointer press does.
            // Deferred one idle tick, since the handler re-borrows CORE. ONE
            // PATH, list-detail included — libadwaita draws no back button for
            // those pages, so the split arm shows kaya's when collapsed. A
            // HIDDEN button is not an affordance.
            if let Some(back) = core.back_buttons.get(&window).cloned() {
                if !gtk4::prelude::WidgetExt::get_visible(&back) {
                    return;
                }
                glib::idle_add_local_once(move || {
                    use gtk4::prelude::ButtonExt;
                    back.emit_clicked();
                });
            }
        })
    }

    fn scroll_overflow(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(adj) = scroll_axis(core, t) else {
                return "<no such target>".to_string();
            };
            // The toolkit's own adjustment: upper is the content
            // extent, page_size the viewport.
            if adj.upper() > adj.page_size() + 2.0 {
                String::new()
            } else {
                format!("content {} in viewport {}", adj.upper(), adj.page_size())
            }
        })
    }

    fn scroll_end(&self, t: crate::harness::Target) {
        Self::on_main(move |core| {
            // The REAL scrolling API: setting the adjustment's value
            // IS how GTK scrolls (scrollbars and kinetic panning both
            // write it).
            let adj = scroll_axis(core, t)
                .unwrap_or_else(|| panic!("kaya: scroll_end on {t:?}, which scrolls nowhere"));
            adj.set_value(adj.upper() - adj.page_size());
        })
    }

    fn progress_state(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.progresses.len()) else {
                return "<no such target>".to_string();
            };
            let bar = &core.progresses[i];
            // The REAL control's state: membership in the pulse set is
            // the indeterminate flag; the fraction is the bar's own.
            let armed = core
                .progresses
                .get(i)
                .map(|b| {
                    // The pulse set is keyed by widget id, so read it via
                    // the bar's kaya id stored at creation.
                    b.clone()
                })
                .is_some()
                && core
                    .indeterminate
                    .borrow()
                    .iter()
                    .any(|key| core.widgets.get(&WidgetId(*key)).is_some_and(|w| {
                        matches!(w, NativeWidget::Progress(p) if p == bar)
                    }));
            if armed {
                "indeterminate".to_string()
            } else {
                format!("{}%", (bar.fraction() * 100.0).round() as i64)
            }
        })
    }

    fn grid_columns(&self, t: crate::harness::Target, want: usize) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.grids.len()) else {
                return "<no such target>".to_string();
            };
            let grid = &core.grids[i];
            // Geometry, never the model's columns copy: cluster the
            // cells' leading edges (allocations are parent-relative
            // in GTK4); the distinct clusters ARE the columns.
            let mut edges: Vec<i32> = Vec::new();
            let mut child = grid.first_child();
            while let Some(c) = child {
                edges.push(c.allocation().x());
                child = c.next_sibling();
            }
            if edges.is_empty() {
                return "no cells".to_string();
            }
            edges.sort_unstable();
            let mut clusters = 0;
            let mut last = i32::MIN;
            for x in edges {
                if clusters == 0 || x - last > 2 {
                    clusters += 1;
                    last = x;
                }
            }
            if clusters == want {
                String::new()
            } else {
                format!("{clusters} column edges, wanted {want}")
            }
        })
    }

    fn choose(&self, t: crate::harness::Target, index: usize) {
        Self::on_main(move |core| {
            // The REAL selection route per kind, quiet guard off so
            // the native signal emits exactly as a user pick does.
            if t.kind == crate::harness::TargetKind::Radio {
                let i = crate::harness::resolve(t.index, core.radios.len());
                let group = &core.radios[i];
                for (id, buttons) in &core.radio_buttons {
                    if matches!(core.widgets.get(&WidgetId(*id)),
                                Some(NativeWidget::Radio(b)) if b == group)
                    {
                        if let Some(check) = buttons.get(index) {
                            check.set_active(true);
                        }
                        return;
                    }
                }
                return;
            }
            let i = crate::harness::resolve(t.index, core.selects.len());
            core.selects[i].set_selected(index as u32);
        });
    }

    fn selected_label(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            if t.kind == crate::harness::TargetKind::Radio {
                // The REAL control's state: the ACTIVE grouped
                // CheckButton's own label.
                let Some(i) = crate::harness::try_resolve(t.index, core.radios.len()) else {
                    return "<no such target>".to_string();
                };
                let group = &core.radios[i];
                for (id, buttons) in &core.radio_buttons {
                    if matches!(core.widgets.get(&WidgetId(*id)),
                                Some(NativeWidget::Radio(b)) if b == group)
                    {
                        return buttons
                            .iter()
                            .find(|c| c.is_active())
                            .and_then(|c| c.label())
                            .map(|l| l.to_string())
                            .unwrap_or_default();
                    }
                }
                return String::new();
            }
            let Some(i) = crate::harness::try_resolve(t.index, core.selects.len()) else {
                return "<no such target>".to_string();
            };
            // The REAL control's state: the selected item out of the
            // DropDown's own model — what the collapsed button shows.
            core.selects[i]
                .selected_item()
                .and_then(|item| item.downcast::<gtk4::StringObject>().ok())
                .map(|s| s.string().to_string())
                .unwrap_or_default()
        })
    }

    fn scroll_at_end(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(adj) = scroll_axis(core, t) else {
                return "<no such target>".to_string();
            };
            let short = adj.upper() - (adj.value() + adj.page_size());
            if short.abs() <= 2.0 {
                String::new()
            } else {
                format!(
                    "content bottom {} vs viewport {}",
                    adj.value() + adj.page_size(),
                    adj.upper()
                )
            }
        })
    }

    fn file_dialog_state(&self) -> Option<(String, Vec<String>)> {
        // The REAL chooser, read over the bus as an assistive client would —
        // never this backend's own record of what it asked for. NOT on the GTK
        // main thread: this is a dbus round trip and the main loop has to keep
        // answering it. A SAVE PANEL IS NOT A PICKER HERE: `open()` and
        // `save()` are two calls on ONE `gtk::FileDialog`, so the tree is what
        // tells them apart.
        let read = file_dialog_atspi(DialogOp::Read)?;
        match read.save_name {
            Some(_) => None,
            None => Some((read.dir, read.rows)),
        }
    }

    fn choose_file(&self, name: Option<&str>) {
        match name {
            // SELECT, THEN PRESS, in two passes: the tree happens to put the
            // list before the buttons, so one in-order pass would break the
            // first time GTK reorders it. Selection is not decoration — with
            // one row the chooser completes without it, which is why the scene
            // keeps a decoy that sorts first.
            Some(file) => {
                file_dialog_atspi(DialogOp::Select(file));
                file_dialog_atspi(DialogOp::Press("Open"));
            }
            // Cancel is the empty list, faithfully — the guest's own
            // reaction is the observable, so nothing is asserted here.
            None => {
                file_dialog_atspi(DialogOp::Press("Cancel"));
            }
        }
    }

    fn save_dialog_state(&self) -> Option<(String, String)> {
        // The REAL save panel, over the same bus and walk as the picker — the
        // two are one `gtk::FileDialog` here, so the reader tells them apart
        // by what the tree carries (DialogRead). NO ROWS ARE REQUIRED, which
        // the trait doc demands of every backend and which GTK gets for free.
        let read = file_dialog_atspi(DialogOp::Read)?;
        Some((read.dir, read.save_name?))
    }

    fn set_save_name(&self, name: &str) {
        // set_text's tier: the field's whole contents replaced, the way a
        // user renaming a suggested name leaves it. Whether it took is NOT
        // assumed — expect_save_dialog reads the field back off the bus.
        file_dialog_atspi(DialogOp::SetName(name));
    }

    fn confirm_save(&self, save: bool) {
        // The panel's OWN buttons, so its own completion runs. The accept
        // button says "Save" here and "Open" on the picker — the one label
        // that differs between two dialogs that are otherwise one object.
        file_dialog_atspi(DialogOp::Press(if save { "Save" } else { "Cancel" }));
    }

    /// The foreign writer: wl-copy (wayland) or xclip (x11), a child process
    /// with its own connection. AND IT WAITS UNTIL THE CONTENT IS REALLY
    /// THERE (§3): wl-copy forks a server and its exit does not mean the
    /// offer landed, so the seed polls the foreign TARGETS until the seeded
    /// type is listed.
    fn clipboard_seed(&self, kind: &str, argument: &str) {
        let expected: &str = match kind {
            "text" => {
                // No explicit type: the platform tool declares its own
                // standard text target set, exactly as a real app's
                // copy would.
                foreign_clip_write(None, argument.as_bytes().to_vec());
                if linux_wayland_session() {
                    "text/plain"
                } else {
                    "UTF8_STRING"
                }
            }
            "html" => {
                foreign_clip_write(Some("text/html"), argument.as_bytes().to_vec());
                "text/html"
            }
            "image" => {
                let bytes = std::fs::read(argument).unwrap_or_else(|e| {
                    panic!("kaya: clipboard_seed image cannot read {argument:?}: {e}")
                });
                foreign_clip_write(Some("image/png"), bytes);
                "image/png"
            }
            "files" => {
                let uri = glib::filename_to_uri(argument, None).unwrap_or_else(|e| {
                    panic!("kaya: clipboard_seed files: {argument:?} is not a path: {e}")
                });
                foreign_clip_write(Some("text/uri-list"), format!("{uri}\r\n").into_bytes());
                "text/uri-list"
            }
            custom => panic!(
                "kaya: clipboard_seed cannot write {custom:?} from outside the app — \
                 no stock tool writes an app-defined format, and a helper kaya wrote \
                 would be foreign in name only"
            ),
        };
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if foreign_clip_targets().contains(expected) {
                return;
            }
            if std::time::Instant::now() > deadline {
                panic!("kaya: clipboard_seed {kind} never appeared on the clipboard");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    /// The foreign reader: wl-paste or xclip -o, one representation. Text,
    /// html and custom answer the content; files answers the FIRST file's
    /// basename; an image answers its DECODED SIZE via imagemagick's
    /// identify — a foreign decoder, because hosts re-encode freely and a
    /// byte count is a different number on every lane (§2).
    fn clipboard_read(&self, kind: &str) -> String {
        match kind {
            // On x11 the text target every owner serves is
            // UTF8_STRING (the convention); on wayland it is the
            // plain mime (measured in the GDK probe's target list).
            "text" => {
                let target = if linux_wayland_session() {
                    "text/plain"
                } else {
                    "UTF8_STRING"
                };
                String::from_utf8_lossy(&foreign_clip_read(target)).into_owned()
            }
            "html" => String::from_utf8_lossy(&foreign_clip_read("text/html")).into_owned(),
            "files" => {
                let raw = foreign_clip_read("text/uri-list");
                let text = String::from_utf8_lossy(&raw);
                let Some(line) = text
                    .lines()
                    .map(|l| l.trim_end_matches('\r'))
                    .find(|l| !l.is_empty() && !l.starts_with('#'))
                else {
                    return String::new();
                };
                match glib::filename_from_uri(line) {
                    Ok((path, _)) => path
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                    Err(_) => String::new(),
                }
            }
            "image" => {
                let bytes = foreign_clip_read("image/png");
                if bytes.is_empty() {
                    return String::new();
                }
                let scratch = std::env::temp_dir()
                    .join(format!("kaya-clipread-{}.png", std::process::id()));
                if std::fs::write(&scratch, &bytes).is_err() {
                    return String::new();
                }
                let out = std::process::Command::new("identify")
                    .args(["-format", "%wx%h"])
                    .arg(&scratch)
                    .output();
                let _ = std::fs::remove_file(&scratch);
                match out {
                    Ok(o) if o.status.success() => {
                        String::from_utf8_lossy(&o.stdout).trim().to_owned()
                    }
                    // BYTES-PRESENT-BUT-UNDECODABLE IS NOT "NOTHING": a
                    // broken embedded asset once hid behind "" here for a
                    // full lane run, because every other platform's decoder
                    // was lenient about a bad IDAT CRC and this lane's
                    // identify is the matrix's first strict one.
                    Ok(o) => format!(
                        "<{} bytes of image/png that identify rejects: {}>",
                        bytes.len(),
                        String::from_utf8_lossy(&o.stderr).trim()
                    ),
                    Err(e) => format!("<identify failed to run: {e}>"),
                }
            }
            custom => String::from_utf8_lossy(&foreign_clip_read(custom)).into_owned(),
        }
    }

    fn goto_directory(&self, path: &str) {
        // ARMED, NOT SET. A chooser reads its initial folder when it is
        // PRESENTED; pointing one already on screen is silently ignored, so
        // this stores it and the apply arm applies it.
        let path = path.to_owned();
        Self::on_main(move |core| {
            *core.pending_dialog_dir.borrow_mut() = Some(path.clone());
        });
    }

    fn alert_count(&self) -> usize {
        Self::on_main(move |core| usize::from(core.live_alert.borrow().is_some()))
    }

    fn root_fills(&self) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::WidgetExt;
            // The SHELL's content and not the window's child, which since the
            // AdwToolbarView flip is the shell itself — and the shell fills
            // the window by construction.
            let Some(root) = window_content(core, 0) else {
                return "nothing mounted".to_owned();
            };
            while glib::MainContext::default().iteration(false) {}
            let alloc = root.allocation();
            // The child's slot excludes whatever the window draws for itself,
            // and how much depends on the compositor: Wayland CSD puts a ~39px
            // headerbar above the child, bare Xvfb draws nothing (the first
            // cut compared against the whole window widget and read a
            // perfectly filling Wayland root as a hug). So "fills" is
            // edge-flush on left, right and bottom; only the top edge is
            // unknowable, since that is where the decoration lives.
            let (width, height) = (core.window.width(), core.window.height());
            // Within two pixels: rounding is not a hug.
            if alloc.x() <= 2
                && (alloc.x() + alloc.width() - width).abs() <= 2
                && (alloc.y() + alloc.height() - height).abs() <= 2
            {
                String::new()
            } else {
                format!(
                    "{}x{}px at ({},{}) inside {}x{}px",
                    alloc.width(),
                    alloc.height(),
                    alloc.x(),
                    alloc.y(),
                    width,
                    height,
                )
            }
        })
    }

    fn typeface(&self) -> String {
        Self::on_main(move |core| {
            while glib::MainContext::default().iteration(false) {}
            let seen = walk_typefaces(core);
            typeface_verdict(core, &seen)
        })
    }

    /// The app's mark, off the X SERVER's copy of the property this process
    /// set — never off GTK, which has no read-back for an icon list.
    /// `read_app_icon` carries the whole argument. TWO STEPS AND NOT ONE: the
    /// main context is released before `xprop` is spawned, because this verb
    /// is POLLED and holding it across a subprocess would stall the app being
    /// read.
    fn app_icon(&self) -> String {
        let probe = Self::on_main(identity_probe);
        read_app_icon(&probe)
    }

    /// The canonical raster, asked of the CORE (docs/canvas-plan.md §7.1)
    /// — every backend answers the same way, because the point is that
    /// five platforms' libkaya drew the same picture.
    fn canvas_probe(&self, target: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(target.index, core.canvas_ids.len()) else {
                return format!("<this window holds {} canvases>", core.canvas_ids.len());
            };
            core.scene
                .canvas_probe(core.canvas_ids[i])
                .unwrap_or_else(|| "<the core holds no drawing for this canvas>".to_owned())
        })
    }

    /// WHICH SIZE this canvas's raster is (docs/canvas-plan.md §3.2.1),
    /// asked of the CORE like `canvas_probe`: the two numbers being
    /// compared were made on opposite sides of the boundary — the TRACK is
    /// what `canvas_track_report` measured off this window's layout, the
    /// VIEWBOX is what the guest declared.
    fn canvas_raster_shape(&self, target: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(target.index, core.canvas_ids.len()) else {
                return format!("<this window holds {} canvases>", core.canvas_ids.len());
            };
            core.scene
                .canvas_raster_shape(core.canvas_ids[i])
                .unwrap_or_else(|| "<the core holds no drawing for this canvas>".to_owned())
        })
    }

    /// ADVANCE THE FRAME CLOCK by one frame at the CORE's own step
    /// (§15.4) — never this platform's, whose tick callback drives no
    /// frame while the harness is running.
    fn frame(&self) {
        Self::on_main_mut(|core| drive_frame(core, crate::capi::harness_frame_time()))
    }

    /// THE BLIT, sampled off the window's OWN RENDERED PIXELS through the
    /// toplevel's real GSK renderer (§7.2) — the mac's `cacheDisplay`
    /// move, in this platform's spelling, and the only canvas read that
    /// fails when the buffer never reached the GtkPicture.
    ///
    /// Every angle-bracketed answer says what it MEASURED (invariant 3),
    /// never a guess about which layer lost the picture.
    fn canvas_ink(&self, target: crate::harness::Target, points: &str) -> String {
        let points = points.to_owned();
        Self::on_main(move |core| {
            use gtk4::prelude::{NativeExt, PaintableExt, WidgetExt};
            // THE APPEARANCE RIDES THE ANSWER (§6): the display raster
            // uses the platform's mode and kaya's palette has two, so a
            // bare colour string would be a frozen expectation quietly
            // depending on the host's appearance setting. THE SAME
            // READING the presentation report sends, so the report and
            // the answer cannot disagree.
            let mode = if adw::StyleManager::default().is_dark() { "dark" } else { "light" };
            let wanted = crate::harness::probe_points(&points);
            if wanted.is_empty() {
                return format!("<no probe points in {points:?}>");
            }
            let Some(i) = crate::harness::try_resolve(target.index, core.canvases.len()) else {
                return format!("<this window holds {} canvases>", core.canvases.len());
            };
            let picture = core.canvases[i].clone();
            while glib::MainContext::default().iteration(false) {}
            let Some(native) = picture.native() else {
                return "<the canvas is in no toplevel: nothing has been mounted>".to_owned();
            };
            let root = native.clone().upcast::<gtk4::Widget>();
            let Some(bounds) = picture.compute_bounds(&root) else {
                return "<the canvas has no bounds inside its toplevel>".to_owned();
            };
            if bounds.width() < 1.0 || bounds.height() < 1.0 {
                return format!(
                    "<the canvas laid out at {}x{} inside its toplevel>",
                    bounds.width(),
                    bounds.height()
                );
            }
            let Some(renderer) = native.renderer() else {
                return "<this toplevel has no GSK renderer, so nothing is drawn yet>".to_owned();
            };
            let paintable = gtk4::WidgetPaintable::new(Some(&root));
            let snapshot = gtk4::Snapshot::new();
            let (rw, rh) = (f64::from(root.width()), f64::from(root.height()));
            paintable.snapshot(&snapshot, rw, rh);
            let Some(node) = snapshot.to_node() else {
                return format!("<the toplevel snapshotted to nothing at {rw}x{rh}>");
            };
            let shot = renderer.render_texture(&node, None);
            // THE RATIO IS MEASURED, NOT ASSUMED: the texture's pixel
            // size over the toplevel's logical size is whatever this
            // display's scale turned out to be, and reading it here means
            // the sampling cannot be wrong about a number nobody checked.
            let (tw, th) = (shot.width(), shot.height());
            if tw < 1 || th < 1 || rw < 1.0 || rh < 1.0 {
                return format!("<the toplevel rendered to {tw}x{th} pixels for {rw}x{rh}>");
            }
            let (sx, sy) = (f64::from(tw) / rw, f64::from(th) / rh);
            let stride = tw as usize * 4;
            let mut buf = vec![0u8; stride * th as usize];
            gtk4::gdk::prelude::TextureExtManual::download(&shot, &mut buf, stride);
            let samples = wanted
                .iter()
                .map(|(px, py)| {
                    let x = ((f64::from(bounds.x()) + f64::from(bounds.width()) * px / 100.0) * sx)
                        as i32;
                    let y = ((f64::from(bounds.y()) + f64::from(bounds.height()) * py / 100.0) * sy)
                        as i32;
                    let x = x.clamp(0, tw - 1) as usize;
                    let y = y.clamp(0, th - 1) as usize;
                    let at = y * stride + x * 4;
                    // gdk_texture_download hands back A8R8G8B8 in NATIVE
                    // byte order (the format cairo calls ARGB32), and it
                    // is PREMULTIPLIED — which is the same number the
                    // mac's sampler reports, since compositing a
                    // premultiplied pixel over black is the identity.
                    let px = u32::from_ne_bytes([buf[at], buf[at + 1], buf[at + 2], buf[at + 3]]);
                    format!("{:02X}{:02X}{:02X}", (px >> 16) & 0xff, (px >> 8) & 0xff, px & 0xff)
                })
                .collect::<Vec<_>>()
                .join("/");
            format!("{mode} {samples}")
        })
    }

    fn inset(&self) -> String {
        Self::on_main(move |core| {
            // The shell's content, the root_fills rule one read over.
            let Some(root) = window_content(core, 0) else {
                return "nothing mounted".to_owned();
            };
            while glib::MainContext::default().iteration(false) {}
            // The root's own CSS box, where `.kaya-root`'s padding is
            // (docs/styling-plan.md D3). AND ON GTK THAT BOX IS SHARED: kaya
            // mounts the root with no wrapper, so a root container's own inset
            // (prop 17) is counted here too. A scene that wants the two apart
            // asserts the container's on a non-root container.
            css_inset_of(&root)
        })
    }

    fn container_inset(&self, target: crate::harness::Target) -> String {
        use crate::harness::TargetKind as K;
        if !matches!(target.kind, K::Column | K::Row | K::Grid) {
            // The runner does not pre-check this step's kind the way it does
            // expect_shares, so the refusal lives here — and it names what
            // arrived, because a leaf's CSS box would answer with the theme's
            // padding and read like a measurement.
            return format!("{:?} is not a container target", target.kind);
        }
        Self::on_main(move |core| {
            let Some(widget) = target_widget(core, target) else {
                return "<no such target>".to_owned();
            };
            while glib::MainContext::default().iteration(false) {}
            css_inset_of(&widget)
        })
    }

    fn sections_presentation(&self, window: u64) -> String {
        // The pump is container_inset's: chrome assembled in this same
        // drain has not been allocated or mapped until the loop turns,
        // and mapping is half of what rendered_sections_arm asks.
        Self::on_main(move |core| {
            while glib::MainContext::default().iteration(false) {}
            rendered_sections_arm(core, window)
        })
    }

    fn section_count(&self) -> usize {
        // The REAL switcher's page model, never the section map.
        Self::on_main(|core| {
            use gtk4::prelude::Cast;
            use gtk4::gio::prelude::ListModelExt;
            core.section_stacks
                .get(&0)
                .map(|stack| stack.pages().upcast_ref::<gtk4::gio::ListModel>().n_items() as usize)
                .unwrap_or(0)
        })
    }

    fn active_section_title(&self) -> String {
        // The visible page's OWN title from the stack — the
        // platform's selection state, not the model mirror.
        Self::on_main(|core| {
            use gtk4::prelude::WidgetExt;
            let Some(stack) = core.section_stacks.get(&0) else {
                return String::new();
            };
            let Some(child) = stack.visible_child() else {
                return String::new();
            };
            stack
                .page(&child)
                .title()
                .map(|t| t.to_string())
                .unwrap_or_default()
        })
    }

    fn section_symbol(&self, title: &str) -> String {
        let title = title.to_owned();
        // The pump is sections_presentation's, for the same reason: a
        // switcher assembled in this same drain has not built its
        // buttons yet, and a read that ran first would report an empty
        // switcher as a missing row.
        Self::on_main(move |core| {
            while glib::MainContext::default().iteration(false) {}
            section_symbol_read(core, &title)
        })
    }

    fn select_section(&self, index: usize) {
        // The user's route: reconcile, move the stack under the echo
        // guard (the notify handler cannot re-borrow CORE from inside
        // this closure), and emit exactly once — the WinUI
        // synchronous-emit pattern.
        Self::on_main_mut(move |core| {
            let ids = core.sections.get(&0).cloned().unwrap_or_default();
            let Some(&sid) = ids.get(index) else { return };
            if core.selected_sections.get(&0) == Some(&sid) {
                return;
            }
            core.selected_sections.insert(0, sid);
            core.scene
                .user_selected_section(WindowId(0), WindowId(sid));
            core.apply_quiet.set(true);
            if let Some(stack) = core.section_stacks.get(&0) {
                stack.set_visible_child_name(&sid.to_string());
            }
            core.apply_quiet.set(false);
            core.occurrences.send(Occurrence::SectionSelected {
                window: WindowId(0),
                section: WindowId(sid),
            });
        });
    }

    fn finish(&self, code: i32, verdict: &str) {
        if code == 0 {
            println!("{verdict}");
        } else {
            eprintln!("{verdict}");
        }
        // THE HOP IS THE EXIT — one rule with the WinUI arm (the
        // measured reason: docs/traps.md "exit() is not final on
        // Windows"); the grace machinery stays as the wall for a hop
        // that never lands (the linux N=6000 wedge).
        Self::on_main(move |_| crate::harness::harness_exit(code));
    }
}

/// The sections arm a window ACTUALLY rendered — what
/// `expect_sections_presentation` believes. NEVER the declared hint: a read
/// that consults the prop agrees with the lowering by construction. Two
/// independent things have to hold and the sentence names the one that did
/// not — the arm stamped its own name, and the widget it left behind is the
/// one that name claims, wired to THIS window's stack, and MAPPED.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn rendered_sections_arm(core: &CoreState, window: u64) -> String {
    use gtk4::prelude::{Cast, ObjectExt, WidgetExt};
    let Some((_, chrome)) = core.section_chrome.get(&window) else {
        return format!("window#{window} has no sections chrome");
    };
    // What the chrome REALLY holds: the switchers driving this window's
    // own stack, plus every child by GType name — so a chrome that
    // holds no switcher at all reports what it does hold instead of a
    // bare absence.
    let stack = core.section_stacks.get(&window);
    let mut built: Vec<&'static str> = Vec::new();
    let mut kinds: Vec<String> = Vec::new();
    let mut child = chrome.first_child();
    while let Some(widget) = child {
        if let Some(sidebar) = widget.downcast_ref::<gtk4::StackSidebar>() {
            if sidebar.stack().as_ref() == stack {
                built.push("sidebar");
            }
        } else if let Some(switcher) = widget.downcast_ref::<gtk4::StackSwitcher>() {
            if switcher.stack().as_ref() == stack {
                built.push("bar");
            }
        }
        kinds.push(widget.type_().name().to_owned());
        child = widget.next_sibling();
    }
    if built.len() != 1 {
        return format!(
            "window#{window} sections chrome drives its stack from {} switchers (children: {})",
            built.len(),
            kinds.join(", ")
        );
    }
    let arm = built[0];
    let stamp = core.sections_rendered.get(&window).copied();
    if stamp != Some(arm) {
        return format!(
            "window#{window} stamped {} but its chrome holds a {arm} switcher",
            stamp.unwrap_or("nothing")
        );
    }
    if !chrome.is_mapped() {
        // Built, filled and never shown. Named that way and not "not
        // mapped", which reads like a timing answer: the poll has been
        // retrying for the deadline by the time this is the verdict.
        return format!("window#{window} {arm} chrome was built but never shown");
    }
    arm.to_owned()
}

/// THE SECTION ROW'S SYMBOL, off the GtkImage the real switcher button draws
/// — never `GtkSectionPage::symbol` beside it and never the accessible
/// Description kaya wrote. TITLE -> ROW is positional and the platform forces
/// it: a switcher renders icon OR title, so a section WITH a symbol has no
/// visible label to match on, and its Nth button is the stack's Nth page.
/// EVERY WINDOW, in id order.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn section_symbol_read(core: &CoreState, title: &str) -> String {
    use gtk4::prelude::{Cast, WidgetExt};
    let mut windows: Vec<u64> = core.sections.keys().copied().collect();
    windows.sort_unstable();
    // What the switchers DO carry, for the miss sentence: "no row by
    // that name" and "the rows are not built yet" are different bugs and
    // the reader chases the sentence.
    let mut seen: Vec<String> = Vec::new();
    for window in windows {
        let Some(stack) = core.section_stacks.get(&window) else {
            continue;
        };
        let ids = core.sections.get(&window).cloned().unwrap_or_default();
        let mut index = None;
        for (i, sid) in ids.iter().enumerate() {
            let Some(record) = core.section_pages.get(sid) else {
                continue;
            };
            if record.page.parent().is_none() {
                continue;
            }
            let page_title = stack
                .page(record.page.upcast_ref::<gtk4::Widget>())
                .title()
                .map(|t| t.to_string())
                .unwrap_or_default();
            if page_title == title {
                index = Some(i);
                break;
            }
            seen.push(page_title);
        }
        let Some(index) = index else { continue };
        let Some((_, chrome)) = core.section_chrome.get(&window) else {
            return format!("window#{window} has no sections chrome");
        };
        let mut child = chrome.first_child();
        while let Some(widget) = child {
            if let Some(switcher) = widget.downcast_ref::<gtk4::StackSwitcher>() {
                let mut button = switcher.first_child();
                let mut at = 0usize;
                while let Some(b) = button {
                    if at == index {
                        let Some(icon) = first_image_icon_name(&b) else {
                            // WHAT THIS MEASURED: the button is in the real
                            // switcher and holds no GtkImage.
                            // GtkStackSwitcher builds one ONLY from the
                            // page's icon-name, so this is "the row draws no
                            // glyph" and not "the app declared none".
                            return "no glyph on the section row".to_owned();
                        };
                        return match symbol_name_of_icon(&icon) {
                            Some(name) => name.to_owned(),
                            None => format!(
                                "the section row {title:?} draws {icon:?}, which is not in \
                                 this backend's symbol table"
                            ),
                        };
                    }
                    at += 1;
                    button = b.next_sibling();
                }
                return format!(
                    "the switcher holding {title:?} has {at} buttons, so there is none at #{index}"
                );
            }
            if widget.downcast_ref::<gtk4::StackSidebar>().is_some() {
                // MEASURED, GTK 4.18.6 (refresh_section_symbols' fact 2):
                // GtkStackSidebar binds the page TITLE into a GtkLabel and
                // ignores icon-name entirely, so the sidebar arm draws no
                // glyph for any section. This is the component, not a
                // lowering that forgot.
                return "a GtkStackSidebar row carries no icon".to_owned();
            }
            child = widget.next_sibling();
        }
        return format!("window#{window} sections chrome holds no switcher");
    }
    format!("no section row is titled {title:?} (the switchers carry: {seen:?})")
}

/// The inset MEASURED on a widget's own CSS box, per side, in whole layout
/// units: `compute_bounds(w, w)` gives the BORDER box in a space GTK4 origins
/// at the CONTENT box, so the origin it returns is minus the inset (measured:
/// `padding: 16px` reports @(-16,-16); plus an 8px border, @(-24,-24)).
/// THE FIRST-CHILD WALK CANNOT WORK HERE — a child at its parent's content
/// origin translates to (0, 0) whatever the inset is, and reads 0 for every
/// window.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn css_inset_of(widget: &gtk4::Widget) -> String {
    use gtk4::prelude::WidgetExt;
    let Some(bounds) = widget.compute_bounds(widget) else {
        return "unallocated".to_owned();
    };
    let (x, y) = ((-bounds.x()).round() as i64, (-bounds.y()).round() as i64);
    if x == y {
        format!("{x}")
    } else {
        format!("{x}x{y} (axes disagree)")
    }
}

/// The widget a `kind#index` target names, from the per-kind registry
/// every other verb resolves through — creation order, which is what
/// `kind#index` means.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn target_widget(core: &CoreState, target: crate::harness::Target) -> Option<gtk4::Widget> {
    use crate::harness::{try_resolve, TargetKind as K};
    use gtk4::prelude::Cast;
    macro_rules! nth {
        ($reg:expr) => {
            try_resolve(target.index, $reg.len()).map(|i| $reg[i].clone().upcast())
        };
    }
    match target.kind {
        K::Button => nth!(core.buttons),
        K::Checkbox => nth!(core.checkboxes),
        K::Label => nth!(core.labels),
        K::Entry => nth!(core.entries),
        K::Textarea => nth!(core.textareas),
        K::Slider => nth!(core.sliders),
        K::Image => nth!(core.images),
        K::Progress => nth!(core.progresses),
        K::Select => nth!(core.selects),
        K::Radio => nth!(core.radios),
        K::Grid => nth!(core.grids),
        K::Scroll => nth!(core.scrolls),
        K::Row => nth!(core.rows),
        K::Column => nth!(core.columns),
        K::Canvas => nth!(core.canvases),
    }
}

/// The AT-SPI role GTK publishes for this widget — MEASURED off the bus
/// (tools/linux/atspi_probe.py), not assumed, and deliberately narrow.
///
/// The bus tree is NOT kaya's tree: GTK publishes widgets kaya never created
/// (every button and check box contains a GtkLabel, and those are real Label
/// nodes on the bus) and hides some it did (an entry's internal GtkText does
/// not appear at all). Getting the set wrong is silent.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_role_of(w: &gtk4::Widget) -> Option<atspi::Role> {
    use gtk4::prelude::{AccessibleExt, Cast};
    // A ScrolledWindow FIRST, before the promotion check below: GTK takes the
    // name but NOT the role, so the bus still publishes `scroll pane`
    // (measured). AND EVERY TEXTAREA'S VIEWPORT IS ONE OF THESE — this walk's
    // count must MATCH the bus's, so skipping it would put every scene holding
    // both a textarea and a scroll viewport one element behind.
    if w.is::<gtk4::ScrolledWindow>() {
        return Some(atspi::Role::ScrollPane);
    }
    // A container kaya NAMED was promoted to Group by the lowering, and
    // Group is exactly what the bus then publishes for it.
    if w.accessible_role() == gtk4::AccessibleRole::Group {
        return Some(atspi::Role::Grouping);
    }
    // A label carrying the heading role (docs/styling-plan.md D4) was given
    // HEADING by the lowering, and GTK 4.18 maps that to ATSPI_ROLE_HEADING
    // — so it is not a Label on the bus. BEFORE the Label check for exactly
    // that reason: counting it as a label would shift every label after it.
    if w.accessible_role() == gtk4::AccessibleRole::Heading {
        return Some(atspi::Role::Heading);
    }
    if w.is::<gtk4::Label>() {
        // Kaya's labels AND the captions inside buttons and check
        // boxes: all of them are Label nodes on the bus.
        return Some(atspi::Role::Label);
    }
    if w.is::<gtk4::CheckButton>() {
        // A grouped check button IS a radio button, and GTK says so
        // through the accessible role it assigns.
        return Some(if w.accessible_role() == gtk4::AccessibleRole::Radio {
            atspi::Role::RadioButton
        } else {
            atspi::Role::CheckBox
        });
    }
    // ToggleButton is a Button subclass and must not count as one: the
    // drop-down's internal button is a toggle, and the bus agrees.
    if w.is::<gtk4::ToggleButton>() {
        return Some(atspi::Role::ToggleButton);
    }
    if w.is::<gtk4::Button>() {
        return Some(atspi::Role::Button);
    }
    // Both editable kinds are role Text on the bus — the very collision
    // that made `textarea#0` read the entry's name.
    if w.is::<gtk4::Entry>() || w.is::<gtk4::TextView>() {
        return Some(atspi::Role::Text);
    }
    if w.is::<gtk4::Scale>() {
        return Some(atspi::Role::Slider);
    }
    if w.is::<gtk4::Picture>() {
        return Some(atspi::Role::Image);
    }
    // The canvas is kaya's own widget rather than a GtkPicture (the size
    // policy's 1:1 blit) and declares `AccessibleRole::Img`, which the bus
    // publishes as Image exactly like the picture above — MEASURED, like
    // every other row here: without this arm three scenes read
    // "<not in the accessibility tree>" (docs/traps.md, "A canvas sized by
    // its own blit NEVER STARTS", last paragraph).
    if w.is::<KayaCanvas>() {
        return Some(atspi::Role::Image);
    }
    if w.is::<gtk4::ProgressBar>() {
        return Some(atspi::Role::ProgressBar);
    }
    if w.is::<gtk4::DropDown>() {
        return Some(atspi::Role::ComboBox);
    }
    None
}

/// This widget's rank among the widgets of the SAME AT-SPI role in the
/// window, walked depth-first — which is the order the bus publishes,
/// so the rank IS the ordinal of its node there.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_rank(window: &gtk4::Window, target: &gtk4::Widget) -> Option<usize> {
    use gtk4::prelude::Cast;
    let want = atspi_role_of(target)?;
    fn walk(
        node: &gtk4::Widget,
        target: &gtk4::Widget,
        want: atspi::Role,
        rank: &mut usize,
    ) -> bool {
        use gtk4::prelude::WidgetExt;
        if node == target {
            return true;
        }
        // THE BUS PUBLISHES WHAT IS ON SCREEN. An unmapped subtree has no
        // accessible nodes, so counting it shifts every ordinal after it: a
        // drop-down's popover carries its own GtkScrolledWindow, and counting
        // that one made the scene's real scroll viewport ScrollPane#1 on a bus
        // that published exactly one (measured 2026-07-25).
        if !node.is_mapped() {
            return false;
        }
        if atspi_role_of(node) == Some(want) {
            *rank += 1;
        }
        let mut child = node.first_child();
        while let Some(c) = child {
            if walk(&c, target, want, rank) {
                return true;
            }
            child = c.next_sibling();
        }
        false
    }
    let mut rank = 0;
    let root: gtk4::Widget = window.clone().upcast();
    // A target that is not in this window's tree has no ordinal at all,
    // which is a finding rather than a zero.
    if !walk(&root, target, want, &mut rank) {
        return None;
    }
    Some(rank)
}

/// Read this app's accessibility tree over AT-SPI, as a real assistive client
/// does. GTK exposes NO getter for accessible properties — the accessible
/// surface IS AT-SPI — so an in-process read would only return kaya's own
/// writes, which is why the harness and this dependency are feature-gated: a
/// shipped app must never link a dbus client to serve a test verb. Everything
/// here was MEASURED against GTK 4.18 in the image (docs/traps.md).
#[cfg(all(feature = "harness", target_os = "linux"))]
enum DialogOp<'a> {
    /// The directory it is showing, the names its list contains, and the
    /// text in its name field if it has one.
    Read,
    /// Select the row whose filename is this. A separate pass from the
    /// press, so the two do not depend on the tree's child order.
    Select(&'a str),
    /// Press the button with this label ("Open", "Save" or "Cancel").
    Press(&'a str),
    /// Type this into the SAVE panel's name field, over whatever is
    /// there — the harness doing what a user's keyboard would, through
    /// the same `EditableText` interface an assistive client uses.
    SetName(&'a str),
}

/// One read of the live chooser, whichever kind it is.
///
/// THE TWO DIALOGS ARE ONE OBJECT ON THIS TOOLKIT — `gtk::FileDialog`
/// with `open()` or `save()` called on it — so one walk answers both and
/// the reader decides which it is looking at from what the tree carries,
/// not from what this backend remembers asking for.
#[cfg(all(feature = "harness", target_os = "linux"))]
struct DialogRead {
    /// The current folder: the path bar's PRESSED toggle button. Both
    /// panels publish it identically (measured on GTK 4.18).
    dir: String,
    /// One filename per data row. A save panel has a browser too, but
    /// nothing asserts on it — see `save_dialog_state`'s "never require
    /// rows".
    rows: Vec<String>,
    /// The text really in the name field — `Some` EXACTLY WHEN this
    /// dialog has one, which is what makes it a save panel rather than a
    /// picker. Measured: the save panel's tree is the open chooser's plus
    /// one `role=text` node carrying `EditableText`; the open chooser
    /// publishes no editable text at all.
    save_name: Option<String>,
}

/// Read or drive the live GTK file chooser over AT-SPI. THE DIALOG IS IN OUR
/// PROCESS and on the same bus as every other widget (no portal is installed),
/// though the walk starts at the desktop so a portal-hosted one is still
/// found. Three things the tree does NOT do the way the mac panel does, all
/// measured (docs/traps.md: "What GTK's file chooser publishes, and what it
/// does not"): no "where" control, whole-line row names, and a header row
/// that is a `table row` too.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn file_dialog_atspi(op: DialogOp<'_>) -> Option<DialogRead> {
    use atspi::proxy::accessible::AccessibleProxy;
    use atspi::proxy::action::ActionProxy;
    use atspi::proxy::editable_text::EditableTextProxy;
    use atspi::proxy::selection::SelectionProxy;
    use atspi::proxy::text::TextProxy;

    atspi::zbus::block_on(async move {
        let conn = atspi::connection::AccessibilityConnection::new()
            .await
            .ok()?;
        let root = AccessibleProxy::builder(conn.connection())
            .destination("org.a11y.atspi.Registry")
            .ok()?
            .path("/org/a11y/atspi/accessible/root")
            .ok()?
            .build()
            .await
            .ok()?;

        struct Found {
            dir: String,
            rows: Vec<String>,
            save_name: Option<String>,
            acted: bool,
            in_dialog: bool,
        }

        async fn walk(
            node: AccessibleProxy<'_>,
            out: &mut Found,
            op: &DialogOp<'_>,
            depth: usize,
            parent_is_list: bool,
            in_combo: bool,
            in_dialog: bool,
        ) {
            if depth > 26 {
                return;
            }
            let (Ok(role), Ok(name)) = (node.get_role().await, node.name().await) else {
                return;
            };
            let in_dialog = in_dialog || role == atspi::Role::Dialog;
            if in_dialog {
                out.in_dialog = true;
            }
            let in_combo = in_combo || role == atspi::Role::ComboBox;

            if in_dialog && role == atspi::Role::ToggleButton && !in_combo {
                if let Ok(states) = node.get_state().await {
                    if states.contains(atspi::State::Pressed) {
                        out.dir = name.clone();
                    }
                }
            }

            if in_dialog && role == atspi::Role::TableRow && parent_is_list {
                let file = name.split_whitespace().next().unwrap_or("").to_owned();
                if !file.is_empty() {
                    out.rows.push(file.clone());
                }
            }

            // THE SAVE PANEL'S ONE EXTRA CONTROL. Matched on the INTERFACE and
            // not on the label: the node's accessible name is the translated
            // "Name:" label beside it, so a lane under another locale would
            // see no save panel at all. THE COMBO IS EXCLUDED.
            if in_dialog && role == atspi::Role::Text && !in_combo {
                let editable = node
                    .get_interfaces()
                    .await
                    .map(|set| set.contains(atspi::Interface::EditableText))
                    .unwrap_or(false);
                if editable {
                    if let Ok(text) = TextProxy::builder(node.inner().connection())
                        .destination(node.inner().destination().to_owned())
                        .and_then(|b| b.path(node.inner().path().to_owned()))
                    {
                        if let Ok(text) = text.build().await {
                            if let Ok(len) = text.character_count().await {
                                out.save_name = text.get_text(0, len).await.ok();
                            }
                        }
                    }
                    if let DialogOp::SetName(want) = op {
                        // The whole contents, not an insert: the panel
                        // opens with the suggested name already in the
                        // field, and a user renaming a file replaces it.
                        if let Ok(editable) = EditableTextProxy::builder(node.inner().connection())
                            .destination(node.inner().destination().to_owned())
                            .and_then(|b| b.path(node.inner().path().to_owned()))
                        {
                            if let Ok(editable) = editable.build().await {
                                out.acted =
                                    editable.set_text_contents(want).await.unwrap_or(false);
                                // Read back what the field now holds, so
                                // one walk both types and reports — the
                                // step's own assertion still re-reads it
                                // from scratch.
                                if let Ok(text) = TextProxy::builder(node.inner().connection())
                                    .destination(node.inner().destination().to_owned())
                                    .and_then(|b| b.path(node.inner().path().to_owned()))
                                {
                                    if let Ok(text) = text.build().await {
                                        if let Ok(len) = text.character_count().await {
                                            out.save_name = text.get_text(0, len).await.ok();
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if in_dialog && role == atspi::Role::Button {
                if let DialogOp::Press(want) = op {
                    if name == *want && !out.acted {
                        if let Ok(action) = ActionProxy::builder(node.inner().connection())
                            .destination(node.inner().destination().to_owned())
                            .and_then(|b| b.path(node.inner().path().to_owned()))
                        {
                            if let Ok(action) = action.build().await {
                                out.acted = action.do_action(0).await.unwrap_or(false);
                            }
                        }
                    }
                }
            }

            let Ok(children) = node.get_children().await else {
                return;
            };
            let is_list = role == atspi::Role::List;

            // SELECTION IS THE PARENT'S JOB, and the rows offer no click
            // action at all — only `listitem.scroll-to`, measured. So the
            // index within this list is what selects.
            if in_dialog && is_list {
                if let DialogOp::Select(want) = op {
                    for (index, child) in children.iter().enumerate() {
                        let Some(dest) = child.name() else { continue };
                        let Ok(builder) = AccessibleProxy::builder(node.inner().connection())
                            .destination(dest.to_owned())
                            .and_then(|b| b.path(child.path().to_owned()))
                        else {
                            continue;
                        };
                        let Ok(row) = builder.build().await else { continue };
                        let Ok(row_name) = row.name().await else { continue };
                        if row_name.split_whitespace().next() != Some(want) {
                            continue;
                        }
                        if let Ok(selection) = SelectionProxy::builder(node.inner().connection())
                            .destination(node.inner().destination().to_owned())
                            .and_then(|b| b.path(node.inner().path().to_owned()))
                        {
                            if let Ok(selection) = selection.build().await {
                                // CLEAR FIRST. In a multi-select chooser
                                // select_child ADDS, and the list already
                                // carries a selection — so choosing
                                // "picked.txt" returned BOTH files with the
                                // decoy first. Measured on GTK 4.18.
                                let _ = selection.clear_selection().await;
                                out.acted =
                                    selection.select_child(index as i32).await.unwrap_or(false);
                            }
                        }
                        break;
                    }
                }
            }

            for child in children {
                let Some(dest) = child.name() else { continue };
                let Ok(proxy) = AccessibleProxy::builder(node.inner().connection())
                    .destination(dest.to_owned())
                    .and_then(|b| b.path(child.path().to_owned()))
                else {
                    continue;
                };
                if let Ok(proxy) = proxy.build().await {
                    Box::pin(walk(
                        proxy, out, op, depth + 1, is_list, in_combo, in_dialog,
                    ))
                    .await;
                }
            }
        }

        let mut found = Found {
            dir: String::new(),
            rows: Vec::new(),
            save_name: None,
            acted: false,
            in_dialog: false,
        };
        for app in root.get_children().await.ok()? {
            let Some(dest) = app.name() else { continue };
            let Ok(builder) = AccessibleProxy::builder(conn.connection())
                .destination(dest.to_owned())
                .and_then(|b| b.path(app.path().to_owned()))
            else {
                continue;
            };
            let Ok(proxy) = builder.build().await else { continue };
            if proxy.get_application().await.is_err() {
                continue;
            }
            Box::pin(walk(proxy, &mut found, &op, 0, false, false, false)).await;
        }

        if !found.in_dialog {
            return None;
        }
        let read = DialogRead {
            dir: found.dir,
            rows: found.rows,
            save_name: found.save_name,
        };
        match op {
            DialogOp::Read => Some(read),
            _ if found.acted => Some(read),
            _ => None,
        }
    })
}

/// A range verb's resolved target: the accessibility-bus ordinal, and
/// the live input-method preedit GTK reported for that widget.
#[cfg(all(feature = "harness", target_os = "linux"))]
struct RangeTarget {
    rank: usize,
    preedit: String,
}

/// Which of the three range observables to read off one Text node.
#[cfg(all(feature = "harness", target_os = "linux"))]
enum RangeRead {
    Highlights,
    /// `preedit` is what GTK says the input method is displaying — see
    /// the caret arm below for why the selection read needs it.
    Selection { preedit: String },
    /// UTF-8 BYTE offsets, straight from the scene: the one verb whose
    /// argument arrives in the protocol's unit rather than being read
    /// back in it.
    Revealed { start: u64, stop: u64 },
}

/// Read one of the three range observables off the Nth `Text` node this
/// application publishes. ONE WALK, ONE CONNECTION, THREE READS. AT-SPI
/// OFFSETS ARE CHARACTERS, which for GTK means CODE POINTS, so every offset
/// below is converted against the text the BUS returned and never kaya's copy.
/// NEVER `GetAttributeValue`: the deprecated point getter SIGSEGVs a
/// GtkTextView, reproduced twice. `GetAttributeRun` is the safe one.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_range_read(index: usize, read: RangeRead) -> Option<String> {
    use atspi::proxy::accessible::AccessibleProxy;
    use atspi::proxy::component::ComponentProxy;
    use atspi::proxy::text::TextProxy;

    atspi::zbus::block_on(async move {
        let conn = atspi::connection::AccessibilityConnection::new()
            .await
            .ok()?;
        let root = AccessibleProxy::builder(conn.connection())
            .destination("org.a11y.atspi.Registry")
            .ok()?
            .path("/org/a11y/atspi/accessible/root")
            .ok()?
            .build()
            .await
            .ok()?;

        /// Depth-first over our own application, collecting the bus
        /// ADDRESS of every node — `atspi_collect` collects names, and
        /// this needs the node itself to ask its other interfaces.
        async fn walk(
            node: AccessibleProxy<'_>, out: &mut Vec<(atspi::Role, String, String)>, depth: usize,
        ) {
            if depth > 24 {
                return;
            }
            if let Ok(role) = node.get_role().await {
                out.push((
                    role,
                    node.inner().destination().to_string(),
                    node.inner().path().to_string(),
                ));
            }
            let Ok(children) = node.get_children().await else {
                return;
            };
            for child in children {
                let Some(dest) = child.name() else { continue };
                let Ok(proxy) = AccessibleProxy::builder(node.inner().connection())
                    .destination(dest.to_owned())
                    .and_then(|b| b.path(child.path().to_owned()))
                else {
                    continue;
                };
                if let Ok(proxy) = proxy.build().await {
                    Box::pin(walk(proxy, out, depth + 1)).await;
                }
            }
        }

        let mut found: Vec<(atspi::Role, String, String)> = Vec::new();
        for app in root.get_children().await.ok()? {
            let Some(dest) = app.name() else { continue };
            let Ok(builder) = AccessibleProxy::builder(conn.connection())
                .destination(dest.to_owned())
                .and_then(|b| b.path(app.path().to_owned()))
            else {
                continue;
            };
            let Ok(proxy) = builder.build().await else { continue };
            if proxy.get_application().await.is_err() {
                continue;
            }
            Box::pin(walk(proxy, &mut found, 0)).await;
        }
        let (_, dest, path) = found
            .iter()
            .filter(|(role, _, _)| *role == atspi::Role::Text)
            .nth(index)?;
        let text = TextProxy::builder(conn.connection())
            .destination(dest.to_owned())
            .ok()?
            .path(path.to_owned())
            .ok()?
            .build()
            .await
            .ok()?;
        // THE PLATFORM'S OWN STRING, read once and used for every
        // conversion and every slice below.
        let count = text.character_count().await.ok()?;
        let full = text.get_text(0, count).await.ok()?;

        match read {
            RangeRead::Highlights => {
                // WALKED, NOT ENUMERATED: for an offset no tag covers, GTK
                // answers with the empty range (0,0) rather than the run of
                // unattributed text, so a reader has to probe every
                // character. Measured at ~0.15ms a call.
                let mut out: Vec<String> = Vec::new();
                let mut at = 0i32;
                while at < count {
                    let Ok((attrs, start, stop)) = text.get_attribute_run(at, false).await else {
                        return None;
                    };
                    if stop > start && attrs.contains_key("bg-color") {
                        // THE COVERED TEXT COMES FROM THE PLATFORM: the offsets
                        // alone would be this read agreeing with the lowering's
                        // own conversion, two symmetric mistakes cancelling.
                        // This slice has no arithmetic in it.
                        let covered = lf(text.get_text(start, stop).await.ok()?);
                        out.push(format!(
                            "{}:{}={covered}",
                            guest_byte_of(&full, start),
                            guest_byte_of(&full, stop)
                        ));
                    }
                    // The run's own end when there is one, a single
                    // character when GTK answered with nothing.
                    at = if stop > at { stop } else { at + 1 };
                }
                Some(out.join("|"))
            }
            RangeRead::Selection { preedit } => {
                let selections = text.get_n_selections().await.ok()?;
                if selections > 0 {
                    let (start, stop) = text.get_selection(0).await.ok()?;
                    let covered = lf(text.get_text(start, stop).await.ok()?);
                    return Some(format!(
                        "{}:{}={covered}",
                        guest_byte_of(&full, start),
                        guest_byte_of(&full, stop)
                    ));
                }
                // AN EMPTY RANGE IS A CARET, NOT A SELECTION, on this
                // platform: `select_range(50, 50)` leaves
                // `GetNSelections` at 0 and puts the caret at 50
                // (measured), so "no selection" and "empty selection at
                // N" are told apart by asking for the caret.
                let caret = text.caret_offset().await.ok()?;
                // AND THE COMPOSITION COUNTS, because the offsets in this
                // spelling are into the text the widget is DISPLAYING, which
                // includes the marked text. GTK renders it out of the layout
                // and leaves the buffer alone (measured: `char_count` stayed 4
                // with a live preedit).
                let at = guest_byte_of(&full, caret) + preedit.len() as u64;
                Some(format!("{at}:{at}="))
            }
            RangeRead::Revealed { start, stop } => {
                let (start, stop) =
                    (buffer_offset_of_byte(&full, start), buffer_offset_of_byte(&full, stop));
                let (rx, ry, rw, rh) = text
                    .get_range_extents(start, stop, atspi::CoordType::Window)
                    .await
                    .ok()?;
                let component = ComponentProxy::builder(conn.connection())
                    .destination(dest.to_owned())
                    .ok()?
                    .path(path.to_owned())
                    .ok()?
                    .build()
                    .await
                    .ok()?;
                let (wx, wy, ww, wh) =
                    component.get_extents(atspi::CoordType::Window).await.ok()?;
                // CONTAINMENT, NEVER THE VIEWPORT ITSELF: how much context a
                // scroll leaves is native behaviour, and a scene asserting a
                // scroll offset would be asserting GTK's taste. Consistent by
                // measurement: `extents.y = widget.y + buffer_y - scroll`.
                let inside =
                    rx >= wx && ry >= wy && rx + rw <= wx + ww && ry + rh <= wy + wh;
                Some(if inside { "visible" } else { "offscreen" }.to_owned())
            }
        }
    })
}

#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_collect(want: atspi::Role, index: usize, want_description: bool) -> Option<String> {
    use atspi::proxy::accessible::AccessibleProxy;
    atspi::zbus::block_on(async move {
        let conn = atspi::connection::AccessibilityConnection::new()
            .await
            .ok()?;
        let root = AccessibleProxy::builder(conn.connection())
            .destination("org.a11y.atspi.Registry")
            .ok()?
            .path("/org/a11y/atspi/accessible/root")
            .ok()?
            .build()
            .await
            .ok()?;
        let me = std::process::id();
        let mut found: Vec<(atspi::Role, String, String)> = Vec::new();
        /// The Text interface's content at the same bus node — what a
        /// screen reader actually speaks for an unlabeled field.
        async fn text_content(node: &AccessibleProxy<'_>) -> Option<String> {
            use atspi::proxy::text::TextProxy;
            let proxy = TextProxy::builder(node.inner().connection())
                .destination(node.inner().destination().to_owned())
                .ok()?
                .path(node.inner().path().to_owned())
                .ok()?
                .build()
                .await
                .ok()?;
            let len = proxy.character_count().await.ok()?;
            proxy.get_text(0, len).await.ok()
        }
        // Depth-first over OUR application only. Roles are matched on
        // the enum, not a localized name string.
        async fn walk(
            node: AccessibleProxy<'_>,
            out: &mut Vec<(atspi::Role, String, String)>,
            depth: usize,
        ) {
            if depth > 24 {
                return;
            }
            if let (Ok(role), Ok(name), Ok(description)) =
                (node.get_role().await, node.name().await, node.description().await)
            {
                // A text field with no authored label publishes an EMPTY name;
                // its content lives on the Text interface, which is what a
                // screen reader speaks. The macOS reader's chain ends in
                // AXValue for the same reason, so `field/<its text>` matches.
                let name = if name.is_empty() && role == atspi::Role::Text {
                    text_content(&node).await.unwrap_or(name)
                } else {
                    name
                };
                out.push((role, name, description));
            }
            let Ok(children) = node.get_children().await else {
                return;
            };
            for child in children {
                let Some(dest) = child.name() else { continue };
                let Ok(proxy) = AccessibleProxy::builder(node.inner().connection())
                    .destination(dest.to_owned())
                    .and_then(|b| b.path(child.path().to_owned()))
                else {
                    continue;
                };
                if let Ok(proxy) = proxy.build().await {
                    Box::pin(walk(proxy, out, depth + 1)).await;
                }
            }
        }
        for app in root.get_children().await.ok()? {
            let Some(dest) = app.name() else { continue };
            let Ok(builder) = AccessibleProxy::builder(conn.connection())
                .destination(dest.to_owned())
                .and_then(|b| b.path(app.path().to_owned()))
            else {
                continue;
            };
            let Ok(proxy) = builder.build().await else { continue };
            // Only our own process's application node.
            if proxy.get_application().await.is_err() {
                continue;
            }
            let _ = me;
            Box::pin(walk(proxy, &mut found, 0)).await;
        }
        let nth = found.iter().filter(|(r, _, _)| *r == want).nth(index);
        if nth.is_none() {
            // A miss is never self-explaining: the question is always
            // what the bus DID publish, and one container round-trip
            // per answer is the expensive way to learn it.
            eprintln!(
                "KAYA_AX_TRACE: no {want:?}#{index} on the bus; it published {:?}",
                found
                    .iter()
                    .map(|(r, n, _)| format!("{r:?}/{n}"))
                    .collect::<Vec<_>>()
            );
        }
        nth.map(|(_, name, description)| {
            if want_description { description.clone() } else { name.clone() }
        })
    })
}

/// Why an accessibility read could not answer, and whether asking again
/// could change that. A read with no sentinel value (`window_dirty`
/// returns a bare bool) has to tell those apart itself: a tree that has
/// not appeared yet is worth another 100ms, and two windows wearing one
/// title never will be.
#[cfg(all(feature = "harness", target_os = "linux"))]
struct AtspiMiss {
    why: String,
    retryable: bool,
}

/// THE OTHER CAUSE OF EVERY BUS MISS, which the tree-shaped readers cannot
/// see: no bus at all. `atspi_collect` and `atspi_range_read` answer in
/// `Option`, so a failed CONNECT and a missing NODE arrive as the same `None`
/// and the sentence the caller prints names the node — which a leg with no
/// DBUS_SESSION_BUS_ADDRESS makes a lie, and it cost a session (measured
/// 2026-08-27, docs/traps.md). Asked only on a failure path.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_absent() -> Option<String> {
    atspi::zbus::block_on(async {
        atspi::connection::AccessibilityConnection::new().await.err()
    })
    .map(|e| {
        format!(
            "<no accessibility bus ({e}): GTK publishes onto a bus libdbus \
             autolaunches for it, but this reader finds one only through \
             DBUS_SESSION_BUS_ADDRESS. On the linux lane that is what \
             tools/linux/a11y-leg.sh exports; a leg wired without it fails \
             every ax read on both protocols>"
        )
    })
}

/// The sentence for a bus read that came back empty — the bus's absence
/// where that is the cause, the missing node otherwise.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_miss(node: &str) -> String {
    atspi_absent().unwrap_or_else(|| node.to_owned())
}

/// Is the marker node — a descendant named `marker` — inside the frame this
/// app publishes under the name `title`? The `dirty` prop's read on GTK
/// (docs/dirty-plan.md D5), and the reason the marker carries an accessible
/// label at all: an unlabelled bullet publishes as `label name='• '`, which no
/// client can address. SCOPED TO ONE FRAME, unlike `atspi_collect`, because
/// `window_dirty` is asked about a WINDOW.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_window_marker(title: &str, marker: &str) -> Result<bool, AtspiMiss> {
    use atspi::proxy::accessible::AccessibleProxy;
    let (title, marker) = (title.to_owned(), marker.to_owned());
    atspi::zbus::block_on(async move {
        let conn = atspi::connection::AccessibilityConnection::new()
            .await
            .map_err(|e| AtspiMiss {
                why: format!("no accessibility bus ({e})"),
                // The bus is stood up before the guest starts; a
                // connection failure is the wiring, not a race.
                retryable: false,
            })?;
        let root = AccessibleProxy::builder(conn.connection())
            .destination("org.a11y.atspi.Registry")
            .and_then(|b| b.path("/org/a11y/atspi/accessible/root"))
            .map_err(|e| AtspiMiss { why: format!("no registry proxy ({e})"), retryable: false })?
            .build()
            .await
            .map_err(|e| AtspiMiss { why: format!("no registry root ({e})"), retryable: false })?;

        /// Frames seen under the wanted name, whether one of them holds
        /// the marker, and every frame name published — the last is for
        /// the failure message, which otherwise cannot say what the tree
        /// DID contain.
        struct Found {
            frames: usize,
            marked: bool,
            names: Vec<String>,
        }

        async fn walk(
            node: AccessibleProxy<'_>,
            want_frame: &str,
            want_marker: &str,
            out: &mut Found,
            in_frame: bool,
            depth: usize,
        ) {
            // The same horizon atspi_collect walks. NOT the depth-8 one
            // in tools/linux/atspi_probe.py: under an Adw header the
            // labels sit at depth ~15, and the shallow probe reports
            // them missing (docs/traps.md, the linux dirty probe §4d).
            if depth > 24 {
                return;
            }
            let mut inside = in_frame;
            if let (Ok(role), Ok(name)) = (node.get_role().await, node.name().await) {
                if role == atspi::Role::Frame {
                    out.names.push(name.clone());
                    if name == want_frame {
                        out.frames += 1;
                        inside = true;
                    }
                }
                // The accessible NAME, which for the marker is the
                // authored label and not the bullet glyph.
                if in_frame && name == want_marker {
                    out.marked = true;
                }
            }
            let Ok(children) = node.get_children().await else {
                return;
            };
            for child in children {
                let Some(dest) = child.name() else { continue };
                let Ok(proxy) = AccessibleProxy::builder(node.inner().connection())
                    .destination(dest.to_owned())
                    .and_then(|b| b.path(child.path().to_owned()))
                else {
                    continue;
                };
                if let Ok(proxy) = proxy.build().await {
                    Box::pin(walk(proxy, want_frame, want_marker, out, inside, depth + 1)).await;
                }
            }
        }

        let mut found = Found { frames: 0, marked: false, names: Vec::new() };
        let apps = root.get_children().await.map_err(|e| AtspiMiss {
            why: format!("the registry published no applications ({e})"),
            retryable: true,
        })?;
        for app in apps {
            let Some(dest) = app.name() else { continue };
            let Ok(builder) = AccessibleProxy::builder(conn.connection())
                .destination(dest.to_owned())
                .and_then(|b| b.path(app.path().to_owned()))
            else {
                continue;
            };
            let Ok(proxy) = builder.build().await else { continue };
            // Only our own process's application node.
            if proxy.get_application().await.is_err() {
                continue;
            }
            Box::pin(walk(proxy, &title, &marker, &mut found, false, 0)).await;
        }
        match found.frames {
            1 => Ok(found.marked),
            0 => Err(AtspiMiss {
                why: format!("no frame is named {title:?}; the tree published {:?}", found.names),
                retryable: true,
            }),
            n => Err(AtspiMiss {
                why: format!(
                    "{n} frames are named {title:?}, so which window's marker to read \
                     is ambiguous — give the windows distinct titles"
                ),
                retryable: false,
            }),
        }
    })
}

/// The promoted header buttons as an assistive client sees them: the
/// accessible NAME and the SENSITIVE state of each, in tree order, inside the
/// frame this app publishes under the name `title`. THE SCOPE IS THE
/// DESCRIPTION — the header publishes as an unnamed `panel`, and setting an
/// accessible ROLE on a box to mark it changed the published role of EVERY
/// other box in the process (measured 2026-08-17). SENSITIVE, NOT ENABLED.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_promoted_buttons(title: &str) -> Result<Vec<(String, bool)>, AtspiMiss> {
    use atspi::proxy::accessible::AccessibleProxy;
    let title = title.to_owned();
    atspi::zbus::block_on(async move {
        let conn = atspi::connection::AccessibilityConnection::new()
            .await
            .map_err(|e| AtspiMiss {
                why: format!("no accessibility bus ({e})"),
                retryable: false,
            })?;
        let root = AccessibleProxy::builder(conn.connection())
            .destination("org.a11y.atspi.Registry")
            .and_then(|b| b.path("/org/a11y/atspi/accessible/root"))
            .map_err(|e| AtspiMiss { why: format!("no registry proxy ({e})"), retryable: false })?
            .build()
            .await
            .map_err(|e| AtspiMiss { why: format!("no registry root ({e})"), retryable: false })?;

        struct Found {
            frames: usize,
            buttons: Vec<(String, bool)>,
            names: Vec<String>,
        }

        async fn walk(
            node: AccessibleProxy<'_>,
            want_frame: &str,
            out: &mut Found,
            in_frame: bool,
            depth: usize,
        ) {
            // The same horizon the other two walks use: under an Adw
            // header the promoted buttons sit at depth ~12.
            if depth > 24 {
                return;
            }
            let mut inside = in_frame;
            if let (Ok(role), Ok(name)) = (node.get_role().await, node.name().await) {
                if role == atspi::Role::Frame {
                    out.names.push(name.clone());
                    if name == want_frame {
                        out.frames += 1;
                        inside = true;
                    }
                }
                if in_frame && role == atspi::Role::Button {
                    let described = node.description().await.unwrap_or_default();
                    if crate::wire::SYMBOLS.iter().any(|(_, s)| *s == described) {
                        let sensitive = node
                            .get_state()
                            .await
                            .is_ok_and(|states| states.contains(atspi::State::Sensitive));
                        out.buttons.push((name, sensitive));
                    }
                }
            }
            let Ok(children) = node.get_children().await else {
                return;
            };
            for child in children {
                let Some(dest) = child.name() else { continue };
                let Ok(proxy) = AccessibleProxy::builder(node.inner().connection())
                    .destination(dest.to_owned())
                    .and_then(|b| b.path(child.path().to_owned()))
                else {
                    continue;
                };
                if let Ok(proxy) = proxy.build().await {
                    Box::pin(walk(proxy, want_frame, out, inside, depth + 1)).await;
                }
            }
        }

        let mut found = Found { frames: 0, buttons: Vec::new(), names: Vec::new() };
        let apps = root.get_children().await.map_err(|e| AtspiMiss {
            why: format!("the registry published no applications ({e})"),
            retryable: true,
        })?;
        for app in apps {
            let Some(dest) = app.name() else { continue };
            let Ok(builder) = AccessibleProxy::builder(conn.connection())
                .destination(dest.to_owned())
                .and_then(|b| b.path(app.path().to_owned()))
            else {
                continue;
            };
            let Ok(proxy) = builder.build().await else { continue };
            // Only our own process's application node.
            if proxy.get_application().await.is_err() {
                continue;
            }
            Box::pin(walk(proxy, &title, &mut found, false, 0)).await;
        }
        match found.frames {
            1 => Ok(found.buttons),
            0 => Err(AtspiMiss {
                why: format!("no frame is named {title:?}; the tree published {:?}", found.names),
                retryable: true,
            }),
            n => Err(AtspiMiss {
                why: format!(
                    "{n} frames are named {title:?}, so which window's chrome to read \
                     is ambiguous — give the windows distinct titles"
                ),
                retryable: false,
            }),
        }
    })
}
