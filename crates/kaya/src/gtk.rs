//! GTK4 backend, milestone 1: an interpreter of resolved apply-ops.
//!
//! Same architecture as the AppKit backend: the core owns the main
//! thread and the GLib main loop; transactions resolve through the scene
//! core into Create/SetProp/AddChild/Mount ops mapped onto gtk4::Box,
//! Button, and Label. The clicked signal pushes an occurrence carrying
//! the widget id and never calls app code; glib::idle_add (g_idle_add)
//! is the doorbell, carrying no data.

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

/// Where a child's grow weight is parked so the layout manager can find
/// it. GTK's own channel for per-child layout data is a `GtkLayoutChild`
/// subclass, which would mean a second GObject type and a factory method
/// on the manager; a keyed data item on the child widget carries the one
/// f64 we need with none of that, and lives and dies with the widget.
const GROW_KEY: &str = "kaya-grow";

/// Where the flex manager parks the main-axis extent it handed a child —
/// THE TRACK, before GTK adjusts the allocation for the child's own
/// align and margins. Same keyed-data channel as the grow weight, for
/// the same reason.
///
/// It exists so `expect_fills <widget>` can be asked a question the
/// allocation alone cannot answer. `child_extent` reads the allocation,
/// which GTK has already shrunk to a start/center/end-aligned child's
/// own size — so "did this widget take the space the layout gave it"
/// needs the number the layout gave, kept beside the number the widget
/// took. Nothing else reads it, and nothing else may: the SHARES are
/// the allocation's business (that is what the other backends' tracks
/// mean too), and this is the one observation that needs both halves.
const TRACK_KEY: &str = "kaya-track";

// --- The semantic icon vocabulary onto Adwaita (docs/styling-plan.md D6) ---
//
// EVERY NAME BELOW IS COPIED FROM THE CATALOG REPORT, NOT RECALLED
// (styling/symbols-adwaita.md §3). Recall is exactly what that column
// punishes: `dialog-information-symbolic` is a LIGHTBULB and not the
// circled "i" (§4.2), `edit-delete-symbolic` is an X in a circle and not
// a trash can (§4.3), `preferences-system-symbolic` is a wrench and
// screwdriver and not a gear (§4.4), and `emblem-favorite-symbolic` —
// the obvious spelling of `star` — was a HEART and was deleted from the
// theme in the 48 cycle (§4.5). Each of those reads right and draws
// wrong, and GTK reports none of it: an unresolvable name falls back
// SILENTLY, with the only notice behind `GTK_DEBUG=iconfallback` (§1).
// Every name here is present in adwaita-icon-theme 43, 45, 48 AND
// 50, so there is no version hole across the range kaya can meet.
//
// Full names including the `-symbolic` suffix, deliberately: GTK decides
// symbolic-ness by string-matching that suffix, and the bare name takes
// the fullcolor legacy path, which modern Adwaita mostly does not have
// (§7). And NO `-rtl` suffix is ever appended here: GTK's `choose_icon`
// tries the direction-suffixed name first and falls back, so
// `go-previous-symbolic` is RTL-aware for free while hard-coding the
// suffix would break LTR (§7).
//
// Column order is the wire order (crate::wire::SYMBOLS), and the const
// assertion below holds the two lists the same length. That catches an
// APPENDED symbol with no glyph at compile time — the moment this
// backend is built at all — and `assert_symbol_icons_resolve` catches
// the rest (a wrong value, a duplicate, a name this machine lacks) the
// first time an app declares any symbol.
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

// A symbol appended to the spec with no Adwaita glyph fails THE BUILD of
// this backend, which is the cheapest wall available: nobody can reach
// the GTK lane without passing it.
const _: () = assert!(
    SYMBOL_ICONS.len() == crate::wire::SYMBOLS.len(),
    "every spec symbol needs an Adwaita name in SYMBOL_ICONS (crates/kaya/src/gtk.rs)"
);

/// The Adwaita name for a wire symbol value, or None when the table has
/// no row for it (which `assert_symbol_icons_resolve` turns into a
/// panic before any app can see a blank).
fn symbol_icon_name(value: i64) -> Option<&'static str> {
    u32::try_from(value)
        .ok()
        .and_then(|v| SYMBOL_ICONS.iter().find(|(id, _)| *id == v))
        .map(|(_, name)| *name)
}

/// The reverse: the SEMANTIC name behind an Adwaita name. This is what
/// the harness read answers with, so the byte-compared verdict is the
/// same sentence every backend prints.
fn symbol_name_of_icon(icon: &str) -> Option<&'static str> {
    SYMBOL_ICONS
        .iter()
        .find(|(_, name)| *name == icon)
        .and_then(|(value, _)| crate::wire::symbol_name(*value as i64))
}

