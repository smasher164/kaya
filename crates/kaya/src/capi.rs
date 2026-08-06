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
pub const KAYA_OCCURRENCE_CLOSE_REQUESTED: u16 = 5;
pub const KAYA_OCCURRENCE_WINDOW_CLOSED: u16 = 6;
pub const KAYA_OCCURRENCE_ALERT_RESULT: u16 = 7;
pub const KAYA_OCCURRENCE_ENTRY_POPPED: u16 = 8;
pub const KAYA_OCCURRENCE_BACK_REQUESTED: u16 = 9;
pub const KAYA_OCCURRENCE_SECTION_SELECTED: u16 = 10;
/// Menu occurrences (core -> guest). Each carries the BUTTON_CLICKED
/// body shape: u64 item id, u32 path_len, u32 reserved, then path_len
/// key values (the on_click_node encoding — empty for a bar or
/// live-widget activation, the anchor copy's key path for a
/// node-anchored context item), then the payload for the stateful pair
/// (a Bool value for TOGGLED, an F64 index for VALUE_CHANGED).
pub const KAYA_OCCURRENCE_MENU_ACTIVATED: u16 = 11;
pub const KAYA_OCCURRENCE_MENU_TOGGLED: u16 = 12;
pub const KAYA_OCCURRENCE_MENU_VALUE_CHANGED: u16 = 13;

/// The file picker's one answer (spec `file_dialog_result`): `count`
/// files, each three consecutive values in the trailing list — an I64
/// handle, a Str display name, and a Str `local_path`. Cancel is count
/// zero. Redeem a handle with `kaya_open_picked`.
pub const KAYA_OCCURRENCE_FILE_DIALOG_RESULT: u16 = 14;
/// The clipboard's two answers: the privileged read's, and the one that
/// arrives because the user pasted. Literals, like every sibling — the
/// pin below is what keeps them honest, since cbindgen evaluates no
/// paths and would silently omit `= ring::X`.
pub const KAYA_OCCURRENCE_CLIPBOARD_RESULT: u16 = 15;
pub const KAYA_OCCURRENCE_PASTED: u16 = 16;
/// The undo pair (spec `undone`/`redone`): kaya routed an undo or a
/// redo, and this is what the core put back — u64 window, u32 signal
/// count, u32 text count, u32 entry count, u32 order count, the Str
/// label, then one flat value list holding those four runs in order.
/// Applying an inverse emits nothing else, so this record is the whole
/// of what an app hears.
pub const KAYA_OCCURRENCE_UNDONE: u16 = 17;
pub const KAYA_OCCURRENCE_REDONE: u16 = 18;
const _: () = assert!(
    KAYA_OCCURRENCE_PAD == ring::REC_PAD
        && KAYA_OCCURRENCE_BUTTON_CLICKED == ring::REC_BUTTON_CLICKED
        && KAYA_OCCURRENCE_TEXT_CHANGED == ring::REC_TEXT_CHANGED
        && KAYA_OCCURRENCE_TOGGLED == ring::REC_TOGGLED
        && KAYA_OCCURRENCE_VALUE_CHANGED == ring::REC_VALUE_CHANGED
        && KAYA_OCCURRENCE_CLOSE_REQUESTED == ring::REC_CLOSE_REQUESTED
        && KAYA_OCCURRENCE_WINDOW_CLOSED == ring::REC_WINDOW_CLOSED
        && KAYA_OCCURRENCE_ALERT_RESULT == ring::REC_ALERT_RESULT
        && KAYA_OCCURRENCE_ENTRY_POPPED == ring::REC_ENTRY_POPPED
        && KAYA_OCCURRENCE_BACK_REQUESTED == ring::REC_BACK_REQUESTED
        && KAYA_OCCURRENCE_SECTION_SELECTED == ring::REC_SECTION_SELECTED
        && KAYA_OCCURRENCE_MENU_ACTIVATED == ring::REC_MENU_ACTIVATED
        && KAYA_OCCURRENCE_MENU_TOGGLED == ring::REC_MENU_TOGGLED
        && KAYA_OCCURRENCE_MENU_VALUE_CHANGED == ring::REC_MENU_VALUE_CHANGED
        && KAYA_OCCURRENCE_FILE_DIALOG_RESULT == ring::REC_FILE_DIALOG_RESULT
        && KAYA_OCCURRENCE_CLIPBOARD_RESULT == ring::REC_CLIPBOARD_RESULT
        && KAYA_OCCURRENCE_PASTED == ring::REC_PASTED
        && KAYA_OCCURRENCE_UNDONE == ring::REC_UNDONE
        && KAYA_OCCURRENCE_REDONE == ring::REC_REDONE
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
pub const KAYA_TX_WIDGET_COMMAND: u16 = 17;
pub const KAYA_TX_SET_WINDOW_PROP: u16 = 18;
pub const KAYA_TX_CREATE_WINDOW: u16 = 19;
pub const KAYA_TX_DESTROY_WINDOW: u16 = 20;
/// SHOW_ALERT: u64 window, u64 alert, u32 actions (0..=2), u32 pad,
/// then five Str values in order: title, message, action0, action1,
/// cancel (slots beyond `actions` ride empty). One alert may be live
/// per process; the result retires the id.
pub const KAYA_TX_SHOW_ALERT: u16 = 21;
/// PUSH_ENTRY: u64 window, u64 entry — push a navigation entry onto
/// the window's stack (entry ids share the surface namespace with
/// windows; mount targets either). POP_ENTRY: u64 window — pop the
/// top entry; its tree is forgotten wholesale. SET_ENTRY_PROP: u64
/// entry, u32 eprop, u32 source, then the SET_PROPERTY tail
/// (element sources rejected).
pub const KAYA_TX_PUSH_ENTRY: u16 = 22;
pub const KAYA_TX_POP_ENTRY: u16 = 23;
pub const KAYA_TX_SET_ENTRY_PROP: u16 = 24;
pub const KAYA_TX_ADD_SECTION: u16 = 25;
pub const KAYA_TX_SELECT_SECTION: u16 = 26;
pub const KAYA_TX_SET_SECTION_PROP: u16 = 27;
/// MENU_ITEM_CREATE: u64 item, u32 menu_kind, u32 pad — create a menu
/// item in its own id space (c_menu_item). MENU_ITEM_APPEND: u64
/// parent, u64 child — append under a grouping node (closed grammar,
/// single-parent). MENUBAR_APPEND: u64 window, u64 item — a top-level
/// grouping node into the window catalog. CONTEXT_ATTACH: u64 widget,
/// u64 item — a context catalog on a live widget (entry/textarea
/// rejected). CONTEXT_ATTACH_NODE: u64 node, u64 item — a context
/// catalog on a template node (Tpl zone; activations carry the copy's
/// keys). SET_MENU_PROP: u64 item, u32 mprop, u32 source, then the
/// SET_PROPERTY tail (element rejected; icon/primary/shortcut reject
/// signal sources).
pub const KAYA_TX_MENU_ITEM_CREATE: u16 = 28;
pub const KAYA_TX_MENU_ITEM_APPEND: u16 = 29;
pub const KAYA_TX_MENUBAR_APPEND: u16 = 30;
pub const KAYA_TX_CONTEXT_ATTACH: u16 = 31;
pub const KAYA_TX_CONTEXT_ATTACH_NODE: u16 = 32;
pub const KAYA_TX_SET_MENU_PROP: u16 = 33;

/// Request the platform's file picker over a live window (0 = primary),
/// on the alert's request/result grammar. Dialog ids are guest-chosen,
/// one may be live per process, and the id retires with its result.
pub const KAYA_TX_SHOW_FILE_DIALOG: u16 = 34;
pub const KAYA_TX_COPY: u16 = 35;
pub const KAYA_TX_READ_CLIPBOARD: u16 = 36;

/// Mark this transaction as ONE undoable step in a window's ledger:
/// u64 window (0 = primary), then a non-empty Str label. MUST BE THE
/// FIRST RECORD OF THE BATCH — a transaction has no header, so the
/// marker's position is what says which ops it covers. A marked batch
/// holds signal writes and collection deltas; focus is permitted and not
/// restored; anything else is refused at apply, naming the op.
pub const KAYA_TX_UNDO_GROUP: u16 = 37;

/// The protocol fingerprint this core was built from. Bindings carry
/// the same value baked in at generation (KAYA_SPEC_HASH and friends)
/// and assert agreement at load: a stale library and a fresh guest —
/// or the reverse — fail loudly at startup instead of decoding each
/// other's bytes as garbage.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_spec_hash() -> u64 {
    crate::spec::hash()
}

/// The identity of the SOURCES this core was compiled from, carried in
/// the binary where a runner can read it without loading or running
/// anything: `tools/build-id.sh --verify libkaya.so`. The spec hash
/// above answers "do the guest and the library agree on the protocol";
/// this answers the question that costs whole debugging sessions — "is
/// the file I am about to test built from the code I just edited". A
/// build step whose failure went unnoticed leaves the PREVIOUS artifact
/// sitting there, and every downstream verdict is then about code
/// nobody wrote today.
///
/// Fixed-size and `no_mangle` on purpose: an exported static of known
/// length survives linking into every artifact shape (cdylib, staticlib,
/// dll) and lands in rodata as findable bytes, and a build.rs that
/// emitted a differently-sized id would fail to compile here rather than
/// bake a truncated one.
#[unsafe(no_mangle)]
pub static KAYA_BUILD_ID_MARKER: [u8; 30] = {
    let src = concat!("kaya-build-id:", env!("KAYA_BUILD_ID")).as_bytes();
    let mut marker = [0u8; 30];
    let mut i = 0;
    while i < 30 {
        marker[i] = src[i];
        i += 1;
    }
    marker
};

/// Host capability bits, queryable any time (like kaya_spec_hash).
/// Platform-static per build: the phones' systems own surface
/// geometry, so KAYA_CAP_AUX_WINDOWS is unset there and create_window
/// is a deterministic scene error (DESIGN.md, Presentation contexts).
pub const KAYA_CAP_AUX_WINDOWS: u64 = 1;

