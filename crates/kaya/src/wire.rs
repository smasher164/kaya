//! Byte encoding of the protocol for the C boundary.
//!
//! One framing serves every channel — u32 size, u16 kind, u16 flags,
//! 8-byte aligned, size includes the header, little-endian. Values are
//! { u32 type; u32 len; payload padded to 8 }. Decoding is for foreign
//! guests, encoding for the pump and for tests; malformed input fails
//! LOUDLY, because a bad buffer is a broken binding.

use std::sync::Arc;

use crate::protocol::{
    EntryProp, MenuItemId, MenuItemKind, MenuProp, SectionProp, WindowProp,
    AlertChoice, AlertId, AlertSpec,
    ApplyOp, Blob, CollectionId, CommandKind, Occurrence, Path, Prop, PropValue, Record, SignalId,
    TemplateNodeId, TextRange, Transaction, TxOp, Value, ValueType, WidgetId, WidgetKind,
    WindowId,
};

pub(crate) const HEADER_SIZE: usize = 8;

// Transaction record kinds (guest -> core).
pub(crate) const TX_CREATE_SIGNAL: u16 = 1;
pub(crate) const TX_WRITE_SIGNAL: u16 = 2;
pub(crate) const TX_CREATE_WIDGET: u16 = 3;
pub(crate) const TX_SET_PROPERTY: u16 = 4;
pub(crate) const TX_ADD_CHILD: u16 = 5;
pub(crate) const TX_MOUNT: u16 = 6;
pub(crate) const TX_CREATE_COLLECTION: u16 = 7;
pub(crate) const TX_COLLECTION_INSERT: u16 = 8;
pub(crate) const TX_COLLECTION_UPDATE: u16 = 9;
pub(crate) const TX_COLLECTION_REMOVE: u16 = 10;
pub(crate) const TX_CREATE_FOR: u16 = 11;
pub(crate) const TX_CREATE_WHEN: u16 = 12;
pub(crate) const TX_TEMPLATE_END: u16 = 13;
pub(crate) const TX_COLLECTION_UPDATE_FIELD: u16 = 14;
pub(crate) const TX_COLLECTION_MOVE: u16 = 15;
pub(crate) const TX_VARIANT_CASE: u16 = 16;
pub(crate) const TX_WIDGET_COMMAND: u16 = 17;
pub(crate) const TX_SET_WINDOW_PROP: u16 = 18;
pub(crate) const TX_CREATE_WINDOW: u16 = 19;
pub(crate) const TX_DESTROY_WINDOW: u16 = 20;
pub(crate) const TX_SHOW_ALERT: u16 = 21;
pub(crate) const TX_PUSH_ENTRY: u16 = 22;
pub(crate) const TX_POP_ENTRY: u16 = 23;
pub(crate) const TX_SET_ENTRY_PROP: u16 = 24;
pub(crate) const TX_ADD_SECTION: u16 = 25;
pub(crate) const TX_SELECT_SECTION: u16 = 26;
pub(crate) const TX_SET_SECTION_PROP: u16 = 27;
pub(crate) const TX_MENU_ITEM_CREATE: u16 = 28;
pub(crate) const TX_MENU_ITEM_APPEND: u16 = 29;
pub(crate) const TX_MENUBAR_APPEND: u16 = 30;
pub(crate) const TX_CONTEXT_ATTACH: u16 = 31;
pub(crate) const TX_CONTEXT_ATTACH_NODE: u16 = 32;
pub(crate) const TX_SET_MENU_PROP: u16 = 33;
pub(crate) const TX_SHOW_FILE_DIALOG: u16 = 34;
/// The clipboard pair: one clip out, one privileged read in.
pub(crate) const TX_COPY: u16 = 35;
pub(crate) const TX_READ_CLIPBOARD: u16 = 36;
/// The head-of-batch undo group marker (docs/undo-plan.md D2).
pub(crate) const TX_UNDO_GROUP: u16 = 37;
/// The three text-range records (docs/ranges-plan.md D6). Byte offsets
/// on this channel; the core converts to the backend's unit before it
/// lowers (docs/ranges-units.md §7).
pub(crate) const TX_HIGHLIGHT_RANGES: u16 = 38;
pub(crate) const TX_SELECT_RANGE: u16 = 39;
pub(crate) const TX_REVEAL_RANGE: u16 = 40;
/// The save dialog's request (docs/save-plan.md D2). Its ANSWER is the
/// picker's — a file_dialog_result carrying one file or none — because
/// the two dialogs share one id space, one live slot and one result
/// grammar.
pub(crate) const TX_SHOW_SAVE_DIALOG: u16 = 41;
pub(crate) const TX_SET_BRAND_ACCENT: u16 = 42;
/// The brand typeface REQUEST (docs/styling-plan.md Slice 2b). Its
/// per-platform pairs ride the wire where the accent's never do: a
/// binding cannot resolve its platform (the JVM says "Linux" on
/// Android) but a lowering IS its platform.
pub(crate) const TX_SET_BRAND_TYPEFACE: u16 = 43;
/// The app's declared identity (docs/app-identity-plan.md). Uses the
/// typeface's mask-plus-always-written-slot convention, so the two
/// records decode the same way.
pub(crate) const TX_SET_APP_IDENTITY: u16 = 44;
/// The column header bar on a For's container: titles plus the sort
/// indicator, one atomic declaration (docs/tables-plan.md).
pub(crate) const TX_SET_COLUMN_HEADERS: u16 = 45;
/// The whole drawing on a canvas, one atomic declaration
/// (docs/canvas-plan.md §3.1).
pub(crate) const TX_SET_DRAWING: u16 = 46;
/// WHAT A CANVAS DOES WITH A TRACK BIGGER THAN ITS VIEWBOX
/// (docs/canvas-plan.md §3.2.1).
pub(crate) const TX_SET_SIZE_POLICY: u16 = 47;
pub(crate) const TX_CREATE_BREAKPOINT: u16 = 48;
/// The size-class vocabulary a breakpoint speaks (ruled 2026-08-31,
/// docs/adaptive-layout-plan.md D3): the guest names the CLASS, never a
/// width. `compact` is the only class a binding can spell today.
/// NONE is the metrics channel's "platform reports no size class" —
/// the core then derives the class from the width at
/// SIZE_CLASS_COMPACT_BELOW; iOS reports its own class and the
/// boundary is never consulted there.
pub(crate) const SIZE_CLASS_NONE: u32 = 0;
pub(crate) const SIZE_CLASS_COMPACT: u32 = 1;
pub(crate) const SIZE_CLASS_REGULAR: u32 = 2;
/// The kaya-owned boundary (Material's compact edge) for platforms
/// that report no class of their own.
pub(crate) const SIZE_CLASS_COMPACT_BELOW: f64 = 600.0;
/// `sorted`'s no-column sentinel (alert_choice's cancel precedent).
pub(crate) const SORT_NONE: u32 = u32::MAX;
/// `direction`'s two values, read only when `sorted` names a column.
pub(crate) const SORT_ASC: u32 = 0;
pub(crate) const SORT_DESC: u32 = 1;

// Apply record kinds (core -> presentation pump).
pub(crate) const APPLY_CREATE: u16 = 1;
pub(crate) const APPLY_SET_PROP: u16 = 2;
pub(crate) const APPLY_ADD_CHILD: u16 = 3;
pub(crate) const APPLY_MOUNT: u16 = 4;
pub(crate) const APPLY_DESTROY: u16 = 5;
pub(crate) const APPLY_MOVE_CHILD: u16 = 6;
pub(crate) const APPLY_COMMAND: u16 = 7;
pub(crate) const APPLY_SET_WINDOW_PROP: u16 = 8;
pub(crate) const APPLY_CREATE_WINDOW: u16 = 9;
pub(crate) const APPLY_DESTROY_WINDOW: u16 = 10;
pub(crate) const APPLY_PRESENT_ALERT: u16 = 11;
pub(crate) const APPLY_PUSH_ENTRY: u16 = 12;
pub(crate) const APPLY_POP_ENTRY: u16 = 13;
pub(crate) const APPLY_SET_ENTRY_PROP: u16 = 14;
pub(crate) const APPLY_ADD_SECTION: u16 = 15;
pub(crate) const APPLY_SELECT_SECTION: u16 = 16;
pub(crate) const APPLY_SET_SECTION_PROP: u16 = 17;
pub(crate) const APPLY_MENU_ITEM_CREATE: u16 = 18;
pub(crate) const APPLY_MENU_ITEM_APPEND: u16 = 19;
pub(crate) const APPLY_MENUBAR_APPEND: u16 = 20;
pub(crate) const APPLY_CONTEXT_ATTACH: u16 = 21;
pub(crate) const APPLY_CONTEXT_ATTACH_NODE: u16 = 22;
pub(crate) const APPLY_SET_MENU_PROP: u16 = 23;
pub(crate) const APPLY_PRESENT_FILE_DIALOG: u16 = 24;
pub(crate) const APPLY_COPY: u16 = 25;
pub(crate) const APPLY_READ_CLIPBOARD: u16 = 26;
/// Reset the focused editable's NATIVE undo history in this window
/// (docs/undo-plan.md A1). Targetless on purpose: the core does not know
/// what is focused and never will — the backends do, and each already
/// asks itself that question for role enablement.
pub(crate) const APPLY_CLEAR_UNDO: u16 = 27;
/// The three text-range records, apply side — NATIVE units.
pub(crate) const APPLY_HIGHLIGHT_RANGES: u16 = 28;
pub(crate) const APPLY_SELECT_RANGE: u16 = 29;
pub(crate) const APPLY_REVEAL_RANGE: u16 = 30;
pub(crate) const APPLY_PRESENT_SAVE_DIALOG: u16 = 31;
pub(crate) const APPLY_SET_BRAND: u16 = 32;
/// The brand typeface, unresolved: the request's body verbatim, because
/// the LOWERING is what resolves a family name (Slice 2b).
pub(crate) const APPLY_SET_TYPEFACE: u16 = 33;
/// The app's identity, uninspected: the declaration's body verbatim,
/// because the LOWERING is what decodes a picture (app-identity-plan I5).
pub(crate) const APPLY_SET_APP_IDENTITY: u16 = 34;
/// The header bar for the For's live container, with the core-minted
/// sort tag appended after the titles — { u32 tag_len; bytes } — which
/// the backend hands to kaya_emit_sort_requested verbatim on a header
/// click, exactly as a button's click tag rides (a stamped copy's
/// identity is a node id plus key path no backend can compute).
pub(crate) const APPLY_SET_COLUMN_HEADERS: u16 = 35;

/// The RASTER a canvas's declaration produced: premultiplied RGBA8
/// device pixels the backend blits (docs/canvas-plan.md §1.1). No op
/// crosses this channel.
pub(crate) const APPLY_SET_DRAWING: u16 = 36;

/// The stacked fold (docs/adaptive-layout-plan.md D7): { u64 child;
/// u64 table } — render the child inside the grown table's viewport as
/// scroll-away content above row 0; table 0 restores it. Core-derived
/// from a stack_when row's own shape; no guest record spells it.
pub(crate) const APPLY_FOLD: u16 = 37;

// Value types.
pub(crate) const VALUE_BOOL: u32 = 1;
pub(crate) const VALUE_I64: u32 = 2;
pub(crate) const VALUE_F64: u32 = 3;
pub(crate) const VALUE_STR: u32 = 4;
pub(crate) const VALUE_BLOB: u32 = 5;

// Widget kinds.
pub(crate) const KIND_COLUMN: u32 = 1;
pub(crate) const KIND_BUTTON: u32 = 2;
pub(crate) const KIND_LABEL: u32 = 3;
pub(crate) const KIND_ENTRY: u32 = 4;
pub(crate) const KIND_ROW: u32 = 5;
pub(crate) const KIND_CHECKBOX: u32 = 6;
pub(crate) const KIND_SLIDER: u32 = 7;
pub(crate) const KIND_IMAGE: u32 = 8;
pub(crate) const KIND_SCROLL: u32 = 9;
pub(crate) const KIND_PROGRESS: u32 = 10;
pub(crate) const KIND_SELECT: u32 = 11;
pub(crate) const KIND_RADIO: u32 = 12;
pub(crate) const KIND_GRID: u32 = 13;
pub(crate) const KIND_TEXTAREA: u32 = 14;
pub(crate) const KIND_CANVAS: u32 = 15;

// Draw opcodes (docs/canvas-plan.md §3.3). The op stream is a flat run
// of tagged values: one of these as an i64, then its operands.
pub(crate) const DRAW_MOVE_TO: i64 = 1;
pub(crate) const DRAW_LINE_TO: i64 = 2;
pub(crate) const DRAW_CLOSE: i64 = 3;
pub(crate) const DRAW_STROKE: i64 = 4;
pub(crate) const DRAW_FILL: i64 = 5;
pub(crate) const DRAW_FONT: i64 = 6;
pub(crate) const DRAW_TEXT: i64 = 7;

// Paint roles (§3.4). Resolved in the core, per appearance.
pub(crate) const PAINT_SERIES: i64 = 1;
pub(crate) const PAINT_SERIES_FILL: i64 = 2;
pub(crate) const PAINT_GRID: i64 = 3;
pub(crate) const PAINT_AXIS: i64 = 4;
pub(crate) const PAINT_GROUND: i64 = 5;

pub(crate) const FILL_NONZERO: i64 = 0;
pub(crate) const FILL_EVEN_ODD: i64 = 1;

// The size policy (§3.2.1): what a canvas does when layout gives it a
// track that is not its viewbox. `scale` is the default — the mode a
// guest that declares nothing gets.
pub(crate) const SIZE_POLICY_SCALE: u32 = 0;
pub(crate) const SIZE_POLICY_FIXED: u32 = 1;
pub(crate) const SIZE_POLICY_REDRAW: u32 = 2;
pub(crate) const SIZE_POLICY_TICK: u32 = 3;

// SVG's text-anchor and dominant-baseline.
pub(crate) const TEXT_ALIGN_START: i64 = 0;
pub(crate) const TEXT_ALIGN_MIDDLE: i64 = 1;
pub(crate) const TEXT_ALIGN_END: i64 = 2;
pub(crate) const TEXT_BASELINE_ALPHABETIC: i64 = 0;
pub(crate) const TEXT_BASELINE_MIDDLE: i64 = 1;
pub(crate) const TEXT_BASELINE_TOP: i64 = 2;
pub(crate) const TEXT_BASELINE_BOTTOM: i64 = 3;

/// The (value, name) table for every draw opcode, paint role, fill rule,
/// text align and text baseline — the second spelling of the five canvas
/// enums, read by the core's refusals. Not in the spec hash; held level by
/// `spec::tests::canvas_names_match_the_spec_enums` and, against the three
/// hand-copied surfaces, by tools/check-symbol-parity.py.
pub(crate) const DRAW_OPS: &[(i64, &str)] = &[
    (DRAW_MOVE_TO, "move_to"),
    (DRAW_LINE_TO, "line_to"),
    (DRAW_CLOSE, "close"),
    (DRAW_STROKE, "stroke"),
    (DRAW_FILL, "fill"),
    (DRAW_FONT, "font"),
    (DRAW_TEXT, "text"),
];

pub(crate) const PAINTS: &[(i64, &str)] = &[
    (PAINT_SERIES, "series"),
    (PAINT_SERIES_FILL, "series_fill"),
    (PAINT_GRID, "grid"),
    (PAINT_AXIS, "axis"),
    (PAINT_GROUND, "ground"),
];

pub(crate) const FILL_RULES: &[(i64, &str)] = &[(FILL_NONZERO, "nonzero"), (FILL_EVEN_ODD, "even_odd")];

/// The size policy's (value, name) table — the same second spelling the
/// five draw vocabularies have, and read by the core's own refusal when
/// a guest sends a number outside it.
pub(crate) const SIZE_POLICIES: &[(i64, &str)] = &[
    (SIZE_POLICY_SCALE as i64, "scale"),
    (SIZE_POLICY_FIXED as i64, "fixed"),
    (SIZE_POLICY_REDRAW as i64, "redraw"),
    (SIZE_POLICY_TICK as i64, "tick"),
];

pub(crate) const TEXT_ALIGNS: &[(i64, &str)] = &[
    (TEXT_ALIGN_START, "start"),
    (TEXT_ALIGN_MIDDLE, "middle"),
    (TEXT_ALIGN_END, "end"),
];

pub(crate) const TEXT_BASELINES: &[(i64, &str)] = &[
    (TEXT_BASELINE_ALPHABETIC, "alphabetic"),
    (TEXT_BASELINE_MIDDLE, "middle"),
    (TEXT_BASELINE_TOP, "top"),
    (TEXT_BASELINE_BOTTOM, "bottom"),
];

