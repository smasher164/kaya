//! The C ABI, milestone-2 shape.
//!
//! The boundary is two-tier. Functions are the portable floor: any
//! language can call `kaya_next_occurrence` and never think about memory
//! order — it hands out one complete occurrence record (the same bytes
//! the ring carries; one vocabulary, two transports). Languages with
//! real atomics (Go, JVM, C#) may instead read the occurrence ring
//! directly: `kaya_occurrence_ring` hands out the layout once
//! (io_uring-offsets style), the data path is lock-free loads and
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

use crate::protocol::{OccSink, Transaction};
use crate::ring::{self, OccRing};
use crate::scene::Scene;
use crate::wire;

// Literal values: cbindgen drops constants defined by path references.
// The asserts below keep them locked to the wire module's values.

/// Occurrence record kinds (the ring, core -> guest). BUTTON_CLICKED
/// body: u64 id, u32 path_len, u32 reserved, then path_len key values.
/// path_len 0 means id is a widget id (a click on a guest-created
/// widget); otherwise id is a template node id and the values are the
/// stamped copy's key path, outermost first.
pub const KAYA_OCCURRENCE_PAD: u16 = 0;
pub const KAYA_OCCURRENCE_BUTTON_CLICKED: u16 = 1;
pub const KAYA_OCCURRENCE_TEXT_CHANGED: u16 = 2;
pub const KAYA_OCCURRENCE_TOGGLED: u16 = 3;
pub const KAYA_OCCURRENCE_VALUE_CHANGED: u16 = 4;
const _: () = assert!(
    KAYA_OCCURRENCE_PAD == ring::REC_PAD
        && KAYA_OCCURRENCE_BUTTON_CLICKED == ring::REC_BUTTON_CLICKED
        && KAYA_OCCURRENCE_TEXT_CHANGED == ring::REC_TEXT_CHANGED
        && KAYA_OCCURRENCE_TOGGLED == ring::REC_TOGGLED
        && KAYA_OCCURRENCE_VALUE_CHANGED == ring::REC_VALUE_CHANGED
);

/// Transaction record kinds (guest -> core, via kaya_submit). Layouts,
/// after the common 8-byte header, little-endian, 8-aligned:
///   CREATE_SIGNAL:     u64 signal_id, value
///   WRITE_SIGNAL:      u64 signal_id, value
///   CREATE_WIDGET:     u64 widget_id, u32 kind, u32 pad
///   SET_PROPERTY:      u64 widget_id, u32 prop, u32 source, then
///                      value (SOURCE_CONST) | u64 signal_id
///                      (SOURCE_SIGNAL) | u32 level, u32 pad
///                      (SOURCE_ELEMENT: the entry value of the
///                      enclosing For, level Fors up, 0 = nearest)
///   ADD_CHILD:         u64 parent, u64 child
///   MOUNT:             u64 window (0 = the default window), u64 root
///   CREATE_COLLECTION: u64 collection_id
///   COLLECTION_INSERT: u64 collection_id, path, key value, value
///   COLLECTION_UPDATE: u64 collection_id, path, key value, value
///   COLLECTION_REMOVE: u64 collection_id, path, key value
///   CREATE_FOR:        u64 id, u64 collection_id — opens a template
///                      scope; records until the matching TEMPLATE_END
///                      declare the blueprint (their ids are template
///                      node ids), and nothing renders until data
///                      arrives. The For itself is a live widget at top
///                      level, a template node when nested.
///   CREATE_WHEN:       u64 id, u64 signal_id — same scoping; stamps on
///                      true, unstamps on false. The signal must be Bool.
///   TEMPLATE_END:      no body
/// where value is { u32 type, u32 len, payload padded to 8 } and path
/// is { u32 count, u32 reserved, count values } — the key path
/// addressing a collection instance (empty for a top-level collection).
pub const KAYA_TX_CREATE_SIGNAL: u16 = 1;
pub const KAYA_TX_WRITE_SIGNAL: u16 = 2;
pub const KAYA_TX_CREATE_WIDGET: u16 = 3;
pub const KAYA_TX_SET_PROPERTY: u16 = 4;
pub const KAYA_TX_ADD_CHILD: u16 = 5;
pub const KAYA_TX_MOUNT: u16 = 6;
pub const KAYA_TX_CREATE_COLLECTION: u16 = 7;
pub const KAYA_TX_COLLECTION_INSERT: u16 = 8;
pub const KAYA_TX_COLLECTION_UPDATE: u16 = 9;
pub const KAYA_TX_COLLECTION_REMOVE: u16 = 10;
pub const KAYA_TX_CREATE_FOR: u16 = 11;
pub const KAYA_TX_CREATE_WHEN: u16 = 12;
pub const KAYA_TX_TEMPLATE_END: u16 = 13;
pub const KAYA_TX_COLLECTION_UPDATE_FIELD: u16 = 14;
pub const KAYA_TX_COLLECTION_MOVE: u16 = 15;
pub const KAYA_TX_VARIANT_CASE: u16 = 16;

