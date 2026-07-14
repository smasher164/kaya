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

use crate::protocol::{Command, OccSink, WidgetId};
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
    let (occ_sink, cmd_rx) = state()
        .core_ends
        .lock()
        .unwrap()
        .take()
        .expect("kaya_run may only be called once");
    crate::backend::run_core(occ_sink, cmd_rx)
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
