//! The C ABI.
//!
//! Two tiers over ONE ring, one consumer whichever style it uses.
//! Functions are the portable floor: `kaya_next_occurrence` hands out one
//! complete occurrence record — the same bytes the ring carries — and
//! asks no memory order of anybody. Languages with real atomics (Go,
//! JVM, C#) may read the ring directly instead.
//!
//! Direct-access contract (single consumer):
//!   1. acquire-load *tail; if *head == *tail the ring is empty; call
//!      kaya_wait_occurrences() to block until it is not (returns false
//!      on shutdown).
//!   2. cast data[*head & (capacity-1)] to KayaRecordHeader (declared in
//!      kaya.h). Skip kind 0 (padding). The payload follows the header;
//!      per-kind record structs are also declared in the header.
//!   3. release-store *head advanced by header.size.
//!
//! The other direction is transactions: the guest packs a buffer of
//! records — same framing as the ring, layouts documented on the
//! KAYA_TX_* constants — and one kaya_submit call commits it atomically.
//! No second ring: the write path asks no atomics of any language.

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
/// arrives because the user pasted.
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
/// A column header was clicked: { u64 id; u32 path_len; u32 column;
/// path_len values } — identity as in button_clicked, `column` the
/// 0-based index in the declared order. A request; the guest sorts
/// (docs/tables-plan.md).
pub const KAYA_OCCURRENCE_SORT_REQUESTED: u16 = 19;
/// THE CANVAS'S TWO ASKS (docs/canvas-plan.md §3.2.1): { u64 id; u32
/// path_len; u32 reserved; path_len values; width; height } for a redraw,
/// and the same with a third f64 value — the frame's time in seconds —
/// for a tick. Identity as in button_clicked.
pub const KAYA_OCCURRENCE_DRAW_REQUESTED: u16 = 20;
pub const KAYA_OCCURRENCE_TICK: u16 = 21;
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
        && KAYA_OCCURRENCE_SORT_REQUESTED == ring::REC_SORT_REQUESTED
        && KAYA_OCCURRENCE_DRAW_REQUESTED == ring::REC_DRAW_REQUESTED
        && KAYA_OCCURRENCE_TICK == ring::REC_TICK
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

/// The three text-range records (docs/ranges-plan.md). Bodies:
/// HIGHLIGHT_RANGES { u64 widget; u32 count; u32 reserved; Values of
/// 2*count I64 offsets — start then end }; SELECT_RANGE and
/// REVEAL_RANGE { u64 widget; u64 start; u64 end }.
///
/// THE OFFSETS ARE UTF-8 BYTE OFFSETS into the widget's current text, on
/// this channel and in every binding. Both ends must be inside the text
/// and on a code-point boundary; the core refuses otherwise, naming the
/// character it splits. An end inside a GRAPHEME cluster is legal — the
/// platforms disagree about what a grapheme is — and a platform may
/// widen what it paints to the whole cluster.
pub const KAYA_TX_HIGHLIGHT_RANGES: u16 = 38;
pub const KAYA_TX_SELECT_RANGE: u16 = 39;
pub const KAYA_TX_REVEAL_RANGE: u16 = 40;
const _: () = assert!(
    KAYA_TX_HIGHLIGHT_RANGES == wire::TX_HIGHLIGHT_RANGES
        && KAYA_TX_SELECT_RANGE == wire::TX_SELECT_RANGE
        && KAYA_TX_REVEAL_RANGE == wire::TX_REVEAL_RANGE
);

/// Request the platform's save dialog over a live window (0 = primary).
/// Body: { u64 window; u64 dialog; Str suggested_name; Values filters —
/// the picker's alternating label/extensions pairs }.
///
/// THE PICKER'S GRAMMAR AND THE PICKER'S ANSWER: dialog ids come out of
/// the same guest-chosen space, one dialog of either kind may be live per
/// process, and the result arrives as a FILE_DIALOG_RESULT occurrence
/// carrying one file (or none, for cancel) whose id retires there.
///
/// THE HANDLE IT ANSWERS WITH OPENS WITH CREATE (docs/save-plan.md D1):
/// the open succeeds on every platform and FILE_MODE_WRITE yields an
/// empty file. There is no FILE_MODE_CREATE, deliberately — creation
/// belongs to the destination the dialog promised, not to the caller.
pub const KAYA_TX_SHOW_SAVE_DIALOG: u16 = 41;
const _: () = assert!(KAYA_TX_SHOW_SAVE_DIALOG == wire::TX_SHOW_SAVE_DIALOG);
pub const KAYA_TX_SET_BRAND_ACCENT: u16 = 42;
const _: () = assert!(KAYA_TX_SET_BRAND_ACCENT == wire::TX_SET_BRAND_ACCENT);
pub const KAYA_TX_SET_BRAND_TYPEFACE: u16 = 43;
const _: () = assert!(KAYA_TX_SET_BRAND_TYPEFACE == wire::TX_SET_BRAND_TYPEFACE);
/// The app's declared identity (docs/app-identity-plan.md): a name and
/// the bytes of the picture that stands for it, on the typeface's
/// mask-plus-always-written-slot convention.
pub const KAYA_TX_SET_APP_IDENTITY: u16 = 44;
const _: () = assert!(KAYA_TX_SET_APP_IDENTITY == wire::TX_SET_APP_IDENTITY);
/// The column header bar on a For's container: { u64 widget; u32 sorted;
/// u32 direction; u32 count; u32 reserved; count Str values } — titles
/// plus the sort indicator, one atomic declaration (docs/tables-plan.md).
pub const KAYA_TX_SET_COLUMN_HEADERS: u16 = 45;
const _: () = assert!(KAYA_TX_SET_COLUMN_HEADERS == wire::TX_SET_COLUMN_HEADERS);
/// The whole drawing on a canvas, one atomic declaration
/// (docs/canvas-plan.md §3.1).
pub const KAYA_TX_SET_DRAWING: u16 = 46;
const _: () = assert!(KAYA_TX_SET_DRAWING == wire::TX_SET_DRAWING);
/// What a canvas does with a track that is not its viewbox
/// (docs/canvas-plan.md §3.2.1): { u64 widget_id; u32 policy; u32 pad }.
/// Never sent for `scale`, which is what a canvas with no record is.
pub const KAYA_TX_SET_SIZE_POLICY: u16 = 47;
const _: () = assert!(KAYA_TX_SET_SIZE_POLICY == wire::TX_SET_SIZE_POLICY);
/// `sorted`'s no-column sentinel, and `direction`'s two values.
pub const KAYA_SORT_NONE: u32 = u32::MAX;
pub const KAYA_SORT_ASC: u32 = 0;
pub const KAYA_SORT_DESC: u32 = 1;
const _: () = assert!(
    KAYA_SORT_NONE == wire::SORT_NONE
        && KAYA_SORT_ASC == wire::SORT_ASC
        && KAYA_SORT_DESC == wire::SORT_DESC
);

/// The protocol fingerprint this core was built from. Bindings carry the
/// same value baked in at generation and assert agreement at load, so a
/// stale library and a fresh guest fail loudly at startup instead of
/// decoding each other's bytes as garbage.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_spec_hash() -> u64 {
    crate::spec::hash()
}

/// The identity of the SOURCES this core was compiled from, readable
/// without loading or running anything:
/// `tools/build-id.sh --verify libkaya.so`. The spec hash above answers
/// "do the guest and the library agree on the protocol"; this answers
/// "is the file I am about to test built from the code I just edited".
///
/// Fixed-size and `no_mangle` on purpose: an exported static of known
/// length survives linking into every artifact shape (cdylib, staticlib,
/// dll) and lands in rodata as findable bytes.
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
/// Platform-static per build: the phones' systems own surface geometry,
/// so KAYA_CAP_AUX_WINDOWS is unset there and create_window is a
/// deterministic scene error (DESIGN.md, Presentation contexts).
///
/// A LITERAL, because cbindgen turns this line into the header's
/// `#define` and a `#define` naming a Rust path is a header no C
/// compiler reads. The static assert under `kaya_capabilities` is what
/// keeps the literal honest.
pub const KAYA_CAP_AUX_WINDOWS: u64 = 1;

/// The capability word, which is the SCENE CORE'S const and not a second
/// copy of its predicate: the wall that refuses `create_window` tests the
/// same bits this hands out (crates/kaya/src/scene.rs).
#[unsafe(no_mangle)]
pub extern "C" fn kaya_capabilities() -> u64 {
    crate::scene::CAPABILITIES
}

const _: () = assert!(
    KAYA_CAP_AUX_WINDOWS == crate::scene::CAP_AUX_WINDOWS,
    "kaya: the header's KAYA_CAP_AUX_WINDOWS and the scene core's bit are different numbers"
);

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
/// doctrine never will.
pub const KAYA_APPLY_CLEAR_UNDO: u16 = 27;

/// The three text-range records, apply side. Same layouts as their tx
/// twins, and NOT the same unit: these offsets are already in this
/// build's backend unit (UTF-16 code units everywhere but GTK, which
/// counts code points), converted by the core against the text it
/// validated them against. A backend does no Unicode arithmetic here.
pub const KAYA_APPLY_HIGHLIGHT_RANGES: u16 = 28;
pub const KAYA_APPLY_SELECT_RANGE: u16 = 29;
pub const KAYA_APPLY_REVEAL_RANGE: u16 = 30;
const _: () = assert!(
    KAYA_APPLY_HIGHLIGHT_RANGES == wire::APPLY_HIGHLIGHT_RANGES
        && KAYA_APPLY_SELECT_RANGE == wire::APPLY_SELECT_RANGE
        && KAYA_APPLY_REVEAL_RANGE == wire::APPLY_REVEAL_RANGE
);

/// Present the platform's real save dialog (SHOW_SAVE_DIALOG, already
/// validated by the core). Answered exactly once with
/// kaya_emit_save_dialog_result: ONE locator, or a null one for cancel.
pub const KAYA_APPLY_PRESENT_SAVE_DIALOG: u16 = 31;
const _: () = assert!(KAYA_APPLY_PRESENT_SAVE_DIALOG == wire::APPLY_PRESENT_SAVE_DIALOG);
pub const KAYA_APPLY_SET_BRAND: u16 = 32;
const _: () = assert!(KAYA_APPLY_SET_BRAND == wire::APPLY_SET_BRAND);
pub const KAYA_APPLY_SET_TYPEFACE: u16 = 33;
const _: () = assert!(KAYA_APPLY_SET_TYPEFACE == wire::APPLY_SET_TYPEFACE);
pub const KAYA_APPLY_SET_APP_IDENTITY: u16 = 34;
const _: () = assert!(KAYA_APPLY_SET_APP_IDENTITY == wire::APPLY_SET_APP_IDENTITY);
/// The header bar with the core-minted sort tag after the titles
/// ({ u32 tag_len } in the reserved slot; see the spec record) — the
/// backend hands the tag to kaya_emit_sort_requested verbatim.
pub const KAYA_APPLY_SET_COLUMN_HEADERS: u16 = 35;
const _: () = assert!(KAYA_APPLY_SET_COLUMN_HEADERS == wire::APPLY_SET_COLUMN_HEADERS);
/// The RASTER a canvas's declaration produced: premultiplied RGBA8
/// device pixels the backend blits (docs/canvas-plan.md §1.1).
pub const KAYA_APPLY_SET_DRAWING: u16 = 36;
const _: () = assert!(KAYA_APPLY_SET_DRAWING == wire::APPLY_SET_DRAWING);
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
pub const KAYA_KIND_CANVAS: u32 = 15;
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
        && KAYA_KIND_CANVAS == wire::KIND_CANVAS
);
// Completeness, not just agreement: a value pin cannot see a FORGOTTEN
// export (docs/traps.md). KIND_PROGRESS shipped to every generated wire
// file while kaya.h silently lacked it, and the Swift typecheck was
// again the first to notice (2026-07-22). A new spec kind trips this
// count and walks you here.
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
        kinds == 15,
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
/// scalar slot; the root domain-checks it. A LITERAL like every sibling
/// above — cbindgen evaluates no paths, so `= wire::X` is silently
/// omitted from kaya.h.
pub const KAYA_PROP_ACCEPTS: u32 = 15;
/// Semantic emphasis (docs/styling-plan.md D4): destructive/prominent
/// on buttons, heading on labels — what a widget MEANS, never how it
/// looks. The variant values are the KAYA_ROLE_* block below.
pub const KAYA_PROP_ROLE: u32 = 16;
/// A container's own padding (docs/styling-plan.md D3, one level down
/// from the window inset): DIP between its bounds and its children,
/// uniform all sides. Layout, carried by the spacing kinds.
pub const KAYA_PROP_INSET: u32 = 17;

