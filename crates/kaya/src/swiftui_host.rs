//! Runtime dispatch to the SwiftUI backend, the one backend on macOS and
//! iOS. The Swift half is a dylib (tools/swiftui/build-dylib.sh) exporting
//! kaya_swiftui_run, found via KAYA_SWIFTUI_LIB or the dyld search.
//!
//! The host hands the backend an explicit table of function pointers rather
//! than letting the dylib bind kaya symbols through the dynamic linker: a
//! host may carry kaya statically or load it RTLD_LOCAL, so the vtable is
//! what pins the one live kaya instance.

use std::ffi::{CString, c_char, c_int, c_void};

use crate::capi::{
    kaya_blob_count, kaya_blob_data, kaya_emit_clicked, kaya_emit_submitted, kaya_emit_text_changed,
    kaya_emit_toggled,
    kaya_emit_value_changed, kaya_emit_value_committed, kaya_next_commands, kaya_emit_date_changed,
    kaya_emit_time_changed,
};

/// Redeem a picked file: the locator, the mode, and out-parameters for
/// seekability. Returns the descriptor the guest now owns, or -1 with
/// `out_error` filled.
///
/// The backend starts the security scope, opens, and stops it INSIDE this
/// call — the scope is a kernel-tracked resource that leaks if held, and
/// the descriptor outlives it (DESIGN.md, measurements 2 and 3).
pub type PickedOpener = unsafe extern "C" fn(
    locator: *const c_char,
    mode: u32,
    out_seekable: *mut u32,
    out_error: *mut *const c_char,
) -> i64;

/// Set when the loaded backend exports an opener. Read by the phones'
/// `PickedSource` when a guest redeems a handle.
pub(crate) static PICKED_OPENER: std::sync::OnceLock<PickedOpener> = std::sync::OnceLock::new();

/// The capability query's platform half (docs/media-plan.md §8 ruling 1):
/// AVFoundation's own answer for a MIME type with its codecs, NUL-terminated.
pub type CanPlay = unsafe extern "C" fn(mime: *const c_char, codecs: *const c_char) -> u8;

pub(crate) static CAN_PLAY: std::sync::OnceLock<CanPlay> = std::sync::OnceLock::new();

/// AVFoundation's answer, or None when no backend that answers is loaded.
pub(crate) fn can_play(mime: &str, codecs: &str) -> Option<bool> {
    let query = CAN_PLAY.get()?;
    let mime = CString::new(mime).ok()?;
    let codecs = CString::new(codecs).ok()?;
    Some(unsafe { query(mime.as_ptr(), codecs.as_ptr()) } != 0)
}