#[unsafe(no_mangle)]
pub extern "C" fn kaya_capabilities() -> u64 {
    #[cfg(any(target_os = "ios", target_os = "android"))]
    {
        0
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    {
        KAYA_CAP_AUX_WINDOWS
    }
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
        && KAYA_TX_WIDGET_COMMAND == wire::TX_WIDGET_COMMAND
        && KAYA_TX_SET_WINDOW_PROP == wire::TX_SET_WINDOW_PROP
        && KAYA_TX_CREATE_WINDOW == wire::TX_CREATE_WINDOW
        && KAYA_TX_DESTROY_WINDOW == wire::TX_DESTROY_WINDOW
        && KAYA_TX_SHOW_ALERT == wire::TX_SHOW_ALERT
        && KAYA_TX_PUSH_ENTRY == wire::TX_PUSH_ENTRY
        && KAYA_TX_POP_ENTRY == wire::TX_POP_ENTRY
        && KAYA_TX_SET_ENTRY_PROP == wire::TX_SET_ENTRY_PROP
        && KAYA_TX_ADD_SECTION == wire::TX_ADD_SECTION
        && KAYA_TX_SELECT_SECTION == wire::TX_SELECT_SECTION
        && KAYA_TX_SET_SECTION_PROP == wire::TX_SET_SECTION_PROP
        && KAYA_TX_MENU_ITEM_CREATE == wire::TX_MENU_ITEM_CREATE
        && KAYA_TX_MENU_ITEM_APPEND == wire::TX_MENU_ITEM_APPEND
        && KAYA_TX_MENUBAR_APPEND == wire::TX_MENUBAR_APPEND
        && KAYA_TX_CONTEXT_ATTACH == wire::TX_CONTEXT_ATTACH
        && KAYA_TX_CONTEXT_ATTACH_NODE == wire::TX_CONTEXT_ATTACH_NODE
        && KAYA_TX_SET_MENU_PROP == wire::TX_SET_MENU_PROP
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
///   COMMAND:   u64 widget_id, u32 command, u32 pad — execute a
///              one-shot command (KAYA_COMMAND_*) on the widget, then
///              let it report through its normal occurrence path (a
///              clear arrives back as text_changed with empty text,
///              through the same path a keystroke uses — emit it
///              explicitly on toolkits whose programmatic set is
///              silent).
pub const KAYA_APPLY_CREATE: u16 = 1;
pub const KAYA_APPLY_SET_PROP: u16 = 2;
pub const KAYA_APPLY_ADD_CHILD: u16 = 3;
pub const KAYA_APPLY_MOUNT: u16 = 4;
pub const KAYA_APPLY_DESTROY: u16 = 5;
pub const KAYA_APPLY_MOVE_CHILD: u16 = 6;
pub const KAYA_APPLY_COMMAND: u16 = 7;
pub const KAYA_APPLY_SET_WINDOW_PROP: u16 = 8;
pub const KAYA_APPLY_CREATE_WINDOW: u16 = 9;
pub const KAYA_APPLY_DESTROY_WINDOW: u16 = 10;
/// PRESENT_ALERT: the same layout as SHOW_ALERT (already validated).
/// Present the platform's real modal dialog and answer exactly once
/// via kaya_emit_alert_result.
pub const KAYA_APPLY_PRESENT_ALERT: u16 = 11;
/// PUSH_ENTRY: u64 window, u64 entry — materialize the entry hidden;
/// a mount presents it. POP_ENTRY: u64 window — release the top
/// entry's views; the batch's NET stack change animates as one
/// transition. SET_ENTRY_PROP: u64 entry, u32 eprop, u32 pad, value.
pub const KAYA_APPLY_PUSH_ENTRY: u16 = 12;
pub const KAYA_APPLY_POP_ENTRY: u16 = 13;
pub const KAYA_APPLY_SET_ENTRY_PROP: u16 = 14;
pub const KAYA_APPLY_ADD_SECTION: u16 = 15;
pub const KAYA_APPLY_SELECT_SECTION: u16 = 16;
pub const KAYA_APPLY_SET_SECTION_PROP: u16 = 17;
/// MENU_ITEM_CREATE: u64 item, u32 menu_kind, u32 pad. MENU_ITEM_APPEND:
/// u64 parent, u64 child. MENUBAR_APPEND: u64 window, u64 item.
/// CONTEXT_ATTACH: u64 widget, u64 item. CONTEXT_ATTACH_NODE: u64
/// widget, u64 item, then the anchor copy's key path { u32 count; u32
/// reserved; count values } — the noun stamped into every activation.
/// SET_MENU_PROP: u64 item, u32 mprop, u32 pad, value (resolved).
pub const KAYA_APPLY_MENU_ITEM_CREATE: u16 = 18;
pub const KAYA_APPLY_MENU_ITEM_APPEND: u16 = 19;
pub const KAYA_APPLY_MENUBAR_APPEND: u16 = 20;
pub const KAYA_APPLY_CONTEXT_ATTACH: u16 = 21;
pub const KAYA_APPLY_CONTEXT_ATTACH_NODE: u16 = 22;
pub const KAYA_APPLY_SET_MENU_PROP: u16 = 23;

/// Present the platform's real file picker (SHOW_FILE_DIALOG, already
/// validated by the core). Answered exactly once, with the chosen files
/// or an EMPTY list for cancel.
pub const KAYA_APPLY_PRESENT_FILE_DIALOG: u16 = 24;

/// The clipboard pair, backend side. COPY's body is byte-identical to
/// the tx record's, values in descending richness — offer them in that
/// order. READ_CLIPBOARD is answered exactly once with
/// kaya_emit_clipboard_result, empty included.
pub const KAYA_APPLY_COPY: u16 = 25;
pub const KAYA_APPLY_READ_CLIPBOARD: u16 = 26;

/// Reset the NATIVE undo history of whatever editable holds the keyboard
/// focus in this window; do nothing if that is nothing. Body: u64 window.
/// Targetless on purpose — the core does not know what is focused and by
/// doctrine never will, while the backend already asks itself the same
/// question for role enablement.
pub const KAYA_APPLY_CLEAR_UNDO: u16 = 27;
const _: () = assert!(
    KAYA_APPLY_COPY == wire::APPLY_COPY
        && KAYA_APPLY_READ_CLIPBOARD == wire::APPLY_READ_CLIPBOARD
        && KAYA_APPLY_CLEAR_UNDO == wire::APPLY_CLEAR_UNDO
);
const _: () = assert!(
    KAYA_APPLY_CREATE == wire::APPLY_CREATE
        && KAYA_APPLY_SET_PROP == wire::APPLY_SET_PROP
        && KAYA_APPLY_ADD_CHILD == wire::APPLY_ADD_CHILD
        && KAYA_APPLY_MOUNT == wire::APPLY_MOUNT
        && KAYA_APPLY_DESTROY == wire::APPLY_DESTROY
        && KAYA_APPLY_MOVE_CHILD == wire::APPLY_MOVE_CHILD
        && KAYA_APPLY_COMMAND == wire::APPLY_COMMAND
        && KAYA_APPLY_SET_WINDOW_PROP == wire::APPLY_SET_WINDOW_PROP
        && KAYA_APPLY_CREATE_WINDOW == wire::APPLY_CREATE_WINDOW
        && KAYA_APPLY_DESTROY_WINDOW == wire::APPLY_DESTROY_WINDOW
        && KAYA_APPLY_PRESENT_ALERT == wire::APPLY_PRESENT_ALERT
        && KAYA_APPLY_PUSH_ENTRY == wire::APPLY_PUSH_ENTRY
        && KAYA_APPLY_POP_ENTRY == wire::APPLY_POP_ENTRY
        && KAYA_APPLY_SET_ENTRY_PROP == wire::APPLY_SET_ENTRY_PROP
        && KAYA_APPLY_ADD_SECTION == wire::APPLY_ADD_SECTION
        && KAYA_APPLY_SELECT_SECTION == wire::APPLY_SELECT_SECTION
        && KAYA_APPLY_SET_SECTION_PROP == wire::APPLY_SET_SECTION_PROP
        && KAYA_APPLY_MENU_ITEM_CREATE == wire::APPLY_MENU_ITEM_CREATE
        && KAYA_APPLY_MENU_ITEM_APPEND == wire::APPLY_MENU_ITEM_APPEND
        && KAYA_APPLY_MENUBAR_APPEND == wire::APPLY_MENUBAR_APPEND
        && KAYA_APPLY_CONTEXT_ATTACH == wire::APPLY_CONTEXT_ATTACH
        && KAYA_APPLY_CONTEXT_ATTACH_NODE == wire::APPLY_CONTEXT_ATTACH_NODE
        && KAYA_APPLY_SET_MENU_PROP == wire::APPLY_SET_MENU_PROP
);

/// One-shot commands (the widget_command tx record / COMMAND apply
/// record): momentary verbs into widget-owned state. The closed
/// vocabulary; each verb is admitted by a real artifact.
pub const KAYA_COMMAND_CLEAR: u32 = 1;
pub const KAYA_COMMAND_FOCUS: u32 = 2;
const _: () = assert!(
    KAYA_COMMAND_CLEAR == wire::COMMAND_CLEAR && KAYA_COMMAND_FOCUS == wire::COMMAND_FOCUS
);

/// Value types.
pub const KAYA_VALUE_BOOL: u32 = 1;
pub const KAYA_VALUE_I64: u32 = 2;
pub const KAYA_VALUE_F64: u32 = 3;
pub const KAYA_VALUE_STR: u32 = 4;
pub const KAYA_VALUE_BLOB: u32 = 5;
const _: () = assert!(
    KAYA_VALUE_BOOL == wire::VALUE_BOOL
        && KAYA_VALUE_I64 == wire::VALUE_I64
        && KAYA_VALUE_F64 == wire::VALUE_F64
        && KAYA_VALUE_STR == wire::VALUE_STR
        && KAYA_VALUE_BLOB == wire::VALUE_BLOB
);

/// Widget kinds.
pub const KAYA_KIND_COLUMN: u32 = 1;
pub const KAYA_KIND_BUTTON: u32 = 2;
pub const KAYA_KIND_LABEL: u32 = 3;
pub const KAYA_KIND_ENTRY: u32 = 4;
pub const KAYA_KIND_ROW: u32 = 5;
pub const KAYA_KIND_CHECKBOX: u32 = 6;
pub const KAYA_KIND_SLIDER: u32 = 7;
pub const KAYA_KIND_IMAGE: u32 = 8;
pub const KAYA_KIND_SCROLL: u32 = 9;
pub const KAYA_KIND_PROGRESS: u32 = 10;
pub const KAYA_KIND_SELECT: u32 = 11;
pub const KAYA_KIND_RADIO: u32 = 12;
pub const KAYA_KIND_GRID: u32 = 13;
pub const KAYA_KIND_TEXTAREA: u32 = 14;
const _: () = assert!(
    KAYA_KIND_COLUMN == wire::KIND_COLUMN
        && KAYA_KIND_BUTTON == wire::KIND_BUTTON
        && KAYA_KIND_LABEL == wire::KIND_LABEL
        && KAYA_KIND_ENTRY == wire::KIND_ENTRY
        && KAYA_KIND_ROW == wire::KIND_ROW
        && KAYA_KIND_CHECKBOX == wire::KIND_CHECKBOX
        && KAYA_KIND_SLIDER == wire::KIND_SLIDER
        && KAYA_KIND_IMAGE == wire::KIND_IMAGE
        && KAYA_KIND_SCROLL == wire::KIND_SCROLL
        && KAYA_KIND_PROGRESS == wire::KIND_PROGRESS
        && KAYA_KIND_SELECT == wire::KIND_SELECT
        && KAYA_KIND_RADIO == wire::KIND_RADIO
        && KAYA_KIND_GRID == wire::KIND_GRID
        && KAYA_KIND_TEXTAREA == wire::KIND_TEXTAREA
);
// Completeness, not just agreement (the PROPS count guard's sibling
// — this exact gap recurred: KIND_PROGRESS shipped to every
// generated wire file while kaya.h silently lacked it, and the Swift
// typecheck was again the first to notice, 2026-07-22). A new spec
// kind trips this count and walks you here.
const _: () = {
    let kinds = {
        let mut n = 0;
        let mut i = 0;
        while i < crate::spec::SPEC.enums.len() {
            if konst_eq(crate::spec::SPEC.enums[i].name, "kind") {
                n = crate::spec::SPEC.enums[i].variants.len();
            }
            i += 1;
        }
        n
    };
    assert!(
        kinds == 14,
        "the spec kind enum grew: export the new KAYA_KIND_* above, extend the pin, and bump          this count"
    );
};

/// const-context string equality (std's == is not const).
const fn konst_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}

/// Property keys.
pub const KAYA_PROP_TEXT: u32 = 1;
pub const KAYA_PROP_CHECKED: u32 = 2;
pub const KAYA_PROP_VALUE: u32 = 3;
pub const KAYA_PROP_MIN: u32 = 4;
pub const KAYA_PROP_MAX: u32 = 5;
pub const KAYA_PROP_SOURCE: u32 = 6;
pub const KAYA_PROP_GROW: u32 = 7;
pub const KAYA_PROP_SPACING: u32 = 8;
pub const KAYA_PROP_ALIGN: u32 = 9;
pub const KAYA_PROP_INDETERMINATE: u32 = 10;
pub const KAYA_PROP_COLUMNS: u32 = 11;
/// The accessibility identifier and label (spec::PROPS). The
/// identifier is a stable authored key and is never spoken; the label
/// is what an assistive client says. Separate on purpose.
pub const KAYA_PROP_A11Y_ID: u32 = 12;
pub const KAYA_PROP_A11Y_LABEL: u32 = 13;
pub const KAYA_PROP_A11Y_HINT: u32 = 14;
/// Which clip representations a widget accepts, as a mask over the
/// `clip` enum (spec: the `accepts` prop). Numeric like every other
/// scalar slot; the root domain-checks it.
/// A LITERAL, like every sibling above, and the assert below is what
/// keeps it honest: cbindgen evaluates no paths, so `= wire::X` is
/// silently omitted from kaya.h and the first thing to notice is a
/// generated binding failing to compile against a constant that does
/// not exist.
pub const KAYA_PROP_ACCEPTS: u32 = 15;

/// Window properties (spec::WINDOW_PROPS): their own namespace —
/// windows are not widgets. Window 0 is the primary surface.
pub const KAYA_WPROP_TITLE: u32 = 1;
pub const KAYA_WPROP_WIDTH: u32 = 2;
pub const KAYA_WPROP_HEIGHT: u32 = 3;
pub const KAYA_WPROP_VETO_CLOSE: u32 = 4;

/// The window prop asking for the adaptive list-detail presentation of
/// this window's entry stack (DESIGN.md, Adaptive list-detail).
pub const KAYA_WPROP_LIST_DETAIL: u32 = 6;

/// The window prop saying this surface holds UNSAVED WORK
/// (docs/dirty-plan.md D1). State, not chrome: each backend spells its
/// own platform's affordance and the app's title string is untouched.
pub const KAYA_WPROP_DIRTY: u32 = 7;

/// Navigation-entry properties (spec::ENTRY_PROPS): their own typed
/// table (DESIGN.md, Navigation). `intercept_back` is the close-veto
/// class transplanted to POP.
pub const KAYA_EPROP_TITLE: u32 = 1;
pub const KAYA_EPROP_INTERCEPT_BACK: u32 = 2;

/// Section properties (spec::SECTION_PROPS) — the third typed surface
/// table (DESIGN.md, Sections). `icon` rides the blob channel.
pub const KAYA_SPROP_TITLE: u32 = 1;
pub const KAYA_SPROP_ICON: u32 = 2;

/// Menu item kinds (spec enum "menu_kind"; DESIGN.md, Menus). `menu`
/// and `radio_group` are the grouping nodes; the rest are leaves.
pub const KAYA_MENU_KIND_MENU: u32 = 1;
pub const KAYA_MENU_KIND_ACTION: u32 = 2;
pub const KAYA_MENU_KIND_TOGGLE: u32 = 3;
pub const KAYA_MENU_KIND_RADIO_GROUP: u32 = 4;
pub const KAYA_MENU_KIND_RADIO_OPTION: u32 = 5;
pub const KAYA_MENU_KIND_SEPARATOR: u32 = 6;
const _: () = assert!(
    KAYA_MENU_KIND_MENU == wire::MENU_KIND_MENU
        && KAYA_MENU_KIND_ACTION == wire::MENU_KIND_ACTION
        && KAYA_MENU_KIND_TOGGLE == wire::MENU_KIND_TOGGLE
        && KAYA_MENU_KIND_RADIO_GROUP == wire::MENU_KIND_RADIO_GROUP
        && KAYA_MENU_KIND_RADIO_OPTION == wire::MENU_KIND_RADIO_OPTION
        && KAYA_MENU_KIND_SEPARATOR == wire::MENU_KIND_SEPARATOR
);
// Completeness, not just agreement (the KAYA_KIND count-pin precedent):
// a new menu_kind trips this count and walks you to export its
// KAYA_MENU_KIND_* constant, extend the pin, and bump the count.
const _: () = {
    let variants = {
        let mut n = 0;
        let mut i = 0;
        while i < crate::spec::SPEC.enums.len() {
            if konst_eq(crate::spec::SPEC.enums[i].name, "menu_kind") {
                n = crate::spec::SPEC.enums[i].variants.len();
            }
            i += 1;
        }
        n
    };
    assert!(
        variants == 6,
        "the spec menu_kind enum grew: export the new KAYA_MENU_KIND_* above, extend the pin, \
         and bump this count"
    );
};

/// Menu properties (spec::MENU_PROPS) — the fifth typed surface table
/// (DESIGN.md, Menus). `label`/`enabled`/`checked`/`value` are
/// signal-bindable; `icon`/`primary`/`shortcut` are const-only.
pub const KAYA_MPROP_LABEL: u32 = 1;
pub const KAYA_MPROP_ENABLED: u32 = 2;
pub const KAYA_MPROP_CHECKED: u32 = 3;
pub const KAYA_MPROP_VALUE: u32 = 4;
pub const KAYA_MPROP_ICON: u32 = 5;
pub const KAYA_MPROP_PRIMARY: u32 = 6;
pub const KAYA_MPROP_SHORTCUT: u32 = 7;
pub const KAYA_MPROP_ROLE: u32 = 8;
const _: () = assert!(
    KAYA_MPROP_LABEL == wire::MPROP_LABEL
        && KAYA_MPROP_ENABLED == wire::MPROP_ENABLED
        && KAYA_MPROP_CHECKED == wire::MPROP_CHECKED
        && KAYA_MPROP_VALUE == wire::MPROP_VALUE
        && KAYA_MPROP_ICON == wire::MPROP_ICON
        && KAYA_MPROP_PRIMARY == wire::MPROP_PRIMARY
        && KAYA_MPROP_SHORTCUT == wire::MPROP_SHORTCUT
        && KAYA_MPROP_ROLE == wire::MPROP_ROLE
);
// Completeness for the menu-prop exports (the SECTION_PROPS count-pin
// sibling): a new MENU_PROPS row trips this count.
const _: () = assert!(
    crate::spec::MENU_PROPS.len() == 8,
    "spec::MENU_PROPS grew: export the new KAYA_MPROP_* above, extend the pin, and bump this \
     count"
);

/// The window prop naming how sections present, and its enum values
/// (spec enum "sections_presentation") — ADVISORY, the width/height
/// precedent; auto is the default and each platform's dominant idiom.
pub const KAYA_WPROP_SECTIONS_PRESENTATION: u32 = 5;
pub const KAYA_SECTIONS_PRESENTATION_AUTO: u32 = 0;
pub const KAYA_SECTIONS_PRESENTATION_BAR: u32 = 1;
pub const KAYA_SECTIONS_PRESENTATION_SIDEBAR: u32 = 2;
const _: () = assert!(
    KAYA_SPROP_TITLE == wire::SPROP_TITLE
        && KAYA_SPROP_ICON == wire::SPROP_ICON
        && KAYA_WPROP_SECTIONS_PRESENTATION == wire::WPROP_SECTIONS_PRESENTATION
        && KAYA_SECTIONS_PRESENTATION_AUTO == wire::SECTIONS_PRESENTATION_AUTO
        && KAYA_SECTIONS_PRESENTATION_BAR == wire::SECTIONS_PRESENTATION_BAR
        && KAYA_SECTIONS_PRESENTATION_SIDEBAR == wire::SECTIONS_PRESENTATION_SIDEBAR
);
// Completeness for the occurrence exports too: the section_selected
// record shipped to every generated wire file while KAYA_OCCURRENCE_*
// silently lacked it, and check-abort's Swift build was the first
// thing to notice (the spacing-prop lesson, occurrence spelling). A
// new spec occurrence trips this count and walks you here.
const _: () = assert!(
    crate::spec::SPEC.occurrence.len() == 18,
    "spec occurrences grew: export the new KAYA_OCCURRENCE_* above, extend the pin, and \
     bump this count"
);
const _: () = assert!(
    crate::spec::SECTION_PROPS.len() == 2,
    "spec::SECTION_PROPS grew: export the new KAYA_SPROP_* above, extend the pin, and bump \
     this count"
);

/// Alert choices (the alert_result occurrence's `choice`): action
/// indices, or the deliberately-not-an-index cancel sentinel every
/// platform-native dismissal (Esc, back, outside tap) resolves to.
pub const KAYA_ALERT_CHOICE_ACTION0: u32 = 0;
pub const KAYA_ALERT_CHOICE_ACTION1: u32 = 1;
pub const KAYA_ALERT_CHOICE_CANCEL: u32 = u32::MAX;
const _: () = assert!(
    KAYA_ALERT_CHOICE_ACTION0 == wire::ALERT_CHOICE_ACTION0
        && KAYA_ALERT_CHOICE_ACTION1 == wire::ALERT_CHOICE_ACTION1
        && KAYA_ALERT_CHOICE_CANCEL == wire::ALERT_CHOICE_CANCEL
);
const _: () = assert!(
    KAYA_PROP_TEXT == wire::PROP_TEXT
        && KAYA_PROP_CHECKED == wire::PROP_CHECKED
        && KAYA_PROP_VALUE == wire::PROP_VALUE
        && KAYA_PROP_MIN == wire::PROP_MIN
        && KAYA_PROP_MAX == wire::PROP_MAX
        && KAYA_PROP_SOURCE == wire::PROP_SOURCE
        && KAYA_PROP_GROW == wire::PROP_GROW
        && KAYA_PROP_SPACING == wire::PROP_SPACING
        && KAYA_PROP_ALIGN == wire::PROP_ALIGN
        && KAYA_PROP_INDETERMINATE == wire::PROP_INDETERMINATE
        && KAYA_PROP_COLUMNS == wire::PROP_COLUMNS
        && KAYA_PROP_A11Y_ID == wire::PROP_A11Y_ID
        && KAYA_PROP_A11Y_LABEL == wire::PROP_A11Y_LABEL
        && KAYA_PROP_A11Y_HINT == wire::PROP_A11Y_HINT
        && KAYA_PROP_ACCEPTS == wire::PROP_ACCEPTS
        && KAYA_WPROP_TITLE == wire::WPROP_TITLE
        && KAYA_WPROP_WIDTH == wire::WPROP_WIDTH
        && KAYA_WPROP_HEIGHT == wire::WPROP_HEIGHT
        && KAYA_WPROP_VETO_CLOSE == wire::WPROP_VETO_CLOSE
        && KAYA_WPROP_LIST_DETAIL == wire::WPROP_LIST_DETAIL
        && KAYA_WPROP_DIRTY == wire::WPROP_DIRTY
        && KAYA_EPROP_TITLE == wire::EPROP_TITLE
        && KAYA_EPROP_INTERCEPT_BACK == wire::EPROP_INTERCEPT_BACK
);

/// The align enum's values (spec enum "align"); baseline is rows-only.
pub const KAYA_ALIGN_START: u32 = 0;
pub const KAYA_ALIGN_CENTER: u32 = 1;
pub const KAYA_ALIGN_END: u32 = 2;
pub const KAYA_ALIGN_STRETCH: u32 = 3;
pub const KAYA_ALIGN_BASELINE: u32 = 4;
const _: () = assert!(
    KAYA_ALIGN_START == wire::ALIGN_START
        && KAYA_ALIGN_CENTER == wire::ALIGN_CENTER
        && KAYA_ALIGN_END == wire::ALIGN_END
        && KAYA_ALIGN_STRETCH == wire::ALIGN_STRETCH
        && KAYA_ALIGN_BASELINE == wire::ALIGN_BASELINE
);
// Completeness, not just agreement: the value pins above cannot see a
// FORGOTTEN export (the spacing prop shipped to every generated wire
// file while kaya.h silently lacked it, and the Swift binding was the
// first thing to notice). A new spec prop trips this count and walks
// you here.
const _: () = assert!(
    crate::spec::PROPS.len() == 15,
    "spec::PROPS grew: export the new KAYA_PROP_* above, extend the pin, and bump this count"
);
const _: () = assert!(
    crate::spec::WINDOW_PROPS.len() == 7,
    "spec::WINDOW_PROPS grew: export the new KAYA_WPROP_* above, extend the pin, and bump \
     this count"
);
const _: () = assert!(
    crate::spec::ENTRY_PROPS.len() == 2,
    "spec::ENTRY_PROPS grew: export the new KAYA_EPROP_* above, extend the pin, and bump \
     this count"
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
        // The watchdog reads this ring's consumer cursor (crate::stall).
        // HERE, where the one process-wide ring is born, because every
        // other candidate is an entry point somebody has to remember.
        crate::stall::watch_ring(Arc::clone(&ring));
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
    // One backend per platform. On Apple the SwiftUI interpreter runs
    // its own presentation pump over this same C API, so core_ends
    // stays in place for it to take.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        crate::swiftui_host::run()
    }

    #[cfg(any(target_os = "windows", target_os = "linux"))]
    {
        let (occ_sink, tx_rx) = take_core_ends().expect("kaya_run may only be called once");
        crate::backend::run_core(occ_sink, tx_rx)
    }

    #[cfg(target_os = "android")]
    {
        panic!("Android owns the process entry; attach from an Activity instead of kaya_run")
    }
}