/// THE SILENT-BLANK WALL, run once per process the first time any app
/// declares any symbol.
///
/// GTK's icon lookup does not fail: `gtk_icon_theme_lookup_icon` ends at
/// `icon_paintable_new ("image-missing", ...)`, and the only notice is
/// behind `GTK_DEBUG=iconfallback` (styling/symbols-adwaita.md §1). So a
/// name this machine does not have ships with no error anywhere — the
/// failure class this whole column exists to kill. MEASURED on this
/// image (GTK 4.18.6, adwaita-icon-theme 48.1), what a GtkStackSwitcher
/// then paints is not even that broken-image glyph: the button is BLANK,
/// zero ink in its whole box. `gtk_icon_theme_has_icon` answers exactly
/// the question that fallback hides, and kaya resolves a CLOSED set of
/// names, so all of them can be asked at once and the answer is a fact
/// about the machine rather than about the app's luck.
///
/// It panics, and it names the semantic concept, the Adwaita name, the
/// theme that was searched and the package that carries it, because the
/// person reading it cannot be expected to know that kaya's `info` is
/// Adwaita's `help-about-symbolic`. The same shape as the wrong-scene-name
/// panic: a wall on the path of doing something basic.
fn assert_symbol_icons_resolve(display: &gdk::Display) {
    use std::cell::Cell;
    thread_local! {
        static CHECKED: Cell<bool> = const { Cell::new(false) };
    }
    if CHECKED.with(|c| c.replace(true)) {
        return;
    }
    let theme = gtk4::IconTheme::for_display(display);
    // The SPEC's list drives the walk, not the table's: a table row with
    // a wrong or duplicated value would leave a spec symbol uncovered,
    // and a length check alone cannot see that.
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
/// `CoreState::container_inset_css`. A class and not a per-widget
/// provider because `gtk_style_context_add_provider` — GTK4's per-widget
/// route — is deprecated, and because the display-level provider is the
/// road the window inset already takes.
const INSET_CLASS: &str = "kaya-inset-";

/// Guest-visible text uses LF as its line separator on every platform
/// (strings are compared byte-for-byte across languages). GTK's
/// Entry/TextView store pasted text verbatim — CR or CRLF from a paste
/// would ride into occurrence payloads and harness reads — so text is
/// normalized wherever it escapes toward the guest, the same boundary
/// discipline as WinUI's `lf` (whose TextBox speaks CR natively).
fn lf(s: String) -> String {
    if s.contains('\r') {
        s.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        s
    }
}

/// kaya AS AN INPUT METHOD — the harness `compose` verb's engine, and
/// nothing else in this file uses it.
///
/// WHY A WHOLE GObject FOR ONE VERB. A preedit is not text and there is
/// no setter for it: GTK's widgets render the string their
/// `GtkIMContext` hands back from `get_preedit_string`, the preedit
/// never enters the buffer at all (measured — `char_count` stayed at 4
/// with a live preedit), and emitting `preedit-changed` by hand only
/// makes the view ask the same context the same question and get "".
/// The only party that can produce marked text on GTK is an input
/// method, so the harness supplies one.
///
/// AND THAT IS WHAT MAKES THE D4 LEG REAL. Once installed, every
/// downstream behaviour is the platform's: the view renders our preedit
/// as marked text, republishes it on `GtkTextView::preedit-changed`, and
/// — the whole point — calls `reset` on us whenever something moves the
/// cursor or the selection programmatically. So a backend that honoured
/// a `select_range` mid-composition would have the composition destroyed
/// by GTK's own machinery rather than by a mock, and the scene's caret
/// assertion is what notices.
#[cfg(feature = "harness")]
mod kaya_im {
    use gtk4::glib;
    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;

    // Every kaya input method GTK has constructed, by the widget it was
    // given. GTK creates the delegate itself and exposes no getter for
    // it, so the instance registers ITSELF at the one moment both sides
    // can name — `set_client_widget`, which the multicontext calls with
    // the very view the harness asked about.
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
        /// END of the composition, which is every platform's convention
        /// and the rule the scene's frozen caret offset is built on.
        fn preedit_string(&self) -> (glib::GString, gtk4::pango::AttrList, i32) {
            let text = self.preedit.borrow().clone();
            let caret = text.chars().count() as i32;
            (glib::GString::from(text), gtk4::pango::AttrList::new(), caret)
        }

        /// THE CANCELLATION PATH, and it is GTK that walks it. A
        /// programmatic cursor or selection move resets the input method
        /// unconditionally — even for a range identical to the one
        /// already selected, even for a caret placement where the caret
        /// already is (all three measured,
        /// scratchpad/range-probe-linux.md §5). Dropping the preedit
        /// here is what an input method does when it is reset, and it is
        /// how a D4 violation becomes observable.
        fn reset(&self) {
            let had = !self.preedit.borrow().is_empty();
            self.preedit.replace(String::new());
            if had {
                self.obj().emit_by_name::<()>("preedit-changed", &[]);
                self.obj().emit_by_name::<()>("preedit-end", &[]);
            }
            self.parent_reset();
        }

        /// GTK hands the delegate the widget it serves; that is the one
        /// moment this instance and the harness's view can be tied
        /// together, since the multicontext never hands its delegate out.
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
/// extension point — the same channel ibus and fcitx register on, and
/// the only public way to hand a widget a different `GtkIMContext`.
#[cfg(feature = "harness")]
const KAYA_IM_ID: &str = "kaya";

/// Install kaya's input method as this view's, and answer with it.
///
/// TWO PUBLIC CALLS AND NO PRIVATE ONES. `observe_controllers` yields
/// the view's own event controllers; GtkTextView builds a
/// `GtkEventControllerKey` around the very `GtkIMMulticontext` it renders
/// preedit from, and `set_context_id` is that multicontext's documented
/// way to choose a delegate. The delegate is then created by GTK, which
/// is why the instance comes back out of the multicontext rather than
/// being constructed here.
#[cfg(feature = "harness")]
fn install_kaya_im(view: &gtk4::TextView) -> Option<kaya_im::KayaIMContext> {
    // REGISTERED ONCE, and registering is idempotent by GIO's own
    // contract: `g_io_extension_point_register` answers with the
    // existing point when the name is taken, which it always is here —
    // GTK creates this one during init.
    static REGISTERED: std::sync::Once = std::sync::Once::new();
    REGISTERED.call_once(|| {
        use glib::translate::IntoGlib;
        // SAFETY: both calls take a NUL-terminated name (C string
        // literals) and a GType registered by the glib::wrapper! above.
        // The extension point is GTK's own and already requires a
        // GtkIMContext, which this type is.
        unsafe {
            let point = gio::ffi::g_io_extension_point_register(c"gtk-im-module".as_ptr());
            gio::ffi::g_io_extension_point_set_required_type(
                point,
                gtk4::IMContext::static_type().into_glib(),
            );
            // THE LOWEST PRIORITY IN THE POINT, and that is the whole
            // safety argument. GTK picks a DEFAULT input method off this
            // same list when nothing names one, so an implementation
            // registered above the platform's own would silently become
            // every text widget's input method the moment this ran. This
            // one is only ever reached BY NAME, through the
            // `set_context_id` below.
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
        // FORCE THE DELEGATE TO EXIST. A multicontext creates its
        // delegate lazily and hands it the client widget then; without
        // this the instance does not exist until the next key event, and
        // the verb would have nothing to set a preedit on.
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

/// The mark REVEAL scrolls to. A mark and not an iterator on purpose:
/// GTK computes line heights in an idle handler, and `scroll_to_mark`
/// is documented to save the point and finish after line validation
/// while `scroll_to_iter` does not — measured on this backend as the
/// difference between landing at y=264 of a 5600px target and landing
/// at 5560 (scratchpad/range-probe-linux.md §3).
const REVEAL_MARK: &str = "kaya-reveal";

/// The buffer's highlight tag, created on first use.
///
/// ONE TAG FOR THE WHOLE SET, which is GTK's own idiom: a `GtkTextTag`
/// is a style, applied to as many ranges as you like, and re-declaring
/// is `remove_all_tags` plus one `apply_tag` per range — measured at
/// 570us for 400 ranges over a 19k-character buffer, with no `changed`
/// emission and no extra frames.
///
/// A BACKGROUND COLOUR AND NOTHING ELSE, because the background is what
/// the accessibility tree publishes (`bg-color` on the attribute run)
/// and accessibility is where the harness reads. The VALUE is not
/// assertable on this widget: a GtkTextView truncates each channel
/// before scaling, so `#ffe066` and `#ff0000` both read back
/// `65535,0,0` and `#808080` reads as black — a GTK defect, measured
/// twice, and the reason `highlights` keys on the attribute's PRESENCE.
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

/// THE OTHER COORDINATE DIVERGENCE, and it is not a Unicode one.
///
/// `lf()` collapses a `\r\n` into the single `\n` the guest is told
/// about, and GTK's buffer keeps BOTH characters (measured: the buffer
/// holds 6 code points for `ab␍␊cd` where the guest's text is 5,
/// scratchpad/ranges-units.md §3). Every offset kaya carries is into
/// the guest's text, so after one CRLF a declared range lands one
/// position early — and nothing anywhere says so. This is the "ships
/// silently" case of this milestone on linux and it has nothing to do
/// with Unicode: it is reachable from any app that writes a document
/// with Windows line endings into an editor.
///
/// Three walks, one rule, each with the free fast path — a buffer with
/// no CR in it maps one-to-one and the whole question disappears, which
/// is every scene in the tree.
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

/// D2's drop, at the one place on this backend that cannot be late: the
/// buffer's own `changed` handler. Every edit reaches it — a keystroke,
/// a programmatic write, a native undo — and a declared set whose text
/// has moved on is removed with nothing said, because the app
/// re-declares from the fold `text_changed` already drives.
///
/// A COMPARE RATHER THAN A BLANKET DROP, so the invariant it states is
/// the true one: PAINTED OFFSETS WERE VALIDATED AGAINST THE TEXT THEY
/// ARE PAINTED ON. `apply_tag` fires no `changed` (measured — 20 full
/// re-declare cycles produced 0 emissions), so declaring a set can
/// never trip this.
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
    // SAFETY: the key is private to this module and only ever set to an
    // f64 by set_child_track below. `None` is "never laid out by the
    // flex manager", which is a different answer from "was given zero".
    unsafe { widget.data::<f64>(TRACK_KEY).map(|p| *p.as_ref()) }
}

fn set_child_track(widget: &gtk4::Widget, extent: f64) {
    // SAFETY: as above — this is the only writer of the key.
    unsafe { widget.set_data(TRACK_KEY, extent) }
}

/// A container's align mode (the align spec enum's wire values), same
/// object-data pattern as the grow weight: AddChild reads it to stamp
/// children that arrive after the prop did.
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

/// Install the flex layout manager on a container the first time one of
/// its children grows.
///
/// Lazy on purpose. GtkBox lays out perfectly well on its own and does
/// it the way GTK apps do; the only thing it cannot say is "divide the
/// leftover 1:3". So the toolkit keeps the layout until a scene asks
/// for that, and containers that never grow anything never leave GTK's
/// own behaviour. The manager takes the spacing with it, since it owns
/// the gaps once installed.
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
    container_box.set_layout_manager(Some(flex::FlexLayout::new(orientation, 8)));
}

/// Reconcile a child's main-axis alignment with its weight.
///
/// Without this, `grow` on GTK would silently do nothing. GTK applies a
/// widget's own halign/valign *inside* the rect its parent allocated, so
/// a grower still carrying the normalized `Start` alignment would be
/// handed its full share and then shrink itself back to natural size
/// within it — the layout manager's arithmetic correct and completely
/// invisible. `Fill` on the main axis is what makes a child actually
/// occupy what it was given; the cross axis keeps `Start`, which is the
/// normalized default and what makes labels read left-aligned rather
/// than centered in a stretched box.
/// Stamp one child's CROSS-axis alignment from its container's align
/// mode. Grow reconciliation owns the MAIN axis (Fill for growers);
/// this owns the other one, so the two never fight. Baseline maps to
/// GTK's native baseline valign (rows only; the scene rejects it on
/// columns at the root).
fn apply_cross_align(child: &gtk4::Widget, vertical_container: bool, mode: i64) {
    use gtk4::prelude::WidgetExt;
    let align = match mode {
        1 => gtk4::Align::Center,
        2 => gtk4::Align::End,
        3 => gtk4::Align::Fill,
        4 => gtk4::Align::Baseline,
        _ => gtk4::Align::Start,
    };
    if vertical_container {
        // A column's cross axis is horizontal.
        child.set_halign(align);
    } else {
        child.set_valign(align);
    }
}

fn reconcile_grow_align(child: &gtk4::Widget) {
    let Some(parent) = child.parent() else { return };
    // The axis comes from our own manager, never from
    // GtkBox::orientation: once ensure_flex has replaced the box layout,
    // that property belongs to a manager that is no longer there. No
    // flex manager means nothing in this container grows, so there is no
    // alignment to reconcile.
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
}

/// The flex layout manager: GTK's half of the `grow` contract.
///
/// GtkBox cannot express this. Its only knob is the boolean
/// `hexpand`/`vexpand`, and extra space is split *equally* among the
/// children that set it — there is no per-child weight anywhere in the
/// widget, so a 1:3 request is not merely awkward to spell, it is
/// unrepresentable. Hence a real layout manager, which is also the
/// GTK-blessed way to add a layout policy rather than fighting one.
///
/// The policy is the one on [`Prop::Grow`]: weight-0 children take their
/// natural main-axis size, and the growers divide what is left in
/// proportion to their weights, their own natural sizes not entering the
/// division.
mod flex {
    use gtk4::glib;
    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;

    pub struct FlexLayoutInner {
        pub orientation: std::cell::Cell<gtk4::Orientation>,
        pub spacing: std::cell::Cell<i32>,
    }

    // Hand-written rather than derived: gtk4::Orientation has no Default,
    // and ObjectSubclass requires one because GObject constructs the
    // instance before any of our code runs. FlexLayout::new overwrites
    // both fields immediately.
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
            let (mut minimum, mut natural, mut count) = (0, 0, 0);
            let mut child = widget.first_child();
            while let Some(c) = child {
                if c.is_visible() {
                    let (cmin, cnat, _, _) = c.measure(orientation, for_size);
                    if self.is_main(orientation) {
                        // Along the axis the children queue on, extents
                        // add up; across it they overlap, so the widest
                        // child sets the requirement.
                        minimum += cmin;
                        natural += cnat;
                    } else {
                        minimum = minimum.max(cmin);
                        natural = natural.max(cnat);
                    }
                    count += 1;
                }
                child = c.next_sibling();
            }
            if self.is_main(orientation) && count > 1 {
                let gaps = self.spacing.get() * (count - 1);
                minimum += gaps;
                natural += gaps;
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
                        // consulted: the contract is flex-basis 0, so it
                        // starts from nothing and lives on its share.
                        0
                    } else {
                        c.measure(self.orientation.get(), -1).1
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
            let pool: f64 = children.iter().map(|(_, w, _)| *w).sum();

            // Pass 2: place them. The growers' shares are handed out
            // exactly, without clamping to their minimum sizes — the
            // split is the contract, while what a too-small container
            // should do is the overflow policy DESIGN still defers. A
            // clamp here would silently turn 1:3 into something else in
            // a tight window, which is the one failure this whole verb
            // exists to catch.
            let mut offset = 0;
            let mut spent = 0;
            let growers = children.iter().filter(|(_, w, _)| *w > 0.0).count();
            let mut seen = 0;
            for (c, weight, natural) in &children {
                let extent = if *weight > 0.0 {
                    seen += 1;
                    if seen == growers {
                        // The last grower absorbs the rounding dust, so
                        // the children always fill the container exactly
                        // instead of leaving a stray pixel.
                        leftover - spent
                    } else {
                        let share = (leftover as f64 * weight / pool).round() as i32;
                        spent += share;
                        share
                    }
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
                // The track, recorded BEFORE the allocate: what GTK
                // stores on the child afterwards is the box the child's
                // own align and margins shrank it to, and the two
                // together are what expect_fills compares on a widget
                // target.
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

        /// The axis this manager stacks on — the authority now that the
        /// GtkBoxLayout that used to own the property has been replaced.
        pub fn orientation(&self) -> gtk4::Orientation {
            self.imp().orientation.get()
        }
    }

    /// Read a child's main-axis extent as the manager allocated it.
    ///
    /// The allocation, not `width()`/`height()`: those report the CSS
    /// box, which the theme insets inside the allocation — Adwaita takes
    /// 10pt out of a button's height — so they answer "how big is the
    /// widget drawn" when the layout contract asks "how much of the axis
    /// was it given". Reading them turned an exactly correct 25/75 split
    /// into 27/73. Same trap as AppKit's alignment rect versus frame,
    /// and the reason child_shares specifies the layout rect everywhere.
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
    /// THE ONE COMPOSITE KIND WITH A CONTROL INSIDE IT: the multi-line
    /// editor is a `GtkTextView` in a `GtkScrolledWindow`, held in that
    /// order (viewport, control). `Radio(gtk4::Box)` is the precedent
    /// for a kind whose native widget is a container, and the textarea
    /// is the case where the container and the control BOTH have to be
    /// reachable — see `widget` and `control` below.
    Textarea(gtk4::ScrolledWindow, gtk4::TextView),
}

impl NativeWidget {
    /// The widget the LAYOUT sees: what gets parented, ordered,
    /// unparented, grown and measured. For every kind but the textarea
    /// this is the control itself.
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
        }
    }

    /// The widget the USER sees: the control that takes focus, holds
    /// the text, and publishes the accessible role a scene names it by.
    /// Identical to [`NativeWidget::widget`] for every kind whose
    /// native widget IS its control; the textarea's `GtkTextView`
    /// inside its viewport.
    ///
    /// THE SPLIT EXISTS BECAUSE THE TWO ANSWERS DIVERGED, silently, in
    /// exactly four places: the accessible label/hint/id (a name on the
    /// viewport leaves the `text` node unnamed, so `expect_ax
    /// textarea#0` reads `field/` — the a11y scene's canary, §4),
    /// focus (the scroll pane is not the focusable thing), and the
    /// harness `set_text`'s reverse lookup from widget to id (which
    /// found nothing, so a set_text stopped clearing the native undo
    /// history the model claims it clears). Everything else wants the
    /// layout widget.
    fn control(&self) -> gtk4::Widget {
        match self {
            NativeWidget::Textarea(_, view) => view.clone().upcast(),
            other => other.widget(),
        }
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
    /// `icon-name` can be re-applied whenever the chrome is rebuilt.
    /// Not an observation: what the harness would read is the switcher's
    /// own GtkImage, never this.
    symbol: i64,
    root: Option<gtk4::Widget>,
}

struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    widgets: HashMap<WidgetId, NativeWidget>,
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index. GTK fires the real
    // signals for programmatic set_text/set_active/set_value, so the
    // stage drives each control exactly as a user would.
    buttons: Vec<gtk4::Button>,
    checkboxes: Vec<gtk4::CheckButton>,
    labels: Vec<gtk4::Label>,
    entries: Vec<gtk4::Entry>,
    sliders: Vec<gtk4::Scale>,
    images: Vec<gtk4::Picture>,
    scrolls: Vec<gtk4::ScrolledWindow>,
    progresses: Vec<gtk4::ProgressBar>,
    selects: Vec<gtk4::DropDown>,
    radios: Vec<gtk4::Box>,
    grids: Vec<gtk4::Grid>,
    textareas: Vec<gtk4::TextView>,
    /// Grid layout state: ordered children + column count. Children
    /// can arrive BEFORE the columns prop (children-first sugars),
    /// so both paths re-flow the attach positions.
    grid_children: HashMap<u64, Vec<gtk4::Widget>>,
    grid_cols: HashMap<u64, i32>,
    /// Radio plumbing, the select_options shape: label id -> (its
    /// radio's id, its row); the row's REAL widget is the grouped
    /// CheckButton in radio_buttons.
    radio_options: HashMap<u64, (u64, u32)>,
    radio_buttons: HashMap<u64, Vec<gtk4::CheckButton>>,
    radio_tags: HashMap<u64, Vec<u8>>,
    /// Option-label plumbing: label widget id -> (its select's id,
    /// its option row). A select's label children are its OPTIONS —
    /// rows of the DropDown's StringList, not standalone widgets —
    /// so their text lands in the model, and they leave the
    /// harness's label registry.
    select_options: HashMap<u64, (u64, u32)>,
    /// The DropDown's string model per select id (rows appended at
    /// AddChild; text arrives via the label's SetProp).
    select_models: HashMap<u64, gtk4::StringList>,
    /// Echo guard for EVERY interactive kind: GTK's change signals
    /// (changed, toggled, value-changed, notify::selected) cannot
    /// tell a user act from a programmatic write, and only the USER
    /// path may emit an occurrence — a property write is state
    /// configuration, never an event (without this, a handler that
    /// writes back a different value than it received ping-pongs
    /// through the native signal forever). Armed around every
    /// SetProp write to an interactive widget and the select's
    /// model appends (GTK auto-selects row 0 when the first item
    /// lands). Commands (clear) and the harness stage's direct
    /// writes stay unguarded ON PURPOSE: a command acts like the
    /// user, and both must reach the app through the widget's own
    /// path.
    apply_quiet: std::rc::Rc<std::cell::Cell<bool>>,
    /// Q2's bracket, spelled GTK (docs/undo-plan.md §3, the
    /// "report a routed native undo ONCE" rule): while this is set, a
    /// text change still EMITS — the field is uncontrolled and the app
    /// must hear it — but is NOT banked, because this backend routed
    /// the undo and reports it with its own sample through
    /// `note_native_undo`.
    ///
    /// A FLAG AND NOT THE MAC ARM'S TEXT-MATCHED ECHO, because the two
    /// reports are adjacent here: GTK's `changed` fires SYNCHRONOUSLY
    /// inside the undo activation (measured — the arm's G0), so a
    /// bracket set and cleared around that call cannot be outlived by
    /// the edit it is bracketing. SwiftUI needed the text match because
    /// its binding pushes a runloop turn later.
    ledger_quiet: std::rc::Rc<std::cell::Cell<bool>>,
    /// A4's answer for the ENTRY, which GTK gives no getter for: the
    /// text widgets whose NATIVE undo stack has something in it.
    ///
    /// A GtkTextBuffer publishes `can-undo`; the GtkText behind a
    /// GtkEntry publishes nothing at all, and its action muxer is
    /// private (measured — `activate_action("text.undo")` answers TRUE
    /// on an empty history, so it is not a proxy either). What kaya CAN
    /// see is every event that moves that stack, because there are only
    /// two: an edit through the platform's own input path fills it (the
    /// `changed` handler below), and any programmatic write empties it
    /// (measured, and the single chokepoint is `clear_native_undo`).
    /// This set is that model, and it is the backend fact the core
    /// cannot derive — not a second copy of the ledger.
    native_dirty: std::rc::Rc<RefCell<std::collections::HashSet<u64>>>,
    /// D2 SPELLED GTK: per textarea, the text its declared highlight set
    /// was validated against (docs/ranges-plan.md D2). Membership IS the
    /// "a set is declared" flag; the ranges themselves are not kept,
    /// because the buffer holds them and the read goes to the platform.
    ///
    /// THE COMPARE IS WHY THIS EXISTS AT ALL, and on this backend it is
    /// not belt-and-braces. A GtkTextTag range lives in the buffer's
    /// b-tree and is anchored to the TEXT: typing three characters ahead
    /// of a tagged range MOVES the range (measured,
    /// scratchpad/range-probe-linux.md §4). Tracking is exactly what D2
    /// refuses to ship — a stale set would keep painting, shifted, until
    /// the app happened to declare something else — so the set is
    /// dropped the moment the recorded text stops being the buffer's
    /// text, in the buffer's own `changed` handler, which is the one
    /// place on this backend that cannot be late.
    highlight_text: std::rc::Rc<RefCell<HashMap<u64, String>>>,
    /// The LIVE input-method preedit per textarea, straight off GTK's
    /// own `GtkTextView::preedit-changed` — which carries the input
    /// method's string as its argument, so this is the platform
    /// reporting its own state and not kaya remembering its intent.
    ///
    /// It answers the D4 question (`ApplyOp::SelectRange` is refused
    /// while a composition is live) and it is the second half of the
    /// `selection` read: GTK renders the preedit out of the LAYOUT and
    /// never puts it in the buffer (measured — the probe's §5 left
    /// `char_count` at 4 with a live preedit), so the buffer's caret
    /// offset alone does not describe where the caret is on screen.
    preedit: std::rc::Rc<RefCell<HashMap<u64, String>>>,
    /// Indeterminate bars pulse on a shared ticker (GTK's activity
    /// mode is pulse-driven, not a property); membership here IS the
    /// indeterminate flag the observation reads.
    indeterminate: std::rc::Rc<RefCell<std::collections::HashSet<u64>>>,
    columns: Vec<gtk4::Box>,
    rows: Vec<gtk4::Box>,
    window: gtk4::Window,
    /// Auxiliary surfaces by kaya window id (the primary is
    /// `window`); created hidden, presented at mount.
    aux_windows: HashMap<u64, gtk4::Window>,
    /// veto_close per window id (primary included; default false).
    window_veto: std::rc::Rc<RefCell<HashMap<u64, bool>>>,
    /// Live navigation entries by surface id, and per-window stacks
    /// bottom to top (DESIGN.md, Navigation): the top entry is the
    /// window's visible child; the window's own root and title come
    /// back when its stack empties.
    nav_entries: HashMap<u64, GtkNavEntry>,
    nav_stacks: HashMap<u64, Vec<u64>>,
    /// list_detail per window (wprop 6; DESIGN.md, Adaptive
    /// list-detail): does this window ASK for the adaptive
    /// presentation of its stack. Whether it GETS one is the size
    /// class's answer, resolved in refresh_nav.
    list_detail: HashMap<u64, bool>,
    /// The presentation refresh_nav ACTUALLY rendered, per window —
    /// stamped by the arm that ran, never derived from `list_detail`
    /// or the width, so expect_split cannot agree with the lowering by
    /// construction.
    split_presentation: HashMap<u64, &'static str>,
    /// The live AdwNavigationSplitView per window. It answers whether it
    /// collapsed, which is the only honest reading of which presentation
    /// happened once GNOME owns that decision.
    split_views: HashMap<u64, adw::NavigationSplitView>,
    /// Sections (DESIGN.md, Sections): per-window ordered sets, page
    /// containers by section id, the GtkStack that materializes the
    /// switcher, and the selection mirror. A section's page swaps
    /// between its own root and its stack's top entry (stacks are
    /// per-surface; nav_stacks keys sections too).
    sections: HashMap<u64, Vec<u64>>,
    section_pages: HashMap<u64, GtkSectionPage>,
    section_stacks: HashMap<u64, gtk4::Stack>,
    /// The assembled chrome per window: (presentation it was built
    /// for, the container) — rebuilt only when the hint changes.
    section_chrome: HashMap<u64, (i64, gtk4::Box)>,
    /// The arm that ACTUALLY assembled that chrome, per window —
    /// stamped inside each branch of refresh_sections, never derived
    /// from the hint below, so expect_sections_presentation cannot
    /// agree with the lowering by construction (the split_presentation
    /// rule, one construct over). The read pairs it with the widget the
    /// branch left behind; see rendered_sections_arm.
    sections_rendered: HashMap<u64, &'static str>,
    selected_sections: HashMap<u64, u64>,
    sections_presentation: HashMap<u64, i64>,
    /// The window's OWN mounted root and title, restored on pop.
    window_roots: HashMap<u64, gtk4::Widget>,
    window_titles: HashMap<u64, String>,
    /// The header-bar back button per window — GTK's back affordance
    /// (the ViewSwitcher-era header pattern); visible only while the
    /// window's stack has entries.
    back_buttons: HashMap<u64, gtk4::Button>,
    /// The unsaved-work marker per window — the bullet label beside the
    /// header-bar title (install_nav_chrome), shown exactly while the
    /// window's `dirty` prop is true.
    ///
    /// THE WIDGET IS THE STATE. There is deliberately no `dirty` map
    /// beside this one: the prop's whole observable is the marker's
    /// visibility, and a model copy would only be something for
    /// `window_dirty` to agree with itself about (the read goes to the
    /// accessibility tree for exactly that reason).
    dirty_markers: HashMap<u64, gtk4::Label>,
    /// The window content inset (wprop 8, docs/styling-plan.md D3):
    /// the value behind the `.kaya-root` CSS padding, kept here because
    /// TWO consumers need the number and the stylesheet cannot be read
    /// back — the wprop arm rewrites the provider, and the harness's
    /// `offer` observation subtracts it from the root's allocation
    /// (offer = what the root's children are actually proposed).
    inset: f64,
    /// The provider holding the `.kaya-root` padding, kept to rewrite
    /// when the inset moves.
    inset_css: gtk4::CssProvider,
    /// A CONTAINER's own inset (prop 17, the window inset one level
    /// down): its own provider, holding one `kaya-inset-N` rule per
    /// distinct value any container has asked for, and the set of values
    /// those rules cover. Separate from `inset_css` for the brand's
    /// reason — the window arm rewrites that one whole and would erase
    /// these — and rewritten only when a value appears that no rule
    /// covers yet.
    container_inset_css: gtk4::CssProvider,
    container_insets: BTreeSet<i64>,
    /// THE BRAND ACCENT (docs/styling-plan.md D1), in the two pieces the
    /// lowering needs: its own provider — separate from `inset_css`,
    /// which the inset arm rewrites whole and would otherwise erase the
    /// brand — and the derived values themselves, kept because the
    /// stylesheet holds ONE appearance's numbers at a time and has to be
    /// rewritten when the system flips light/dark. Shared with the
    /// `dark` notify handler, which is why it is an Rc rather than a
    /// plain field.
    brand: Rc<RefCell<Option<crate::brand::BrandAccent>>>,
    brand_css: gtk4::CssProvider,
    /// THE BRAND TYPEFACE (docs/styling-plan.md Slice 2b), in the two
    /// pieces this backend's arm needs.
    ///
    /// ITS OWN PROVIDER, and never `brand_css`: `load_kaya_css` replaces
    /// a provider's ENTIRE content, and `brand_css` is rewritten from
    /// scratch by the appearance notify handler above, out of
    /// `brand_css_for()` alone. A `font-family` parked in that provider
    /// would vanish the first time the session flipped light/dark, with
    /// no error anywhere — the silent failure this slice exists to
    /// prevent (scratchpad/styling/typeface-gtk.md §1).
    typeface_css: gtk4::CssProvider,
    /// The family THIS platform asked for (the `linux` row of the
    /// request, or its default), kept because the read needs BOTH
    /// numbers to tell its two causes apart: a resolved family that is
    /// not the request means either "the rule applied and fontconfig has
    /// no such family" or "the rule never reached the widget", and the
    /// resolved family alone is the same string in both (probe §3).
    typeface_request: Option<String>,
    /// The last typeface diagnosis this process printed. `expect_typeface`
    /// polls for 15 seconds at 20ms, so an undeduplicated diagnosis would
    /// bury the failing verdict under ~750 identical lines; what is worth
    /// printing is a CHANGE of state.
    #[cfg(feature = "harness")]
    typeface_said: RefCell<Option<String>>,
    /// Where kaya's own stylesheets report their parse errors, read by
    /// `load_kaya_css` immediately after each load.
    css_error: Rc<RefCell<Option<String>>>,
    /// The live modal alert (one per process): the request's identity
    /// plus the REAL dialog object for the runner's reads. Shared with
    /// the choose callback, which clears it when the one result fires.
    live_alert: std::rc::Rc<RefCell<Option<GtkLiveAlert>>>,
    /// The live file picker, and the directory the next one opens on.
    ///
    /// THE DIRECTORY IS ARMED, NOT SET: a dialog's initial folder is
    /// read when it is PRESENTED, so the harness's file_dialog_goto
    /// stores it here and the apply arm applies it. Setting it on a
    /// dialog already on screen is silently ignored, and a picker aimed
    /// at nothing falls back to its last-used location — the failure
    /// that cost a session on macOS and is guarded the same way here.
    live_file_dialog: std::rc::Rc<RefCell<Option<GtkLiveFileDialog>>>,
    pending_dialog_dir: std::rc::Rc<RefCell<Option<String>>>,
    /// The command-catalog registry (DESIGN.md, Menus): items, bars,
    /// anchors. Rc'd so the GSimpleAction handlers reach the mirror
    /// without borrowing CORE (see the menus section comment).
    menus: Rc<RefCell<MenuRegistry>>,
    /// The GMenu model per window — the object the PopoverMenuBar
    /// renders and menu_count reads; rebuilt in place on catalog
    /// mutations.
    menu_models: HashMap<u64, gio::Menu>,
    /// The bar strip per window: (strip, content slot). Present only
    /// once a catalog anchored; set_window_content routes through it.
    menu_strips: HashMap<u64, (gtk4::Box, gtk4::Box)>,
    /// Auxiliary windows' "win"-prefixed action groups (the primary is
    /// a GtkApplicationWindow and exports "win" itself).
    menu_action_groups: HashMap<u64, gio::SimpleActionGroup>,
    /// Context attachments by anchor widget id.
    context_menus: HashMap<u64, GtkContextMenu>,
    /// The OPEN context menu's anchor: taken by the gesture and the
    /// context_open verb, cleared by activation or chrome dismissal.
    /// While set it owns path resolution EXCLUSIVELY (the
    /// interpreters' rule). Rc'd: the popover's closed handler clears
    /// it without borrowing CORE.
    open_context: Rc<RefCell<Option<u64>>>,
    /// EVERY TOUCH OF THE CLAIM ABOVE, so that a failure can say what
    /// cleared it and when.
    ///
    /// menus-java-wayland flaked once with `no such menu item Remove`,
    /// which is the BAR route reporting that the claim was None at the
    /// moment the harness activated a CONTEXT item. Eighty-six attempts
    /// to reproduce it failed — six full lane runs, fifty-three of the
    /// leg alone, twenty of the whole menus family under contention —
    /// and two mechanisms were proposed and DISPROVED (the claim is set
    /// synchronously, so it is not late; and removing the scene's
    /// intervening expect, which should have made a destroy-races-open
    /// theory near-certain, still passed).
    ///
    /// So the next occurrence has to answer the question itself. Five
    /// places touch the claim and any of them could be the one; the
    /// trail names which, with the elapsed time, and the panic prints
    /// it. Rc'd for the same reason the claim is: the popover handlers
    /// clear it without borrowing CORE.
    #[cfg(feature = "harness")]
    context_trail: Rc<RefCell<Vec<(std::time::Instant, &'static str, Option<u64>)>>>,
    /// The clipboard hub (see ClipboardHub): accepts lists, paste
    /// tags, focus resolution, and the armed flag the harness's
    /// serial primer consults. Rc'd because menu-role action handlers
    /// reach it without borrowing CORE, the menus rule.
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
        while let Ok(tx) = core.transactions.try_recv() {
            for op in core.scene.apply(tx) {
                apply(core, op);
            }
        }
        // A transaction can be an undo GROUP, and a group is a ledger
        // entry: Edit>Undo's enablement moved with it. The clipboard
        // roles' refresh list (focus, clipboard, role/accepts, copy)
        // has no member that fires here, so the undo roles add the one
        // moment that is theirs.
        refresh_roles(core);
    });
}

/// The chrome-close grammar: a veto_close window emits
/// close_requested and stays; a non-veto auxiliary closes and
/// reports window_closed; the non-veto primary exits with the app
/// (GTK quits when the application window closes).
/// The live alert's identity and its REAL dialog: title reads come
/// from the AlertDialog object, and choose_alert finds the presented
/// dialog window's actual button to activate.
/// The live file dialog: what the harness needs to find it in the
/// accessibility tree and to know one is up at all. The TITLE is the
/// handle — GTK publishes the dialog as `role=dialog name=<title>` and
/// sets no accessible-id on it, so the title is the only identity there
/// is (measured, not assumed; see the GTK section of docs/traps.md).
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

/// Depth-first search for a button with the given label under a
/// widget — how the runner presses the REAL button inside the
/// presented alert window (gtk::AlertDialog exposes no press API).
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

fn gtk_window(core: &CoreState, id: u64) -> gtk4::Window {
    if id == 0 {
        core.window.clone()
    } else {
        core.aux_windows
            .get(&id)
            .expect("harness targeted an unknown window")
            .clone()
    }
}

/// Install the window's chrome: a HeaderBar carrying GTK's back
/// affordance (the ViewSwitcher-era header pattern; hidden until the
/// window's stack has entries, and the click runs the SAME user-pop
/// path a real press does, so the harness's `back` verb drives the
/// actual button) and the unsaved-work marker beside the title.
///
/// THE MARKER IS THE `dirty` PROP'S WHOLE LOWERING ON THIS PLATFORM
/// (docs/dirty-plan.md D2). GTK4 has no window-level edited/modified
/// affordance at any layer — not GtkWindow's 25 properties, not
/// libadwaita, not xdg-shell, and X11's urgency hint means "demands
/// attention" and has no Wayland counterpart — so kaya draws it. The
/// shape is GNOME Text Editor's own, read from its `editor-window.ui`:
/// a GtkLabel holding U+2022, `visible=false`, sitting in the header
/// bar's title widget BESIDE the title, with the window's title string
/// left completely alone. (The GNOME-2-era "insert an asterisk at the
/// beginning of the window title" rule is HIG 2.2.1 and did not survive
/// the GNOME 40 rewrite; the current HIG says nothing at all about
/// unsaved state. Composing a marker into the title is also D1's named
/// rejection — the declared title is compared byte-for-byte across five
/// platforms, and there are four `set_title` call sites here, three of
/// them on the navigation path, so a composed marker would need a
/// chokepoint the other three could not bypass.)
///
/// Setting a title widget means kaya renders the title itself, so the
/// box carries a `.title` label BOUND to the window's own `title`
/// property — one binding rather than a fifth write, so every existing
/// `set_title` call site keeps working untouched.
///
/// AND THE MARKER CARRIES AN ACCESSIBLE LABEL, which is what makes it
/// observable at all: measured on the bus, an unlabelled bullet
/// publishes as `label name='• '` — a glyph is not a name, so neither a
/// screen reader nor the harness can address it. With the label the node
/// is `label name='Unsaved changes'` (the accessible name REPLACES the
/// glyph, which is also what a screen reader should say), and
/// `Stage::window_dirty` reads exactly that.
fn install_nav_chrome(window: &gtk4::Window, id: u64) -> (gtk4::Button, gtk4::Label) {
    use gtk4::prelude::{ButtonExt, GtkWindowExt, ObjectExt, WidgetExt};
    let header = gtk4::HeaderBar::new();
    let back = gtk4::Button::from_icon_name("go-previous-symbolic");
    back.set_visible(false);
    back.connect_clicked(move |_| {
        CORE.with_borrow_mut(|core| {
            let Some(core) = core.as_mut() else { return };
            user_back(core, id);
        });
    });
    header.pack_start(&back);

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
    // A CenterBox and not a plain Box, which is GNOME's own trick and
    // worth the extra line: the marker EXPANDS into the space to the
    // left of the title and hugs its trailing edge, so appearing and
    // disappearing does not move the title. A Box makes the two a single
    // centered group — measured on this scene, the title stepped 7px
    // right the moment the mark went up, which is a title that twitches
    // while you type.
    let title_box = gtk4::CenterBox::new();
    title_box.set_hexpand(true);
    marker.set_hexpand(true);
    marker.set_halign(gtk4::Align::End);
    marker.set_margin_end(6);
    title_box.set_start_widget(Some(&marker));
    title_box.set_center_widget(Some(&title));
    header.set_title_widget(Some(&title_box));

    window.set_titlebar(Some(&header));
    (back, marker)
}

/// The glyph GNOME's own editor draws for unsaved work, and the name the
/// accessibility tree publishes in its place. The NAME is what the
/// harness matches on (see `install_nav_chrome`); neither string is ever
/// compared across platforms — `dirty` is one declaration with five
/// different chromes (D2), which is why the verb exists at all.
const DIRTY_MARKER: &str = "\u{2022}";
const DIRTY_MARKER_NAME: &str = "Unsaved changes";

/// A user-driven back on the window's top entry: an
/// intercept_back-armed top emits back_requested and nothing pops
/// (the veto class); an unarmed top pops here, reconciles the
/// core-owned stack post-fact, and reports entry_popped.
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

/// Reconcile the window's visible state with its stack: the top
/// entry's root and title (the entry title IS the window title while
/// covered, the NavigationStack semantic), or the window's own root
/// and title when the stack is empty; the back button shows only
/// over entries.
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

    // ADAPTIVE LIST-DETAIL (DESIGN.md). Both halves must hold: the app
    // asked (wprop 6) and the window IS regular — the same 600
    // boundary every other backend draws, read off the real window
    // rather than derived from anything the app said.
    //
    // A plain horizontal Box, deliberately NOT GtkPaned: a paned is a
    // DRAGGABLE splitter, which DESIGN separates from list-detail by
    // name (2/4 native, not admitted). libadwaita's
    // AdwNavigationSplitView is the idiomatic wrapper — animations and
    // AdwBreakpoint for free — but this backend does not depend on
    // libadwaita, and the semantic is expressible without it. That
    // dependency is a ledger item, not a blocker.
    let wants_split = core.list_detail.get(&window).copied().unwrap_or(false);
    // No `top.is_some()` requirement: an empty stack on a regular
    // window shows the leading pane and an EMPTY trailing one
    // (DESIGN.md). Requiring an entry here made GTK report `stacked`
    // where mac reported `split` for the same scene — a semantics
    // divergence, which is never a backend's call to make.
    // NO width test here any more. AdwNavigationSplitView collapses on
    // a BREAKPOINT, and the condition is GNOME's documented one rather
    // than a number kaya invented and then graded itself against.
    if wants_split {
        use adw::prelude::*;
        let base = core.window_roots.get(&window).cloned();
        let detail = top.and_then(|id| core.nav_entries.get(&id)).and_then(|e| e.root.clone());
        if let Some(base) = base {
            let split = adw::NavigationSplitView::new();
            unparent(&base);
            // The sidebar pane is sized by libadwaita's OWN rule now:
            // sidebar-width-fraction with min/max, which is where
            // protocol::leading_pane_width's 25%/180..280 came from in
            // the first place. Adopting the widget means adopting the
            // source rather than the copy.
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
            // show-content is the ONE stack fact the widget is told:
            // whether a detail is open. Everything else about the stack
            // stays in kaya's core, which is what keeps a pop and the
            // widget's pop from being two different truths.
            split.set_show_content(top.is_some());

            // The COLLAPSE decision, handed to GNOME. AdwNavigationSplitView
            // has no default of its own — libadwaita deliberately makes
            // the application declare the breakpoint — so kaya supplies
            // the condition from libadwaita's own documented example
            // rather than choosing a width. A BreakpointBin is what lets
            // a plain GtkApplicationWindow carry one; add_breakpoint
            // otherwise lives on AdwWindow, which this backend is not.
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

            // The user's back, caught where libadwaita reports it.
            // Collapsed, its navigation view draws a back button whose
            // pop sets show-content false; that transition IS the
            // gesture, and it is distinguishable from a resize, which
            // moves `collapsed` and leaves show-content alone (measured
            // on libadwaita 1.7.6 before any of this was written).
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

            // THE BACK AFFORDANCE FOLLOWS THE COLLAPSE, and it has to be
            // driven from here rather than set once below: `collapsed`
            // is the BREAKPOINT's answer, and a breakpoint applies
            // during allocation — at the moment this arm builds the
            // view, nothing has been measured and `is_collapsed` is
            // still false. This is the same shape WinUI needed for
            // ModeChanged, for the same reason.
            //
            // Only the button's visibility, never the whole arm: this
            // fires from inside layout, and re-running the arm here
            // would build a fresh view whose own breakpoint applies and
            // fires it again.
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
            // WITH AN EMPTY STACK THE WINDOW KEEPS ITS OWN TITLE. This
            // used to fall back to the empty string, which is a window
            // with no title at all — the serial arm's None branch below
            // has always used window_titles for exactly this case, and
            // the split arm simply did not. Caught on macOS, where the
            // title bar is read for real and AppKit substitutes the
            // PROCESS NAME for an empty one (2026-07-27).
            let title = top
                .and_then(|id| core.nav_entries.get(&id))
                .map(|e| e.title.clone())
                .unwrap_or_else(|| {
                    core.window_titles.get(&window).cloned().unwrap_or_default()
                });
            target.set_title(Some(&title));
            let collapsed = split.is_collapsed();
            core.split_views.insert(window, split);
            // THE SAME RULE THE SERIAL ARM FOLLOWS: a back button
            // exactly where back reveals something. Two panes reveal
            // nothing, so it is absent there — that IS the two-pane
            // rule, and the harness's `back` refuses a hidden button
            // like any other.
            //
            // This used to hide the button for the whole presentation,
            // on the belief that libadwaita draws its own once
            // collapsed. IT DOES NOT: libadwaita draws that button
            // inside a header bar IT owns (an AdwHeaderBar in the page,
            // normally via AdwToolbarView), and these pages carry the
            // raw scene root. So a collapsed window had no back
            // affordance at all while `back` popped anyway — the
            // harness driving something the screen did not have, which
            // is exactly what the two-pane rule forbids in the other
            // direction. Caught by screenshotting the collapsed window;
            // no lane could see it, because no assertion reads whether
            // an affordance is THERE (docs/deferred.md).
            //
            // Best-effort here and authoritative in the notify handler
            // above: nothing is measured yet at build time, so this is
            // false on a first build and the breakpoint corrects it.
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

/// Assemble (or reassemble on a hint change) the window's sections
/// chrome: a GtkStack of section pages under the presentation's
/// switcher — the header StackSwitcher for auto/bar, GtkStackSidebar
/// for sidebar (the ADVISORY hint, resolved to this platform's
/// spellings). The stack's notify::visible-child is the USER route:
/// a switcher click lands there unguarded, reconciles the core, and
/// emits; programmatic selection rides the echo guard.
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
    // The chrome above is rebuilt from scratch whenever the hint moves,
    // and a rebuilt GtkStackSwitcher mints fresh buttons — so the
    // accessible descriptions have to be re-stamped every time, not
    // once at declare time.
    refresh_section_symbols(core, window);
}

/// The sections half of the semantic icon (docs/styling-plan.md D6):
/// each page's `icon-name`, then the switcher's accessible description.
///
/// TWO MEASURED PLATFORM FACTS, both from the container (GTK 4.18.6,
/// adwaita-icon-theme 48.1), neither recalled:
///
/// 1. `GtkStackSwitcher` renders icon OR title, never both. Its
///    `rebuild_child` builds a GtkImage when the page has an icon-name
///    and a GtkLabel otherwise, and moves the title to the button's
///    TOOLTIP. The probe read `GtkToggleButton label=(null)` over
///    `GtkImage visible=1 mapped=1 icon-name=go-home-symbolic`. So on
///    this backend a section's symbol REPLACES its tab title, where the
///    SwiftUI arm shows a Label with both. GTK's own component owns that
///    choice, the same way the menu dress owns hiding row icons;
///    libadwaita's AdwViewSwitcher is the component that shows both, and
///    adopting it means moving sections onto AdwViewStack — a rewrite of
///    this lowering, not a line of it. Flagged in the arm's report.
/// 2. `GtkStackSidebar` ignores icon-name entirely: it binds only the
///    page's title into a GtkLabel (probe: `GtkListBoxRow > GtkLabel`,
///    no image anywhere). So the SIDEBAR arm draws no symbol at all.
///    Recorded, not worked around — kaya does not hand-build rows inside
///    a component that owns them.
///
/// THE ACCESSIBLE DESCRIPTION goes on the switcher button, and only
/// there, because that is the one place on GTK where kaya's symbol is
/// something a person actually sees. The button's accessible NAME is
/// GTK's own and already carries the title — measured on the AT-SPI bus,
/// `role='page tab' name='Feed'` with no label widget left — so kaya
/// must not overwrite it; the DESCRIPTION was empty (the tooltip does
/// NOT fill it) and is free for the semantic name. Read back off the
/// live bus as `role='page tab' name='Archive' DESC='star'`.
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
            // 0 (no symbol) and nothing else: the wall already refused
            // any value with no row. Cleared through the PROPERTY, not
            // through `set_icon_name("")` — GtkStackSwitcher's
            // `rebuild_child` branches on the name being NULL, and an
            // empty string is not NULL, so the "" spelling would leave
            // the button holding an empty image where the title should
            // be.
            None => {
                use gtk4::glib::prelude::ObjectExt;
                page.set_property("icon-name", None::<&str>);
            }
        }
    }
    // The switcher's buttons are minted from the stack's pages IN PAGE
    // ORDER, which is the order sections were added — so the Nth child
    // is the Nth section. Only the bar arm has buttons; the sidebar arm
    // has a GtkStackSidebar, whose rows carry no icon (fact 2 above) and
    // so have nothing to describe.
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
                    // THE PAIRING IS POSITIONAL, and unlike the menu
                    // read this is a WRITE — no assertion can catch a
                    // description that landed on the wrong button, it
                    // just quietly describes the wrong tab. So the
                    // pairing is checked against the one thing on the
                    // button that came from the page: the GtkImage
                    // GtkStackSwitcher built from its icon-name.
                    // Debug-only and a BACKEND invariant, never a guest
                    // error — the assert_model_actions_resolve
                    // precedent, and the lanes build debug.
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

/// Re-attach a grid's children row-major per its current column
/// count — called when children or the columns prop arrive, in
/// either order (children-first sugars emit adds before the prop).
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
//
// The ratified GTK lowering: one GMenu model per window, rendered by a
// PopoverMenuBar in a strip ABOVE the mounted root (the header bar
// already carries nav chrome; the bar is its own row, the traditional
// Linux shape). Every actionable item is a real window-scoped
// GSimpleAction (`win.kmi-<id>`): enablement is set_enabled, a toggle
// is a stateful bool action, a radio group is ONE stateful action
// whose options are int targets — checkmarks and radio rendering come
// free from GMenu — and shortcuts ride set_accels_for_action, so
// accel display and key dispatch are both native. A context catalog is
// GtkPopoverMenu::from_model on a right-click GestureClick, its
// actions in a per-anchor group ("kayactx" on the anchor widget) so a
// stamped copy's occurrence carries THAT copy's key path — the noun is
// baked into the action's tag at attach time, exactly as stamped
// click tags are (the on_click_node encoding).
//
// One dispatch path: bar chrome, the context popover, accelerators,
// and the harness verbs all activate the same GSimpleAction, whose
// handler mirrors user state FIRST and then emits (docs/traps.md's
// post-user-mirror rule). Programmatic checked/value writes go through
// set_state, which never fires `activate` — the echo doctrine holds
// with no quiet guard. The handlers capture the Rc'd registry and the
// sink, never CORE, so a stage verb may activate them while it holds
// the CORE borrow (the same discipline as every widget signal here).

/// One menu item's retained state: the props mirror (the post-user
/// mirror toggles/radios update BEFORE emitting), the semantic tree,
/// and every live GSimpleAction instance materialized for the item —
/// the bar's window-scoped one, plus one per context attachment — so
/// enabled/checked/value writes reach all of them.
struct MenuItemState {
    kind: MenuItemKind,
    label: String,
    /// The item's OWN flag; what chrome and dispatch honor is the AND
    /// of this and every grouping ancestor's (docs/traps.md).
    enabled: bool,
    checked: bool,
    value: f64,
    /// The CHROME-promotion hint (DESIGN.md, "Chrome promotion and
    /// `primary`"): the first k of these in catalog preorder belong in
    /// this window's chrome. Nothing here reads it YET — the GTK arm is
    /// the AdwHeaderBar pack, and this backend still answers the
    /// toolbar verbs with `depth_stub("toolbar")` (docs/chrome-plan.md
    /// C2, ledgered in docs/deferred.md). It stopped being inert BY
    /// POLICY on 2026-08-17; it is inert here by not having got there.
    #[allow(dead_code)]
    primary: bool,
    /// The semantic icon's wire value (0 = none). Held ONLY so the GMenu
    /// model can be rebuilt from the registry — nothing reads it back as
    /// an observation. `Stage::menu_symbol` reads the GIcon off the
    /// realized row instead, so a lowering that stored this and never
    /// reached the chrome still fails.
    symbol: i64,
    /// A standard-command role from the closed vocabulary ("" = none).
    /// PLACEMENT is inert here (no dress-owned home), but the
    /// clipboard roles change BEHAVIOR: activation performs the
    /// command on the focused widget, and enablement folds in
    /// role_enabled (refresh_roles).
    role: String,
    shortcut: String,
    parent: Option<u64>,
    children: Vec<u64>,
    actions: Vec<gio::SimpleAction>,
}

/// The command-catalog registry. Rc'd so action handlers can reach the
/// mirror without touching CORE (see the section comment).
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
/// ancestor's — the inherited rule every read, render, accel, and
/// activation route shares (docs/traps.md).
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

/// Resolve a `>`-joined label path SEMANTICALLY against root items,
/// labels compared byte-for-byte (the shared-scene contract). A
/// grouping root's label is a path segment whether or not the
/// materialization mints a titled row — an inline nested radio group
/// has none, yet "View>Sort>Date" still lands on Date. `"Sort>Date"`
/// is option Date inside group Sort; `"Sort"` is the group itself.
/// Note a touch of the open-context claim. Bounded: the last sixteen
/// are all anyone reads, and an unbounded trail on a long run is a
/// leak.
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
/// happened — a race is a question about ORDER and INTERVAL, and both
/// are unreadable from a list of ids alone.
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

/// Push inherited enablement into the REAL actions: every instance of
/// every item under `id` carries the AND of its own flag and its
/// ancestors', so native rendering (grayed rows), native dispatch (a
/// disabled GSimpleAction refuses activation), accelerators, and the
/// harness verbs all gate on one state. Grouping nodes have no GAction
/// of their own — GtkPopoverMenuBarItem binds only `label` from the
/// model, so a bar-level header has no sensitivity to bind (nested
/// submenu rows do, but graying only there would make GTK's own two
/// levels disagree). Their reads come from the registry, and the AND
/// below still reaches every command underneath.
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

/// Mirror a radio group's selected index onto every option's action
/// state, in every instance (the bar's and each context attachment's).
/// A radio row is checked exactly when its action's state equals its
/// target, and every option targets its own index, so one shared value
/// drives the whole group's checkmarks.
fn menu_sync_radio_state(reg: &MenuRegistry, group: u64) {
    use gtk4::glib::prelude::ToVariant;
    let state = (reg.items[&group].value as i32).to_variant();
    for &option in &reg.items[&group].children {
        for action in &reg.items[&option].actions {
            action.set_state(&state);
        }
    }
}

/// Create the GSimpleAction for one item — the shared dispatch path's
/// one entry: chrome clicks, accelerators, and harness verbs all
/// activate THIS object, and only its handler emits. `noun` is the
/// anchor's key path (empty for the bar and live-widget anchors).
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
                // A clipboard role PERFORMS rather than reports: the
                // item is the platform's own command acting on the
                // focused widget, so no menu occurrence goes up (the
                // mac arm's rule; DESIGN.md — gestures are commands).
                // The role is read at ACTIVATION time because the
                // prop lands after the action is minted.
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
                // Post-user mirror FIRST (docs/traps.md): the registry
                // and every sibling instance move, then the occurrence
                // goes up — a later rebuild starts from the user's
                // state.
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
            // One stateful action PER OPTION, not one per group. GTK
            // gives an item the radio role when the item carries a
            // target and its action carries state (gtkmenutrackeritem),
            // and it takes the row's sensitivity from that action's
            // enabled flag — which has no per-target form. So options
            // that shared one group action could never gray
            // individually. Per-option actions keep the radio idiom
            // (checked is state == target, and every option's state is
            // the GROUP's selected index) while giving each option the
            // enabled flag the inherited AND already walks onto it.
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

/// The window-scoped action home: the primary IS a
/// GtkApplicationWindow, whose own ActionMap exports the "win" prefix;
/// an auxiliary window is plain, so CreateWindow inserted a group
/// under the same prefix (only GtkApplicationWindow reserves it).
/// Where a window's own actions live — the read side of
/// [`add_window_action`]: the primary IS a GtkApplicationWindow (its
/// own ActionMap exports "win"), an auxiliary carries the group
/// CreateWindow inserted under the same prefix.
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

/// Put the item's semantic icon on a GMenu row.
///
/// `G_MENU_ATTRIBUTE_ICON` is GTK's own slot for this, and it is a
/// SERIALIZED GIcon rather than a name, which is why the themed icon is
/// built here instead of writing a string attribute.
///
/// MEASURED, and the reason this arm claims nothing about pixels
/// (container, GTK 4.18.6, adwaita-icon-theme 48.1): the attribute DOES
/// reach the widget — the realized `GtkModelButton` holds
/// `GThemedIcon object-select-symbolic` — and GTK's menu dress then
/// keeps that image HIDDEN. `gtk_model_button_set_icon` builds the
/// GtkImage and `update_visibility` sets
/// `visible = has_icon && (iconic || !has_text)`, so a row with a label
/// shows the label alone; the probe read `GtkImage visible=0` beside
/// `GtkLabel visible=1 label=Save`. That is GNOME's house style (icons
/// in menus were deliberately dropped), and it is the same fact the
/// `MenuProp::Icon` apply arm has recorded since day one — so kaya fills
/// the platform's slot, and does not fight the dress into painting it.
///
/// It follows that NO accessible description is stamped on a menu row.
/// The description would announce an icon that this platform draws
/// nowhere, and a claim to a user about something they cannot perceive
/// is the accessibility version of a diagnostic printing what it did not
/// measure (CLAUDE.md invariant 3). The section switcher, which DOES
/// paint the glyph, is where the description goes — see
/// `refresh_section_symbols`.
fn set_row_symbol(row: &gio::MenuItem, symbol: i64) {
    if symbol == 0 {
        return;
    }
    let Some(icon) = symbol_icon_name(symbol) else {
        // Unreachable in practice: assert_symbol_icons_resolve has
        // already refused the whole process. Silent rather than a
        // second panic — the first one names the fix.
        return;
    };
    row.set_icon(&gio::ThemedIcon::new(icon));
}

/// A radio group's option rows: each option carries its OWN stateful
/// action plus its index as target — GMenu renders the radio idiom
/// from exactly that shape (target + state), and the per-option action
/// is what lets ONE option gray while its siblings stay live.
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

/// Materialize a child list into a GMenu: plain leaves accumulate in
/// an anonymous section, a separator starts the next one, a nested
/// menu cascades as a real submenu, and a nested radio group lands
/// INLINE as its own labeled section (the ratified compact-grouping
/// shape; its checkmarks ride the group action's targets).
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
                // A nested radio group lands as a LABELED SECTION, and a
                // GMenu section header is not an item — it has no icon
                // attribute to carry a symbol on. Declared and not
                // materialized here; `Stage::menu_symbol` says exactly
                // that rather than inventing an answer.
                into.append_section(Some(&item.label), &options);
            }
            MenuItemKind::RadioOption => {
                unreachable!("scene validated: options live under radio groups")
            }
        }
    }
    flush_menu_section(into, &mut section);
}