/// A picked file on iOS: the locator the backend answered with, opened
/// through the backend on every redemption — Android's `UriSource` shape.
/// iOS's good-looking POSIX path is a TRAP: re-opening it once the
/// security scope drops fails with EPERM (DESIGN.md, measurement 4), so a
/// `PathSource` would work in the simulator and fail on a device. Only the
/// URL OBJECT re-acquires its scope, and only the backend can hold one.
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
/// next_commands blocks until a transaction resolves, then borrows out that
/// batch's apply-op records; blob_data resolves a blob handle to (pointer,
/// length), NULL for a dead one. BOTH BORROWS DIE AT THE NEXT next_commands
/// call, so fetch and decode within the batch. THERE IS NO SIZE CAP.
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
    /// The field submitted (docs/submit-plan.md S1): the tag and its text.
    pub emit_submitted: unsafe extern "C" fn(*const u8, usize, *const u8, usize),
    pub emit_toggled: unsafe extern "C" fn(*const u8, usize, u8),
    pub emit_value_changed: unsafe extern "C" fn(*const u8, usize, f64),
    /// The value a slider gesture settled on (docs/slider-plan.md S2).
    pub emit_value_committed: unsafe extern "C" fn(*const u8, usize, f64),
    /// The pickers' committed values, packed (docs/datetime-plan.md D2).
    pub emit_date_changed: unsafe extern "C" fn(*const u8, usize, i64),
    pub emit_time_changed: unsafe extern "C" fn(*const u8, usize, i64),
    /// docs/color-picker-plan.md §3 rule 1: the one quantizer, and the
    /// settled colour it answered.
    pub color_quantize: extern "C" fn(f64, f64, f64, f64) -> u32,
    pub emit_color_changed: unsafe extern "C" fn(*const u8, usize, i64),
    /// docs/range-plan.md §3 rule 2: the one clamp, and the pair it settled.
    pub range_clamp: extern "C" fn(f64, f64, f64, f64, u8, f64, f64) -> f64,
    pub emit_range: unsafe extern "C" fn(*const u8, usize, f64, f64, u8),
    /// docs/media-plan.md §2: a player's reports, through the core's state
    /// machine; each answers the player's state after it.
    pub player_loaded: unsafe extern "C" fn(u64, u64, u32, u32, u8, *const u8, usize) -> u32,
    pub player_rate: extern "C" fn(u64, u8) -> u32,
    pub player_ended: extern "C" fn(u64) -> u32,
    pub player_failed: unsafe extern "C" fn(u64, *const u8, usize, i64, i64, *const u8, usize) -> u32,
    pub player_position: extern "C" fn(u64, u64) -> u32,
    pub player_seeked: extern "C" fn(u64, u64) -> u32,
    pub player_overdue: extern "C" fn(u64) -> u32,
    /// docs/media-plan.md §3, §7b: the platform's tracks and cue, kaya's
    /// caption renderer's question, and a video view's visibility.
    pub player_tracks: unsafe extern "C" fn(u64, *const u8, usize, *const u8, usize, u32, u32) -> u32,
    pub player_cue: unsafe extern "C" fn(u64, *const u8, usize) -> u32,
    pub caption_at: unsafe extern "C" fn(u64, u64, *mut u8, usize) -> usize,
    /// docs/media-plan.md §3: an http(s) sidecar fetched by the platform.
    pub player_captions_text: unsafe extern "C" fn(u64, *const u8, usize, *const u8, usize) -> u32,
    pub player_captions_failed:
        unsafe extern "C" fn(u64, *const u8, usize, *const u8, usize, i64, i64, *const u8, usize) -> u32,
    pub video_visible: extern "C" fn(u64, f64),
    /// docs/media-plan.md §5: the core's route for a remote action, and the
    /// system playback state to publish after every report.
    pub session_action: extern "C" fn(u32, u64) -> u32,
    pub session_state: extern "C" fn() -> u32,
    pub blob_data: unsafe extern "C" fn(u64, *mut usize) -> *const u8,
    pub blob_count: unsafe extern "C" fn() -> u64,
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
    /// A notification's one answer (a NOTIFICATION_OUTCOME value):
    /// activated by the user, or refused by the platform.
    pub emit_notification_result: extern "C" fn(u64, u32),
    /// The text the user sent from a notification's reply field
    /// (docs/notification-reply-plan.md): UTF-8 bytes and their length.
    pub emit_notification_reply: unsafe extern "C" fn(u64, *const u8, usize),
    /// A URL the platform handed this app (docs/app-links-plan.md §4):
    /// the raw kAEGetURL Apple event on macOS, `.onOpenURL` on iOS. The
    /// interpreter parses nothing — the core matches the route.
    pub link_opened: unsafe extern "C" fn(*const std::os::raw::c_char),
    /// The runtime capability bits this host measured (KAYA_CAP_NOTIFICATIONS
    /// when the process is a bundle that can post), granted before the
    /// guest's first read.
    pub grant_capabilities: extern "C" fn(u64),
    /// The capability word as the core holds it (static bits plus the
    /// runtime ones it granted at startup) — the interpreter's ONE reading
    /// of whether this process can post a notification.
    pub capabilities: extern "C" fn() -> u64,
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
    /// sheet_dismissed after the user's cancel path closed a sheet natively
    /// (the core forgets the chain inside this call); dismiss_requested when
    /// the sheet's intercept_dismiss is armed and nothing went.
    pub emit_sheet_dismissed: extern "C" fn(u64),
    pub emit_dismiss_requested: extern "C" fn(u64),
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
    /// THE UNDO TIER (docs/undo-plan.md §3). `undo_route`/`redo_route` take
    /// the window, the focused widget (0 for none) and the field's own
    /// CanUndo, and answer 0 nothing / 1 the field's native stack / 2 the
    /// core's ledger — asked once and used twice, so a greyed Edit>Undo and
    /// an inert one cannot drift. `undo`/`redo` return nothing.
    /// `note_native_undo` is the reconciliation sample after a NATIVE undo:
    /// the same undo's text_changed carries the ledger-quiet flag, so one
    /// change is reported once.
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
    /// The drag arms (docs/dnd-plan.md D1, D2): a drop's occurrence with
    /// its point, verdict and anchor; a drag's end; and the pure verdict.
    pub emit_dropped: unsafe extern "C" fn(
        *const u8,
        usize,
        f64,
        f64,
        u32,
        *const u8,
        usize,
        u32,
        *const crate::capi::KayaRepresentation,
    ),
    pub emit_drag_ended: unsafe extern "C" fn(*const u8, usize, u32),
    pub drag_verdict: unsafe extern "C" fn(
        *const std::os::raw::c_char,
        u32,
        u32,
        *const std::os::raw::c_char,
        u32,
        u32,
    ) -> u32,
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
    /// ROW WINDOWING (docs/virtualization-plan.md §3), backend plumbing and
    /// never app surface. `window_moved` narrows a For's band (unbounded
    /// until the first report); `rows_measured` is the verify half;
    /// `scroll_to_row_*` map a row KEY to its index, one entry per key type
    /// (KAYA_ROW_NOT_FOUND for no answer); `window_geometry` reads the band.
    pub window_moved: extern "C" fn(u64, u64, u64),
    pub rows_measured: unsafe extern "C" fn(u64, u64, *const f64, usize),
    pub scroll_to_row_str: unsafe extern "C" fn(u64, *const u8, usize) -> u64,
    pub scroll_to_row_i64: extern "C" fn(u64, i64) -> u64,
    pub window_geometry: unsafe extern "C" fn(u64, *mut crate::capi::KayaWindowGeometry),
    /// One row's height, measured or presumed. The row-height delegate
    /// asks per row over the WHOLE collection, which the band-shaped
    /// geometry read cannot answer.
    pub row_extent: extern "C" fn(u64, u64) -> f64,
    /// THE CANVAS (docs/canvas-plan.md). `presentation` is the window's
    /// scale and appearance, reported so the core re-rasters; nothing
    /// about the drawing crosses the other way except the pixels on the
    /// apply channel. `canvas_probe` is the harness's read of the
    /// CANONICAL raster, composed in the core so five platforms compare
    /// a string kaya wrote.
    pub presentation: extern "C" fn(f64, bool),
    /// The toolkit's text scale, latched for apps (capi::kaya_text_scale_report;
    /// docs/compliance-plan.md §2.1).
    pub text_scale_report: extern "C" fn(f64),
    pub canvas_probe: unsafe extern "C" fn(u64, *mut u8, usize) -> usize,
    /// THE SIZE POLICY (docs/canvas-plan.md §3.2.1). `canvas_track` reports
    /// what layout assigned one canvas, in points. `frame` is the platform's
    /// frame drive at its OWN timestamp; `harness_frame` is the
    /// deterministic step a scene verb advances, kept in the core so three
    /// harnesses share one number. `canvas_raster_shape` is the harness's
    /// read of WHICH size the raster is.
    pub canvas_track: extern "C" fn(u64, f64, f64),
    /// The window's content size plus the platform's own size class
    /// (docs/adaptive-layout-plan.md D3; classes ruled 2026-08-31): the
    /// facts every declared breakpoint evaluates against, reported
    /// whenever either changes. The class is wire::SIZE_CLASS_COMPACT /
    /// _REGULAR on iOS, SIZE_CLASS_NONE on macOS (the core derives from
    /// the width there).
    pub window_metrics: extern "C" fn(u64, f64, f64, i64),
    pub frame: extern "C" fn(f64),
    pub harness_frame: extern "C" fn(),
    pub canvas_raster_shape: unsafe extern "C" fn(u64, *mut u8, usize) -> usize,
    /// KAYA'S OWN WINDOW MEMORY (docs/tasks-s4-plan.md P4). The key is
    /// RESERVED, so the guest floor (`kaya_pref_set_string`) refuses it and
    /// the backend reaches the store through these two instead — which is
    /// also what keeps `kaya.window.<id>.frame` spelled once, in
    /// crates/kaya/src/prefs.rs. `window_frame` answers 0 for none.
    pub window_frame: unsafe extern "C" fn(u64, *mut u8, usize) -> usize,
    pub set_window_frame: unsafe extern "C" fn(u64, *const u8, usize),
    /// RICH TEXT, presentation side (docs/rich-text-plan.md R4/R5/R9): the
    /// six reports an arm makes and the two reads the harness makes.
    pub text_composing: extern "C" fn(u64, u8),
    pub text_pending: unsafe extern "C" fn(u64, *const u8, usize, *const u8, usize, u8, u64),
    pub text_edit_source: extern "C" fn(u64, u32),
    pub text_reported_edit: extern "C" fn(u64, u64, u64, u64),
    pub text_selection: extern "C" fn(u64, u64, u64),
    pub text_formatted:
        unsafe extern "C" fn(*const u8, usize, u64, u64, *const u8, usize, *const u8, usize, u8),
    pub text_runs: unsafe extern "C" fn(u64, *mut u8, usize) -> usize,
    pub text_last_edit: unsafe extern "C" fn(u64, *mut u8, usize) -> usize,
    /// The `copy_asset` scene verb (capi::kaya_harness_copy_asset): the
    /// asset name and the expanded destination path, the sentence written
    /// into the buffer, `ok` set to 1 on success.
    pub copy_asset:
        unsafe extern "C" fn(*const u8, usize, *const u8, usize, *mut u8, usize, *mut u8) -> usize,
    /// docs/fullscreen-plan.md: the user's own door, never kaya's write.
    pub emit_fullscreen_changed: extern "C" fn(u64, u8),
    /// THE NUMBER FIELD'S RULES (docs/number-field-plan.md §3), one copy in
    /// the core: a value's text at a step, and what a commit or a step
    /// makes of the committed value — 0 revert, 1 unchanged, 2 moved with
    /// the new value written through the pointer.
    pub number_text: unsafe extern "C" fn(f64, f64, *mut u8, usize) -> usize,
    pub number_commit: unsafe extern "C" fn(*const u8, usize, f64, f64, f64, f64, *mut f64) -> u32,
    pub number_step: unsafe extern "C" fn(f64, i32, f64, f64, f64, *mut f64) -> u32,
    /// docs/media-plan.md §8 ruling 4: a reader's reports, through the core;
    /// frame and pcm answer 1 while the read is still wanted, overdue 1 when
    /// the core failed it `timeout`.
    pub reader_frame: unsafe extern "C" fn(u64, u64, u32, u64, u32, u32, *const u8, usize) -> u32,
    pub reader_pcm: unsafe extern "C" fn(u64, u64, u32, u32, *const f32, usize, u64) -> u32,
    pub reader_finished: extern "C" fn(u64, u64),
    pub reader_failed: unsafe extern "C" fn(u64, u64, *const u8, usize, i64, i64, *const u8, usize),
    pub reader_overdue: extern "C" fn(u64, u64) -> u32,
    /// docs/capture-plan.md: a capture's reports, its frames and samples on
    /// the capture thread, the synthetic devices and the harness's verbs.
    pub capture_state: unsafe extern "C" fn(u64, u32, u32, u32, u32, u32, *const u8, usize),
    pub capture_overdue: extern "C" fn(u64) -> u32,
    pub capture_permission: unsafe extern "C" fn(u32, u32, *const u8, usize),
    pub capture_devices_begin: extern "C" fn(),
    pub capture_device: unsafe extern "C" fn(*const u8, usize, *const u8, usize, u32, u32, u32),
    pub capture_devices_end: extern "C" fn(),
    pub capture_frame: unsafe extern "C" fn(u64, u32, u32, *const u8, u32, *const u8, u32, u64, u32) -> u32,
    pub capture_samples: unsafe extern "C" fn(u64, u32, u32, *const f32, usize, u64),
    pub capture_synthetic:
        unsafe extern "C" fn(u32, *mut u8, usize, *mut u8, usize, *mut u32, *mut u32, *mut u32, *mut u32) -> u32,
    pub capture_synthetic_permission: extern "C" fn(u32, u32) -> u32,
    pub capture_harness: unsafe extern "C" fn(u32, u32, *const u8, usize, *mut u8, usize, *mut u8) -> usize,
    pub reader_no_track: unsafe extern "C" fn(u64, u64, *const u8, usize),
    pub capture_nearest_format: unsafe extern "C" fn(*const u32, usize, f64, f64, f64, *mut u32) -> u32,
    pub capture_self_view_box: unsafe extern "C" fn(u32, u32, u32, i64, *mut u32),
    pub video_view_box: unsafe extern "C" fn(u32, u32, i64, *mut u32),
}