/// The core's ends of the transport: the ring-backed occurrence sink and
/// the transaction receiver. Taken once, by whichever entry starts the
/// core (kaya_run here; KayaRing.attach on Android, where the OS owns
/// main).
#[cfg_attr(
    any(target_os = "macos", target_os = "ios", target_os = "android"),
    allow(dead_code)
)] // The interpreter platforms' pump takes core_ends inline in
// kaya_next_commands; only the Rust-native backends' kaya_run arm
// takes them here.
pub(crate) fn take_core_ends() -> Option<(OccSink, Receiver<Transaction>)> {
    state().core_ends.lock().unwrap().take()
}

/// The occurrence ring's raw layout, for the JVM tier (jvm.rs's
/// KayaRing natives) to expose as addresses the Java side reads
/// directly — Android's Compose backend and the desktop JVM guests
/// consume the same surface.
#[cfg(any(
    target_os = "android",
    target_os = "macos",
    target_os = "windows",
    target_os = "linux"
))]
pub(crate) fn ring_raw() -> (*mut u8, u32, *mut u32, *mut u32) {
    state().ring.raw()
}

/// The blob tables: bulk payload bytes live once, in core-owned
/// memory, and every record stream carries 8-byte handles.
///
/// Two directions, two small id spaces:
/// - `pending` (guest -> core): kaya_blob_register copies bytes in and
///   returns a handle valid for exactly one submit — the next
///   kaya_submit resolves references (Arc clones into values) and
///   drains the whole table, referenced or not, so registration's
///   ownership transfers at the submit boundary and an unreferenced
///   blob cannot leak.
/// - `out` (core -> presentation pump): batch-local, 1-based indices
///   minted by the wire writer; kaya_blob_data serves the CURRENT
///   batch and the next kaya_next_commands call replaces it. Fetch and
///   decode within the batch, per the pump contract.
///
/// Reclamation is refcount: scene state (signal values, collection
/// records) holds Arc clones, so restamps re-read without re-upload,
/// and the last drop frees (DESIGN open question #2).
struct Blobs {
    next: u64,
    pending: std::collections::HashMap<u64, std::sync::Arc<[u8]>>,
    out: Vec<std::sync::Arc<[u8]>>,
}