/// Window properties (spec::WINDOW_PROPS): their own namespace —
/// windows are not widgets. Window 0 is the primary surface.
pub const KAYA_WPROP_TITLE: u32 = 1;
pub const KAYA_WPROP_WIDTH: u32 = 2;
pub const KAYA_WPROP_HEIGHT: u32 = 3;
pub const KAYA_WPROP_VETO_CLOSE: u32 = 4;

/// The window prop declaring the pane CEILING for this window's entry
/// stack (DESIGN.md, Adaptive panes).
pub const KAYA_WPROP_PANES: u32 = 6;
/// The panes enum's values (spec enum "panes"): the counts themselves.
pub const KAYA_PANES_ONE: u32 = 1;
pub const KAYA_PANES_TWO: u32 = 2;
pub const KAYA_PANES_THREE: u32 = 3;

/// The window prop saying this surface holds UNSAVED WORK
/// (docs/dirty-plan.md D1). State, not chrome: each backend spells its
/// own platform's affordance and the app's title string is untouched.
pub const KAYA_WPROP_DIRTY: u32 = 7;
/// The window content inset, in layout units — LAYOUT, not appearance
/// (docs/styling-plan.md D3). Kaya's own padding inside the mounted
/// root; defaults to 16, and 0 is full bleed. Platform safe areas are
/// not part of it and are not removed by it.
pub const KAYA_WPROP_INSET: u32 = 8;

/// Navigation-entry properties (spec::ENTRY_PROPS): their own typed
/// table (DESIGN.md, Navigation). `intercept_back` is the close-veto
/// class transplanted to POP.
pub const KAYA_EPROP_TITLE: u32 = 1;
pub const KAYA_EPROP_INTERCEPT_BACK: u32 = 2;

/// Section properties (spec::SECTION_PROPS) — the third typed surface
/// table (DESIGN.md, Sections). `icon` rides the blob channel.
pub const KAYA_SPROP_TITLE: u32 = 1;
pub const KAYA_SPROP_ICON: u32 = 2;
/// The switcher item's SEMANTIC ICON NAME (docs/styling-plan.md D6):
/// a value of the KAYA_SYMBOL_* block below, never bytes.
pub const KAYA_SPROP_SYMBOL: u32 = 3;

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
// Completeness, not just agreement (docs/traps.md): a new menu_kind
// trips this count and walks you to export its KAYA_MENU_KIND_*
// constant, extend the pin, and bump the count.
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
/// The item's SEMANTIC ICON NAME (docs/styling-plan.md D6): a value of
/// the KAYA_SYMBOL_* block below. Const-only, beside KAYA_MPROP_ICON —
/// a name for the standard concepts, a blob for app-specific art.
pub const KAYA_MPROP_SYMBOL: u32 = 9;
const _: () = assert!(
    KAYA_MPROP_LABEL == wire::MPROP_LABEL
        && KAYA_MPROP_ENABLED == wire::MPROP_ENABLED
        && KAYA_MPROP_CHECKED == wire::MPROP_CHECKED
        && KAYA_MPROP_VALUE == wire::MPROP_VALUE
        && KAYA_MPROP_ICON == wire::MPROP_ICON
        && KAYA_MPROP_PRIMARY == wire::MPROP_PRIMARY
        && KAYA_MPROP_SHORTCUT == wire::MPROP_SHORTCUT
        && KAYA_MPROP_ROLE == wire::MPROP_ROLE
        && KAYA_MPROP_SYMBOL == wire::MPROP_SYMBOL
);
// Completeness for the menu-prop exports (docs/traps.md): a new
// MENU_PROPS row trips this count.
const _: () = assert!(
    crate::spec::MENU_PROPS.len() == 9,
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
        && KAYA_SPROP_SYMBOL == wire::SPROP_SYMBOL
        && KAYA_WPROP_SECTIONS_PRESENTATION == wire::WPROP_SECTIONS_PRESENTATION
        && KAYA_SECTIONS_PRESENTATION_AUTO == wire::SECTIONS_PRESENTATION_AUTO
        && KAYA_SECTIONS_PRESENTATION_BAR == wire::SECTIONS_PRESENTATION_BAR
        && KAYA_SECTIONS_PRESENTATION_SIDEBAR == wire::SECTIONS_PRESENTATION_SIDEBAR
);
// Completeness for the occurrence exports (docs/traps.md): the
// section_selected record shipped to every generated wire file while
// KAYA_OCCURRENCE_* silently lacked it. A new spec occurrence trips this
// count and walks you here.
const _: () = assert!(
    crate::spec::SPEC.occurrence.len() == 21,
    "spec occurrences grew: export the new KAYA_OCCURRENCE_* above, extend the pin, and \
     bump this count"
);
const _: () = assert!(
    crate::spec::SECTION_PROPS.len() == 3,
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
        && KAYA_PROP_ROLE == wire::PROP_ROLE
        && KAYA_PROP_INSET == wire::PROP_INSET
        && KAYA_WPROP_TITLE == wire::WPROP_TITLE
        && KAYA_WPROP_WIDTH == wire::WPROP_WIDTH
        && KAYA_WPROP_HEIGHT == wire::WPROP_HEIGHT
        && KAYA_WPROP_VETO_CLOSE == wire::WPROP_VETO_CLOSE
        && KAYA_WPROP_PANES == wire::WPROP_PANES
        && KAYA_PANES_ONE == wire::PANES_ONE
        && KAYA_PANES_TWO == wire::PANES_TWO
        && KAYA_PANES_THREE == wire::PANES_THREE
        && KAYA_WPROP_DIRTY == wire::WPROP_DIRTY
        && KAYA_WPROP_INSET == wire::WPROP_INSET
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

/// THE CANVAS VOCABULARIES (docs/canvas-plan.md §3.3, §3.4), for the C
/// floor, which writes the op stream out as the array it is. All five
/// ride the wire as I64 inside the op stream, so they are exported at
/// that width rather than as u32.
pub const KAYA_DRAW_MOVE_TO: i64 = 1;
pub const KAYA_DRAW_LINE_TO: i64 = 2;
pub const KAYA_DRAW_CLOSE: i64 = 3;
pub const KAYA_DRAW_STROKE: i64 = 4;
pub const KAYA_DRAW_FILL: i64 = 5;
pub const KAYA_DRAW_FONT: i64 = 6;
pub const KAYA_DRAW_TEXT: i64 = 7;
pub const KAYA_PAINT_SERIES: i64 = 1;
pub const KAYA_PAINT_SERIES_FILL: i64 = 2;
pub const KAYA_PAINT_GRID: i64 = 3;
pub const KAYA_PAINT_AXIS: i64 = 4;
pub const KAYA_PAINT_GROUND: i64 = 5;
pub const KAYA_FILL_NONZERO: i64 = 0;
pub const KAYA_FILL_EVEN_ODD: i64 = 1;
pub const KAYA_TEXT_ALIGN_START: i64 = 0;
pub const KAYA_TEXT_ALIGN_MIDDLE: i64 = 1;
pub const KAYA_TEXT_ALIGN_END: i64 = 2;
pub const KAYA_TEXT_BASELINE_ALPHABETIC: i64 = 0;
pub const KAYA_TEXT_BASELINE_MIDDLE: i64 = 1;
pub const KAYA_TEXT_BASELINE_TOP: i64 = 2;
pub const KAYA_TEXT_BASELINE_BOTTOM: i64 = 3;
const _: () = assert!(
    KAYA_DRAW_MOVE_TO == wire::DRAW_MOVE_TO
        && KAYA_DRAW_LINE_TO == wire::DRAW_LINE_TO
        && KAYA_DRAW_CLOSE == wire::DRAW_CLOSE
        && KAYA_DRAW_STROKE == wire::DRAW_STROKE
        && KAYA_DRAW_FILL == wire::DRAW_FILL
        && KAYA_DRAW_FONT == wire::DRAW_FONT
        && KAYA_DRAW_TEXT == wire::DRAW_TEXT
        && KAYA_PAINT_SERIES == wire::PAINT_SERIES
        && KAYA_PAINT_SERIES_FILL == wire::PAINT_SERIES_FILL
        && KAYA_PAINT_GRID == wire::PAINT_GRID
        && KAYA_PAINT_AXIS == wire::PAINT_AXIS
        && KAYA_PAINT_GROUND == wire::PAINT_GROUND
        && KAYA_FILL_NONZERO == wire::FILL_NONZERO
        && KAYA_FILL_EVEN_ODD == wire::FILL_EVEN_ODD
        && KAYA_TEXT_ALIGN_START == wire::TEXT_ALIGN_START
        && KAYA_TEXT_ALIGN_MIDDLE == wire::TEXT_ALIGN_MIDDLE
        && KAYA_TEXT_ALIGN_END == wire::TEXT_ALIGN_END
        && KAYA_TEXT_BASELINE_ALPHABETIC == wire::TEXT_BASELINE_ALPHABETIC
        && KAYA_TEXT_BASELINE_MIDDLE == wire::TEXT_BASELINE_MIDDLE
        && KAYA_TEXT_BASELINE_TOP == wire::TEXT_BASELINE_TOP
        && KAYA_TEXT_BASELINE_BOTTOM == wire::TEXT_BASELINE_BOTTOM
);

/// The role enum's values (spec enum "role"): semantic emphasis, a
/// closed set. Which variant fits which KIND is the root's
/// value-dependent check (destructive/prominent are buttons-only,
/// heading is labels-only) — one wire slot, the variants divide it.
pub const KAYA_ROLE_DESTRUCTIVE: u32 = 1;
pub const KAYA_ROLE_PROMINENT: u32 = 2;
pub const KAYA_ROLE_HEADING: u32 = 3;
const _: () = assert!(
    KAYA_ROLE_DESTRUCTIVE == wire::ROLE_DESTRUCTIVE
        && KAYA_ROLE_PROMINENT == wire::ROLE_PROMINENT
        && KAYA_ROLE_HEADING == wire::ROLE_HEADING
);

/// The SEMANTIC ICON VOCABULARY (spec enum "symbol";
/// docs/styling-plan.md D6, DESIGN.md "Icons want names, not bytes").
/// A closed set of CONCEPTS: each backend maps a value to its own
/// platform's symbol set. Both the menu-item slot (KAYA_MPROP_SYMBOL)
/// and the section slot (KAYA_SPROP_SYMBOL) take these values.
///
/// APPEND-ONLY. These numbers are wire facts in eight generated bindings
/// and every backend's glyph table; renumbering silently redraws shipped
/// menus. New concepts start at 21.
pub const KAYA_SYMBOL_ADD: u32 = 1;
pub const KAYA_SYMBOL_REMOVE: u32 = 2;
pub const KAYA_SYMBOL_DELETE: u32 = 3;
pub const KAYA_SYMBOL_EDIT: u32 = 4;
pub const KAYA_SYMBOL_DONE: u32 = 5;
pub const KAYA_SYMBOL_CLOSE: u32 = 6;
pub const KAYA_SYMBOL_SEARCH: u32 = 7;
pub const KAYA_SYMBOL_SETTINGS: u32 = 8;
pub const KAYA_SYMBOL_REFRESH: u32 = 9;
pub const KAYA_SYMBOL_INFO: u32 = 10;
pub const KAYA_SYMBOL_WARNING: u32 = 11;
pub const KAYA_SYMBOL_BACK: u32 = 12;
pub const KAYA_SYMBOL_FORWARD: u32 = 13;
pub const KAYA_SYMBOL_MORE: u32 = 14;
pub const KAYA_SYMBOL_COPY: u32 = 15;
pub const KAYA_SYMBOL_PASTE: u32 = 16;
pub const KAYA_SYMBOL_STAR: u32 = 17;
pub const KAYA_SYMBOL_LOCK: u32 = 18;
pub const KAYA_SYMBOL_PERSON: u32 = 19;
pub const KAYA_SYMBOL_HOME: u32 = 20;
const _: () = assert!(
    KAYA_SYMBOL_ADD == wire::SYMBOL_ADD
        && KAYA_SYMBOL_REMOVE == wire::SYMBOL_REMOVE
        && KAYA_SYMBOL_DELETE == wire::SYMBOL_DELETE
        && KAYA_SYMBOL_EDIT == wire::SYMBOL_EDIT
        && KAYA_SYMBOL_DONE == wire::SYMBOL_DONE
        && KAYA_SYMBOL_CLOSE == wire::SYMBOL_CLOSE
        && KAYA_SYMBOL_SEARCH == wire::SYMBOL_SEARCH
        && KAYA_SYMBOL_SETTINGS == wire::SYMBOL_SETTINGS
        && KAYA_SYMBOL_REFRESH == wire::SYMBOL_REFRESH
        && KAYA_SYMBOL_INFO == wire::SYMBOL_INFO
        && KAYA_SYMBOL_WARNING == wire::SYMBOL_WARNING
        && KAYA_SYMBOL_BACK == wire::SYMBOL_BACK
        && KAYA_SYMBOL_FORWARD == wire::SYMBOL_FORWARD
        && KAYA_SYMBOL_MORE == wire::SYMBOL_MORE
        && KAYA_SYMBOL_COPY == wire::SYMBOL_COPY
        && KAYA_SYMBOL_PASTE == wire::SYMBOL_PASTE
        && KAYA_SYMBOL_STAR == wire::SYMBOL_STAR
        && KAYA_SYMBOL_LOCK == wire::SYMBOL_LOCK
        && KAYA_SYMBOL_PERSON == wire::SYMBOL_PERSON
        && KAYA_SYMBOL_HOME == wire::SYMBOL_HOME
);
// Completeness, not just agreement (docs/traps.md): a symbol nobody
// exported is a concept the C floor and every generated header silently
// lack. A new variant trips this count and walks you here.
const _: () = {
    let variants = {
        let mut n = 0;
        let mut i = 0;
        while i < crate::spec::SPEC.enums.len() {
            if konst_eq(crate::spec::SPEC.enums[i].name, "symbol") {
                n = crate::spec::SPEC.enums[i].variants.len();
            }
            i += 1;
        }
        n
    };
    assert!(
        variants == 20,
        "the spec symbol enum grew: export the new KAYA_SYMBOL_* above, extend the pin, and \
         bump this count"
    );
};
// Completeness, not just agreement (docs/traps.md): the spacing prop
// shipped to every generated wire file while kaya.h silently lacked it.
// A new spec prop trips this count and walks you here.
const _: () = assert!(
    crate::spec::PROPS.len() == 17,
    "spec::PROPS grew: export the new KAYA_PROP_* above, extend the pin, and bump this count"
);
const _: () = assert!(
    crate::spec::WINDOW_PROPS.len() == 8,
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
        // HERE, where the one process-wide ring is born.
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
    // On Apple the SwiftUI interpreter runs its own presentation pump
    // over this same C API, so core_ends stays in place for it to take.
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

/// The occurrence ring's raw layout, for the JVM tier (jvm.rs's KayaRing
/// natives) to expose as addresses the Java side reads directly.
#[cfg(any(
    target_os = "android",
    target_os = "macos",
    target_os = "windows",
    target_os = "linux"
))]
pub(crate) fn ring_raw() -> (*mut u8, u32, *mut u32, *mut u32) {
    state().ring.raw()
}