/// The protocol fingerprint this core was built from. Bindings carry
/// the same value baked in at generation (KAYA_SPEC_HASH and friends)
/// and assert agreement at load: a stale library and a fresh guest —
/// or the reverse — fail loudly at startup instead of decoding each
/// other's bytes as garbage.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_spec_hash() -> u64 {
    crate::spec::hash()
}
const _: () = assert!(
    KAYA_TX_CREATE_SIGNAL == wire::TX_CREATE_SIGNAL
        && KAYA_TX_WRITE_SIGNAL == wire::TX_WRITE_SIGNAL
        && KAYA_TX_CREATE_WIDGET == wire::TX_CREATE_WIDGET
        && KAYA_TX_SET_PROPERTY == wire::TX_SET_PROPERTY
        && KAYA_TX_ADD_CHILD == wire::TX_ADD_CHILD
        && KAYA_TX_MOUNT == wire::TX_MOUNT
        && KAYA_TX_CREATE_COLLECTION == wire::TX_CREATE_COLLECTION
        && KAYA_TX_COLLECTION_INSERT == wire::TX_COLLECTION_INSERT
        && KAYA_TX_COLLECTION_UPDATE == wire::TX_COLLECTION_UPDATE
        && KAYA_TX_COLLECTION_REMOVE == wire::TX_COLLECTION_REMOVE
        && KAYA_TX_CREATE_FOR == wire::TX_CREATE_FOR
        && KAYA_TX_CREATE_WHEN == wire::TX_CREATE_WHEN
        && KAYA_TX_TEMPLATE_END == wire::TX_TEMPLATE_END
        && KAYA_TX_COLLECTION_UPDATE_FIELD == wire::TX_COLLECTION_UPDATE_FIELD
        && KAYA_TX_COLLECTION_MOVE == wire::TX_COLLECTION_MOVE
        && KAYA_TX_VARIANT_CASE == wire::TX_VARIANT_CASE
);

