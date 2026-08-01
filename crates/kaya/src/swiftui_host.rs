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

/// Redeem a picked file: the locator the backend answered the pick
/// with, the mode, and out-parameters for seekability. Returns the
/// descriptor the guest now owns, or -1 with `out_error` filled.
///
/// The backend keeps the platform object the locator names — on iOS a
/// security-scoped URL, which is the only durable capability there —
/// and starts the scope, opens, and stops it INSIDE this call. That is
/// not a workaround: the scope is a kernel-tracked resource with a
/// concurrency limit that leaks if held, and the descriptor outlives it
/// (DESIGN.md, measurements 2 and 3).
pub type PickedOpener = unsafe extern "C" fn(
    locator: *const c_char,
    mode: u32,
    out_seekable: *mut u32,
    out_error: *mut *const c_char,
) -> i64;

/// Set when the loaded backend exports an opener. Read by the phones'
/// `PickedSource` when a guest redeems a handle.
pub(crate) static PICKED_OPENER: std::sync::OnceLock<PickedOpener> = std::sync::OnceLock::new();

/// A picked file on iOS: the locator the backend answered with, which it
/// can still redeem, opened through the backend on every redemption.
///
/// THE SAME SHAPE AS ANDROID'S `UriSource`, and for the same reason. iOS
/// has a perfectly good-looking POSIX path for a picked file and it is a
/// TRAP: re-opening it once the security scope drops fails with EPERM
/// (DESIGN.md, measurement 4), so a `PathSource` here would work in the
/// simulator — which enforces no sandbox at all — and fail on a device.
/// What survives is the URL OBJECT, which re-acquires its scope
/// (measurement 5), and only the backend can hold one.
#[cfg(target_os = "ios")]
pub(crate) struct UrlSource {
    pub name: String,
    pub locator: String,
}

#[cfg(target_os = "ios")]
impl crate::protocol::PickedSource for UrlSource {
    fn open(&self, mode: crate::protocol::FileMode) -> std::io::Result<(i64, bool)> {
        let opener = PICKED_OPENER.get().ok_or_else(|| {
            std::io::Error::other(
                "kaya: this SwiftUI backend exports no picked-file opener — rebuild it",
            )
        })?;
        let locator = CString::new(self.locator.as_str())
            .map_err(|e| std::io::Error::other(format!("kaya: the locator would not cross: {e}")))?;
        let mut seekable: u32 = 0;
        let mut error: *const c_char = std::ptr::null();
        let handle = unsafe {
            opener(
                locator.as_ptr(),
                crate::protocol::picked_mode_code(mode),
                &mut seekable,
                &mut error,
            )
        };
        if handle < 0 {
            // The backend's own sentence, which names the platform's
            // reason (a dropped scope, a file that moved, a mode the
            // document does not allow); a bare code would send the
            // guest looking in the wrong place.
            let why = if error.is_null() {
                "the backend refused the open and gave no reason".to_owned()
            } else {
                unsafe { std::ffi::CStr::from_ptr(error) }
                    .to_string_lossy()
                    .into_owned()
            };
            return Err(std::io::Error::other(format!("kaya: {why}")));
        }
        Ok((handle, seekable != 0))
    }

    fn name(&self) -> &str {
        &self.name
    }

    /// EMPTY, and measured rather than assumed: iOS HAS a path for the
    /// picked file and re-opening it after the scope drops is DENIED, so
    /// publishing it would hand the guest something that looks usable
    /// and is not — the one thing `local_path` exists to refuse.
    fn local_path(&self) -> &str {
        ""
    }
}

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
    /// The picker's answer: parallel arrays of `count` NUL-terminated
    /// paths and names, or count 0 for cancel. Through the vtable like
    /// every other emission — a direct symbol dies on static-Rust and
    /// RTLD_LOCAL-Python hosts.
    pub emit_file_dialog_result: unsafe extern "C" fn(
        u64,
        *const *const std::os::raw::c_char,
        *const *const std::os::raw::c_char,
        usize,
    ),
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
    /// Menu occurrence emits — ONE dispatch path for chrome clicks,
    /// shortcuts, and harness activation (DESIGN.md, Menus). The
    /// pointer/length pair is the noun: the wire path
    /// CONTEXT_ATTACH_NODE handed the backend for a node-anchored
    /// context item, or NULL/0 for a bar or live-widget item.
    /// Programmatic checked/value writes never arrive here — the echo
    /// doctrine.
    pub emit_menu_activated: unsafe extern "C" fn(u64, *const u8, usize),
    pub emit_menu_toggled: unsafe extern "C" fn(u64, *const u8, usize, u8),
    pub emit_menu_value_changed: unsafe extern "C" fn(u64, *const u8, usize, f64),
    /// The stall watchdog's reading, for `expect_stall`. A READ rather
    /// than an emit, and it rides the vtable for the same reason every
    /// emit does: a direct symbol binds whichever kaya the loader
    /// happens to resolve, which is the wrong one on a static-Rust or
    /// RTLD_LOCAL-Python host. The interpreter must ask the ONE live
    /// instance, or it reads a watchdog watching nothing.
    pub stalled_ms: extern "C" fn() -> u64,
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
    // THE ONE CALL THAT RUNS THE OTHER WAY, and it is resolved the same
    // way `run` is rather than through the vtable: the vtable carries
    // functions the BACKEND calls on the core, and this is the core
    // calling the backend. A picked file on the phones is a
    // security-scoped URL the backend has to keep — the path EPERMs the
    // moment the scope drops (DESIGN.md, measurement 4) — so redeeming
    // a handle means asking the backend, exactly as Android's source
    // asks the JVM.
    //
    // OPTIONAL BY DESIGN: a backend built before this existed still
    // runs, and only a guest that opens a picked file meets the
    // absence, which then says so.
    let opener = unsafe { dlsym(handle, c"kaya_swiftui_open_picked".as_ptr()) };
    if !opener.is_null() {
        let opener: PickedOpener = unsafe { std::mem::transmute(opener) };
        let _ = PICKED_OPENER.set(opener);
    }
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
        emit_file_dialog_result: crate::capi::kaya_emit_file_dialog_result,
        emit_entry_popped: crate::capi::kaya_emit_entry_popped,
        emit_back_requested: crate::capi::kaya_emit_back_requested,
        emit_section_selected: crate::capi::kaya_emit_section_selected,
        emit_menu_activated: crate::capi::kaya_emit_menu_activated,
        emit_menu_toggled: crate::capi::kaya_emit_menu_toggled,
        emit_menu_value_changed: crate::capi::kaya_emit_menu_value_changed,
        stalled_ms: crate::capi::kaya_stalled_ms,
    };
    let run: extern "C" fn(*const KayaHostApi) -> i32 =
        unsafe { std::mem::transmute(symbol) };
    run(&api)
}