/// The blob tables: bulk payload bytes live once, in core-owned memory,
/// and every record stream carries 8-byte handles.
///
/// - `pending` (guest -> core): kaya_blob_register copies bytes in and
///   returns a handle valid for exactly ONE submit — the next
///   kaya_submit resolves references and drains the whole table,
///   referenced or not, so an unreferenced blob cannot leak.
/// - `out` (core -> presentation pump): batch-local, 1-based indices
///   minted by the wire writer; kaya_blob_data serves the CURRENT batch
///   and the next kaya_next_commands replaces it. Fetch and decode
///   within the batch.
///
/// Reclamation is refcount: scene state holds Arc clones, so restamps
/// re-read without re-upload, and the last drop frees.
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

/// Register bulk payload bytes and get the handle the next submitted
/// transaction references them by. One copy, into core-owned memory;
/// `len` is a usize — blob size is bounded by memory, never by any wire
/// or pump buffer, because the bytes never enter a record stream. The
/// handle is consumed by the next kaya_submit, referenced or not.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_blob_register(bytes: *const u8, len: usize) -> u64 {
    let src = if bytes.is_null() || len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, len) }
    };
    pending_register(std::sync::Arc::from(src))
}

/// The pending table's insert, factored out so the ONE place a
/// guest-to-core handle is minted stays one place (`kaya_asset_blob`
/// registers bytes the core itself read).
fn pending_register(bytes: std::sync::Arc<[u8]>) -> u64 {
    let mut table = blobs().lock().unwrap();
    let handle = table.next;
    table.next += 1;
    table.pending.insert(handle, bytes);
    handle
}

/// THE ASSET TABLE, the fourth direction: a file the guest's BUILD put
/// beside the program, read by the core, held by handle until the guest
/// says it is done (docs/assets-plan.md).
///
/// It is the OCCURRENCE table's shape and not the pending table's,
/// because no boundary retires one of these: an asset handle is a thing
/// the guest holds and reads through — possibly twice, possibly never
/// redeemed into a record at all — so the release is explicit.
///
/// THE TWO REDEMPTIONS: `kaya_asset_blob` hands the same `Arc` to the
/// pending table, so a font or an icon reaches `set_app_identity` with
/// the bytes never entering the guest's heap; `kaya_asset_bytes` borrows
/// them for a guest that is itself the consumer, and each binding wraps
/// that in its own in-memory reader.
struct Assets {
    next: u64,
    live: std::collections::HashMap<u64, std::sync::Arc<[u8]>>,
}

fn assets_table() -> &'static Mutex<Assets> {
    static TABLE: OnceLock<Mutex<Assets>> = OnceLock::new();
    TABLE.get_or_init(|| Mutex::new(Assets { next: 1, live: std::collections::HashMap::new() }))
}

/// Open an asset by name and get the handle its bytes are held under.
/// `name` is a relative path under the asset root, spelled with `/`, as
/// UTF-8 of `name_len` bytes — not NUL-terminated, so every binding
/// hands its own string type's bytes without a copy through C.
///
/// ZERO IS THE MISS, and a value rather than a panic on purpose: a panic
/// inside an `extern "C"` frame is an uncatchable process abort in every
/// guest language (docs/traps.md). The BINDING raises in its own idiom,
/// carrying the sentence `kaya_asset_why_not` hands it.
///
/// READ-ONLY, STRUCTURALLY: there is no mode argument, so the
/// check-file-modes bug class cannot exist on this surface at all.
///
/// EACH CALL READS. No cache, no watch, no reload (wall 4).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_asset_open(name: *const u8, name_len: usize) -> u64 {
    let Some(name) = (unsafe { borrowed_str(name, name_len) }) else { return 0 };
    let Ok(bytes) = crate::assets::read(&name) else { return 0 };
    let mut table = assets_table().lock().unwrap();
    let handle = table.next;
    table.next += 1;
    table.live.insert(handle, std::sync::Arc::from(&bytes[..]));
    handle
}

/// An open asset's bytes. Returns the pointer and writes the length;
/// NULL for a handle already released or never minted. The pointer
/// borrows core memory and stays valid until `kaya_asset_release` —
/// copy, then release, exactly as the occurrence blob's contract says.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_asset_bytes(handle: u64, len: *mut usize) -> *const u8 {
    let table = assets_table().lock().unwrap();
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

/// An open asset's byte count, for a binding that sizes a buffer before
/// it copies. 0 for a dead handle — and an asset is never legitimately
/// 0 bytes (wall 2 refuses an empty file at the open), so 0 here means
/// the handle, never the file.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_asset_len(handle: u64) -> usize {
    assets_table().lock().unwrap().live.get(&handle).map_or(0, |arc| arc.len())
}

/// THE BLOB REDEMPTION: register this asset's bytes into the pending
/// table and get the handle a record will carry. The `Arc` is cloned,
/// not the bytes, which is what makes this a different thing from
/// `bytes()` plus `kaya_blob_register`.
///
/// The handle obeys the pending table's lifetime (wall 5): valid for
/// exactly one submit, drained whether referenced or not. 0 for a dead
/// asset handle, so a redemption of something never opened cannot
/// register empty bytes that would sail through a lowering.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_asset_blob(handle: u64) -> u64 {
    let arc = assets_table().lock().unwrap().live.get(&handle).cloned();
    match arc {
        Some(arc) => pending_register(arc),
        None => 0,
    }
}

/// Drop an open asset. Idempotent: a handle already released, or never
/// minted, is a no-op rather than an error, so a binding's finalizer
/// needs no bookkeeping of its own.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_asset_release(handle: u64) {
    assets_table().lock().unwrap().live.remove(&handle);
}

/// Why `kaya_asset_open(name)` would answer 0 — the whole sentence, in
/// UTF-8, written into `out` and truncated to `cap`; the return value is
/// the length the sentence actually has, so a caller that got a short
/// buffer can size one and ask again.
///
/// An EMPTY sentence (return 0) means the asset resolves. That is what
/// makes this total rather than a failure path.
///
/// THE PROSE IS NOT WRITTEN HERE. crates/kaya/src/assets.rs's
/// `asset_why_not` is the one author, so every binding's raise is the
/// same bytes and a scene can freeze them once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_asset_why_not(
    name: *const u8,
    name_len: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    let name = unsafe { borrowed_str(name, name_len) }.unwrap_or_default();
    let sentence = crate::assets::asset_why_not(&name);
    let bytes = sentence.as_bytes();
    if !out.is_null() && cap > 0 {
        let n = bytes.len().min(cap);
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, n) };
    }
    bytes.len()
}