fn blobs() -> &'static std::sync::Mutex<Blobs> {
    static BLOBS: std::sync::OnceLock<std::sync::Mutex<Blobs>> = std::sync::OnceLock::new();
    BLOBS.get_or_init(|| {
        std::sync::Mutex::new(Blobs { next: 1, pending: std::collections::HashMap::new(), out: Vec::new() })
    })
}

/// Register bulk payload bytes (an encoded image, a row batch) and get
/// the handle the next submitted transaction references them by. One
/// copy, into core-owned memory; `len` is a usize — blob size is
/// bounded by memory, never by any wire or pump buffer, because the
/// bytes never enter a record stream. The handle is consumed by the
/// next kaya_submit from this guest, referenced or not.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_blob_register(bytes: *const u8, len: usize) -> u64 {
    let src = if bytes.is_null() || len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, len) }
    };
    let mut table = blobs().lock().unwrap();
    let handle = table.next;
    table.next += 1;
    table.pending.insert(handle, std::sync::Arc::from(src));
    handle
}

/// Fetch a blob's bytes by the handle an apply record carried. Returns
/// the byte pointer and writes the length; NULL for a dead handle (a
/// batch already superseded). The pointer borrows core memory and is
/// valid until the next kaya_next_commands call — fetch and decode
/// within the batch.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_blob_data(handle: u64, len: *mut usize) -> *const u8 {
    let table = blobs().lock().unwrap();
    // Pump handles are 1-based indices into the current batch's table.
    match usize::try_from(handle).ok().and_then(|h| h.checked_sub(1)).and_then(|i| table.out.get(i))
    {
        Some(arc) => {
            if !len.is_null() {
                unsafe { *len = arc.len() };
            }
            arc.as_ptr()
        }
        None => {
            if !len.is_null() {
                unsafe { *len = 0 };
            }
            std::ptr::null()
        }
    }
}

/// THE OCCURRENCE BLOB TABLE, the third direction: core -> guest.
///
/// The other two both have a boundary that retires a handle — a submit
/// drains `pending`, a batch replaces `out` — and this one has neither.
/// The guest takes occurrences one at a time and the core cannot see it
/// advance, least of all the direct-ring consumers that move the head
/// themselves. So these handles are released EXPLICITLY.
///
/// THE APP NEVER SEES ONE. A binding decoding an occurrence redeems the
/// handle, copies the bytes into its own language's byte type, and
/// releases before the occurrence reaches the guest — the same shape a
/// backend already uses on the pump side, and the reason the contract
/// is safe to state as "release immediately". An app holding a pasted
/// image holds its own bytes, so nothing here outlives the decode.
struct OccBlobs {
    next: u64,
    live: std::collections::HashMap<u64, std::sync::Arc<[u8]>>,
}

fn occ_blobs() -> &'static Mutex<OccBlobs> {
    static TABLE: OnceLock<Mutex<OccBlobs>> = OnceLock::new();
    TABLE.get_or_init(|| {
        Mutex::new(OccBlobs {
            next: 1,
            live: std::collections::HashMap::new(),
        })
    })
}

/// Core side: publish bytes an occurrence record will name by handle.
pub(crate) fn occ_blob_register(bytes: std::sync::Arc<[u8]>) -> u64 {
    let mut table = occ_blobs().lock().unwrap();
    let handle = table.next;
    table.next += 1;
    table.live.insert(handle, bytes);
    handle
}

/// Fetch the bytes an occurrence's blob value named. Returns the
/// pointer and writes the length; NULL for a handle already released.
/// The pointer borrows core memory and stays valid until
/// `kaya_occurrence_blob_release` — copy, then release.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_occurrence_blob(handle: u64, len: *mut usize) -> *const u8 {
    let table = occ_blobs().lock().unwrap();
    match table.live.get(&handle) {
        Some(arc) => {
            if !len.is_null() {
                unsafe { *len = arc.len() };
            }
            arc.as_ptr()
        }
        None => {
            if !len.is_null() {
                unsafe { *len = 0 };
            }
            std::ptr::null()
        }
    }
}

/// Drop an occurrence blob. Idempotent: a handle already released, or
/// never minted, is a no-op rather than an error, so a binding's
/// decode path needs no bookkeeping of its own.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_occurrence_blob_release(handle: u64) {
    occ_blobs().lock().unwrap().live.remove(&handle);
}

/// Submit one transaction: `len` bytes of records at `records`, applied
/// atomically on the UI thread. The buffer is copied before this call
/// returns. Malformed records are a broken binding and fail loudly.
/// Blob references resolve against the pending registration table,
/// which drains at this boundary whether referenced or not.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_submit(records: *const u8, len: usize) {
    let buf = if records.is_null() || len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(records, len) }
    };
    let tx = {
        let mut table = blobs().lock().unwrap();
        let pending = std::mem::take(&mut table.pending);
        drop(table);
        wire::decode_transaction_with_blobs(buf, &|h| pending.get(&h).cloned())
    };
    if state().tx_tx.send(tx).is_ok() {
        crate::backend::ring_doorbell();
    }
}

/// Returned by `kaya_next_occurrence` when the core has shut down.
pub const KAYA_OCCURRENCE_SHUTDOWN: usize = 0;

/// Returned by `kaya_next_occurrence` when a background thread called
/// `kaya_wake`: no record was handed out, and the caller should run
/// whatever it has queued of its own before waiting again. Chosen
/// SMALLER than any real record (a header alone is 8 bytes) rather than
/// as a huge sentinel, so a consumer that has not learned about it yet
/// cannot mistake it for a length and read past the record.
pub const KAYA_OCCURRENCE_WOKEN: usize = 1;

thread_local! {
    /// Where the record handed out by the last `kaya_next_occurrence`
    /// lives. THREAD-LOCAL AND NOT A GLOBAL because the borrow's
    /// lifetime is stated per caller ("until your next call"), and a
    /// second thread calling would otherwise free bytes the app thread
    /// is still decoding — the failure would be a torn paste, arriving
    /// nowhere near the thread that caused it.
    static HELD_OCCURRENCE: std::cell::RefCell<Vec<u8>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// Function-floor consumption: block until the next occurrence and hand
/// back one complete record — header included, exactly the ring's bytes.
/// Writes the borrowed pointer to `record` and returns its size, or
/// `KAYA_OCCURRENCE_SHUTDOWN` when the core has shut down, or
/// `KAYA_OCCURRENCE_WOKEN` when a background thread rang the doorbell
/// for work of the caller's own. Call from a single app thread, and do
/// not mix with direct ring access.
///
/// BOTH SENTINELS NULL THE POINTER rather than leaving it as it was,
/// and that is deliberate. A caller that forgets the WOKEN case used to
/// re-parse the buffer it still held — the PREVIOUS occurrence,
/// dispatched a second time, silently. Nulling turns that into a crash
/// at the deref, on the line that forgot, instead of a stale click
/// nobody can trace back here.
///
/// THE CORE OWNS THE BYTES, and that is the whole point of the shape.
/// This used to copy into a caller-sized buffer, and every function-floor
/// caller sized it 256 — which meant an occurrence carrying more than
/// 208 bytes of payload ABORTED THE PROCESS from inside an extern "C"
/// frame, uncatchable, with no guest able to guard against it. A pasted
/// paragraph does that, and an html clip does it every time (measured
/// 2026-08-02: 200 bytes of pasted text passed, 240 aborted). No cap is
/// the fix rather than a bigger cap: a limit on how much content may
/// reach a guest is not something kaya gets to have, and a buffer that
/// cannot be too small cannot be too small at 1 MB either.
///
/// The bytes stay valid until this thread's NEXT call — copy out what
/// you keep, exactly as `kaya_blob_data` and `kaya_occurrence_blob`
/// already ask.
///
/// # Safety
/// `record` must be a valid place to write a pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_next_occurrence(record: *mut *const u8) -> usize {
    if record.is_null() {
        return KAYA_OCCURRENCE_SHUTDOWN;
    }
    unsafe { *record = std::ptr::null() };
    match state().ring.wait_pop() {
        crate::ring::Waited::Record(kind, body) => {
            let size = wire::HEADER_SIZE + body.len();
            HELD_OCCURRENCE.with(|held| {
                let mut held = held.borrow_mut();
                held.clear();
                held.reserve(size);
                held.extend_from_slice(&(size as u32).to_le_bytes());
                held.extend_from_slice(&kind.to_le_bytes());
                held.extend_from_slice(&0u16.to_le_bytes());
                held.extend_from_slice(&body);
                unsafe { *record = held.as_ptr() };
            });
            size
        }
        crate::ring::Waited::Woken => KAYA_OCCURRENCE_WOKEN,
        crate::ring::Waited::Shutdown => KAYA_OCCURRENCE_SHUTDOWN,
    }
}

/// Wake this process's app thread from wherever it is parked waiting for
/// occurrences. SAFE FROM ANY THREAD — the only entry here that is.
///
/// WHO CALLS IT. In the sugar languages, the BINDING does, inside its
/// post: the guest hands over a closure, the binding queues it in the
/// binding's own closure type, and this is how it tells the app thread
/// to come and look. A guest in those languages never names this
/// function, the same way it never names kaya_submit.
///
/// A C guest has no binding, so it calls this itself. It owns the queue
/// — a mutex and a list — rings this, and drains the queue in the
/// occurrence loop it already writes by hand. That is the floor being
/// the floor, exactly as a C guest builds its widget tree with
/// kaya_tx_* calls rather than a construction chain.
///
/// EITHER WAY, CLOSURES DO NOT CROSS THIS ABI. All the core owes a
/// posting thread is the wake-up. A function-pointer-plus-void-star
/// work queue down here would be one uniform mechanism, and also the
/// worst spelling available in seven of the eight sugar languages.
///
/// Calling it with nothing queued is harmless: the app thread spins
/// once, finds the ring empty and its own queue empty, and parks again.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_wake() {
    state().ring.wake();
}

