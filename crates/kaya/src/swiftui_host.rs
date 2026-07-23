//! Runtime dispatch to the SwiftUI backend. The Swift half lives in a
//! dylib (built by tools/swiftui/build-dylib.sh) exporting
//! kaya_swiftui_run, which is App.main() behind a C symbol.
//!
//! The host hands the backend an explicit table of function pointers
//! (KayaHostApi) rather than letting the dylib bind kaya symbols through
//! the dynamic linker: hosts may carry kaya statically (a Rust
//! executable) or load it RTLD_LOCAL (ctypes), so symbol-space coupling
//! is unreliable, and the vtable pins the one live kaya instance by
//! construction. The one backend on macOS and iOS; the dylib is found
//! via KAYA_SWIFTUI_LIB or the default dyld search.

use std::ffi::{CString, c_char, c_int, c_void};

use crate::capi::{
    kaya_blob_data, kaya_emit_clicked, kaya_emit_text_changed, kaya_emit_toggled,
    kaya_emit_value_changed, kaya_next_commands,
};

/// The presentation-side functions handed to a guest-language backend.
/// emit_clicked takes the click-tag bytes delivered with a widget's
/// CREATE record, verbatim. next_commands blocks until a transaction is
/// resolved and fills the buffer with apply-op records (KAYA_APPLY_*);
/// returns the byte length, 0 on shutdown. blob_data resolves a blob
/// value's u64 handle to (pointer, length) — handles are batch-local
/// and the pointer is valid until the next next_commands call, so fetch
/// and decode within the batch; NULL for a dead handle.
#[repr(C)]
pub struct KayaHostApi {
    pub emit_clicked: unsafe extern "C" fn(*const u8, usize),
    pub next_commands: unsafe extern "C" fn(*mut u8, usize) -> usize,
    pub emit_text_changed: unsafe extern "C" fn(*const u8, usize, *const u8, usize),
    pub emit_toggled: unsafe extern "C" fn(*const u8, usize, u8),
    pub emit_value_changed: unsafe extern "C" fn(*const u8, usize, f64),
    pub blob_data: unsafe extern "C" fn(u64, *mut usize) -> *const u8,
    /// The protocol fingerprint (capi::kaya_spec_hash). The dylib
    /// asserts it against its own baked copy before pumping — the
    /// stale-artifact guard for the presentation side, which check-verbs
    /// can only hold at SOURCE level (a stale compiled dylib bypasses
    /// source gates and would decode wire records with old constants).
    pub spec_hash: extern "C" fn() -> u64,
    /// Window lifecycle emits (slice 2): close_requested for a
    /// veto_close window's chrome close, window_closed after a
    /// non-veto auxiliary closed natively.
    pub emit_close_requested: extern "C" fn(u64),
    pub emit_window_closed: extern "C" fn(u64),
    /// The alert's one answer (an ALERT_CHOICE value: an action index
    /// or the cancel sentinel). Retires the live alert id.
    pub emit_alert_result: extern "C" fn(u64, u32),
    /// Navigation lifecycle emits: entry_popped after the user's back
    /// affordance popped natively (the core's stack reconciles inside
    /// this call), back_requested when the top entry's intercept_back
    /// is armed and nothing popped.
    pub emit_entry_popped: extern "C" fn(u64),
    pub emit_back_requested: extern "C" fn(u64),
    /// The user switched sections through the platform switcher
    /// (post-fact; the core's selection mirror reconciles inside this
    /// call). A programmatic select_section never arrives here — the
    /// echo doctrine.
    pub emit_section_selected: extern "C" fn(u64, u64),
}

unsafe extern "C" {
    fn dlopen(path: *const c_char, flag: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}

const RTLD_NOW: c_int = 2;

/// Load the SwiftUI backend and enter its run loop on the calling
/// (main) thread. Returns the exit code if the loop ever returns.
pub(crate) fn run() -> i32 {
    let path = std::env::var("KAYA_SWIFTUI_LIB")
        .unwrap_or_else(|_| "libkaya_swiftui.dylib".to_string());
    let cpath = CString::new(path.clone()).unwrap();
    let handle = unsafe { dlopen(cpath.as_ptr(), RTLD_NOW) };
    assert!(
        !handle.is_null(),
        "could not load the SwiftUI backend from {path:?}; build it with \
         tools/swiftui/build-dylib.sh and set KAYA_SWIFTUI_LIB"
    );
    let symbol = unsafe { dlsym(handle, c"kaya_swiftui_run".as_ptr()) };
    assert!(
        !symbol.is_null(),
        "kaya_swiftui_run not exported by {path:?}"
    );
    let api = KayaHostApi {
        emit_clicked: kaya_emit_clicked,
        next_commands: kaya_next_commands,
        emit_text_changed: kaya_emit_text_changed,
        emit_toggled: kaya_emit_toggled,
        emit_value_changed: kaya_emit_value_changed,
        blob_data: kaya_blob_data,
        spec_hash: crate::capi::kaya_spec_hash,
        emit_close_requested: crate::capi::kaya_emit_close_requested,
        emit_window_closed: crate::capi::kaya_emit_window_closed,
        emit_alert_result: crate::capi::kaya_emit_alert_result,
        emit_entry_popped: crate::capi::kaya_emit_entry_popped,
        emit_back_requested: crate::capi::kaya_emit_back_requested,
        emit_section_selected: crate::capi::kaya_emit_section_selected,
    };
    let run: extern "C" fn(*const KayaHostApi) -> i32 =
        unsafe { std::mem::transmute(symbol) };
    run(&api)
}