/// Rebuild a window's GMenu from the registry: catalogs are small and
/// GMenu items are immutable snapshots, so a full rebuild is the
/// live-label/topology path (the PopoverMenuBar tracks the model
/// OBJECT, which stays). Action state never lives in the model, so a
/// rebuild cannot revert a toggle or radio pick — the post-user-mirror
/// rule holds by construction.
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
            // A TOP-LEVEL holder gets no icon, and that is a measured
            // fact rather than an omission: PopoverMenuBar renders each
            // one as a GtkPopoverMenuBarItem, which binds `label` alone
            // (the note on menu_sync_enabled says the same for
            // enablement) — the probe read its children as exactly one
            // GtkLabel and the popover. Setting the attribute would put
            // an icon in the model that nothing on the bar can draw.
            model.append_submenu(Some(&item.label), &submenu);
        }
    }
    assert_model_actions_resolve(core, window, model);
    refresh_menu_accels(core, window);
}


/// Every action a rendered ROW names must exist in the window's action
/// group. GTK draws a row whose action is missing as insensitive — a
/// user sees a permanently gray command — while a registry-side read
/// happily reports it enabled, so a typo or a stale name in the model
/// is invisible to a state assertion. Walking the model the chrome
/// actually renders closes that gap end to end: model row -> action
/// name -> the group the accel controller and the click path resolve
/// against. Debug-only: the lanes build debug, and this is a BACKEND
/// invariant, never a guest error.
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

/// Every `GtkModelButton` under `root`, in tree order.
///
/// The rows exist BEFORE the menu is ever opened — measured in the
/// container, `GtkModelButton ... visible=1 mapped=0` inside a popover
/// that is neither — which is what lets the harness read a symbol
/// without popping a menu the scene never opens.
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
/// GtkStackSwitcher button actually draws, which is the only thing on
/// that button that came from the page it stands for.
#[cfg(debug_assertions)]
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
/// GtkPopoverMenuBarItem's caption is read, since it publishes no
/// `label` property of its own.
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

/// ONE WIDGET'S TWO FONT NUMBERS: the CSS-computed REQUEST, and the
/// family Pango RESOLVED it to.
///
/// `pango_context().font_description()` IS THE REQUEST AND IT LIES —
/// measured: an unbranded label's context says `Sans` while the text
/// system is using `DejaVu Sans`, and a branded one echoes
/// `KayaNoSuchFamily-9x` back verbatim for a family this image does not
/// have (scratchpad/styling/typeface-gtk.md §2). The honest number comes
/// from LOADING that request and asking the FONT what it is.
///
/// Both are returned because the diagnosis needs both: the resolved
/// family alone is the same string whether the rule applied to a family
/// nobody has installed or never reached the widget at all.
///
/// The face name is cross-checked against the description's (R3 against
/// R2 in the probe, which measured them agreeing in every pass). A
/// disagreement is reported AS one, in a string no scene can assert.
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

/// Every text-bearing widget under the app's windows, read the honest
/// way.
///
/// THE WIDGETS AND NOT THE MODEL, for the reason the whole slice exists:
/// every font API renders SOMETHING for a family it cannot match, so a
/// read that reported what kaya asked for would report a perfect swap for
/// a family that was never installed.
///
/// THE LABELS ARE WHERE THE ANSWER IS. A GtkButton's title is a GtkLabel
/// child and a GtkEntry's editable is a GtkText, so walking to the
/// text-bearing leaf covers every kind the scene puts on screen without
/// naming any of them; a GtkBox's own context would resolve too, and mean
/// nothing.
///
/// `.monospace` IS SKIPPED, DELIBERATELY. It is the one slot libadwaita's
/// stylesheet claims a family for, and `:root` is chosen precisely so
/// that it keeps it (a `*` rule would swap the editor's face). A
/// monospace surface resolving to DejaVu Sans Mono under a serif brand is
/// the design working, so counting it would report a disagreement that
/// kaya chose.
#[cfg(feature = "harness")]
fn walk_typefaces(core: &CoreState) -> TypefaceSeen {
    use gtk4::prelude::{Cast, GtkWindowExt, WidgetExt};
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
    // The CONTENT, not the window: a window's own chrome (the header bar
    // kaya installs, its title) is not the scene's, exactly as the mac
    // read walks the content view and not the title bar.
    for window in std::iter::once(&core.window).chain(core.aux_windows.values()) {
        if let Some(root) = window.child() {
            walk(root.upcast_ref::<gtk4::Widget>(), &mut seen);
        }
    }
    seen
}

