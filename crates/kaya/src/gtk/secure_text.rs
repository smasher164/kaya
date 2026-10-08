// docs/traps.md, "GTK 4.18 hands a password entry's text to every AT-SPI
// client": a GtkPasswordEntry that implements GtkAccessibleText, answered by
// its own GtkText's implementation, which reads the display text.

use gtk4::glib::{self, ffi::gpointer, gobject_ffi, translate::*};
use gtk4::prelude::*;
use gtk4::{ffi, AccessibleTextContentChange};
use std::ffi::{c_char, c_int, c_uint};
use std::sync::OnceLock;

fn masked_type() -> glib::ffi::GType {
    static TYPE: OnceLock<glib::ffi::GType> = OnceLock::new();
    *TYPE.get_or_init(|| unsafe {
        let parent = ffi::gtk_password_entry_get_type();
        let mut query: gobject_ffi::GTypeQuery = std::mem::zeroed();
        gobject_ffi::g_type_query(parent, &mut query);
        assert!(query.class_size > 0 && query.instance_size > 0, "GtkPasswordEntry has no size");
        let ty = gobject_ffi::g_type_register_static_simple(
            parent,
            c"KayaPasswordEntry".as_ptr(),
            query.class_size,
            Some(class_init),
            query.instance_size,
            None,
            0,
        );
        let info = gobject_ffi::GInterfaceInfo {
            interface_init: Some(interface_init),
            interface_finalize: None,
            interface_data: std::ptr::null_mut(),
        };
        gobject_ffi::g_type_add_interface_static(ty, ffi::gtk_accessible_text_get_type(), &info);
        ty
    })
}

type Allocate = unsafe extern "C" fn(*mut ffi::GtkWidget, c_int, c_int, c_int);
type Measure =
    unsafe extern "C" fn(*mut ffi::GtkWidget, ffi::GtkOrientation, c_int, *mut c_int, *mut c_int, *mut c_int, *mut c_int);
static PARENT_ALLOCATE: OnceLock<Allocate> = OnceLock::new();
static PARENT_MEASURE: OnceLock<Measure> = OnceLock::new();
/// The entry's `border-spacing` in GTK's theme, the gap GtkPasswordEntry
/// leaves before its own icons (gtkpasswordentry.c's size_allocate).
const EYE_SPACING: i32 = 6;

/// GtkPasswordEntry allocates only the children it knows (gtkpasswordentry.c,
/// 4.20.3), so the eye takes the trailing slot its peek icon would.
unsafe extern "C" fn class_init(klass: gpointer, _data: gpointer) {
    unsafe {
        let parent = gobject_ffi::g_type_class_peek_parent(klass) as *const ffi::GtkWidgetClass;
        let _ = PARENT_ALLOCATE.set((*parent).size_allocate.expect("GtkPasswordEntry allocates"));
        let _ = PARENT_MEASURE.set((*parent).measure.expect("GtkPasswordEntry measures"));
        let class = klass as *mut ffi::GtkWidgetClass;
        (*class).size_allocate = Some(size_allocate);
        (*class).measure = Some(measure);
    }
}

fn shown_eye(widget: *mut ffi::GtkWidget) -> Option<gtk4::Button> {
    let entry: glib::translate::Borrowed<gtk4::Widget> = unsafe { from_glib_borrow(widget) };
    eye_of(&*entry).filter(|eye| eye.is_visible())
}

unsafe extern "C" fn size_allocate(widget: *mut ffi::GtkWidget, width: c_int, height: c_int, baseline: c_int) {
    let parent = PARENT_ALLOCATE.get().expect("class_init ran");
    let Some(eye) = shown_eye(widget) else {
        return unsafe { parent(widget, width, height, baseline) };
    };
    let (_, natural, _, _) = eye.measure(gtk4::Orientation::Horizontal, -1);
    unsafe { parent(widget, (width - natural - EYE_SPACING).max(0), height, baseline) };
    eye.size_allocate(&gtk4::Allocation::new(width - natural, 0, natural, height), baseline);
}