/// One canvas vocabulary's name for a value, or None for a value the
/// vocabulary does not carry. ONE lookup over all five tables: the
/// caller already names the table.
pub fn vocab_name(table: &[(i64, &'static str)], value: i64) -> Option<&'static str> {
    table.iter().find(|(v, _)| *v == value).map(|(_, n)| *n)
}

// Property keys.
pub(crate) const PROP_TEXT: u32 = 1;
pub(crate) const PROP_CHECKED: u32 = 2;
pub(crate) const PROP_VALUE: u32 = 3;
pub(crate) const PROP_MIN: u32 = 4;
pub(crate) const PROP_MAX: u32 = 5;
pub(crate) const PROP_SOURCE: u32 = 6;
pub(crate) const PROP_GROW: u32 = 7;
pub(crate) const PROP_SPACING: u32 = 8;
pub(crate) const PROP_ALIGN: u32 = 9;
pub(crate) const PROP_INDETERMINATE: u32 = 10;
pub(crate) const PROP_COLUMNS: u32 = 11;
/// The accessibility identifier (never spoken) and label (spoken).
pub(crate) const PROP_A11Y_ID: u32 = 12;
pub(crate) const PROP_A11Y_LABEL: u32 = 13;
pub(crate) const PROP_A11Y_HINT: u32 = 14;
/// Which clip representations a widget accepts, a mask over the `clip`
/// enum (docs/clipboard-plan.md §0). Per-widget because whether Paste
/// is live is the intersection of what the clipboard offers and what
/// the focused target takes.
pub(crate) const PROP_ACCEPTS: u32 = 15;
pub(crate) const PROP_ROLE: u32 = 16;
/// A container's own padding (the window inset one level down): DIP
/// between its bounds and its children, uniform all sides. Layout,
/// carried by the spacing kinds.
pub(crate) const PROP_INSET: u32 = 17;
pub(crate) const PROP_AXIS: u32 = 18;

/// The clip representation masks (spec enum "clip"). BIT POSITIONS, not
/// an ordinal: a copy carries several and a widget accepts several, so
/// both ride as a mask. The canonical order richest-first is files,
/// image, html, text — kaya defines it once rather than leaving each
/// app to get the wire's preference order right.
pub(crate) const CLIP_TEXT: u32 = 1;
pub(crate) const CLIP_HTML: u32 = 2;
pub(crate) const CLIP_IMAGE: u32 = 4;
pub(crate) const CLIP_FILES: u32 = 8;
pub(crate) const CLIP_CUSTOM: u32 = 16;

/// Window property ids (spec::WINDOW_PROPS) — their own namespace;
/// windows are not widgets.
pub(crate) const WPROP_TITLE: u32 = 1;
pub(crate) const WPROP_WIDTH: u32 = 2;
pub(crate) const WPROP_HEIGHT: u32 = 3;
pub(crate) const WPROP_VETO_CLOSE: u32 = 4;
pub(crate) const WPROP_SECTIONS_PRESENTATION: u32 = 5;
pub(crate) const WPROP_PANES: u32 = 6;
pub(crate) const WPROP_DIRTY: u32 = 7;
pub(crate) const WPROP_INSET: u32 = 8;

/// Section property ids (spec::SECTION_PROPS) — the third typed
/// surface table (see DESIGN.md, Sections).
pub(crate) const SPROP_TITLE: u32 = 1;
pub(crate) const SPROP_ICON: u32 = 2;
pub(crate) const SPROP_SYMBOL: u32 = 3;

/// Menu item kinds (spec enum "menu_kind"; DESIGN.md, Menus). `menu`
/// and `radio_group` are the grouping nodes.
pub(crate) const MENU_KIND_MENU: u32 = 1;
pub(crate) const MENU_KIND_ACTION: u32 = 2;
pub(crate) const MENU_KIND_TOGGLE: u32 = 3;
pub(crate) const MENU_KIND_RADIO_GROUP: u32 = 4;
pub(crate) const MENU_KIND_RADIO_OPTION: u32 = 5;
pub(crate) const MENU_KIND_SEPARATOR: u32 = 6;

/// Menu property ids (spec::MENU_PROPS) — their own typed surface
/// table, separate from widget/window/entry/section props.
pub(crate) const MPROP_LABEL: u32 = 1;
pub(crate) const MPROP_ENABLED: u32 = 2;
pub(crate) const MPROP_CHECKED: u32 = 3;
pub(crate) const MPROP_VALUE: u32 = 4;
pub(crate) const MPROP_ICON: u32 = 5;
pub(crate) const MPROP_PRIMARY: u32 = 6;
pub(crate) const MPROP_SHORTCUT: u32 = 7;
pub(crate) const MPROP_ROLE: u32 = 8;
pub(crate) const MPROP_SYMBOL: u32 = 9;

/// The sections_presentation enum's wire values (spec enum
/// "sections_presentation"): ADVISORY, the width/height precedent.
pub(crate) const SECTIONS_PRESENTATION_AUTO: u32 = 0;
pub(crate) const SECTIONS_PRESENTATION_BAR: u32 = 1;
pub(crate) const SECTIONS_PRESENTATION_SIDEBAR: u32 = 2;

/// The panes enum's wire values (spec enum "panes"): the declared
/// ceiling on side-by-side stack entries. VALUES ARE THE COUNTS
/// THEMSELVES (alert_choice's index precedent) — 0 is deliberately
/// unassigned so an unset default cannot alias a legal ceiling.
pub(crate) const PANES_ONE: u32 = 1;
pub(crate) const PANES_TWO: u32 = 2;
pub(crate) const PANES_THREE: u32 = 3;

/// Navigation-entry property ids (spec::ENTRY_PROPS) — their own
/// typed table, not WINDOW_PROPS with applicability checks (see
/// DESIGN.md, Navigation).
pub(crate) const EPROP_TITLE: u32 = 1;
pub(crate) const EPROP_INTERCEPT_BACK: u32 = 2;

/// The alert_choice enum's wire values (spec enum "alert_choice"):
/// action indices, and the deliberately-not-an-index cancel sentinel
/// every platform-native dismissal resolves to.
pub(crate) const ALERT_CHOICE_ACTION0: u32 = 0;
pub(crate) const ALERT_CHOICE_ACTION1: u32 = 1;
pub(crate) const ALERT_CHOICE_CANCEL: u32 = u32::MAX;

/// What kaya_open_picked opens a handle for (spec enum "file_mode").
/// Three modes cover every platform; writability is DISCOVERABLE but
/// never REQUESTABLE, so the open is fallible in ways the pick is not.
pub(crate) const FILE_MODE_READ: u32 = 0;
pub(crate) const FILE_MODE_WRITE: u32 = 1;
pub(crate) const FILE_MODE_READ_WRITE: u32 = 2;

/// The align enum's wire values (spec enum "align").
// The arrangement axis (docs/adaptive-layout-plan.md D1).
pub(crate) const AXIS_HORIZONTAL: u32 = 0;
pub(crate) const AXIS_VERTICAL: u32 = 1;
pub(crate) const ALIGN_START: u32 = 0;
pub(crate) const ALIGN_CENTER: u32 = 1;
pub(crate) const ALIGN_END: u32 = 2;
pub(crate) const ALIGN_STRETCH: u32 = 3;
pub(crate) const ALIGN_BASELINE: u32 = 4;

/// Which platform a per-platform brand value is for (spec enum
/// "platform"). ONE ENTRY PER BACKEND ROSTER ROW, not per operating
/// system: the roster is what reads these, so a tag no backend serves
/// would be a value no lowering could pick.
pub(crate) const PLATFORM_MAC: u32 = 1;
pub(crate) const PLATFORM_IOS: u32 = 2;
pub(crate) const PLATFORM_LINUX: u32 = 3;
pub(crate) const PLATFORM_WINDOWS: u32 = 4;
pub(crate) const PLATFORM_ANDROID: u32 = 5;

/// The platform vocabulary as one table, in wire order: `(id, name)`.
/// The NAME is what the root's wall prints, so the sentence comes from
/// the same place the values do.
pub(crate) const PLATFORMS: &[(u32, &str)] = &[
    (PLATFORM_MAC, "mac"),
    (PLATFORM_IOS, "ios"),
    (PLATFORM_LINUX, "linux"),
    (PLATFORM_WINDOWS, "windows"),
    (PLATFORM_ANDROID, "android"),
];

/// WHICH PLATFORM THIS CORE IS, as a tag. The apply record carries this
/// number so a lowering asks "is this row mine?" without keeping a
/// private copy of the vocabulary (the CLIP_* mirror trap). The core
/// may answer where a BINDING may not: a binding cannot tell (the JVM
/// says "Linux" on Android), this crate is compiled once per target.
pub fn this_platform() -> u32 {
    #[cfg(target_os = "macos")]
    {
        PLATFORM_MAC
    }
    #[cfg(target_os = "ios")]
    {
        PLATFORM_IOS
    }
    #[cfg(target_os = "linux")]
    {
        PLATFORM_LINUX
    }
    #[cfg(target_os = "windows")]
    {
        PLATFORM_WINDOWS
    }
    #[cfg(target_os = "android")]
    {
        PLATFORM_ANDROID
    }
    // No other target builds a backend; the compile-time assertion is
    // the cfg set above being exhaustive over the roster.
    #[cfg(not(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "linux",
        target_os = "windows",
        target_os = "android"
    )))]
    {
        compile_error!(
            "kaya: this_platform has no tag for this target — the platform \
             vocabulary is one entry per backend roster row"
        )
    }
}

/// The tag's name, or None when nothing in the vocabulary carries it.
pub fn platform_name(tag: i64) -> Option<&'static str> {
    u32::try_from(tag)
        .ok()
        .and_then(|t| PLATFORMS.iter().find(|(id, _)| *id == t).map(|(_, n)| *n))
}

pub(crate) const ROLE_DESTRUCTIVE: u32 = 1;
pub(crate) const ROLE_PROMINENT: u32 = 2;
pub(crate) const ROLE_HEADING: u32 = 3;
pub(crate) const ROLE_CAPTION: u32 = 4;

/// The semantic icon vocabulary's wire values (spec enum "symbol";
/// docs/styling-plan.md D6). APPEND-ONLY: every backend keys its
/// per-platform glyph table on these numbers.
pub(crate) const SYMBOL_ADD: u32 = 1;
pub(crate) const SYMBOL_REMOVE: u32 = 2;
pub(crate) const SYMBOL_DELETE: u32 = 3;
pub(crate) const SYMBOL_EDIT: u32 = 4;
pub(crate) const SYMBOL_DONE: u32 = 5;
pub(crate) const SYMBOL_CLOSE: u32 = 6;
pub(crate) const SYMBOL_SEARCH: u32 = 7;
pub(crate) const SYMBOL_SETTINGS: u32 = 8;
pub(crate) const SYMBOL_REFRESH: u32 = 9;
pub(crate) const SYMBOL_INFO: u32 = 10;
pub(crate) const SYMBOL_WARNING: u32 = 11;
pub(crate) const SYMBOL_BACK: u32 = 12;
pub(crate) const SYMBOL_FORWARD: u32 = 13;
pub(crate) const SYMBOL_MORE: u32 = 14;
pub(crate) const SYMBOL_COPY: u32 = 15;
pub(crate) const SYMBOL_PASTE: u32 = 16;
pub(crate) const SYMBOL_STAR: u32 = 17;
pub(crate) const SYMBOL_LOCK: u32 = 18;
pub(crate) const SYMBOL_PERSON: u32 = 19;
pub(crate) const SYMBOL_HOME: u32 = 20;

/// The vocabulary as one table, in wire order: `(id, semantic name)`.
/// The NAME is what a diagnostic prints and what the harness compares —
/// never a per-backend glyph string.
pub(crate) const SYMBOLS: &[(u32, &str)] = &[
    (SYMBOL_ADD, "add"),
    (SYMBOL_REMOVE, "remove"),
    (SYMBOL_DELETE, "delete"),
    (SYMBOL_EDIT, "edit"),
    (SYMBOL_DONE, "done"),
    (SYMBOL_CLOSE, "close"),
    (SYMBOL_SEARCH, "search"),
    (SYMBOL_SETTINGS, "settings"),
    (SYMBOL_REFRESH, "refresh"),
    (SYMBOL_INFO, "info"),
    (SYMBOL_WARNING, "warning"),
    (SYMBOL_BACK, "back"),
    (SYMBOL_FORWARD, "forward"),
    (SYMBOL_MORE, "more"),
    (SYMBOL_COPY, "copy"),
    (SYMBOL_PASTE, "paste"),
    (SYMBOL_STAR, "star"),
    (SYMBOL_LOCK, "lock"),
    (SYMBOL_PERSON, "person"),
    (SYMBOL_HOME, "home"),
];

/// The semantic name of a wire symbol value, or None if it is outside
/// the vocabulary. The root's wall and every diagnostic read it, so no
/// site spells the vocabulary a second time.
pub fn symbol_name(value: i64) -> Option<&'static str> {
    u32::try_from(value)
        .ok()
        .and_then(|v| SYMBOLS.iter().find(|(id, _)| *id == v).map(|(_, name)| *name))
}

// set_property sources.
pub(crate) const SOURCE_CONST: u32 = 0;
pub(crate) const SOURCE_SIGNAL: u32 = 1;
pub(crate) const SOURCE_ELEMENT: u32 = 2;

// One-shot commands.
pub(crate) const COMMAND_CLEAR: u32 = 1;
pub(crate) const COMMAND_FOCUS: u32 = 2;

fn pad8(n: usize) -> usize {
    (n + 7) & !7
}

// --- Reading -------------------------------------------------------------

struct Reader<'a> {
    buf: &'a [u8],
    at: usize,
    /// Resolves a wire blob handle to its bytes. Guest submissions
    /// resolve against the pending registration table; decoders with
    /// no blob context (unit tests over scalar records) pass a
    /// resolver that refuses, and any blob handle fails loudly.
    blobs: &'a dyn Fn(u64) -> Option<Arc<[u8]>>,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> &'a [u8] {
        let s = self
            .buf
            .get(self.at..self.at + n)
            .expect("kaya: truncated record in submitted transaction");
        self.at += n;
        s
    }
    fn u16(&mut self) -> u16 {
        u16::from_le_bytes(self.take(2).try_into().unwrap())
    }
    fn u32(&mut self) -> u32 {
        u32::from_le_bytes(self.take(4).try_into().unwrap())
    }
    fn u64(&mut self) -> u64 {
        u64::from_le_bytes(self.take(8).try_into().unwrap())
    }
    fn value(&mut self) -> Value {
        let ty = self.u32();
        let len = self.u32() as usize;
        let payload = self.take(len);
        let value = match ty {
            VALUE_BOOL => Value::Bool(payload[0] != 0),
            VALUE_I64 => {
                let v = i64::from_le_bytes(payload.try_into().unwrap());
                // The safe-integer contract's one wall (spec.rs's
                // MAX_SAFE_INTEGER): keys route through here too, so
                // an i64 identity past 2^53 is refused with its fix.
                assert!(
                    v.unsigned_abs() <= crate::spec::MAX_SAFE_INTEGER as u64,
                    "kaya: integer value {v} is outside ±(2^53 − 1) — kaya \
                     integers are counts and quantities (spec.rs's \
                     safe-integer contract); identity belongs in a string \
                     or an opaque tag, which round-trip any width"
                );
                Value::I64(v)
            }
            VALUE_F64 => Value::F64(f64::from_le_bytes(payload.try_into().unwrap())),
            VALUE_STR => Value::Str(
                std::str::from_utf8(payload)
                    .expect("kaya: string value is not UTF-8")
                    .to_owned(),
            ),
            VALUE_BLOB => {
                let handle = u64::from_le_bytes(payload.try_into().unwrap());
                Value::Blob(Blob((self.blobs)(handle).unwrap_or_else(|| {
                    panic!(
                        "kaya: blob handle {handle} is not registered — handles \
                         are consumed by one submit; register the bytes again \
                         for each transaction that references them"
                    )
                })))
            }
            other => panic!("kaya: unknown value type {other}"),
        };
        self.at = pad8(self.at);
        value
    }

    /// A key path: { u32 count; u32 reserved; count values }.
    fn path(&mut self) -> Path {
        let count = self.u32() as usize;
        let _reserved = self.u32();
        (0..count).map(|_| self.value()).collect()
    }

    /// A record: same shape as a path — { u32 count; u32 reserved;
    /// count values } — but the values are one entry's fields, not keys.
    fn record(&mut self) -> Record {
        self.path()
    }

    /// A schema: { u32 count; u32 reserved; count u32 value-type tags },
    /// padded to 8.
    /// One field-type list per variant of the element sum; a record
    /// collection is the one-variant case.
    fn variants(&mut self) -> Vec<Vec<ValueType>> {
        let count = self.u32() as usize;
        let _reserved = self.u32();
        let variants = (0..count)
            .map(|_| {
                let fields = self.u32() as usize;
                (0..fields).map(|_| value_type(self.u32())).collect()
            })
            .collect();
        self.at = pad8(self.at);
        variants
    }
}

fn value_type(raw: u32) -> ValueType {
    match raw {
        VALUE_BOOL => ValueType::Bool,
        VALUE_I64 => ValueType::I64,
        VALUE_F64 => ValueType::F64,
        VALUE_STR => ValueType::Str,
        VALUE_BLOB => ValueType::Blob,
        other => panic!("kaya: unknown value type {other} in schema"),
    }
}

/// Used by the test-only transaction encoder today; foreign guests
/// write their own tags from the generated constants.
#[cfg_attr(not(test), allow(dead_code))]
pub fn value_type_raw(ty: ValueType) -> u32 {
    match ty {
        ValueType::Bool => VALUE_BOOL,
        ValueType::I64 => VALUE_I64,
        ValueType::F64 => VALUE_F64,
        ValueType::Str => VALUE_STR,
        ValueType::Blob => VALUE_BLOB,
    }
}

fn command_kind(raw: u32) -> CommandKind {
    match raw {
        COMMAND_CLEAR => CommandKind::Clear,
        COMMAND_FOCUS => CommandKind::Focus,
        other => panic!("kaya: unknown command {other}"),
    }
}

fn command_raw(command: CommandKind) -> u32 {
    match command {
        CommandKind::Clear => COMMAND_CLEAR,
        CommandKind::Focus => COMMAND_FOCUS,
    }
}

fn widget_kind(raw: u32) -> WidgetKind {
    match raw {
        KIND_COLUMN => WidgetKind::Column,
        KIND_BUTTON => WidgetKind::Button,
        KIND_LABEL => WidgetKind::Label,
        KIND_ENTRY => WidgetKind::Entry,
        KIND_ROW => WidgetKind::Row,
        KIND_CHECKBOX => WidgetKind::Checkbox,
        KIND_SLIDER => WidgetKind::Slider,
        KIND_IMAGE => WidgetKind::Image,
        KIND_SCROLL => WidgetKind::Scroll,
        KIND_PROGRESS => WidgetKind::Progress,
        KIND_SELECT => WidgetKind::Select,
        KIND_RADIO => WidgetKind::Radio,
        KIND_GRID => WidgetKind::Grid,
        KIND_TEXTAREA => WidgetKind::Textarea,
        KIND_CANVAS => WidgetKind::Canvas,
        other => panic!("kaya: unknown widget kind {other}"),
    }
}

fn prop(raw: u32) -> Prop {
    match raw {
        PROP_TEXT => Prop::Text,
        PROP_CHECKED => Prop::Checked,
        PROP_VALUE => Prop::Value,
        PROP_MIN => Prop::Min,
        PROP_MAX => Prop::Max,
        PROP_SOURCE => Prop::Source,
        PROP_GROW => Prop::Grow,
        PROP_SPACING => Prop::Spacing,
        PROP_ALIGN => Prop::Align,
        PROP_INDETERMINATE => Prop::Indeterminate,
        PROP_COLUMNS => Prop::Columns,
        PROP_A11Y_ID => Prop::A11yId,
        PROP_A11Y_LABEL => Prop::A11yLabel,
        PROP_A11Y_HINT => Prop::A11yHint,
        PROP_ACCEPTS => Prop::Accepts,
        PROP_ROLE => Prop::Role,
        PROP_INSET => Prop::Inset,
        PROP_AXIS => Prop::Axis,
        other => panic!("kaya: unknown property {other}"),
    }
}

fn window_prop(raw: u32) -> WindowProp {
    match raw {
        WPROP_TITLE => WindowProp::Title,
        WPROP_WIDTH => WindowProp::Width,
        WPROP_HEIGHT => WindowProp::Height,
        WPROP_VETO_CLOSE => WindowProp::VetoClose,
        WPROP_SECTIONS_PRESENTATION => WindowProp::SectionsPresentation,
        WPROP_PANES => WindowProp::Panes,
        WPROP_DIRTY => WindowProp::Dirty,
        WPROP_INSET => WindowProp::Inset,
        other => panic!("kaya: unknown window property {other}"),
    }
}

fn window_prop_raw(p: WindowProp) -> u32 {
    match p {
        WindowProp::Title => WPROP_TITLE,
        WindowProp::Width => WPROP_WIDTH,
        WindowProp::Height => WPROP_HEIGHT,
        WindowProp::VetoClose => WPROP_VETO_CLOSE,
        WindowProp::SectionsPresentation => WPROP_SECTIONS_PRESENTATION,
        WindowProp::Panes => WPROP_PANES,
        WindowProp::Dirty => WPROP_DIRTY,
        WindowProp::Inset => WPROP_INSET,
    }
}

fn section_prop(raw: u32) -> SectionProp {
    match raw {
        SPROP_TITLE => SectionProp::Title,
        SPROP_ICON => SectionProp::Icon,
        SPROP_SYMBOL => SectionProp::Symbol,
        other => panic!("kaya: unknown section property {other}"),
    }
}

fn section_prop_raw(p: SectionProp) -> u32 {
    match p {
        SectionProp::Title => SPROP_TITLE,
        SectionProp::Icon => SPROP_ICON,
        SectionProp::Symbol => SPROP_SYMBOL,
    }
}

fn menu_kind(raw: u32) -> MenuItemKind {
    match raw {
        MENU_KIND_MENU => MenuItemKind::Menu,
        MENU_KIND_ACTION => MenuItemKind::Action,
        MENU_KIND_TOGGLE => MenuItemKind::Toggle,
        MENU_KIND_RADIO_GROUP => MenuItemKind::RadioGroup,
        MENU_KIND_RADIO_OPTION => MenuItemKind::RadioOption,
        MENU_KIND_SEPARATOR => MenuItemKind::Separator,
        other => panic!("kaya: unknown menu kind {other}"),
    }
}

fn menu_kind_raw(kind: MenuItemKind) -> u32 {
    match kind {
        MenuItemKind::Menu => MENU_KIND_MENU,
        MenuItemKind::Action => MENU_KIND_ACTION,
        MenuItemKind::Toggle => MENU_KIND_TOGGLE,
        MenuItemKind::RadioGroup => MENU_KIND_RADIO_GROUP,
        MenuItemKind::RadioOption => MENU_KIND_RADIO_OPTION,
        MenuItemKind::Separator => MENU_KIND_SEPARATOR,
    }
}

