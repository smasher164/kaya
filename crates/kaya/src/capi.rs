//! Minimal C ABI for milestone 0.
//!
//! The boundary is two-tier. Functions are the portable floor: any
//! language can call `kaya_next_occurrence` and never think about memory
//! order. Languages with real atomics (Go, JVM, C#) may instead read the
//! occurrence ring directly: `kaya_occurrence_ring` hands out the layout
//! once (io_uring-offsets style), the data path is lock-free loads and
//! stores, and `kaya_wait_occurrences` is the blocking call for the empty
//! case only, like io_uring_enter. Both tiers drain the same ring; there
//! is one consumer, whichever style it uses.
//!
//! Direct-access contract (single consumer):
//!   1. acquire-load *tail; if *head == *tail the ring is empty; call
//!      kaya_wait_occurrences() to block until it is not (returns false
//!      on shutdown).
//!   2. cast data[*head & (capacity-1)] to KayaRecordHeader (declared in
//!      kaya.h). Skip kind 0 (padding). The payload follows the header;
//!      per-kind record structs (e.g. KayaRecordButtonClicked) are also
//!      declared in the header.
//!   3. release-store *head advanced by header.size.
//!
//! Commands travel through functions in both tiers; a transaction commits
//! as one call, so the per-record boundary cost never multiplies.

use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, OnceLock};

use crate::protocol::{Command, OccSink, Occurrence, WidgetId};
use crate::ring::{self, OccRing};

// Literal values: cbindgen drops constants defined by path references.
// The asserts below keep them locked to the ring's record kinds.
pub const KAYA_OCCURRENCE_PAD: u16 = 0;
pub const KAYA_OCCURRENCE_BUTTON_CLICKED: u16 = 1;
const _: () = assert!(
    KAYA_OCCURRENCE_PAD == ring::REC_PAD
        && KAYA_OCCURRENCE_BUTTON_CLICKED == ring::REC_BUTTON_CLICKED
);

/// Widget ids of the fixed milestone-0 scene.
pub const KAYA_WIDGET_BUTTON: u64 = 1;
pub const KAYA_WIDGET_LABEL: u64 = 2;

#[repr(C)]
pub struct KayaOccurrence {
    pub kind: u16,
    pub widget_id: u64,
}

/// The occurrence ring's layout, for direct consumers.
#[repr(C)]
pub struct KayaRingInfo {
    pub data: *mut u8,
    pub capacity: u32,
    pub head: *mut u32,
    pub tail: *mut u32,
}

struct CState {
    ring: Arc<OccRing>,
    cmd_tx: Sender<Command>,
    core_ends: Mutex<Option<(OccSink, Receiver<Command>)>>,
}

fn state() -> &'static CState {
    static STATE: OnceLock<CState> = OnceLock::new();
    STATE.get_or_init(|| {
        let ring = Arc::new(OccRing::new(64 * 1024));
        let (cmd_tx, cmd_rx) = mpsc::channel();
        CState {
            ring: ring.clone(),
            cmd_tx,
            core_ends: Mutex::new(Some((OccSink::Ring(ring), cmd_rx))),
        }
    })
}

/// Take over the calling thread, which must be the process main thread,
/// and run the milestone-0 scene. Returns when the app exits, with the
/// exit code; the host decides how to terminate its own process.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_run() -> i32 {
    // Runtime backend selection (interim mechanism: environment). The
    // SwiftUI backend runs its own presentation pump over this same C
    // API, so core_ends stays in place for it to take.
    #[cfg(target_os = "macos")]
    if std::env::var("KAYA_BACKEND").as_deref() == Ok("swiftui") {
        return crate::swiftui_host::run();
    }

    let (occ_sink, cmd_rx) = take_core_ends().expect("kaya_run may only be called once");
    crate::backend::run_core(occ_sink, cmd_rx)
}

/// The core's ends of the transport: the ring-backed occurrence sink and
/// the command receiver. Taken once, by whichever entry starts the core
/// (kaya_run here; Kaya.nativeRun on Android, where the OS owns main).
pub(crate) fn take_core_ends() -> Option<(OccSink, Receiver<Command>)> {
    state().core_ends.lock().unwrap().take()
}

/// The occurrence ring's raw layout, for the Android backend to wrap in
/// direct ByteBuffers (the JVM's window onto foreign memory).
#[cfg(target_os = "android")]
pub(crate) fn ring_raw() -> (*mut u8, u32, *mut u32, *mut u32) {
    state().ring.raw()
}