/// A borrowed UTF-8 string from a pointer and a length, or None for a
/// null pointer or bytes that are not UTF-8. Not NUL-terminated: every
/// binding hands its own string type's bytes.
///
/// INVALID UTF-8 IS A MISS RATHER THAN A LOSSY CONVERSION: a lossily
/// converted name would report "no asset named <mojibake>" and send the
/// reader after the wrong thing.
unsafe fn borrowed_str(ptr: *const u8, len: usize) -> Option<String> {
    if ptr.is_null() {
        return Some(String::new());
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    std::str::from_utf8(slice).ok().map(|s| s.to_owned())
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
/// drains `pending`, a batch replaces `out` — and this one has neither,
/// so these handles are released EXPLICITLY.
///
/// THE APP NEVER SEES ONE. A binding decoding an occurrence redeems the
/// handle, copies the bytes into its own language's byte type, and
/// releases before the occurrence reaches the guest.
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
    /// lives. THREAD-LOCAL AND NOT A GLOBAL: the borrow's lifetime is
    /// stated per caller ("until your next call"), and a second thread
    /// calling would otherwise free bytes the app thread is still
    /// decoding.
    static HELD_OCCURRENCE: std::cell::RefCell<Vec<u8>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// Function-floor consumption: block until the next occurrence and hand
/// back one complete record — header included, exactly the ring's bytes.
/// Writes the borrowed pointer to `record` and returns its size, or
/// `KAYA_OCCURRENCE_SHUTDOWN` when the core has shut down, or
/// `KAYA_OCCURRENCE_WOKEN` when a background thread rang the doorbell for
/// work of the caller's own. Call from a single app thread, and do not
/// mix with direct ring access.
///
/// BOTH SENTINELS NULL THE POINTER rather than leaving it as it was: a
/// caller that forgets the WOKEN case would otherwise re-parse the
/// buffer it still held and dispatch the PREVIOUS occurrence a second
/// time, silently.
///
/// THE CORE OWNS THE BYTES, and there is no size cap. Copying into a
/// caller-sized buffer aborted the process from inside an `extern "C"`
/// frame above 208 bytes of payload (docs/traps.md); a limit on how much
/// content may reach a guest is not something kaya gets to have.
///
/// The bytes stay valid until this thread's NEXT call — copy out what you
/// keep, exactly as `kaya_blob_data` and `kaya_occurrence_blob` ask.
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
/// In the sugar languages the BINDING calls it, inside its post, and a
/// guest never names it. A C guest has no binding, so it owns its queue
/// and calls this itself.
///
/// EITHER WAY, CLOSURES DO NOT CROSS THIS ABI: all the core owes a
/// posting thread is the wake-up.
///
/// Calling it with nothing queued is harmless.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_wake() {
    state().ring.wake();
}

/// How many milliseconds the app thread has been ignoring pending
/// occurrences, or 0 when it is keeping up. The stall watchdog's reading
/// for anyone outside Rust; see crate::stall for what counts.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_stalled_ms() -> u64 {
    crate::stall::stalled_for()
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// The latched fault's sentence — the whole thing, in UTF-8, written
/// into `out` and truncated to `cap`; the return value is the length the
/// sentence actually has, so a caller that got a short buffer can size
/// one and ask again. `kaya_asset_why_not`'s shape exactly.
///
/// ZERO MEANS NO FAULT, which is what makes this a poll rather than a
/// failure path: the interpreter harnesses ask once per step, and a
/// scene whose transaction died inside `Scene::apply` then reddens
/// carrying that sentence instead of waiting out every remaining
/// expect (crates/kaya/src/fault.rs).
///
/// A PEEK, NOT A TAKE: a harness asks again after its last step, and a
/// consuming read would let that second look report a green leg.
///
/// # Safety
/// `out` must be null or valid for `cap` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_fault(out: *mut u8, cap: usize) -> usize {
    let Some(sentence) = crate::fault::latched() else {
        return 0;
    };
    let bytes = sentence.as_bytes();
    if !out.is_null() && cap > 0 {
        let n = bytes.len().min(cap);
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, n) };
    }
    bytes.len()
}

/// The harness's watch declaration (crates/kaya/src/fault.rs): the
/// SwiftUI and Compose script runners call this before their first
/// step, so a fault reddens the leg instead of ending the process.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_fault_watch() {
    crate::fault::watch();
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
// resolved apply-ops instead of calling kaya_run. Scene resolution
// happens here, core-side, so a presentation layer never grows signal
// machinery. Exclusive with kaya_run — one presentation layer per
// process.

static PRESENTATION_TX_RX: Mutex<Option<Receiver<Transaction>>> = Mutex::new(None);
static PRESENTATION_SCENE: Mutex<Option<Scene>> = Mutex::new(None);

/// The interpreter backends declare that they window rows at their host
/// init — swiftui_host::run for mac and iOS, android.rs's
/// register_present_natives for Compose — which is BEFORE the first
/// nextCommands builds the presentation scene. The declaration waits
/// here for it (docs/deferred.md, the declares-windowing entry).
static WINDOWING_DECLARED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

pub(crate) fn declare_windowing() {
    WINDOWING_DECLARED.store(true, std::sync::atomic::Ordering::SeqCst);
    if let Some(scene) = PRESENTATION_SCENE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
    {
        scene.declare_windowing();
    }
}

/// THE WINDOW'S PRESENTATION, LATCHED — the scale-and-appearance twin of
/// `WINDOWING_DECLARED` above, and dropped for exactly its reason until
/// 2026-08-27. A backend reports at its first layout (SwiftUI's
/// `KayaPresentationReporter` fires `onAppear`), which is BEFORE the
/// first nextCommands builds the presentation scene, so the report
/// reached `with_window_scene`, found no scene and returned in silence.
/// The initial raster then used `Presentation::default()` — the LIGHT
/// palette at scale 1.0 — and nothing ever corrected it, because a
/// machine already dark at launch never fires an appearance CHANGE
/// (measured, docs/traps.md).
///
/// A report is a FACT ABOUT THE WINDOW, not an event: it is recorded here
/// whether or not a scene exists, and `presentation_scene` below is born
/// at it.
static PRESENTATION_REPORTED: Mutex<Option<crate::canvas::Presentation>> = Mutex::new(None);

/// The presentation scene, built at the pre-scene facts both latches hold.
/// `kaya_next_commands` builds it lazily on the first call; the unit suite
/// reaches the same seeding here (`a_presentation_reported_before_the_scene_exists_seeds_it`).
fn presentation_scene() -> Scene {
    let mut scene = Scene::new();
    if WINDOWING_DECLARED.load(std::sync::atomic::Ordering::SeqCst) {
        scene.declare_windowing();
    }
    if let Some(p) = *PRESENTATION_REPORTED
        .lock()
        .unwrap_or_else(|e| e.into_inner())
    {
        // A scene this new holds no drawings, so this seeds the field
        // and emits nothing.
        scene.set_presentation(p);
    }
    scene
}

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
/// core-owned stack, then forwards the post-fact occurrence. cfg'd OUT
/// on the rust-native platforms like alert_resolved: their backends
/// reconcile their own scene and emit on their own core OccSink.
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
/// entry natively (post-fact). Exported on every platform — one C header,
/// one export surface — but answerable only where a guest-language
/// presentation layer exists.
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

/// Presentation side: the user switched sections through the platform's
/// own switcher (post-fact — the selection has already changed on
/// screen). Only the user's act arrives this way: a programmatic
/// select_section never echoes. Exported everywhere, answerable where a
/// presentation layer exists.
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

// The live alert slot: ONE alert per process (the platform floor). The
// scene sets it at show (apply side) and the result that frees it
// arrives on the presentation side — this singleton is the one state
// both ends share.
/// THE PICKED-FILE TABLE. Handles are integers into this map, and the map
/// holds what only the backend understands — an `NSURL`, a Java `Uri`, a
/// `StorageFile`, a path.
///
/// WHY A TABLE AND NOT THE POINTER ITSELF. Four things a raw `uintptr_t`
/// would cost: the object is refcounted, so its lifetime becomes a manual
/// protocol spelled nine times; a bogus value is undefined behaviour
/// where a bogus integer is a clean error; it is not ONE kind of pointer
/// (ObjC retain/release, a JNI reference, WinRT AddRef/Release, a
/// `char*`) and uniform semantics means the guest cannot see which; and a
/// JNI local ref is valid only on its creating thread and frame.
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

/// What the PLATFORM calls a picked file, for a backend that has to put
/// it somewhere the platform understands — a pasteboard file URL, a
/// `text/uri-list` line, a `DROPFILES` entry. A DEAD HANDLE FAILS
/// LOUDLY: entries are process-lifetime, so the only way to miss is a
/// handle never minted, which is a broken guest.
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
/// Returns 0 on success and writes `out_fd` plus `out_seekable`; returns
/// the errno-shaped failure otherwise. The open is FALLIBLE in ways the
/// pick is not: no picker on any platform lets you request write, so a
/// read-only document refuses here.
///
/// RESOLVE UNDER THE LOCK, RELEASE, THEN OPEN. Holding it across the open
/// would serialize every concurrent open and undo the parallelism the
/// guest created by spawning threads.
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

/// UNIX NO LONGER GATES THESE (docs/save-plan.md D3). The gate was
/// `cfg(all(test, unix))`, so the one test of the redemption path had
/// never run on the platform whose handle is a HANDLE and not a
/// descriptor, where `file_from_raw` takes the other arm.
#[cfg(test)]
mod picked_tests {
    use super::*;
    use crate::protocol::{PathSource, SaveDestination};
    use std::io::{Read, Seek, Write};

    /// THE CENTRAL CLAIM OF THE FILE-DIALOG DESIGN, at unit level: a
    /// handle redeems for a REAL descriptor, and the caller reads it with
    /// its own file API while the core is nowhere in the data path.
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
        // NOT `fd >= 0`: a Windows HANDLE is a pointer value, not a
        // small index — the one thing that is never a handle there is -1
        // (INVALID_HANDLE_VALUE).
        assert_ne!(fd, -1);
        assert_eq!(seekable, 1, "a regular file seeks");

        // The guest's own file API, from here on.
        let mut file = unsafe { crate::protocol::file_from_raw(fd) };
        let mut got = String::new();
        file.read_to_string(&mut got).unwrap();
        assert_eq!(got, "picked bytes");

        // REDEEMABLE MORE THAN ONCE — that is what makes save-back work
        // without pinning a writable descriptor from the pick.
        let mut fd2 = -1i64;
        assert_eq!(
            kaya_open_picked(handle.0, crate::wire::FILE_MODE_READ_WRITE, &mut fd2, &mut seekable),
            0
        );
        assert_ne!(fd2, -1);
        // AND THE WRITE HALF IS EXERCISED, which no test did until the
        // save milestone (docs/save-plan.md D3). READ_WRITE is a
        // positioned write and does NOT truncate.
        {
            let mut file = unsafe { crate::protocol::file_from_raw(fd2) };
            file.write_all(b"RW").unwrap();
        }
        assert_eq!(std::fs::read(&path).unwrap(), b"RWcked bytes");

        // WRITE truncates, and that is what makes the two modes
        // distinguishable ON DISK rather than by inspection.
        let mut fd3 = -1i64;
        assert_eq!(
            kaya_open_picked(handle.0, crate::wire::FILE_MODE_WRITE, &mut fd3, &mut seekable),
            0
        );
        {
            let mut file = unsafe { crate::protocol::file_from_raw(fd3) };
            file.write_all(b"W").unwrap();
        }
        assert_eq!(std::fs::read(&path).unwrap(), b"W");