fn menu_prop(raw: u32) -> MenuProp {
    match raw {
        MPROP_LABEL => MenuProp::Label,
        MPROP_ENABLED => MenuProp::Enabled,
        MPROP_CHECKED => MenuProp::Checked,
        MPROP_VALUE => MenuProp::Value,
        MPROP_ICON => MenuProp::Icon,
        MPROP_PRIMARY => MenuProp::Primary,
        MPROP_SHORTCUT => MenuProp::Shortcut,
        MPROP_ROLE => MenuProp::Role,
        MPROP_SYMBOL => MenuProp::Symbol,
        other => panic!("kaya: unknown menu property {other}"),
    }
}

fn menu_prop_raw(p: MenuProp) -> u32 {
    match p {
        MenuProp::Label => MPROP_LABEL,
        MenuProp::Enabled => MPROP_ENABLED,
        MenuProp::Checked => MPROP_CHECKED,
        MenuProp::Value => MPROP_VALUE,
        MenuProp::Icon => MPROP_ICON,
        MenuProp::Primary => MPROP_PRIMARY,
        MenuProp::Shortcut => MPROP_SHORTCUT,
        MenuProp::Role => MPROP_ROLE,
        MenuProp::Symbol => MPROP_SYMBOL,
    }
}

fn entry_prop(raw: u32) -> EntryProp {
    match raw {
        EPROP_TITLE => EntryProp::Title,
        EPROP_INTERCEPT_BACK => EntryProp::InterceptBack,
        other => panic!("kaya: unknown entry property {other}"),
    }
}

fn entry_prop_raw(p: EntryProp) -> u32 {
    match p {
        EntryProp::Title => EPROP_TITLE,
        EntryProp::InterceptBack => EPROP_INTERCEPT_BACK,
    }
}

/// Decode a submitted transaction buffer with no blob context: any
/// blob handle fails loudly. The scalar path for tests and callers
/// that cannot see the registration table.
#[cfg_attr(not(test), allow(dead_code))]
pub fn decode_transaction(buf: &[u8]) -> Transaction {
    decode_transaction_with_blobs(buf, &|_| None)
}

/// Decode a submitted transaction buffer, resolving blob handles
/// through `blobs` (the pending registration table at the submit
/// boundary). Panics on malformed input; a bad buffer is a broken
/// binding and the failure should be loud.
pub fn decode_transaction_with_blobs(
    buf: &[u8],
    blobs: &dyn Fn(u64) -> Option<Arc<[u8]>>,
) -> Transaction {
    assert!(buf.len() % 8 == 0, "kaya: transaction length not 8-aligned");
    let mut ops = Vec::new();
    let mut at = 0;
    while at < buf.len() {
        let mut r = Reader { buf, at, blobs };
        let size = r.u32() as usize;
        let kind = r.u16();
        let _flags = r.u16();
        assert!(
            size >= HEADER_SIZE && size % 8 == 0 && at + size <= buf.len(),
            "kaya: bad record size {size} at offset {at}"
        );
        ops.push(match kind {
            TX_CREATE_SIGNAL => TxOp::CreateSignal {
                id: SignalId(r.u64()),
                initial: r.value(),
            },
            TX_WRITE_SIGNAL => TxOp::WriteSignal {
                id: SignalId(r.u64()),
                value: r.value(),
            },
            TX_CREATE_WIDGET => TxOp::CreateWidget {
                id: WidgetId(r.u64()),
                kind: widget_kind(r.u32()),
            },
            TX_SET_PROPERTY => {
                let widget = WidgetId(r.u64());
                let p = prop(r.u32());
                let source = r.u32();
                let value = match source {
                    SOURCE_CONST => PropValue::Const(r.value()),
                    SOURCE_SIGNAL => PropValue::Signal(SignalId(r.u64())),
                    SOURCE_ELEMENT => {
                        let level = r.u32();
                        let field = r.u32();
                        PropValue::Element { level, field }
                    }
                    other => panic!("kaya: unknown property source {other}"),
                };
                TxOp::SetProperty {
                    widget,
                    prop: p,
                    value,
                }
            }
            TX_ADD_CHILD => TxOp::AddChild {
                parent: WidgetId(r.u64()),
                child: WidgetId(r.u64()),
            },
            TX_MOUNT => TxOp::Mount {
                window: WindowId(r.u64()),
                root: WidgetId(r.u64()),
            },
            TX_CREATE_COLLECTION => TxOp::CreateCollection {
                id: CollectionId(r.u64()),
                variants: r.variants(),
            },
            TX_COLLECTION_INSERT => TxOp::CollectionInsert {
                id: CollectionId(r.u64()),
                path: r.path(),
                key: r.value(),
                variant: {
                    let variant = r.u32();
                    let _reserved = r.u32();
                    variant
                },
                record: r.record(),
            },
            TX_COLLECTION_UPDATE => TxOp::CollectionUpdate {
                id: CollectionId(r.u64()),
                path: r.path(),
                key: r.value(),
                variant: {
                    let variant = r.u32();
                    let _reserved = r.u32();
                    variant
                },
                record: r.record(),
            },
            TX_COLLECTION_UPDATE_FIELD => {
                let id = CollectionId(r.u64());
                let path = r.path();
                let key = r.value();
                let field = r.u32();
                let variant = r.u32();
                TxOp::CollectionUpdateField {
                    id,
                    path,
                    key,
                    variant,
                    field,
                    value: r.value(),
                }
            }
            TX_COLLECTION_MOVE => TxOp::CollectionMove {
                id: CollectionId(r.u64()),
                path: r.path(),
                key: r.value(),
                before: {
                    let mut anchors = r.path();
                    assert!(
                        anchors.len() <= 1,
                        "kaya: collection_move carries at most one anchor key"
                    );
                    anchors.pop()
                },
            },
            TX_COLLECTION_REMOVE => TxOp::CollectionRemove {
                id: CollectionId(r.u64()),
                path: r.path(),
                key: r.value(),
            },
            TX_CREATE_FOR => TxOp::CreateFor {
                id: r.u64(),
                collection: CollectionId(r.u64()),
            },
            TX_CREATE_WHEN => TxOp::CreateWhen {
                id: r.u64(),
                signal: SignalId(r.u64()),
            },
            TX_TEMPLATE_END => TxOp::TemplateEnd,
            TX_VARIANT_CASE => TxOp::VariantCase {
                variant: {
                    let variant = r.u32();
                    let _reserved = r.u32();
                    variant
                },
            },
            TX_WIDGET_COMMAND => TxOp::WidgetCommand {
                widget: WidgetId(r.u64()),
                command: {
                    let command = command_kind(r.u32());
                    let _reserved = r.u32();
                    command
                },
            },
            TX_SET_WINDOW_PROP => {
                let window = WindowId(r.u64());
                let p = window_prop(r.u32());
                let source = r.u32();
                let value = match source {
                    SOURCE_CONST => PropValue::Const(r.value()),
                    SOURCE_SIGNAL => PropValue::Signal(SignalId(r.u64())),
                    SOURCE_ELEMENT => {
                        panic!("kaya: window properties cannot bind element sources")
                    }
                    other => panic!("kaya: unknown property source {other}"),
                };
                TxOp::SetWindowProp {
                    window,
                    prop: p,
                    value,
                }
            }
            TX_CREATE_WINDOW => TxOp::CreateWindow {
                window: WindowId(r.u64()),
            },
            TX_DESTROY_WINDOW => TxOp::DestroyWindow {
                window: WindowId(r.u64()),
            },
            TX_SHOW_ALERT => {
                let window = WindowId(r.u64());
                let alert = AlertId(r.u64());
                let actions_n = r.u32();
                let _reserved = r.u32();
                let title = alert_str(r.value(), "title");
                let message = alert_str(r.value(), "message");
                let action0 = alert_str(r.value(), "action0");
                let action1 = alert_str(r.value(), "action1");
                let cancel = alert_str(r.value(), "cancel");
                if actions_n > 2 {
                    panic!("kaya: show_alert carries {actions_n} actions (the cap is 2)");
                }
                // Slots beyond the count ride empty and are dropped
                // here; the spec is authoritative that they carry
                // nothing.
                let mut actions = Vec::with_capacity(actions_n as usize);
                if actions_n >= 1 {
                    actions.push(action0);
                }
                if actions_n == 2 {
                    actions.push(action1);
                }
                TxOp::ShowAlert(AlertSpec { window, alert, title, message, actions, cancel })
            }
            TX_COPY => TxOp::Copy(read_clip(&mut r)),
            TX_READ_CLIPBOARD => {
                let request = r.u64();
                let accepting = clip_str(Some(r.value()), "accept list");
                TxOp::ReadClipboard { request, accepting }
            }
            TX_UNDO_GROUP => {
                let window = WindowId(r.u64());
                let label = match r.value() {
                    Value::Str(s) => s,
                    other => panic!("kaya: undo group label is {other:?}, wanted a string"),
                };
                TxOp::UndoGroup { window, label }
            }
            TX_HIGHLIGHT_RANGES => {
                let widget = WidgetId(r.u64());
                let count = r.u32() as usize;
                let _reserved = r.u32();
                // The offsets ride as one flat Values list read IN PAIRS
                // — start then end. The declared `count` and the list's
                // own length must agree, or half a set gets painted.
                let flat = r.record();
                assert!(
                    flat.len() == count * 2,
                    "kaya: highlight_ranges declares {count} ranges but carries {} \
                     offsets (two per range)",
                    flat.len()
                );
                let ranges = flat
                    .chunks_exact(2)
                    .map(|pair| TextRange::new(range_offset(&pair[0]), range_offset(&pair[1])))
                    .collect();
                TxOp::HighlightRanges { widget, ranges }
            }
            TX_SELECT_RANGE => TxOp::SelectRange {
                widget: WidgetId(r.u64()),
                range: TextRange::new(r.u64(), r.u64()),
            },
            TX_REVEAL_RANGE => TxOp::RevealRange {
                widget: WidgetId(r.u64()),
                range: TextRange::new(r.u64(), r.u64()),
            },
            TX_SET_BRAND_ACCENT => {
                let seed = r.u32();
                let mask = r.u32();
                let light_raw = r.u32();
                let dark_raw = r.u32();
                TxOp::SetBrandAccent {
                    seed,
                    light: (mask & 1 != 0).then_some(light_raw),
                    dark: (mask & 2 != 0).then_some(dark_raw),
                }
            }
            TX_SET_BRAND_TYPEFACE => {
                let mask = r.u32();
                // The apply record's platform stamp sits here; on the tx
                // side it is reserved, because a guest cannot name its
                // platform and is never asked to.
                let _reserved = r.u32();
                let family = match r.value() {
                    Value::Str(s) => s,
                    other => panic!(
                        "kaya: set_brand_typeface family is {other:?}, wanted a string"
                    ),
                };
                // The filters' pair encoding, one tier over: an I64
                // platform tag then that platform's family, read in
                // twos. Same shape, so the same odd-count refusal.
                let flat = r.record();
                assert!(
                    flat.len() % 2 == 0,
                    "kaya: set_brand_typeface carries {} platform values (pairs of \
                     platform tag and family, so an even count)",
                    flat.len()
                );
                let platforms = flat
                    .chunks_exact(2)
                    .map(|pair| {
                        let tag = match &pair[0] {
                            Value::I64(v) => *v,
                            other => panic!(
                                "kaya: set_brand_typeface platform tag is {other:?}, \
                                 wanted one of the platform enum's values"
                            ),
                        };
                        let family = match &pair[1] {
                            Value::Str(s) => s.clone(),
                            other => panic!(
                                "kaya: set_brand_typeface per-platform family is \
                                 {other:?}, wanted a string"
                            ),
                        };
                        let tag = u32::try_from(tag).unwrap_or_else(|_| {
                            panic!(
                                "kaya: set_brand_typeface platform tag {tag} is not in \
                                 the platform vocabulary (mac/ios/linux/windows/android)"
                            )
                        });
                        (tag, family)
                    })
                    .collect();
                // THE FONT SLOT IS ALWAYS WRITTEN, and the mask is what
                // says whether it means anything: an absent font rides
                // as an empty Str, so the record's field count never
                // varies with the payload (the accent's mask, verbatim).
                let font = match (mask & 1 != 0, r.value()) {
                    (true, Value::Blob(b)) => Some(b),
                    (true, other) => panic!(
                        "kaya: set_brand_typeface says a font blob is present but \
                         carries {other:?}"
                    ),
                    // THE OTHER DIRECTION IS LOUD TOO: a clear mask bit
                    // over a real blob would drop the font silently.
                    (false, Value::Blob(_)) => panic!(
                        "kaya: set_brand_typeface carries a font blob but its mask \
                         bit says none is present — the encoding disagrees with \
                         itself and the font would be silently dropped"
                    ),
                    (false, _) => None,
                };
                TxOp::SetBrandTypeface(crate::protocol::TypefaceRequest {
                    family,
                    platforms,
                    font,
                })
            }
            TX_SET_APP_IDENTITY => {
                let mask = r.u32();
                let _reserved = r.u32();
                let name = match r.value() {
                    Value::Str(s) => s,
                    other => panic!(
                        "kaya: set_app_identity name is {other:?}, wanted a string"
                    ),
                };
                // THE ICON SLOT IS ALWAYS WRITTEN and the mask says
                // whether it means anything — the typeface's convention
                // verbatim, including BOTH directions of the
                // disagreement.
                let icon = match (mask & 1 != 0, r.value()) {
                    (true, Value::Blob(b)) => Some(b),
                    (true, other) => panic!(
                        "kaya: set_app_identity says an icon blob is present but \
                         carries {other:?}"
                    ),
                    (false, Value::Blob(_)) => panic!(
                        "kaya: set_app_identity carries an icon blob but its mask \
                         bit says none is present — the encoding disagrees with \
                         itself and the icon would be silently dropped"
                    ),
                    (false, _) => None,
                };
                TxOp::SetAppIdentity(crate::protocol::AppIdentity { name, icon })
            }
            TX_CREATE_BREAKPOINT => {
                let window = WindowId(r.u64());
                let when = match r.value() {
                    Value::I64(n) => n,
                    other => {
                        panic!(
                            "kaya: create_breakpoint's size class is {other:?}, \
                             wanted i64 (SIZE_CLASS_COMPACT)"
                        )
                    }
                };
                let n = r.u32() as usize;
                let _reserved = r.u32();
                let flat = r.record();
                assert!(
                    flat.len() == n * 3,
                    "kaya: create_breakpoint declares {n} setters but carries {} values",
                    flat.len()
                );
                // Widgets, then props, then values — thirds by position,
                // the encode's contract.
                let setters = (0..n)
                    .map(|i| {
                        let w = match &flat[i] {
                            Value::I64(x) => WidgetId(*x as u64),
                            other => panic!(
                                "kaya: create_breakpoint setter {i}'s widget is {other:?}, \
                                 wanted i64"
                            ),
                        };
                        let p = match &flat[n + i] {
                            Value::I64(x) => prop(*x as u32),
                            other => panic!(
                                "kaya: create_breakpoint setter {i}'s prop is {other:?}, \
                                 wanted i64"
                            ),
                        };
                        (w, p, flat[2 * n + i].clone())
                    })
                    .collect();
                TxOp::CreateBreakpoint { window, when, setters }
            }
            TX_SET_COLUMN_HEADERS => {
                let widget = WidgetId(r.u64());
                let sorted = r.u32();
                let direction = r.u32();
                let count = r.u32() as usize;
                let path_len = r.u32() as usize;
                // KEYS FIRST, then titles — sort_requested's identity
                // convention pointed the other way — and both declared
                // lengths must agree with the list's own, or a header
                // renders with the wrong arity on some platform
                // (highlight_ranges' rule).
                let mut flat = r.record();
                assert!(
                    flat.len() == path_len + count,
                    "kaya: set_column_headers declares {path_len} keys and {count} columns \
                     but carries {} values",
                    flat.len()
                );
                let titles = flat
                    .split_off(path_len)
                    .into_iter()
                    .map(|v| match v {
                        Value::Str(s) => s,
                        other => panic!("kaya: a column title is {other:?}, wanted a string"),
                    })
                    .collect();
                TxOp::SetColumnHeaders { widget, sorted, direction, path: flat, titles }
            }
            TX_SET_DRAWING => {
                let widget = WidgetId(r.u64());
                let vb_w = match r.value() {
                    Value::F64(n) => n,
                    other => panic!("kaya: set_drawing's viewbox width is {other:?}, wanted f64"),
                };
                let vb_h = match r.value() {
                    Value::F64(n) => n,
                    other => panic!("kaya: set_drawing's viewbox height is {other:?}, wanted f64"),
                };
                let count = r.u32() as usize;
                let path_len = r.u32() as usize;
                // KEYS FIRST, then the op stream — set_column_headers'
                // convention verbatim — and both declared lengths must
                // agree with the list's own, or the fold walks operands
                // belonging to a key.
                let mut flat = r.record();
                assert!(
                    flat.len() == path_len + count,
                    "kaya: set_drawing declares {path_len} keys and {count} op values \
                     but carries {} values",
                    flat.len()
                );
                let ops = flat.split_off(path_len);
                TxOp::SetDrawing { widget, viewbox: (vb_w, vb_h), path: flat, ops }
            }
            TX_SET_SIZE_POLICY => {
                let widget = WidgetId(r.u64());
                let policy = r.u32();
                let _reserved = r.u32();
                TxOp::SetSizePolicy { widget, policy }
            }
            TX_SHOW_SAVE_DIALOG => {
                let window = WindowId(r.u64());
                let dialog = crate::protocol::FileDialogId(r.u64());
                let suggested_name = match r.value() {
                    Value::Str(s) => s,
                    other => panic!(
                        "kaya: show_save_dialog suggested_name is {other:?}, wanted a string"
                    ),
                };
                // The picker's filter encoding verbatim — pairs of label
                // and extensions, read in twos.
                let flat = r.record();
                assert!(
                    flat.len() % 2 == 0,
                    "kaya: show_save_dialog carries {} filter values (pairs of \
                     label and extensions, so an even count)",
                    flat.len()
                );
                let filters = flat
                    .chunks_exact(2)
                    .map(|pair| (filter_str(&pair[0], "label"), filter_str(&pair[1], "extensions")))
                    .collect();
                TxOp::ShowSaveDialog(crate::protocol::SaveDialogSpec {
                    window,
                    dialog,
                    suggested_name,
                    filters,
                })
            }
            TX_SHOW_FILE_DIALOG => {
                let window = WindowId(r.u64());
                let dialog = crate::protocol::FileDialogId(r.u64());
                let multiple = r.u32() != 0;
                let _reserved = r.u32();
                // Filters ride as one flat Values read IN PAIRS — label
                // then extensions. Reading in groups is the whole
                // encoding; a trailing half-pair is a broken binding, so
                // it fails here rather than silently dropping a filter.
                let flat = r.record();
                assert!(
                    flat.len() % 2 == 0,
                    "kaya: show_file_dialog carries {} filter values (pairs of \
                     label and extensions, so an even count)",
                    flat.len()
                );
                let filters = flat
                    .chunks_exact(2)
                    .map(|pair| {
                        (filter_str(&pair[0], "label"), filter_str(&pair[1], "extensions"))
                    })
                    .collect();
                TxOp::ShowFileDialog(crate::protocol::FileDialogSpec {
                    window,
                    dialog,
                    multiple,
                    filters,
                })
            }
            TX_PUSH_ENTRY => TxOp::PushEntry {
                window: WindowId(r.u64()),
                entry: WindowId(r.u64()),
            },
            TX_POP_ENTRY => TxOp::PopEntry {
                window: WindowId(r.u64()),
            },
            TX_SET_ENTRY_PROP => {
                let entry = WindowId(r.u64());
                let p = entry_prop(r.u32());
                let source = r.u32();
                let value = match source {
                    SOURCE_CONST => PropValue::Const(r.value()),
                    SOURCE_SIGNAL => PropValue::Signal(SignalId(r.u64())),
                    SOURCE_ELEMENT => {
                        panic!("kaya: entry properties cannot bind element sources")
                    }
                    other => panic!("kaya: unknown property source {other}"),
                };
                TxOp::SetEntryProp {
                    entry,
                    prop: p,
                    value,
                }
            }
            TX_ADD_SECTION => TxOp::AddSection {
                window: WindowId(r.u64()),
                section: WindowId(r.u64()),
            },
            TX_SELECT_SECTION => TxOp::SelectSection {
                window: WindowId(r.u64()),
                section: WindowId(r.u64()),
            },
            TX_SET_SECTION_PROP => {
                let section = WindowId(r.u64());
                let p = section_prop(r.u32());
                let source = r.u32();
                let value = match source {
                    SOURCE_CONST => PropValue::Const(r.value()),
                    SOURCE_SIGNAL => PropValue::Signal(SignalId(r.u64())),
                    SOURCE_ELEMENT => {
                        panic!("kaya: section properties cannot bind element sources")
                    }
                    other => panic!("kaya: unknown property source {other}"),
                };
                TxOp::SetSectionProp {
                    section,
                    prop: p,
                    value,
                }
            }
            TX_MENU_ITEM_CREATE => TxOp::MenuItemCreate {
                item: MenuItemId(r.u64()),
                kind: {
                    let kind = menu_kind(r.u32());
                    let _reserved = r.u32();
                    kind
                },
            },
            TX_MENU_ITEM_APPEND => TxOp::MenuItemAppend {
                parent: MenuItemId(r.u64()),
                child: MenuItemId(r.u64()),
            },
            TX_MENUBAR_APPEND => TxOp::MenubarAppend {
                window: WindowId(r.u64()),
                item: MenuItemId(r.u64()),
            },
            TX_CONTEXT_ATTACH => TxOp::ContextAttach {
                widget: WidgetId(r.u64()),
                item: MenuItemId(r.u64()),
            },
            TX_CONTEXT_ATTACH_NODE => TxOp::ContextAttachNode {
                node: TemplateNodeId(r.u64()),
                item: MenuItemId(r.u64()),
            },
            TX_SET_MENU_PROP => {
                let item = MenuItemId(r.u64());
                let p = menu_prop(r.u32());
                let source = r.u32();
                let value = match source {
                    SOURCE_CONST => PropValue::Const(r.value()),
                    SOURCE_SIGNAL => PropValue::Signal(SignalId(r.u64())),
                    SOURCE_ELEMENT => {
                        panic!("kaya: menu properties cannot bind element sources")
                    }
                    other => panic!("kaya: unknown property source {other}"),
                };
                TxOp::SetMenuProp {
                    item,
                    prop: p,
                    value,
                }
            }
            other => panic!("kaya: unknown transaction record kind {other}"),
        });
        at += size;
    }
    ops
}