/// How many milliseconds the app thread has been ignoring pending
/// occurrences, or 0 when it is keeping up.
///
/// The stall watchdog's reading, for anyone outside Rust: the SwiftUI
/// and Compose interpreters answer `expect_stall` with it, and an app
/// that wants to report its own health can poll it. See crate::stall
/// for what does and does not count as a stall.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_stalled_ms() -> u64 {
    crate::stall::stalled_for()
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
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

/// Presentation side: the user asked a veto_close window to close.
/// Nothing has closed; the app answers with destroy_window if it
/// agrees (the request/confirm veto class).
#[unsafe(no_mangle)]
pub extern "C" fn kaya_emit_close_requested(window: u64) {
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send(crate::protocol::Occurrence::CloseRequested {
            window: crate::protocol::WindowId(window),
        });
        return;
    }
    state()
        .ring
        .push_record(ring::REC_CLOSE_REQUESTED, &window.to_le_bytes());
}

/// Presentation side: a non-veto auxiliary window was chrome-closed
/// (informational and post-fact; destroy_window reconciles).
#[unsafe(no_mangle)]
pub extern "C" fn kaya_emit_window_closed(window: u64) {
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send(crate::protocol::Occurrence::WindowClosed {
            window: crate::protocol::WindowId(window),
        });
        return;
    }
    state()
        .ring
        .push_record(ring::REC_WINDOW_CLOSED, &window.to_le_bytes());
}

/// Presentation side (interpreter platforms ONLY): the user's back
/// affordance popped a navigation entry natively. Reconciles the
/// core-owned stack (the scene lives in this module's singleton on
/// these platforms), then forwards the post-fact occurrence. cfg'd
/// OUT on the rust-native backend platforms like alert_resolved:
/// their backends reconcile their own scene and emit on their own
/// core OccSink.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
pub(crate) fn entry_user_popped(entry: u64) {
    PRESENTATION_SCENE
        .lock()
        .unwrap()
        .as_mut()
        .expect("kaya: entry popped before any transaction was applied")
        .user_popped(crate::protocol::WindowId(entry));
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send(crate::protocol::Occurrence::EntryPopped {
            entry: crate::protocol::WindowId(entry),
        });
        return;
    }
    state()
        .ring
        .push_record(ring::REC_ENTRY_POPPED, &entry.to_le_bytes());
}

/// Presentation side: the user's back affordance popped a navigation
/// entry natively (post-fact; the core's stack reconciles here).
/// Exported on every platform (one C header, one export surface), but
/// answerable only where a guest-language presentation layer exists —
/// the kaya_emit_alert_result pattern.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_emit_entry_popped(entry: u64) {
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
    {
        entry_user_popped(entry);
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "android")))]
    {
        let _ = entry;
        panic!(
            "kaya: kaya_emit_entry_popped is the interpreter platforms' entry — \
             this host's backend reconciles pops on its own sink"
        );
    }
}

/// Presentation side: the user switched sections through the
/// platform's own switcher (post-fact — the selection has already
/// changed on screen; the core's selected-section mirror reconciles
/// here). Only the user's act arrives this way: a programmatic
/// select_section is configuration and never echoes (the echo
/// doctrine). The entry_popped export pattern: one header, every
/// platform, answerable where a presentation layer exists.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_emit_section_selected(window: u64, section: u64) {
    PRESENTATION_SCENE
        .lock()
        .unwrap()
        .as_mut()
        .expect("kaya: section selected before any transaction was applied")
        .user_selected_section(
            crate::protocol::WindowId(window),
            crate::protocol::WindowId(section),
        );
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send(crate::protocol::Occurrence::SectionSelected {
            window: crate::protocol::WindowId(window),
            section: crate::protocol::WindowId(section),
        });
        return;
    }
    let mut body = [0u8; 16];
    body[..8].copy_from_slice(&window.to_le_bytes());
    body[8..].copy_from_slice(&section.to_le_bytes());
    state().ring.push_record(ring::REC_SECTION_SELECTED, &body);
}

/// Presentation side: the user drove the back affordance on an entry
/// whose intercept_back is armed. Nothing has popped; the app answers
/// with pop_entry if it agrees (the close_requested veto class).
#[unsafe(no_mangle)]
pub extern "C" fn kaya_emit_back_requested(entry: u64) {
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send(crate::protocol::Occurrence::BackRequested {
            entry: crate::protocol::WindowId(entry),
        });
        return;
    }
    state()
        .ring
        .push_record(ring::REC_BACK_REQUESTED, &entry.to_le_bytes());
}

// The live alert slot: ONE alert per process (the platform floor —
// ContentDialog throws on a second per root). Process-global on
// purpose: the scene sets it at show (apply side) and the result that
// frees it arrives on the presentation side — this singleton is the
// one state both ends share.
/// THE PICKED-FILE TABLE. Handles are integers into this map, and the
/// map holds what only the backend understands — an `NSURL`, a Java
/// `Uri`, a `StorageFile`, a path. Same shape as the blob table above:
/// a monotonic counter, a `Mutex<HashMap<u64, _>>` behind a `OnceLock`,
/// an integer out to the guest.
///
/// WHY A TABLE AND NOT THE POINTER ITSELF. Four things a raw
/// `uintptr_t` would cost: the object is refcounted, so its lifetime
/// becomes a manual protocol spelled nine times; a bogus value is
/// undefined behaviour where a bogus integer is a clean error; it is
/// not ONE kind of pointer (ObjC retain/release, a JNI reference, WinRT
/// AddRef/Release, a `char*` to free) and uniform semantics means the
/// guest cannot see which; and a JNI local ref is valid only on its
/// creating thread and frame. Every id in kaya is already an integer
/// with a table behind it; a pointer would be the sole exception.
///
/// Entries are process-lifetime. They hold nothing the kernel counts,
/// which is why explicit release is deferred (DESIGN.md).
struct Picked {
    next: u64,
    live: std::collections::HashMap<u64, std::sync::Arc<dyn crate::protocol::PickedSource>>,
}

fn picked() -> &'static Mutex<Picked> {
    static PICKED: std::sync::OnceLock<Mutex<Picked>> = std::sync::OnceLock::new();
    PICKED.get_or_init(|| {
        Mutex::new(Picked {
            next: 1,
            live: std::collections::HashMap::new(),
        })
    })
}

/// Backend side: register one picked file and get the handle the guest
/// will name it by.
pub(crate) fn picked_register(
    source: std::sync::Arc<dyn crate::protocol::PickedSource>,
) -> crate::protocol::PickedId {
    let mut table = picked().lock().unwrap();
    let handle = table.next;
    table.next += 1;
    table.live.insert(handle, source);
    crate::protocol::PickedId(handle)
}

/// What the PLATFORM calls a picked file, for a backend that has to
/// put it somewhere the platform understands — a pasteboard file URL,
/// a `text/uri-list` line, a `DROPFILES` entry.
///
/// A DEAD HANDLE FAILS LOUDLY rather than copying an empty reference:
/// entries are process-lifetime, so the only way to miss is to name a
/// handle that was never minted, which is a broken guest.
pub(crate) fn picked_locator(handle: crate::protocol::PickedId) -> String {
    let table = picked().lock().unwrap();
    match table.live.get(&handle.0) {
        Some(source) => crate::protocol::PickedSource::locator(&**source).to_owned(),
        None => panic!(
            "kaya: copy names picked file {} , which was never minted — a \
             file handle comes from a picker result",
            handle.0
        ),
    }
}

/// Redeem a handle for an open descriptor. THE ONE ENTRY HERE THAT IS
/// SAFE FROM ANY THREAD, alongside kaya_wake.
///
/// Returns 0 on success and writes `out_fd` plus `out_seekable`;
/// returns the errno-shaped failure otherwise. The open is FALLIBLE in
/// ways the pick is not: no picker on any platform lets you request
/// write, so a read-only document refuses here rather than earlier, and
/// that is the correct place — kaya surfaces the platform's answer and
/// does not stand between the guest and the error.
///
/// RESOLVE UNDER THE LOCK, RELEASE, THEN OPEN. The lock covers a map
/// lookup; holding it across the open would serialize every concurrent
/// open and undo the parallelism the guest created by spawning threads.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_open_picked(
    handle: u64,
    mode: u32,
    out_handle: *mut i64,
    out_seekable: *mut u32,
) -> i32 {
    if out_handle.is_null() || out_seekable.is_null() {
        return libc_einval();
    }
    let source = {
        let table = picked().lock().unwrap();
        match table.live.get(&handle) {
            Some(s) => std::sync::Arc::clone(s),
            None => return libc_einval(),
        }
    };
    let mode = match mode {
        crate::wire::FILE_MODE_READ => crate::protocol::FileMode::Read,
        crate::wire::FILE_MODE_WRITE => crate::protocol::FileMode::Write,
        crate::wire::FILE_MODE_READ_WRITE => crate::protocol::FileMode::ReadWrite,
        _ => return libc_einval(),
    };
    match source.open(mode) {
        Ok((raw, seekable)) => {
            unsafe {
                *out_handle = raw;
                *out_seekable = u32::from(seekable);
            }
            0
        }
        Err(e) => e.raw_os_error().unwrap_or(libc_einval()),
    }
}

/// EINVAL without pulling in libc: the value is stable across every
/// platform kaya targets.
fn libc_einval() -> i32 {
    22
}

#[cfg(all(test, unix))]
mod picked_tests {
    use super::*;
    use crate::protocol::PathSource;
    use std::io::Read;