unsafe extern "C" fn measure(
    widget: *mut ffi::GtkWidget,
    orientation: ffi::GtkOrientation,
    for_size: c_int,
    minimum: *mut c_int,
    natural: *mut c_int,
    minimum_baseline: *mut c_int,
    natural_baseline: *mut c_int,
) {
    unsafe {
        (PARENT_MEASURE.get().expect("class_init ran"))(
            widget, orientation, for_size, minimum, natural, minimum_baseline, natural_baseline,
        );
        let Some(eye) = shown_eye(widget) else { return };
        let horizontal = orientation == ffi::GTK_ORIENTATION_HORIZONTAL;
        let (eye_min, eye_nat, _, _) =
            eye.measure(if horizontal { gtk4::Orientation::Horizontal } else { gtk4::Orientation::Vertical }, -1);
        if horizontal {
            *minimum += eye_min + EYE_SPACING;
            *natural += eye_nat + EYE_SPACING;
        } else {
            *minimum = (*minimum).max(eye_min);
            *natural = (*natural).max(eye_nat);
        }
    }
}

pub(super) fn password_entry() -> gtk4::PasswordEntry {
    let ty: glib::Type = unsafe { from_glib(masked_type()) };
    let entry = glib::Object::with_type(ty)
        .downcast::<gtk4::PasswordEntry>()
        .expect("KayaPasswordEntry derives GtkPasswordEntry");
    forward_updates(&entry);
    entry
}

/// docs/reveal-plan.md V2 and V5: the user's flip reaches the app as `toggled`,
/// and a shown password leaves by no route the masked one refuses — the
/// clipboard, the PRIMARY selection, a drag.
pub(super) fn reveal_doors(
    entry: &gtk4::PasswordEntry,
    tag: &[u8],
    sink: &crate::protocol::OccSink,
    quiet: &std::rc::Rc<std::cell::Cell<bool>>,
) {
    let Some(text) = inner_text(entry) else { return };
    let (tag, sink, quiet) = (tag.to_vec(), sink.clone(), quiet.clone());
    text.connect_notify_local(Some("visibility"), move |t, _| {
        if !quiet.get() {
            sink.send_toggle_tag(&tag, gtk4::Text::is_visible(t));
        }
    });
    for signal in ["copy-clipboard", "cut-clipboard"] {
        text.connect_local(signal, false, move |values| {
            let t = values.first()?.get::<gtk4::Text>().ok()?;
            if gtk4::Text::is_visible(&t) {
                t.stop_signal_emission_by_name(signal);
                t.error_bell();
            }
            None
        });
    }
    let press = gtk4::GestureClick::new();
    press.set_button(gtk4::gdk::BUTTON_PRIMARY);
    press.set_propagation_phase(gtk4::PropagationPhase::Capture);
    press.connect_pressed(|g, n, _, _| {
        let Some(t) = g.widget().and_then(|w| w.downcast::<gtk4::Text>().ok()) else { return };
        let extending = g.current_event_state().contains(gtk4::gdk::ModifierType::SHIFT_MASK);
        if n == 1 && !extending && gtk4::Text::is_visible(&t) {
            if let Some((start, _)) = gtk4::prelude::EditableExt::selection_bounds(&t) {
                gtk4::prelude::EditableExt::select_region(&t, start, start);
            }
        }
    });
    text.add_controller(press);
    let weak = text.downgrade();
    text.primary_clipboard().connect_changed(move |clipboard| {
        let Some(t) = weak.upgrade() else { return };
        let Some(content) = clipboard.content() else { return };
        if clipboard.is_local() && t.has_focus() && content.type_().name() == "GtkTextContent" {
            refuse_while_shown(&content, &t);
        }
    });
}