/// Apply record kinds (core -> presentation pump, via kaya_next_commands).
/// Layouts after the header:
///   CREATE:    u64 widget_id, u32 kind, u32 tag_len, then tag_len bytes
///              (padded to 8): the click tag an interactive widget must
///              emit verbatim through kaya_emit_clicked on activation.
///              tag_len 0 means no tag. The tag bytes are exactly a
///              BUTTON_CLICKED occurrence body.
///   SET_PROP:  u64 widget_id, u32 prop, u32 pad, value (always resolved)
///   ADD_CHILD: u64 parent, u64 child
///   MOUNT:     u64 window, u64 root
///   DESTROY:   u64 widget_id — remove from its parent and forget it.
///              Teardown arrives children-first; never walk anything.
///   MOVE_CHILD: u64 parent, u64 child, u64 before — reposition child
///              among parent's children so it sits before `before`;
///              0 means the end (widget ids start at 1).
pub const KAYA_APPLY_CREATE: u16 = 1;
pub const KAYA_APPLY_SET_PROP: u16 = 2;
pub const KAYA_APPLY_ADD_CHILD: u16 = 3;
pub const KAYA_APPLY_MOUNT: u16 = 4;
pub const KAYA_APPLY_DESTROY: u16 = 5;
pub const KAYA_APPLY_MOVE_CHILD: u16 = 6;
const _: () = assert!(
    KAYA_APPLY_CREATE == wire::APPLY_CREATE
        && KAYA_APPLY_SET_PROP == wire::APPLY_SET_PROP
        && KAYA_APPLY_ADD_CHILD == wire::APPLY_ADD_CHILD
        && KAYA_APPLY_MOUNT == wire::APPLY_MOUNT
        && KAYA_APPLY_DESTROY == wire::APPLY_DESTROY
        && KAYA_APPLY_MOVE_CHILD == wire::APPLY_MOVE_CHILD
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
pub const KAYA_KIND_ENTRY: u32 = 4;
pub const KAYA_KIND_ROW: u32 = 5;
pub const KAYA_KIND_CHECKBOX: u32 = 6;
pub const KAYA_KIND_SLIDER: u32 = 7;
const _: () = assert!(
    KAYA_KIND_COLUMN == wire::KIND_COLUMN
        && KAYA_KIND_BUTTON == wire::KIND_BUTTON
        && KAYA_KIND_LABEL == wire::KIND_LABEL
        && KAYA_KIND_ENTRY == wire::KIND_ENTRY
        && KAYA_KIND_ROW == wire::KIND_ROW
        && KAYA_KIND_CHECKBOX == wire::KIND_CHECKBOX
        && KAYA_KIND_SLIDER == wire::KIND_SLIDER
);

/// Property keys.
pub const KAYA_PROP_TEXT: u32 = 1;
pub const KAYA_PROP_CHECKED: u32 = 2;
pub const KAYA_PROP_VALUE: u32 = 3;
pub const KAYA_PROP_MIN: u32 = 4;
pub const KAYA_PROP_MAX: u32 = 5;
const _: () = assert!(
    KAYA_PROP_TEXT == wire::PROP_TEXT
        && KAYA_PROP_CHECKED == wire::PROP_CHECKED
        && KAYA_PROP_VALUE == wire::PROP_VALUE
        && KAYA_PROP_MIN == wire::PROP_MIN
        && KAYA_PROP_MAX == wire::PROP_MAX
);

/// set_property sources. SOURCE_ELEMENT is valid only inside a template.
pub const KAYA_SOURCE_CONST: u32 = 0;
pub const KAYA_SOURCE_SIGNAL: u32 = 1;
pub const KAYA_SOURCE_ELEMENT: u32 = 2;
const _: () = assert!(
    KAYA_SOURCE_CONST == wire::SOURCE_CONST
        && KAYA_SOURCE_SIGNAL == wire::SOURCE_SIGNAL
        && KAYA_SOURCE_ELEMENT == wire::SOURCE_ELEMENT
);

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
/// one complete record — header included, exactly the ring's bytes — to
/// `buf`. Returns the record size, or 0 when the core has shut down.
/// 256 bytes of capacity covers any occurrence with a reasonable key
/// path; an overflowing record fails loudly. Call from a single app
/// thread, and do not mix with direct ring access.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_next_occurrence(buf: *mut u8, cap: usize) -> usize {
    if buf.is_null() {
        return 0;
    }
    match state().ring.wait_pop() {
        Some((kind, body)) => {
            let size = wire::HEADER_SIZE + body.len();
            assert!(
                size <= cap,
                "kaya: occurrence record of {size} bytes exceeds the buffer of {cap}"
            );
            let mut record = Vec::with_capacity(size);
            record.extend_from_slice(&(size as u32).to_le_bytes());
            record.extend_from_slice(&kind.to_le_bytes());
            record.extend_from_slice(&0u16.to_le_bytes());
            record.extend_from_slice(&body);
            unsafe { std::ptr::copy_nonoverlapping(record.as_ptr(), buf, size) };
            size
        }
        None => 0,
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

/// Presentation side: emit a click, exactly as a backend's action
/// handler would — `tag` is the click tag bytes delivered with the
/// widget's CREATE record, handed back verbatim. Do not combine with
/// kaya_run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_clicked(tag: *const u8, len: usize) {
    assert!(!tag.is_null() && len != 0, "kaya: empty click tag");
    let tag = unsafe { std::slice::from_raw_parts(tag, len) };
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send_click_tag(tag);
        return;
    }
    state().ring.push_record(ring::REC_BUTTON_CLICKED, tag);
}

/// Presentation side: emit a checkbox toggle, exactly as a backend's
/// change handler would — `tag` is the tag bytes delivered with the
/// checkbox's CREATE record, `checked` the new state (0 or 1). Do not
/// combine with kaya_run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_toggled(tag: *const u8, tag_len: usize, checked: u8) {
    assert!(!tag.is_null() && tag_len != 0, "kaya: empty checkbox tag");
    let tag = unsafe { std::slice::from_raw_parts(tag, tag_len) };
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send_toggle_tag(tag, checked != 0);
        return;
    }
    state()
        .ring
        .push_record(ring::REC_TOGGLED, &wire::toggled_body(tag, checked != 0));
}