    /// THE CENTRAL CLAIM OF THE FILE-DIALOG DESIGN, at unit level: a
    /// handle redeems for a REAL descriptor, and the caller reads it
    /// with its own file API while the core is nowhere in the data
    /// path.
    #[test]
    fn a_handle_redeems_for_a_readable_descriptor() {
        let dir = std::env::temp_dir().join(format!("kaya-picked-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("note.txt");
        std::fs::write(&path, b"picked bytes").unwrap();

        let handle = picked_register(std::sync::Arc::new(PathSource {
            name: "note.txt".into(),
            path: path.to_string_lossy().into_owned(),
        }));

        let mut fd = -1i64;
        let mut seekable = 0u32;
        assert_eq!(kaya_open_picked(handle.0, crate::wire::FILE_MODE_READ, &mut fd, &mut seekable), 0);
        assert!(fd >= 0);
        assert_eq!(seekable, 1, "a regular file seeks");

        // The guest's own file API, from here on.
        let mut file = unsafe { crate::protocol::file_from_raw(fd) };
        let mut got = String::new();
        file.read_to_string(&mut got).unwrap();
        assert_eq!(got, "picked bytes");

        // REDEEMABLE MORE THAN ONCE — that is what makes save-back work
        // without pinning a writable descriptor from the moment of the
        // pick (DESIGN.md, measurement 7).
        let mut fd2 = -1i64;
        assert_eq!(
            kaya_open_picked(handle.0, crate::wire::FILE_MODE_READ_WRITE, &mut fd2, &mut seekable),
            0
        );
        assert!(fd2 >= 0);
        drop(unsafe { crate::protocol::file_from_raw(fd2) });

        std::fs::remove_dir_all(&dir).ok();
    }

    /// A WRONG HANDLE IS A CLEAN ERROR, which is the whole reason the
    /// table exists instead of handing the guest a pointer. With a
    /// pointer this is undefined behaviour.
    #[test]
    fn a_bogus_handle_or_mode_fails_cleanly() {
        let mut fd = -1i64;
        let mut seekable = 0u32;
        assert_ne!(
            kaya_open_picked(u64::MAX, crate::wire::FILE_MODE_READ, &mut fd, &mut seekable),
            0,
            "an unknown handle must not succeed"
        );
        assert_eq!(fd, -1, "a failed open writes no descriptor");

        let handle = picked_register(std::sync::Arc::new(PathSource {
            name: "x".into(),
            path: "/nonexistent/kaya".into(),
        }));
        assert_ne!(
            kaya_open_picked(handle.0, 99, &mut fd, &mut seekable),
            0,
            "an unknown mode must not succeed"
        );
        // And the platform's own failure reaches the caller unchanged:
        // kaya surfaces the error, it does not stand between the guest
        // and it.
        let rc = kaya_open_picked(handle.0, crate::wire::FILE_MODE_READ, &mut fd, &mut seekable);
        assert_ne!(rc, 0, "opening a missing path must fail");
    }
}

static ALERT_LIVE: Mutex<Option<u64>> = Mutex::new(None);

/// Scene side: a show_alert was applied. Panics if one is already
/// live — a guest error (show the next alert from the first's result
/// handler).
/// The one-live-dialog slot, the alert's rule for the same reason: the
/// platform floor allows one modal picker at a time, and the result
/// that frees the slot arrives on the presentation side, so the slot
/// lives here — the one state both ends share.
static FILE_DIALOG_LIVE: Mutex<Option<u64>> = Mutex::new(None);

/// Scene side: a show_file_dialog was applied.
pub(crate) fn file_dialog_shown(dialog: crate::protocol::FileDialogId) {
    let mut live = FILE_DIALOG_LIVE.lock().unwrap();
    if let Some(id) = *live {
        panic!(
            "kaya: file dialog {id} is already live — one per process; \
             show the next from the first's result handler"
        );
    }
    *live = Some(dialog.0);
}

/// Validate the dialog id against the live slot and free it — the one
/// retire gate for every backend, EMISSION being the caller's (the
/// alert_retire split, for the same reason: a ring push from a
/// rust-native backend would strand the result).
pub(crate) fn file_dialog_retire(dialog: u64) {
    let mut live = FILE_DIALOG_LIVE.lock().unwrap();
    match *live {
        Some(id) if id == dialog => *live = None,
        Some(id) => panic!("kaya: file dialog result for {dialog} but {id} is the live one"),
        None => panic!("kaya: file dialog result for {dialog} but none is live"),
    }
}

/// Presentation side (interpreter platforms ONLY, exactly as
/// alert_resolved): retire, then emit on the presentation sink.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
pub(crate) fn file_dialog_resolved(dialog: u64, files: Vec<crate::protocol::PickedFile>) {
    file_dialog_retire(dialog);
    let dialog = crate::protocol::FileDialogId(dialog);
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send(crate::protocol::Occurrence::FileDialogResult { dialog, files });
        return;
    }
    state().ring.push_record(
        ring::REC_FILE_DIALOG_RESULT,
        &crate::wire::file_dialog_result_body(dialog, &files),
    );
}

pub(crate) fn alert_shown(alert: crate::protocol::AlertId) {
    let mut live = ALERT_LIVE.lock().unwrap();
    if let Some(id) = *live {
        panic!(
            "kaya: alert {id} is already live — one alert per process; \
             show the next from the first's result handler"
        );
    }
    *live = Some(alert.0);
}

/// Validate the alert id against the live slot and free it — the one
/// retire gate for every backend. EMISSION is the caller's: the
/// C entry below rides the presentation sink / ring, and the
/// Rust-native backends send on their own core OccSink (a ring push
/// there would strand the result — their guests listen on the Mpsc;
/// the linux confirm-rust legs caught exactly that).
pub(crate) fn alert_retire(alert: u64) {
    let mut live = ALERT_LIVE.lock().unwrap();
    match *live {
        Some(id) if id == alert => *live = None,
        Some(id) => panic!(
            "kaya: alert result for {alert} but alert {id} is the live one"
        ),
        None => panic!("kaya: alert result for {alert} but no alert is live"),
    }
}

/// Presentation side (interpreter platforms ONLY): retire, then emit
/// on the presentation sink (the ring for foreign guests, the AppCtx
/// mpsc for the Rust API's runtime-selected modes). cfg'd OUT on the
/// rust-native backend platforms on purpose: their guests listen on
/// the backend's own OccSink, so a call from gtk.rs/winui would
/// strand results on the ring (the linux confirm-rust legs caught
/// exactly that) — this way the call cannot compile there at all.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
pub(crate) fn alert_resolved(alert: u64, choice: crate::protocol::AlertChoice) {
    alert_retire(alert);
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send(crate::protocol::Occurrence::AlertResult {
            alert: crate::protocol::AlertId(alert),
            choice,
        });
        return;
    }
    state().ring.push_record(
        ring::REC_ALERT_RESULT,
        &crate::wire::alert_result_body(crate::protocol::AlertId(alert), choice),
    );
}

/// Presentation side: the alert's one answer — an ALERT_CHOICE value
/// (an action index, or the cancel sentinel for every platform-native
/// dismissal). The alert id retires here. Exported on every platform
/// (one C header, one export surface — deploy-win's header/dll gate
/// holds that line), but ANSWERABLE only where a guest-language
/// presentation layer exists: the rust-native backends emit on their
/// own core sink (alert_resolved is cfg'd out of existence there),
/// so on GTK/WinUI hosts this entry has no caller by construction
/// and panics loudly if one appears.
/// Turn a backend's parallel locator/name arrays into registered picked
/// files. THE ONE PLACE THE PLATFORM SOURCE IS CHOSEN — the picker and
/// a pasted file list both arrive as locators, and a second copy of
/// this decision is a second place for a platform to be forgotten.
///
/// # Safety
/// `locators` and `names` must each point to `count` valid
/// NUL-terminated UTF-8 strings that outlive the call.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
unsafe fn register_picked(
    locators: *const *const std::os::raw::c_char,
    names: *const *const std::os::raw::c_char,
    count: usize,
) -> Vec<crate::protocol::PickedFile> {
    let mut files = Vec::with_capacity(count);
    for i in 0..count {
        let read = |base: *const *const std::os::raw::c_char| -> String {
            if base.is_null() {
                return String::new();
            }
            let p = unsafe { *base.add(i) };
            if p.is_null() {
                return String::new();
            }
            unsafe { std::ffi::CStr::from_ptr(p) }
                .to_string_lossy()
                .into_owned()
        };
        // ONE SOURCE PER PLATFORM, decided here because the locator
        // means something different on each: a path on macOS, a
        // `content://` URI on Android, and on iOS a name only the
        // backend can redeem (the path EPERMs once the scope drops).
        #[cfg(target_os = "android")]
        let source: std::sync::Arc<dyn crate::protocol::PickedSource> =
            std::sync::Arc::new(crate::android::UriSource {
                name: read(names),
                uri: read(locators),
            });
        #[cfg(target_os = "ios")]
        let source: std::sync::Arc<dyn crate::protocol::PickedSource> =
            std::sync::Arc::new(crate::swiftui_host::UrlSource {
                name: read(names),
                locator: read(locators),
            });
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        let source: std::sync::Arc<dyn crate::protocol::PickedSource> =
            std::sync::Arc::new(crate::protocol::PathSource {
                name: read(names),
                path: read(locators),
            });
        let handle = picked_register(source.clone());
        // Read the record back OFF the source, so the source stays the
        // single answer to "what is this file called and can its name
        // be re-opened".
        files.push(crate::protocol::PickedFile {
            handle,
            name: crate::protocol::PickedSource::name(&*source).to_owned(),
            local_path: crate::protocol::PickedSource::local_path(&*source).to_owned(),
        });
    }
    files
}

/// Presentation side: the file picker's one answer. `locators` and
/// `names` are parallel arrays of `count` NUL-terminated UTF-8 strings;
/// an EMPTY count is cancel, which every platform reports the same way
/// because none can confirm an empty selection.
///
/// LOCATORS AND NOT PATHS: a locator is whatever the platform's picker
/// says a file IS, and that differs. macOS and iOS answer with a
/// filesystem path; Android answers with a `content://` URI into a
/// document provider that may not be a filesystem at all. The parameter
/// was called `paths` while only the desktops had an arm, and the name
/// would have been a lie the moment Android got one.
///
/// THE CORE MINTS THE HANDLES, not the backend: it wraps each locator in
/// the platform's source, registers it, and hands the guest integers. On
/// the desktops a path IS the capability, so `PathSource` is the whole
/// story. Android registers a source holding the URI, because opening it
/// means the ContentResolver — which is exactly why the registration
/// seam is a trait and not a string.
///
/// # Safety
/// `locators` and `names` must each point to `count` valid
/// NUL-terminated UTF-8 strings that outlive the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_file_dialog_result(
    dialog: u64,
    locators: *const *const std::os::raw::c_char,
    names: *const *const std::os::raw::c_char,
    count: usize,
) {
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
    {
        let files = unsafe { register_picked(locators, names, count) };
        file_dialog_resolved(dialog, files);
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "android")))]
    {
        let _ = (dialog, locators, names, count);
        panic!(
            "kaya: kaya_emit_file_dialog_result is the interpreter platforms' \
             entry — this host's backend answers on its own sink"
        );
    }
}

/// ONE REPRESENTATION, as C sees it: the kind names which arm, and
/// exactly the fields that arm uses are read. `text` carries text and
/// html; `id` plus `bytes`/`len` carry a custom format; `bytes`/`len`
/// alone carry an image; `locators`/`names`/`count` carry files, in the
/// picker's own parallel-array shape so a backend that already emits a
/// dialog result emits a pasted file list with the same code.
///
/// A STRUCT AND NOT NINE PARAMETERS TWICE: the read's answer and a
/// paste carry the identical payload, and the two entries below would
/// otherwise repeat a signature wide enough to get wrong.
#[repr(C)]
pub struct KayaRepresentation {
    /// A single KAYA_CLIP_* member, never a mask.
    pub clip: u32,
    pub text: *const std::os::raw::c_char,
    pub id: *const std::os::raw::c_char,
    pub bytes: *const u8,
    pub len: usize,
    pub locators: *const *const std::os::raw::c_char,
    pub names: *const *const std::os::raw::c_char,
    pub count: usize,
}

/// Read a `KayaRepresentation` into the protocol's sum. NULL is the
/// universal no; so is `clip` zero.
///
/// # Safety
/// The struct's pointers must be valid for the kind `clip` names.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
unsafe fn representation(
    rep: *const KayaRepresentation,
) -> Option<crate::protocol::Representation> {
    use crate::protocol::Representation as R;
    if rep.is_null() {
        return None;
    }
    let rep = unsafe { &*rep };
    let cstr = |p: *const std::os::raw::c_char| -> String {
        if p.is_null() {
            String::new()
        } else {
            unsafe { std::ffi::CStr::from_ptr(p) }
                .to_string_lossy()
                .into_owned()
        }
    };
    let blob = || -> crate::protocol::Blob {
        let src = if rep.bytes.is_null() || rep.len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(rep.bytes, rep.len) }
        };
        crate::protocol::Blob(std::sync::Arc::from(src))
    };
    match rep.clip {
        0 => None,
        wire::CLIP_TEXT => Some(R::Text(cstr(rep.text))),
        wire::CLIP_HTML => Some(R::Html(cstr(rep.text))),
        wire::CLIP_IMAGE => Some(R::Image(blob())),
        wire::CLIP_CUSTOM => Some(R::Custom { id: cstr(rep.id), bytes: blob() }),
        wire::CLIP_FILES => Some(R::Files(unsafe {
            register_picked(rep.locators, rep.names, rep.count)
        })),
        other => panic!(
            "kaya: a clipboard answer names clip kind {other}, which is not a \
             single member of the clip enum"
        ),
    }
}