/// docs/reveal-plan.md V10: GTK's peek icon is an image no key reaches, so the
/// eye is a button of kaya's, the peek icon's glyphs and GTK's own words for
/// them, at the entry's trailing edge. A pointer click leaves the focus where
/// it was (V6); Tab reaches it.
pub(super) fn eye(entry: &gtk4::PasswordEntry) {
    let Some(text) = inner_text(entry) else { return };
    let eye = gtk4::Button::new();
    eye.set_widget_name(EYE);
    eye.add_css_class("flat");
    eye.add_css_class("image-button");
    eye.set_focus_on_click(false);
    eye.set_valign(gtk4::Align::Center);
    eye.set_visible(false);
    eye.set_parent(entry);
    dress_eye(&eye, gtk4::Text::is_visible(&text));
    let weak = text.downgrade();
    eye.connect_clicked(move |_| {
        if let Some(t) = weak.upgrade() {
            t.set_visibility(!gtk4::Text::is_visible(&t));
        }
    });
    let weak = eye.downgrade();
    text.connect_notify_local(Some("visibility"), move |t, _| {
        if let Some(eye) = weak.upgrade() {
            dress_eye(&eye, gtk4::Text::is_visible(t));
        }
    });
    entry.connect_destroy(|entry| {
        if let Some(eye) = eye_of(entry) {
            eye.unparent();
        }
    });
}

const EYE: &str = "kaya-reveal-eye";

pub(super) fn eye_of(entry: &impl IsA<gtk4::Widget>) -> Option<gtk4::Button> {
    let mut child = entry.as_ref().first_child();
    while let Some(widget) = child {
        if widget.widget_name() == EYE {
            return widget.downcast::<gtk4::Button>().ok();
        }
        child = widget.next_sibling();
    }
    None
}

fn dress_eye(eye: &gtk4::Button, shown: bool) {
    let (icon, words) =
        if shown { ("view-conceal-symbolic", "Hide Text") } else { ("view-reveal-symbolic", "Show Text") };
    let words = glib::dgettext(Some("gtk40"), words);
    eye.set_icon_name(icon);
    eye.set_tooltip_text(Some(&words));
    eye.update_property(&[gtk4::accessible::Property::Label(&words)]);
}