        std::fs::remove_dir_all(&dir).ok();
    }

    /// THE SAVE DECISION AT UNIT LEVEL (docs/save-plan.md D1): a save
    /// dialog's destination opens even though NOTHING IS THERE, and
    /// opening it for write yields an empty file.
    ///
    /// This is the whole difference between the two sources, and the
    /// reason it is a source rather than a fourth file mode: the guest
    /// asks for the same `Write` it would ask for on a picked file, and
    /// the DESTINATION is what makes it create.
    #[test]
    fn a_save_destination_creates_and_then_truncates() {
        let dir = std::env::temp_dir().join(format!("kaya-save-unit-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("chosen.txt");
        // The state a real save panel leaves behind on macOS, GTK and
        // Windows: a name, and no file (measured — the panel creates
        // nothing, and does not truncate on Replace either).
        assert!(!path.exists());

        let handle = picked_register(std::sync::Arc::new(SaveDestination {
            name: "chosen.txt".into(),
            path: path.to_string_lossy().into_owned(),
        }));

        // A PICKED SOURCE FOR THE SAME PATH REFUSES, and that comparison
        // is the test: without it this only says "opening a file works".
        let picked = picked_register(std::sync::Arc::new(PathSource {
            name: "chosen.txt".into(),
            path: path.to_string_lossy().into_owned(),
        }));
        let mut fd = -1i64;
        let mut seekable = 0u32;
        assert_ne!(
            kaya_open_picked(picked.0, crate::wire::FILE_MODE_WRITE, &mut fd, &mut seekable),
            0,
            "a picked file that does not exist must still fail — only a \
             save destination creates"
        );

        assert_eq!(
            kaya_open_picked(handle.0, crate::wire::FILE_MODE_WRITE, &mut fd, &mut seekable),
            0,
            "a save destination opens for write even though nothing is there"
        );
        assert_eq!(seekable, 1);
        {
            let mut file = unsafe { crate::protocol::file_from_raw(fd) };
            // EMPTY AT THE START is the promise; the length is how a test
            // can see it, since a fresh descriptor has nothing to read.
            assert_eq!(file.metadata().unwrap().len(), 0);
            file.write_all(b"a longer first save").unwrap();
        }
        assert_eq!(std::fs::read(&path).unwrap(), b"a longer first save");

        // TRUNCATE ON EVERY WRITE OPEN, not only the creating one: the
        // second save of a document must not leave the tail of the first
        // behind, which is the failure a shorter save produces and a
        // longer one hides.
        let mut fd2 = -1i64;
        assert_eq!(
            kaya_open_picked(handle.0, crate::wire::FILE_MODE_WRITE, &mut fd2, &mut seekable),
            0
        );
        {
            let mut file = unsafe { crate::protocol::file_from_raw(fd2) };
            file.write_all(b"short").unwrap();
        }
        assert_eq!(std::fs::read(&path).unwrap(), b"short");

        // AND READING IT BACK DOES NOT DESTROY IT. The round trip the
        // save scene walks — write, reopen, read — is only a round trip
        // if Read leaves the bytes alone, so the create that every mode
        // carries must not bring truncation with it.
        let mut fd3 = -1i64;
        assert_eq!(
            kaya_open_picked(handle.0, crate::wire::FILE_MODE_READ, &mut fd3, &mut seekable),
            0
        );
        let mut got = String::new();
        unsafe { crate::protocol::file_from_raw(fd3) }
            .read_to_string(&mut got)
            .unwrap();
        assert_eq!(got, "short");

        // A DESTINATION IN A DIRECTORY THAT DOES NOT EXIST STILL FAILS,
        // and cleanly: create makes a FILE, never a path.
        let nowhere = picked_register(std::sync::Arc::new(SaveDestination {
            name: "x".into(),
            path: dir.join("no-such-dir").join("x").to_string_lossy().into_owned(),
        }));
        assert_ne!(
            kaya_open_picked(nowhere.0, crate::wire::FILE_MODE_WRITE, &mut fd, &mut seekable),
            0
        );

        std::fs::remove_dir_all(&dir).ok();
    }

    /// A SAVE DESTINATION READ BEFORE ANYTHING IS WRITTEN is the corner
    /// where the platforms disagree loudest: Android and iOS hand back a
    /// document that EXISTS, the three path platforms a name for nothing
    /// where a plain read would be ENOENT. The create every mode carries
    /// is what makes those one behaviour.
    #[test]
    fn reading_an_untouched_destination_answers_empty() {
        let dir = std::env::temp_dir().join(format!("kaya-save-fresh-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("fresh.txt");
        let handle = picked_register(std::sync::Arc::new(SaveDestination {
            name: "fresh.txt".into(),
            path: path.to_string_lossy().into_owned(),
        }));
        let mut fd = -1i64;
        let mut seekable = 0u32;
        assert_eq!(
            kaya_open_picked(handle.0, crate::wire::FILE_MODE_READ, &mut fd, &mut seekable),
            0
        );
        let mut got = String::new();
        let mut file = unsafe { crate::protocol::file_from_raw(fd) };
        file.read_to_string(&mut got).unwrap();
        assert_eq!(got, "");
        // Read and ReadWrite coincide on a destination — creation costs
        // write access on every OS kaya targets — and the honest way to
        // say so is to write through the handle Read handed back.
        file.rewind().unwrap();
        file.write_all(b"x").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"x");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// A WRONG HANDLE IS A CLEAN ERROR, which is the whole reason the
    /// table exists instead of handing the guest a pointer.
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
        // And the platform's own failure reaches the caller unchanged.
        let rc = kaya_open_picked(handle.0, crate::wire::FILE_MODE_READ, &mut fd, &mut seekable);
        assert_ne!(rc, 0, "opening a missing path must fail");
    }
}

static ALERT_LIVE: Mutex<Option<u64>> = Mutex::new(None);

/// The one-live-dialog slot, the alert's rule for the same reason: the
/// platform floor allows one modal picker at a time, and the result that
/// frees the slot arrives on the presentation side, so the slot lives
/// here — the one state both ends share.
static FILE_DIALOG_LIVE: Mutex<Option<u64>> = Mutex::new(None);

/// Scene side: a show_file_dialog was applied. Answers whether the slot
/// took it — `false` means a second one was asked for while the first
/// was live, the op is DROPPED, and the fault carries the sentence.
///
/// A REPORT AND NOT A PANIC: this runs inside `Scene::apply`, which
/// every backend drives from a frame that cannot unwind, so the panic
/// this used to raise aborted the process and took the harness's
/// failure list with it (crates/kaya/src/fault.rs).
pub(crate) fn file_dialog_shown(dialog: crate::protocol::FileDialogId) -> bool {
    let mut live = FILE_DIALOG_LIVE.lock().unwrap();
    if let Some(id) = *live {
        crate::fault::report(format!(
            "kaya: file dialog {id} is already live — one per process; \
             show the next from the first's result handler"
        ));
        return false;
    }
    *live = Some(dialog.0);
    true
}

/// Validate the dialog id against the live slot and free it — the one
/// retire gate for every backend, EMISSION being the caller's (the
/// alert_retire split: a ring push from a rust-native backend would
/// strand the result).
pub(crate) fn file_dialog_retire(dialog: u64) {
    let mut live = FILE_DIALOG_LIVE.lock().unwrap();
    match *live {
        Some(id) if id == dialog => *live = None,
        // THE SLOT IS LEFT ALONE on a mismatch: the live dialog is
        // still live, and freeing it on the strength of a wrong id
        // would let the next show_file_dialog through as if nothing
        // had happened.
        Some(id) => crate::fault::report(format!(
            "kaya: file dialog result for {dialog} but {id} is the live one"
        )),
        None => crate::fault::report(format!(
            "kaya: file dialog result for {dialog} but none is live"
        )),
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

/// Scene side: a show_alert was applied. Answers whether the slot took
/// it — `false` means one was already live, the op is DROPPED, and the
/// fault carries the sentence (the guest error is: show the next alert
/// from the first's result handler). The file-dialog twin's note says
/// why this reports rather than panics.
pub(crate) fn alert_shown(alert: crate::protocol::AlertId) -> bool {
    let mut live = ALERT_LIVE.lock().unwrap();
    if let Some(id) = *live {
        crate::fault::report(format!(
            "kaya: alert {id} is already live — one alert per process; \
             show the next from the first's result handler"
        ));
        return false;
    }
    *live = Some(alert.0);
    true
}

/// Whether an alert holds the one live slot RIGHT NOW.
///
/// THE HARNESS'S `alert_choose` WAITS ON THIS. Pressing a dialog's button
/// only ASKS; the platform answers through a completion, and that
/// completion is what calls `alert_retire`. Until it lands the slot is
/// still taken and the next `show_alert` hits the panic above.
///
/// READ WITHOUT ANY BACKEND STATE, which is why it lives here: on WinUI
/// every route into `CoreState` holds a `RefCell` borrow for the length
/// of the call, and the completion that frees the slot needs a MUTABLE
/// one, so a verb that polled the backend would be waiting on a borrow it
/// was itself preventing. This slot is a plain `Mutex`.
///
/// CFG'd TO ITS ONE CALLER. Widening the cfg is what a second caller
/// costs.
#[cfg(all(feature = "harness", target_os = "windows"))]
pub(crate) fn alert_is_live() -> bool {
    ALERT_LIVE.lock().unwrap().is_some()
}

/// Validate the alert id against the live slot and free it — the one
/// retire gate for every backend. EMISSION is the caller's: the C entry
/// below rides the presentation sink / ring, and the Rust-native backends
/// send on their own core OccSink (a ring push there would strand the
/// result — the linux confirm-rust legs caught exactly that).
pub(crate) fn alert_retire(alert: u64) {
    let mut live = ALERT_LIVE.lock().unwrap();
    match *live {
        Some(id) if id == alert => *live = None,
        // The slot survives a mismatch, exactly as file_dialog_retire's
        // does and for the same reason.
        Some(id) => crate::fault::report(format!(
            "kaya: alert result for {alert} but alert {id} is the live one"
        )),
        None => crate::fault::report(format!(
            "kaya: alert result for {alert} but no alert is live"
        )),
    }
}

/// Presentation side (interpreter platforms ONLY): retire, then emit on
/// the presentation sink. cfg'd OUT on the rust-native platforms on
/// purpose — their guests listen on the backend's own OccSink, so a call
/// from gtk.rs/winui would strand results on the ring (the linux
/// confirm-rust legs caught exactly that); this way it cannot compile
/// there at all.
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
        // ONE SOURCE PER PLATFORM, decided here because the locator means
        // something different on each: a path on macOS, a `content://`
        // URI on Android, and on iOS a name only the backend can redeem
        // (the path EPERMs once the scope drops).
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
        // single answer to what this file is called.
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
/// says a file IS. macOS and iOS answer with a filesystem path; Android
/// answers with a `content://` URI into a document provider that may not
/// be a filesystem at all.
///
/// THE CORE MINTS THE HANDLES, not the backend: it wraps each locator in
/// the platform's source, registers it, and hands the guest integers.
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

/// Register a save dialog's destination — THE ONE PLACE `create` COMES
/// FROM, and the reason it is a separate entry from the picker's.
///
/// A picked file exists; a destination need not. The two platforms whose
/// dialogs answer with a document register the source they always did;
/// the three that answer with a name for a file nobody has made register
/// a `SaveDestination`, whose open creates. The guest sees
/// docs/save-plan.md D1's one behaviour either way.
///
/// STRUCTURALLY, NOT BY A FLAG A BACKEND MIGHT FORGET: this entry takes
/// ONE locator and is reached only from a save presentation.
///
/// # Safety
/// `locator` and `name` must be valid NUL-terminated UTF-8 that outlives
/// the call, or null (which is CANCEL).
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
unsafe fn register_saved(
    locator: *const std::os::raw::c_char,
    name: *const std::os::raw::c_char,
) -> Vec<crate::protocol::PickedFile> {
    if locator.is_null() {
        // Cancel is the empty answer, exactly as the picker spells it.
        return Vec::new();
    }
    let read = |p: *const std::os::raw::c_char| -> String {
        if p.is_null() {
            return String::new();
        }
        unsafe { std::ffi::CStr::from_ptr(p) }
            .to_string_lossy()
            .into_owned()
    };
    #[cfg(target_os = "android")]
    let source: std::sync::Arc<dyn crate::protocol::PickedSource> =
        std::sync::Arc::new(crate::android::UriSource {
            name: read(name),
            uri: read(locator),
        });
    #[cfg(target_os = "ios")]
    let source: std::sync::Arc<dyn crate::protocol::PickedSource> =
        std::sync::Arc::new(crate::swiftui_host::UrlSource {
            name: read(name),
            locator: read(locator),
        });
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let source: std::sync::Arc<dyn crate::protocol::PickedSource> =
        std::sync::Arc::new(crate::protocol::SaveDestination {
            name: read(name),
            path: read(locator),
        });
    let handle = picked_register(source.clone());
    vec![crate::protocol::PickedFile {
        handle,
        name: crate::protocol::PickedSource::name(&*source).to_owned(),
        local_path: crate::protocol::PickedSource::local_path(&*source).to_owned(),
    }]
}

/// Presentation side: the save dialog's one answer, on the picker's
/// result grammar (docs/save-plan.md D2) — the occurrence, the live slot
/// and the retire gate are all the picker's.
///
/// ONE LOCATOR, NOT AN ARRAY, and that is the type doing the work: no
/// platform's save dialog names two destinations. A NULL `locator` is
/// cancel.
///
/// # Safety
/// `locator` and `name` must be valid NUL-terminated UTF-8 outliving the
/// call, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_save_dialog_result(
    dialog: u64,
    locator: *const std::os::raw::c_char,
    name: *const std::os::raw::c_char,
) {
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
    {
        let files = unsafe { register_saved(locator, name) };
        file_dialog_resolved(dialog, files);
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "android")))]
    {
        let _ = (dialog, locator, name);
        panic!(
            "kaya: kaya_emit_save_dialog_result is the interpreter platforms' \
             entry — this host's backend answers on its own sink"
        );
    }
}

/// ONE REPRESENTATION, as C sees it: the kind names which arm, and
/// exactly the fields that arm uses are read. `text` carries text and
/// html; `id` plus `bytes`/`len` carry a custom format; `bytes`/`len`
/// alone carry an image; `locators`/`names`/`count` carry files, in the
/// picker's own parallel-array shape.
///
/// A STRUCT AND NOT NINE PARAMETERS TWICE: the read's answer and a paste
/// carry the identical payload.
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
/// bytes every other occurrence rides on, so a stamped row's paste needs
/// no second entry.
///
/// A PASTE THAT DELIVERED NOTHING IS NOT AN OCCURRENCE: `rep` must name a
/// representation. The empty answer belongs to the read, which asked and
/// may be refused.
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