/// Presentation side: the privileged read's one answer. `rep` NULL, or
/// its `clip` zero, is the universal no — denied, unfocused, empty, or
/// nothing the request accepted. The request id retires here.
///
/// # Safety
/// `rep` must be NULL or a valid `KayaRepresentation` outliving the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_clipboard_result(
    request: u64,
    rep: *const KayaRepresentation,
) {
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
    {
        let clip = unsafe { representation(rep) };
        if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
            sink.send(crate::protocol::Occurrence::ClipboardResult { request, clip });
            return;
        }
        state().ring.push_record(
            ring::REC_CLIPBOARD_RESULT,
            &crate::wire::clipboard_result_body(request, clip.as_ref()),
        );
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "android")))]
    {
        let _ = (request, rep);
        panic!(
            "kaya: kaya_emit_clipboard_result is the interpreter platforms' \
             entry — this host's backend answers on its own sink"
        );
    }
}

/// Presentation side: content arriving at a widget because the user
/// pasted. `tag` is the widget's stored click tag — the same identity
/// bytes every other occurrence rides on, so a stamped row's paste
/// needs no second entry.
///
/// A PASTE THAT DELIVERED NOTHING IS NOT AN OCCURRENCE: `rep` must name
/// a representation. The empty answer belongs to the read, which asked
/// and may be refused; a paste that reached a widget already carries
/// content by definition.
///
/// # Safety
/// `tag` must point to `tag_len` valid bytes and `rep` to a valid
/// `KayaRepresentation`, both outliving the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_pasted(
    tag: *const u8,
    tag_len: usize,
    rep: *const KayaRepresentation,
) {
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
    {
        let clip = unsafe { representation(rep) }.expect(
            "kaya: kaya_emit_pasted was handed no representation — a paste \
             that delivered nothing is not an occurrence",
        );
        let bytes = if tag.is_null() || tag_len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(tag, tag_len) }
        };
        let occurrence = match crate::wire::decode_click_tag(bytes) {
            crate::protocol::Occurrence::ButtonClicked { id } => {
                crate::protocol::Occurrence::Pasted { id, clip }
            }
            crate::protocol::Occurrence::InstanceButtonClicked { node, path } => {
                crate::protocol::Occurrence::InstancePasted { node, path, clip }
            }
            other => unreachable!("kaya: a click tag decoded to {other:?}"),
        };
        if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
            sink.send(occurrence);
            return;
        }
        let clip = match &occurrence {
            crate::protocol::Occurrence::Pasted { clip, .. }
            | crate::protocol::Occurrence::InstancePasted { clip, .. } => clip,
            _ => unreachable!(),
        };
        // The tag went out as the backend holds it and comes back
        // verbatim: no re-encoding, so no chance of a different one.
        state()
            .ring
            .push_record(ring::REC_PASTED, &crate::wire::pasted_body(bytes, clip));
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "android")))]
    {
        let _ = (tag, tag_len, rep);
        panic!(
            "kaya: kaya_emit_pasted is the interpreter platforms' entry — \
             this host's backend emits on its own sink"
        );
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn kaya_emit_alert_result(alert: u64, choice: u32) {
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
    {
        alert_resolved(alert, crate::wire::alert_choice(choice));
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "android")))]
    {
        let _ = (alert, choice);
        panic!(
            "kaya: kaya_emit_alert_result is the interpreter platforms' entry —              this host's backend answers alerts on its own sink"
        );
    }
}
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
///
/// THE LAST THREE ARGUMENTS ARE THE UNDO LEDGER'S (docs/undo-plan.md
/// §3), and they ride HERE rather than on a second entry point because
/// the alternative was a `note_text_changed` call beside every emit —
/// two ABI crossings per keystroke to carry facts the backend is already
/// standing on:
///
/// - `window`: which surface's ledger this run of typing belongs to. The
///   core cannot derive it (a scene keeps no widget-to-window map — see
///   `Scene::ledgers`), and the backend, which is rendering the widget
///   inside a window, can.
/// - `focused`: whether the field this event names holds focus. An event
///   on an UNFOCUSED field closes the episode as it stands — the user is
///   no longer there. A backend that cannot tell passes 0 and the ledger
///   treats it as unfocused.
/// - `quiet`: LEDGER-QUIET, apply_quiet's spirit for the banking stream.
///   A backend that ROUTES a native undo reports it once, through
///   `kaya_note_native_undo` with the sample it took at the widget; the
///   ordinary text_changed the same undo provokes is bracketed with this
///   flag so the same change is not banked twice, in either order (the
///   platforms differ on whether the emit lands before or after the
///   sample). The occurrence still goes to the app: the field is
///   uncontrolled and the app's model must follow it. Only the BANKING
///   is suppressed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_text_changed(
    tag: *const u8,
    tag_len: usize,
    text: *const u8,
    text_len: usize,
    window: u64,
    focused: u8,
    quiet: u8,
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
    if quiet == 0 {
        bank_text_changed(window, tag, text, focused != 0);
    }
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send_text_tag(tag, text);
        return;
    }
    state()
        .ring
        .push_record(ring::REC_TEXT_CHANGED, &wire::text_changed_body(tag, text));
}

/// Show the edit to the window's undo ledger on its way past, BEFORE the
/// app hears it: the run of edits on one field between clears is one
/// entry, and the core banks it from the occurrence stream it already
/// receives rather than by reading any widget.
///
/// A stamped copy edits under its template node's tag plus a key path;
/// the ledger keys on the identity that CARRIES the text, which for the
/// copy is its own internal widget id — the same id every programmatic
/// write to it names, so `absorb_text_writes` and this agree.
fn bank_text_changed(window: u64, tag: &[u8], text: &str, focused: bool) {
    let mut scene_slot = PRESENTATION_SCENE.lock().unwrap();
    // Before the first transaction there is no scene and no widget to
    // bank against: the presentation layer is still building.
    let Some(scene) = scene_slot.as_mut() else {
        return;
    };
    let Some(field) = scene.text_field_of_tag(tag) else {
        return;
    };
    scene.note_text_changed(crate::protocol::WindowId(window), field, text, focused);
}

/// The noun path bytes an emit_menu_* call carries: the wire path
/// encoding CONTEXT_ATTACH_NODE handed the backend for a node-anchored
/// context item, or empty for a bar / live-widget activation.
///
/// # Safety
/// `noun`/`noun_len` must describe a valid byte range, or be NULL/0.
unsafe fn menu_noun<'a>(noun: *const u8, noun_len: usize) -> &'a [u8] {
    if noun.is_null() || noun_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(noun, noun_len) }
    }
}

/// Presentation side: a menu action fired — a bar/overflow click, a
/// context-menu selection, OR a shortcut. ONE occurrence, one dispatch
/// path: the shortcut is another affordance of the same item. `item` is
/// the menu item id; `noun`/`noun_len` carry the anchor copy's key path
/// (the wire path CONTEXT_ATTACH_NODE handed the backend) for a
/// node-anchored context item, or NULL/0 for a bar or live-widget
/// activation. One entry serves both routes. Do not combine with
/// kaya_run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_menu_activated(item: u64, noun: *const u8, noun_len: usize) {
    let tag = wire::menu_tag(item, unsafe { menu_noun(noun, noun_len) });
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send_menu_activated_tag(&tag);
        return;
    }
    state().ring.push_record(ring::REC_MENU_ACTIVATED, &tag);
}

/// Presentation side: a toggle item flipped; `checked` is the new state
/// (0 or 1). Same `item`/`noun` identity as kaya_emit_menu_activated.
/// Do not combine with kaya_run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_menu_toggled(
    item: u64,
    noun: *const u8,
    noun_len: usize,
    checked: u8,
) {
    let tag = wire::menu_tag(item, unsafe { menu_noun(noun, noun_len) });
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send_menu_toggled_tag(&tag, checked != 0);
        return;
    }
    state()
        .ring
        .push_record(ring::REC_MENU_TOGGLED, &wire::toggled_body(&tag, checked != 0));
}

/// Presentation side: a radio group's selected option changed;
/// `index` is the new 0-based option index (integral). Same
/// `item`/`noun` identity as kaya_emit_menu_activated, keyed by the
/// group. Do not combine with kaya_run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_menu_value_changed(
    item: u64,
    noun: *const u8,
    noun_len: usize,
    index: f64,
) {
    let tag = wire::menu_tag(item, unsafe { menu_noun(noun, noun_len) });
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send_menu_value_tag(&tag, index);
        return;
    }
    state()
        .ring
        .push_record(ring::REC_MENU_VALUE_CHANGED, &wire::value_changed_body(&tag, index));
}

// --- The undo tier's presentation entries (docs/undo-plan.md §3) -------
//
// The ledger lives in the presentation scene, so every entry here takes
// the same lock the pump takes and none of them blocks on anything else.
// Exported on every platform (one header, one export surface — the
// kaya_emit_alert_result pattern) and answerable where a guest-language
// presentation layer exists.

/// Apply-ops the core produced OUTSIDE a transaction: an undo's inverse
/// or an episode's coarse restore. Nothing else in the protocol makes
/// ops without a transaction, and the pump is the only way out, so they
/// wait here for the next batch and lead it — the scene mutation that
/// made them happened before whatever that batch applies, under the same
/// lock, so leading is the order the scene actually saw.
static PRESENTATION_PENDING: Mutex<Vec<crate::protocol::ApplyOp>> = Mutex::new(Vec::new());

/// Queue an undo's ops for the pump and wake it.
///
/// THE WAKE IS NOT OPTIONAL. The pump blocks on the transaction channel,
/// and an app that registers no `on_undone` handler sends no transaction
/// in response — so without a nudge the inverse would sit here until the
/// user did something else, which is the silent class this milestone
/// exists to close. An empty transaction is the nudge; `kaya_next_commands`
/// treats an empty resolved batch as "nothing to say yet", not shutdown.
///
/// Called with the scene lock HELD, so the queue's order is the order the
/// scene was mutated in.
fn queue_undo_ops(pending: &mut Vec<crate::protocol::ApplyOp>, ops: Vec<crate::protocol::ApplyOp>) {
    if ops.is_empty() {
        return;
    }
    pending.extend(ops);
    let _ = state().tx_tx.send(Vec::new());
}

/// Send an `undone` / `redone` occurrence the way every other
/// presentation-side emission goes out: the runtime-selected sink when
/// one is installed, the byte ring otherwise.
fn send_undo_occurrence(occurrence: crate::protocol::Occurrence) {
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send(occurrence);
        return;
    }
    match occurrence {
        crate::protocol::Occurrence::Undone { window, label, delta } => state()
            .ring
            .push_record(ring::REC_UNDONE, &wire::undo_body(window, &label, &delta)),
        crate::protocol::Occurrence::Redone { window, label, delta } => state()
            .ring
            .push_record(ring::REC_REDONE, &wire::undo_body(window, &label, &delta)),
        _ => unreachable!("kaya: the undo tier emits undone/redone and nothing else"),
    }
}

/// The shared body of `kaya_undo` / `kaya_redo` / a walk that exhausted
/// itself: mutate the ledger, put the ops in front of the pump, then
/// tell the app what came back.
///
/// THE SCENE LOCK SPANS THE FIRST TWO. The pump takes the same lock to
/// resolve a transaction, so a transaction the guest sent WHILE this ran
/// would otherwise be resolved against the restored scene and reach the
/// backend AHEAD of the restore it came after — the app's newer write
/// overwritten by an older value. Locking across both puts the ops in
/// the queue before any batch can form.
///
/// The occurrence goes out afterwards, lock released: it is what makes
/// the app apply its own transaction, and that transaction must not
/// overtake the restore it is reacting to (the ops are already queued,
/// and a queued op leads the next batch).
fn with_undo_scene(
    f: impl FnOnce(&mut Scene) -> Option<(Vec<crate::protocol::ApplyOp>, crate::protocol::Occurrence)>,
) {
    let mut scene_slot = PRESENTATION_SCENE.lock().unwrap();
    // No scene means no transaction has been applied: nothing is undoable.
    let Some(scene) = scene_slot.as_mut() else {
        return;
    };
    let Some((ops, occurrence)) = f(scene) else {
        return;
    };
    queue_undo_ops(&mut PRESENTATION_PENDING.lock().unwrap(), ops);
    drop(scene_slot);
    send_undo_occurrence(occurrence);
}

