//! The C ABI, milestone-1 shape.
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
//! The other direction is transactions: the guest packs a buffer of
//! records — same framing as the ring, layouts documented on the KAYA_TX_*
//! constants — and one kaya_submit call commits it atomically. No second
//! ring: the write path asks no atomics of any language.

use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, OnceLock};

use crate::protocol::{OccSink, Occurrence, Transaction, WidgetId};
use crate::ring::{self, OccRing};
use crate::scene::Scene;
use crate::wire;

// Literal values: cbindgen drops constants defined by path references.
// The asserts below keep them locked to the wire module's values.

/// Occurrence record kinds (the ring, core -> guest).
pub const KAYA_OCCURRENCE_PAD: u16 = 0;
pub const KAYA_OCCURRENCE_BUTTON_CLICKED: u16 = 1;
const _: () = assert!(
    KAYA_OCCURRENCE_PAD == ring::REC_PAD
        && KAYA_OCCURRENCE_BUTTON_CLICKED == ring::REC_BUTTON_CLICKED
);

/// Transaction record kinds (guest -> core, via kaya_submit). Layouts,
/// after the common 8-byte header, little-endian, 8-aligned:
///   CREATE_SIGNAL: u64 signal_id, value
///   WRITE_SIGNAL:  u64 signal_id, value
///   CREATE_WIDGET: u64 widget_id, u32 kind, u32 pad
///   SET_PROPERTY:  u64 widget_id, u32 prop, u32 source,
///                  then value (SOURCE_CONST) or u64 signal_id (SOURCE_SIGNAL)
///   ADD_CHILD:     u64 parent, u64 child
///   MOUNT:         u64 window (0 = the default window), u64 root
/// where value is { u32 type, u32 len, payload padded to 8 }.
pub const KAYA_TX_CREATE_SIGNAL: u16 = 1;
pub const KAYA_TX_WRITE_SIGNAL: u16 = 2;
pub const KAYA_TX_CREATE_WIDGET: u16 = 3;
pub const KAYA_TX_SET_PROPERTY: u16 = 4;
pub const KAYA_TX_ADD_CHILD: u16 = 5;
pub const KAYA_TX_MOUNT: u16 = 6;
const _: () = assert!(
    KAYA_TX_CREATE_SIGNAL == wire::TX_CREATE_SIGNAL
        && KAYA_TX_WRITE_SIGNAL == wire::TX_WRITE_SIGNAL
        && KAYA_TX_CREATE_WIDGET == wire::TX_CREATE_WIDGET
        && KAYA_TX_SET_PROPERTY == wire::TX_SET_PROPERTY
        && KAYA_TX_ADD_CHILD == wire::TX_ADD_CHILD
        && KAYA_TX_MOUNT == wire::TX_MOUNT
);

/// Apply record kinds (core -> presentation pump, via kaya_next_commands).
/// Layouts after the header:
///   CREATE:    u64 widget_id, u32 kind, u32 pad
///   SET_PROP:  u64 widget_id, u32 prop, u32 pad, value (always resolved)
///   ADD_CHILD: u64 parent, u64 child
///   MOUNT:     u64 window, u64 root
pub const KAYA_APPLY_CREATE: u16 = 1;
pub const KAYA_APPLY_SET_PROP: u16 = 2;
pub const KAYA_APPLY_ADD_CHILD: u16 = 3;
pub const KAYA_APPLY_MOUNT: u16 = 4;
const _: () = assert!(
    KAYA_APPLY_CREATE == wire::APPLY_CREATE
        && KAYA_APPLY_SET_PROP == wire::APPLY_SET_PROP
        && KAYA_APPLY_ADD_CHILD == wire::APPLY_ADD_CHILD
        && KAYA_APPLY_MOUNT == wire::APPLY_MOUNT
);

/// Value types.
pub const KAYA_VALUE_BOOL: u32 = 1;
pub const KAYA_VALUE_I64: u32 = 2;
pub const KAYA_VALUE_F64: u32 = 3;
pub const KAYA_VALUE_STR: u32 = 4;
const _: () = assert!(
    KAYA_VALUE_BOOL == wire::VALUE_BOOL
        && KAYA_VALUE_I64 == wire::VALUE_I64
        && KAYA_VALUE_F64 == wire::VALUE_F64
        && KAYA_VALUE_STR == wire::VALUE_STR
);

/// Widget kinds.
pub const KAYA_KIND_COLUMN: u32 = 1;
pub const KAYA_KIND_BUTTON: u32 = 2;
pub const KAYA_KIND_LABEL: u32 = 3;
const _: () = assert!(
    KAYA_KIND_COLUMN == wire::KIND_COLUMN
        && KAYA_KIND_BUTTON == wire::KIND_BUTTON
        && KAYA_KIND_LABEL == wire::KIND_LABEL
);

/// Property keys.
pub const KAYA_PROP_TEXT: u32 = 1;
const _: () = assert!(KAYA_PROP_TEXT == wire::PROP_TEXT);