/// The answer `expect_typeface` compares, and — when it is not the one
/// the app asked for — a diagnosis printed beside it.
///
/// THE DIAGNOSIS PRINTS ONLY WHAT THIS PROCESS MEASURED, and it exists
/// because the resolved family ALONE cannot tell the two causes apart
/// (invariant 3; the `kayaOpenPanelWhyNot` shape). On this image both
/// failures answer `DejaVu Sans`:
///
/// ```text
/// asked "KayaNoSuchFamily-9x", css "KayaNoSuchFamily-9x", resolved "DejaVu Sans"
///     -> the rule applied; fontconfig has no such family
/// asked "DejaVu Serif",        css "Sans",                resolved "DejaVu Sans"
///     -> the rule never reached the widget
/// ```
///
/// A sentence naming only the resolved family is a sentence printed for
/// both, and the reader would chase whichever it named.
#[cfg(feature = "harness")]
fn typeface_verdict(core: &CoreState, seen: &TypefaceSeen) -> String {
    let answer = match seen.families.len() {
        // A REAL ANSWER AND NOT AN EMPTY STRING: no text-bearing widget
        // is on screen to read, which is a different state from a font
        // that failed to apply, and the sentence says which.
        0 => "no text widget on screen".to_owned(),
        1 => seen.families.iter().next().cloned().unwrap_or_default(),
        // Reporting the first would hide a rule that reached one widget
        // and not another, so a disagreement is reported AS one, naming
        // each widget type — a string no scene can assert.
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
    // never happened. Measured by making the branch print (the
    // empty-walk negative), which is the only way that class of bug is
    // ever seen; it is the `kayaOpenPanelWhyNot` shape exactly.
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
    // ONE LINE PER STATE CHANGE. expect_typeface polls for 15 seconds at
    // 20ms, and 750 copies of one sentence would bury the verdict it is
    // there to explain.
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
/// `primary` IS GTK's <Primary> (kaya adopted the name from GTK), and
/// named keys map onto their keysym names. Total — the root already
/// rejected everything outside the floor, and accelerator_parse
/// validates whatever else a steps script could carry.
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
        // The punctuation set onto X keysym names (the canonical
        // spellings name UNSHIFTED US positions, which is exactly what
        // these keysyms are).
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

/// (Re)register the window catalog's accelerators with the
/// application: accel display beside the items and key dispatch are
/// both native. Item ids are globally unique, so registrations never
/// collide across windows; shortcuts are const-only and items never
/// removed, so nothing needs unregistering.
fn refresh_menu_accels(core: &CoreState, window: u64) {
    let Some(app) = core.app.as_ref() else { return };
    let reg = core.menus.borrow();
    for &root in reg.bars.get(&window).map(Vec::as_slice).unwrap_or(&[]) {
        for id in menu_preorder(&reg, root) {
            let item = &reg.items[&id];
            if item.shortcut.is_empty() {
                continue;
            }
            // Every LEAF command may carry a chord. An option's action
            // is its own and takes the option index as target, so its
            // accelerator names the DETAILED action — GTK's
            // `win.kmi-7(1)` spelling — which is also what the rendered
            // row activates.
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

/// Materialize the window's menu chrome on first use: the
/// PopoverMenuBar over the window's GMenu model in a strip above the
/// content. The window's current child moves into the strip's content
/// slot, and every later content change routes through
/// set_window_content.
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
    let target = gtk_window(core, window);
    if let Some(existing) = target.child() {
        target.set_child(gtk4::Widget::NONE);
        existing.set_hexpand(true);
        existing.set_vexpand(true);
        content.append(&existing);
    }
    target.set_child(Some(&strip));
    core.menu_strips.insert(window, (strip, content));
}

/// Route a window's content through the menu strip when one exists:
/// the bar is chrome above the content, so everything that used to be
/// the window's child — the mounted root, a nav entry's root, the
/// sections chrome — fills the strip's content slot instead. No strip
/// means no menus were declared, and the window keeps GTK's own child
/// slot.
/// The window's live content width in pixels, read from its ALLOCATION
/// rather than from `default_size()`.
///
/// default_size is the size REQUESTED, not the one in effect: under a
/// bare Xvfb with no window manager the two drift apart, and the arm
/// and the assertion then disagree about the same instant — the arm
/// rendered `split` while the read said `compact`, which looks like a
/// lowering bug and is not one. Same lesson the WinUI backend learned:
/// measure the window, and measure it once for both readers.
/// Falls back to the request before the window is mapped, when the
/// allocation is legitimately 0.
fn window_width(core: &CoreState, window: u64) -> i32 {
    use gtk4::prelude::{GtkWindowExt, WidgetExt};
    let target = gtk_window(core, window);
    let allocated = target.width();
    if allocated > 0 { allocated } else { target.default_size().0 }
}

/// Detach a widget from whatever currently holds it. GTK gives a
/// widget EXACTLY ONE parent and asserts loudly on a second
/// (`gtk_window_set_child: assertion ... failed`), and these roots move
/// between the window, the menu-strip content box, and the list-detail
/// split box as the size class changes. Every reparenting path goes
/// through here.
fn unparent(child: &gtk4::Widget) {
    use gtk4::prelude::{BoxExt, Cast, GtkWindowExt, WidgetExt};
    let Some(parent) = child.parent() else { return };
    if let Some(bx) = parent.downcast_ref::<gtk4::Box>() {
        bx.remove(child);
    } else if let Some(win) = parent.downcast_ref::<gtk4::Window>() {
        win.set_child(None::<&gtk4::Widget>);
    } else if let Some(page) = parent.downcast_ref::<adw::NavigationPage>() {
        // A page owns its child through a PROPERTY, so a bare unparent
        // detaches the widget while leaving the page still pointing at
        // it. The pane then lives in no tree the accessibility walk can
        // reach, and `expect_ax` reports it absent while kaya's own
        // model still has it — which is exactly how this presented.
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
            // Expansion is opt-in inside a Box (a bare window child
            // fills by construction): without it the mounted root
            // hugs and every grow weight divides nothing.
            widget.set_hexpand(true);
            widget.set_vexpand(true);
            content.append(widget);
        }
    } else {
        if let Some(widget) = child {
            unparent(widget);
        }
        gtk_window(core, window).set_child(child);
    }
}

/// Attach a context catalog root to a live or stamped widget: a
/// GtkPopoverMenu over the attachment's own model, opened by the
/// platform's own gesture (right-click, button 3), its actions in a
/// per-anchor group so each stamped copy's occurrences carry that
/// copy's key path.
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
        // menu_activate clears it BEFORE its popdown, so this no-ops
        // on the harness path. The Rc keeps this closure off CORE —
        // popdown can run while a stage closure holds that borrow.
        let open = core.open_context.clone();
        #[cfg(feature = "harness")]
        let trail_closed = core.context_trail.clone();
        popover.connect_closed(move |popover| {
            let mut open = open.borrow_mut();
            if *open != Some(widget) {
                return;
            }
            // A CLOSE THAT ARRIVES WITH THE CLAIM STILL SET IS A FAILED
            // PRESENTATION, NOT A DISMISSAL — under the harness, which
            // is the only place this distinction is reachable.
            //
            // Chrome dismissal is a USER doing something (Esc, a click
            // outside), and menu_activate clears the claim BEFORE its
            // popdown, so on the harness path this handler is expected
            // to no-op — the comment above has said so since it was
            // written. There is no user in a scene. So a close landing
            // here means popup() did not keep the menu up, and the
            // right answer is to put it back rather than to release a
            // claim the harness still believes in.
            //
            // MEASURED, not reasoned: menus-{csharp,java}-wayland both
            // failed with `no such menu item "Remove"` and a trail
            // reading `harness context_open -> claimed by widget
            // 9223372036854775811` then `popover closed -> cleared` 0ms
            // before the panic. The anchor is a STAMPED ROW, restamped
            // by the re-render the preceding Rename caused, and popping
            // over a freshly restamped row is what fails. Wayland only;
            // every x11 twin passed. 86 earlier attempts to reproduce
            // it found nothing, and two other mechanisms were proposed
            // and disproved (docs/traps.md).
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

/// The widget id behind a harness target — the reverse of the
/// kind#index registries, by object identity (the registries hold the
/// same native objects the widget map does).
// Harness-only: its sole caller is the Stage impl below, and it speaks
// harness types, so it goes with the harness rather than shipping in a
// user's binary.
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

/// The REAL activation route for a resolved item: the GSimpleAction
/// (and the option index for a radio pick). Grouping nodes and
/// separators have none — chrome opens or ignores them, and so does
/// the verb.
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
            // The option's own action, the same object its rendered row
            // activates — a disabled option refuses the verb exactly as
            // it refuses a click.
            instance(item).map(|a| (a, Some(index)))
        }
        MenuItemKind::Menu | MenuItemKind::RadioGroup | MenuItemKind::Separator => None,
    }
}

// ---------------------------------------------------------------------
// Clipboard (DESIGN.md, Clipboard; docs/clipboard-plan.md §5b for what
// this platform was measured to charge).
//
// The COPY arm is one provider per populated representation, unioned —
// the union advertises all of them, an arbitrary slash-bearing custom
// mime included (measured; a SLASHLESS type is advertised and never
// served, which is why the id grammar is validated at the root). The
// READ arm consults formats() — the offer — and transfers exactly the
// one representation it chooses, answering exactly once; an
// unsatisfiable read answers NOW (measured: GDK fails it in 0ms).
//
// THE FAILURE THIS ARM CANNOT SEE: Wayland lets a client take the
// selection only with an input-event serial, and a headless seat can
// never deliver one — the compositor drops set_content SILENTLY while
// GDK's own bookkeeping reports it set. Nothing here can check that;
// the scene's foreign reader is the only honest observer, and the
// harness primes one serial per leg (ensure_serial_primed) exactly so
// an ordinary GDK arm works in a headless session the way it works in
// a real one.
// ---------------------------------------------------------------------

/// Everything a menu-role activation needs WITHOUT borrowing CORE —
/// the same rule the menus registry follows, and for the same reason:
/// a stage verb activates actions while it holds the core borrow.
struct ClipboardHub {
    /// Accept lists by widget id (the accepts prop; empty = unset =
    /// absent here). The paste split and Paste's enablement both read
    /// it.
    accepts: RefCell<HashMap<u64, String>>,
    /// Identity tags by widget id — the same bytes clicks ride — so a
    /// paste onto a stamped copy carries its noun without a second
    /// registry.
    tags: RefCell<HashMap<u64, Vec<u8>>>,
    /// id -> (widget, is it an editable kind), for resolving which
    /// kaya widget owns focus. Weak: destruction must not need this
    /// map's cooperation.
    widgets: RefCell<HashMap<u64, (glib::WeakRef<gtk4::Widget>, bool)>>,
    sink: OccSink,
    /// A clipboard surface appeared (accepts / copy / read): the
    /// harness primes the wayland serial only for scenes that will
    /// spend one.
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
    /// containing the toplevel's focus widget, because a GtkEntry
    /// delegates to an internal GtkText (the entry itself is never the
    /// focus widget) and every ancestor container "contains" the focus
    /// too.
    ///
    /// THE ACTIVE TOPLEVEL FIRST, AND THEN EVERY OTHER ONE — not the
    /// first toplevel that happens to have a focus widget. Window
    /// activation belongs to the WINDOW MANAGER, and after a modal
    /// dialog closes there may be no active toplevel at all: the lane's
    /// X server has no window manager, and the headless compositor does
    /// not re-activate a parent either. The old fallback committed to
    /// the first toplevel with a focus widget, and a dismissed-but-not-
    /// yet-finalized GtkFileChooser is exactly that — its focus widget
    /// is not one of ours, so this answered None and every caller lost
    /// its subject.
    ///
    /// Measured 2026-08-10 on the editor scene: after File>Open,
    /// `undo_route` saw no focused field and no can-undo, so Edit>Undo
    /// routed to the CORE tier. The core's coarse restore is a
    /// PROGRAMMATIC write, which is `apply_quiet` and reaches no app —
    /// so the document went back on screen while the guest's own model
    /// kept the edit, and `expect_dirty false` failed for fifteen
    /// seconds with the buffer already correct.
    ///
    /// A candidate must still map to one of OUR widgets, so this cannot
    /// invent focus — it only stops giving up early.
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

    /// Whether a clipboard role's command can act right now; a
    /// non-role item answers true and pays nothing. THE SAME RULE AS
    /// THE MAC ARM (kayaRoleEnabled), spelled GTK: paste is the
    /// INTERSECTION of what the clipboard offers and what the focused
    /// widget accepts — a widget that declared NOTHING still pastes
    /// (the platform inserts), so an undeclared target enables on the
    /// text offer alone. Cut and copy need a focused editable with a
    /// selection to give; the widget's own action refuses the rest.
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

    /// Perform a clipboard role on the focused widget. Answers whether
    /// it WAS one, so a plain action falls through to its own
    /// dispatch.
    ///
    /// THE PASTE SPLIT, the rule the whole gesture layer turns on
    /// (DESIGN.md): a widget that DECLARED what it accepts takes the
    /// content itself — the same walk the privileged read makes,
    /// delivered to the paste hook — while one that declared nothing
    /// gets the platform's own insertion ("clipboard.paste", the
    /// action GtkText's own accelerator activates) and its ordinary
    /// change handler reports the result.
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

/// Whether the offer includes text in any spelling a text read can
/// take: the plain mime (with or without GDK's charset aliases) or a
/// same-process string value.
fn clipboard_offers_text(formats: &gdk::ContentFormats) -> bool {
    formats.contain_mime_type("text/plain")
        || formats.contain_mime_type("text/plain;charset=utf-8")
        || formats.contains_type(glib::types::Type::STRING)
}

/// Recompute the GESTURE roles' action enablement. THE MAC FINDING,
/// spelled GTK (docs/clipboard-plan.md §3): enablement is the
/// intersection of what the clipboard offers and what the focused
/// widget accepts, and both move long after the bar was built. The
/// GAction's enabled flag is what grays the row AND what refuses a
/// harness activation, so this runs wherever enablement can change
/// hands: focus moves, the clipboard changes, a role or accepts list
/// lands, a copy goes out — and before a harness menu activation or
/// read. menu_sync_enabled writes the STRUCTURAL enablement alone, so
/// every site that calls it for a role-bearing tree follows with this.
///
/// UNDO AND REDO JOIN THE SAME FILTER, which is the D6 landing note
/// (docs/undo-plan.md): a role outside this set never has its
/// enablement recomputed at all, and on GTK the GAction's flag is also
/// what refuses an activation — so a missing role here is a menu item
/// that nothing can activate. Their enablement moves with the LEDGER
/// rather than with the clipboard, so the ledger's own movers call this
/// too (a transaction drain, a banked edit, an undo).
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
//
// GTK OWNS RAW CONTROLS, which is the whole difference between this arm
// and the mac one. §3a's amendment says every arm must answer "does a
// native undo reach kaya's model here?" BY MEASUREMENT; this backend's
// answer is YES on both kinds, synchronously, on the ordinary `changed`
// signal (measured in the container against the lane's own GTK: an
// undo through GtkText's `text.undo` action and one through
// GtkTextBuffer::undo each moved the text and each emitted `changed`).
//
// So the three channels §3a lists are not this arm's to add — the
// emission already carries a native undo to the app, and it would
// ALSO carry it to the ledger as ordinary typing. The work here is the
// opposite one: SUPPRESS the banking half for an undo this backend
// routed (ledger_quiet) and report it once, with a sample, through
// `note_native_undo`.
//
// D7 IS FREE HERE TOO, and the §0 defect it was written for does not
// exist on this backend: a programmatic `set_text` neither enters the
// native stack nor survives beside it — it WIPES the field's history
// by itself, on both kinds (measured; the same verdict the Windows
// probe reached for TextBox). The explicit clear below is therefore
// documentation of the rule, not the thing that buys it — except at
// A1's call site, where nothing is written and the clear is the whole
// operation.

impl CoreState {
    /// A4's ONE named query — "can the focused widget undo?" — answered
    /// in this platform's vocabulary and asked nowhere else in this
    /// file. The core's `route_undo` consumes it; a second expression of
    /// the same question is the shape A4 exists to refuse.
    ///
    /// THE TWO KINDS ANSWER DIFFERENTLY BECAUSE GTK DOES. A
    /// GtkTextBuffer publishes `can-undo`/`can-redo` and answers for
    /// itself. The GtkText behind a GtkEntry publishes NOTHING — no
    /// getter, and its action muxer is private (measured:
    /// `gtk_widget_activate_action` returns TRUE for `text.undo` even
    /// with an empty history, so it is not a proxy either) — so the
    /// entry is answered from `native_dirty`, this backend's model of
    /// the one thing it cannot read.
    ///
    /// THE MODEL IS EXACT BECAUSE THE STACK HAS ONLY TWO MOVERS, both
    /// of which pass through this file: input through the platform's
    /// own path fills it, and any programmatic write empties it
    /// (measured). Where it could still be stale — a walk that
    /// exhausted the stack without kaya routing it — the ACTIVATION
    /// finds out: an undo with nothing left moves nothing and emits
    /// nothing, which `perform_undo_role` reports as `can_undo = false`
    /// so the core finishes the step coarsely from its own ledger.
    ///
    /// REDO ASKS THE SAME SET, and the imprecision costs nothing: the
    /// core only consults it for a frontier episode it has just seen
    /// walked backwards, where a native redo demonstrably exists.
    fn focused_can_undo(&self, redo: bool) -> bool {
        // The hub already resolves the focused widget across toplevels
        // (a GtkEntry delegates to an internal GtkText, so the entry is
        // never the toplevel's focus widget itself).
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

    /// Whether a text widget's NATIVE undo stack holds anything —
    /// `focused_can_undo`'s question asked about a named widget, which
    /// is what the typing verb needs to prove it typed for real.
    #[cfg(feature = "harness")]
    fn native_undo_filled(&self, id: WidgetId) -> bool {
        match self.widgets.get(&id) {
            Some(NativeWidget::Textarea(_, view)) => view.buffer().can_undo(),
            Some(NativeWidget::Entry(_)) => self.native_dirty.borrow().contains(&id.0),
            _ => false,
        }
    }

    /// Whether a role's command can act right now — the enablement half
    /// of every gesture role, in one place. Undo and redo ask the CORE
    /// (the ledger decides against what this backend can see: what is
    /// focused, and whether that field's own stack has anything); the
    /// clipboard roles ask the hub, as they always have.
    fn role_enabled(&self, role: &str) -> bool {
        match role {
            "undo" => self.undo_route(false) != crate::scene::UndoRoute::Nothing,
            "redo" => self.undo_route(true) != crate::scene::UndoRoute::Nothing,
            _ => self.clipboard.role_enabled(role),
        }
    }

    /// Where an undo (or redo) would go RIGHT NOW.
    ///
    /// ASKED ONCE AND USED TWICE — enablement and activation are the
    /// same question (D6: "enablement is that same question, computed
    /// live at activation exactly as paste's offer∩accepts is"), and
    /// `Nothing` IS what a disabled Edit>Undo means. And the answer is
    /// the CORE's: this backend contributes only the pair it alone can
    /// see, and the ledger decides.
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
    /// window, and failing that the ACTIVE toplevel's — the nearest
    /// thing this platform has to the mac arm's key window, and the
    /// same question `focused_widget_id` already answers for the
    /// clipboard. ASKED IN ONE PLACE because enablement and activation
    /// must not disagree about which history they are talking about;
    /// window 0 always exists, so a coarse answer is never a lost one.
    fn undo_window(&self) -> WindowId {
        self.clipboard
            .focused_widget_id()
            .map(WidgetId)
            .and_then(|id| self.window_of_widget(id))
            .or_else(|| active_window_id(self))
            .unwrap_or(WindowId(0))
    }

    /// Which window's ledger a widget's edits belong to (§3 keeps one
    /// ledger per window). Resolved from the toolkit rather than from a
    /// map kaya would have to maintain: a widget's root IS its window,
    /// and the aux table is small.
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

    /// Reset ONE editable's native undo history — D7's spelling on this
    /// backend, and A1's whole operation.
    ///
    /// Per kind, because GTK gives the two kinds different levers
    /// (both measured to clear a REAL typed history and to touch no
    /// text): the buffer takes an EMPTY irreversible-action bracket,
    /// documented to discard the queue; the entry takes an
    /// enable-undo toggle, which clears and leaves undo enabled.
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

/// D7 + A3 at the quiet-write sites: a programmatic write to a text
/// widget resets THAT widget's native undo history — but only when the
/// write CHANGED the text.
///
/// A3 IS NOT TIDINESS HERE, it is the one thing this backend has to get
/// right about D7: GTK's own `set_text` leaves the history alone when
/// the text is identical (measured), so an app that mirrors a field
/// into a signal and writes it back keeps its typing history — and an
/// unconditional clear from kaya would be the thing that took it away.
///
/// Called from the APPLY ARMS rather than from the writing sites, so an
/// inverse the CORE writes (§3's coarse episode restore) travels the
/// same path a forward write does.
fn note_quiet_text_write(core: &CoreState, id: WidgetId, previous: &str, next: &str) {
    if previous == next {
        return;
    }
    core.clear_native_undo(id);
}

/// The reconciliation sample (§3): what a NATIVE undo left behind.
///
/// The core walks its frontier episode backwards from three facts — the
/// field, the text the walk landed on, and whether the field can still
/// undo — and ends the walk three ways: consumed at the before-image,
/// still open with more to give, or exhausted short of the before-image
/// (the case A1's clear is meant to make unreachable, which falls back
/// to the coarse restore).
///
/// THE THIRD FACT IN BOTH DIRECTIONS is `can_undo`, deliberately, the
/// mac arm's rule for the mac arm's reason: it is not "did this walk
/// have more to give" but the core's exhausted-walk test, and a redo
/// answering `can_redo` there would report false at the end of a
/// forward walk and send the core backwards.
///
/// On this backend the walk's own movement is what answers it for an
/// entry (GTK publishes no can-undo for one): an activation with
/// nothing left moves nothing, measured, so `moved` IS the platform's
/// answer at exactly the moment the core asks.
fn note_native_undo(core: &mut CoreState, field: WidgetId, moved: bool) {
    let Some(text) = core.text_of(field) else { return };
    let window = core.window_of_widget(field).unwrap_or(WindowId(0));
    // CAN-UNDO IN BOTH DIRECTIONS, never can-redo: `can_redo` answers
    // FALSE at the end of a forward walk, and the core would read that
    // as an exhausted BACKWARD walk and coarse-restore to the
    // before-image — undoing the redo it was just told about.
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

/// Perform an undo/redo role on the focused surface. Answers whether it
/// WAS one, so a plain action falls through to its own dispatch —
/// ClipboardHub::perform_role's contract, for the same reason: a role
/// item is the PLATFORM's command, not the app's action.
///
/// ROUTING IS KAYA'S HERE, all of it (§1: "GTK and Compose route in
/// kaya — no platform path exists"). GTK has no responder chain and no
/// Edit-menu resolution of its own: the focused text's `text.undo`
/// action is reachable, and nothing above it is.
///
/// DEFERRED TO AN IDLE, which is this file's standing discipline rather
/// than a hedge: a menu action's handler may run while the harness
/// holds the CORE borrow (the stage's `menu_activate` activates the
/// REAL GAction from inside `on_main`), and both tiers of an undo need
/// `&mut CoreState` — the core tier to apply the inverse, the native
/// tier to hand the core its sample. The clipboard hub's enablement
/// refresh already defers for exactly this reason. Ordering is not at
/// risk: idle sources run FIFO, and every later harness verb is itself
/// an idle queued after this one.
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
                    // THE LEDGER-QUIET BRACKET (Q2). The change this
                    // activation provokes still reaches the app through
                    // the widget's own `changed` — the field is
                    // uncontrolled — and is banked by nobody: this
                    // function reports it once, with the sample below.
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
                    // THE NATIVE TIER MUST ACTUALLY HAVE SOMETHING, and
                    // under the harness that is provable rather than
                    // hopeful. Routing sent this activation at the
                    // field's own stack because the ledger's frontier
                    // episode is live on it and this backend answered
                    // "it can undo"; an activation that moves nothing
                    // means the stack was EMPTY there. In a scene the
                    // only ways that can happen are the two this
                    // milestone must never ship: the characters never
                    // travelled the platform's input path (a `type`
                    // stand-in), or GTK stopped recording typed input.
                    // Both would otherwise be SILENT — the core's coarse
                    // restore below finishes the step and the scene
                    // passes with the native tier untested. (No harness:
                    // a user's own unintercepted Ctrl+Z can empty the
                    // stack legitimately — GtkText's binding is live,
                    // A6's gap — so shipped apps take the fallback.)
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
                        // The stack was empty where this backend's model
                        // said it was not (an undo kaya did not route —
                        // GtkText's own Ctrl+Z is live and unintercepted,
                        // A6's gap on this backend). Correct the model
                        // here, and let the core finish the step.
                        core.native_dirty.borrow_mut().remove(&field.0);
                    }
                    // A REDO THAT MOVED NOTHING IS NOT REPORTED. The
                    // core's third fact is the exhausted-walk test and
                    // it runs BACKWARDS: fed a no-move on the forward
                    // direction it would coarse-restore to the
                    // before-image, which is the opposite of what was
                    // asked. Nothing moved, so the core's picture is
                    // already right.
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
                // Inert: both tiers are empty, and the item reads
                // disabled for the same reason (one question, asked
                // once — the route above IS the enablement).
                crate::scene::UndoRoute::Nothing => {}
            }
            refresh_roles(core);
        });
    });
    true
}

/// Bank one text edit into the ledger (§3's episode banking), off the
/// occurrence the widget just emitted.
///
/// THE TAG RESOLVES THE FIELD, not a captured id: the ledger keys on
/// the widget id a programmatic write would name, and
/// `Scene::text_field_of_tag` is the one resolver that says so — it
/// answers None for a stamped collection row, whose typing is therefore
/// not banked on any backend (uniform by construction rather than by
/// coincidence).
///
/// DEFERRED, like everything else that needs `&mut CoreState` from a
/// widget signal: `changed` fires during apply for a `clear`, and the
/// stage's own `set_text` fires it while the harness holds the CORE
/// borrow. Idle sources run FIFO, so edits bank in the order they
/// happened and before any transaction the guest sends in reply — the
/// occurrence that would provoke one leaves this handler after the bank
/// is queued.
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

/// The kaya text widget holding the keyboard focus IN ONE WINDOW —
/// A1's target, which names a window rather than a widget.
///
/// Resolved from that window's own focus widget rather than from the
/// hub's cross-toplevel answer: a group can commit in a window that is
/// not the active one, and clearing the history of whatever field the
/// user happens to be typing in elsewhere is the exact damage D7's
/// focus guard exists to prevent.
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

/// Whether a text widget holds the keyboard focus, read the way
/// `is_focused` reads it: a focused GtkEntry delegates to an internal
/// GtkText, so the entry itself is never the toplevel's focus widget
/// and FOCUS_WITHIN is the flag that answers.
fn widget_focused(widget: &impl IsA<gtk4::Widget>) -> bool {
    use gtk4::prelude::{Cast, GtkWindowExt, WidgetExt};
    let widget = widget.as_ref();
    if widget
        .state_flags()
        .intersects(gtk4::StateFlags::FOCUSED | gtk4::StateFlags::FOCUS_WITHIN)
    {
        return true;
    }
    // THE SECOND CLAUSE, and the one a session with no window manager
    // needs. GTK keeps both flags above in step with WINDOW ACTIVATION:
    // `gtk_window_set_is_active` runs a focus change over the focus
    // widget and its ancestors, so both CLEAR the moment the toplevel
    // goes inactive — while `gtk_window_get_focus` still names the same
    // widget and keystrokes still land in it.
    //
    // A modal dialog deactivates its parent, and re-activating the
    // parent afterwards is the window manager's job. The lane's X server
    // has none and the headless compositor does not do it either, so
    // after any file dialog the flags never come back.
    //
    // MEASURED 2026-08-10, editor scene, linux/x11, right after
    // File>Open… closed:
    //
    //   widget_focused flags=false win_active=false
    //                  win_has_focus_widget=true
    //
    // What that cost: this function is how a text change is classified
    // as a USER EDIT rather than a programmatic one, so the keystroke
    // after the dialog was banked as programmatic, no open episode was
    // recorded on the field, and `route_undo` therefore sent Edit>Undo
    // to the CORE tier. The core's coarse restore is a programmatic
    // write, which reaches no guest — so the document went back on
    // screen while the app's own model kept the edit.
    //
    // The clause cannot invent focus: the widget must really be its own
    // window's focus widget, or contain it (a GtkEntry delegates to an
    // internal GtkText, which is why containment is the test).
    let Some(window) = widget.root().and_then(|r| r.downcast::<gtk4::Window>().ok()) else {
        return false;
    };
    let Some(focus) = GtkWindowExt::focus(&window) else {
        return false;
    };
    &focus == widget || focus.is_ancestor(widget)
}

/// Choose the RICHEST representation the clipboard offers that the
/// accept list takes, transfer exactly that one, and answer exactly
/// once — None for no intersection or a failed transfer, the
/// universal no. Shared by the privileged read and the declared-paste
/// delivery, because the two differ in their trigger and never in
/// what they can materialize.
///
/// The chooser consults formats() — the OFFER — so no transfer runs
/// for a representation nobody asked for, and the unsatisfiable case
/// answers immediately (measured §5b: a GDK read of an unoffered type
/// fails in 0ms, so no timeout lives here).
///
/// Descending clip value — custom (accept-list order), files, image,
/// html, text — the canonical order (§1), which is preference order
/// on every host that has one.
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
                // The RFC's grammar: CRLF separators (bare LF
                // tolerated), comment lines start with '#'. Only
                // file:// URIs become files — a pasted http link is
                // not a file the receiver may open.
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
                    // The picker's capability, arriving through the
                    // second door: the same registration the file
                    // dialog result makes, so kaya_open_picked
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

/// One mime type's bytes off the clipboard, whole, then the callback —
/// None for a failed transfer (the universal no; GDK fails an
/// unservable read fast, measured §5b).
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