/// Where an undo would go RIGHT NOW: 0 nowhere (the command is inert and
/// reads disabled), 1 the focused field's own stack, 2 the core's ledger.
///
/// `focused` is the widget the backend has focus on, 0 for none;
/// `can_undo` is A4's one named query, answered in the platform's own
/// vocabulary (CanUndo / canUndo / undoManager.canUndo). Enablement and
/// activation are the SAME call, so the two cannot drift.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_undo_route(window: u64, focused: u64, can_undo: u8) -> u32 {
    undo_route_code(window, focused, can_undo, false)
}

/// Redo's twin, with the field's `canRedo` in place of `canUndo`.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_redo_route(window: u64, focused: u64, can_redo: u8) -> u32 {
    undo_route_code(window, focused, can_redo, true)
}

fn undo_route_code(window: u64, focused: u64, can: u8, redo: bool) -> u32 {
    let mut scene_slot = PRESENTATION_SCENE.lock().unwrap();
    // No scene means no transaction has been applied: nothing can have
    // been done, so nothing can be undone.
    let Some(scene) = scene_slot.as_mut() else {
        return 0;
    };
    let window = crate::protocol::WindowId(window);
    let focused = (focused != 0).then_some(crate::protocol::WidgetId(focused));
    let route = if redo {
        scene.route_redo(window, focused, can != 0)
    } else {
        scene.route_undo(window, focused, can != 0)
    };
    match route {
        crate::scene::UndoRoute::Nothing => 0,
        crate::scene::UndoRoute::Native => 1,
        crate::scene::UndoRoute::Core => 2,
    }
}

/// The core tier answers: apply the newest ledger entry's inverse and
/// emit `undone` carrying the label and the whole restored state. The
/// ops reach the backend through the pump like any other apply.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_undo(window: u64) {
    with_undo_scene(|scene| scene.undo(crate::protocol::WindowId(window)));
}

/// Redo's twin: the forward delta, computed at apply beside the inverse,
/// so nothing is re-run and nothing is re-derived.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_redo(window: u64) {
    with_undo_scene(|scene| scene.redo(crate::protocol::WindowId(window)));
}

/// THE ONE REPORT OF A ROUTED NATIVE UNDO (docs/undo-plan.md §3): the
/// field the backend sent the platform's own undo to, the text the walk
/// landed on, and whether that field can still undo. The core walks its
/// frontier episode from those three facts.
///
/// The ordinary text_changed the same undo provokes carries the
/// ledger-quiet flag on `kaya_emit_text_changed`, so this change is
/// banked once no matter which of the two the platform delivers first.
///
/// Usually there is nothing to apply — the walk already happened in the
/// widget. The exception is a platform that exhausted its stack short of
/// the episode's before-image, which falls back to the coarse restore
/// and comes back with ops and an occurrence like any core-tier undo.
///
/// # Safety
/// `text`/`text_len` must describe a valid UTF-8 byte range, or be
/// NULL/0 for the empty string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_note_native_undo(
    window: u64,
    field: u64,
    text: *const u8,
    text_len: usize,
    can_undo: u8,
) {
    let text = if text_len == 0 {
        ""
    } else {
        assert!(!text.is_null(), "kaya: null text with nonzero length");
        std::str::from_utf8(unsafe { std::slice::from_raw_parts(text, text_len) })
            .expect("kaya: field text must be UTF-8")
    };
    with_undo_scene(|scene| {
        scene.note_native_undo(
            crate::protocol::WindowId(window),
            crate::protocol::WidgetId(field),
            text,
            can_undo != 0,
        )
    });
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
    // 0 MEANS SHUTDOWN TO EVERY PUMP, so a batch that resolved to
    // nothing must not be returned: keep waiting instead. The undo
    // tier's wake is an empty transaction whose ops are already queued
    // (queue_undo_ops), and a transaction whose ops all cancelled out is
    // the same shape — neither is the core going away.
    let ops = loop {
        let Ok(tx) = rx_slot.as_ref().unwrap().recv() else {
            return 0;
        };
        let mut scene_slot = PRESENTATION_SCENE.lock().unwrap();
        // The queue leads: those ops were made under this same lock,
        // before this transaction could be resolved.
        let mut ops = std::mem::take(&mut *PRESENTATION_PENDING.lock().unwrap());
        ops.extend(scene_slot.as_mut().unwrap().apply(tx));
        if !ops.is_empty() {
            break ops;
        }
    };
    let mut writer = wire::Writer::new();
    for op in &ops {
        writer.apply_op(op);
    }
    // Publish the batch's blob table (replacing the previous batch's):
    // the records in `buf` reference these bytes by 1-based index
    // through kaya_blob_data, valid until the next call here. Blob
    // payloads never enter `buf`, so the 64 KiB pump budget is spent
    // on records alone.
    blobs().lock().unwrap().out = std::mem::take(&mut writer.blobs);
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
    /// The blob tables' lifecycle, in one serial test (the tables are
    /// process-global): registration fills pending; the submit
    /// boundary drains it, referenced or not (ownership transfers, an
    /// unreferenced blob cannot leak); the out table serves the
    /// current batch by 1-based index and a dead handle reads NULL.
    #[test]
    fn blob_tables_register_drain_and_serve() {
        let bytes = [1u8, 2, 3, 4];
        let handle = unsafe { kaya_blob_register(bytes.as_ptr(), bytes.len()) };
        assert!(handle > 0);
        assert_eq!(
            blobs().lock().unwrap().pending.get(&handle).map(|a| a.len()),
            Some(4)
        );
        // An empty submit still drains pending: registration's
        // ownership transferred at the boundary.
        unsafe { kaya_submit(std::ptr::null(), 0) };
        assert!(blobs().lock().unwrap().pending.is_empty());

        // The out table serves the current batch; index 0 and past-end
        // are dead handles (NULL, len 0).
        blobs().lock().unwrap().out = vec![std::sync::Arc::from(&bytes[..])];
        let mut len = 0usize;
        let p = unsafe { kaya_blob_data(1, &mut len) };
        assert!(!p.is_null());
        assert_eq!(len, 4);
        assert_eq!(unsafe { std::slice::from_raw_parts(p, len) }, &bytes);
        let dead = unsafe { kaya_blob_data(2, &mut len) };
        assert!(dead.is_null());
        assert_eq!(len, 0);
        let zero = unsafe { kaya_blob_data(0, &mut len) };
        assert!(zero.is_null());
        blobs().lock().unwrap().out.clear();
    }

    /// THE FUNCTION FLOOR HAS NO SIZE CAP, because the core owns the
    /// bytes it hands out.
    ///
    /// It used to copy into a caller-sized buffer, and every caller
    /// sized it 256 — so an occurrence carrying more than 208 bytes of
    /// payload ABORTED THE PROCESS from inside an extern "C" frame,
    /// uncatchable by any guest (measured 2026-08-02: 200 bytes of
    /// pasted text passed, 240 aborted). A pasted paragraph does that
    /// and an html clip does it every time, so the clipboard is where a
    /// latent limit became a routine one.
    ///
    /// 8 KiB is not a new cap. It is thirty-two times the buffer every
    /// caller passed, which is the distance that matters: under the old
    /// shape this test could not have run at all.
    #[test]
    fn the_function_floor_hands_out_a_record_of_any_size() {
        let text = "x".repeat(8 * 1024);
        let clip = crate::protocol::Representation::Text(text.clone());
        let tag = crate::wire::click_tag(5, &[]);
        let body = crate::wire::pasted_body(&tag, &clip);
        state().ring.push_record(ring::REC_PASTED, &body);

        let mut record: *const u8 = std::ptr::null();
        let size = unsafe { kaya_next_occurrence(&mut record) };
        assert_eq!(size, wire::HEADER_SIZE + body.len());
        assert!(!record.is_null());

        // The whole record arrives, header included, and the text in it
        // is the text that went in — not a prefix that happened to fit.
        let bytes = unsafe { std::slice::from_raw_parts(record, size) };
        assert_eq!(
            u32::from_le_bytes(bytes[0..4].try_into().unwrap()) as usize,
            size
        );
        assert_eq!(
            u16::from_le_bytes(bytes[4..6].try_into().unwrap()),
            ring::REC_PASTED
        );
        assert!(
            bytes.ends_with(text.as_bytes()),
            "the record was truncated: {size} bytes for {} of text",
            text.len()
        );
    }

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
            ("widget_command", KAYA_TX_WIDGET_COMMAND),
            ("set_window_prop", KAYA_TX_SET_WINDOW_PROP),
            ("create_window", KAYA_TX_CREATE_WINDOW),
            ("destroy_window", KAYA_TX_DESTROY_WINDOW),
            ("show_alert", KAYA_TX_SHOW_ALERT),
            ("push_entry", KAYA_TX_PUSH_ENTRY),
            ("pop_entry", KAYA_TX_POP_ENTRY),
            ("set_entry_prop", KAYA_TX_SET_ENTRY_PROP),
            ("add_section", KAYA_TX_ADD_SECTION),
            ("select_section", KAYA_TX_SELECT_SECTION),
            ("set_section_prop", KAYA_TX_SET_SECTION_PROP),
            ("menu_item_create", KAYA_TX_MENU_ITEM_CREATE),
            ("menu_item_append", KAYA_TX_MENU_ITEM_APPEND),
            ("menubar_append", KAYA_TX_MENUBAR_APPEND),
            ("context_attach", KAYA_TX_CONTEXT_ATTACH),
            ("context_attach_node", KAYA_TX_CONTEXT_ATTACH_NODE),
            ("set_menu_prop", KAYA_TX_SET_MENU_PROP),
            ("show_file_dialog", KAYA_TX_SHOW_FILE_DIALOG),
            ("copy", KAYA_TX_COPY),
            ("read_clipboard", KAYA_TX_READ_CLIPBOARD),
            ("undo_group", KAYA_TX_UNDO_GROUP),
        ];
        let apply = [
            ("create", KAYA_APPLY_CREATE),
            ("set_prop", KAYA_APPLY_SET_PROP),
            ("add_child", KAYA_APPLY_ADD_CHILD),
            ("mount", KAYA_APPLY_MOUNT),
            ("destroy", KAYA_APPLY_DESTROY),
            ("move_child", KAYA_APPLY_MOVE_CHILD),
            ("command", KAYA_APPLY_COMMAND),
            ("set_window_prop", KAYA_APPLY_SET_WINDOW_PROP),
            ("create_window", KAYA_APPLY_CREATE_WINDOW),
            ("destroy_window", KAYA_APPLY_DESTROY_WINDOW),
            ("present_alert", KAYA_APPLY_PRESENT_ALERT),
            ("push_entry", KAYA_APPLY_PUSH_ENTRY),
            ("pop_entry", KAYA_APPLY_POP_ENTRY),
            ("set_entry_prop", KAYA_APPLY_SET_ENTRY_PROP),
            ("add_section", KAYA_APPLY_ADD_SECTION),
            ("select_section", KAYA_APPLY_SELECT_SECTION),
            ("set_section_prop", KAYA_APPLY_SET_SECTION_PROP),
            ("menu_item_create", KAYA_APPLY_MENU_ITEM_CREATE),
            ("menu_item_append", KAYA_APPLY_MENU_ITEM_APPEND),
            ("menubar_append", KAYA_APPLY_MENUBAR_APPEND),
            ("context_attach", KAYA_APPLY_CONTEXT_ATTACH),
            ("context_attach_node", KAYA_APPLY_CONTEXT_ATTACH_NODE),
            ("set_menu_prop", KAYA_APPLY_SET_MENU_PROP),
            ("present_file_dialog", KAYA_APPLY_PRESENT_FILE_DIALOG),
            ("copy", KAYA_APPLY_COPY),
            ("read_clipboard", KAYA_APPLY_READ_CLIPBOARD),
            ("clear_undo", KAYA_APPLY_CLEAR_UNDO),
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
