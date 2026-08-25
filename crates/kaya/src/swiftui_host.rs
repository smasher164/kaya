//! Runtime dispatch to the SwiftUI backend, the one backend on macOS and
//! iOS. The Swift half is a dylib (tools/swiftui/build-dylib.sh) exporting
//! kaya_swiftui_run, found via KAYA_SWIFTUI_LIB or the default dyld search.
//!
//! The host hands the backend an explicit table of function pointers
//! (KayaHostApi) rather than letting the dylib bind kaya symbols through
//! the dynamic linker: a host may carry kaya statically (a Rust
//! executable) or load it RTLD_LOCAL (ctypes), so the vtable is what pins
//! the one live kaya instance.

use std::ffi::{CString, c_char, c_int, c_void};

use crate::capi::{
    kaya_blob_data, kaya_emit_clicked, kaya_emit_text_changed, kaya_emit_toggled,
    kaya_emit_value_changed, kaya_next_commands,
};

/// Redeem a picked file: the locator the backend answered the pick with,
/// the mode, and out-parameters for seekability. Returns the descriptor
/// the guest now owns, or -1 with `out_error` filled.
///
/// The backend starts the security scope, opens, and stops it INSIDE this
/// call: the scope is a kernel-tracked resource with a concurrency limit
/// that leaks if held, and the descriptor outlives it (DESIGN.md,
/// measurements 2 and 3).
pub type PickedOpener = unsafe extern "C" fn(
    locator: *const c_char,
    mode: u32,
    out_seekable: *mut u32,
    out_error: *mut *const c_char,
) -> i64;

/// Set when the loaded backend exports an opener. Read by the phones'
/// `PickedSource` when a guest redeems a handle.
pub(crate) static PICKED_OPENER: std::sync::OnceLock<PickedOpener> = std::sync::OnceLock::new();

/// A picked file on iOS: the locator the backend answered with, opened
/// through the backend on every redemption — the same shape as Android's
/// `UriSource`. iOS has a good-looking POSIX path for a picked file and it
/// is a TRAP: re-opening it once the security scope drops fails with EPERM
/// (DESIGN.md, measurement 4), so a `PathSource` here would work in the
/// simulator, which enforces no sandbox, and fail on a device. What
/// survives is the URL OBJECT, which re-acquires its scope (measurement
/// 5), and only the backend can hold one.
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
            // The backend's own sentence names the platform's reason (a
            // dropped scope, a file that moved, a mode the document does
            // not allow); a bare code would send the guest looking in the
            // wrong place.
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

    /// EMPTY, and measured: iOS HAS a path for the picked file and
    /// re-opening it after the scope drops is DENIED, so publishing it
    /// would hand the guest something that looks usable and is not.
    fn local_path(&self) -> &str {
        ""
    }

    /// The backend's own name for the URL it holds — unusable as a path,
    /// and what the backend needs handed back to put the file on a
    /// pasteboard.
    fn locator(&self) -> &str {
        &self.locator
    }
}