/// set_property sources.
pub const KAYA_SOURCE_CONST: u32 = 0;
pub const KAYA_SOURCE_SIGNAL: u32 = 1;
const _: () = assert!(
    KAYA_SOURCE_CONST == wire::SOURCE_CONST && KAYA_SOURCE_SIGNAL == wire::SOURCE_SIGNAL
);

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
    tx_tx: Sender<Transaction>,
    core_ends: Mutex<Option<(OccSink, Receiver<Transaction>)>>,
}

fn state() -> &'static CState {
    static STATE: OnceLock<CState> = OnceLock::new();
    STATE.get_or_init(|| {
        let ring = Arc::new(OccRing::new(64 * 1024));
        let (tx_tx, tx_rx) = mpsc::channel();
        CState {
            ring: ring.clone(),
            tx_tx,
            core_ends: Mutex::new(Some((OccSink::Ring(ring), tx_rx))),
        }
    })
}

/// Take over the calling thread, which must be the process main thread,
/// and run the core. Returns when the app exits, with the exit code; the
/// host decides how to terminate its own process.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_run() -> i32 {
    // Runtime backend selection (interim mechanism: environment). The
    // SwiftUI backend runs its own presentation pump over this same C
    // API, so core_ends stays in place for it to take.
    #[cfg(target_os = "macos")]
    if std::env::var("KAYA_BACKEND").as_deref() == Ok("swiftui") {
        return crate::swiftui_host::run();
    }

    let (occ_sink, tx_rx) = take_core_ends().expect("kaya_run may only be called once");
    crate::backend::run_core(occ_sink, tx_rx)
}

/// The core's ends of the transport: the ring-backed occurrence sink and
/// the transaction receiver. Taken once, by whichever entry starts the
/// core (kaya_run here; KayaRing.attach on Android, where the OS owns
/// main).
pub(crate) fn take_core_ends() -> Option<(OccSink, Receiver<Transaction>)> {
    state().core_ends.lock().unwrap().take()
}

/// The occurrence ring's raw layout, for the Android backend to wrap in
/// direct ByteBuffers (the JVM's window onto foreign memory).
#[cfg(target_os = "android")]
pub(crate) fn ring_raw() -> (*mut u8, u32, *mut u32, *mut u32) {
    state().ring.raw()
}

/// Submit one transaction: `len` bytes of records at `records`, applied
/// atomically on the UI thread. The buffer is copied before this call
/// returns. Malformed records are a broken binding and fail loudly.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_submit(records: *const u8, len: usize) {
    let buf = if records.is_null() || len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(records, len) }
    };
    let tx = wire::decode_transaction(buf);
    if state().tx_tx.send(tx).is_ok() {
        crate::backend::ring_doorbell();
    }
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
// A guest-language presentation layer (the SwiftUI and Compose backends)
// plays the core's presentation role: it emits occurrences and consumes
// resolved apply-ops, instead of calling kaya_run. kaya_next_commands
// blocks the way kaya_next_occurrence does; the scene resolution (signals
// to concrete property sets) happens here, core-side, so a presentation
// layer never grows signal machinery. Exclusive with kaya_run — one
// presentation layer per process.

static PRESENTATION_TX_RX: Mutex<Option<Receiver<Transaction>>> = Mutex::new(None);
static PRESENTATION_SCENE: Mutex<Option<Scene>> = Mutex::new(None);

// Where presentation-side emissions land. Defaults to the byte ring
// (foreign guests read it via kaya_next_occurrence); the Rust API's
// runtime-selected modes route emissions into the AppCtx mpsc instead.
static PRESENTATION_SINK: Mutex<Option<OccSink>> = Mutex::new(None);

pub(crate) fn set_presentation_sink(sink: OccSink) {
    *PRESENTATION_SINK.lock().unwrap() = Some(sink);
}

/// The transaction sender feeding whatever presentation layer is running,
/// for the Rust API's runtime-selected backends.
pub(crate) fn presentation_tx_sender() -> mpsc::Sender<Transaction> {
    state().tx_tx.clone()
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

/// Presentation side: block until the next transaction, resolve it
/// through the scene, and write the apply-op records into `buf`.
/// Returns the byte length written, or 0 when the core has shut down.
/// Call from a single pump thread with a buffer of at least 64 KiB;
/// an overflowing batch fails loudly.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_next_commands(buf: *mut u8, cap: usize) -> usize {
    if buf.is_null() {
        return 0;
    }
    let mut rx_slot = PRESENTATION_TX_RX.lock().unwrap();
    if rx_slot.is_none() {
        let Some((_occ, tx_rx)) = state().core_ends.lock().unwrap().take() else {
            return 0;
        };
        *rx_slot = Some(tx_rx);
        *PRESENTATION_SCENE.lock().unwrap() = Some(Scene::new());
    }
    let Ok(tx) = rx_slot.as_ref().unwrap().recv() else {
        return 0;
    };
    let mut scene_slot = PRESENTATION_SCENE.lock().unwrap();
    let ops = scene_slot.as_mut().unwrap().apply(tx);
    let mut writer = wire::Writer::new();
    for op in &ops {
        writer.apply_op(op);
    }
    let bytes = writer.into_bytes();
    assert!(
        bytes.len() <= cap,
        "kaya: apply batch of {} bytes exceeds the pump buffer of {cap}",
        bytes.len()
    );
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf, bytes.len()) };
    bytes.len()
}