/// # Safety
/// `out` must be null or valid for `cap` bytes.
unsafe extern "C" fn number_text(value: f64, step: f64, out: *mut u8, cap: usize) -> usize {
    let text = crate::number_field::text(value, step);
    let bytes = text.as_bytes();
    if !out.is_null() && cap > 0 {
        let n = bytes.len().min(cap);
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, n) };
    }
    bytes.len()
}

fn number_answer(commit: crate::number_field::Commit, out: *mut f64) -> u32 {
    use crate::number_field::Commit;
    match commit {
        Commit::Revert => 0,
        Commit::Unchanged => 1,
        Commit::Moved(value) => {
            if !out.is_null() {
                unsafe { *out = value };
            }
            2
        }
    }
}

/// # Safety
/// `text` must be valid for `len` bytes; `out` must be null or valid.
unsafe extern "C" fn number_commit(
    text: *const u8,
    len: usize,
    committed: f64,
    min: f64,
    max: f64,
    step: f64,
    out: *mut f64,
) -> u32 {
    let bytes = if text.is_null() || len == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(text, len) } };
    let text = String::from_utf8_lossy(bytes);
    number_answer(crate::number_field::commit(&text, committed, min, max, step), out)
}

/// # Safety
/// `out` must be null or valid.
unsafe extern "C" fn number_step(committed: f64, steps: i32, min: f64, max: f64, step: f64, out: *mut f64) -> u32 {
    number_answer(crate::number_field::stepped(committed, steps, min, max, step), out)
}

