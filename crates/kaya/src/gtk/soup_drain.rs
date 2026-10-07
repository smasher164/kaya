// docs/traps.md: GStreamer 1.28.7 drains an HLS download context on the
// thread that stops the pipeline. tools/check-verbs.py holds the wiring.

use gtk4::glib::{ffi as gffi, gobject_ffi};
use std::cell::{Cell, RefCell};
use std::ffi::{c_int, c_uint};
use std::sync::atomic::{AtomicBool, Ordering};

const GUARD_PRIORITY: c_int = gffi::G_PRIORITY_HIGH - 1000;

thread_local! {
    static DEPTH: Cell<u32> = const { Cell::new(0) };
    static PUSHED: RefCell<Vec<usize>> = const { RefCell::new(Vec::new()) };
}

struct Funcs(gffi::GSourceFuncs);
unsafe impl Sync for Funcs {}

static FUNCS: Funcs = Funcs(gffi::GSourceFuncs {
    prepare: Some(prepare),
    check: Some(check),
    dispatch: Some(dispatch),
    finalize: None,
    closure_callback: None,
    closure_marshal: None,
});

fn funcs() -> *mut gffi::GSourceFuncs {
    &FUNCS.0 as *const gffi::GSourceFuncs as *mut gffi::GSourceFuncs
}

unsafe fn ready(source: *mut gffi::GSource) -> bool {
    DEPTH.with(|d| d.get()) > 0
        && unsafe { gffi::g_main_context_get_thread_default() != gffi::g_source_get_context(source) }
}

unsafe extern "C" fn prepare(source: *mut gffi::GSource, timeout: *mut c_int) -> gffi::gboolean {
    if !timeout.is_null() {
        unsafe { *timeout = -1 };
    }
    unsafe { ready(source) as gffi::gboolean }
}

unsafe extern "C" fn check(source: *mut gffi::GSource) -> gffi::gboolean {
    unsafe { ready(source) as gffi::gboolean }
}

unsafe extern "C" fn dispatch(
    source: *mut gffi::GSource,
    _callback: gffi::GSourceFunc,
    _data: gffi::gpointer,
) -> gffi::gboolean {
    static SAID: AtomicBool = AtomicBool::new(false);
    let context = unsafe { gffi::g_source_get_context(source) };
    unsafe { gffi::g_main_context_push_thread_default(context) };
    PUSHED.with_borrow_mut(|p| p.push(context as usize));
    if !SAID.swap(true, Ordering::Relaxed) {
        eprintln!(
            "kaya: GStreamer iterated a download context on the thread stopping its pipeline; kaya made it \
             that thread's default for the stop (gstreamer#5296, docs/traps.md)"
        );
    }
    gffi::GTRUE
}

unsafe extern "C" fn unused(_: gffi::gpointer) -> gffi::gboolean {
    gffi::GFALSE
}

unsafe extern "C" fn request_queued(
    _hint: *mut gobject_ffi::GSignalInvocationHint,
    _n: c_uint,
    _params: *const gobject_ffi::GValue,
    _data: gffi::gpointer,
) -> gffi::gboolean {
    unsafe {
        let context = gffi::g_main_context_get_thread_default();
        if context.is_null() || context == gffi::g_main_context_default() {
            return gffi::GTRUE;
        }
        if gffi::g_main_context_find_source_by_funcs_user_data(context, funcs(), std::ptr::null_mut()).is_null() {
            let source = gffi::g_source_new(funcs(), std::mem::size_of::<gffi::GSource>() as c_uint);
            gffi::g_source_set_priority(source, GUARD_PRIORITY);
            gffi::g_source_set_callback(source, Some(unused), std::ptr::null_mut(), None);
            gffi::g_source_set_name(source, c"kaya soup drain".as_ptr());
            gffi::g_source_attach(source, context);
            gffi::g_source_unref(source);
        }
    }
    gffi::GTRUE
}

pub(super) fn install() {
    static INSTALLED: AtomicBool = AtomicBool::new(false);
    if INSTALLED.load(Ordering::Acquire) {
        return;
    }
    unsafe {
        let ty = gobject_ffi::g_type_from_name(c"SoupSession".as_ptr());
        if ty == 0 {
            return;
        }
        let id = gobject_ffi::g_signal_lookup(c"request-queued".as_ptr(), ty);
        if INSTALLED.swap(true, Ordering::AcqRel) || id == 0 {
            return;
        }
        gobject_ffi::g_signal_add_emission_hook(id, 0, Some(request_queued), std::ptr::null_mut(), None);
    }
}

pub(super) fn scope<R>(f: impl FnOnce() -> R) -> R {
    struct Leave(usize);
    impl Drop for Leave {
        fn drop(&mut self) {
            DEPTH.with(|d| d.set(d.get() - 1));
            while let Some(context) = PUSHED.with_borrow_mut(|p| (p.len() > self.0).then(|| p.pop()).flatten()) {
                unsafe { gffi::g_main_context_pop_thread_default(context as *mut gffi::GMainContext) };
            }
        }
    }
    DEPTH.with(|d| d.set(d.get() + 1));
    let _leave = Leave(PUSHED.with_borrow(|p| p.len()));
    f()
}