/// Presentation side: the alert's one answer — an ALERT_CHOICE value (an
/// action index, or the cancel sentinel for every platform-native
/// dismissal). The alert id retires here. Exported on every platform
/// (one C header, one export surface), but ANSWERABLE only where a
/// guest-language presentation layer exists: the rust-native backends
/// emit on their own core sink, so on GTK/WinUI this entry has no caller
/// by construction and panics loudly if one appears.
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
/// Presentation side: emit a click, exactly as a backend's action handler
/// would — `tag` is the click tag bytes delivered with the widget's
/// CREATE record, handed back verbatim. Do not combine with kaya_run.
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

/// Presentation side: emit a column-header click, exactly as a
/// backend's header handler would — `tag` is the sort tag delivered
/// with the container's SET_COLUMNS record, handed back verbatim;
/// `column` the 0-based index in the declared order. A REQUEST: the
/// guest sorts (docs/tables-plan.md). Do not combine with kaya_run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_emit_sort_requested(tag: *const u8, tag_len: usize, column: u32) {
    assert!(!tag.is_null() && tag_len != 0, "kaya: empty sort tag");
    let tag = unsafe { std::slice::from_raw_parts(tag, tag_len) };
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        sink.send_sort_tag(tag, column);
        return;
    }
    state()
        .ring
        .push_record(ring::REC_SORT_REQUESTED, &wire::sort_body(tag, column));
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

/// Presentation side: emit an entry edit, exactly as a backend's change
/// handler would — `tag` is the tag bytes delivered with the entry's
/// CREATE record, `text`/`text_len` the field's current UTF-8 content.
/// Do not combine with kaya_run.
///
/// THE LAST THREE ARGUMENTS ARE THE UNDO LEDGER'S (docs/undo-plan.md §3),
/// and they ride HERE rather than on a second entry point because the
/// alternative was two ABI crossings per keystroke to carry facts the
/// backend is already standing on:
///
/// - `window`: which surface's ledger this run of typing belongs to. The
///   core cannot derive it (a scene keeps no widget-to-window map).
/// - `focused`: whether the field this event names holds focus. An event
///   on an UNFOCUSED field closes the episode as it stands. A backend
///   that cannot tell passes 0.
/// - `quiet`: LEDGER-QUIET. A backend that ROUTES a native undo reports
///   it once through `kaya_note_native_undo`; the ordinary text_changed
///   the same undo provokes is bracketed with this flag so the change is
///   not banked twice, in either order. The occurrence still goes to the
///   app — only the BANKING is suppressed.
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
/// entry, banked from the occurrence stream rather than by reading any
/// widget.
///
/// A stamped copy edits under its template node's tag plus a key path;
/// the ledger keys on the identity that CARRIES the text, which for the
/// copy is its own internal widget id — the same id `absorb_text_writes`
/// names.
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
/// CONTEXT_ATTACH_NODE handed the backend for a node-anchored context
/// item, or empty for a bar / live-widget activation.
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
/// path. `item` is the menu item id; `noun`/`noun_len` carry the anchor
/// copy's key path for a node-anchored context item, or NULL/0 for a bar
/// or live-widget activation. Do not combine with kaya_run.
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
// the same lock the pump takes. Exported on every platform, answerable
// where a guest-language presentation layer exists.

/// Apply-ops the core produced OUTSIDE a transaction: an undo's inverse
/// or an episode's coarse restore. Nothing else in the protocol makes ops
/// without a transaction, and the pump is the only way out, so they wait
/// here for the next batch and LEAD it — the scene mutation that made
/// them happened before whatever that batch applies, under the same lock.
static PRESENTATION_PENDING: Mutex<Vec<crate::protocol::ApplyOp>> = Mutex::new(Vec::new());

/// Queue a core-made batch's ops for the pump and wake it. TWO
/// PRODUCERS reach it: the undo tier and the row window
/// (docs/virtualization-plan.md §3.3).
///
/// THE WAKE IS NOT OPTIONAL. The pump blocks on the transaction channel,
/// and an app that registers no `on_undone` handler sends no transaction
/// in response — so without a nudge the inverse would sit here until the
/// user did something else. An empty transaction is the nudge;
/// `kaya_next_commands` treats an empty resolved batch as "nothing to say
/// yet", not shutdown.
///
/// Called with the scene lock HELD, so the queue's order is the order the
/// scene was mutated in.
fn queue_presentation_ops(pending: &mut Vec<crate::protocol::ApplyOp>, ops: Vec<crate::protocol::ApplyOp>) {
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

/// The shared body of `kaya_undo` / `kaya_redo`: mutate the ledger, put
/// the ops in front of the pump, then tell the app what came back.
///
/// THE SCENE LOCK SPANS THE FIRST TWO. The pump takes the same lock to
/// resolve a transaction, so a transaction the guest sent WHILE this ran
/// would otherwise be resolved against the restored scene and reach the
/// backend AHEAD of the restore it came after.
///
/// The occurrence goes out afterwards, lock released: the app's reaction
/// must not overtake the restore, and the ops are already queued.
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
    queue_presentation_ops(&mut PRESENTATION_PENDING.lock().unwrap(), ops);
    drop(scene_slot);
    send_undo_occurrence(occurrence);
}

/// Where an undo would go RIGHT NOW: 0 nowhere (the command is inert and
/// reads disabled), 1 the focused field's own stack, 2 the core's ledger.
/// `focused` is the widget the backend has focus on, 0 for none;
/// `can_undo` is A4's one named query, answered in the platform's own
/// vocabulary. Enablement and activation are the SAME call, so the two
/// cannot drift.
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
/// landed on, and whether that field can still undo.
///
/// The ordinary text_changed the same undo provokes carries the
/// ledger-quiet flag on `kaya_emit_text_changed`, so this change is
/// banked once no matter which of the two the platform delivers first.
///
/// Usually there is nothing to apply. The exception is a platform that
/// exhausted its stack short of the episode's before-image, which falls
/// back to the coarse restore.
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

// --- Row windowing's host entries (docs/virtualization-plan.md §3) -----
//
// BACKEND PLUMBING, never app surface: no binding exposes these, no guest
// implements a callback, and nothing is supplied on demand — the
// collection already holds every row. The applies they make ride the pump
// as its SECOND PRODUCER: core-internal, never re-entering the guest, and
// serialized with transaction applies by the scene lock the pump also
// takes (§3.3). The Rust-native backends drive the same Scene methods
// directly, the way they drive Scene::apply; only the interpreter
// platforms cross this ABI.

/// `kaya_scroll_to_row_*`'s no-answer: the scene is not up, or the target
/// or key was refused. The FAULT carries the sentence.
pub const KAYA_ROW_NOT_FOUND: u64 = u64::MAX;

/// Mutate the presentation scene outside a transaction and put its ops in
/// front of the pump — `with_undo_scene`'s shape without an occurrence,
/// because the window tier tells the guest nothing.
///
/// THE UNWIND STOPS HERE. Every caller is an `extern "C"` frame entered
/// from a backend's layout pass, so a refused target reddens the leg with
/// its sentence instead of aborting (crates/kaya/src/fault.rs).
fn with_window_scene<R: Default>(
    what: &str,
    f: impl FnOnce(&mut Scene) -> (Vec<crate::protocol::ApplyOp>, R),
) -> R {
    let mut scene_slot = PRESENTATION_SCENE.lock().unwrap_or_else(|e| e.into_inner());
    let Some(scene) = scene_slot.as_mut() else {
        return R::default();
    };
    let Some((ops, answer)) = crate::fault::guard(what, || f(scene)) else {
        return R::default();
    };
    queue_presentation_ops(&mut PRESENTATION_PENDING.lock().unwrap(), ops);
    answer
}

/// A For's visible range changed — scroll, resize or first layout.
///
/// `for_target` is the For CONTAINER's widget id (the id its create apply
/// carried), live or stamped. Indices are POSITIONS over the collection's
/// current order, so rows flow through a fixed band under a sort, exactly
/// as platform tables behave.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_window_moved(for_target: u64, first_index: u64, visible_count: u64) {
    with_window_scene("reporting a window range", |scene| {
        (
            scene.window_moved(for_target, first_index as usize, visible_count as usize),
            (),
        )
    })
}

/// The extents a backend measured for the realized rows at
/// `first_index..`, one per row (§3.4). Produces no applies: a height
/// moves the ARITHMETIC, never the band, which is a position over the
/// order.
///
/// # Safety
/// `heights` must point at `count` readable doubles, or be NULL with
/// `count` 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_rows_measured(
    for_target: u64,
    first_index: u64,
    heights: *const f64,
    count: usize,
) {
    let measured: Vec<f64> = if count == 0 || heights.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(heights, count) }.to_vec()
    };
    with_window_scene("reporting measured row heights", |scene| {
        scene.rows_measured(for_target, first_index as usize, &measured);
        (Vec::new(), ())
    })
}

/// `scroll_to_row` for a STRING-keyed collection: the row's index in the
/// collection's current order, for the backend to scroll to.
/// [`KAYA_ROW_NOT_FOUND`] when there is no answer.
///
/// TWO ENTRIES, ONE PER KEY TYPE, because `protocol::Key` is exactly
/// I64|Str and a `kind` integer beside the payload is the file-modes trap
/// (tools/check-file-modes.sh): five hand-written sites decoding a number
/// nobody re-checks. The type is in the name instead.
///
/// # Safety
/// `key`/`key_len` must describe a valid UTF-8 byte range, or be NULL/0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_scroll_to_row_str(
    for_target: u64,
    key: *const u8,
    key_len: usize,
) -> u64 {
    let Some(key) = (unsafe { borrowed_str(key, key_len) }) else {
        crate::fault::report(
            "kaya: scroll_to_row was handed a key that is not UTF-8".to_owned(),
        );
        return KAYA_ROW_NOT_FOUND;
    };
    with_window_scene("resolving scroll_to_row", |scene| {
        (
            Vec::new(),
            scene.scroll_to_row(for_target, &crate::protocol::Value::Str(key)) as u64,
        )
    })
}

/// `scroll_to_row` for an I64-keyed collection.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_scroll_to_row_i64(for_target: u64, key: i64) -> u64 {
    with_window_scene("resolving scroll_to_row", |scene| {
        (
            Vec::new(),
            scene.scroll_to_row(for_target, &crate::protocol::Value::I64(key)) as u64,
        )
    })
}

/// One windowed For's geometry, as a backend lays it out. `first`/`count`
/// are the realized band, `total` the whole collection's rows, `offset`
/// the band's top, `extent` the collection's, and `anchor_shift` how far
/// the anchor row has moved since the viewport parked on it — what the
/// backend adds to its scroll so a correction above does not move the
/// content under the reader's eyes (§2.4). `corrected` is 0 while every
/// measurement has equalled the pitch.
#[repr(C)]
#[derive(Default)]
pub struct KayaWindowGeometry {
    pub first: u64,
    pub count: u64,
    pub total: u64,
    pub offset: f64,
    pub extent: f64,
    pub anchor_shift: f64,
    pub corrected: u8,
}

/// Read one windowed For's geometry. Answers a zeroed record when the
/// scene is not up or the target was refused; the fault carries the
/// sentence.
///
/// # Safety
/// `out` must be a valid place to write a `KayaWindowGeometry`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_window_geometry(for_target: u64, out: *mut KayaWindowGeometry) {
    if out.is_null() {
        return;
    }
    let g = with_window_scene("reading a window's geometry", |scene| {
        let g = scene.window_geometry(for_target);
        (
            Vec::new(),
            KayaWindowGeometry {
                first: g.first as u64,
                count: g.count as u64,
                total: g.total as u64,
                offset: g.offset,
                extent: g.extent,
                anchor_shift: g.anchor_shift,
                corrected: u8::from(g.corrected),
            },
        )
    });
    unsafe { *out = g };
}

