//! Runtime dispatch to the SwiftUI backend. The Swift half lives in a
//! dylib (built by tools/swiftui/build-dylib.sh) exporting
//! kaya_swiftui_run, which is App.main() behind a C symbol.
//!
//! The host hands the backend an explicit table of function pointers
//! (KayaHostApi) rather than letting the dylib bind kaya symbols through
//! the dynamic linker: hosts may carry kaya statically (a Rust
//! executable) or load it RTLD_LOCAL (ctypes), so symbol-space coupling
//! is unreliable, and the vtable pins the one live kaya instance by
//! construction. Selected with KAYA_BACKEND=swiftui; the dylib is found
//! via KAYA_SWIFTUI_LIB or the default dyld search.

use std::ffi::{CString, c_char, c_int, c_void};

use crate::capi::{kaya_emit_button_clicked, kaya_next_commands};

/// The presentation-side functions handed to a guest-language backend.
/// next_commands blocks until a transaction is resolved and fills the
/// buffer with apply-op records (KAYA_APPLY_*); returns the byte length,
/// 0 on shutdown.
#[repr(C)]
pub struct KayaHostApi {
    pub emit_button_clicked: extern "C" fn(u64),
    pub next_commands: unsafe extern "C" fn(*mut u8, usize) -> usize,
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
        emit_button_clicked: kaya_emit_button_clicked,
        next_commands: kaya_next_commands,
    };
    let run: extern "C" fn(*const KayaHostApi) -> i32 =
        unsafe { std::mem::transmute(symbol) };
    run(&api)
}