// --- Alerts ----------------------------------------------------------------

/// The five Str slots of an alert record, in wire order — action
/// slots beyond the count ride empty (the count is authoritative).
fn alert_value_slots(spec: &AlertSpec) -> [String; 5] {
    [
        spec.title.clone(),
        spec.message.clone(),
        spec.actions.first().cloned().unwrap_or_default(),
        spec.actions.get(1).cloned().unwrap_or_default(),
        spec.cancel.clone(),
    ]
}

/// One end of a declared range, off the flat Values list.
///
/// I64 AND NOT U64 ON THE WIRE, because the wire's scalar vocabulary has
/// no unsigned integer — every binding's integer is signed, so a guest
/// with a bug writes a negative one and it must fail HERE rather than
/// wrap into a 2^64-sized offset that the length check would then pass.
fn range_offset(v: &Value) -> u64 {
    match v {
        Value::I64(n) if *n >= 0 => *n as u64,
        Value::I64(n) => panic!("kaya: a text range offset is {n}, which is negative"),
        other => panic!("kaya: a text range offset is {other:?}, wanted an integer"),
    }
}

fn alert_str(v: Value, field: &str) -> String {
    match v {
        Value::Str(s) => s,
        other => panic!("kaya: show_alert {field} must be a Str value, got {other:?}"),
    }
}

/// One half of a filter pair. BOTH DIALOGS READ IT — the picker and the
/// save request carry the same advisory encoding, so the refusal for a
/// non-Str filter is written once and cannot drift between them.
fn filter_str(v: &Value, what: &str) -> String {
    match v {
        Value::Str(s) => s.clone(),
        other => panic!("kaya: filter {what} is {other:?}, wanted a string"),
    }
}

/// The alert_result occurrence body: { u64 alert; u32 choice; u32
/// reserved }.
pub(crate) fn alert_result_body(alert: AlertId, choice: AlertChoice) -> [u8; 16] {
    let mut b = [0u8; 16];
    b[..8].copy_from_slice(&alert.0.to_le_bytes());
    b[8..12].copy_from_slice(&alert_choice_raw(choice).to_le_bytes());
    b
}