/// One row's height in the core's arithmetic — measured if that row has
/// been, presumed from the pitch otherwise, and 0 before this For has
/// been measured at all.
///
/// A ROW-HEIGHT DELEGATE ASKS PER ROW, over the whole collection and not
/// just the band (the macOS native tier, §4), so the geometry read cannot
/// serve: a backend without this would keep a height cache of its own,
/// which is the second estimator §2 exists to remove.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_row_extent(for_target: u64, index: u64) -> f64 {
    with_window_scene("reading a row's extent", |scene| {
        (Vec::new(), scene.row_extent(for_target, index as usize))
    })
}

/// THE WINDOW'S SCALE AND APPEARANCE, reported by the backend; the core
/// re-rasters every canvas at them (docs/canvas-plan.md §5, §6). That is
/// the platforms' own rescale-then-re-render mechanism, not an
/// invention: `backingScaleFactor` plus `windowDidChangeBackingProperties:`
/// on macOS, `WM_DPICHANGED` on Windows, fractional-scale's
/// `preferred_scale` on Wayland.
///
/// `scale` is the TRUE scale, never the rounded one — GTK is the backend
/// that can hand back a fraction, and `gdk_surface_get_scale` is the
/// double to read rather than `gtk_widget_get_scale_factor`'s integer.
/// `dark` is the ONLY thing a platform contributes to a drawing: no
/// platform colour reaches one.
///
/// A report that changes nothing emits nothing.
///
/// LATCHED BEFORE IT IS APPLIED (`PRESENTATION_REPORTED`): the backends
/// report at their first layout, which can precede the scene, and a
/// report the scene never saw is a canvas rastered at the wrong palette
/// for the process's whole life.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_presentation(scale: f64, dark: bool) {
    let mode = if dark { crate::canvas::Mode::Dark } else { crate::canvas::Mode::Light };
    let reported = crate::canvas::Presentation { scale, mode };
    *PRESENTATION_REPORTED
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = Some(reported);
    with_window_scene("reporting the window's scale and appearance", |scene| {
        (scene.set_presentation(reported), ())
    })
}

/// THE TRACK LAYOUT ASSIGNED ONE CANVAS, in device-independent points,
/// reported by the backend exactly as `kaya_window_moved` reports a For's
/// visible band (docs/canvas-plan.md §3.2.1). This is the report the
/// stretch defect was missing: without it the core could only ever raster
/// at the viewbox and leave the backend to stretch the picture.
///
/// What happens next is the canvas's SIZE POLICY: `scale` re-rasterizes
/// the held display list under a uniform fit, `redraw` and `tick` are
/// asked for a drawing at this size, and `fixed` records the number and
/// changes nothing. A report that changes nothing emits nothing.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_canvas_track(widget: u64, width: f64, height: f64) {
    let asks = with_window_scene("reporting a canvas's assigned track", |scene| {
        let (ops, asks) =
            scene.set_canvas_track(crate::protocol::WidgetId(widget), (width, height));
        (ops, asks)
    });
    send_occurrences(asks);
}

/// A FRAME, at the platform's own frame time in seconds (§15.4): every
/// `tick` canvas is handed the size it was assigned and that time.
///
/// THE TIME IS THE PLATFORM'S — CADisplayLink's `targetTimestamp`,
/// Choreographer's frame time — never one the core or a guest reads for
/// itself, because both are fixed at schedule time and a clock read in
/// the callback re-imports the jitter they removed.
/// MONOTONE, AND THAT IS WHAT MAKES ONE DRIVER PER CANVAS SAFE: the
/// backends attach a frame source to each canvas rather than reading a
/// policy they are not told, so N canvases hand the SAME frame's
/// timestamp in N times. Only the first advances anything.
static LAST_FRAME: Mutex<f64> = Mutex::new(f64::NEG_INFINITY);

#[unsafe(no_mangle)]
pub extern "C" fn kaya_frame(time: f64) {
    if !time.is_finite() {
        return;
    }
    {
        let mut last = LAST_FRAME.lock().unwrap_or_else(|e| e.into_inner());
        if time <= *last {
            return;
        }
        *last = time;
    }
    drive_frame(time);
}

fn drive_frame(time: f64) {
    let ticks = with_window_scene("driving a frame", |scene| (Vec::new(), scene.frame(time)));
    send_occurrences(ticks);
}

/// The harness clock's rate. ONE NUMBER, in the core, and that is the
/// point: three harnesses keeping three counters is the
/// hand-copied-constant class one surface over
/// (tools/check-file-modes.sh's trap), and a leg's frame count is part
/// of the scene.
pub const HARNESS_FRAME_HZ: f64 = 60.0;
static HARNESS_FRAMES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// THE HARNESS'S FRAME CLOCK: advance by exactly one frame at
/// `HARNESS_FRAME_HZ` and drive it. Wall clock never reaches a tick
/// under the harness, so a leg's frame count is what the scene's `frame`
/// verbs advanced and not a fact about the machine's load.
///
/// BYPASSES `kaya_frame`'s MONOTONE GUARD deliberately: this clock
/// starts at one sixtieth while a platform's starts at a timestamp
/// decades wide, so a stray platform frame would silence every harness
/// frame for the rest of the run. Under the harness no platform driver
/// is attached, so the two clocks never both run — and this counter is
/// monotone on its own.
#[unsafe(no_mangle)]
pub extern "C" fn kaya_harness_frame() {
    let n = HARNESS_FRAMES.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
    drive_frame(n as f64 / HARNESS_FRAME_HZ);
}

/// Presentation-side occurrences the core produced rather than a user
/// gesture: the Rust API's mpsc where one is installed, the byte ring
/// otherwise. One helper because the canvas has three senders and each
/// spelling of this fallback is a place the ring and the mpsc can drift.
fn send_occurrences(occurrences: Vec<crate::protocol::Occurrence>) {
    if occurrences.is_empty() {
        return;
    }
    if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {
        for occ in occurrences {
            sink.send(occ);
        }
        return;
    }
    let state = state();
    for occ in occurrences {
        match occ {
            crate::protocol::Occurrence::DrawRequested { id, size } => state.ring.push_record(
                ring::REC_DRAW_REQUESTED,
                &crate::wire::draw_body(id.0, &[], size, None),
            ),
            crate::protocol::Occurrence::Tick { id, size, time } => state.ring.push_record(
                ring::REC_TICK,
                &crate::wire::draw_body(id.0, &[], size, Some(time)),
            ),
            other => unreachable!("send_occurrences carries only the canvas asks: {other:?}"),
        }
    }
}

/// WHAT THE HARNESS READS BACK ABOUT ONE CANVAS: the CANONICAL raster's
/// hash and the two legible facts, as one ASCII line
/// `"<16 hex> <ops>/<l>,<t>,<r>,<b>"` (docs/canvas-plan.md §7.1, §7.2).
///
/// Canonical means scale 1.0 and the light palette, pinned HERE rather
/// than read from the lane's display, which is what lets one frozen
/// string hold on five platforms. It is a read of an ARTIFACT — the
/// output of validation, the fold, shaping, font resolution, the palette
/// and the rasterizer — never of the declaration, so it is not the
/// forbidden shape where the scene agrees with itself.
///
/// Writes at most `cap` bytes to `out` and returns how many it wrote; 0
/// means `widget` names no canvas that has been drawn. Never NUL
/// terminates: the caller has the length.
///
/// # Safety
/// `out` must point at `cap` writable bytes, or be NULL with `cap` 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_canvas_probe(widget: u64, out: *mut u8, cap: usize) -> usize {
    let answer = with_window_scene("probing a canvas", |scene| {
        (Vec::new(), scene.canvas_probe(crate::protocol::WidgetId(widget)))
    });
    let Some(answer) = answer else { return 0 };
    let bytes = answer.as_bytes();
    if out.is_null() || cap < bytes.len() {
        return 0;
    }
    // SAFETY: the caller promises `cap` writable bytes and the length
    // was just checked against it.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
    bytes.len()
}

/// WHICH SIZE ONE CANVAS'S RASTER IS — `expect_raster`'s observation
/// (docs/canvas-plan.md §3.2.1). `"track"` when it is the size the
/// BACKEND reported, `"viewbox"` when it is the one the GUEST declared,
/// and on disagreement all three numbers rather than a guess about which
/// is wrong (invariant 3: a diagnostic prints what it measured).
///
/// This is the only canvas read the size policy can move. `kaya_canvas_probe`
/// rasterizes at the viewbox by definition — that is what makes its hash
/// one string on five platforms — so the hash and the ink bounds are
/// policy-blind, and a canvas that stretched its buffer instead of
/// re-rastering at the track would answer both of them identically.
///
/// Writes at most `cap` bytes to `out` and returns how many it wrote; 0
/// means `widget` names no canvas that has been drawn.
///
/// # Safety
/// `out` must point at `cap` writable bytes, or be NULL with `cap` 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_canvas_raster_shape(
    widget: u64,
    out: *mut u8,
    cap: usize,
) -> usize {
    let answer = with_window_scene("reading a canvas's raster shape", |scene| {
        (Vec::new(), scene.canvas_raster_shape(crate::protocol::WidgetId(widget)))
    });
    let Some(answer) = answer else { return 0 };
    let bytes = answer.as_bytes();
    if out.is_null() || cap < bytes.len() {
        return 0;
    }
    // SAFETY: the caller promises `cap` writable bytes and the length
    // was just checked against it.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
    bytes.len()
}