/// # Safety
/// `out` must be null or valid for `cap` bytes.
unsafe extern "C" fn window_frame(window: u64, out: *mut u8, cap: usize) -> usize {
    let Some(text) = crate::prefs::window_frame(window) else { return 0 };
    let bytes = text.as_bytes();
    if !out.is_null() && cap > 0 {
        let n = bytes.len().min(cap);
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, n) };
    }
    bytes.len()
}

/// # Safety
/// `frame` must be valid for `len` bytes.
unsafe extern "C" fn set_window_frame(window: u64, frame: *const u8, len: usize) {
    if frame.is_null() || len == 0 {
        return;
    }
    let bytes = unsafe { std::slice::from_raw_parts(frame, len) };
    let Ok(text) = std::str::from_utf8(bytes) else { return };
    crate::prefs::set_window_frame(window, text);
}

unsafe extern "C" {
    fn dlopen(path: *const c_char, flag: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlerror() -> *const c_char;
    fn syslog(priority: c_int, format: *const c_char, ...);
}

/// LOG_USER | LOG_ERR.
const SYSLOG_USER_ERR: c_int = 8 | 3;

const RTLD_NOW: c_int = 2;

/// What the loader said, or the fact that it said nothing.
///
/// A DIAGNOSTIC MAY ONLY PRINT WHAT IT MEASURED (invariant 3): measured
/// 2026-08-18, fifty legs of a five-lane matrix died on the fixed sentence
/// "build it and set KAYA_SWIFTUI_LIB" while the dylib was on disk and
/// named exactly as it asked. Only the loader's own answer tells an absent
/// file from a bad architecture from a missing dependency.
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
    // BESIDE THE EXECUTABLE WHEN NOBODY SAYS OTHERWISE: a bundle carries
    // its own copy, and a process the PLATFORM started — a link opening
    // the app (docs/app-links-plan.md L5), a tap on a notification —
    // inherits no environment at all, so the lane's KAYA_SWIFTUI_LIB is
    // not there to read. The bare name is the last resort.
    let path = std::env::var("KAYA_SWIFTUI_LIB").ok().unwrap_or_else(|| {
        let beside = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|d| d.join("libkaya_swiftui.dylib")))
            .filter(|p| p.is_file());
        match beside {
            Some(p) => p.to_string_lossy().into_owned(),
            None => "libkaya_swiftui.dylib".to_string(),
        }
    });
    let cpath = CString::new(path.clone()).unwrap();
    let handle = unsafe { dlopen(cpath.as_ptr(), RTLD_NOW) };
    if handle.is_null() {
        // The loader's own sentence FIRST, then two facts about the path
        // this process looked at: whether it is there and how big it is.
        let said = loader_said();
        let seen = match std::fs::metadata(&path) {
            Ok(m) => format!("it is on disk, {} bytes", m.len()),
            Err(e) => format!("it is not readable from here ({e})"),
        };
        let sentence = format!(
            "could not load the SwiftUI backend from {path:?}: {said} — {seen}. \
             If the file is absent, build it with tools/swiftui/build-dylib.sh \
             and set KAYA_SWIFTUI_LIB, or package the app with its copy \
             beside the executable (tools/package.py mac); if it is there, \
             the sentence above is the loader's and names the real reason."
        );
        // The system log as well as stderr: a process the platform starts
        // has nowhere to print (docs/traps.md, the cold notification reply
        // of 2026-09-27).
        if let Ok(line) = CString::new(format!("kaya: {sentence}")) {
            unsafe { syslog(SYSLOG_USER_ERR, c"%s".as_ptr(), line.as_ptr()) };
        }
        panic!("{sentence}");
    }
    let symbol = unsafe { dlsym(handle, c"kaya_swiftui_run".as_ptr()) };
    assert!(
        !symbol.is_null(),
        "kaya_swiftui_run not exported by {path:?}: {}",
        loader_said()
    );
    // THE ONE CALL THAT RUNS THE OTHER WAY — the core calling the backend,
    // so it is resolved by symbol exactly as `run` is: redeeming a picked
    // handle on the phones means asking the backend, which holds the
    // security-scoped URL (DESIGN.md, measurement 4). OPTIONAL BY DESIGN,
    // so a backend built before this existed still runs and only a guest
    // that opens a picked file meets the absence.
    let opener = unsafe { dlsym(handle, c"kaya_swiftui_open_picked".as_ptr()) };
    if !opener.is_null() {
        let opener: PickedOpener = unsafe { std::mem::transmute(opener) };
        let _ = PICKED_OPENER.set(opener);
    }
    let can_play = unsafe { dlsym(handle, c"kaya_swiftui_can_play".as_ptr()) };
    if !can_play.is_null() {
        let can_play: CanPlay = unsafe { std::mem::transmute(can_play) };
        let _ = CAN_PLAY.set(can_play);
    }
    let api = KayaHostApi {
        emit_clicked: kaya_emit_clicked,
        next_commands: kaya_next_commands,
        emit_text_changed: kaya_emit_text_changed,
        emit_submitted: kaya_emit_submitted,
        emit_toggled: kaya_emit_toggled,
        emit_value_changed: kaya_emit_value_changed,
        emit_value_committed: kaya_emit_value_committed,
        emit_date_changed: kaya_emit_date_changed,
        emit_time_changed: kaya_emit_time_changed,
        color_quantize: crate::capi::kaya_color_quantize,
        emit_color_changed: crate::capi::kaya_emit_color_changed,
        range_clamp: crate::capi::kaya_range_clamp,
        emit_range: crate::capi::kaya_emit_range,
        player_loaded: crate::capi::kaya_player_loaded,
        player_rate: crate::capi::kaya_player_rate,
        player_ended: crate::capi::kaya_player_ended,
        player_failed: crate::capi::kaya_player_failed,
        player_position: crate::capi::kaya_player_position,
        player_seeked: crate::capi::kaya_player_seeked,
        player_overdue: crate::capi::kaya_player_overdue,
        player_tracks: crate::capi::kaya_player_tracks,
        player_cue: crate::capi::kaya_player_cue,
        caption_at: crate::capi::kaya_caption_at,
        player_captions_text: crate::capi::kaya_player_captions_text,
        player_captions_failed: crate::capi::kaya_player_captions_failed,
        video_visible: crate::capi::kaya_video_visible,
        session_action: crate::capi::kaya_session_action,
        session_state: crate::capi::kaya_session_state,
        blob_data: kaya_blob_data,
        blob_count: kaya_blob_count,
        spec_hash: crate::capi::kaya_spec_hash,
        emit_close_requested: crate::capi::kaya_emit_close_requested,
        emit_window_closed: crate::capi::kaya_emit_window_closed,
        emit_alert_result: crate::capi::kaya_emit_alert_result,
        emit_notification_result: crate::capi::kaya_emit_notification_result,
        emit_notification_reply: crate::capi::kaya_emit_notification_reply,
        link_opened: crate::capi::kaya_link_opened,
        grant_capabilities: crate::capi::kaya_grant_capabilities,
        capabilities: crate::capi::kaya_capabilities,
        emit_file_dialog_result: crate::capi::kaya_emit_file_dialog_result,
        emit_save_dialog_result: crate::capi::kaya_emit_save_dialog_result,
        emit_entry_popped: crate::capi::kaya_emit_entry_popped,
        emit_back_requested: crate::capi::kaya_emit_back_requested,
        emit_sheet_dismissed: crate::capi::kaya_emit_sheet_dismissed,
        emit_dismiss_requested: crate::capi::kaya_emit_dismiss_requested,
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
        emit_dropped: crate::capi::kaya_emit_dropped,
        emit_drag_ended: crate::capi::kaya_emit_drag_ended,
        drag_verdict: crate::capi::kaya_drag_verdict,
        fault: crate::capi::kaya_fault,
        fault_watch: crate::capi::kaya_fault_watch,
        window_moved: crate::capi::kaya_window_moved,
        rows_measured: crate::capi::kaya_rows_measured,
        scroll_to_row_str: crate::capi::kaya_scroll_to_row_str,
        scroll_to_row_i64: crate::capi::kaya_scroll_to_row_i64,
        window_geometry: crate::capi::kaya_window_geometry,
        row_extent: crate::capi::kaya_row_extent,
        presentation: crate::capi::kaya_presentation,
        text_scale_report: crate::capi::kaya_text_scale_report,
        canvas_probe: crate::capi::kaya_canvas_probe,
        canvas_track: crate::capi::kaya_canvas_track,
        window_metrics: crate::capi::kaya_window_metrics,
        frame: crate::capi::kaya_frame,
        harness_frame: crate::capi::kaya_harness_frame,
        canvas_raster_shape: crate::capi::kaya_canvas_raster_shape,
        window_frame,
        set_window_frame,
        text_composing: crate::capi::kaya_text_composing,
        text_pending: crate::capi::kaya_text_pending,
        text_edit_source: crate::capi::kaya_text_edit_source,
        text_reported_edit: crate::capi::kaya_text_reported_edit,
        text_selection: crate::capi::kaya_text_selection,
        text_formatted: crate::capi::kaya_text_formatted,
        text_runs: crate::capi::kaya_text_runs,
        text_last_edit: crate::capi::kaya_text_last_edit,
        copy_asset: crate::capi::kaya_harness_copy_asset,
        emit_fullscreen_changed: crate::capi::kaya_emit_fullscreen_changed,
        number_text,
        number_commit,
        number_step,
        reader_frame: crate::capi::kaya_reader_frame,
        reader_pcm: crate::capi::kaya_reader_pcm,
        reader_finished: crate::capi::kaya_reader_finished,
        reader_failed: crate::capi::kaya_reader_failed,
        reader_overdue: crate::capi::kaya_reader_overdue,
        capture_state: crate::capi::kaya_capture_state,
        capture_overdue: crate::capi::kaya_capture_overdue,
        capture_permission: crate::capi::kaya_capture_permission,
        capture_devices_begin: crate::capi::kaya_capture_devices_begin,
        capture_device: crate::capi::kaya_capture_device,
        capture_devices_end: crate::capi::kaya_capture_devices_end,
        capture_frame: crate::capi::kaya_capture_frame,
        capture_samples: crate::capi::kaya_capture_samples,
        capture_synthetic: crate::capi::kaya_capture_synthetic,
        capture_synthetic_permission: crate::capi::kaya_capture_synthetic_permission,
        capture_harness: crate::capi::kaya_capture_harness,
        reader_no_track: crate::capi::kaya_reader_no_track,
        capture_nearest_format: crate::capi::kaya_capture_nearest_format,
        capture_self_view_box: crate::capi::kaya_capture_self_view_box,
        video_view_box: crate::capi::kaya_video_view_box,
    };
    // THIS BACKEND WINDOWS ROWS (docs/deferred.md, the declares-windowing
    // entry), and the declaration has to beat the first transaction rather
    // than the first layout. One site serves mac and iOS.
    crate::capi::declare_windowing();
    let run: extern "C" fn(*const KayaHostApi) -> i32 =
        unsafe { std::mem::transmute(symbol) };
    run(&api)
}