/// Presentation side: emit a slider move, exactly as a backend's
/// change handler would — `tag` is the tag bytes delivered with the
/// slider's CREATE record, `value` the new position. Do not combine
/// with kaya_run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_value_changed(tag: *const u8, tag_len: usize, value: f64) {
    assert!(!tag.is_null() && tag_len != 0, "kaya: empty slider tag");
    let tag = unsafe { std::slice::from_raw_parts(tag, tag_len) };
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send_value_tag(tag, value);
        return;
    }
    state()
        .ring
        .push_record(ring::REC_VALUE_CHANGED, &wire::value_changed_body(tag, value));
}

/// Presentation side: emit an entry edit, exactly as a backend's
/// change handler would — `tag` is the tag bytes delivered with the
/// entry's CREATE record, `text`/`text_len` the field's current UTF-8
/// content. Do not combine with kaya_run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_text_changed(
    tag: *const u8,
    tag_len: usize,
    text: *const u8,
    text_len: usize,
) {
    assert!(!tag.is_null() && tag_len != 0, "kaya: empty entry tag");
    let tag = unsafe { std::slice::from_raw_parts(tag, tag_len) };
    let text = if text_len == 0 {
        ""
    } else {
        assert!(!text.is_null(), "kaya: null text with nonzero length");
        std::str::from_utf8(unsafe { std::slice::from_raw_parts(text, text_len) })
            .expect("kaya: entry text must be UTF-8")
    };
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send_text_tag(tag, text);
        return;
    }
    state()
        .ring
        .push_record(ring::REC_TEXT_CHANGED, &wire::text_changed_body(tag, text));
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The KAYA_-prefixed constants are the C ABI's copy of the spec's
    /// record kinds — the one table the generator does not write. This
    /// pins it to the spec both ways: every row has its constant (the
    /// count catches a row added without one — the failure that once
    /// surfaced as a Swift guest typecheck error, five tools
    /// downstream) and every constant matches its row's kind.
    #[test]
    fn c_abi_constants_cover_the_spec() {
        let tx = [
            ("create_signal", KAYA_TX_CREATE_SIGNAL),
            ("write_signal", KAYA_TX_WRITE_SIGNAL),
            ("create_widget", KAYA_TX_CREATE_WIDGET),
            ("set_property", KAYA_TX_SET_PROPERTY),
            ("add_child", KAYA_TX_ADD_CHILD),
            ("mount", KAYA_TX_MOUNT),
            ("create_collection", KAYA_TX_CREATE_COLLECTION),
            ("collection_insert", KAYA_TX_COLLECTION_INSERT),
            ("collection_update", KAYA_TX_COLLECTION_UPDATE),
            ("collection_remove", KAYA_TX_COLLECTION_REMOVE),
            ("create_for", KAYA_TX_CREATE_FOR),
            ("create_when", KAYA_TX_CREATE_WHEN),
            ("template_end", KAYA_TX_TEMPLATE_END),
            ("collection_update_field", KAYA_TX_COLLECTION_UPDATE_FIELD),
            ("collection_move", KAYA_TX_COLLECTION_MOVE),
            ("variant_case", KAYA_TX_VARIANT_CASE),
        ];
        let apply = [
            ("create", KAYA_APPLY_CREATE),
            ("set_prop", KAYA_APPLY_SET_PROP),
            ("add_child", KAYA_APPLY_ADD_CHILD),
            ("mount", KAYA_APPLY_MOUNT),
            ("destroy", KAYA_APPLY_DESTROY),
            ("move_child", KAYA_APPLY_MOVE_CHILD),
        ];
        for (spec, consts) in [(crate::spec::SPEC.tx, &tx[..]), (crate::spec::SPEC.apply, &apply[..])] {
            assert_eq!(
                spec.len(),
                consts.len(),
                "a spec row has no KAYA_ constant (or the reverse)"
            );
            for row in spec {
                let (_, value) = consts
                    .iter()
                    .find(|(name, _)| *name == row.name)
                    .unwrap_or_else(|| panic!("no KAYA_ constant for spec row {:?}", row.name));
                assert_eq!(*value, row.kind, "kind mismatch for {:?}", row.name);
            }
        }
    }
}