fn apply(core: &mut CoreState, op: ApplyOp) {
    match op {
        ApplyOp::Create { id, kind, tag } => {
            // The clipboard hub's copies, taken before the kind arms
            // consume the tag: focus resolution wants every widget,
            // paste delivery wants the identity tag (stamped copies
            // carry their noun inside it), and the editable flag is
            // cut/copy's enablement answer.
            let clip_tag = tag.clone();
            let clip_editable =
                matches!(kind, WidgetKind::Entry | WidgetKind::Textarea);
            let native = match kind {
                WidgetKind::Entry => {
                    // Uncontrolled: the widget owns its text; each edit
                    // goes up with the entry's identity tag, and the
                    // app folds it into its own model. GTK fires
                    // `changed` for programmatic set_text too, so the
                    // USER/programmatic split rides apply_quiet: the
                    // stage's direct writes and the clear command
                    // emit like a user; SetProp stays silent.
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
                            // AND THE LEDGER HEARS IT TOO (§3's episode
                            // banking), unless this backend routed the
                            // undo that caused it and is reporting that
                            // one itself (Q2's bracket). The focus flag
                            // is sampled HERE, where it is true.
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
                    // Normalized layout default (uniform across backends):
                    // 8-unit spacing between children; the box hugs the
                    // top-left of its parent (Start/Start) rather than
                    // centering/filling. Children are pinned to the
                    // leading edge at natural size on add (see AddChild).
                    let column = gtk4::Box::new(gtk4::Orientation::Vertical, 8);
                    column.set_halign(gtk4::Align::Start);
                    column.set_valign(gtk4::Align::Start);
                    // No flex manager yet, deliberately: GtkBox's own
                    // layout stays until a child actually carries a
                    // weight (see ensure_flex). Replacing it eagerly
                    // would put every scene through our arithmetic and
                    // throw away GTK's own behaviour, when the point is
                    // that each platform flows like itself.
                    core.columns.push(column.clone());
                    NativeWidget::Column(column)
                }
                WidgetKind::Row => {
                    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
                    row.set_halign(gtk4::Align::Start);
                    row.set_valign(gtk4::Align::Start);
                    core.rows.push(row.clone());
                    NativeWidget::Row(row)
                }
                WidgetKind::Checkbox => {
                    // The box owns its checked bit; each flip goes up
                    // with the box's identity tag. GTK fires `toggled`
                    // for programmatic set_active too — the
                    // USER/programmatic split rides apply_quiet (see
                    // that field).
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
                    // Uncontrolled, like the entry: the slider owns its
                    // position; each change goes up with its identity
                    // tag. GTK fires `value-changed` for programmatic
                    // set_value too — the USER/programmatic split
                    // rides apply_quiet (see that field).
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
                    core.labels.push(label.clone());
                    NativeWidget::Label(label)
                }
                WidgetKind::Scroll => {
                    // The vertical scroll viewport over its ONE child
                    // (the scene enforces the count):
                    // GtkScrolledWindow, the platform's own machinery
                    // — its vadjustment is both the observation
                    // source and the API scroll_end drives.
                    let scrolled = gtk4::ScrolledWindow::new();
                    // Vertical-only v1: no horizontal bar, ever.
                    scrolled.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);
                    core.scrolls.push(scrolled.clone());
                    NativeWidget::Scroll(scrolled)
                }
                WidgetKind::Progress => {
                    // Display-only, like Label: no tag, no signal.
                    // Determinate = set_fraction; indeterminate =
                    // GTK's pulse mode, driven by a ticker while the
                    // prop is on (see the SetProp arm).
                    let bar = gtk4::ProgressBar::new();
                    core.progresses.push(bar.clone());
                    NativeWidget::Progress(bar)
                }
                WidgetKind::Textarea => {
                    // The multi-line editor: GtkTextView, the entry's
                    // exact contract — the buffer's `changed` fires
                    // for programmatic set_text too, so the
                    // USER/programmatic split rides apply_quiet.
                    let view = gtk4::TextView::new();
                    // THE SIZING CONTRACT. The editor takes its LAYOUT
                    // size and its content scrolls inside it, which is
                    // what every other kaya widget does and what this
                    // one alone did not: a bare GtkTextView grows to
                    // its content, so 400 lines made a 6400px widget in
                    // a 6692px window — no scrollbar, no keyboard
                    // scroll, the text simply unreachable, and
                    // `scroll_to_mark` returning true while moving
                    // nothing because the view believed the whole
                    // buffer was visible (all measured, GTK 4.18.6,
                    // scratchpad/range-probe-linux.md §3).
                    //
                    // The viewport is the fix, in the ONE shape that
                    // works: the TextView as the DIRECT child of the
                    // GtkScrolledWindow. GtkTextView implements
                    // GtkScrollable, so the scrolled window drives the
                    // view's own adjustments and adds no GtkViewport;
                    // put a Box between them and the view is handed its
                    // natural height again and nothing scrolls (shape C
                    // in the same measurement — which is what an app
                    // gets TODAY by putting a textarea inside kaya's
                    // `scroll` kind).
                    //
                    // The 240x96 minimum moves from the view to the
                    // viewport, because the viewport is now the widget
                    // the parent measures: it keeps the same layout
                    // floor the textarea has always declared, and
                    // `grow` still stretches it through the flex
                    // manager exactly as before.
                    //
                    // ONE AXIS, like kaya's `scroll` kind: vertical
                    // scrolling, never a horizontal bar. Which is only
                    // honest if no line can escape sideways, so the
                    // view WRAPS — WordChar rather than Word so a
                    // single unbreakable token cannot reopen the
                    // unbounded-width half of the same wart. Wrapping
                    // is a rendering decision and touches no
                    // observable: the buffer, `read_text`, and the
                    // AT-SPI Text interface all speak the stored
                    // string, which still holds exactly the newlines
                    // the app wrote.
                    view.set_wrap_mode(gtk4::WrapMode::WordChar);
                    let scroller = gtk4::ScrolledWindow::new();
                    scroller.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);
                    // THE PIN THAT KEEPS THE VIEWPORT A VIEWPORT. Both
                    // default to false, and both are stated because
                    // either one set to true asks the scrolled window
                    // for its CHILD's natural size and restores the
                    // wart this arm exists to remove — the negative
                    // test is in the report, and it is the one pin the
                    // GTK arm has to make (the control's own opinion
                    // set is empty: GTK 4 has no rich-text clipboard
                    // format at all, no spell checker, no autocorrect
                    // and no formatting bindings — audited against the
                    // shipped library, §1 of the report).
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
                    // signal carries the input method's string, so this
                    // is the platform saying what it is displaying —
                    // and when a programmatic selection move resets the
                    // IM context (which GTK does unconditionally,
                    // measured), it arrives here empty and the D4 read
                    // reports the caret where it really is.
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
                        // D2 FIRST, and unconditionally — before the
                        // quiet gate, because a programmatic write
                        // invalidates a declared set exactly as a
                        // keystroke does and the gate is about who
                        // hears the occurrence, not about what is
                        // painted.
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
                    // The 2D layout contract on GTK's own Grid:
                    // columns take their natural width (homogeneous
                    // off is the default), aligned across rows by the
                    // toolkit itself. Attach positions re-flow when
                    // children or the columns prop arrive.
                    let grid = gtk4::Grid::new();
                    core.grid_children.insert(id.0, Vec::new());
                    core.grid_cols.insert(id.0, 1);
                    core.grids.push(grid.clone());
                    NativeWidget::Grid(grid)
                }
                WidgetKind::Radio => {
                    // The choice contract inline: GTK's radio idiom
                    // is grouped CheckButtons (set_group renders the
                    // circle); the group's Box is the widget. Rows
                    // materialize at AddChild; each USER pick emits
                    // with the group's identity tag (toggled fires
                    // for programmatic set_active too, so the picks
                    // ride apply_quiet like every interactive kind).
                    let group = gtk4::Box::new(gtk4::Orientation::Vertical, 4);
                    core.radio_tags
                        .insert(id.0, tag.clone().expect("radio groups carry a tag"));
                    core.radio_buttons.insert(id.0, Vec::new());
                    core.radios.push(group.clone());
                    NativeWidget::Radio(group)
                }
                WidgetKind::Select => {
                    // The dressed floor: GtkDropDown over a
                    // StringList — the select's label children are
                    // its OPTIONS, rows of this model (see AddChild).
                    // Uncontrolled like the slider: each USER pick
                    // goes up with the identity tag; programmatic
                    // writes ride the quiet guard because
                    // notify::selected cannot tell the two apart.
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
                    // Display-only, like Label: no tag, no signal. The
                    // source arrives as a SetProp blob and decodes
                    // there.
                    let picture = gtk4::Picture::new();
                    core.images.push(picture.clone());
                    NativeWidget::Image(picture)
                }
            };
            {
                // THE CONTROL: focus resolution picks the DEEPEST
                // registered widget containing the toplevel's focus
                // widget, so the textarea registers its GtkTextView
                // rather than the viewport around it — the same node
                // the toolkit actually focuses.
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
                NativeWidget::Column(b) | NativeWidget::Row(b) => b.clone(),
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
        ApplyOp::Destroy { id } => {
            // The clipboard hub forgets the widget with it (the weak
            // ref would go stale on its own; the maps must not grow).
            core.clipboard.widgets.borrow_mut().remove(&id.0);
            core.clipboard.tags.borrow_mut().remove(&id.0);
            core.clipboard.accepts.borrow_mut().remove(&id.0);
            // A destroyed anchor takes its context attachment with it
            // (menu ITEMS are never destroyed): the popover unparents
            // BEFORE the widget leaves its container, this
            // attachment's action instances leave the registry's sync
            // lists, and a dangling open-context claim is released —
            // a Remove activation destroys its own anchor (the WinUI
            // lifecycle precedent, docs/traps.md).
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
            let target = if window.0 == 0 {
                core.window.clone()
            } else {
                core.aux_windows
                    .get(&window.0)
                    .expect("scene validated the window id")
                    .clone()
            };
            match (prop, &value) {
                (WindowProp::Title, Value::Str(title)) => {
                    // The window's OWN title; while a navigation
                    // entry covers it the entry's title shows (the
                    // NavigationStack semantic), and this one comes
                    // back at pop.
                    core.window_titles.insert(window.0, title.clone());
                    let covered = core
                        .nav_stacks
                        .get(&window.0)
                        .is_some_and(|s| !s.is_empty());
                    if !covered {
                        target.set_title(Some(title));
                    }
                }
                // The advisory size request. GTK4's one public size
                // verb is set_default_size; under the suites' X11 WM
                // it resizes a mapped window too, and the WM (or a
                // Wayland compositor) keeps the last word — exactly
                // the request semantics (DESIGN.md, Presentation
                // contexts).
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
                (WindowProp::ListDetail, Value::Bool(on)) => {
                    core.list_detail.insert(window.0, *on);
                    refresh_nav(core, window.0);
                }
                // The unsaved-work marker beside the header-bar title
                // (docs/dirty-plan.md D2 — install_nav_chrome carries
                // the reasoning). THE TITLE STRING IS NOT TOUCHED here
                // or anywhere: `target` is not written at all.
                //
                // No materialization hazard to guard, unlike the mac
                // arm's re-apply from `register()`: the marker is built
                // with the window's chrome, so it exists before any
                // transaction can name that window (the scene validates
                // the id, and CreateWindow is what makes one valid).
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
            // normalized 540x330 default and the root inset ride the
            // same paths the primary uses.
            use gtk4::prelude::GtkWindowExt;
            let aux = gtk4::Window::builder()
                .default_width(540)
                .default_height(330)
                .build();
            let (back, marker) = install_nav_chrome(&aux, window.0);
            core.back_buttons.insert(window.0, back);
            core.dirty_markers.insert(window.0, marker);
            wire_close(
                &aux,
                window.0,
                core.window_veto.clone(),
                core.occurrences.clone(),
            );
            // Window-scoped menu actions for a PLAIN window: the
            // primary is a GtkApplicationWindow whose own ActionMap
            // exports "win"; an auxiliary needs the group inserted by
            // hand under the same prefix (safe here — only
            // GtkApplicationWindow reserves it).
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
            // ... and its menu chrome. The registry keeps the items
            // (they are never destroyed); only this window's bar list
            // and materialization go.
            core.menu_models.remove(&window.0);
            core.menu_strips.remove(&window.0);
            core.menu_action_groups.remove(&window.0);
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
            // Programmatic pop: the core already reconciled its
            // stack; drop the top and reconcile the visible state
            // (the batch's NET change shows once drained).
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
            // Append-only: a page container joins the window's stack;
            // the mount fills it. First added is selected (mirrored
            // from the core).
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
            // Programmatic and QUIET: the stack moves under the echo
            // guard, so notify::visible-child stays silent (the echo
            // doctrine — only the user's switch emits).
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
                // GtkStackPage's own `icon-name`, which is the slot both
                // switcher spellings read the page through.
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
            // Registry only: actions and chrome materialize at anchor
            // time, when the item's window (or anchor widget) is
            // known.
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
            // Append-at-any-time: a subtree landing under an anchored
            // root materializes NOW (the rework path appends Publish
            // under the retained Document and the steps activate it
            // with no further nudge).
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
                    // The inherited AND lands on every descendant's
                    // REAL action; no model rebuild — enablement is
                    // live action state. Enablement writes never emit.
                    {
                        let reg = core.menus.borrow();
                        menu_sync_enabled(&reg, item.0);
                    }
                    // menu_sync_enabled wrote STRUCTURAL enablement
                    // alone, which would un-gray a role item whose
                    // clipboard half says no — the role factor goes
                    // back on top.
                    refresh_roles(core);
                }
                MenuProp::Checked => {
                    // QUIET (the echo doctrine): set_state never fires
                    // activate, so the write configures the native
                    // checkmark without an occurrence.
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
                    // QUIET, same as checked (the choice contract's
                    // programmatic side). The state lives on the
                    // OPTIONS' actions, one per option, so the group's
                    // write fans out to all of them.
                    let mut reg = core.menus.borrow_mut();
                    reg.items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .value = crate::protocol::prop_f64(&value);
                    menu_sync_radio_state(&reg, item.0);
                }
                MenuProp::Primary => {
                    // The phone-promotion hint: INERT on desktop by
                    // design (DESIGN.md, Menus) — recorded, never
                    // materialized.
                    core.menus
                        .borrow_mut()
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .primary = crate::protocol::prop_bool(&value);
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
                    // Day-one slot: accepted; GTK's menu dress carries
                    // no item icons and phone promotion is not this
                    // platform (DESIGN.md, Menus — ignored where the
                    // dress has none).
                }
                // THE SEMANTIC ICON NAME (docs/styling-plan.md D6): onto
                // the GMenu row's `icon` attribute, which is GTK's own
                // slot for it. GMenu items are immutable snapshots, so
                // the write is a registry update plus the same full
                // rebuild live labels take.
                //
                // The theme wall runs HERE, on the first symbol any app
                // declares, rather than at window creation: an app with
                // no symbols must not be able to die of an icon theme it
                // never asked for.
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
                    // PLACEMENT is a request this host has nowhere to
                    // honor — no dress-owned application menu — so the
                    // item stays exactly where the app declared it.
                    // BEHAVIOR is not: a clipboard role's activation
                    // performs the standard command on the focused
                    // widget, and its enablement is the offer/accepts
                    // intersection, so the role is recorded and the
                    // role items resync now.
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
            // One provider per populated representation, unioned: the
            // union advertises all of them (measured §5b — it does not
            // let the last provider win, and GTK mints the text
            // aliases and texture shapes for free).
            let mut providers: Vec<gdk::ContentProvider> = Vec::new();
            // Descending clip value — custom, files, image, html,
            // text — the canonical order (§1): a backend offers the
            // values in the order it is handed them and is right.
            for (id, bytes) in &clip.custom {
                providers.push(gdk::ContentProvider::for_bytes(
                    id,
                    &glib::Bytes::from(&bytes.0[..]),
                ));
            }
            if !clip.files.is_empty() {
                // text/uri-list with the RFC's CRLF separators and
                // trailing terminator (measured: the foreign reader
                // is unbothered either way, so the RFC spelling
                // stands).
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
                // RAW BYTES UNDER THE TYPE, never GdkTexture: the
                // texture re-encodes on demand and the bytes stop
                // round-tripping (the macOS writeObjects lesson,
                // measured again here — byte-identical through a
                // foreign read, §5b).
                providers.push(gdk::ContentProvider::for_bytes(
                    "image/png",
                    &glib::Bytes::from(&png.0[..]),
                ));
            }
            if let Some(html) = &clip.html {
                // Raw UTF-8 under the bare type; GDK adds no charset
                // alias for html (measured §5b), and the lane's
                // foreign reader asks for the bare type.
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
                // This error is LOCAL bookkeeping only. The failure
                // that matters — the compositor rejecting the
                // selection for want of an input serial — is silent
                // BY DESIGN and only the scene's foreign reader can
                // see it (§5b finding 3; the harness primes a serial
                // per leg so it does not happen on the lane).
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
                    // Answered exactly once; None IS an answer — the
                    // universal no (denied, absent, unfocused, and
                    // nothing-accepted alike).
                    sink.send(Occurrence::ClipboardResult { request, clip });
                }),
            );
        }
        // A1, THE KEYSTONE (docs/undo-plan.md §3): a core undo group
        // committed, so the focused editable's native history goes with
        // it. The episode was banked before the clear, so nothing is
        // lost but granularity — and every episode after this one
        // therefore begins with an EMPTY native stack, which is what
        // makes "ask the focused text first" and "ask the most recent
        // first" the same question.
        //
        // Targetless by design: the core does not know what is focused,
        // and this backend already asks itself that for role
        // enablement.
        // THE THREE TEXT-RANGE PRIMITIVES (docs/ranges-plan.md D1). All
        // three arrive in GTK'S OWN UNIT — CODE POINTS, converted by the
        // core against the text it validated the byte offsets against
        // (scene.rs `native_offset`) — so there is no Unicode arithmetic
        // anywhere below and there must never be: a `NativeRange` is the
        // only thing an ApplyOp can carry, and it is unbuildable from
        // the wire.
        ApplyOp::HighlightRanges { id, ranges } => {
            let Some(NativeWidget::Textarea(_, view)) = core.widgets.get(&id) else {
                return;
            };
            let buffer = view.buffer();
            // THE BUFFER'S OWN TEXT, read once: the D2 record needs it
            // and so does every offset below, because the buffer keeps a
            // CR the guest was never told about.
            let raw = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string();
            // DECLARATIVE: the set REPLACES the previous one, and an
            // empty list is the clear. `remove_all_tags` is safe to
            // aim at the whole buffer because kaya creates exactly one
            // tag on it.
            buffer.remove_all_tags(&buffer.start_iter(), &buffer.end_iter());
            let tag = highlight_tag(&buffer);
            for range in &ranges {
                // THE UNIT ASSERTION, and it is cheap because GTK is the
                // one backend whose native unit differs from everyone
                // else's: a byte offset that reached here unconverted
                // is an offset into a LONGER string, so it runs off the
                // end of a buffer holding any non-ASCII at all. The
                // ranges scene's document opens with CJK precisely so
                // that a forwarded byte offset is six characters wrong
                // rather than accidentally right.
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
            // mechanism on this backend, since GTK's tags would
            // otherwise follow the next edit rather than being dropped
            // by it.
            core.highlight_text.borrow_mut().insert(id.0, lf(raw));
        }
        ApplyOp::SelectRange { id, range } => {
            let Some(NativeWidget::Textarea(_, view)) = core.widgets.get(&id) else {
                return;
            };
            // D4, AND THIS BACKEND IS WHERE THE HAZARD WAS MEASURED.
            // `select_range` cancels an active composition
            // UNCONDITIONALLY — even when the requested range is the one
            // already selected, even when it is the caret's existing
            // position (scratchpad/range-probe-linux.md §5, all three
            // rows measured). GTK resets the IM context on any
            // programmatic cursor move and asks no questions. So the
            // backend asks them: a live preedit means the user is
            // mid-word, and moving the selection now would take the
            // half-typed syllable away from them. Refused as a no-op
            // under a named reason, never a panic — the app wrote
            // correct code and lost a race with a human being.
            if let Some(preedit) = core.preedit.borrow().get(&id.0) {
                eprintln!(
                    "KAYA_DIAG select_range refused: ime_composition (widget {}, preedit {preedit:?})",
                    id.0
                );
                return;
            }
            let buffer = view.buffer();
            let raw = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string();
            let start = buffer.iter_at_offset(buffer_offset(&raw, range.start));
            let stop = buffer.iter_at_offset(buffer_offset(&raw, range.stop));
            // The insert mark goes FIRST, so the caret lands at the end
            // of the range — the direction a search result is selected
            // in. `selection_bounds()` normalizes either way; the marks
            // are what keep the direction.
            buffer.select_range(&stop, &start);
        }
        ApplyOp::SetTypeface(request) => {
            // THE BRAND TYPEFACE, GTK's half (docs/styling-plan.md Slice
            // 2b): one `:root { font-family }` rule in kaya's own
            // provider at APPLICATION priority. Every mechanic here was
            // measured on the lane image, both display backends
            // (scratchpad/styling/typeface-gtk.md).
            //
            // THE ROW IS PICKED HERE because a LOWERING IS ITS PLATFORM
            // while a binding is not (the JVM says "Linux" on Android).
            // `family_for` walks the pairs once for every backend, and
            // `this_platform()` is the compiler's own answer to which
            // row is ours.
            let family = request.family_for(crate::wire::this_platform()).to_owned();
            // FONT BYTES: registered with the live text system BEFORE
            // the name machinery runs, and the family that registration
            // named is what the rule then asks for —
            // register-then-resolve, so both forms of the request share
            // one lowering, one observation and one fallback (the plan's
            // Slice 2b paragraph). NOT fontconfig's app-font API, which
            // this position cannot use at all: see register_font_blob.
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
            // libadwaita's documented app override, written into kaya's
            // own provider (brand_css_for carries the spelling and the
            // reasoning). The request is recorded first: the appearance
            // can flip afterwards, and the notify handler re-lowers from
            // exactly this value.
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
            // selection change, no `changed`, and no interference with a
            // composition (measured: a `scroll_to_mark` mid-preedit left
            // the preedit alive and the commit intact). Undo does not
            // restore it.
            //
            // THE VIEWPORT IS THE FOUNDATION'S, and without it this arm
            // could not exist: a bare GtkTextView grows to its content,
            // so its page size equals its content height, and
            // `scroll_to_mark` returned TRUE while moving nothing — the
            // worst kind of no-op.
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
            // GNOME's own save panel, and it is the SAME OBJECT the picker
            // builds — gtk::FileDialog asked to `save()` rather than
            // `open()`. So everything around it is already the picker's
            // and none of it is written twice: the one-live-dialog slot,
            // the retire path, the FileDialogResult occurrence, the
            // armed-directory rule, the advisory filters, and the
            // DISMISSED-to-empty mapping that spells cancel. What differs
            // on this backend is exactly two lines — the initial name, and
            // the SOURCE the answer is registered as.
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

            // The name the panel OPENS with, in its name field, which is
            // the one thing a user sees that a picker has not got. Also
            // advisory: the user types over it, and the guest reads the
            // name it GOT (protocol::SaveDialogSpec).
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
                    // A DESTINATION, NOT A PICKED FILE, and that is the
                    // whole of docs/save-plan.md D1 on this backend. GTK
                    // answers with a path to a file NOBODY HAS MADE
                    // (measured: `exists=false` when the callback runs),
                    // so registering the picker's `PathSource` here would
                    // hand the guest a handle that refuses in every mode
                    // with ENOENT — measured too, on this lane, before the
                    // milestone existed. `SaveDestination` creates.
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
                    // error the open arm already maps to an empty list, so
                    // `Ok(...)` above yields nothing and the guest sees
                    // `Msg::Saved(None)`.
                    crate::capi::file_dialog_retire(dialog_id);
                    sink.send(Occurrence::FileDialogResult {
                        dialog: crate::protocol::FileDialogId(dialog_id),
                        files: picked,
                    });
                },
            );
        }
        ApplyOp::PresentFileDialog(spec) => {
            // GNOME's own picker: gtk::FileDialog (4.10+), presented on
            // the requesting window and answered exactly once through
            // capi::file_dialog_resolved — the shared retire path.
            //
            // IN OUR PROCESS, measured: with no xdg-desktop-portal
            // installed GTK presents its own chooser rather than handing
            // off, so the harness reads it on the same a11y bus as every
            // other widget. A portal-hosted picker would be a different
            // application on that bus; the read walks from the desktop
            // and would still find it, but nothing here depends on that.
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

            // Cancel is the EMPTY LIST, faithfully: GTK reports a
            // dismissed picker as an error (DISMISSED), and no platform
            // can confirm an empty selection, so there is no sentinel to
            // invent (DESIGN.md, File dialogs).
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

            // NOT file_dialog_shown here: scene.rs marks the dialog
            // live when the op is applied, for every backend at once.
            // Calling it again is a second registration and the liveness
            // guard says so — which is how this was caught.
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
            // The platform's REAL modal dialog: gtk::AlertDialog maps
            // the vocabulary 1:1 (buttons in order, cancel-button
            // index, async choose -> index). Answered exactly once
            // through capi::alert_resolved — the shared retire path.
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
            // The result must ride THIS backend's sink (the guest
            // listens there — Mpsc for a Rust guest, the ring for a
            // C one); capi::alert_retire is only the liveness gate.
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
                    // An option label's text lands in its DropDown
                    // row (the model is what the popup and the
                    // collapsed button both render) — or its radio
                    // row's CheckButton label.
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
                    // Quiet: a property write is configuration, not a
                    // user edit (see apply_quiet).
                    //
                    // The before-image is read one line before the
                    // write, which is the last moment it exists — D7's
                    // clear is gated on it having CHANGED (A3).
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
                // THE UNIVERSAL PROPS. Every other arm keys on a
                // (kind, prop) pair because every other prop names
                // something only some controls have; these name
                // something every element has, so they match the prop
                // alone and reach the widget through
                // NativeWidget::control.
                //
                // THE CONTROL AND NOT THE LAYOUT WIDGET, which is the
                // same node for every kind but the textarea, and for
                // that one is the difference between naming the
                // `text` node an assistive client reads and naming the
                // `scroll pane` wrapped around it (§4's negative test:
                // route this to `widget` and `expect_ax textarea#0`
                // reads `field/` instead of `field/Notes`).
                //
                // The LABEL is a real accessible property — it is what
                // an assistive client speaks, and setting it OVERRIDES
                // whatever the control derived from its own content, so
                // an unset label must never be written as "".
                (w, Prop::A11yLabel, Value::Str(label)) => {
                    use gtk4::prelude::{AccessibleExt, AccessibleExtManual};
                    if !label.is_empty() {
                        let widget = w.control();
                        // Promote a CONTAINER to a semantic group. GTK
                        // made GtkBox's role GENERIC in 4.12 (it was
                        // GROUP before), and GENERIC is documented as "a
                        // nameless container with no semantic meaning" —
                        // so a label set on one simply does not surface
                        // as an AT-SPI name. Naming a container IS the
                        // app declaring it a group, which is the same
                        // rule WinUI enforces (an unnamed Grid has no
                        // automation peer) and what the ARIA guidance
                        // says: unnamed containers are flattened, named
                        // ones are groups.
                        //
                        // EVERY container kind, not just row and column:
                        // measured 2026-07-25 over AT-SPI, a named grid
                        // and a named radio group both stayed role
                        // `panel` with an EMPTY name, and a named scroll
                        // stayed `scroll pane`, also nameless. The radio
                        // group is here because its accessibility shape
                        // IS a container — a group of radio buttons,
                        // which is what every other platform publishes
                        // for it too.
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
                        // AN AUTHORED NAME MUST WIN. GTK's name
                        // computation reads the LABELLED_BY relation
                        // FIRST and the label property second
                        // (gtkatcontext.c), and a control that points a
                        // relation at its own content therefore
                        // outranks anything an app sets: a named select
                        // read back as `combo box name='Red'`, its
                        // selected option, with the authored "Color"
                        // ignored (measured 2026-07-25 over AT-SPI,
                        // through a re-apply on notify, on map and on a
                        // later timeout — none of them could win a
                        // precedence fight). Dropping the relation is
                        // what makes the property the answer.
                        widget.reset_relation(gtk4::AccessibleRelation::LabelledBy);
                        widget.update_property(&[gtk4::accessible::Property::Label(
                            label.as_str(),
                        )]);
                    }
                }
                // The IDENTIFIER has no GTK setter and no reader below
                // 4.22 (gtk_accessible_get_accessible_id landed there;
                // this build pins v4_10 and Debian trixie ships 4.18).
                // The widget NAME is what GTK's AT-SPI backend publishes
                // for a widget's identity, so that is where it goes —
                // and it is what the AT-SPI reader will match on.
                // The HINT: GTK's DESCRIPTION property, which AT-SPI
                // publishes as the description — the slot for what
                // acting on the control does. Same empty-means-unset
                // rule as the label.
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
                // ACCEPTANCE IS PER-WIDGET (DESIGN.md, Clipboard): the
                // list drives the paste split and Paste's enablement,
                // both read off the hub. Kind-agnostic like the
                // universal props — the scene validated the string.
                // Empty means unset, the universal prop rule.
                (_, Prop::Accepts, Value::Str(list)) => {
                    if list.is_empty() {
                        core.clipboard.accepts.borrow_mut().remove(&id.0);
                    } else {
                        core.clipboard.accepts.borrow_mut().insert(id.0, list);
                    }
                    core.clipboard.armed.set(true);
                    refresh_roles(core);
                }
                // SEMANTIC EMPHASIS (docs/styling-plan.md D4): what the
                // widget MEANS, lowered to the platform's OWN name for
                // it. libadwaita ships both button affordances as
                // documented style classes — there is no `.brand-action`
                // and inventing one would mean writing colors, which is
                // leaving the tier — so the lowering is the class and
                // nothing else. WHICH variant may reach which kind is
                // the root's check (scene.rs: a destructive label dies
                // at declare time), so these two arms see only the
                // variants that belong to them.
                //
                // Both classes are removed before one is added: the two
                // emphases are mutually exclusive in libadwaita's own
                // stylesheet, and a re-applied role would otherwise
                // leave the previous one stacked underneath.
                //
                // The legal variants sit in the PATTERNS, so a role on a
                // kind it does not fit falls to this match's catch-all
                // and dies naming the prop and the value — the same
                // sentence any other impossible pair gets.
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
                // THE HEADING ROLE IS TWO FACTS AT ONCE, the same two
                // every backend lowers it to: the platform's heading
                // TEXT STYLE and the platform's heading ACCESSIBLE role.
                //
                // `.heading` and not `.title-1`..`.title-4`: those are a
                // SIZE ladder (measured — .title-2 and .title-3 are the
                // same size and differ only in weight), and one role has
                // no business picking a level out of it. `.heading` is
                // libadwaita's own name for "this text heads something",
                // at the base size, which is the class SwiftUI's
                // `.headline` corresponds to.
                //
                // The accessible role is the half a scene can read. A
                // style class does not touch it (measured: a `.title-1`
                // label still publishes `label`), so without this line
                // the role would be invisible to every assistive client
                // AND to `expect_ax` — GTK 4.18 maps HEADING to
                // ATSPI_ROLE_HEADING, which is what the steps freeze.
                (NativeWidget::Label(label), Prop::Role, Value::I64(3)) => {
                    use gtk4::prelude::{AccessibleExt, WidgetExt};
                    label.add_css_class("heading");
                    label.set_accessible_role(gtk4::AccessibleRole::Heading);
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
                    // GTK's activity mode is pulse-driven, not a
                    // property: a ticker pulses every armed bar; the
                    // membership set is also what the observation
                    // reads. Turning it off restores the fraction
                    // display (set_fraction repaints the bar).
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
                    // The container's own inter-child gap; the flex
                    // manager reads the Box spacing at allocate time,
                    // so both layout paths follow it.
                    container.set_spacing(gap.round() as i32);
                }
                // THE CONTAINER'S OWN PADDING (prop 17), all three kinds
                // the root allows it on. The CSS box carries it, not the
                // layout: GTK hands a layout manager the CONTENT size
                // and places its children from the content origin, so
                // both of this backend's layout paths — GtkBox's own and
                // kaya's FlexLayout — inset their children with no code
                // here (measured, docs/styling-plan.md D3).
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
                    // gdk::Texture::from_bytes reads encoded PNG/JPEG.
                    // A failed decode yields the placeholder class (no
                    // paintable, image_size reads 0x0), never a panic.
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
            // DropDown's model, never widgets in a container. The
            // native label stays unparented (its SetProp text lands
            // in the model row) and leaves the harness's label
            // registry — options are the select's data, so they must
            // not shift every later label's index. The append rides
            // the quiet guard: GTK auto-selects row 0 when the first
            // item lands, and that notify is not a user pick.
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
                // CheckButton rows, never standalone widgets. The row
                // initializes from the label's CURRENT text
                // (children-first sugars set it before this AddChild)
                // and the label leaves the harness's label registry.
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
            // Normalized layout default: children sit at natural size on
            // the leading edge. GtkWidget's default halign is Fill, which
            // stretches a child to the full cross-axis extent (and makes
            // labels read as centered-in-fill); Start pins it left/top at
            // its intrinsic size instead.
            child_widget.set_halign(gtk4::Align::Start);
            child_widget.set_valign(gtk4::Align::Start);
            // ... then the container's align mode overrides the cross
            // axis for children arriving after the prop did.
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
                NativeWidget::Column(column) => column.append(&child_widget),
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
            // The root fills its window, as it does on every other
            // backend — AppKit's contentView and UIKit's root view fill
            // by construction, while a GTK child obeys its own align and
            // would otherwise hug its content in the top-left corner.
            // Without this there is no leftover space anywhere in the
            // tree, so every grow weight in the scene divides nothing.
            root_widget.set_halign(gtk4::Align::Fill);
            root_widget.set_valign(gtk4::Align::Fill);
            root_widget.add_css_class("kaya-root");
            // The target is a SURFACE: a navigation entry presents
            // in-window (the push already stacked it; the mount fills
            // it), the primary is the window's own root, an auxiliary
            // presents its window.
            if core.section_pages.contains_key(&window.0) {
                // A section presents in-window: added to the set
                // already; the mount fills its page.
                core.section_pages.get_mut(&window.0).unwrap().root =
                    Some(root_widget);
                refresh_section_pane(core, window.0);
                // ... AND SO DOES ITS WINDOW, when that window is an
                // auxiliary. A window that presents sections mounts
                // into its SECTIONS and never into a root, so the
                // "mounting presents" arm below cannot fire for it: the
                // window was built, filled and titled, and nothing ever
                // showed it. Sections on an aux window were
                // unmaterializable here until the sidebar-coverage
                // scene asked for one (2026-08-15; the SwiftUI
                // interpreter had the same hole, found the same day).
                // A section's mount is that window's mounting-presents
                // moment.
                let owner = core.section_pages[&window.0].window;
                if owner != 0 {
                    use gtk4::prelude::GtkWindowExt;
                    core.aux_windows
                        .get(&owner)
                        .expect("scene validated the section's window")
                        .present();
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
                core.aux_windows
                    .get(&window.0)
                    .expect("scene validated the window id")
                    .present();
                core.window_roots.insert(window.0, root_widget);
            }
        }
        ApplyOp::Command { id, command } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match command {
                CommandKind::Clear => {
                    // A command ACTS LIKE THE USER (unlike a property
                    // write): apply_quiet stays off here on purpose, so
                    // GTK's `changed` carries the empty edit to the app
                    // through the widget's own path — the entry
                    // scene's second-add round depends on exactly
                    // this echo.
                    //
                    // It is still a PROGRAMMATIC write for D7's
                    // purposes: what it destroys is widget-owned text
                    // the user did not delete, so the edit history that
                    // described it goes too.
                    let previous = core.text_of(id).unwrap_or_default();
                    match widget {
                        NativeWidget::Entry(entry) => entry.set_text(""),
                        NativeWidget::Textarea(_, view) => view.buffer().set_text(""),
                        _ => panic!("kaya: clear on a non-text widget (scene validates kinds)"),
                    }
                    note_quiet_text_write(core, id, &previous, "");
                }
                CommandKind::Focus => {
                    // grab_focus is per-window (the toplevel's focus
                    // widget), so parallel tiled suite legs cannot
                    // steal each other's focus assertions. The
                    // materialization class (see traps.md): an
                    // unmapped widget cannot take focus and the bool
                    // is discarded — a mount-tx focus would silently
                    // drop. Not mapped yet: one-shot re-grab from the
                    // widget's own map signal.
                    //
                    // THE CONTROL, not the layout widget: the
                    // textarea's viewport is not the focusable thing
                    // inside it, and `expect_focused textarea#0` reads
                    // the GtkTextView.
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
/// FATAL rather than silent.
///
/// `GtkCssProvider::parsing-error` fires with a precise section for a bad
/// property, a bad color and a bad selector, and it is the only signal
/// GTK gives that the string it was handed did not do what it said. It is
/// also NECESSARY AND NOT SUFFICIENT, measured both ways by the styling
/// research: `var(--kaya-no-such-variable)` raises nothing and silently
/// inherits, so this catches "kaya's CSS is malformed" and never "the
/// variable name is one libadwaita does not read". The second question
/// belongs to a rendered pixel, which is where this arm's verification
/// went (scratchpad styling/fanout-gtk.md).
///
/// The error is recorded and the panic raised HERE rather than in the
/// handler: `load_from_data` calls it synchronously, and unwinding out of
/// a Rust panic through GTK's C frames is not something to do for a
/// diagnostic. Every string that reaches this function is kaya's, never
/// the app's — an unparseable one is kaya's bug, so it dies naming both
/// the stylesheet and the fix.
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

/// A CONTAINER's own inset (prop 17): the space between its bounds and
/// its children, lowered onto the container's CSS box.
///
/// A TRANSPARENT BORDER, NOT `padding` — the one spelling in this file
/// GTK's cascade chose rather than kaya. This backend mounts the root
/// with no wrapper of its own, so `.kaya-root`, which carries the WINDOW
/// inset, sits on the very widget a root container's own inset lands on,
/// and two `padding` declarations on one widget do not add: the later
/// provider simply wins. Measured — a root under `.kaya-root { padding:
/// 16px }` plus a second provider's `padding: 8px` places its children
/// 8 in, and the window's 16 is gone with no error anywhere. Every other
/// backend NESTS the two (SwiftUI's KayaRoot pads around the mounted
/// view and the node's own `.padding(node.inset)` sits inside it; Compose
/// the same), so the numbers add there. A border is a different CSS box,
/// so they add here too (measured: 16 + 8 puts the content 24 in), it is
/// subtracted from the content the same way padding is, and being
/// transparent it draws nothing. Nothing else in kaya's GTK stylesheet
/// writes a border, and Adwaita gives a plain box or grid none.
///
/// ONE RULE PER DISTINCT VALUE in one display-level provider, rather than
/// a provider per widget: `gtk_style_context_add_provider` is GTK4's
/// per-widget route and it is deprecated, and the class route is the one
/// the window inset already takes. Per VALUE and not per widget because
/// the stamped case is the one that scales — a thousand collection rows
/// inset by 8 share one rule — and the sheet is rewritten only when a
/// value nothing has asked for yet arrives.
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
///
/// Three variables and no fourth. `--accent-bg-color` is the accent as a
/// background (what `.suggested-action` fills with), `--accent-fg-color`
/// the foreground that sits on it, `--accent-color` the STANDALONE
/// variant — accent-colored text on a neutral surface, which needs a
/// different number than a fill and which libadwaita's own docs say must
/// be set alongside the background or it goes stale. All three are read
/// straight out of the appearance's `DerivedAccent`: the core's
/// derivation is the one place the color math lives, so this backend
/// re-derives nothing. In particular it does NOT use libadwaita's
/// documented per-widget recipe
/// `oklab(from var(--accent-bg-color) var(--standalone-color-oklab))`,
/// which the research measured producing an out-of-gamut GdkRGBA (a
/// negative green channel) for a saturated seed.
///
/// CUSTOM PROPERTIES ONLY, NEVER `@name`. The two spellings are not
/// aliases: `@accent_bg_color` still parses on 4.18.6 and resolves to the
/// SYSTEM accent even while `--accent-bg-color` is overridden (measured).
/// Mixing them yields a half-branded window with no error anywhere.
///
/// One appearance at a time, because GTK CSS has no appearance selector:
/// libadwaita switches by swapping its own stylesheet, so kaya writes the
/// CURRENT appearance's values and rewrites them when the system flips
/// (the `dark` notify wired in `run_core`). `AdwStyleManager:dark` is a
/// read of the SESSION's preference, which that object answers correctly
/// — unlike its accent getters, which report the system accent even after
/// an app override succeeds and must never be used to verify one.
fn brand_css_for(accent: crate::brand::BrandAccent, dark: bool) -> String {
    let a = if dark { accent.dark } else { accent.light };
    format!(
        ":root {{\n  --accent-bg-color: #{:06x};\n  --accent-fg-color: #{:06x};\n  \
         --accent-color: #{:06x};\n}}\n",
        a.fill, a.on_fill, a.standalone
    )
}

/// THE BRAND TYPEFACE, GTK's half (docs/styling-plan.md Slice 2b): one
/// inherited `font-family`, and nothing else in the sheet.
///
/// `:root`, NEVER `*`, and the two are not interchangeable. `*` matches
/// the `.monospace` element itself and beats libadwaita's own rule for
/// it, so a brand family would swap the face of every monospace surface —
/// kaya's own text editor among them. `:root` sets an INHERITED value
/// that the theme overrides exactly where it means to: extracting
/// libadwaita 1.7's compiled stylesheet shows `.monospace` and its four
/// row variants are the ONLY selectors in the whole theme that declare a
/// font-family, and GTK's built-in Adwaita declares none at all
/// (scratchpad/styling/typeface-gtk.md §1, measured both ways).
///
/// THE FAMILY AND NOT THE SCALE, which is what makes this route the right
/// one: nine surfaces across the type ramp were measured identical in
/// size and weight to the pixel, branded and unbranded. The rejected
/// alternative — `GtkSettings:gtk-font-name` — moves every size with the
/// family, because the theme's ramp is relative to the settings font
/// size, and it stomps a session-global setting from inside an app.
fn typeface_css_for(family: &str) -> String {
    format!(":root {{\n  font-family: {};\n}}\n", css_string(family))
}

/// A family name as a CSS string token.
///
/// The name is the APP's, so it is the one string in kaya's stylesheets
/// that this process did not write, and an unescaped `"` in it would end
/// the token and let the rest of the name become declarations. CSS's own
/// escape rules answer it: a backslash before `"` and `\`, and a
/// `\<hex><space>` for anything a CSS string cannot carry literally.
///
/// A family kaya cannot escape correctly does not fail quietly here: the
/// resulting sheet goes through `load_kaya_css`, whose `parsing-error`
/// watcher panics naming the stylesheet. Absence is the other half —
/// a family that is merely NOT INSTALLED is perfectly valid CSS and
/// raises nothing at all, which is what the resolved-family read is for.
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

/// FONT BYTES, GTK's half: register the blob with the live text system
/// and answer with the family it registered under, so the name machinery
/// above takes over unchanged (register-then-resolve, the plan's Slice 2b
/// paragraph). `None` when the file added nothing this process can name,
/// and the caller then asks for the family the app itself named.
///
/// PANGO'S ROUTE AND NOT FONTCONFIG'S, and the difference is measured
/// rather than stylistic. `FcConfigAppFontAddFile` — the documented
/// app-font API, and the one the probe brief expected — RETURNS SUCCESS
/// AND DOES NOTHING once GTK has started: registered before
/// `Application::run`, the family joins the map and resolves; registered
/// anywhere after it (inside `activate`, right after `present()`, or a
/// frame later) the call still returns 1, the family never appears in the
/// realized `PangoFontMap`, and the request falls back to DejaVu Sans.
/// `pango_font_map_changed()` does not help. Measured three ways this
/// session; the whole apply path sits on the wrong side of that line,
/// because a typeface arrives in the first transaction, which is drained
/// after `activate`.
///
/// `pango_font_map_add_font_file()` (Pango 1.56, the lane image's 1.56.3)
/// adds the file to the realized `PangoCairoFcFontMap` GTK is already
/// using, at any time: measured HIT in the same position where the
/// fontconfig route silently missed. That is why this crate names pango
/// directly and asks for `v1_56` (see crates/kaya/Cargo.toml).
///
/// THE FILE, not the bytes: Pango's API takes a path, so the blob is
/// written to a temp file named after its own content — same bytes, same
/// path, so repeated runs reuse one file rather than piling up — and left
/// there for the process's life, because the text system keeps reading
/// it.
fn register_font_blob(core: &CoreState, bytes: &[u8], named: &str) -> Option<String> {
    use gtk4::pango::prelude::{FontFamilyExt, FontMapExt};
    use gtk4::prelude::WidgetExt;
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    let path = std::env::temp_dir().join(format!("kaya-font-{hash:016x}"));
    // NEVER TRUNCATE THE SHARED NAME IN PLACE. The path is content-named
    // and shared by every process shipping these bytes, and freetype
    // MAPS it: an `fs::write` here is open(O_TRUNC), which drops the
    // file to zero length under any process that already has it mapped,
    // and that process then dies of SIGBUS (BUS_ADRERR — a page past the
    // truncated EOF) the next time Pango touches a cold page. Measured
    // 2026-08-16: the linux lane runs its legs in a parallel pool, and
    // typeface-java-wayland crashed inside libfreetype exactly this way
    // while a sibling leg re-wrote the file (hs_err mapped the faulting
    // address to /tmp/kaya-font-e67019d22467d0da). So: skip when the
    // bytes are already there, and otherwise write a UNIQUE temp name
    // and rename() it in — the directory entry flips atomically and the
    // old inode stays alive for every process that mapped it. The winui
    // arm learned the same lesson the same day (Windows refuses the
    // overwrite outright, os error 1224); POSIX permits it, which is
    // worse, because it turns the collision into a crash in whoever got
    // there first.
    let already = std::fs::read(&path).is_ok_and(|have| have == bytes);
    if !already {
        let staged = path.with_extension(format!("stage-{}", std::process::id()));
        let write_then_rename = std::fs::write(&staged, bytes)
            .and_then(|()| std::fs::rename(&staged, &path));
        if let Err(why) = write_then_rename {
            // A DIAGNOSIS AND NOT A PANIC: the app's brand is chrome,
            // and a read-only temp directory is the host's problem, not
            // a reason to refuse to start. The sentence names the path
            // and the OS error, and the resolved-family read still
            // reports the truth.
            let _ = std::fs::remove_file(&staged);
            eprintln!(
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
        eprintln!(
            "KAYA_DIAG brand typeface: pango refused {} ({} bytes): {why}",
            path.display(),
            bytes.len()
        );
        return None;
    }
    let after: std::collections::BTreeSet<String> =
        map.list_families().iter().map(|f| f.name().to_string()).collect();
    // WHICH FAMILY DID THE FILE BRING? Three answers, and each says which
    // it is rather than guessing:
    //   1. the app's own family row, if the file put it in the map — the
    //      app named the face inside its own file, which is the only
    //      unambiguous answer for a file carrying several;
    //   2. the one family that appeared, when the app named none;
    //   3. nothing nameable, and the caller falls back to the app's name
    //      with the numbers printed.
    if after.contains(named) && !before.contains(named) {
        return Some(named.to_owned());
    }
    let mut fresh = after.difference(&before);
    match (fresh.next(), fresh.next()) {
        (Some(one), None) => Some(one.clone()),
        (Some(one), Some(two)) => {
            eprintln!(
                "KAYA_DIAG brand typeface: {} added {} families ({one}, {two}, …) and the \
                 request names {named:?}, which is not among them — kaya asks for {named:?} \
                 and the resolved-family read reports what the text system does with it",
                path.display(),
                after.difference(&before).count()
            );
            None
        }
        (None, _) => {
            eprintln!(
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
        // constructed, and the list-detail arm constructs one. Safe to
        // call more than once, and it must come after GTK is up, which
        // inside activate it already is.
        adw::init().expect("libadwaita init");
        let Some((occ_tx, tx_rx)) = ends.borrow_mut().take() else {
            return;
        };
        let window = gtk4::ApplicationWindow::builder()
            .application(app)
            .title("kaya milestone 2")
            .default_width(540)
            .default_height(330)
            .build();
        // The normalized root inset: 16 units INSIDE the root, via the
        // CSS box (padding sits inside the allocation, so the root
        // still fills its window and expect_root_fills holds — margins
        // would shrink the allocation instead and break it). The class
        // is stamped on the mounted root in the Mount arm.
        let css_error: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
        let css = gtk4::CssProvider::new();
        watch_css_errors(&css, &css_error);
        load_kaya_css(&css, "root inset", ".kaya-root { padding: 16px; }", &css_error);
        // The brand's own provider, EMPTY until a SetBrand arrives: an
        // app that requests no accent must leave the platform's own
        // alone, and an empty provider contributes nothing at all.
        //
        // APPLICATION priority (600) for both, which is the whole
        // vocabulary's position on Linux: it outranks libadwaita's own
        // stylesheet (THEME, 200) and the settings-derived values (400),
        // and it LOSES to the user's `~/.config/gtk-4.0/gtk.css` (USER,
        // 800). Losing there is D2 holding structurally with no code —
        // "the app requests a brand accent; a platform may let its user
        // override it" — and on this platform the user's own stylesheet
        // is that override.
        let brand_css = gtk4::CssProvider::new();
        watch_css_errors(&brand_css, &css_error);
        // The brand TYPEFACE's provider, EMPTY until a SetTypeface
        // arrives, for the accent's reason and one more of its own: an
        // app that requests no family must leave the platform's face
        // alone, and this provider is ADDED ONCE and rewritten in place
        // rather than replaced. The probe measured the alternative —
        // create-and-swap a provider per change — silently failing to
        // apply on one pass of a seven-pass sequence, reproducibly, with
        // `parsing-error` never firing (typeface-gtk.md §1, "the
        // provider lifecycle").
        let typeface_css = gtk4::CssProvider::new();
        watch_css_errors(&typeface_css, &css_error);
        // The container inset's provider, EMPTY until some container
        // asks for one — a scene where nothing is inset contributes no
        // rule at all (see set_container_inset).
        let container_inset_css = gtk4::CssProvider::new();
        watch_css_errors(&container_inset_css, &css_error);
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
        }
        let inset_css = css.clone();
        // The accent is written for the appearance the session is in
        // RIGHT NOW, so a session that flips has to be re-lowered. This
        // is not the runtime theme-SWITCHING surface the plan declines
        // (§2): the app still states its brand once, before the first
        // mount; what moves is the platform underneath it, and following
        // it is what every other backend's arm does too (the SwiftUI one
        // recomputes its tint from the current appearance on each pass).
        //
        // The handler holds the derived values and the provider directly
        // rather than reaching for CORE: a notify can arrive at any
        // point in a main-loop turn, including one where CORE is already
        // borrowed by an apply.
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
            });
        }
        let (primary_back, primary_marker) = {
            use gtk4::prelude::Cast;
            install_nav_chrome(window.upcast_ref::<gtk4::Window>(), 0)
        };
        window.present();

        #[cfg(feature = "harness")]
        if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
            crate::harness::spawn(&scene, GtkStage, |line| println!("{line}"));
        }
        // A build WITHOUT the harness feature must not silently ignore
        // KAYA_SELFTEST. The feature is off by default so users do not
        // ship the scene interpreter, which means a runner that forgets
        // `--features harness` would otherwise start the app, run no
        // steps, print no verdict, and hang until its timeout — the
        // silent-no-op shape this repo keeps paying for. Fail loudly
        // instead, naming the fix.
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
                scene: Scene::new(),
                occurrences: occ_tx.clone(),
                aux_windows: HashMap::new(),
                nav_entries: HashMap::new(),
                nav_stacks: HashMap::new(),
                list_detail: HashMap::new(),
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
                back_buttons: {
                    let mut buttons = HashMap::new();
                    buttons.insert(0, primary_back);
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
                    markers.insert(0, primary_marker);
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
                    // Enablement moves when the clipboard or the focus
                    // does (the mac finding, §3) — and BOTH signals can
                    // fire mid-apply while CORE is borrowed (set_content
                    // raises changed synchronously; grab_focus runs in a
                    // SetProp arm), so each defers to an idle rather than
                    // re-borrowing here and now.
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
                buttons: Vec::new(),
                checkboxes: Vec::new(),
                labels: Vec::new(),
                entries: Vec::new(),
                sliders: Vec::new(),
                images: Vec::new(),
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
                select_models: HashMap::new(),
                apply_quiet: std::rc::Rc::new(std::cell::Cell::new(false)),
                ledger_quiet: std::rc::Rc::new(std::cell::Cell::new(false)),
                native_dirty: std::rc::Rc::new(RefCell::new(std::collections::HashSet::new())),
                highlight_text: std::rc::Rc::new(RefCell::new(HashMap::new())),
                preedit: std::rc::Rc::new(RefCell::new(HashMap::new())),
                indeterminate: std::rc::Rc::new(RefCell::new(std::collections::HashSet::new())),
                columns: Vec::new(),
                rows: Vec::new(),
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
    let mut child = command
        .stdin(Stdio::piped())
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
    assert!(
        status.success(),
        "kaya: the foreign clipboard writer exited {status}"
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

/// Wayland charges an input-event serial for TAKING the selection, and
/// the charge is not one-time (docs/clipboard-plan.md §5b finding 3,
/// all of it measured): the lane's headless seat has no input devices,
/// so no client ever earns a serial on its own, AND wlroots rejects a
/// set_selection whose serial is older than the current selection's —
/// every wl-copy seed advances that watermark, so a serial obtained
/// once goes stale the moment a seed lands. The rejection is silent
/// (DEBUG-level log; GDK still records a local claim), and a GDK
/// client with a live local claim IGNORES incoming offers and waits
/// for a `cancelled` that never comes, so ONE dropped copy leaves the
/// guest deaf to the clipboard for the rest of its life.
///
/// So the harness taps a virtual-keyboard F24 before EVERY step that
/// can lead to a copy: each tap hands the focused client a serial
/// newer than any seed's. The FIRST tap uses the press-hold-release
/// form — the press races GDK's late wl_keyboard bind and is lost,
/// the release at +800ms lands after the bind; later taps take the
/// quick form, the keyboard being bound by then. The keyboard exists
/// only for the tap's own lifetime ON PURPOSE: a session-held virtual
/// keyboard makes keyboard focus EXCLUSIVE across the compositor, and
/// the lane pools eight legs in one session — adding a holder broke
/// three unrelated legs' expect_focused the day it was tried
/// (2026-08-03). A transient keyboard during a SERIALISED clipboard
/// leg has no neighbor to disturb.
///
/// HARNESS MACHINERY, deliberately: the arm stays ordinary GDK, and a
/// real session delivers real input continuously. F24 because it is
/// bound to nothing and types nothing; during a serialised clipboard
/// leg the focused window is the leg's own.
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
    /// preedit GTK has reported for that widget.
    ///
    /// TOTAL, like `menu_state`: every miss is a short description
    /// rather than a panic, so the three verbs double as the wait for a
    /// render to land.
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
            // enablement is recomputed at the two moments it can
            // change hands — chrome about to present, and a harness
            // activation. The GAction's enabled flag refuses a
            // disabled activation natively, so it must be CURRENT
            // before the route resolves.
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
            // The bar route: resolve SEMANTICALLY over the model tree
            // (a grouping root's label is a path segment whether or
            // not materialization mints a titled row), then drive the
            // REAL window-scoped GAction — the same object bar chrome
            // and the accelerator hit. A disabled action refuses the
            // activation natively, exactly as its grayed row would.
            let route = {
                let reg = core.menus.borrow();
                let roots = reg.bars.get(&0).cloned().unwrap_or_default();
                let item = menu_resolve_path(&reg, &roots, &path).unwrap_or_else(|| {
                    // REACHING HERE MEANS THE CLAIM WAS NONE, which for
                    // a context item is the whole bug rather than a
                    // detail: the bar cannot contain it, so the useful
                    // question is never "which item" but "what cleared
                    // the claim, and when". The trail answers it.
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
        // Correspondence is ORDINAL: the Nth element of the matching
        // role in the app's AT-SPI tree, which is what `kind#index`
        // already means. GTK <= 4.21 publishes no settable accessible
        // id (verified: set_widget_name does NOT surface as one), so
        // identity matching is unavailable here — unlike macOS, where
        // the identifier works and is used instead. Strongest
        // correspondence each platform offers.
        #[cfg(feature = "harness")]
        {
            // THE ROLE COMES FROM THE WIDGET, NOT FROM ITS KIND, and the
            // two are not always the same question. For every kind but
            // one they agree by construction — a kaya button is a
            // GtkButton and publishes `push button`, an entry and a
            // textarea are both `text` (read off the live bus with the
            // probe, not guessed), a scroll viewport keeps GTK's own
            // `scroll pane` while the other containers are promoted to
            // Grouping by being NAMED. Where they part is the styling
            // pass's heading role (docs/styling-plan.md D4): a LABEL
            // carrying it publishes ATSPI heading, which is the one
            // styling fact an assistive client — and this read — can
            // see. A mapping keyed on the kind would still ask for
            // `label`, rank the target among labels, and answer with a
            // different element's name.
            //
            // atspi_role_of is also the function atspi_rank ranks BY, so
            // asking it here is what keeps the ordinal and the collected
            // role from being two different questions. A widget it does
            // not answer for — an unnamed container, which publishes
            // GENERIC and is not a semantic node at all — has no ordinal
            // either, and that is a finding rather than a zero.
            //
            // AND THE ORDINAL IS NOT kaya's INDEX. `label#0` means the
            // first label kaya created, but the bus's Nth Label counts
            // the captions inside buttons and check boxes too — so
            // `label#0` read `label/Save`, the caption inside the first
            // button (measured 2026-07-25). The same collision hits
            // every role the bus shares between kinds: an entry and a
            // textarea are both `text`, so `textarea#0` read the
            // entry's name; every named container is `grouping`, so
            // `row#0` read the enclosing column's.
            //
            // So kaya's index resolves a WIDGET (creation order, what
            // `kind#index` means), and the widget's rank among the
            // widgets publishing the SAME bus role — walked
            // depth-first, the order the bus publishes — is the ordinal
            // to ask for. Widget-tree order rather than creation order
            // on purpose: creation is parent-first in statement-shaped
            // languages and child-first in expression-shaped ones,
            // while the tree is identical in both.
            //
            // Exact identity is still unavailable here (GTK publishes
            // no settable accessible id below 4.22, and the AT-SPI
            // probe confirms the widget name does not surface as one);
            // this is the strongest correspondence the platform offers.
            //
            // The rank is read on the MAIN thread (the widget tree
            // lives there), the bus walk on this one — the same split
            // every other GTK verb makes.
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
                None => "<not in the accessibility tree>".to_owned(),
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

    /// THE THREE RANGE READS, all three off the ACCESSIBILITY BUS — the
    /// same tree `ax` reads and the same correspondence rules (kaya's
    /// index picks a widget, the widget's rank among same-role nodes
    /// picks the bus ordinal). Nothing here consults what kaya declared:
    /// a leg that passed because the backend remembered its own intent
    /// would prove nothing about the GtkTextTag, the selection or the
    /// viewport.
    fn highlights(&self, target: crate::harness::Target) -> String {
        match Self::range_target(target) {
            Ok(at) => atspi_range_read(at.rank, RangeRead::Highlights)
                .unwrap_or_else(|| "<the accessibility tree did not answer>".to_owned()),
            Err(why) => why,
        }
    }

    fn selection(&self, target: crate::harness::Target) -> String {
        match Self::range_target(target) {
            Ok(at) => atspi_range_read(at.rank, RangeRead::Selection { preedit: at.preedit })
                .unwrap_or_else(|| "<the accessibility tree did not answer>".to_owned()),
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
            .unwrap_or_else(|| "<the accessibility tree did not answer>".to_owned()),
            Err(why) => why,
        }
    }

    /// Start a real input-method composition in the textarea.
    ///
    /// THE ONLY DOOR GTK LEAVES OPEN, and it is the real one. A preedit
    /// exists because an INPUT METHOD produced it: GTK's text widgets
    /// render `priv->im_context`'s preedit string and nothing else can
    /// put one there — `gtk_im_context_set_preedit` does not exist, the
    /// preedit never enters the buffer (measured: `char_count` stayed at
    /// 4 with a live preedit), and emitting `preedit-changed` by hand
    /// only makes the view ask the same context the same question.
    ///
    /// So kaya BECOMES the input method for the duration: a
    /// `GtkIMContext` subclass registered on GTK's own `gtk-im-module`
    /// extension point, installed as the slave of the view's
    /// GtkIMMulticontext through the public `set_context_id`. Everything
    /// downstream is then the platform's: the view asks our context for
    /// its preedit string, renders it as marked text, reports it on
    /// `GtkTextView::preedit-changed` — and, crucially, RESETS it on any
    /// programmatic cursor or selection move, which is the D4 hazard
    /// this scene exists to prove. A backend that honoured a
    /// `select_range` here would destroy the composition through GTK's
    /// own machinery, not through a mock, and the caret assertion would
    /// say so.
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
        // Like `type_text`: block until the composition is LIVE, read
        // back through GTK's own signal rather than assumed from the
        // call. A composition the view never rendered is not a
        // composition, and the next step would assert against a state
        // that never existed.
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
        // `Property::Description`, which is the accessible surface's
        // slot for "what does acting on this do", and the same node
        // `ax` resolves. Same correspondence rules apply (see `ax`):
        // kaya's index picks a widget, the widget's rank among
        // same-role nodes picks the bus ordinal.
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
                None => "<not in the accessibility tree>".to_owned(),
            };
        }
        #[allow(unreachable_code)]
        {
            let _ = target;
            "<the GTK accessibility read is not implemented yet>".to_owned()
        }
    }

    fn resize_window(&self, window: u64, width: f64, height: f64) {
        // The REAL resize path: the size a user's drag would set.
        Self::on_main_mut(move |core| {
            use gtk4::prelude::GtkWindowExt;
            gtk_window(core, window).set_default_size(width as i32, height as i32);
        });
        // WAIT FOR THE ALLOCATION, then re-run the arm. set_default_size
        // returns before GTK has laid out, so an arm that re-ran
        // immediately measured the OLD width and stamped the OLD
        // presentation — while the assertion, polling a beat later, saw
        // the new one. The two disagreeing about one instant is the
        // signature of reading a tree mid-update (docs/traps.md).
        //
        // Polled from the HARNESS thread, never by pumping the main
        // loop from inside a CoreState borrow: re-entering CORE there
        // aborts.
        // Wait until the allocation lands on the SAME SIDE OF THE
        // BOUNDARY as the request — not until it equals it. A window
        // manager (or, under Xvfb, its absence) is free to grant a
        // different size, so exact equality never held and every resize
        // paid the full timeout instead of ~a frame. The size class is
        // the only thing the arm reads, so it is the only thing worth
        // waiting for.
        let want_regular = width >= 600.0;
        for _ in 0..100 {
            let now = f64::from(Self::on_main(move |core| window_width(core, window)));
            if (now >= 600.0) == want_regular {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        Self::on_main_mut(move |core| {
            refresh_nav(core, window);
        });
    }

    fn split_presentation(&self) -> String {
        Self::on_main(|core| {
            use gtk4::prelude::GtkWindowExt;
            // The class from the window's real width, the same 600
            // boundary menu_presentation draws; the presentation from
            // the arm that actually ran.
            // The SAME source the arm used.
            let width = window_width(core, 0);
            let class = if width >= 600 { "regular" } else { "compact" };
            // THE WIDGET'S OWN ANSWER, not a value the arm stamped
            // about itself: GNOME decides where this collapses, so
            // asking anything else would be asking kaya what kaya did.
            // A window that never requested list-detail has no widget,
            // and falls back to the serial arm's stamp.
            let presentation = match core.split_views.get(&0) {
                Some(view) => {
                    if view.is_collapsed() {
                        "stacked"
                    } else {
                        "split"
                    }
                }
                None => core.split_presentation.get(&0).copied().unwrap_or("stacked"),
            };
            format!("{class}/{presentation}")
        })
    }

    fn menu_presentation(&self) -> String {
        Self::on_main(|core| {
            use gtk4::prelude::GtkWindowExt;
            // GTK4 has no size-class API of its own (libadwaita's
            // AdwBreakpoint is the nearest, and this backend does not
            // depend on it), so the class comes from the window's real
            // content width against the same 600 boundary the other
            // platforms draw — default_size on a mapped toplevel, the
            // notion window_content_size already reads.
            let width = gtk_window(core, 0).default_size().0;
            let class = if width >= 600 { "regular" } else { "compact" };
            // The presentation is read off the REAL chrome — a
            // PopoverMenuBar exists or it does not. GTK has only the
            // bar lowering, so there is no arm to disagree with the
            // class; that is a fact about this backend, recorded, not
            // an inference.
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
            // THE HARNESS-READ REFRESH — the mac arm's finding 2, which
            // cost that leg a debugging round: enablement is recomputed
            // at the moments it can change hands, and a harness READ is
            // one of them exactly as a harness ACTIVATION is. Without
            // this line `expect_menu "Edit>Undo" enabled` answers with
            // whatever the item was born with, and no scene before this
            // milestone's caught it because none asserts an enablement
            // that MOVES.
            refresh_roles(core);
            // TOTAL, the try_resolve style: a missing item is a
            // retryable miss — expect_menu doubles as the wait for a
            // catalog rebuild — never a panic. The OPEN context menu
            // owns resolution exclusively while presented.
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
                    // The REAL action's flag where one exists (it
                    // carries the inherited AND) — including a radio
                    // option's own action, which is what grays that one
                    // row. Grouping nodes have no GAction, so the
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
                    // The state lives on the OPTIONS' actions, one per
                    // option and all carrying the group's selected
                    // index (that index is what each row compares its
                    // target against to draw the radio mark). Reading
                    // the first option's action therefore reads what
                    // GMenu renders — and a group with no options yet
                    // has no such state to read.
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
        // THE REAL ROW GTK BUILT, never the registry's mirror: the
        // GIcon held by the materialized GtkModelButton the menu tracker
        // minted from the model. A lowering that stored the prop and
        // never wrote the model attribute fails here, and so does one
        // that wrote a name this backend cannot map back.
        //
        // GtkModelButton is private to GTK — there is no public type to
        // downcast to and none in gtk4-rs — so the row is found by GType
        // NAME and read through GObject properties. That is not a
        // workaround for a better API; it is the only API. It is also
        // why every step below states what it measured: a walk that
        // finds nothing must not answer like a row that carries nothing.
        //
        // TOTAL, the menu_state style: every failure is a short sentence
        // and a retryable non-match, never a panic — expect_menu_symbol
        // doubles as the wait for a catalog rebuild.
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
                        // top-level holder a GtkPopoverMenuBarItem whose
                        // only content is a GtkLabel, so there is no
                        // icon slot on the bar at all. Named as a fact
                        // about the platform rather than about the app.
                        return "a top-level menu on GTK's bar carries no icon".to_owned();
                    }
                    // BY LABEL, not by ordinal. The ordinal would be a
                    // second identity rule — `bars` order against the
                    // bar's child order — and a drifted one answers with
                    // a DIFFERENT menu's icon instead of failing.
                    // menu_resolve_path already makes a byte-for-byte
                    // label the identity of a menu (the shared-scene
                    // contract), so this walk uses the same one, and the
                    // miss prints the labels the bar actually shows.
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
                    // The registry has the item and the chrome has no
                    // row for it. TWO causes reach here — a rebuild
                    // still pending, and a kind that mints no row at all
                    // (a nested radio GROUP renders as a labeled GMenu
                    // *section*, and a section header is not an item, so
                    // it has no icon attribute) — and this reader cannot
                    // tell them apart. So it prints the KIND rather than
                    // naming a cause: the kind is the one fact that
                    // separates them, and it is one this read measured.
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
                // WHAT THIS MEASURED: the row exists in the real chrome
                // and GTK holds no GIcon for it. Deliberately NOT "no
                // symbol": this reader cannot tell "the app declared
                // none" from "declared and never lowered", and a
                // diagnostic may only print what it measured
                // (CLAUDE.md invariant 3).
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
            // ONE sentence for both ways this can fail — an icon that is
            // not themed at all, and a themed one naming something the
            // table does not hold — because the useful half is the same
            // in both: GIcon's own serialization, which is what was
            // actually on the row.
            let shown = gio::prelude::IconExt::to_string(&icon)
                .map(|s| s.to_string())
                .unwrap_or_else(|| "<not serializable>".to_owned());
            format!("the row's icon is {shown:?}, which is not in this backend's symbol table")
        })
    }

    // THE TOOLBAR IS A DEPTH SLICE, mac first (docs/chrome-plan.md C2).
    // This backend's arm is the AdwHeaderBar pack the plan measured —
    // buttons in catalog preorder, a synthesized GtkMenuButton for the
    // remainder GTK has no overflow for, and the accessible name an
    // icon-only button does not publish by itself. None of that is here
    // yet, so the refusal goes through the helper both gates read: it
    // holds every linux toolbar leg off run-suites.sh until the arm
    // lands, and it cannot pass vacuously because it cannot pass.
    fn toolbar_chrome(&self) -> String {
        crate::depth_stub("toolbar")
    }

    fn toolbar_item(&self, _label: &str, _aspect: &str) -> String {
        crate::depth_stub("toolbar")
    }

    fn shortcut(&self, spelling: &str) {
        // Same two reasons as menu_activate: the chord may land on a
        // role item.
        Self::prime_if_clipboard_scene();
        let spelling = spelling.to_owned();
        Self::on_main(move |core| {
            refresh_roles(core);
            // The platform's own table: the application accelerator
            // map that set_accels_for_action filled — the exact table
            // GtkApplicationWindow's accel controller walks for a
            // real key press. A chord no catalog action owns is a
            // SILENT no-op (the dress must never swallow it — the
            // interpreters' rule), which the map gates structurally:
            // only catalog actions are ever registered in it.
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
                // The action machinery end to end: resolve the
                // detailed name through the owning window's muxer —
                // where the accel controller lands a key event — so
                // the SAME GSimpleAction handler emits the SAME
                // menu_activated a direct activation would.
                // A DETAILED name carries an option's target —
                // `win.kmi-7(1)` — and activate_action takes a plain
                // name plus the parameter, never the detailed
                // spelling. Splitting it is what lets one option of a
                // group answer its own chord.
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
                    .map(|window| gtk_window(core, window))
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
            // A click on a TEXT KIND focuses it — what a native click
            // does to a field, and the only way a scene can put focus
            // on a STAMPED copy (no instance-addressed focus command
            // exists for a guest to call). grab_focus lands on the
            // entry's inner GtkText exactly as a pointer click would,
            // which is why is_focused reads FOCUS_WITHIN.
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

    /// The real-keystroke typing verb (docs/undo-plan.md A8), to
    /// harness.rs's six-point contract.
    ///
    /// 1. THE PLATFORM'S OWN INPUT PATH. The keys enter through the
    ///    session's input machinery — a transient Wayland virtual
    ///    keyboard (`wtype`, the tool the clipboard lane already
    ///    installs and taps for its serial) or XTEST (`xdotool`) — so
    ///    the field's native history fills exactly as a user's typing
    ///    fills it. Measured: a programmatic insert fills NOTHING on
    ///    this backend (a GtkText records no history for
    ///    gtk_editable_insert_text), so a stand-in here would not merely
    ///    be impure, it would leave the native tier empty and let a
    ///    native-tier leg pass having observed nothing.
    /// 2. WHATEVER HOLDS FOCUS RECEIVES IT: both tools deliver to the
    ///    session's focused surface, so the platform answers the
    ///    routing question and kaya never looks a widget up.
    /// 3. IT APPENDS: the caret goes to the END with nothing selected
    ///    first, which matters here because kaya's `focus` command is
    ///    grab_focus and GTK selects an entry's contents on focus — the
    ///    same trap macOS has, and one script is compared byte for byte
    ///    on both.
    /// 4. IT BLOCKS UNTIL THE TEXT HAS LANDED: the tool is run to
    ///    completion and then the widget is polled until it shows what
    ///    was typed. An `expect` after this verb would be a bounded
    ///    retry, but `menu_activate "Edit>Undo"` — the reason the verb
    ///    exists — is an action and has no such cover.
    /// 5. NO SYNTHETIC COALESCING: one key event per character, in
    ///    order; GTK merges a run into one undo step by itself
    ///    (measured), which is the platform's business.
    ///
    /// THE FIRST KEYSTROKE IS LOST WITHOUT A WARM-UP on Wayland
    /// (measured: `wtype tea` types "ea", every invocation): a fresh
    /// virtual keyboard races GDK's wl_keyboard bind. The lane's own
    /// answer is the press-hold-release of F24 — a key bound to nothing
    /// that types nothing — and here it rides INSIDE the same
    /// invocation, so the payload follows on a keyboard that is already
    /// bound. X11 has no such race (XTEST types on the server's own
    /// keyboard) and needs no warm-up.
    fn type_text(&self, text: &str) {
        assert!(
            !text.starts_with('-'),
            "kaya: type {text:?} begins with '-', which both injection tools read as an \
             option — type text that does not, or teach this verb a tool that takes a \
             payload on stdin"
        );
        // FIRST, LET THE PREVIOUS STEP'S CONSEQUENCES LAND — and this is
        // correctness, measured by the lane rather than reasoned about.
        // The scene clicks a button whose handler focuses the field and
        // then types; an ACTION returns as soon as it is delivered, so
        // the guest's `focus` transaction is still in flight. GTK's
        // grab_focus SELECTS THE ENTRY'S CONTENTS, so a focus that lands
        // between this verb's caret move and the keystrokes turns an
        // append into a REPLACE: pooled eight wide, `type "s"` on a
        // field holding "tea" read "s" on both protocols (2026-08-04),
        // while the same leg alone passed six times running — the
        // wayland warm-up hold happened to absorb the round trip and
        // x11's zero-delay injection did not.
        //
        // Quiescence, bounded: drain what has arrived, and require
        // several consecutive empty drains before typing. A guest that
        // never goes quiet costs the deadline and then types anyway,
        // because a stalled app is the following assertion's story to
        // tell, not this verb's.
        let settle = std::time::Instant::now() + std::time::Duration::from_millis(500);
        let mut quiet = 0;
        while quiet < 3 && std::time::Instant::now() < settle {
            let applied = Self::on_main_mut(|core| {
                let mut n = 0usize;
                while let Ok(tx) = core.transactions.try_recv() {
                    for op in core.scene.apply(tx) {
                        apply(core, op);
                    }
                    n += 1;
                }
                if n > 0 {
                    refresh_roles(core);
                }
                n
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
        // THE CARET MOVE RIDES THE SAME INPUT STREAM as the characters,
        // ahead of them: Ctrl+End is a real key event that goes to the
        // end of the text and collapses any selection, so nothing the
        // toolkit does between this verb's programmatic caret move and
        // the first character can turn the run into a replace. The
        // characters follow with the SMALLEST inter-key delay each tool
        // takes (wtype refuses 0 — "Invalid sleep time", measured),
        // which keeps the burst inside GDK's event reading rather than
        // leaving idle-priority gaps for a late transaction to land in.
        let (tool, args): (&str, Vec<&str>) = if linux_wayland_session() {
            (
                "wtype",
                vec![
                    "-P", "F24", "-s", hold, "-p", "F24", "-s", "20", "-M", "ctrl", "-k",
                    "End", "-m", "ctrl", "-s", "10", "-d", "1", text,
                ],
            )
        } else {
            ("xdotool", vec!["key", "ctrl+End", "type", "--delay", "0", text])
        };
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
        // Point 4: every character delivered AND processed.
        let Some((id, before)) = target else { return };
        let want = format!("{before}{text}");
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(2000);
        loop {
            let now = Self::on_main(move |core| core.text_of(id).unwrap_or_default());
            if now == want {
                // AND THE KEYS FILLED THE NATIVE HISTORY, which is the
                // whole reason this verb exists and the one thing a
                // stand-in cannot fake. A `set_text` here would satisfy
                // every assertion above AND every assertion in
                // tools/scenes/undo.steps — the frontier undo would
                // quietly fall to the core's coarse restore and the
                // native tier would go untested while the leg went
                // green. That is the failure this line refuses.
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
                // NOT a verdict — the contract says a following
                // assertion reports the mismatch — but never silent
                // either: a verb that gave up is the thing a reader of
                // the failure will want to know about first.
                eprintln!(
                    "KAYA_UNDO_TRACE: type {text:?} never landed: the field holds {now:?}, \
                     expected {want:?} after {tool} reported success"
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
            // IT EMITS LIKE THE USER AND IT WRITES LIKE THE APP, and
            // the second half is what the native stack sees: a
            // programmatic write wipes a GTK field's undo history
            // (measured), whatever the occurrence says. So the model of
            // that stack is corrected here — otherwise a scene that
            // set_texts a focused field and then activates Edit>Undo
            // routes NATIVE into an empty stack and spends an
            // activation discovering it.
            // BY CONTROL, not by layout widget: this verb resolved the
            // textarea through core.textareas (the GtkTextView), and a
            // lookup keyed on the viewport would simply find nothing —
            // silently leaving the native-undo model uncorrected.
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
            use gtk4::prelude::WidgetExt;
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return "<no such target>".to_string();
            };
            let container = &registry[i];
            while glib::MainContext::default().iteration(false) {}
            // width()/height() are ALREADY the content box on GTK4 —
            // CSS padding lives outside the widget's own coordinate
            // space, unlike every other backend here, and child
            // allocations are content-relative. Subtracting the
            // .kaya-root padding on top of that read a filling root as
            // 259px spanning 227px on the first Wayland run.
            let inner = if vertical {
                container.height()
            } else {
                container.width()
            };
            let mut min_start = i32::MAX;
            let mut max_end = i32::MIN;
            let mut child = container.first_child();
            while let Some(widget) = child {
                let alloc = widget.allocation();
                let (start, extent) = if vertical {
                    (alloc.y(), alloc.height())
                } else {
                    (alloc.x(), alloc.width())
                };
                min_start = min_start.min(start);
                max_end = max_end.max(start + extent);
                child = widget.next_sibling();
            }
            if max_end < min_start {
                return "no children".to_owned();
            }
            let span = max_end - min_start;
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
            // The LAYOUT widget, not the control: a textarea's flex
            // child is its GtkScrolledWindow, and target_widget hands
            // out the GtkTextView inside it (that is what every text
            // verb wants). Asking the view about its track would find
            // none — it is not the box the flex manager placed.
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
            // The allocation is what the widget DREW at: GTK adjusts it
            // for the child's align and margins on the way in, so a
            // start-aligned or size-request-bound child reads its own
            // box here while the track above stays what the layout
            // handed out. An overflow is not a leftover, so this is
            // one-sided.
            let drawn = flex::child_extent(&widget, vertical);
            if drawn >= track - 2.0 {
                String::new()
            } else {
                format!("draws {}px of a {}px track", drawn.round(), track.round())
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
            // width()/height() are the content box and child
            // allocations are content-relative (the fills lesson), so
            // the cross box is 0..inner.
            let inner = if vertical { container.width() } else { container.height() };
            let mut rects: Vec<(i32, i32)> = Vec::new();
            let mut baselines: Vec<i32> = Vec::new();
            let mut child = container.first_child();
            while let Some(widget) = child {
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
                child = widget.next_sibling();
            }
            if rects.is_empty() {
                return "no children".to_owned();
            }
            let all = |f: &dyn Fn(&(i32, i32)) -> bool| rects.iter().all(f);
            // Baseline first: GTK 4.12 spells it BASELINE_FILL, so the
            // boxes legitimately fill the row too — but the box hands
            // children an allocated baseline ONLY under baseline
            // alignment (plain fill reads -1), which is the honest
            // discriminator stretch geometry cannot fake. PARTICIPATION
            // is the whole check: the reported values are not
            // comparable across widget kinds (a label reports the
            // box-allocated line, a button its content-relative one —
            // 37 vs 27 for a visually ALIGNED pair, screenshot-
            // verified), so the agreement itself is GTK's to keep,
            // the way root_fills leaves "content area" to each
            // platform's own notion.
            if !vertical && baselines.len() >= 2 {
                return "baseline".to_owned();
            }
            // Every geometric mode is tested; more than one match
            // means the scene's geometry cannot distinguish them, and
            // a first-match answer would let such a scene pass while
            // proving nothing — ambiguity fails loudly instead (the
            // separability lesson, made structural).
            let mut matches = Vec::new();
            if all(&|r| (r.1 - inner).abs() <= 2) {
                matches.push("stretch");
            }
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
            gtk_window(core, window)
                .title()
                .map(String::from)
                .unwrap_or_default()
        })
    }

    fn window_content_size(&self, window: u64) -> (f64, f64) {
        Self::on_main(move |core| {
            use gtk4::prelude::GtkWindowExt;
            // On a mapped toplevel default_size tracks the current
            // content size (X11; a Wayland compositor keeps its own
            // last word, the request semantics).
            let (w, h) = gtk_window(core, window).default_size();
            (f64::from(w), f64::from(h))
        })
    }

    fn window_dirty(&self, window: u64) -> bool {
        // THE CHROME, OVER THE BUS — the read D5's table names for this
        // backend. GTK publishes no getter for accessible properties and
        // kaya's own model would only agree with itself, so the honest
        // question is the one an assistive client asks: does this
        // window's accessibility subtree contain the marker node?
        //
        // The window is identified by its frame's NAME, which is the
        // window title GTK publishes (measured: the property,
        // _NET_WM_NAME and sway's IPC name agreed exactly, every time) —
        // and `dirty` never touches that string, on any platform, which
        // is what makes it usable as identity here. Two windows wearing
        // one title would make the question ambiguous, and ambiguity is
        // reported rather than guessed at.
        //
        // UNREADABLE IS ITS OWN FAILURE, NEVER `false`. A clean-window
        // assertion that passes because the bus was not there is the
        // exact vacuous green the depth arm refused on macOS. The common
        // cause is a leg wired WITHOUT tools/linux/a11y-leg.sh: GTK
        // publishes an accessibility tree only under GTK_A11Y=atspi with
        // a bus to sit on, and that wrapper is what stands both up.
        //
        // The bounded retry is for PUBLICATION LAG, not for the answer:
        // the tree is served by our own main loop on demand, and a frame
        // can be a beat late to appear. Every other GTK accessibility
        // read has a sentinel string for this (`ax` returns "<not in the
        // accessibility tree>" and lets the harness poll re-ask); a bool
        // has no spelling that is not an answer, so the waiting happens
        // here.
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
        Self::on_main(move |core| {
            use gtk4::prelude::GtkWindowExt;
            // The REAL chrome path: close() runs close_request, so
            // the veto grammar fires exactly as a user click would.
            gtk_window(core, window).close();
        })
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
        Self::on_main(move |core| {
            use gtk4::prelude::{Cast, GtkWindowExt, WidgetExt};
            let live = core.live_alert.borrow();
            let Some(alert) = live.as_ref() else { return };
            let label = if choice == crate::wire::ALERT_CHOICE_CANCEL {
                alert.labels.last().cloned()
            } else {
                alert
                    .labels
                    .get(choice as usize)
                    .filter(|_| (choice as usize) < alert.actions)
                    .cloned()
            };
            let Some(label) = label else { return };
            // The REAL button inside the presented dialog window:
            // find the alert's own toplevel (transient-for our
            // window, not one of ours) and activate its button —
            // the same signal path a user's click runs.
            let parent = gtk_window(core, alert.window);
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
                    return;
                }
            }
        });
        // AND WAIT FOR IT TO ACTUALLY GO, which is what makes this verb
        // mean the same thing here as everywhere else.
        //
        // Activating the button only ASKS: `AlertDialog::choose`
        // answers through an async callback, and that callback is what
        // runs capi::alert_retire. Until it lands the core still holds
        // the alert in its one live slot, so an app that shows its NEXT
        // alert from any other event — not from this one's result
        // handler — walks into "alert N is already live" and the
        // process aborts.
        //
        // Measured 2026-08-10, both protocols: the editor scene cancels
        // File>New's alert, and 40ms later a close_requested shows the
        // second one. That abort took the whole run's verdict with it.
        // Every other backend's alert_choose is settled when it
        // returns; a scene author must not have to know this one is
        // not, so the difference is paid here rather than in five
        // hundred lines of scene script (CLAUDE.md invariant 1).
        //
        // A stuck alert dies LOUDLY: a silent give-up would leave the
        // next expect_alert reading the wrong dialog and passing.
        // THE SAME BOUNDED RETRY EVERY OBSERVATION GETS, and deliberately
        // the same two numbers: this is a wait for an observable to
        // settle, so it has no business inventing a second deadline.
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
            // The REAL affordance: activate the header bar's back
            // button — its click handler runs the same user-pop path
            // a pointer press does. Deferred one idle tick: the
            // handler re-borrows CORE, which this closure holds.
            //
            // ONE PATH, list-detail included. This used to special-case
            // a split window by activating `navigation.pop` on the view
            // directly, on the belief that libadwaita's own back button
            // was the affordance being driven. There was no such button
            // (see refresh_nav), so the harness popped a collapsed
            // window that showed nothing to press — the verb inventing
            // an affordance, which is the failure the check below
            // exists to prevent. The split arm now shows kaya's button
            // when collapsed, so this path covers both arms and the
            // two-pane rule falls out of the SAME visibility test:
            // two panes, no button, nothing to drive.
            //
            // A HIDDEN button is not an affordance. emit_clicked runs
            // the handler regardless of visibility, so without this the
            // harness could pop where a user has no button to press,
            // and the two-pane back rule would pass its own test while
            // being false on screen.
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
            let Some(i) = crate::harness::try_resolve(t.index, core.scrolls.len()) else {
                return "<no such target>".to_string();
            };
            // The toolkit's own adjustment: upper is the content
            // extent, page_size the viewport.
            let adj = core.scrolls[i].vadjustment();
            if adj.upper() > adj.page_size() + 2.0 {
                String::new()
            } else {
                format!("content {} in viewport {}", adj.upper(), adj.page_size())
            }
        })
    }

    fn scroll_end(&self, t: crate::harness::Target) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.scrolls.len());
            // The REAL scrolling API: setting the adjustment's value
            // IS how GTK scrolls (scrollbars and kinetic panning both
            // write it).
            let adj = core.scrolls[i].vadjustment();
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
                    // Recover the widget id by identity against the
                    // registry order is unnecessary: the pulse set is
                    // keyed by widget id, so read it via the bar's
                    // kaya id stored at creation.
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
            let Some(i) = crate::harness::try_resolve(t.index, core.scrolls.len()) else {
                return "<no such target>".to_string();
            };
            let adj = core.scrolls[i].vadjustment();
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
        // The REAL chooser, read over the bus as an assistive client
        // would — never this backend's own record of what it asked for.
        // A dialog aimed at the wrong place, or filtered down to
        // nothing, presents perfectly and is useless; only reading it
        // back catches that.
        //
        // NOT on the GTK main thread: this is a dbus round trip, and the
        // main loop is what has to keep answering it.
        //
        // A SAVE PANEL IS NOT A PICKER HERE, deliberately, and this is
        // the mac arm's rule spelled for GTK: there one slot holds an
        // NSSavePanel and two computed readers ask the TYPE, so neither
        // can see the other's panel. On this toolkit there is no type to
        // ask — `open()` and `save()` are two calls on ONE
        // `gtk::FileDialog` — so the tree answers instead, and the two
        // readers stay mutually exclusive all the same. It also makes the
        // discriminator's own failure LOUD on legs that already run: if
        // the name field were ever found on an open chooser, eight green
        // filedialog legs would go red here rather than a save leg
        // quietly typing into a picker.
        let read = file_dialog_atspi(DialogOp::Read)?;
        match read.save_name {
            Some(_) => None,
            None => Some((read.dir, read.rows)),
        }
    }

    fn choose_file(&self, name: Option<&str>) {
        match name {
            // SELECT, THEN PRESS, in two passes. The tree happens to put
            // the list before the buttons, so one in-order pass would
            // work today and break the first time GTK reorders it.
            //
            // Selection is not decoration here: with one row in the
            // directory the chooser completes with it even when nothing
            // is selected, so a scene whose directory held a single file
            // would pass without any of this running. That is why the
            // scene keeps a decoy that sorts first.
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
        // The REAL save panel, over the same bus and the same walk as the
        // picker — the two are one `gtk::FileDialog` here, so the reader
        // tells them apart by what the tree carries (DialogRead).
        //
        // NO ROWS ARE REQUIRED, which the trait doc demands of every
        // backend and which GTK gets for free: this panel does publish a
        // browser, and nothing here looks at it. A reader that waited for
        // rows would be writing macOS's collapsed-panel trap into a
        // platform that does not have it.
        let read = file_dialog_atspi(DialogOp::Read)?;
        Some((read.dir, read.save_name?))
    }

    fn set_save_name(&self, name: &str) {
        // set_text's tier: the field's whole contents replaced, the way a
        // user renaming a suggested name leaves it. Whether it took is
        // NOT assumed — expect_save_dialog reads the field back off the
        // bus, and the scene asserts it before pressing Save.
        file_dialog_atspi(DialogOp::SetName(name));
    }

    fn confirm_save(&self, save: bool) {
        // The panel's OWN buttons, so its own completion runs and the
        // answer travels the path a user's would. The accept button says
        // "Save" here and "Open" on the picker — the one label that
        // differs between two dialogs that are otherwise the same object.
        file_dialog_atspi(DialogOp::Press(if save { "Save" } else { "Cancel" }));
    }

    /// The foreign writer: wl-copy (wayland) or xclip (x11), a child
    /// process with its own connection — nothing kaya wrote serves the
    /// content. AND IT WAITS UNTIL THE CONTENT IS REALLY THERE (the
    /// osascript lesson, §3): wl-copy forks a server and its exit does
    /// not mean the offer landed, so the seed polls the foreign
    /// TARGETS until the seeded type is listed. A seed that does not
    /// verify makes everything after it race.
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

    /// The foreign reader: wl-paste or xclip -o, one representation.
    /// Text, html and custom answer the content; files answers the
    /// FIRST file's basename (parity with pbpaste, which exposes one);
    /// an image answers its DECODED SIZE via imagemagick's identify —
    /// a foreign decoder, because hosts re-encode freely and a byte
    /// count is a different number on every lane (§2). Empty when the
    /// clipboard holds nothing of that kind.
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
                    // BYTES-PRESENT-BUT-UNDECODABLE IS NOT "NOTHING",
                    // and it must not read like it: a broken embedded
                    // asset once hid behind "" here for a full lane
                    // run, because every other platform's decoder was
                    // lenient about a bad IDAT CRC and this lane's
                    // identify is the matrix's first strict one. The
                    // failure text names the decoder's own complaint
                    // so the verdict line carries the cause.
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
        // PRESENTED; pointing one already on screen is silently ignored.
        // So this stores it and the apply arm applies it — the same
        // shape the SwiftUI interpreter uses, for the same reason.
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
            use gtk4::prelude::{GtkWindowExt, WidgetExt};
            let Some(root) = core.window.child() else {
                return "nothing mounted".to_owned();
            };
            while glib::MainContext::default().iteration(false) {}
            let alloc = root.allocation();
            // The child's slot excludes whatever the window draws for
            // itself, and how much that is depends on the compositor:
            // Wayland CSD puts a ~39px headerbar above the child, bare
            // Xvfb draws nothing (the first cut compared against the
            // whole window widget and read a perfectly filling Wayland
            // root as a hug). So "fills" is edge-flush: from wherever
            // the slot starts, the allocation reaches the window's
            // left, right and bottom edges. A hugging child leaves the
            // bottom or right edge unreached and fails either way;
            // only the top edge is unknowable, since it is exactly
            // where the decoration lives.
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

    fn inset(&self) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::GtkWindowExt;
            let Some(root) = core.window.child() else {
                return "nothing mounted".to_owned();
            };
            while glib::MainContext::default().iteration(false) {}
            // The root's own CSS box, where `.kaya-root`'s padding is
            // (docs/styling-plan.md D3). AND ON GTK THAT BOX IS SHARED:
            // kaya mounts the root with no wrapper, so a root container
            // carrying its own inset (prop 17) is counted here too, and
            // the number is the total its children actually sit behind.
            // A scene that wants the two apart asserts the container's
            // on a container that is not the root — which is where the
            // prop was born (the editor's full-bleed window and its
            // inset status ROW).
            css_inset_of(&root)
        })
    }

    fn container_inset(&self, target: crate::harness::Target) -> String {
        use crate::harness::TargetKind as K;
        if !matches!(target.kind, K::Column | K::Row | K::Grid) {
            // The runner does not pre-check this step's kind the way it
            // does expect_shares, so the refusal lives here — and it
            // names what arrived, because a leaf's CSS box would answer
            // with the theme's padding and read like a measurement.
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
        // request_exit reads the main thread's CORE; hop before asking.
        Self::on_main(move |_| request_exit(code));
    }
}

/// The sections arm a window ACTUALLY rendered — what
/// `expect_sections_presentation` believes.
///
/// NEVER the declared hint (wprop 5, `core.sections_presentation`): a
/// read that consults the prop agrees with the lowering by construction
/// and cannot fail when the lowering is wrong. That is the expect_split
/// rule, at the sections construct. Two independent things have to
/// hold, and the sentence names the one that did not:
///
/// - the branch that assembled the chrome stamped its own name on the
///   window (`sections_rendered`), and
/// - the widget that branch left behind is the one that name claims,
///   wired to THIS window's stack, and MAPPED.
///
/// The mapped clause is what makes an auxiliary window honest on this
/// backend. GTK builds its widget tree eagerly, so a chrome merely
/// EXISTING proves that refresh_sections ran and nothing more — not
/// that any window ever presented it. The SwiftUI interpreter gets that
/// for free (its stamp rides the body's appearance and an unshown body
/// writes nothing); this is the same guarantee spelled for a toolkit
/// that builds first and shows later, and it is what holds the
/// aux-window fix in ApplyOp::Mount in place.
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

/// The inset MEASURED on a widget's own CSS box: the offset from its
/// border box to the box its children are placed from, per side, in
/// whole layout units — what both `expect_inset` forms report.
///
/// `compute_bounds(w, w)` gives the widget's BORDER box in the widget's
/// OWN coordinate space, and GTK4 puts that space's origin at the
/// CONTENT box, so the origin it returns is exactly minus the inset on
/// each side. Measured in a container: a box under `padding: 16px`
/// reports @(-16,-16), and one carrying that padding plus an 8px border
/// reports @(-24,-24). Real layout, not the stylesheet read back — it is
/// the allocated box the children were actually placed from.
///
/// THE FIRST-CHILD WALK CANNOT WORK HERE, and this backend shipped it:
/// because a widget's coordinate space starts inside its own padding, a
/// child sitting at its parent's content origin translates to (0, 0)
/// whatever the parent's inset is (measured, both spellings —
/// `translate_coordinates` is `compute_point` underneath). `inset` did
/// exactly that walk and answered 0 for every window; the only step that
/// has ever asserted it is the styling scene's `expect_inset 0`, so the
/// vacuous number WAS the expected one and no lane ever failed.
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
    }
}

/// The AT-SPI role GTK publishes for this widget — MEASURED off the bus
/// (tools/linux/atspi_probe.py), not assumed, and deliberately narrow:
/// it answers only for the roles a scene can assert.
///
/// It exists because the bus tree is NOT kaya's tree. GTK publishes
/// widgets kaya never created (every button and check box contains a
/// GtkLabel, and those labels are real Label nodes on the bus) and
/// hides some it did (an entry's internal GtkText does not appear at
/// all). Ranking a target among the widgets that publish the SAME role
/// is what turns kaya's per-kind index into the bus's ordinal, and
/// getting the set wrong is silent: it reads the wrong element's name.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_role_of(w: &gtk4::Widget) -> Option<atspi::Role> {
    use gtk4::prelude::{AccessibleExt, Cast};
    // A ScrolledWindow FIRST, before the promotion check below: the
    // lowering names it like any other container, and GTK takes the
    // name but NOT the role — the bus still publishes `scroll pane`
    // (measured). Reading the promotion here instead would rank it
    // among groupings and shift every named container after it.
    //
    // AND EVERY TEXTAREA'S VIEWPORT IS ONE OF THESE. The rule this
    // function lives by is that its count must MATCH the bus's, never
    // that it counts only the widgets kaya's scene named: the bus
    // publishes the textarea's scroll pane exactly like the scene's
    // own, so counting it here keeps `scroll#N` pointing at the same
    // node it did before the viewport existed. Skipping it is the
    // failure — the count would fall one behind the bus and every
    // scene holding both a textarea and a scroll viewport would read
    // the wrong element's name (the negative test in the foundation
    // report does exactly that, and `expect_ax scroll#0 "group/Feed"`
    // fails). This is the SAME rule the unmapped-subtree guard below
    // states from the other side: count what the bus publishes,
    // nothing more and nothing less.
    if w.is::<gtk4::ScrolledWindow>() {
        return Some(atspi::Role::ScrollPane);
    }
    // A container kaya NAMED was promoted to Group by the lowering, and
    // Group is exactly what the bus then publishes for it.
    if w.accessible_role() == gtk4::AccessibleRole::Group {
        return Some(atspi::Role::Grouping);
    }
    // A label carrying the heading role (docs/styling-plan.md D4) was
    // given HEADING by the lowering, and GTK 4.18 maps that to
    // ATSPI_ROLE_HEADING — so it is not a Label on the bus and must not
    // be counted as one. BEFORE the Label check for exactly that reason:
    // reading it as a label would put it in the labels' ordinal run and
    // shift every label after it by one.
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
        // THE BUS PUBLISHES WHAT IS ON SCREEN. An unmapped subtree has
        // no accessible nodes, so counting it shifts every ordinal
        // after it: a drop-down's popover carries its own
        // GtkScrolledWindow, and counting that one made the scene's
        // real scroll viewport ScrollPane#1 on a bus that published
        // exactly one (measured 2026-07-25).
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

/// Read this app's accessibility tree over AT-SPI, as a real assistive
/// client does.
///
/// GTK exposes NO getter for accessible properties — the accessible
/// surface IS AT-SPI — so an in-process read would only return kaya's
/// own writes. Going over the bus is the only honest route, and it is
/// why the harness (and this dependency) is feature-gated: a shipped
/// app must never link a dbus client to serve a test verb.
/// What to do with the live file chooser: read it back, or drive it.
///
/// One walk shape serves all three because the tree is the same; only
/// the verb at the interesting node differs. Everything here was
/// MEASURED against GTK 4.18 in the validation image rather than
/// assumed — the probe and its findings are in docs/traps.md.
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

/// Read or drive the live GTK file chooser over AT-SPI.
///
/// THE DIALOG IS IN OUR PROCESS and on the same bus as every other
/// widget: with no xdg-desktop-portal installed GTK presents its own
/// chooser rather than handing off. The walk starts at the desktop, so a
/// portal-hosted one would still be found — it would simply be a
/// different application node.
///
/// Three things the tree does NOT do the way the mac panel does, all
/// measured:
///
/// - There is no "where" control. The current folder is the path bar's
///   PRESSED toggle button — `checked` is false on all of them, so the
///   state to read is Pressed, and the filter combo's own toggle button
///   has to be excluded or it collides.
/// - Rows carry the whole line as one name, "picked.txt 12 bytes Text
///   01:00", so the filename is the first field.
/// - The header row is a `table row` too. Data rows are the ones whose
///   parent is the inner `list`; the header hangs off the `tree table`
///   directly.
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

            // THE SAVE PANEL'S ONE EXTRA CONTROL. Matched on the
            // INTERFACE and not on the label: the node's accessible name
            // is the "Name:" label beside it, which is a translated
            // string, and a lane running under a different locale would
            // then see no save panel at all and fail with "no save dialog
            // is live" — a lie about the app, told by the reader. What
            // never translates is that the field is editable text.
            //
            // THE COMBO IS EXCLUDED for the directory read's reason one
            // control over: the filter drop-down is its own subtree, and
            // a GtkDropDown's search entry is editable text too.
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

            // SELECTION IS THE PARENT'S JOB, and the rows themselves
            // offer no click action at all — only `listitem.scroll-to`,
            // measured. So the index within this list is what selects,
            // and it must be taken here where the index exists.
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
                                // "picked.txt" returned BOTH files with
                                // the decoy first, which is exactly the
                                // wrong answer the decoy exists to
                                // expose. Measured on GTK 4.18.
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
/// application publishes.
///
/// ONE WALK, ONE CONNECTION, THREE READS — the shape `atspi_collect`
/// already uses, with the node's own `Text` (and, for reveal,
/// `Component`) interface asked instead of its name.
///
/// AT-SPI OFFSETS ARE CHARACTERS, which for GTK means CODE POINTS — the
/// same unit the buffer counts and the same unit the core lowered. The
/// harness spelling is UTF-8 BYTES, so every offset below is converted
/// against the text the BUS returned, never against kaya's copy.
///
/// NEVER `GetAttributeValue`: the deprecated point getter SIGSEGVs a
/// GtkTextView, reproduced twice (scratchpad/range-probe-linux.md §6).
/// `GetAttributeRun` is the safe one.
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
                // WALKED, NOT ENUMERATED: for an offset no tag covers,
                // GTK answers with the empty range (0,0) rather than the
                // run of unattributed text, so a reader cannot skip
                // forward and has to probe every character. Measured at
                // ~0.15ms a call, which a scene-sized document affords
                // and a real one would not.
                let mut out: Vec<String> = Vec::new();
                let mut at = 0i32;
                while at < count {
                    let Ok((attrs, start, stop)) = text.get_attribute_run(at, false).await else {
                        return None;
                    };
                    if stop > start && attrs.contains_key("bg-color") {
                        // THE COVERED TEXT COMES FROM THE PLATFORM, and
                        // that is the whole point of the spelling: the
                        // offsets alone would be this read agreeing with
                        // the lowering's own conversion, two symmetric
                        // mistakes cancelling while the wrong characters
                        // were decorated. This slice has no arithmetic
                        // in it — the bus slices its own string with the
                        // range it is actually holding.
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
                // AND THE COMPOSITION COUNTS, because the offsets in
                // this spelling are into the text the widget is
                // DISPLAYING — which on every platform includes the
                // marked text. AppKit's NSTextView literally holds it in
                // `string`; GTK renders it out of the layout and leaves
                // the buffer alone (measured: `char_count` stayed 4 with
                // a live preedit), so the buffer's caret describes where
                // the caret is in the DOCUMENT and the preedit is the
                // rest of the answer. The string is GTK's own, reported
                // on `preedit-changed` — so a backend that let a
                // `select_range` through would have its composition
                // reset by GTK, this would arrive empty, and the number
                // would move.
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
                // CONTAINMENT, NEVER THE VIEWPORT ITSELF: how much
                // context a scroll leaves is native behaviour, and a
                // scene that asserted a scroll offset would be asserting
                // GTK's taste. The arithmetic is consistent by
                // measurement — `extents.y = widget.y + buffer_y -
                // scroll_offset` — and it is only meaningful because the
                // textarea now HAS a viewport: on the old unscrolled
                // shape the widget box was the whole buffer and every
                // range was vacuously inside it.
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
                // A text field with no authored label publishes an
                // EMPTY name; its content lives on the Text interface,
                // and that content is what a screen reader speaks for
                // it. The macOS reader's fallback chain ends in
                // AXValue for the same reason (description -> title ->
                // value there; name -> Text content here), so
                // `field/<its text>` reads the same on both platforms.
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

/// Is the marker node — a descendant named `marker` — inside the frame
/// this app publishes under the name `title`?
///
/// The `dirty` prop's read on GTK (docs/dirty-plan.md D5), and the
/// reason the marker carries an accessible label at all: an unlabelled
/// bullet publishes as `label name='• '`, which no client can address.
/// Measured with the whole scene's toggle: the node appears in and
/// disappears from the tree in lockstep with `gtk_widget_set_visible`,
/// both directions, while the frame's own name stays clean throughout.
///
/// SCOPED TO ONE FRAME, unlike `atspi_collect`, which ranks nodes across
/// the whole application. `window_dirty` is asked about a WINDOW, and a
/// scene with two of them (the panels grammar) would otherwise read one
/// window's marker as another's.
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