/// The picker's answer on the wire: dialog id, count, reserved, then
/// `count` files as THREE consecutive values each — I64 handle, Str
/// name, Str local_path. Cancel is count zero.
pub(crate) fn file_dialog_result_body(
    dialog: crate::protocol::FileDialogId,
    files: &[crate::protocol::PickedFile],
) -> Vec<u8> {
    let mut b = Vec::new();
    b.extend_from_slice(&dialog.0.to_le_bytes());
    b.extend_from_slice(&(files.len() as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    // The Values encoding by hand: count, reserved, then each value.
    // write_values is the guest-side encoder and is cfg(test) here,
    // because in production the guest encodes and the core decodes.
    b.extend_from_slice(&((files.len() * 3) as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    for f in files {
        write_value(&mut b, &Value::I64(f.handle.0 as i64), &mut Vec::new());
        write_value(&mut b, &Value::Str(f.name.clone()), &mut Vec::new());
        write_value(&mut b, &Value::Str(f.local_path.clone()), &mut Vec::new());
    }
    b
}

/// An undo group's label, validated here so it fails identically in
/// eight languages. NON-EMPTY IS THE WHOLE RULE: the empty label is
/// already taken — it is how a TYPING EPISODE identifies itself on the
/// `undone` occurrence (docs/undo-plan.md §3).
pub(crate) fn check_undo_label(label: &str, what: &str) {
    assert!(
        !label.is_empty(),
        "kaya: {what} has an empty label — name the step ({}), because \
         the empty label already means \"a typing episode\" on the \
         undone occurrence and an anonymous group would be \
         indistinguishable from the native tier",
        "tx.undoable(\"add todo\")"
    );
}

/// An undo or redo's answer on the wire: the window, the four run
/// counts, the label, then one flat Values list holding the runs in
/// order — signal pairs, then three ARITY-FIRST group runs (texts,
/// entries, orders), each opening with the size of the group including
/// the size itself. Layouts: `spec::UNDO_DELTA_RUNS`. This is the ONE
/// encoder; `redone` is byte-identical.
pub(crate) fn undo_body(
    window: WindowId,
    label: &str,
    delta: &crate::protocol::UndoDelta,
) -> Vec<u8> {
    let mut values: Vec<Value> = Vec::new();
    for (signal, value) in &delta.signals {
        values.push(Value::I64(signal.0 as i64));
        values.push(value.clone());
    }
    for text in &delta.texts {
        // size counts ITSELF: 3 fixed ints + the path + the text.
        let size = 4 + text.path.len();
        values.push(Value::I64(size as i64));
        values.push(Value::I64(text.id as i64));
        values.push(Value::I64(text.path.len() as i64));
        values.extend(text.path.iter().cloned());
        values.push(Value::Str(text.text.clone()));
    }
    for entry in &delta.entries {
        let (present, variant, record) = match &entry.state {
            Some((variant, record)) => (1i64, *variant as i64, record.as_slice()),
            None => (0, 0, [].as_slice()),
        };
        // size counts ITSELF: 5 fixed ints + the path + the key + the
        // record. A reader takes the size first and needs nothing else.
        let size = 6 + entry.path.len() + record.len();
        values.push(Value::I64(size as i64));
        values.push(Value::I64(entry.collection.0 as i64));
        values.push(Value::I64(present));
        values.push(Value::I64(variant));
        values.push(Value::I64(entry.path.len() as i64));
        values.extend(entry.path.iter().cloned());
        values.push(entry.key.clone());
        values.extend(record.iter().cloned());
    }
    for order in &delta.orders {
        let size = 3 + order.path.len() + order.keys.len();
        values.push(Value::I64(size as i64));
        values.push(Value::I64(order.collection.0 as i64));
        values.push(Value::I64(order.path.len() as i64));
        values.extend(order.path.iter().cloned());
        values.extend(order.keys.iter().cloned());
    }
    let mut b = Vec::new();
    b.extend_from_slice(&window.0.to_le_bytes());
    b.extend_from_slice(&(delta.signals.len() as u32).to_le_bytes());
    b.extend_from_slice(&(delta.texts.len() as u32).to_le_bytes());
    b.extend_from_slice(&(delta.entries.len() as u32).to_le_bytes());
    b.extend_from_slice(&(delta.orders.len() as u32).to_le_bytes());
    write_value(&mut b, &Value::Str(label.to_owned()), &mut Vec::new());
    b.extend_from_slice(&(values.len() as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    for v in &values {
        write_value(&mut b, v, &mut Vec::new());
    }
    b
}

/// Read an undo body back — what a guest's generated parser does, in
/// one place, so the encoding above is pinned by a round trip rather
/// than by eight readers agreeing with it by luck. Panics on a
/// malformed body; a bad one is a broken encoder, not bad input.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn decode_undo_body(
    body: &[u8],
) -> (WindowId, String, crate::protocol::UndoDelta) {
    use crate::protocol::{UndoDelta, UndoEntry, UndoOrder, UndoText};
    let mut r = Reader { buf: body, at: 0, blobs: &|_| None };
    let window = WindowId(r.u64());
    let signals = r.u32() as usize;
    let texts = r.u32() as usize;
    let entries = r.u32() as usize;
    let orders = r.u32() as usize;
    let label = match r.value() {
        Value::Str(s) => s,
        other => panic!("kaya: undo label is {other:?}, wanted a string"),
    };
    let flat = r.record();
    let mut at = 0;
    let mut next = |n: usize| {
        let s = flat
            .get(at..at + n)
            .unwrap_or_else(|| panic!("kaya: undo delta is truncated"))
            .to_vec();
        at += n;
        s
    };
    let int = |v: &Value| match v {
        Value::I64(n) => *n,
        other => panic!("kaya: undo delta wanted an integer, got {other:?}"),
    };
    let mut delta = UndoDelta::default();
    for _ in 0..signals {
        let pair = next(2);
        delta
            .signals
            .push((SignalId(int(&pair[0]) as u64), pair[1].clone()));
    }
    for _ in 0..texts {
        let head = next(3);
        let size = int(&head[0]) as usize;
        let path_len = int(&head[2]) as usize;
        let rest = next(size - 3);
        let text = match &rest[path_len] {
            Value::Str(s) => s.clone(),
            other => panic!("kaya: undo text is {other:?}, wanted a string"),
        };
        delta.texts.push(UndoText {
            id: int(&head[1]) as u64,
            path: rest[..path_len].to_vec(),
            text,
        });
    }
    for _ in 0..entries {
        let head = next(5);
        let size = int(&head[0]) as usize;
        let path_len = int(&head[4]) as usize;
        let rest = next(size - 5);
        let path: Path = rest[..path_len].to_vec();
        let key = rest[path_len].clone();
        let state = if int(&head[2]) != 0 {
            Some((int(&head[3]) as u32, rest[path_len + 1..].to_vec()))
        } else {
            None
        };
        delta.entries.push(UndoEntry {
            collection: CollectionId(int(&head[1]) as u64),
            path,
            key,
            state,
        });
    }
    for _ in 0..orders {
        let head = next(3);
        let size = int(&head[0]) as usize;
        let path_len = int(&head[2]) as usize;
        let rest = next(size - 3);
        delta.orders.push(UndoOrder {
            collection: CollectionId(int(&head[1]) as u64),
            path: rest[..path_len].to_vec(),
            keys: rest[path_len..].to_vec(),
        });
    }
    assert_eq!(at, flat.len(), "kaya: undo delta has trailing values");
    (window, label, delta)
}

/// The privileged read's answer on the wire: request id, the clip kind
/// that arrived, reserved, then that one representation's values.
/// `clip` zero with no values is the universal no.
pub(crate) fn clipboard_result_body(
    request: u64,
    clip: Option<&crate::protocol::Representation>,
) -> Vec<u8> {
    let mut b = Vec::new();
    b.extend_from_slice(&request.to_le_bytes());
    b.extend_from_slice(&representation_kind(clip).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    write_representation(&mut b, clip);
    b
}

/// A paste landing on a widget: the widget's stored identity tag, then
/// the clip kind and that representation's values.
///
/// THE TAG GOES IN VERBATIM, which is why the clip kind rides AFTER the
/// path rather than in the tag's reserved slot. NEVER the empty kind: a
/// paste that delivered nothing is not an occurrence.
pub(crate) fn pasted_body(tag: &[u8], clip: &crate::protocol::Representation) -> Vec<u8> {
    let mut b = Vec::with_capacity(tag.len() + 32);
    b.extend_from_slice(tag);
    b.extend_from_slice(&representation_kind(Some(clip)).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    write_representation(&mut b, Some(clip));
    b
}

/// The four closed kinds, by the names an accept list spells them —
/// the same names the `clip` enum uses, so there is one vocabulary and
/// not a wire spelling beside a guest spelling.
pub(crate) const CLIP_NAMES: &[(&str, u32)] = &[
    ("text", CLIP_TEXT),
    ("html", CLIP_HTML),
    ("image", CLIP_IMAGE),
    ("files", CLIP_FILES),
];

/// Split an accept list into the closed kinds it names and the custom
/// ids it names. ONE PARSER, used by the root's check, by every
/// rust-native backend, and mirrored by each interpreter — the string
/// is the contract, so a second reading of it is a second contract.
pub fn parse_accept_list(list: &str) -> (u32, Vec<&str>) {
    let mut kinds = 0;
    let mut custom = Vec::new();
    for token in list.split_whitespace() {
        match CLIP_NAMES.iter().find(|(name, _)| *name == token) {
            Some((_, bit)) => kinds |= bit,
            None => custom.push(token),
        }
    }
    (kinds, custom)
}

/// An accept list names at least one representation and names none
/// twice, and every custom id it names is held to the id grammar.
///
/// WHICH TOKENS ARE CUSTOM IS ASKED OF [`parse_accept_list`] and not
/// decided again here — a second reading of the string is a second
/// contract. It also keeps the parser reachable on macOS, where neither
/// rust-native backend compiles and it would otherwise be dead code.
pub(crate) fn check_accept_list(list: &str, what: &str) {
    let (_, custom) = parse_accept_list(list);
    let tokens: Vec<&str> = list.split_whitespace().collect();
    assert!(
        !tokens.is_empty(),
        "kaya: {what} names no representation — an empty accept list can \
         only ever answer empty, so it is a typo rather than a request"
    );
    for (i, token) in tokens.iter().enumerate() {
        assert!(
            !tokens[..i].contains(token),
            "kaya: {what} names {token:?} twice — an accept list is a SET"
        );
        if custom.contains(token) {
            check_custom_id(token, what);
        }
    }
}

/// The custom-id grammar (DESIGN.md, Clipboard): MIME-SHAPED — a
/// slash, lowercase, no whitespace. The slash and the case are GDK's
/// charges (docs/clipboard-plan.md §5b finding 4), enforced here so
/// they fail the same way on every platform. Whitespace because accept
/// lists are space-separated.
pub(crate) fn check_custom_id(id: &str, what: &str) {
    assert!(
        id.contains('/'),
        "kaya: {what} custom id {id:?} has no slash — a custom id is \
         mime-shaped, like \"dev.kaya/note\": GDK serves only \
         slash-bearing types, so this id would be advertised and never \
         served on GTK"
    );
    assert!(
        !id.contains(char::is_whitespace),
        "kaya: {what} custom id {id:?} carries whitespace — accept lists \
         are space-separated, so this id could never be accepted by name"
    );
    assert!(
        !id.chars().any(|c| c.is_ascii_uppercase()),
        "kaya: {what} custom id {id:?} is not lowercase — GDK lowercases \
         mime types, so this id would surface as {:?} on GTK and \
         verbatim everywhere else",
        id.to_ascii_lowercase()
    );
}

pub(crate) fn representation_kind(clip: Option<&crate::protocol::Representation>) -> u32 {
    use crate::protocol::Representation as R;
    match clip {
        None => 0,
        Some(R::Text(_)) => CLIP_TEXT,
        Some(R::Html(_)) => CLIP_HTML,
        Some(R::Image(_)) => CLIP_IMAGE,
        Some(R::Files(_)) => CLIP_FILES,
        Some(R::Custom { .. }) => CLIP_CUSTOM,
    }
}

/// The one representation's values, as a Values block. The slot counts
/// mirror [`write_clip`]'s: one value for text and html, one blob for
/// an image, id-then-bytes for custom, and the picker's three-per-file
/// grouping for files — so a guest that already decodes a dialog result
/// decodes a pasted file list with the same loop.
fn write_representation(b: &mut Vec<u8>, clip: Option<&crate::protocol::Representation>) {
    use crate::protocol::Representation as R;
    let values: Vec<Value> = match clip {
        None => Vec::new(),
        Some(R::Text(s) | R::Html(s)) => vec![Value::Str(s.clone())],
        Some(R::Image(bytes)) => vec![Value::Blob(bytes.clone())],
        Some(R::Custom { id, bytes }) => {
            vec![Value::Str(id.clone()), Value::Blob(bytes.clone())]
        }
        Some(R::Files(files)) => files
            .iter()
            .flat_map(|f| {
                [
                    Value::I64(f.handle.0 as i64),
                    Value::Str(f.name.clone()),
                    Value::Str(f.local_path.clone()),
                ]
            })
            .collect(),
    };
    b.extend_from_slice(&(values.len() as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    for v in &values {
        write_occurrence_value(b, v);
    }
}

/// A value on the OCCURRENCE channel, where a blob resolves through the
/// occurrence blob table rather than a batch-local index: tx and apply
/// each have a boundary that retires a handle (a submit, a batch) and
/// this channel has neither, so the handle is a table entry the binding
/// redeems and releases while decoding.
fn write_occurrence_value(b: &mut Vec<u8>, value: &Value) {
    match value {
        Value::Blob(blob) => {
            let handle = crate::capi::occ_blob_register(blob.0.clone());
            b.extend_from_slice(&VALUE_BLOB.to_le_bytes());
            b.extend_from_slice(&8u32.to_le_bytes());
            b.extend_from_slice(&handle.to_le_bytes());
            while b.len() % 8 != 0 {
                b.push(0);
            }
        }
        other => write_value(b, other, &mut Vec::new()),
    }
}

/// The mirror of [`write_representation`], for the round-trip tests and
/// for any core-side consumer: the kind says which arm, the values
/// carry it. Blobs arrive as table handles, so this is only meaningful
/// where the table is live.
#[cfg(test)]
fn read_representation(kind: u32, values: Vec<Value>) -> Option<crate::protocol::Representation> {
    use crate::protocol::Representation as R;
    let mut it = values.into_iter();
    match kind {
        0 => None,
        CLIP_TEXT => Some(R::Text(clip_str(it.next(), "text"))),
        CLIP_HTML => Some(R::Html(clip_str(it.next(), "html"))),
        CLIP_IMAGE => Some(R::Image(clip_blob(it.next(), "image"))),
        CLIP_CUSTOM => Some(R::Custom {
            id: clip_str(it.next(), "custom id"),
            bytes: clip_blob(it.next(), "custom bytes"),
        }),
        CLIP_FILES => {
            let mut files = Vec::new();
            while let Some(handle) = it.next() {
                let handle = match handle {
                    Value::I64(v) => crate::protocol::PickedId(v as u64),
                    other => panic!("kaya: a pasted file is {other:?}, wanted a handle"),
                };
                files.push(crate::protocol::PickedFile {
                    handle,
                    name: clip_str(it.next(), "file name"),
                    local_path: clip_str(it.next(), "file local_path"),
                });
            }
            Some(R::Files(files))
        }
        other => panic!("kaya: unknown clip kind {other}"),
    }
}

pub(crate) fn alert_choice_raw(choice: AlertChoice) -> u32 {
    match choice {
        AlertChoice::Action(i) => i,
        AlertChoice::Cancel => ALERT_CHOICE_CANCEL,
    }
}

pub(crate) fn alert_choice(raw: u32) -> AlertChoice {
    match raw {
        ALERT_CHOICE_CANCEL => AlertChoice::Cancel,
        i if i <= 1 => AlertChoice::Action(i),
        other => panic!("kaya: unknown alert choice {other}"),
    }
}

// --- Click tags ------------------------------------------------------------
//
// The occurrence body for a click, also handed to backends inside
// ApplyOp::Create so they can emit it verbatim: { u64 id; u32 path_len;
// u32 reserved; path_len values }. path_len 0 means id is a widget id;
// otherwise id is a template node id and the values are the copy's key
// path, outermost first.

pub fn click_tag(id: u64, path: &[Value]) -> Vec<u8> {
    let mut b = Vec::with_capacity(16);
    b.extend_from_slice(&id.to_le_bytes());
    b.extend_from_slice(&(path.len() as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    for key in path {
        write_value(&mut b, key, &mut Vec::new());
    }
    b
}

pub fn decode_click_tag(tag: &[u8]) -> Occurrence {
    let mut r = Reader { buf: tag, at: 0, blobs: &|_| None };
    let id = r.u64();
    let path = r.path();
    if path.is_empty() {
        Occurrence::ButtonClicked { id: WidgetId(id) }
    } else {
        Occurrence::InstanceButtonClicked {
            node: TemplateNodeId(id),
            path,
        }
    }
}

// A sort-requested occurrence body IS the sort tag with the column
// index patched into the reserved slot — { u64 id; u32 path_len;
// u32 column; path_len values } — so the backend hands the tag back
// verbatim plus one integer, exactly like every other tag door.
pub fn sort_body(tag: &[u8], column: u32) -> Vec<u8> {
    let mut b = tag.to_vec();
    b[12..16].copy_from_slice(&column.to_le_bytes());
    b
}

// THE TWO CANVAS OCCURRENCES (docs/canvas-plan.md §3.2.1). Both are a
// click tag with the size the core is asking about appended as tagged
// values — { u64 id; u32 path_len; u32 reserved; path_len keys; w; h }
// and the same with a third value, the FRAME'S TIME.
pub fn draw_body(id: u64, path: &[Value], size: (f64, f64), time: Option<f64>) -> Vec<u8> {
    let mut b = click_tag(id, path);
    let mut blobs = Vec::new();
    write_value(&mut b, &Value::F64(size.0), &mut blobs);
    write_value(&mut b, &Value::F64(size.1), &mut blobs);
    if let Some(t) = time {
        write_value(&mut b, &Value::F64(t), &mut blobs);
    }
    b
}

/// `draw_body`'s inverse: the id, the copy's key path, the size, and the
/// frame time when there is one.
///
/// TEST-ONLY: foreign guests decode these bodies in their own languages
/// off the ring, and the Rust API's sink carries the `Occurrence`
/// itself.
#[cfg(test)]
fn read_draw_body(body: &[u8], ticking: bool) -> (u64, Path, (f64, f64), f64) {
    let mut r = Reader { buf: body, at: 0, blobs: &|_| None };
    let id = r.u64();
    let path = r.path();
    let num = |v: Value, which: &str| match v {
        Value::F64(n) => n,
        other => panic!("kaya: a canvas {which} occurrence carries {other:?}, wanted f64"),
    };
    let w = num(r.value(), "size");
    let h = num(r.value(), "size");
    let t = if ticking { num(r.value(), "frame time") } else { 0.0 };
    (id, path, (w, h), t)
}

#[cfg(test)]
pub fn decode_draw_requested(body: &[u8]) -> Occurrence {
    let (id, path, size, _) = read_draw_body(body, false);
    if path.is_empty() {
        Occurrence::DrawRequested { id: WidgetId(id), size }
    } else {
        Occurrence::InstanceDrawRequested { node: TemplateNodeId(id), path, size }
    }
}

#[cfg(test)]
pub fn decode_tick(body: &[u8]) -> Occurrence {
    let (id, path, size, time) = read_draw_body(body, true);
    if path.is_empty() {
        Occurrence::Tick { id: WidgetId(id), size, time }
    } else {
        Occurrence::InstanceTick { node: TemplateNodeId(id), path, size, time }
    }
}

pub fn decode_sort_tag(tag: &[u8], column: u32) -> Occurrence {
    let mut r = Reader { buf: tag, at: 0, blobs: &|_| None };
    let id = r.u64();
    let path = r.path();
    if path.is_empty() {
        Occurrence::SortRequested { id: WidgetId(id), column }
    } else {
        Occurrence::InstanceSortRequested {
            node: TemplateNodeId(id),
            path,
            column,
        }
    }
}

// A text-changed occurrence body: the widget's stored tag (identity,
// same layout as a click) followed by the new text as a value. The
// backend never learns what the tag means; it appends what the user
// typed.
pub fn text_changed_body(tag: &[u8], text: &str) -> Vec<u8> {
    let mut b = Vec::with_capacity(tag.len() + 8 + text.len());
    b.extend_from_slice(tag);
    write_value(&mut b, &Value::Str(text.to_owned()), &mut Vec::new());
    b
}

// A toggled occurrence body: the checkbox's stored tag (identity, same
// layout as a click) followed by the new state as a value.
pub fn toggled_body(tag: &[u8], checked: bool) -> Vec<u8> {
    let mut b = Vec::with_capacity(tag.len() + 16);
    b.extend_from_slice(tag);
    write_value(&mut b, &Value::Bool(checked), &mut Vec::new());
    b
}

// A value-changed occurrence body: the slider's stored tag (identity,
// same layout as a click) followed by the new value.
pub fn value_changed_body(tag: &[u8], value: f64) -> Vec<u8> {
    let mut b = Vec::with_capacity(tag.len() + 16);
    b.extend_from_slice(tag);
    write_value(&mut b, &Value::F64(value), &mut Vec::new());
    b
}

pub fn decode_value_changed_tag(tag: &[u8], value: f64) -> Occurrence {
    let mut r = Reader { buf: tag, at: 0, blobs: &|_| None };
    let id = r.u64();
    let path = r.path();
    if path.is_empty() {
        Occurrence::ValueChanged {
            id: WidgetId(id),
            value,
        }
    } else {
        Occurrence::InstanceValueChanged {
            node: TemplateNodeId(id),
            path,
            value,
        }
    }
}

pub fn decode_toggled_tag(tag: &[u8], checked: bool) -> Occurrence {
    let mut r = Reader { buf: tag, at: 0, blobs: &|_| None };
    let id = r.u64();
    let path = r.path();
    if path.is_empty() {
        Occurrence::Toggled {
            id: WidgetId(id),
            checked,
        }
    } else {
        Occurrence::InstanceToggled {
            node: TemplateNodeId(id),
            path,
            checked,
        }
    }
}

pub fn decode_text_changed_tag(tag: &[u8], text: &str) -> Occurrence {
    let mut r = Reader { buf: tag, at: 0, blobs: &|_| None };
    let id = r.u64();
    let path = r.path();
    if path.is_empty() {
        Occurrence::TextChanged {
            id: WidgetId(id),
            text: text.to_owned(),
        }
    } else {
        Occurrence::InstanceTextChanged {
            node: TemplateNodeId(id),
            path,
            text: text.to_owned(),
        }
    }
}

// --- Menu occurrence tags --------------------------------------------------
//
// The item id plus a NOUN: empty for a bar action or a live-widget
// context item, or the anchor copy's key path for a node-anchored one,
// encoded { u32 count; u32 reserved; count values }. The resulting tag
// is BYTE-IDENTICAL to a click_tag, so the toggled/value body builders
// and the click-tag decoders serve menus unchanged.

pub fn menu_tag(item: u64, noun: &[u8]) -> Vec<u8> {
    let mut b = Vec::with_capacity(16 + noun.len());
    b.extend_from_slice(&item.to_le_bytes());
    if noun.is_empty() {
        b.extend_from_slice(&0u32.to_le_bytes()); // path_len
        b.extend_from_slice(&0u32.to_le_bytes()); // reserved
    } else {
        b.extend_from_slice(noun);
    }
    b
}

pub fn decode_menu_activated_tag(tag: &[u8]) -> Occurrence {
    let mut r = Reader { buf: tag, at: 0, blobs: &|_| None };
    let item = r.u64();
    let path = r.path();
    if path.is_empty() {
        Occurrence::MenuActivated { item: MenuItemId(item) }
    } else {
        Occurrence::InstanceMenuActivated { item: MenuItemId(item), path }
    }
}

pub fn decode_menu_toggled_tag(tag: &[u8], checked: bool) -> Occurrence {
    let mut r = Reader { buf: tag, at: 0, blobs: &|_| None };
    let item = r.u64();
    let path = r.path();
    if path.is_empty() {
        Occurrence::MenuToggled { item: MenuItemId(item), checked }
    } else {
        Occurrence::InstanceMenuToggled { item: MenuItemId(item), path, checked }
    }
}

pub fn decode_menu_value_tag(tag: &[u8], index: f64) -> Occurrence {
    let mut r = Reader { buf: tag, at: 0, blobs: &|_| None };
    let group = r.u64();
    let path = r.path();
    if path.is_empty() {
        Occurrence::MenuValueChanged { group: MenuItemId(group), index }
    } else {
        Occurrence::InstanceMenuValueChanged { group: MenuItemId(group), path, index }
    }
}

// --- Writing -------------------------------------------------------------

pub struct Writer {
    buf: Vec<u8>,
    /// The batch's blob table, in first-reference order. A blob VALUE
    /// on the wire is a 1-based index into it (0 is invalid). Handles
    /// are BATCH-LOCAL: kaya_blob_data serves the current table until
    /// the next kaya_next_commands call replaces it. Payload bytes
    /// never enter the record stream.
    pub blobs: Vec<Arc<[u8]>>,
}

impl Writer {
    pub fn new() -> Self {
        Writer { buf: Vec::new(), blobs: Vec::new() }
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.buf
    }

    fn record(&mut self, kind: u16, body: impl FnOnce(&mut Vec<u8>, &mut Vec<Arc<[u8]>>)) {
        let start = self.buf.len();
        self.buf.extend_from_slice(&[0; HEADER_SIZE]);
        body(&mut self.buf, &mut self.blobs);
        while self.buf.len() % 8 != 0 {
            self.buf.push(0);
        }
        let size = (self.buf.len() - start) as u32;
        self.buf[start..start + 4].copy_from_slice(&size.to_le_bytes());
        self.buf[start + 4..start + 6].copy_from_slice(&kind.to_le_bytes());
    }

    pub fn apply_op(&mut self, op: &ApplyOp) {
        match op {
            // Create: { u64 id; u32 kind; u32 tag_len; tag bytes padded }.
            // tag_len 0 means no tag (non-interactive widget).
            ApplyOp::Create { id, kind, tag } => self.record(APPLY_CREATE, |b, _| {
                b.extend_from_slice(&id.0.to_le_bytes());
                b.extend_from_slice(&kind_raw(*kind).to_le_bytes());
                let tag = tag.as_deref().unwrap_or(&[]);
                b.extend_from_slice(&(tag.len() as u32).to_le_bytes());
                b.extend_from_slice(tag);
            }),
            ApplyOp::SetProp { id, prop, value } => self.record(APPLY_SET_PROP, |b, blobs| {
                b.extend_from_slice(&id.0.to_le_bytes());
                b.extend_from_slice(&prop_raw(*prop).to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
                write_value(b, value, blobs);
            }),
            ApplyOp::SetWindowProp { window, prop, value } => {
                self.record(APPLY_SET_WINDOW_PROP, |b, blobs| {
                    b.extend_from_slice(&window.0.to_le_bytes());
                    b.extend_from_slice(&window_prop_raw(*prop).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    write_value(b, value, blobs);
                })
            }
            ApplyOp::CreateWindow { window } => self.record(APPLY_CREATE_WINDOW, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
            }),
            ApplyOp::DestroyWindow { window } => self.record(APPLY_DESTROY_WINDOW, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
            }),
            ApplyOp::PresentAlert(spec) => self.record(APPLY_PRESENT_ALERT, |b, blobs| {
                b.extend_from_slice(&spec.window.0.to_le_bytes());
                b.extend_from_slice(&spec.alert.0.to_le_bytes());
                b.extend_from_slice(&(spec.actions.len() as u32).to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
                for s in alert_value_slots(spec) {
                    write_value(b, &Value::Str(s), blobs);
                }
            }),
            ApplyOp::PresentFileDialog(spec) => {
                self.record(APPLY_PRESENT_FILE_DIALOG, |b, blobs| {
                    b.extend_from_slice(&spec.window.0.to_le_bytes());
                    b.extend_from_slice(&spec.dialog.0.to_le_bytes());
                    b.extend_from_slice(&u32::from(spec.multiple).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    b.extend_from_slice(&((spec.filters.len() * 2) as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    for (label, exts) in &spec.filters {
                        write_value(b, &Value::Str(label.clone()), blobs);
                        write_value(b, &Value::Str(exts.clone()), blobs);
                    }
                })
            }
            ApplyOp::PresentSaveDialog(spec) => {
                self.record(APPLY_PRESENT_SAVE_DIALOG, |b, blobs| {
                    b.extend_from_slice(&spec.window.0.to_le_bytes());
                    b.extend_from_slice(&spec.dialog.0.to_le_bytes());
                    write_value(b, &Value::Str(spec.suggested_name.clone()), blobs);
                    b.extend_from_slice(&((spec.filters.len() * 2) as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    for (label, exts) in &spec.filters {
                        write_value(b, &Value::Str(label.clone()), blobs);
                        write_value(b, &Value::Str(exts.clone()), blobs);
                    }
                })
            }
            ApplyOp::Copy(clip) => self.record(APPLY_COPY, |b, blobs| {
                write_clip_out(b, clip, blobs);
            }),
            ApplyOp::ReadClipboard { request, accepting } => {
                self.record(APPLY_READ_CLIPBOARD, |b, blobs| {
                    b.extend_from_slice(&request.to_le_bytes());
                    write_value(b, &Value::Str(accepting.clone()), blobs);
                })
            }
            ApplyOp::SetTypeface(req) => self.record(APPLY_SET_TYPEFACE, |b, blobs| {
                // ONE WRITER FOR BOTH CHANNELS: the core resolves the
                // family nowhere (docs/styling-plan.md Slice 2b). The
                // one word it fills is which platform this core is.
                write_typeface(b, req, this_platform(), blobs);
            }),
            ApplyOp::SetAppIdentity(identity) => {
                self.record(APPLY_SET_APP_IDENTITY, |b, blobs| {
                    // ONE WRITER FOR BOTH CHANNELS, the typeface's rule.
                    // No platform stamp to fill: unlike a family name, a
                    // picture needs no row picked — every platform gets
                    // the same bytes.
                    write_app_identity(b, identity, blobs);
                })
            }
            ApplyOp::ClearUndo { window } => self.record(APPLY_CLEAR_UNDO, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
            }),
            ApplyOp::HighlightRanges { id, ranges } => {
                self.record(APPLY_HIGHLIGHT_RANGES, |b, blobs| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    b.extend_from_slice(&(ranges.len() as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    b.extend_from_slice(&((ranges.len() * 2) as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    for r in ranges {
                        write_value(b, &Value::I64(r.start as i64), blobs);
                        write_value(b, &Value::I64(r.stop as i64), blobs);
                    }
                })
            }
            ApplyOp::SetColumnHeaders { id, sorted, direction, titles, tag } => {
                self.record(APPLY_SET_COLUMN_HEADERS, |b, blobs| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    b.extend_from_slice(&sorted.to_le_bytes());
                    b.extend_from_slice(&direction.to_le_bytes());
                    b.extend_from_slice(&(titles.len() as u32).to_le_bytes());
                    b.extend_from_slice(&(tag.len() as u32).to_le_bytes());
                    b.extend_from_slice(&(titles.len() as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    for title in titles {
                        write_value(b, &Value::Str(title.clone()), blobs);
                    }
                    // The sort tag rides after the titles, 8-aligned as
                    // every record body is padded (create's convention).
                    b.extend_from_slice(tag);
                    while b.len() % 8 != 0 {
                        b.push(0);
                    }
                })
            }
            ApplyOp::SetDrawing { id, width, height, scale, pixels } => {
                self.record(APPLY_SET_DRAWING, |b, blobs| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    b.extend_from_slice(&width.to_le_bytes());
                    b.extend_from_slice(&height.to_le_bytes());
                    write_value(b, &Value::F64(*scale), blobs);
                    write_value(b, &Value::Blob(pixels.clone()), blobs);
                })
            }
            ApplyOp::SelectRange { id, range } => self.record(APPLY_SELECT_RANGE, |b, _| {
                b.extend_from_slice(&id.0.to_le_bytes());
                b.extend_from_slice(&range.start.to_le_bytes());
                b.extend_from_slice(&range.stop.to_le_bytes());
            }),
            ApplyOp::RevealRange { id, range } => self.record(APPLY_REVEAL_RANGE, |b, _| {
                b.extend_from_slice(&id.0.to_le_bytes());
                b.extend_from_slice(&range.start.to_le_bytes());
                b.extend_from_slice(&range.stop.to_le_bytes());
            }),
            // Eleven packed sRGB words, fixed order: seed, then the
            // light appearance's five (fill, on_fill, standalone,
            // hover, pressed), then dark's five. The interpreters'
            // decoders carry the same order by name; check-verbs pins
            // the constant into both.
            ApplyOp::SetBrand { accent } => self.record(APPLY_SET_BRAND, |b, _| {
                for word in [
                    accent.seed,
                    accent.light.fill,
                    accent.light.on_fill,
                    accent.light.standalone,
                    accent.light.hover,
                    accent.light.pressed,
                    accent.dark.fill,
                    accent.dark.on_fill,
                    accent.dark.standalone,
                    accent.dark.hover,
                    accent.dark.pressed,
                ] {
                    b.extend_from_slice(&word.to_le_bytes());
                }
            }),
            ApplyOp::AddChild { parent, child } => self.record(APPLY_ADD_CHILD, |b, _| {
                b.extend_from_slice(&parent.0.to_le_bytes());
                b.extend_from_slice(&child.0.to_le_bytes());
            }),
            ApplyOp::Fold { child, table } => self.record(APPLY_FOLD, |b, _| {
                b.extend_from_slice(&child.0.to_le_bytes());
                b.extend_from_slice(&table.0.to_le_bytes());
            }),
            ApplyOp::Mount { window, root } => self.record(APPLY_MOUNT, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
                b.extend_from_slice(&root.0.to_le_bytes());
            }),
            ApplyOp::MoveChild { parent, child, before } => {
                self.record(APPLY_MOVE_CHILD, |b, _| {
                    b.extend_from_slice(&parent.0.to_le_bytes());
                    b.extend_from_slice(&child.0.to_le_bytes());
                    b.extend_from_slice(&before.map_or(0, |w| w.0).to_le_bytes());
                })
            }
            ApplyOp::Destroy { id } => self.record(APPLY_DESTROY, |b, _| {
                b.extend_from_slice(&id.0.to_le_bytes());
            }),
            ApplyOp::Command { id, command } => self.record(APPLY_COMMAND, |b, _| {
                b.extend_from_slice(&id.0.to_le_bytes());
                b.extend_from_slice(&command_raw(*command).to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
            }),
            ApplyOp::PushEntry { window, entry } => self.record(APPLY_PUSH_ENTRY, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
                b.extend_from_slice(&entry.0.to_le_bytes());
            }),
            ApplyOp::PopEntry { window } => self.record(APPLY_POP_ENTRY, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
            }),
            ApplyOp::SetEntryProp { entry, prop, value } => {
                self.record(APPLY_SET_ENTRY_PROP, |b, blobs| {
                    b.extend_from_slice(&entry.0.to_le_bytes());
                    b.extend_from_slice(&entry_prop_raw(*prop).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    write_value(b, value, blobs);
                })
            }
            ApplyOp::AddSection { window, section } => {
                self.record(APPLY_ADD_SECTION, |b, _| {
                    b.extend_from_slice(&window.0.to_le_bytes());
                    b.extend_from_slice(&section.0.to_le_bytes());
                })
            }
            ApplyOp::SelectSection { window, section } => {
                self.record(APPLY_SELECT_SECTION, |b, _| {
                    b.extend_from_slice(&window.0.to_le_bytes());
                    b.extend_from_slice(&section.0.to_le_bytes());
                })
            }
            ApplyOp::SetSectionProp { section, prop, value } => {
                self.record(APPLY_SET_SECTION_PROP, |b, blobs| {
                    b.extend_from_slice(&section.0.to_le_bytes());
                    b.extend_from_slice(&section_prop_raw(*prop).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    write_value(b, value, blobs);
                })
            }
            // MENU_ITEM_CREATE: u64 item, u32 kind, u32 pad.
            ApplyOp::MenuItemCreate { item, kind } => {
                self.record(APPLY_MENU_ITEM_CREATE, |b, _| {
                    b.extend_from_slice(&item.0.to_le_bytes());
                    b.extend_from_slice(&menu_kind_raw(*kind).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                })
            }
            // MENU_ITEM_APPEND: u64 parent, u64 child.
            ApplyOp::MenuItemAppend { parent, child } => {
                self.record(APPLY_MENU_ITEM_APPEND, |b, _| {
                    b.extend_from_slice(&parent.0.to_le_bytes());
                    b.extend_from_slice(&child.0.to_le_bytes());
                })
            }
            // MENUBAR_APPEND: u64 window, u64 item.
            ApplyOp::MenubarAppend { window, item } => {
                self.record(APPLY_MENUBAR_APPEND, |b, _| {
                    b.extend_from_slice(&window.0.to_le_bytes());
                    b.extend_from_slice(&item.0.to_le_bytes());
                })
            }
            // CONTEXT_ATTACH: u64 widget, u64 item.
            ApplyOp::ContextAttach { widget, item } => {
                self.record(APPLY_CONTEXT_ATTACH, |b, _| {
                    b.extend_from_slice(&widget.0.to_le_bytes());
                    b.extend_from_slice(&item.0.to_le_bytes());
                })
            }
            // CONTEXT_ATTACH_NODE: u64 widget, u64 item, then the anchor
            // copy's key path as { u32 count; u32 reserved; count values }
            // — the noun every activation from this attachment stamps.
            ApplyOp::ContextAttachNode { widget, item, path } => {
                self.record(APPLY_CONTEXT_ATTACH_NODE, |b, blobs| {
                    b.extend_from_slice(&widget.0.to_le_bytes());
                    b.extend_from_slice(&item.0.to_le_bytes());
                    b.extend_from_slice(&(path.len() as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    for key in path {
                        write_value(b, key, blobs);
                    }
                })
            }
            // SET_MENU_PROP: u64 item, u32 mprop, u32 pad, value.
            ApplyOp::SetMenuProp { item, prop, value } => {
                self.record(APPLY_SET_MENU_PROP, |b, blobs| {
                    b.extend_from_slice(&item.0.to_le_bytes());
                    b.extend_from_slice(&menu_prop_raw(*prop).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    write_value(b, value, blobs);
                })
            }
        }
    }

    /// Transaction encoding: exercised by the round-trip tests; the Rust
    /// API sends parsed values, and foreign guests pack their own bytes.
    #[cfg(test)]
    pub fn tx_op(&mut self, op: &TxOp) {
        match op {
            TxOp::CreateSignal { id, initial } => self.record(TX_CREATE_SIGNAL, |b, blobs| {
                b.extend_from_slice(&id.0.to_le_bytes());
                write_value(b, initial, blobs);
            }),
            TxOp::WriteSignal { id, value } => self.record(TX_WRITE_SIGNAL, |b, blobs| {
                b.extend_from_slice(&id.0.to_le_bytes());
                write_value(b, value, blobs);
            }),
            TxOp::CreateWidget { id, kind } => self.record(TX_CREATE_WIDGET, |b, _| {
                b.extend_from_slice(&id.0.to_le_bytes());
                b.extend_from_slice(&kind_raw(*kind).to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
            }),
            TxOp::SetProperty {
                widget,
                prop,
                value,
            } => self.record(TX_SET_PROPERTY, |b, blobs| {
                b.extend_from_slice(&widget.0.to_le_bytes());
                b.extend_from_slice(&prop_raw(*prop).to_le_bytes());
                match value {
                    PropValue::Const(v) => {
                        b.extend_from_slice(&SOURCE_CONST.to_le_bytes());
                        write_value(b, v, blobs);
                    }
                    PropValue::Signal(id) => {
                        b.extend_from_slice(&SOURCE_SIGNAL.to_le_bytes());
                        b.extend_from_slice(&id.0.to_le_bytes());
                    }
                    PropValue::Element { level, field } => {
                        b.extend_from_slice(&SOURCE_ELEMENT.to_le_bytes());
                        b.extend_from_slice(&level.to_le_bytes());
                        b.extend_from_slice(&field.to_le_bytes());
                    }
                }
            }),
            TxOp::AddChild { parent, child } => self.record(TX_ADD_CHILD, |b, _| {
                b.extend_from_slice(&parent.0.to_le_bytes());
                b.extend_from_slice(&child.0.to_le_bytes());
            }),
            TxOp::Mount { window, root } => self.record(TX_MOUNT, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
                b.extend_from_slice(&root.0.to_le_bytes());
            }),
            TxOp::CreateCollection { id, variants } => {
                self.record(TX_CREATE_COLLECTION, |b, _| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    b.extend_from_slice(&(variants.len() as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    for schema in variants {
                        b.extend_from_slice(&(schema.len() as u32).to_le_bytes());
                        for ty in schema {
                            b.extend_from_slice(&value_type_raw(*ty).to_le_bytes());
                        }
                    }
                    while b.len() % 8 != 0 {
                        b.push(0);
                    }
                })
            }
            TxOp::CollectionInsert { id, path, key, variant, record } => {
                self.record(TX_COLLECTION_INSERT, |b, blobs| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    write_path(b, path, blobs);
                    write_value(b, key, blobs);
                    b.extend_from_slice(&variant.to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    write_values(b, record, blobs);
                })
            }
            TxOp::CollectionUpdate { id, path, key, variant, record } => {
                self.record(TX_COLLECTION_UPDATE, |b, blobs| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    write_path(b, path, blobs);
                    write_value(b, key, blobs);
                    b.extend_from_slice(&variant.to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    write_values(b, record, blobs);
                })
            }
            TxOp::CollectionUpdateField { id, path, key, variant, field, value } => {
                self.record(TX_COLLECTION_UPDATE_FIELD, |b, blobs| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    write_path(b, path, blobs);
                    write_value(b, key, blobs);
                    b.extend_from_slice(&field.to_le_bytes());
                    b.extend_from_slice(&variant.to_le_bytes());
                    write_value(b, value, blobs);
                })
            }
            TxOp::CollectionMove { id, path, key, before } => {
                self.record(TX_COLLECTION_MOVE, |b, blobs| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    write_path(b, path, blobs);
                    write_value(b, key, blobs);
                    let anchors: Path = before.iter().cloned().collect();
                    write_path(b, &anchors, blobs);
                })
            }
            TxOp::CollectionRemove { id, path, key } => {
                self.record(TX_COLLECTION_REMOVE, |b, blobs| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    write_path(b, path, blobs);
                    write_value(b, key, blobs);
                })
            }
            TxOp::CreateFor { id, collection } => self.record(TX_CREATE_FOR, |b, _| {
                b.extend_from_slice(&id.to_le_bytes());
                b.extend_from_slice(&collection.0.to_le_bytes());
            }),
            TxOp::CreateWhen { id, signal } => self.record(TX_CREATE_WHEN, |b, _| {
                b.extend_from_slice(&id.to_le_bytes());
                b.extend_from_slice(&signal.0.to_le_bytes());
            }),
            TxOp::VariantCase { variant } => self.record(TX_VARIANT_CASE, |b, _| {
                b.extend_from_slice(&variant.to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
            }),
            TxOp::WidgetCommand { widget, command } => self.record(TX_WIDGET_COMMAND, |b, _| {
                b.extend_from_slice(&widget.0.to_le_bytes());
                b.extend_from_slice(&command_raw(*command).to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
            }),
            TxOp::SetWindowProp {
                window,
                prop,
                value,
            } => self.record(TX_SET_WINDOW_PROP, |b, blobs| {
                b.extend_from_slice(&window.0.to_le_bytes());
                b.extend_from_slice(&window_prop_raw(*prop).to_le_bytes());
                match value {
                    PropValue::Const(v) => {
                        b.extend_from_slice(&SOURCE_CONST.to_le_bytes());
                        write_value(b, v, blobs);
                    }
                    PropValue::Signal(id) => {
                        b.extend_from_slice(&SOURCE_SIGNAL.to_le_bytes());
                        b.extend_from_slice(&id.0.to_le_bytes());
                    }
                    PropValue::Element { .. } => {
                        panic!("kaya: window properties cannot bind element sources")
                    }
                }
            }),
            TxOp::CreateWindow { window } => self.record(TX_CREATE_WINDOW, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
            }),
            TxOp::DestroyWindow { window } => self.record(TX_DESTROY_WINDOW, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
            }),
            TxOp::ShowAlert(spec) => self.record(TX_SHOW_ALERT, |b, blobs| {
                b.extend_from_slice(&spec.window.0.to_le_bytes());
                b.extend_from_slice(&spec.alert.0.to_le_bytes());
                b.extend_from_slice(&(spec.actions.len() as u32).to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
                for s in alert_value_slots(spec) {
                    write_value(b, &Value::Str(s), blobs);
                }
            }),
            TxOp::ShowFileDialog(spec) => self.record(TX_SHOW_FILE_DIALOG, |b, blobs| {
                b.extend_from_slice(&spec.window.0.to_le_bytes());
                b.extend_from_slice(&spec.dialog.0.to_le_bytes());
                b.extend_from_slice(&u32::from(spec.multiple).to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
                // Filters ride as alternating Str values, label then
                // extensions — the Values encoding read in pairs, the
                // same grouping trick the result uses in threes.
                let flat: Vec<Value> = spec
                    .filters
                    .iter()
                    .flat_map(|(label, exts)| {
                        [Value::Str(label.clone()), Value::Str(exts.clone())]
                    })
                    .collect();
                write_values(b, &flat, blobs);
            }),
            TxOp::SetBrandAccent { seed, light, dark } => {
                self.record(TX_SET_BRAND_ACCENT, |b, _| {
                    let mask: u32 = light.map_or(0, |_| 1) | dark.map_or(0, |_| 2);
                    b.extend_from_slice(&seed.to_le_bytes());
                    b.extend_from_slice(&mask.to_le_bytes());
                    b.extend_from_slice(&light.unwrap_or(0).to_le_bytes());
                    b.extend_from_slice(&dark.unwrap_or(0).to_le_bytes());
                })
            }
            TxOp::SetBrandTypeface(req) => self.record(TX_SET_BRAND_TYPEFACE, |b, blobs| {
                write_typeface(b, req, 0, blobs);
            }),
            TxOp::SetAppIdentity(identity) => {
                self.record(TX_SET_APP_IDENTITY, |b, blobs| {
                    write_app_identity(b, identity, blobs);
                })
            }
            TxOp::ShowSaveDialog(spec) => self.record(TX_SHOW_SAVE_DIALOG, |b, blobs| {
                b.extend_from_slice(&spec.window.0.to_le_bytes());
                b.extend_from_slice(&spec.dialog.0.to_le_bytes());
                write_value(b, &Value::Str(spec.suggested_name.clone()), blobs);
                let flat: Vec<Value> = spec
                    .filters
                    .iter()
                    .flat_map(|(label, exts)| {
                        [Value::Str(label.clone()), Value::Str(exts.clone())]
                    })
                    .collect();
                write_values(b, &flat, blobs);
            }),
            TxOp::UndoGroup { window, label } => self.record(TX_UNDO_GROUP, |b, blobs| {
                b.extend_from_slice(&window.0.to_le_bytes());
                write_value(b, &Value::Str(label.clone()), blobs);
            }),
            TxOp::Copy(clip) => self.record(TX_COPY, |b, blobs| {
                write_clip(b, clip, blobs);
            }),
            TxOp::ReadClipboard { request, accepting } => {
                self.record(TX_READ_CLIPBOARD, |b, blobs| {
                    b.extend_from_slice(&request.to_le_bytes());
                    write_value(b, &Value::Str(accepting.clone()), blobs);
                })
            }
            TxOp::HighlightRanges { widget, ranges } => {
                self.record(TX_HIGHLIGHT_RANGES, |b, blobs| {
                    b.extend_from_slice(&widget.0.to_le_bytes());
                    b.extend_from_slice(&(ranges.len() as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    b.extend_from_slice(&((ranges.len() * 2) as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    for r in ranges {
                        write_value(b, &Value::I64(r.start as i64), blobs);
                        write_value(b, &Value::I64(r.stop as i64), blobs);
                    }
                })
            }
            TxOp::CreateBreakpoint { window, when, setters } => {
                self.record(TX_CREATE_BREAKPOINT, |b, blobs| {
                    b.extend_from_slice(&window.0.to_le_bytes());
                    write_value(b, &Value::I64(*when), blobs);
                    b.extend_from_slice(&(setters.len() as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    b.extend_from_slice(&((setters.len() * 3) as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    // Widgets, then props, then values — thirds by
                    // position, the decode's contract.
                    for (w, _, _) in setters {
                        write_value(b, &Value::I64(w.0 as i64), blobs);
                    }
                    for (_, p, _) in setters {
                        write_value(b, &Value::I64(prop_raw(*p) as i64), blobs);
                    }
                    for (_, _, v) in setters {
                        write_value(b, v, blobs);
                    }
                })
            }
            TxOp::SetColumnHeaders { widget, sorted, direction, path, titles } => {
                self.record(TX_SET_COLUMN_HEADERS, |b, blobs| {
                    b.extend_from_slice(&widget.0.to_le_bytes());
                    b.extend_from_slice(&sorted.to_le_bytes());
                    b.extend_from_slice(&direction.to_le_bytes());
                    b.extend_from_slice(&(titles.len() as u32).to_le_bytes());
                    b.extend_from_slice(&(path.len() as u32).to_le_bytes());
                    b.extend_from_slice(&((path.len() + titles.len()) as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    // Keys first, then titles — the decode's contract.
                    for key in path {
                        write_value(b, key, blobs);
                    }
                    for title in titles {
                        write_value(b, &Value::Str(title.clone()), blobs);
                    }
                })
            }
            TxOp::SetDrawing { widget, viewbox, path, ops } => {
                self.record(TX_SET_DRAWING, |b, blobs| {
                    b.extend_from_slice(&widget.0.to_le_bytes());
                    write_value(b, &Value::F64(viewbox.0), blobs);
                    write_value(b, &Value::F64(viewbox.1), blobs);
                    b.extend_from_slice(&(ops.len() as u32).to_le_bytes());
                    b.extend_from_slice(&(path.len() as u32).to_le_bytes());
                    b.extend_from_slice(&((path.len() + ops.len()) as u32).to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                    // Keys first, then the op stream — the decode's
                    // contract, and set_column_headers' verbatim.
                    for key in path {
                        write_value(b, key, blobs);
                    }
                    for op in ops {
                        write_value(b, op, blobs);
                    }
                })
            }
            TxOp::SetSizePolicy { widget, policy } => {
                self.record(TX_SET_SIZE_POLICY, |b, _| {
                    b.extend_from_slice(&widget.0.to_le_bytes());
                    b.extend_from_slice(&policy.to_le_bytes());
                    b.extend_from_slice(&0u32.to_le_bytes());
                })
            }
            TxOp::SelectRange { widget, range } => self.record(TX_SELECT_RANGE, |b, _| {
                b.extend_from_slice(&widget.0.to_le_bytes());
                b.extend_from_slice(&range.start.to_le_bytes());
                b.extend_from_slice(&range.stop.to_le_bytes());
            }),
            TxOp::RevealRange { widget, range } => self.record(TX_REVEAL_RANGE, |b, _| {
                b.extend_from_slice(&widget.0.to_le_bytes());
                b.extend_from_slice(&range.start.to_le_bytes());
                b.extend_from_slice(&range.stop.to_le_bytes());
            }),
            TxOp::PushEntry { window, entry } => self.record(TX_PUSH_ENTRY, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
                b.extend_from_slice(&entry.0.to_le_bytes());
            }),
            TxOp::PopEntry { window } => self.record(TX_POP_ENTRY, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
            }),
            TxOp::SetEntryProp { entry, prop, value } => {
                self.record(TX_SET_ENTRY_PROP, |b, blobs| {
                    b.extend_from_slice(&entry.0.to_le_bytes());
                    b.extend_from_slice(&entry_prop_raw(*prop).to_le_bytes());
                    match value {
                        PropValue::Const(v) => {
                            b.extend_from_slice(&SOURCE_CONST.to_le_bytes());
                            write_value(b, v, blobs);
                        }
                        PropValue::Signal(id) => {
                            b.extend_from_slice(&SOURCE_SIGNAL.to_le_bytes());
                            b.extend_from_slice(&id.0.to_le_bytes());
                        }
                        PropValue::Element { .. } => {
                            panic!("kaya: entry properties cannot bind element sources")
                        }
                    }
                })
            }
            TxOp::AddSection { window, section } => self.record(TX_ADD_SECTION, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
                b.extend_from_slice(&section.0.to_le_bytes());
            }),
            TxOp::SelectSection { window, section } => {
                self.record(TX_SELECT_SECTION, |b, _| {
                    b.extend_from_slice(&window.0.to_le_bytes());
                    b.extend_from_slice(&section.0.to_le_bytes());
                })
            }
            TxOp::SetSectionProp { section, prop, value } => {
                self.record(TX_SET_SECTION_PROP, |b, blobs| {
                    b.extend_from_slice(&section.0.to_le_bytes());
                    b.extend_from_slice(&section_prop_raw(*prop).to_le_bytes());
                    match value {
                        PropValue::Const(v) => {
                            b.extend_from_slice(&SOURCE_CONST.to_le_bytes());
                            write_value(b, v, blobs);
                        }
                        PropValue::Signal(id) => {
                            b.extend_from_slice(&SOURCE_SIGNAL.to_le_bytes());
                            b.extend_from_slice(&id.0.to_le_bytes());
                        }
                        PropValue::Element { .. } => {
                            panic!("kaya: section properties cannot bind element sources")
                        }
                    }
                })
            }
            TxOp::MenuItemCreate { item, kind } => self.record(TX_MENU_ITEM_CREATE, |b, _| {
                b.extend_from_slice(&item.0.to_le_bytes());
                b.extend_from_slice(&menu_kind_raw(*kind).to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
            }),
            TxOp::MenuItemAppend { parent, child } => self.record(TX_MENU_ITEM_APPEND, |b, _| {
                b.extend_from_slice(&parent.0.to_le_bytes());
                b.extend_from_slice(&child.0.to_le_bytes());
            }),
            TxOp::MenubarAppend { window, item } => self.record(TX_MENUBAR_APPEND, |b, _| {
                b.extend_from_slice(&window.0.to_le_bytes());
                b.extend_from_slice(&item.0.to_le_bytes());
            }),
            TxOp::ContextAttach { widget, item } => self.record(TX_CONTEXT_ATTACH, |b, _| {
                b.extend_from_slice(&widget.0.to_le_bytes());
                b.extend_from_slice(&item.0.to_le_bytes());
            }),
            TxOp::ContextAttachNode { node, item } => {
                self.record(TX_CONTEXT_ATTACH_NODE, |b, _| {
                    b.extend_from_slice(&node.0.to_le_bytes());
                    b.extend_from_slice(&item.0.to_le_bytes());
                })
            }
            TxOp::SetMenuProp { item, prop, value } => self.record(TX_SET_MENU_PROP, |b, blobs| {
                b.extend_from_slice(&item.0.to_le_bytes());
                b.extend_from_slice(&menu_prop_raw(*prop).to_le_bytes());
                match value {
                    PropValue::Const(v) => {
                        b.extend_from_slice(&SOURCE_CONST.to_le_bytes());
                        write_value(b, v, blobs);
                    }
                    PropValue::Signal(id) => {
                        b.extend_from_slice(&SOURCE_SIGNAL.to_le_bytes());
                        b.extend_from_slice(&id.0.to_le_bytes());
                    }
                    PropValue::Element { .. } => {
                        panic!("kaya: menu properties cannot bind element sources")
                    }
                }
            }),
            TxOp::TemplateEnd => self.record(TX_TEMPLATE_END, |_, _| {}),
        }
    }
}

#[cfg(test)]
fn write_path(b: &mut Vec<u8>, path: &Path, blobs: &mut Vec<Arc<[u8]>>) {
    b.extend_from_slice(&(path.len() as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    for key in path {
        write_value(b, key, blobs);
    }
}

/// A typeface request's body: mask, the second word, family, the
/// platform pairs, and the font slot. Both channels call this and
/// differ in ONE word, `second`: the tx record has nothing to say there
/// (a guest cannot name its platform) while the apply record stamps
/// WHICH platform this core is.
fn write_typeface(
    b: &mut Vec<u8>,
    req: &crate::protocol::TypefaceRequest,
    second: u32,
    blobs: &mut Vec<Arc<[u8]>>,
) {
    b.extend_from_slice(&u32::from(req.font.is_some()).to_le_bytes());
    b.extend_from_slice(&second.to_le_bytes());
    write_value(b, &Value::Str(req.family.clone()), blobs);
    // The pair list, written out rather than through write_values:
    // that helper is test-only (the tx encoder is), and this writer
    // serves the APPLY channel, which ships.
    b.extend_from_slice(&((req.platforms.len() * 2) as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    for (tag, family) in &req.platforms {
        write_value(b, &Value::I64(i64::from(*tag)), blobs);
        write_value(b, &Value::Str(family.clone()), blobs);
    }
    // The slot is written either way; see the decoder's note.
    match &req.font {
        Some(bytes) => write_value(b, &Value::Blob(bytes.clone()), blobs),
        None => write_value(b, &Value::Str(String::new()), blobs),
    }
}

/// The app identity's body, shared by the tx and apply channels
/// (docs/app-identity-plan.md I5). The typeface's writer one record
/// along, minus the platform stamp: a family name has to be resolved per
/// platform, a picture does not.
fn write_app_identity(
    b: &mut Vec<u8>,
    identity: &crate::protocol::AppIdentity,
    blobs: &mut Vec<Arc<[u8]>>,
) {
    b.extend_from_slice(&u32::from(identity.icon.is_some()).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    write_value(b, &Value::Str(identity.name.clone()), blobs);
    // The slot is written either way; see the decoder's note.
    match &identity.icon {
        Some(bytes) => write_value(b, &Value::Blob(bytes.clone()), blobs),
        None => write_value(b, &Value::Str(String::new()), blobs),
    }
}

/// A record's fields, count-prefixed — the same shape as a path.
#[cfg(test)]
fn write_values(b: &mut Vec<u8>, values: &[Value], blobs: &mut Vec<Arc<[u8]>>) {
    b.extend_from_slice(&(values.len() as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    for v in values {
        write_value(b, v, blobs);
    }
}

fn kind_raw(kind: WidgetKind) -> u32 {
    match kind {
        WidgetKind::Column => KIND_COLUMN,
        WidgetKind::Button => KIND_BUTTON,
        WidgetKind::Label => KIND_LABEL,
        WidgetKind::Entry => KIND_ENTRY,
        WidgetKind::Row => KIND_ROW,
        WidgetKind::Checkbox => KIND_CHECKBOX,
        WidgetKind::Slider => KIND_SLIDER,
        WidgetKind::Image => KIND_IMAGE,
        WidgetKind::Scroll => KIND_SCROLL,
        WidgetKind::Progress => KIND_PROGRESS,
        WidgetKind::Select => KIND_SELECT,
        WidgetKind::Radio => KIND_RADIO,
        WidgetKind::Grid => KIND_GRID,
        WidgetKind::Textarea => KIND_TEXTAREA,
        WidgetKind::Canvas => KIND_CANVAS,
    }
}


/// The mirror of [`write_clip`]: the header says how many of each
/// plural kind follow, and the canonical order (descending clip value)
/// says which slot is which. ONE DECODER, as there is one encoder.
///
/// A COUNT THAT DOES NOT MATCH THE SLOTS IS A BROKEN BINDING and fails
/// here rather than handing the app half a clip.
fn read_clip(r: &mut Reader<'_>) -> crate::protocol::Clip {
    let present = r.u32();
    let file_count = r.u32() as usize;
    let custom_count = r.u32() as usize;
    let _reserved = r.u32();
    let values = r.record();

    let singles = usize::from(present & CLIP_TEXT != 0)
        + usize::from(present & CLIP_HTML != 0)
        + usize::from(present & CLIP_IMAGE != 0);
    let wanted = singles + file_count + custom_count * 2;
    assert!(
        values.len() == wanted,
        "kaya: copy carries {} values but its header describes {wanted} \
         (text/html/image flags, {file_count} files, {custom_count} custom)",
        values.len()
    );

    let mut it = values.into_iter();
    let mut clip = crate::protocol::Clip::default();
    for _ in 0..custom_count {
        let id = clip_str(it.next(), "custom id");
        assert!(
            !id.is_empty(),
            "kaya: a custom clip representation carries an empty id"
        );
        clip.custom.push((id, clip_blob(it.next(), "custom bytes")));
    }
    for _ in 0..file_count {
        clip.files.push(match it.next() {
            Some(Value::I64(v)) => crate::protocol::PickedId(v as u64),
            other => panic!("kaya: a copied file is {other:?}, wanted a handle"),
        });
    }
    if present & CLIP_IMAGE != 0 {
        clip.image = Some(clip_blob(it.next(), "image"));
    }
    if present & CLIP_HTML != 0 {
        clip.html = Some(clip_str(it.next(), "html"));
    }
    if present & CLIP_TEXT != 0 {
        clip.text = Some(clip_str(it.next(), "text"));
    }
    clip
}

fn clip_str(v: Option<Value>, what: &str) -> String {
    match v {
        Some(Value::Str(s)) => s,
        other => panic!("kaya: clip {what} is {other:?}, wanted a string"),
    }
}

fn clip_blob(v: Option<Value>, what: &str) -> crate::protocol::Blob {
    match v {
        Some(Value::Blob(b)) => b,
        other => panic!("kaya: clip {what} is {other:?}, wanted bytes"),
    }
}

/// A clip's fixed header and its values, in the CANONICAL ORDER:
/// DESCENDING CLIP VALUE — custom (16), files (8), image (4), html (2),
/// text (1). That is PREFERENCE ORDER on every host that has one (macOS
/// pasteboard types, X11 TARGETS), so a backend writes what it is handed in
/// the order it is handed. THE TX HALF IS TEST-ONLY, pinning [`read_clip`];
/// the live apply direction goes through [`write_clip_out`].
#[cfg_attr(not(test), allow(dead_code))]
fn write_clip(
    b: &mut Vec<u8>,
    clip: &crate::protocol::Clip,
    blobs: &mut Vec<std::sync::Arc<[u8]>>,
) {
    let files: Vec<Value> = clip
        .files
        .iter()
        .map(|handle| Value::I64(handle.0 as i64))
        .collect();
    write_clip_fields(
        b,
        clip.text.as_deref(),
        clip.html.as_deref(),
        clip.image.as_ref(),
        &files,
        &clip.custom,
        blobs,
    );
}

/// The apply channel's twin: the same header, the same order, files
/// spelled as the platform's own LOCATORS rather than kaya handles —
/// the one difference between what a guest names and what a backend
/// can put on a clipboard.
fn write_clip_out(
    b: &mut Vec<u8>,
    clip: &crate::protocol::ClipOut,
    blobs: &mut Vec<std::sync::Arc<[u8]>>,
) {
    let files: Vec<Value> = clip
        .files
        .iter()
        .map(|locator| Value::Str(locator.clone()))
        .collect();
    write_clip_fields(
        b,
        clip.text.as_deref(),
        clip.html.as_deref(),
        clip.image.as_ref(),
        &files,
        &clip.custom,
        blobs,
    );
}

/// The header and the canonical order, once. Both channels come
/// through here so the order cannot drift between them; only the file
/// slot's spelling differs, and the caller has already made it.
fn write_clip_fields(
    b: &mut Vec<u8>,
    text: Option<&str>,
    html: Option<&str>,
    image: Option<&crate::protocol::Blob>,
    files: &[Value],
    custom: &[(String, crate::protocol::Blob)],
    blobs: &mut Vec<std::sync::Arc<[u8]>>,
) {
    let mut present = 0u32;
    if text.is_some() {
        present |= CLIP_TEXT;
    }
    if html.is_some() {
        present |= CLIP_HTML;
    }
    if image.is_some() {
        present |= CLIP_IMAGE;
    }
    if !files.is_empty() {
        present |= CLIP_FILES;
    }
    if !custom.is_empty() {
        present |= CLIP_CUSTOM;
    }
    b.extend_from_slice(&present.to_le_bytes());
    b.extend_from_slice(&(files.len() as u32).to_le_bytes());
    b.extend_from_slice(&(custom.len() as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    // The count the Values field needs: one slot per single-valued
    // representation present, one per file, two per custom pair.
    let slots = text.iter().count()
        + html.iter().count()
        + image.iter().count()
        + files.len()
        + custom.len() * 2;
    b.extend_from_slice(&(slots as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    for (id, bytes) in custom {
        write_value(b, &Value::Str(id.clone()), blobs);
        write_value(b, &Value::Blob(bytes.clone()), blobs);
    }
    for file in files {
        write_value(b, file, blobs);
    }
    if let Some(image) = image {
        write_value(b, &Value::Blob(image.clone()), blobs);
    }
    if let Some(html) = html {
        write_value(b, &Value::Str(html.to_owned()), blobs);
    }
    if let Some(text) = text {
        write_value(b, &Value::Str(text.to_owned()), blobs);
    }
}

fn prop_raw(prop: Prop) -> u32 {
    match prop {
        Prop::Text => PROP_TEXT,
        Prop::Checked => PROP_CHECKED,
        Prop::Value => PROP_VALUE,
        Prop::Min => PROP_MIN,
        Prop::Max => PROP_MAX,
        Prop::Source => PROP_SOURCE,
        Prop::Grow => PROP_GROW,
        Prop::Spacing => PROP_SPACING,
        Prop::Align => PROP_ALIGN,
        Prop::Indeterminate => PROP_INDETERMINATE,
        Prop::Columns => PROP_COLUMNS,
        Prop::A11yId => PROP_A11Y_ID,
        Prop::A11yLabel => PROP_A11Y_LABEL,
        Prop::Accepts => PROP_ACCEPTS,
        Prop::Role => PROP_ROLE,
        Prop::Inset => PROP_INSET,
        Prop::Axis => PROP_AXIS,
        Prop::A11yHint => PROP_A11Y_HINT,
    }
}

fn write_value(b: &mut Vec<u8>, value: &Value, blobs: &mut Vec<Arc<[u8]>>) {
    let start = b.len();
    match value {
        Value::Bool(v) => {
            b.extend_from_slice(&VALUE_BOOL.to_le_bytes());
            b.extend_from_slice(&1u32.to_le_bytes());
            b.push(*v as u8);
        }
        Value::I64(v) => {
            b.extend_from_slice(&VALUE_I64.to_le_bytes());
            b.extend_from_slice(&8u32.to_le_bytes());
            b.extend_from_slice(&v.to_le_bytes());
        }
        Value::F64(v) => {
            b.extend_from_slice(&VALUE_F64.to_le_bytes());
            b.extend_from_slice(&8u32.to_le_bytes());
            b.extend_from_slice(&v.to_le_bytes());
        }
        Value::Str(s) => {
            b.extend_from_slice(&VALUE_STR.to_le_bytes());
            b.extend_from_slice(&(s.len() as u32).to_le_bytes());
            b.extend_from_slice(s.as_bytes());
        }
        Value::Blob(blob) => {
            // The bytes never enter the record stream: the value is a
            // 1-based index into the batch's blob table, and the
            // consumer fetches by handle for exactly one batch.
            blobs.push(blob.0.clone());
            b.extend_from_slice(&VALUE_BLOB.to_le_bytes());
            b.extend_from_slice(&8u32.to_le_bytes());
            b.extend_from_slice(&(blobs.len() as u64).to_le_bytes());
        }
    }
    let _ = start;
    while b.len() % 8 != 0 {
        b.push(0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every record kind survives the encode/decode round trip, and EVERY
    /// SPEC RECORD MUST HAVE A DECODE ARM — checked against this file's own
    /// source, since a missing arm only panics when a foreign guest sends
    /// one, which is a matrix leg and not a build (docs/traps.md: "A wire
    /// arm nobody references ships untested, and a dead-code warning is the
    /// only symptom").
    #[test]
    fn every_spec_record_has_a_decode_arm() {
        let src = include_str!("wire.rs");
        let mut missing = Vec::new();
        for row in crate::spec::SPEC.tx {
            let arm = format!("TX_{} =>", row.name.to_uppercase());
            if !src.contains(&arm) {
                missing.push(arm);
            }
        }
        assert!(
            missing.is_empty(),
            "spec tx records with no decoder arm in wire.rs: {missing:?} — a \
             foreign guest sending one hits the catch-all and panics on a \
             matrix leg instead of here"
        );
    }

    #[test]
    fn transaction_round_trip() {
        let ops = vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: Value::from("Clicked 0 times"),
            },
            TxOp::CreateWidget {
                id: WidgetId(1),
                kind: WidgetKind::Column,
            },
            TxOp::CreateWidget {
                id: WidgetId(2),
                kind: WidgetKind::Button,
            },
            TxOp::SetProperty {
                widget: WidgetId(2),
                prop: Prop::Text,
                value: PropValue::Const(Value::from("Click me")),
            },
            TxOp::CreateWidget {
                id: WidgetId(3),
                kind: WidgetKind::Label,
            },
            TxOp::SetProperty {
                widget: WidgetId(3),
                prop: Prop::Text,
                value: PropValue::Signal(SignalId(1)),
            },
            TxOp::CreateBreakpoint {
                window: WindowId(0),
                when: i64::from(SIZE_CLASS_COMPACT),
                setters: vec![(WidgetId(1), Prop::Axis, Value::I64(1))],
            },
            TxOp::AddChild {
                parent: WidgetId(1),
                child: WidgetId(2),
            },
            TxOp::AddChild {
                parent: WidgetId(1),
                child: WidgetId(3),
            },
            TxOp::Mount {
                window: WindowId(0),
                root: WidgetId(1),
            },
            TxOp::WriteSignal {
                id: SignalId(1),
                value: Value::I64(-7),
            },
            TxOp::WidgetCommand {
                widget: WidgetId(2),
                command: CommandKind::Clear,
            },
            TxOp::WidgetCommand {
                widget: WidgetId(2),
                command: CommandKind::Focus,
            },
        ];
        let mut w = Writer::new();
        for op in &ops {
            w.tx_op(op);
        }
        let decoded = decode_transaction(&w.into_bytes());
        assert_eq!(decoded.len(), ops.len());
        for (a, b) in ops.iter().zip(decoded.iter()) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"));
        }
    }

    /// The safe-integer contract's boundary, both sides (spec.rs's
    /// MAX_SAFE_INTEGER; ruled 2026-08-31 for the ninth binding and
    /// enforced for all nine): ±(2^53 − 1) round-trips exactly, and
    /// one past it is refused at the decode chokepoint with the
    /// sentence that names the fix. The negative is watched — with
    /// the guard deleted this test FAILS (no panic), which is the
    /// difference between a wall and a comment.
    #[test]
    fn safe_integer_boundary_round_trips() {
        for v in [
            crate::spec::MAX_SAFE_INTEGER,
            -crate::spec::MAX_SAFE_INTEGER,
            0,
            1,
            -1,
        ] {
            let mut w = Writer::new();
            w.tx_op(&TxOp::WriteSignal {
                id: SignalId(1),
                value: Value::I64(v),
            });
            let decoded = decode_transaction(&w.into_bytes());
            assert_eq!(decoded.len(), 1);
            assert_eq!(
                format!("{:?}", decoded[0]),
                format!(
                    "{:?}",
                    TxOp::WriteSignal {
                        id: SignalId(1),
                        value: Value::I64(v),
                    }
                )
            );
        }
    }

    #[test]
    #[should_panic(expected = "outside ±(2^53 − 1)")]
    fn an_integer_past_the_safe_range_is_refused() {
        let mut w = Writer::new();
        w.tx_op(&TxOp::WriteSignal {
            id: SignalId(1),
            value: Value::I64(crate::spec::MAX_SAFE_INTEGER + 1),
        });
        decode_transaction(&w.into_bytes());
    }

    #[test]
    #[should_panic(expected = "outside ±(2^53 − 1)")]
    fn a_negative_integer_past_the_safe_range_is_refused() {
        let mut w = Writer::new();
        w.tx_op(&TxOp::WriteSignal {
            id: SignalId(1),
            value: Value::I64(-(crate::spec::MAX_SAFE_INTEGER + 1)),
        });
        decode_transaction(&w.into_bytes());
    }

    /// Blobs ride every value position — a signal's initial, a write,
    /// a record field — as batch-local handles; the bytes live in the
    /// writer's table and the decoder resolves them back. Content
    /// equality crosses the allocation boundary (Blob's PartialEq).
    #[test]
    fn blob_values_round_trip_by_handle() {
        use crate::protocol::Blob;
        let png: &[u8] = &[0x89, b'P', b'N', b'G', 0, 159, 146, 150];
        let ops = vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: Value::Blob(Blob::from(png)),
            },
            TxOp::CollectionInsert {
                id: CollectionId(2),
                path: vec![],
                key: Value::from("a"),
                variant: 0,
                record: vec![Value::from("avatar"), Value::Blob(Blob::from(png))],
            },
        ];
        let mut w = Writer::new();
        for op in &ops {
            w.tx_op(op);
        }
        // The record stream stays small: two blob references cost 16
        // payload bytes, not two copies of the image.
        assert_eq!(w.blobs.len(), 2);
        let table = w.blobs.clone();
        let bytes = w.into_bytes();
        let decoded = wire_decode_with(&bytes, &table);
        assert_eq!(decoded.len(), ops.len());
        for (a, b) in ops.iter().zip(decoded.iter()) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"));
        }
    }

    fn wire_decode_with(bytes: &[u8], table: &[Arc<[u8]>]) -> Transaction {
        decode_transaction_with_blobs(bytes, &|h| {
            usize::try_from(h).ok().and_then(|h| h.checked_sub(1)).and_then(|i| table.get(i)).cloned()
        })
    }

    /// A handle with no registration is a broken binding, loudly.
    #[test]
    #[should_panic(expected = "blob handle 1 is not registered")]
    fn unregistered_blob_handle_fails_loudly() {
        use crate::protocol::Blob;
        let mut w = Writer::new();
        w.tx_op(&TxOp::CreateSignal {
            id: SignalId(1),
            initial: Value::Blob(Blob::from(&b"x"[..])),
        });
        decode_transaction(&w.into_bytes());
    }

    #[test]
    #[should_panic(expected = "unknown transaction record kind")]
    fn unknown_kind_fails_loudly() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&8u32.to_le_bytes());
        buf.extend_from_slice(&999u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        decode_transaction(&buf);
    }

    #[test]
    fn structural_ops_round_trip() {
        use crate::protocol::CollectionId;
        let ops = vec![
            // A sum: Note{Str} | Todo{Str, Bool}; a record collection is
            // the one-variant case of the same encoding.
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![
                    vec![ValueType::Str],
                    vec![ValueType::Str, ValueType::Bool],
                ],
            },
            TxOp::CreateFor { id: 2, collection: CollectionId(1) },
            TxOp::VariantCase { variant: 0 },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(3),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::VariantCase { variant: 1 },
            TxOp::TemplateEnd,
            TxOp::CreateWhen { id: 4, signal: SignalId(9) },
            TxOp::TemplateEnd,
            TxOp::CollectionInsert {
                id: CollectionId(1),
                path: vec![],
                key: Value::from("g1"),
                variant: 0,
                record: vec![Value::from("Work")],
            },
            TxOp::CollectionUpdate {
                id: CollectionId(7),
                path: vec![Value::from("g1"), Value::I64(4)],
                key: Value::I64(4),
                variant: 1,
                record: vec![Value::from("Work"), Value::Bool(true)],
            },
            TxOp::CollectionUpdateField {
                id: CollectionId(7),
                path: vec![Value::from("g1")],
                key: Value::I64(4),
                variant: 1,
                field: 1,
                value: Value::Bool(false),
            },
            TxOp::CollectionRemove {
                id: CollectionId(7),
                path: vec![Value::from("g1")],
                key: Value::from("a"),
            },
            TxOp::CollectionMove {
                id: CollectionId(7),
                path: vec![Value::from("g1")],
                key: Value::from("c"),
                before: Some(Value::from("a")),
            },
            TxOp::CollectionMove {
                id: CollectionId(7),
                path: vec![],
                key: Value::from("a"),
                before: None,
            },
        ];
        let mut w = Writer::new();
        for op in &ops {
            w.tx_op(op);
        }
        let decoded = decode_transaction(&w.into_bytes());
        assert_eq!(decoded.len(), ops.len());
        for (a, b) in ops.iter().zip(decoded.iter()) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"));
        }
    }

    /// The header bar out and back — titles with spaces (the reason a
    /// Str prop could not carry them), the sentinel, and both
    /// directions — plus the sort body's column patch and its decode
    /// on both identity shapes.
    #[test]
    fn set_columns_round_trips_and_the_sort_body_patches() {
        let ops = vec![
            TxOp::SetColumnHeaders {
                widget: WidgetId(4),
                sorted: SORT_NONE,
                direction: SORT_ASC,
                path: Vec::new(),
                titles: vec!["Name".into(), "Date Modified".into()],
            },
            TxOp::SetColumnHeaders {
                widget: WidgetId(4),
                sorted: 1,
                direction: SORT_DESC,
                path: Vec::new(),
                titles: vec!["Name".into(), "Size".into(), "Kind".into()],
            },
            // The keyed shape: a stamped copy's re-declaration, keys
            // outermost first (docs/tables-plan.md, dynamic tables).
            TxOp::SetColumnHeaders {
                widget: WidgetId(7),
                sorted: 0,
                direction: SORT_ASC,
                path: vec![Value::Str("brokerage".into()), Value::I64(3)],
                titles: vec!["Ticker".into(), "Qty".into()],
            },
        ];
        let mut w = Writer::new();
        for op in &ops {
            w.tx_op(op);
        }
        let decoded = decode_transaction(&w.into_bytes());
        assert_eq!(decoded.len(), ops.len());
        for (a, b) in ops.iter().zip(decoded.iter()) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"));
        }

        let live = click_tag(4, &[]);
        match decode_sort_tag(&live, 2) {
            Occurrence::SortRequested { id, column } => {
                assert_eq!(id, WidgetId(4));
                assert_eq!(column, 2);
            }
            other => panic!("unexpected: {other:?}"),
        }
        // The body IS the tag with the column in the reserved slot.
        let body = sort_body(&live, 2);
        assert_eq!(&body[..12], &live[..12]);
        assert_eq!(u32::from_le_bytes(body[12..16].try_into().unwrap()), 2);
        let stamped = click_tag(9, &[Value::from("g1"), Value::I64(4)]);
        match decode_sort_tag(&stamped, 0) {
            Occurrence::InstanceSortRequested { node, path, column } => {
                assert_eq!(node, TemplateNodeId(9));
                assert_eq!(path, vec![Value::from("g1"), Value::I64(4)]);
                assert_eq!(column, 0);
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    /// THE SIZE POLICY'S RECORD AND ITS TWO ASKS, out and back
    /// (docs/canvas-plan.md §3.2.1). The two occurrence bodies differ by
    /// ONE TRAILING VALUE, which is exactly the shape where a decoder
    /// reading the wrong one gets a plausible number rather than an
    /// error: a tick read as a draw request drops its time silently, and
    /// a draw request read as a tick reads past the end.
    #[test]
    fn the_size_policy_and_its_asks_round_trip() {
        let ops = vec![
            TxOp::SetSizePolicy { widget: WidgetId(3), policy: SIZE_POLICY_FIXED },
            TxOp::SetSizePolicy { widget: WidgetId(4), policy: SIZE_POLICY_TICK },
        ];
        let mut w = Writer::new();
        for op in &ops {
            w.tx_op(op);
        }
        let decoded = decode_transaction(&w.into_bytes());
        assert_eq!(decoded.len(), ops.len());
        for (a, b) in ops.iter().zip(decoded.iter()) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"));
        }

        let live = draw_body(7, &[], (400.5, 120.0), None);
        assert_eq!(
            decode_draw_requested(&live),
            Occurrence::DrawRequested { id: WidgetId(7), size: (400.5, 120.0) }
        );
        let ticked = draw_body(7, &[], (400.5, 120.0), Some(0.05));
        assert_eq!(
            decode_tick(&ticked),
            Occurrence::Tick { id: WidgetId(7), size: (400.5, 120.0), time: 0.05 }
        );
        // The tick's body is the draw request's plus one value, and
        // reading it as a draw request would silently lose the time.
        assert!(ticked.len() > live.len());
        assert_eq!(&ticked[..live.len()], &live[..]);
        // The stamped shapes, which the core does not emit today but the
        // grammar carries: keys first, then the numbers.
        let keys = [Value::from("row"), Value::I64(2)];
        assert_eq!(
            decode_tick(&draw_body(9, &keys, (10.0, 20.0), Some(1.0))),
            Occurrence::InstanceTick {
                node: TemplateNodeId(9),
                path: keys.to_vec(),
                size: (10.0, 20.0),
                time: 1.0,
            }
        );
        assert_eq!(
            decode_draw_requested(&draw_body(9, &keys, (10.0, 20.0), None)),
            Occurrence::InstanceDrawRequested {
                node: TemplateNodeId(9),
                path: keys.to_vec(),
                size: (10.0, 20.0),
            }
        );
    }

    /// BOTH DIALOG REQUESTS, out and back, because what can break is the
    /// difference: the picker carries a flag then a list, the save request a
    /// STR AND THEN A LIST — a shape no other tx record has, where a decoder
    /// reading the name's padding as the list's count gets a garbage length.
    /// The no-filters save request is here so a mis-sized name runs off the end.
    #[test]
    fn dialog_requests_round_trip() {
        use crate::protocol::{FileDialogId, FileDialogSpec, SaveDialogSpec};
        let ops = vec![
            TxOp::ShowFileDialog(FileDialogSpec {
                window: WindowId(0),
                dialog: FileDialogId(7),
                multiple: true,
                filters: vec![("Text".into(), "txt md".into())],
            }),
            TxOp::ShowSaveDialog(SaveDialogSpec {
                window: WindowId(3),
                dialog: FileDialogId(8),
                suggested_name: "notes".into(),
                filters: vec![],
            }),
            TxOp::ShowSaveDialog(SaveDialogSpec {
                window: WindowId(0),
                dialog: FileDialogId(9),
                // A name whose length is not a multiple of 8, so the
                // padding between the Str and the values count has to be
                // right rather than accidentally right.
                suggested_name: "a-rather-long-suggested-name.txt".into(),
                filters: vec![
                    ("Text".into(), "txt".into()),
                    ("Markdown".into(), "md markdown".into()),
                ],
            }),
        ];
        let mut w = Writer::new();
        for op in &ops {
            w.tx_op(op);
        }
        let decoded = decode_transaction(&w.into_bytes());
        assert_eq!(decoded.len(), ops.len());
        for (a, b) in ops.iter().zip(decoded.iter()) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"));
        }
    }

    /// The TX_COPY record, out and back: what a foreign binding packs by
    /// hand is what the root reads (docs/traps.md: "A wire arm nobody
    /// references ships untested, and a dead-code warning is the only
    /// symptom"). THE MIXED CLIP IS THE ONE THAT CAN FAIL — one
    /// representation round-trips under any order — with two customs and two
    /// files, because a count read as a flag passes at one. The empty clip
    /// is the other end.
    #[test]
    fn copy_records_round_trip() {
        use crate::protocol::{Blob, Clip, PickedId};
        let png: &[u8] = &[0x89, b'P', b'N', b'G', 0, 159, 146, 150];
        let ops = vec![
            TxOp::Copy(Clip::default()),
            TxOp::Copy(Clip {
                text: Some("kaya clip".into()),
                ..Clip::default()
            }),
            TxOp::Copy(Clip {
                text: Some("kaya clip".into()),
                html: Some("<b>kaya</b> clip".into()),
                image: Some(Blob::from(png)),
                files: vec![PickedId(7), PickedId(9)],
                custom: vec![
                    ("dev.kaya/note".into(), Blob::from(&b"note=1"[..])),
                    ("dev.kaya/card".into(), Blob::from(&b"{}"[..])),
                ],
            }),
        ];
        let mut w = Writer::new();
        for op in &ops {
            w.tx_op(op);
        }
        let table = w.blobs.clone();
        let decoded = wire_decode_with(&w.into_bytes(), &table);
        assert_eq!(decoded.len(), ops.len());
        for (a, b) in ops.iter().zip(decoded.iter()) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"));
        }
    }

    /// A header that disagrees with the slots it describes is a broken
    /// binding, and it says so rather than handing the app half a clip.
    ///
    /// The disagreement is INTRODUCED BY HAND, because no encoder in
    /// this file can produce it. Record layout: 8-byte record header,
    /// then present / file count / custom count / reserved, so bytes
    /// 12..16 are the file count.
    #[test]
    #[should_panic(expected = "copy carries 1 values but its header describes 2")]
    fn clip_header_disagreeing_with_its_slots_fails_loudly() {
        use crate::protocol::Clip;
        let mut w = Writer::new();
        w.tx_op(&TxOp::Copy(Clip {
            text: Some("kaya clip".into()),
            ..Clip::default()
        }));
        let mut bytes = w.into_bytes();
        assert_eq!(
            bytes[12..16],
            0u32.to_le_bytes(),
            "the file count is not where this test thinks it is"
        );
        bytes[12..16].copy_from_slice(&1u32.to_le_bytes());
        decode_transaction(&bytes);
    }

    /// The two clipboard occurrences, out and back — including the blob that
    /// never enters the record stream. THE BLOB HANDLE IS THE POINT: a
    /// batch-local index reused here would name a slot in whatever batch the
    /// pump was serving. The decode redeems through the occurrence table as a
    /// binding does, and RELEASES — a leak there is a megabyte per paste.
    #[test]
    fn clipboard_occurrences_round_trip() {
        use crate::protocol::Representation as R;

        // A binding's decode: redeem, copy, release.
        let resolve = |h: u64| -> Option<Arc<[u8]>> {
            let mut len = 0usize;
            let p = unsafe { crate::capi::kaya_occurrence_blob(h, &mut len) };
            if p.is_null() {
                return None;
            }
            let bytes: Arc<[u8]> = Arc::from(unsafe { std::slice::from_raw_parts(p, len) });
            crate::capi::kaya_occurrence_blob_release(h);
            Some(bytes)
        };

        let cases = vec![
            None,
            Some(R::Text("milk".into())),
            Some(R::Html("<b>milk</b>".into())),
            Some(R::Image(crate::protocol::Blob(Arc::from(&b"PNG"[..])))),
            Some(R::Custom {
                id: "dev.kaya/note".into(),
                bytes: crate::protocol::Blob(Arc::from(&b"{}"[..])),
            }),
            Some(R::Files(vec![crate::protocol::PickedFile {
                handle: crate::protocol::PickedId(7),
                name: "notes.txt".into(),
                local_path: "/tmp/notes.txt".into(),
            }])),
        ];

        for want in cases {
            let body = clipboard_result_body(42, want.as_ref());
            let mut r = Reader { buf: &body, at: 0, blobs: &resolve };
            assert_eq!(r.u64(), 42);
            let kind = r.u32();
            let _reserved = r.u32();
            assert_eq!(read_representation(kind, r.path()), want);

            let Some(clip) = want else { continue };
            // The same payload, reached through a widget and through a
            // stamped copy: one record kind, the click tag deciding.
            let body = pasted_body(&click_tag(5, &[]), &clip);
            let mut r = Reader { buf: &body, at: 0, blobs: &resolve };
            assert_eq!(r.u64(), 5);
            assert!(r.path().is_empty(), "an empty path is a live widget");
            let kind = r.u32();
            let _reserved = r.u32();
            assert_eq!(read_representation(kind, r.path()), Some(clip.clone()));

            let path = vec![Value::from("g1")];
            let body = pasted_body(&click_tag(8, &path), &clip);
            let mut r = Reader { buf: &body, at: 0, blobs: &resolve };
            assert_eq!(r.u64(), 8);
            assert_eq!(r.path(), path);
            let kind = r.u32();
            let _reserved = r.u32();
            assert_eq!(read_representation(kind, r.path()), Some(clip));
        }
    }

    /// The undo payload's four runs survive the trip, INCLUDING the shapes a
    /// reader gets wrong: a record with more fields than the fixed head, an
    /// absent entry with no record, a non-empty instance path, and an order
    /// group whose length differs from the entry count. THE TEXTS RUN CARRIES
    /// BOTH IDENTITIES, in that order — a reader that kept a fixed-arity pair
    /// reading takes the group's SIZE for the widget id.
    #[test]
    fn undo_bodies_round_trip() {
        use crate::protocol::{UndoDelta, UndoEntry, UndoOrder, UndoText};
        let delta = UndoDelta {
            signals: vec![
                (SignalId(3), Value::from("one")),
                (SignalId(9), Value::Bool(true)),
            ],
            texts: vec![
                UndoText {
                    id: 2,
                    path: vec![],
                    text: "milk bread".into(),
                },
                UndoText {
                    id: 31,
                    path: vec![Value::from("g1"), Value::I64(4)],
                    text: "row note".into(),
                },
            ],
            entries: vec![
                UndoEntry {
                    collection: CollectionId(1),
                    path: vec![],
                    key: Value::from("a"),
                    state: Some((0, vec![Value::from("Alpha"), Value::Bool(false)])),
                },
                UndoEntry {
                    collection: CollectionId(1),
                    path: vec![Value::from("g1"), Value::I64(4)],
                    key: Value::I64(7),
                    state: None,
                },
            ],
            orders: vec![UndoOrder {
                collection: CollectionId(1),
                path: vec![],
                keys: vec![Value::from("a"), Value::from("b"), Value::from("c")],
            }],
        };
        let body = undo_body(WindowId(2), "shuffle", &delta);
        assert!(body.len() % 8 == 0, "bodies must stay 8-aligned for the ring");
        let (window, label, back) = decode_undo_body(&body);
        assert_eq!(window, WindowId(2));
        assert_eq!(label, "shuffle");
        assert_eq!(back, delta);
        // The empty payload is a real one: an episode redo carries a
        // text and nothing else, and a label-only record must decode.
        let bare = undo_body(WindowId(0), "", &UndoDelta::default());
        assert_eq!(
            decode_undo_body(&bare),
            (WindowId(0), String::new(), UndoDelta::default())
        );

        // THE GROUP'S VALUES, PINNED ONE BY ONE. A round trip passes for
        // any self-consistent encoder, including one that wrote the path
        // before the length or forgot to count the size itself; the
        // eight bindings are written against THIS table, so it is the
        // table that has to be right.
        let pinned = undo_body(
            WindowId(1),
            "",
            &UndoDelta {
                texts: vec![UndoText {
                    id: 7,
                    path: vec![Value::I64(3)],
                    text: "ha".into(),
                }],
                ..UndoDelta::default()
            },
        );
        let mut r = Reader { buf: &pinned, at: 0, blobs: &|_| None };
        assert_eq!(r.u64(), 1);
        assert_eq!((r.u32(), r.u32(), r.u32(), r.u32()), (0, 1, 0, 0));
        assert_eq!(r.value(), Value::Str(String::new()));
        assert_eq!(
            r.record(),
            vec![
                Value::I64(5), // size, counting itself: 3 ints + 1 path key + the text
                Value::I64(7), // id — a template node, because the path below is not empty
                Value::I64(1), // path_len
                Value::I64(3), // the copy's key
                Value::from("ha"),
            ]
        );
    }

    #[test]
    fn click_tags_round_trip() {
        let plain = click_tag(5, &[]);
        assert_eq!(
            decode_click_tag(&plain),
            Occurrence::ButtonClicked { id: WidgetId(5) }
        );
        let path = vec![Value::from("g2"), Value::I64(4)];
        let tagged = click_tag(8, &path);
        assert_eq!(
            decode_click_tag(&tagged),
            Occurrence::InstanceButtonClicked {
                node: TemplateNodeId(8),
                path,
            }
        );
        assert!(tagged.len() % 8 == 0, "tags must stay 8-aligned for the ring");
    }

    /// The same identity tags carry entry edits: tag + text value out,
    /// TextChanged occurrences back.
    #[test]
    fn text_changed_round_trips() {
        assert_eq!(
            decode_text_changed_tag(&click_tag(5, &[]), "milk"),
            Occurrence::TextChanged {
                id: WidgetId(5),
                text: "milk".into(),
            }
        );
        let path = vec![Value::from("g1")];
        assert_eq!(
            decode_text_changed_tag(&click_tag(8, &path), "eggs"),
            Occurrence::InstanceTextChanged {
                node: TemplateNodeId(8),
                path,
                text: "eggs".into(),
            }
        );
        // The wire body is tag bytes then one value: the parser side of
        // this (generated per language) reads keys, then the text.
        let body = text_changed_body(&click_tag(5, &[]), "milk");
        let mut r = Reader { buf: &body, at: 0, blobs: &|_| None };
        assert_eq!(r.u64(), 5);
        assert!(r.path().is_empty());
        assert_eq!(r.value(), Value::from("milk"));
        assert!(body.len() % 8 == 0, "bodies must stay 8-aligned for the ring");
    }

    /// The same identity tags carry toggles: tag + Bool value out,
    /// Toggled occurrences back.
    #[test]
    fn toggled_round_trips() {
        assert_eq!(
            decode_toggled_tag(&click_tag(5, &[]), true),
            Occurrence::Toggled {
                id: WidgetId(5),
                checked: true,
            }
        );
        let path = vec![Value::from("g1")];
        assert_eq!(
            decode_toggled_tag(&click_tag(8, &path), false),
            Occurrence::InstanceToggled {
                node: TemplateNodeId(8),
                path,
                checked: false,
            }
        );
        let body = toggled_body(&click_tag(5, &[]), true);
        let mut r = Reader { buf: &body, at: 0, blobs: &|_| None };
        assert_eq!(r.u64(), 5);
        assert!(r.path().is_empty());
        assert_eq!(r.value(), Value::Bool(true));
        assert!(body.len() % 8 == 0, "bodies must stay 8-aligned for the ring");
    }

    #[test]
    fn values_round_trip() {
        for v in [
            Value::Bool(true),
            // i64::MIN is refused since the safe-integer contract
            // (spec.rs's MAX_SAFE_INTEGER); the boundary tests hold
            // the integer extremes.
            Value::I64(-crate::spec::MAX_SAFE_INTEGER),
            Value::F64(2.5),
            Value::Str("héllo".into()),
        ] {
            let mut w = Writer::new();
            w.tx_op(&TxOp::WriteSignal {
                id: SignalId(9),
                value: v.clone(),
            });
            match &decode_transaction(&w.into_bytes())[0] {
                TxOp::WriteSignal { value, .. } => assert_eq!(*value, v),
                other => panic!("wrong op: {other:?}"),
            }
        }
    }
}