thread_local! {
    /// Where the batch handed out by the last `kaya_next_commands`
    /// lives. THREAD-LOCAL for HELD_OCCURRENCE's reason: the borrow's
    /// lifetime is stated per caller, and a second thread calling would
    /// otherwise free bytes the pump is still decoding.
    static HELD_BATCH: std::cell::RefCell<Vec<u8>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// Presentation side: block until the next transaction, resolve it
/// through the scene, and hand back that batch's apply-op records.
/// Writes the borrowed pointer to `batch` and returns the byte length,
/// or 0 when the core has shut down. Call from a single pump thread.
///
/// THE CORE OWNS THE BYTES, and there is no size cap — kaya_next_occurrence's
/// ruling, reached the same way one direction over: a caller-sized buffer
/// makes the batch a wall, and 161 four-column rows in one transaction
/// aborted the interpreter platforms from inside this `extern "C"` frame
/// (docs/traps.md, "A caller-sized occurrence buffer"; docs/measurements/
/// choke-{macos,ios,android}-2026-08-24.txt). Splitting is not the
/// alternative: a batch is one recomposition, so only the producer can
/// size it.
///
/// The bytes — and this batch's blob table — stay valid until this
/// thread's NEXT call here. Copy out what you keep, exactly as
/// `kaya_blob_data` asks.
///
/// SHUTDOWN NULLS THE POINTER rather than leaving it as it was, so a
/// caller that forgets the case cannot re-apply the previous batch.
///
/// # Safety
/// `batch` must be a valid place to write a pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kaya_next_commands(batch: *mut *const u8) -> usize {
    if batch.is_null() {
        return 0;
    }
    unsafe { *batch = std::ptr::null() };
    let mut rx_slot = PRESENTATION_TX_RX.lock().unwrap();
    if rx_slot.is_none() {
        let Some((_occ, tx_rx)) = state().core_ends.lock().unwrap().take() else {
            return 0;
        };
        *rx_slot = Some(tx_rx);
        *PRESENTATION_SCENE.lock().unwrap() = Some(presentation_scene());
    }
    // 0 MEANS SHUTDOWN TO EVERY PUMP, so a batch that resolved to nothing
    // must not be returned: keep waiting instead. The undo tier's wake is
    // an empty transaction whose ops are already queued, and a
    // transaction whose ops all cancelled out is the same shape.
    let ops = loop {
        let Ok(tx) = rx_slot.as_ref().unwrap().recv() else {
            return 0;
        };
        // POISON-TOLERANT because the guard below exists: a caught
        // panic drops this lock while unwinding, and an `unwrap` on
        // the next call would then panic OUTSIDE the guard — the abort
        // this whole path removes, one call later.
        let mut scene_slot = PRESENTATION_SCENE.lock().unwrap_or_else(|e| e.into_inner());
        // The queue leads: those ops were made under this same lock,
        // before this transaction could be resolved.
        let mut ops = std::mem::take(&mut *PRESENTATION_PENDING.lock().unwrap());
        // THE UNWIND STOPS HERE. This is an `extern "C"` frame, so a
        // panic out of Scene::apply — every app-misuse assertion in
        // scene.rs — is `fatal runtime error: failed to initiate panic`
        // and the leg dies with no verdict list (crates/kaya/src/fault.rs).
        // The faulted transaction's ops are dropped and the pump waits
        // for the next one; the harness reads the latch and reddens.
        let Some(resolved) = crate::fault::guard("applying a transaction", || {
            scene_slot.as_mut().unwrap().apply(tx)
        }) else {
            continue;
        };
        ops.extend(resolved);
        // A transaction that turned a canvas into a redraw one when its
        // track was already known leaves a draw request behind
        // (docs/canvas-plan.md §3.2.1). Drained under the scene lock and
        // sent after it, because the sink is a different lock.
        let asks = scene_slot.as_mut().unwrap().take_asks();
        drop(scene_slot);
        send_occurrences(asks);
        if !ops.is_empty() {
            break ops;
        }
    };
    let mut writer = wire::Writer::new();
    for op in &ops {
        writer.apply_op(op);
    }
    // Publish the batch's blob table (replacing the previous batch's):
    // the records reference these bytes by 1-based index through
    // kaya_blob_data, valid until the next call here. Blob payloads never
    // enter the record stream.
    blobs().lock().unwrap().out = std::mem::take(&mut writer.blobs);
    HELD_BATCH.with(|held| {
        let mut held = held.borrow_mut();
        *held = writer.into_bytes();
        unsafe { *batch = held.as_ptr() };
        held.len()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `blobs().out` is process-global AND the pump replaces it with
    /// every batch, so the two tests that read it take this first.
    static OUT_TABLE: Mutex<()> = Mutex::new(());

    /// The blob tables' lifecycle, in one serial test (the tables are
    /// process-global): registration fills pending; the submit boundary
    /// drains it, referenced or not; the out table serves the current
    /// batch by 1-based index and a dead handle reads NULL.
    #[test]
    fn blob_tables_register_drain_and_serve() {
        let _serial = OUT_TABLE.lock().unwrap_or_else(|e| e.into_inner());
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

    /// THE INITIAL RASTER READS THE REPORTED MODE, even though the report
    /// arrives BEFORE the scene exists — which is the ordering every
    /// interpreter backend actually has, and the one that shipped the
    /// canvas rendering light in a dark window (measured 2026-08-27 on a
    /// dark-mode mac, docs/traps.md).
    ///
    /// NO SCENE CAN FAIL THIS on a light-mode host, and every lane before
    /// tonight ran light: the leg reddens only where the machine's
    /// appearance differs from `Presentation::default()`. So the ordering
    /// is asserted here, where the host's own appearance cannot reach it.
    #[test]
    fn a_presentation_reported_before_the_scene_exists_seeds_it() {
        let _serial = OUT_TABLE.lock().unwrap_or_else(|e| e.into_inner());
        let ground = |mode: crate::canvas::Mode| -> [u8; 4] {
            // THE REPORT COMES FIRST, with no scene built — the whole
            // point. `kaya_presentation` latches it.
            kaya_presentation(2.0, mode == crate::canvas::Mode::Dark);
            let mut scene = presentation_scene();
            let id = crate::protocol::WidgetId(1);
            let ops = vec![
                crate::protocol::TxOp::CreateWidget {
                    id,
                    kind: crate::protocol::WidgetKind::Canvas,
                },
                crate::protocol::TxOp::SetDrawing {
                    widget: id,
                    viewbox: (10.0, 10.0),
                    path: Vec::new(),
                    // One filled rect in the ground role: every pixel is
                    // the palette entry the mode resolved.
                    ops: vec![
                        crate::protocol::Value::I64(wire::DRAW_MOVE_TO),
                        crate::protocol::Value::F64(0.0),
                        crate::protocol::Value::F64(0.0),
                        crate::protocol::Value::I64(wire::DRAW_LINE_TO),
                        crate::protocol::Value::F64(10.0),
                        crate::protocol::Value::F64(0.0),
                        crate::protocol::Value::I64(wire::DRAW_LINE_TO),
                        crate::protocol::Value::F64(10.0),
                        crate::protocol::Value::F64(10.0),
                        crate::protocol::Value::I64(wire::DRAW_LINE_TO),
                        crate::protocol::Value::F64(0.0),
                        crate::protocol::Value::F64(10.0),
                        crate::protocol::Value::I64(wire::DRAW_CLOSE),
                        crate::protocol::Value::I64(wire::DRAW_FILL),
                        crate::protocol::Value::I64(wire::PAINT_GROUND),
                        crate::protocol::Value::I64(wire::FILL_NONZERO),
                    ],
                },
                crate::protocol::TxOp::Mount {
                    window: crate::protocol::DEFAULT_WINDOW,
                    root: id,
                },
            ];
            // UNDER THE PUMP'S OWN GUARD, which is how kaya_next_commands
            // drives it — fault::tests::every_scene_apply_caller_sits_under_a_guard
            // finds this site and is right to.
            let applied = crate::fault::guard("applying a transaction", || scene.apply(ops))
                .expect("the canvas declaration applies without faulting");
            let drawing = applied
                .iter()
                .find_map(|o| match o {
                    crate::protocol::ApplyOp::SetDrawing {
                        width,
                        height,
                        scale,
                        pixels,
                        ..
                    } => Some((*width, *height, *scale, pixels)),
                    _ => None,
                })
                .expect("the canvas declaration emits a SetDrawing");
            let (width, _height, scale, pixels) = drawing;
            // THE SCALE IS THE OTHER HALF the same dropped report cost,
            // and no scene can see it: a 10pt viewbox at the reported 2.0
            // is 20 pixels across.
            assert_eq!(scale, 2.0, "the reported scale never reached the raster");
            assert_eq!(width, 20, "a 10pt viewbox at scale 2.0 is 20px wide");
            let centre = ((width as usize / 2) * 4) + (width as usize * 4 * (width as usize / 2));
            [
                pixels.0[centre],
                pixels.0[centre + 1],
                pixels.0[centre + 2],
                pixels.0[centre + 3],
            ]
        };
        assert_eq!(
            ground(crate::canvas::Mode::Dark),
            [0x16, 0x18, 0x1C, 0xFF],
            "reported dark, rastered something else — PALETTE_DARK's ground is 16181C"
        );
        // The light arm is the control: it passes with the latch removed,
        // which is why the dark arm above is the one that measures.
        assert_eq!(
            ground(crate::canvas::Mode::Light),
            [0xFF, 0xFF, 0xFF, 0xFF],
            "reported light, rastered something else — PALETTE_LIGHT's ground is FFFFFF"
        );
        *PRESENTATION_REPORTED
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// THE FUNCTION FLOOR HAS NO SIZE CAP, because the core owns the
    /// bytes it hands out. It used to copy into a caller-sized buffer
    /// every caller sized 256, so an occurrence above 208 bytes of
    /// payload ABORTED THE PROCESS from inside an `extern "C"` frame
    /// (docs/traps.md).
    ///
    /// 8 KiB is not a new cap: it is thirty-two times that buffer, which
    /// is the distance that matters.
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

    /// AND NEITHER DOES THE PUMP, the same call one direction over. It
    /// used to copy into a caller-sized buffer both interpreters sized
    /// 64 KiB, so ONE BUILD TRANSACTION of 161 four-column table rows
    /// aborted the process on macOS, iOS and Android before the harness
    /// script started (docs/deferred.md; docs/measurements/choke-*.txt).
    ///
    /// 400 labels is ~10x that buffer. A batch is one recomposition and
    /// may not be split, so the only fix is the core owning the bytes.
    #[test]
    fn the_pump_hands_out_a_batch_of_any_size() {
        let _serial = OUT_TABLE.lock().unwrap_or_else(|e| e.into_inner());
        let rows = 400usize;
        let last = format!("row {} {}", rows - 1, "y".repeat(200));
        let mut tx = vec![crate::protocol::TxOp::CreateWidget {
            id: crate::protocol::WidgetId(1),
            kind: crate::protocol::WidgetKind::Column,
        }];
        for i in 0..rows {
            let id = crate::protocol::WidgetId(2 + i as u64);
            tx.push(crate::protocol::TxOp::CreateWidget {
                id,
                kind: crate::protocol::WidgetKind::Label,
            });
            tx.push(crate::protocol::TxOp::SetProperty {
                widget: id,
                prop: crate::protocol::Prop::Text,
                value: crate::protocol::PropValue::Const(crate::protocol::Value::Str(
                    format!("row {i} {}", "y".repeat(200)),
                )),
            });
            tx.push(crate::protocol::TxOp::AddChild {
                parent: crate::protocol::WidgetId(1),
                child: id,
            });
        }
        tx.push(crate::protocol::TxOp::Mount {
            window: crate::protocol::DEFAULT_WINDOW,
            root: crate::protocol::WidgetId(1),
        });
        state().tx_tx.send(tx).unwrap();

        let mut batch: *const u8 = std::ptr::null();
        let n = unsafe { kaya_next_commands(&mut batch) };
        assert!(!batch.is_null());
        assert!(
            n > 64 * 1024,
            "the probe is too small to reach the old wall: {n} bytes"
        );
        let bytes = unsafe { std::slice::from_raw_parts(batch, n) };

        // The records walk to EXACTLY n and the walk ends on the Mount:
        // a truncated batch either runs off the end or stops short of it.
        let mut at = 0usize;
        let mut kind = 0u16;
        while at < n {
            let size = u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
            kind = u16::from_le_bytes(bytes[at + 4..at + 6].try_into().unwrap());
            assert!(
                size >= wire::HEADER_SIZE && size % 8 == 0 && at + size <= n,
                "record of {size} bytes at {at} of {n}"
            );
            at += size;
        }
        assert_eq!(at, n);
        assert_eq!(kind, wire::APPLY_MOUNT);
        assert!(
            bytes.windows(last.len()).any(|w| w == last.as_bytes()),
            "the last row's text never arrived in {n} bytes"
        );
        blobs().lock().unwrap().out.clear();
    }

    /// The KAYA_-prefixed constants are the C ABI's copy of the spec's
    /// record kinds — the one table the generator does not write. This
    /// pins it both ways: every row has its constant (the count catches a
    /// row added without one) and every constant matches its row's kind.
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
            ("highlight_ranges", KAYA_TX_HIGHLIGHT_RANGES),
            ("select_range", KAYA_TX_SELECT_RANGE),
            ("reveal_range", KAYA_TX_REVEAL_RANGE),
            ("show_save_dialog", KAYA_TX_SHOW_SAVE_DIALOG),
            ("set_brand_accent", KAYA_TX_SET_BRAND_ACCENT),
            ("set_brand_typeface", KAYA_TX_SET_BRAND_TYPEFACE),
            ("set_app_identity", KAYA_TX_SET_APP_IDENTITY),
            ("set_column_headers", KAYA_TX_SET_COLUMN_HEADERS),
            ("set_drawing", KAYA_TX_SET_DRAWING),
            ("set_size_policy", KAYA_TX_SET_SIZE_POLICY),
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
            ("highlight_ranges", KAYA_APPLY_HIGHLIGHT_RANGES),
            ("select_range", KAYA_APPLY_SELECT_RANGE),
            ("reveal_range", KAYA_APPLY_REVEAL_RANGE),
            ("present_save_dialog", KAYA_APPLY_PRESENT_SAVE_DIALOG),
            ("set_brand", KAYA_APPLY_SET_BRAND),
            ("set_typeface", KAYA_APPLY_SET_TYPEFACE),
            ("set_app_identity", KAYA_APPLY_SET_APP_IDENTITY),
            ("set_column_headers", KAYA_APPLY_SET_COLUMN_HEADERS),
            ("set_drawing", KAYA_APPLY_SET_DRAWING),
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
