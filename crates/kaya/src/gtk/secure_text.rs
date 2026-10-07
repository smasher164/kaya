// docs/traps.md, "GTK 4.18 hands a password entry's text to every AT-SPI
// client": a GtkPasswordEntry that implements GtkAccessibleText, answered by
// its own GtkText's implementation, which reads the display text.

use gtk4::glib::{self, ffi::gpointer, gobject_ffi, translate::*};
use gtk4::prelude::*;
use gtk4::{ffi, AccessibleTextContentChange};
use std::ffi::{c_char, c_uint};
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
            None,
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

pub(super) fn password_entry() -> gtk4::PasswordEntry {
    let ty: glib::Type = unsafe { from_glib(masked_type()) };
    let entry = glib::Object::with_type(ty)
        .downcast::<gtk4::PasswordEntry>()
        .expect("KayaPasswordEntry derives GtkPasswordEntry");
    forward_updates(&entry);
    entry
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