/// The presentation-side functions handed to a guest-language backend.
/// next_commands blocks until a transaction resolves, then borrows out
/// that batch's apply-op records (KAYA_APPLY_*): it writes a core-owned
/// pointer and returns the byte length, 0 (pointer NULLed) on shutdown.
/// blob_data resolves a blob value's u64 handle to (pointer, length),
/// NULL for a dead handle. BOTH BORROWS DIE AT THE NEXT next_commands
/// call — the batch's bytes and its blob table together — so fetch and
/// decode within the batch. THERE IS NO SIZE CAP on either.
#[repr(C)]
pub struct KayaHostApi {
    pub emit_clicked: unsafe extern "C" fn(*const u8, usize),
    pub next_commands: unsafe extern "C" fn(*mut *const u8) -> usize,
    /// An entry edit: the tag and the new text, plus the three facts only
    /// the backend holds — the window whose undo ledger this run of typing
    /// belongs to, whether the field is focused, and whether the edit is
    /// LEDGER-QUIET (a native undo the backend routed and reports through
    /// note_native_undo instead).
    pub emit_text_changed: unsafe extern "C" fn(*const u8, usize, *const u8, usize, u64, u8, u8),
    pub emit_toggled: unsafe extern "C" fn(*const u8, usize, u8),
    pub emit_value_changed: unsafe extern "C" fn(*const u8, usize, f64),
    pub blob_data: unsafe extern "C" fn(u64, *mut usize) -> *const u8,
    /// The protocol fingerprint (capi::kaya_spec_hash), asserted by the
    /// dylib against its own baked copy before pumping: a stale compiled
    /// dylib bypasses every source gate and would decode wire records with
    /// old constants.
    pub spec_hash: extern "C" fn() -> u64,
    /// close_requested for a veto_close window's chrome close;
    /// window_closed after a non-veto auxiliary closed natively.
    pub emit_close_requested: extern "C" fn(u64),
    pub emit_window_closed: extern "C" fn(u64),
    /// The alert's one answer (an ALERT_CHOICE value: an action index
    /// or the cancel sentinel). Retires the live alert id.
    pub emit_alert_result: extern "C" fn(u64, u32),
    /// The picker's answer: parallel arrays of `count` NUL-terminated
    /// paths and names, or count 0 for cancel.
    pub emit_file_dialog_result: unsafe extern "C" fn(
        u64,
        *const *const std::os::raw::c_char,
        *const *const std::os::raw::c_char,
        usize,
    ),
    /// The save dialog's answer: ONE locator and its name, or NULL for
    /// cancel. Its own entry rather than the picker's with a count of one,
    /// because it is what makes the destination CREATABLE — the core
    /// registers a source whose open creates.
    pub emit_save_dialog_result: unsafe extern "C" fn(
        u64,
        *const std::os::raw::c_char,
        *const std::os::raw::c_char,
    ),
    /// entry_popped after the user's back affordance popped natively (the
    /// core's stack reconciles inside this call); back_requested when the
    /// top entry's intercept_back is armed and nothing popped.
    pub emit_entry_popped: extern "C" fn(u64),
    pub emit_back_requested: extern "C" fn(u64),
    /// The user switched sections through the platform switcher
    /// (post-fact). A programmatic select_section never arrives here.
    pub emit_section_selected: extern "C" fn(u64, u64),
    /// Menu occurrences — ONE dispatch path for chrome clicks, shortcuts
    /// and harness activation (DESIGN.md, Menus). The pointer/length pair
    /// is the noun: the wire path CONTEXT_ATTACH_NODE handed the backend
    /// for a node-anchored context item, or NULL/0 for a bar or
    /// live-widget item. Programmatic writes never arrive here.
    pub emit_menu_activated: unsafe extern "C" fn(u64, *const u8, usize),
    pub emit_menu_toggled: unsafe extern "C" fn(u64, *const u8, usize, u8),
    pub emit_menu_value_changed: unsafe extern "C" fn(u64, *const u8, usize, f64),
    /// The clipboard's two answers. `emit_clipboard_result` takes the
    /// request id and a KayaRepresentation, NULL being the universal no;
    /// `emit_pasted` takes the widget's click tag verbatim and the
    /// representation that arrived, which is never absent.
    pub emit_clipboard_result:
        unsafe extern "C" fn(u64, *const crate::capi::KayaRepresentation),
    pub emit_pasted:
        unsafe extern "C" fn(*const u8, usize, *const crate::capi::KayaRepresentation),
    /// THE UNDO TIER (docs/undo-plan.md §3). `undo_route`/`redo_route`
    /// take the window, the focused widget (0 for none) and A4's one named
    /// query (the focused field's own CanUndo), and answer 0 nothing / 1
    /// the field's native stack / 2 the core's ledger. Asked once and used
    /// twice — enablement and activation are the same call — so a greyed
    /// Edit>Undo and an inert one cannot drift.
    ///
    /// `undo`/`redo` return nothing: the inverse's ops reach the backend
    /// through next_commands like any other apply, and the occurrence
    /// reaches the app through the sink.
    ///
    /// `note_native_undo` is the reconciliation sample after a NATIVE undo
    /// the backend routed — the field, the text the walk landed on, and
    /// whether it can still undo. The text_changed the same undo provokes
    /// carries the ledger-quiet flag, so one change is reported once.
    pub undo_route: extern "C" fn(u64, u64, u8) -> u32,
    pub redo_route: extern "C" fn(u64, u64, u8) -> u32,
    pub undo: extern "C" fn(u64),
    pub redo: extern "C" fn(u64),
    pub note_native_undo: unsafe extern "C" fn(u64, u64, *const u8, usize, u8),
    /// The stall watchdog's reading, for `expect_stall`. A READ rather
    /// than an emit, riding the vtable for the reason every emit does: a
    /// direct symbol binds whichever kaya the loader resolves, which is
    /// the wrong one on a static-Rust or RTLD_LOCAL-Python host.
    pub stalled_ms: extern "C" fn() -> u64,
    /// A column-header click: the sort tag delivered with SET_COLUMNS,
    /// verbatim, plus the 0-based column index (docs/tables-plan.md).
    pub emit_sort_requested: unsafe extern "C" fn(*const u8, usize, u32),
    /// The latched fault's sentence into a caller buffer, returning its
    /// true length; 0 for none. A READ, riding the vtable for the
    /// reason `stalled_ms` does. The harness asks once per step, so a
    /// transaction that died inside `Scene::apply` reddens the leg
    /// carrying its sentence instead of aborting the process
    /// (crates/kaya/src/fault.rs).
    pub fault: unsafe extern "C" fn(*mut u8, usize) -> usize,
    /// The harness's watch declaration (crates/kaya/src/fault.rs):
    /// called once at the top of the script runner, before any step,
    /// so an unwatched process still dies legibly while a watched leg
    /// reddens.
    pub fault_watch: extern "C" fn(),
    /// ROW WINDOWING (docs/virtualization-plan.md §3), backend plumbing
    /// and never app surface. `window_moved` is the report that narrows a
    /// For's band — before the first one the band is unbounded and every
    /// row realizes; `rows_measured` is the verify half, one extent per
    /// realized row; `scroll_to_row_*` map a row KEY to its index in the
    /// collection's current order (KAYA_ROW_NOT_FOUND for no answer), one
    /// entry per key type; `window_geometry` reads the band, the total
    /// and the arithmetic the core owns.
    pub window_moved: extern "C" fn(u64, u64, u64),
    pub rows_measured: unsafe extern "C" fn(u64, u64, *const f64, usize),
    pub scroll_to_row_str: unsafe extern "C" fn(u64, *const u8, usize) -> u64,
    pub scroll_to_row_i64: extern "C" fn(u64, i64) -> u64,
    pub window_geometry: unsafe extern "C" fn(u64, *mut crate::capi::KayaWindowGeometry),
}