thread_local! {
    static SELECTIONS: std::cell::RefCell<Vec<(usize, glib::WeakRef<gtk4::Text>)>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

type GetValue = unsafe extern "C" fn(
    *mut gtk4::gdk::ffi::GdkContentProvider,
    *mut gobject_ffi::GValue,
    *mut *mut glib::ffi::GError,
) -> glib::ffi::gboolean;

static TEXT_GET_VALUE: OnceLock<GetValue> = OnceLock::new();

fn refuse_while_shown(content: &gtk4::gdk::ContentProvider, text: &gtk4::Text) {
    let at = content.as_ptr() as usize;
    SELECTIONS.with(|s| {
        let mut s = s.borrow_mut();
        s.retain(|(_, w)| w.upgrade().is_some());
        if !s.iter().any(|(p, _)| *p == at) {
            s.push((at, text.downgrade()));
        }
    });
    TEXT_GET_VALUE.get_or_init(|| unsafe {
        let class = gobject_ffi::g_type_class_peek(content.type_().into_glib())
            as *mut gtk4::gdk::ffi::GdkContentProviderClass;
        let original = (*class).get_value.expect("GtkTextContent reads its selection");
        (*class).get_value = Some(selection_value);
        original
    });
}

unsafe extern "C" fn selection_value(
    provider: *mut gtk4::gdk::ffi::GdkContentProvider,
    value: *mut gobject_ffi::GValue,
    error: *mut *mut glib::ffi::GError,
) -> glib::ffi::gboolean {
    let shown = SELECTIONS.with(|s| {
        s.borrow()
            .iter()
            .find(|(p, _)| *p == provider as usize)
            .and_then(|(_, w)| w.upgrade())
            .is_some_and(|t| gtk4::Text::is_visible(&t))
    });
    unsafe {
        if shown {
            glib::ffi::g_set_error_literal(
                error,
                gtk4::gio::ffi::g_io_error_quark(),
                gtk4::gio::ffi::G_IO_ERROR_PERMISSION_DENIED,
                c"a revealed secure field's selection is not offered".as_ptr(),
            );
            return glib::ffi::GFALSE;
        }
        (TEXT_GET_VALUE.get().expect("patched before any read"))(provider, value, error)
    }
}

fn inner_text(entry: &gtk4::PasswordEntry) -> Option<gtk4::Text> {
    gtk4::prelude::EditableExt::delegate(entry).and_then(|d| d.downcast::<gtk4::Text>().ok())
}

fn forward_updates(entry: &gtk4::PasswordEntry) {
    let Some(text) = inner_text(entry) else { return };
    let weak = entry.downgrade();
    text.connect_local("insert-text", true, move |values| {
        let entry = weak.upgrade()?;
        let inserted: Option<glib::GString> = values.get(1).and_then(|v| v.get().ok());
        let length: i32 = values.get(2).and_then(|v| v.get().ok()).unwrap_or(-1);
        let position: glib::ffi::gpointer =
            values.get(3).and_then(|v| v.get::<glib::Pointer>().ok())?;
        let inserted = inserted?;
        let bytes = if length < 0 { inserted.len() } else { (length as usize).min(inserted.len()) };
        let chars = inserted.as_str().get(..bytes).unwrap_or("").chars().count() as u32;
        let end = unsafe { *(position as *const i32) }.max(0) as u32;
        if let Some(a) = entry.dynamic_cast_ref::<gtk4::AccessibleText>() {
            a.update_contents(AccessibleTextContentChange::Insert, end.saturating_sub(chars), end);
        }
        None
    });
    let weak = entry.downgrade();
    gtk4::prelude::EditableExt::connect_delete_text(&text, move |t, start, end| {
        let Some(entry) = weak.upgrade() else { return };
        let end = if end < 0 { gtk4::prelude::EditableExt::text(t).chars().count() as i32 } else { end };
        if let Some(a) = entry.dynamic_cast_ref::<gtk4::AccessibleText>() {
            a.update_contents(AccessibleTextContentChange::Remove, start.max(0) as u32, end.max(0) as u32);
        }
    });
    let weak = entry.downgrade();
    text.connect_notify_local(Some("cursor-position"), move |_, _| {
        if let Some(a) = weak.upgrade().as_ref().and_then(|e| e.dynamic_cast_ref::<gtk4::AccessibleText>()) {
            a.update_caret_position();
        }
    });
    let weak = entry.downgrade();
    text.connect_notify_local(Some("selection-bound"), move |_, _| {
        if let Some(a) = weak.upgrade().as_ref().and_then(|e| e.dynamic_cast_ref::<gtk4::AccessibleText>()) {
            a.update_selection_bound();
        }
    });
}

unsafe fn delegate(
    this: *mut ffi::GtkAccessibleText,
) -> Option<(*mut ffi::GtkAccessibleText, *const ffi::GtkAccessibleTextInterface)> {
    unsafe {
        let text = ffi::gtk_editable_get_delegate(this as *mut ffi::GtkEditable);
        if text.is_null()
            || gobject_ffi::g_type_check_instance_is_a(
                text as *mut gobject_ffi::GTypeInstance,
                ffi::gtk_text_get_type(),
            ) == 0
        {
            return None;
        }
        let class = (*(text as *mut gobject_ffi::GTypeInstance)).g_class;
        let iface = gobject_ffi::g_type_interface_peek(class as gpointer, ffi::gtk_accessible_text_get_type())
            as *const ffi::GtkAccessibleTextInterface;
        (!iface.is_null()).then_some((text as *mut ffi::GtkAccessibleText, iface))
    }
}

unsafe fn empty_bytes() -> *mut glib::ffi::GBytes {
    unsafe {
        glib::ffi::g_bytes_new(c"".as_ptr() as *const _, 1)
    }
}

unsafe extern "C" fn get_contents(
    this: *mut ffi::GtkAccessibleText,
    start: c_uint,
    end: c_uint,
) -> *mut glib::ffi::GBytes {
    unsafe {
        match delegate(this).and_then(|(t, i)| (*i).get_contents.map(|f| f(t, start, end))) {
            Some(bytes) if !bytes.is_null() => bytes,
            _ => empty_bytes(),
        }
    }
}

unsafe extern "C" fn get_contents_at(
    this: *mut ffi::GtkAccessibleText,
    offset: c_uint,
    granularity: ffi::GtkAccessibleTextGranularity,
    start: *mut c_uint,
    end: *mut c_uint,
) -> *mut glib::ffi::GBytes {
    unsafe {
        match delegate(this).and_then(|(t, i)| (*i).get_contents_at.map(|f| f(t, offset, granularity, start, end))) {
            Some(bytes) if !bytes.is_null() => bytes,
            _ => {
                *start = 0;
                *end = 0;
                empty_bytes()
            }
        }
    }
}

unsafe extern "C" fn get_caret_position(this: *mut ffi::GtkAccessibleText) -> c_uint {
    unsafe {
        delegate(this).and_then(|(t, i)| (*i).get_caret_position.map(|f| f(t))).unwrap_or(0)
    }
}

unsafe extern "C" fn get_selection(
    this: *mut ffi::GtkAccessibleText,
    n_ranges: *mut usize,
    ranges: *mut *mut ffi::GtkAccessibleTextRange,
) -> glib::ffi::gboolean {
    unsafe {
        delegate(this).and_then(|(t, i)| (*i).get_selection.map(|f| f(t, n_ranges, ranges))).unwrap_or(0)
    }
}

unsafe extern "C" fn get_attributes(
    this: *mut ffi::GtkAccessibleText,
    offset: c_uint,
    n_ranges: *mut usize,
    ranges: *mut *mut ffi::GtkAccessibleTextRange,
    names: *mut *mut *mut c_char,
    values: *mut *mut *mut c_char,
) -> glib::ffi::gboolean {
    unsafe {
        delegate(this)
            .and_then(|(t, i)| (*i).get_attributes.map(|f| f(t, offset, n_ranges, ranges, names, values)))
            .unwrap_or(0)
    }
}

unsafe extern "C" fn get_default_attributes(
    this: *mut ffi::GtkAccessibleText,
    names: *mut *mut *mut c_char,
    values: *mut *mut *mut c_char,
) {
    unsafe {
        match delegate(this).and_then(|(t, i)| (*i).get_default_attributes.map(|f| (t, f))) {
            Some((t, f)) => f(t, names, values),
            None => {
                *names = glib::ffi::g_malloc0(std::mem::size_of::<*mut c_char>()) as *mut *mut c_char;
                *values = glib::ffi::g_malloc0(std::mem::size_of::<*mut c_char>()) as *mut *mut c_char;
            }
        }
    }
}

unsafe extern "C" fn get_extents(
    this: *mut ffi::GtkAccessibleText,
    start: c_uint,
    end: c_uint,
    extents: *mut gtk4::graphene::ffi::graphene_rect_t,
) -> glib::ffi::gboolean {
    unsafe {
        delegate(this).and_then(|(t, i)| (*i).get_extents.map(|f| f(t, start, end, extents))).unwrap_or(0)
    }
}

unsafe extern "C" fn get_offset(
    this: *mut ffi::GtkAccessibleText,
    point: *const gtk4::graphene::ffi::graphene_point_t,
    offset: *mut c_uint,
) -> glib::ffi::gboolean {
    unsafe {
        delegate(this).and_then(|(t, i)| (*i).get_offset.map(|f| f(t, point, offset))).unwrap_or(0)
    }
}

unsafe extern "C" fn interface_init(iface: gpointer, _data: gpointer) {
    unsafe {
        let iface = iface as *mut ffi::GtkAccessibleTextInterface;
        (*iface).get_contents = Some(get_contents);
        (*iface).get_contents_at = Some(get_contents_at);
        (*iface).get_caret_position = Some(get_caret_position);
        (*iface).get_selection = Some(get_selection);
        (*iface).get_attributes = Some(get_attributes);
        (*iface).get_default_attributes = Some(get_default_attributes);
        (*iface).get_extents = Some(get_extents);
        (*iface).get_offset = Some(get_offset);
    }
}