/// Function-floor consumption: block until the next occurrence and write
/// it to `out`. Returns false when the core has shut down. Call from a
/// single app thread, and do not mix with direct ring access.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_next_occurrence(out: *mut KayaOccurrence) -> bool {
    if out.is_null() {
        return false;
    }
    match state().ring.wait_pop() {
        Some((kind, widget_id)) => {
            unsafe { *out = KayaOccurrence { kind, widget_id } };
            true
        }
        None => false,
    }
}

/// Direct-access setup: the occurrence ring's memory layout. Pointers
/// remain valid for the life of the process.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_occurrence_ring(out: *mut KayaRingInfo) {
    if out.is_null() {
        return;
    }
    let (data, capacity, head, tail) = state().ring.raw();
    unsafe {
        *out = KayaRingInfo {
            data,
            capacity,
            head,
            tail,
        };
    }
}

/// Direct-access waiting: block until the ring is non-empty. Returns
/// false when the core has shut down and the ring is drained.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_wait_occurrences() -> bool {
    state().ring.wait_nonempty()
}

// --- Presentation-side API (guest-language backends) --------------------
//
// A guest-language presentation layer (the SwiftUI backend) plays the
// core's presentation role: it emits occurrences and consumes commands,
// instead of calling kaya_run. The shape mirrors the guest side:
// kaya_next_command blocks the way kaya_next_occurrence does, and
// kaya_emit_* is the counterpart of kaya_set_text. Exclusive with
// kaya_run — one presentation layer per process. The full contract grows
// with the reactive surface; this is the milestone-0 subset.

pub const KAYA_COMMAND_SET_TEXT: u16 = 1;

#[repr(C)]
pub struct KayaCommand {
    pub kind: u16,
    pub widget_id: u64,
    pub text_len: u32,
    pub text: [u8; 256],
}

static PRESENTATION_CMD_RX: Mutex<Option<Receiver<Command>>> = Mutex::new(None);

// Where presentation-side emissions land. Defaults to the byte ring
// (foreign guests read it via kaya_next_occurrence); the Rust API's
// SwiftUI mode routes emissions into the AppCtx mpsc instead.
static PRESENTATION_SINK: Mutex<Option<OccSink>> = Mutex::new(None);

pub(crate) fn set_presentation_sink(sink: OccSink) {
    *PRESENTATION_SINK.lock().unwrap() = Some(sink);
}

/// The command sender feeding whatever presentation layer is running,
/// for the Rust API's runtime-selected backends.
pub(crate) fn presentation_cmd_sender() -> mpsc::Sender<Command> {
    state().cmd_tx.clone()
}

/// Presentation side: emit a button-clicked occurrence, exactly as a
/// backend's action handler would. Do not combine with kaya_run.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_emit_button_clicked(widget_id: u64) {
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send(Occurrence::ButtonClicked {
            id: WidgetId(widget_id),
        });
        return;
    }
    state().ring.push(ring::REC_BUTTON_CLICKED, widget_id);
}

/// Presentation side: block until the next command and write it to `out`.
/// Returns false if command consumption could not be acquired (kaya_run
/// owns it). Call from a single presentation pump thread; process exit is
/// the shutdown path for a presentation leg at milestone-0 grade.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_next_command(out: *mut KayaCommand) -> bool {
    if out.is_null() {
        return false;
    }
    let mut slot = PRESENTATION_CMD_RX.lock().unwrap();
    if slot.is_none() {
        let Some((_occ, cmd_rx)) = state().core_ends.lock().unwrap().take() else {
            return false;
        };
        *slot = Some(cmd_rx);
    }
    match slot.as_ref().unwrap().recv() {
        Ok(Command::SetText { id, text }) => {
            let bytes = text.as_bytes();
            let len = bytes.len().min(256);
            unsafe {
                let out = &mut *out;
                out.kind = KAYA_COMMAND_SET_TEXT;
                out.widget_id = id.0;
                out.text_len = len as u32;
                out.text[..len].copy_from_slice(&bytes[..len]);
            }
            true
        }
        Err(_) => false,
    }
}

/// Set a widget's text. `text` points to `len` bytes of UTF-8; invalid
/// sequences are replaced rather than rejected.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_set_text(widget_id: u64, text: *const u8, len: usize) {
    let text = if text.is_null() {
        String::new()
    } else {
        String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(text, len) }).into_owned()
    };
    let command = Command::SetText {
        id: WidgetId(widget_id),
        text,
    };
    if state().cmd_tx.send(command).is_ok() {
        crate::backend::ring_doorbell();
    }
}