unsafe extern "C" {
    fn dlopen(path: *const c_char, flag: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlerror() -> *const c_char;
}

const RTLD_NOW: c_int = 2;

/// What the loader said, or the fact that it said nothing.
///
/// A DIAGNOSTIC MAY ONLY PRINT WHAT IT MEASURED (invariant 3). The
/// assertion below used to answer a `dlopen` failure with one sentence —
/// "build it with tools/swiftui/build-dylib.sh and set KAYA_SWIFTUI_LIB"
/// — which is a CAUSE, and it was printed for every cause it did not
/// name. Measured 2026-08-18: fifty legs of a five-lane matrix died with
/// that sentence while the dylib was on disk, current, and named by
/// KAYA_SWIFTUI_LIB exactly as it asked for; the reader spent the next
/// twenty minutes looking for a build that had never gone wrong. This
/// asks the loader instead, and the loader's answer is the only thing
/// that can tell an absent file from a bad architecture from a missing
/// dependency from a process that has run out of file descriptors.
fn loader_said() -> String {
    // dlerror() is one-shot and thread-local: it clears on read, so it
    // is read EXACTLY ONCE, right after the failing call.
    let raw = unsafe { dlerror() };
    if raw.is_null() {
        return "the loader gave no reason (dlerror was empty)".to_owned();
    }
    unsafe { std::ffi::CStr::from_ptr(raw) }.to_string_lossy().into_owned()
}

/// Load the SwiftUI backend and enter its run loop on the calling
/// (main) thread. Returns the exit code if the loop ever returns.
pub(crate) fn run() -> i32 {
    let path = std::env::var("KAYA_SWIFTUI_LIB")
        .unwrap_or_else(|_| "libkaya_swiftui.dylib".to_string());
    let cpath = CString::new(path.clone()).unwrap();
    let handle = unsafe { dlopen(cpath.as_ptr(), RTLD_NOW) };
    if handle.is_null() {
        // The loader's own sentence FIRST, then two facts about the path
        // this process actually looked at — whether it is there and how
        // big it is. Between them they separate "never built" from
        // "half-written by a concurrent build" from "wrong architecture"
        // from "the process is out of descriptors".
        let said = loader_said();
        let seen = match std::fs::metadata(&path) {
            Ok(m) => format!("it is on disk, {} bytes", m.len()),
            Err(e) => format!("it is not readable from here ({e})"),
        };
        panic!(
            "could not load the SwiftUI backend from {path:?}: {said} — {seen}. \
             If the file is absent, build it with tools/swiftui/build-dylib.sh \
             and set KAYA_SWIFTUI_LIB; if it is there, the sentence above is \
             the loader's and names the real reason."
        );
    }
    let symbol = unsafe { dlsym(handle, c"kaya_swiftui_run".as_ptr()) };
    assert!(
        !symbol.is_null(),
        "kaya_swiftui_run not exported by {path:?}: {}",
        loader_said()
    );
    // THE ONE CALL THAT RUNS THE OTHER WAY: the vtable carries functions
    // the BACKEND calls on the core, and this is the core calling the
    // backend, so it is resolved by symbol exactly as `run` is. Redeeming
    // a picked handle on the phones means asking the backend, which holds
    // the security-scoped URL — the path EPERMs the moment the scope drops
    // (DESIGN.md, measurement 4).
    //
    // OPTIONAL BY DESIGN: a backend built before this existed still runs,
    // and only a guest that opens a picked file meets the absence, which
    // then says so.
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
        emit_save_dialog_result: crate::capi::kaya_emit_save_dialog_result,
        emit_entry_popped: crate::capi::kaya_emit_entry_popped,
        emit_back_requested: crate::capi::kaya_emit_back_requested,
        emit_section_selected: crate::capi::kaya_emit_section_selected,
        emit_menu_activated: crate::capi::kaya_emit_menu_activated,
        emit_menu_toggled: crate::capi::kaya_emit_menu_toggled,
        emit_menu_value_changed: crate::capi::kaya_emit_menu_value_changed,
        emit_clipboard_result: crate::capi::kaya_emit_clipboard_result,
        emit_pasted: crate::capi::kaya_emit_pasted,
        undo_route: crate::capi::kaya_undo_route,
        redo_route: crate::capi::kaya_redo_route,
        undo: crate::capi::kaya_undo,
        redo: crate::capi::kaya_redo,
        note_native_undo: crate::capi::kaya_note_native_undo,
        stalled_ms: crate::capi::kaya_stalled_ms,
        emit_sort_requested: crate::capi::kaya_emit_sort_requested,
        fault: crate::capi::kaya_fault,
        fault_watch: crate::capi::kaya_fault_watch,
        window_moved: crate::capi::kaya_window_moved,
        rows_measured: crate::capi::kaya_rows_measured,
        scroll_to_row_str: crate::capi::kaya_scroll_to_row_str,
        scroll_to_row_i64: crate::capi::kaya_scroll_to_row_i64,
        window_geometry: crate::capi::kaya_window_geometry,
    };
    let run: extern "C" fn(*const KayaHostApi) -> i32 =
        unsafe { std::mem::transmute(symbol) };
    run(&api)
}
