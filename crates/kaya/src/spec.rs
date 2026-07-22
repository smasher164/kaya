//! The protocol, as data: the root document the binding generator walks.
//!
//! Rust is the root. This module is the single machine-readable
//! statement of the wire vocabulary — enums and record layouts — and
//! tools/kaya-bindgen consumes it as a library to emit each language's
//! vocabulary file. wire.rs remains the hand-written implementation;
//! the tests at the bottom hold the two together (a spec-driven
//! generic encoder must round-trip through wire.rs's decoder, and every
//! constant must match), so drift fails cargo test rather than
//! surfacing as a guest whose bytes the core rejects.
//!
//! Field types are deliberately few: every record is a sequence drawn
//! from { u32, u64, value, values, type_tags }, where value is the
//! tagged scalar encoding, values is a count-prefixed sequence of them
//! (a key path or an entry's record — same shape, different meaning),
//! and type_tags is a count-prefixed sequence of u32 value-type tags (a
//! collection's schema). New vocabulary should be new records over
//! these types, not new types — that is what keeps eight bindings
//! mechanical.

/// A record field: its name (for generated helper signatures and docs)
/// and its wire type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Field {
    pub name: &'static str,
    pub ty: FieldTy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FieldTy {
    /// Little-endian u32.
    U32,
    /// Little-endian u64 (ids of every space).
    U64,
    /// { u32 type; u32 len; payload padded to 8 }.
    Value,
    /// { u32 count; u32 reserved; count values }: a key path or an
    /// entry's record — one encoding, named by the field.
    Values,
    /// { u32 variant_count; u32 reserved; per variant: u32 field_count,
    /// field_count u32 value-type tags; padded to 8 }: one schema per
    /// variant of a collection's element sum. A record collection is
    /// the one-variant case.
    VariantSchemas,
}

/// One record kind of a channel: the numeric kind, a name, its fields
/// in wire order, and a one-line doc. `payload` is the type of the one
/// trailing value an occurrence carries after its key path (None for
/// clicks and every non-occurrence record) — a spec fact, so the
/// generated parsers' payload-kind lists derive rather than drift.
#[derive(Debug, Clone, Copy)]
pub struct Record {
    pub kind: u16,
    pub name: &'static str,
    pub fields: &'static [Field],
    pub payload: Option<PropKind>,
    pub doc: &'static str,
}

/// A named constant group (widget kinds, value types, ...).
#[derive(Debug, Clone, Copy)]
pub struct EnumSpec {
    pub name: &'static str,
    pub variants: &'static [(&'static str, u32)],
}

/// The whole vocabulary. One value, walked by the generator.
#[derive(Debug, Clone, Copy)]
pub struct ProtocolSpec {
    /// Transaction records (guest -> core, via kaya_submit).
    pub tx: &'static [Record],
    /// Apply records (core -> presentation pump, via kaya_next_commands).
    pub apply: &'static [Record],
    /// Occurrence records (core -> guest, via the ring or
    /// kaya_next_occurrence). The record header is shared by all
    /// channels: { u32 size; u16 kind; u16 flags }, 8-aligned.
    pub occurrence: &'static [Record],
    pub enums: &'static [EnumSpec],
}

const fn f(name: &'static str, ty: FieldTy) -> Field {
    Field { name, ty }
}

/// A typed wire slot's value type: drives the generated typed setters
/// (set_text takes a string, set_checked a bool, in every language)
/// and names occurrence payload types (Record::payload).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PropKind {
    Str,
    Bool,
    F64,
    /// Bulk payload bytes by handle (an image's encoded source). The
    /// typed setter takes the language's bytes form; the wire carries
    /// the registration handle.
    Blob,
    /// A closed set of named values — one of the spec's enums, named
    /// here. Rides the wire as I64; every binding exposes its
    /// language's native enum over the generated constants.
    Enum(&'static str),
}

/// Properties with their wire ids and value kinds; kept in lockstep
/// with the "prop" enum (pinned by test).
pub const PROPS: &[(&'static str, u32, PropKind)] = &[
    ("text", 1, PropKind::Str),
    ("checked", 2, PropKind::Bool),
    ("value", 3, PropKind::F64),
    ("min", 4, PropKind::F64),
    ("max", 5, PropKind::F64),
    ("source", 6, PropKind::Blob),
    ("grow", 7, PropKind::F64),
    ("spacing", 8, PropKind::F64),
    ("align", 9, PropKind::Enum("align")),
    // Progress-only: the bar shows activity without a fraction
    // (pulse/spinner mode). Bool, default false; Value carries the
    // determinate fraction (0..=1, domain-checked at the root).
    ("indeterminate", 10, PropKind::Bool),
];

/// Window properties: the presentation-context twin of PROPS, kept
/// in its own table because windows are not widgets — the scene
/// core's widget domain checks stay widget-pure, and the constants
/// get their own namespace in every binding. `title` is uniform with
/// per-platform materialization (title bar, UIScene.title, the
/// Activity task label); `width`/`height` are the ADVISORY initial
/// content size in DIP — a request on every platform, honored where
/// the window manager permits (see DESIGN.md, Presentation
/// contexts). Window 0 is the primary surface and always exists.
pub const WINDOW_PROPS: &[(&'static str, u32, PropKind)] = &[
    ("title", 1, PropKind::Str),
    ("width", 2, PropKind::F64),
    ("height", 3, PropKind::F64),
    // Who owns the chrome close. False (the default): native — an aux
    // window just closes (window_closed reports it), and closing the
    // primary exits the app. True: the close button EMITS
    // close_requested and nothing closes until the app answers with
    // destroy_window — the veto class, armed by opt-in, the way the
    // platforms themselves gate it (windowShouldClose delegate
    // presence). Inert on mobile by physics: no chrome close, and
    // back is not close (DESIGN.md, Presentation contexts).
    ("veto_close", 4, PropKind::Bool),
];

/// Navigation-entry properties: their own typed table, deliberately
/// not WINDOW_PROPS with applicability checks — the tables are spec
/// facts and the emitters' typed setters are the point (a
/// wrong-surface prop dies at compile time in every binding rather
/// than at the scene). `title` feeds the back affordance (the iOS
/// back-button label, the desktop headers). `intercept_back` is the
/// close-veto class transplanted to POP: false (the default) = the
/// platform pops natively with its full predictive animation; true =
/// the back affordance emits back_requested and nothing pops until
/// the app answers with pop_entry (Android's own declared-ahead
/// OnBackPressedCallback model — see DESIGN.md, Navigation).
pub const ENTRY_PROPS: &[(&'static str, u32, PropKind)] = &[
    ("title", 1, PropKind::Str),
    ("intercept_back", 2, PropKind::Bool),
];

/// The variable tail of SET_PROPERTY, after `source`: a value for
/// SOURCE_CONST, a u64 signal id for SOURCE_SIGNAL, or u32 level + u32
/// reserved for SOURCE_ELEMENT. The one record whose layout depends on
/// a discriminant; generators emit one helper per source rather than a
/// union type.
pub const SET_PROPERTY_NOTE: &str =
    "tail after `source`: value (SOURCE_CONST) | u64 signal_id (SOURCE_SIGNAL) \
     | u32 level, u32 field (SOURCE_ELEMENT — which field of the element's \
     record; 0 for a scalar collection)";

/// A deterministic fingerprint of the whole vocabulary: every record
/// kind, field name and type, enum variant, and prop. The core exports
/// it (capi::kaya_spec_hash), the generator bakes it into every wire
/// file, and every runtime asserts the two agree at load — so a guest
/// generated from one spec revision can never talk silently past a
/// core built from another (the stale-artifact bug class: an old
/// dylib/DLL decoding new bytes as garbage).
pub fn hash() -> u64 {
    // FNV-1a, over a canonical walk. Stable across platforms and
    // builds by construction; any spec edit changes it.
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |bytes: &[u8]| {
        for b in bytes {
            h ^= u64::from(*b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        h ^= 0xff; // separator
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    };
    for (channel, records) in [("tx", SPEC.tx), ("apply", SPEC.apply), ("occ", SPEC.occurrence)] {
        eat(channel.as_bytes());
        for r in records {
            eat(&r.kind.to_le_bytes());
            eat(r.name.as_bytes());
            for f in r.fields {
                eat(f.name.as_bytes());
                eat(format!("{:?}", f.ty).as_bytes());
            }
            eat(format!("{:?}", r.payload).as_bytes());
        }
    }
    for e in SPEC.enums {
        eat(e.name.as_bytes());
        for (name, value) in e.variants {
            eat(name.as_bytes());
            eat(&value.to_le_bytes());
        }
    }
    for (name, id, kind) in PROPS {
        eat(name.as_bytes());
        eat(&id.to_le_bytes());
        eat(format!("{kind:?}").as_bytes());
    }
    eat(b"window_props");
    for (name, id, kind) in WINDOW_PROPS {
        eat(name.as_bytes());
        eat(&id.to_le_bytes());
        eat(format!("{kind:?}").as_bytes());
    }
    eat(b"entry_props");
    for (name, id, kind) in ENTRY_PROPS {
        eat(name.as_bytes());
        eat(&id.to_le_bytes());
        eat(format!("{kind:?}").as_bytes());
    }
    h
}

pub const SPEC: ProtocolSpec = ProtocolSpec {
    tx: &[
        Record {
            kind: 1,
            name: "create_signal",
            fields: &[f("signal_id", FieldTy::U64), f("initial", FieldTy::Value)],
            payload: None,
            doc: "Create a signal holding `initial`.",
        },
        Record {
            kind: 2,
            name: "write_signal",
            fields: &[f("signal_id", FieldTy::U64), f("value", FieldTy::Value)],
            payload: None,
            doc: "Replace a signal's value; keep-latest per batch.",
        },
        Record {
            kind: 3,
            name: "create_widget",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("kind", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "Create a live widget, or declare a template node inside a scope.",
        },
        Record {
            kind: 4,
            name: "set_property",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("prop", FieldTy::U32),
                f("source", FieldTy::U32),
            ],
            payload: None,
            doc: "Bind a property; see SET_PROPERTY_NOTE for the tail.",
        },
        Record {
            kind: 5,
            name: "add_child",
            fields: &[f("parent", FieldTy::U64), f("child", FieldTy::U64)],
            payload: None,
            doc: "Append `child` to `parent` (same zone only).",
        },
        Record {
            kind: 6,
            name: "mount",
            fields: &[f("window", FieldTy::U64), f("root", FieldTy::U64)],
            payload: None,
            doc: "Mount a root into a window (0 = the default window).",
        },
        Record {
            kind: 7,
            name: "create_collection",
            fields: &[
                f("collection_id", FieldTy::U64),
                f("variants", FieldTy::VariantSchemas),
            ],
            payload: None,
            doc: "Declare a collection and its schema: one ordered \
                  field-type list per variant of the element sum. A record \
                  collection is the one-variant case and a scalar collection \
                  the one-variant one-field case. Variants are indices; \
                  names never travel. A blueprint when inside a template.",
        },
        Record {
            kind: 8,
            name: "collection_insert",
            fields: &[
                f("collection_id", FieldTy::U64),
                f("path", FieldTy::Values),
                f("key", FieldTy::Value),
                f("variant", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("fields", FieldTy::Values),
            ],
            payload: None,
            doc: "Insert an entry into the instance at `path`; the fields \
                  match `variant`'s schema positionally. Stamps a copy from \
                  that variant's case.",
        },
        Record {
            kind: 9,
            name: "collection_update",
            fields: &[
                f("collection_id", FieldTy::U64),
                f("path", FieldTy::Values),
                f("key", FieldTy::Value),
                f("variant", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("fields", FieldTy::Values),
            ],
            payload: None,
            doc: "Replace an entry's record; every element binding follows. \
                  A different `variant` than the entry's current one tears \
                  down its stamped copy and restamps from the new variant's \
                  case, in place.",
        },
        Record {
            kind: 10,
            name: "collection_remove",
            fields: &[
                f("collection_id", FieldTy::U64),
                f("path", FieldTy::Values),
                f("key", FieldTy::Value),
            ],
            payload: None,
            doc: "Remove an entry; its stamped copy tears down.",
        },
        Record {
            kind: 11,
            name: "create_for",
            fields: &[f("id", FieldTy::U64), f("collection_id", FieldTy::U64)],
            payload: None,
            doc: "A For over a collection; opens a template scope until template_end.",
        },
        Record {
            kind: 12,
            name: "create_when",
            fields: &[f("id", FieldTy::U64), f("signal_id", FieldTy::U64)],
            payload: None,
            doc: "A When over a Bool signal; opens a template scope until template_end.",
        },
        Record {
            kind: 13,
            name: "template_end",
            fields: &[],
            payload: None,
            doc: "Close the innermost template scope.",
        },
        Record {
            kind: 15,
            name: "collection_move",
            fields: &[
                f("collection_id", FieldTy::U64),
                f("path", FieldTy::Values),
                f("key", FieldTy::Value),
                f("before", FieldTy::Values),
            ],
            payload: None,
            doc: "Move an entry so it sits before the entry whose key is the \
                  one value in `before`, or to the end when `before` is \
                  empty. Keys, never indices: order is data, and indices \
                  would race the very deltas that change them.",
        },
        Record {
            kind: 14,
            name: "collection_update_field",
            fields: &[
                f("collection_id", FieldTy::U64),
                f("path", FieldTy::Values),
                f("key", FieldTy::Value),
                f("field", FieldTy::U32),
                f("variant", FieldTy::U32),
                f("value", FieldTy::Value),
            ],
            payload: None,
            doc: "Set one field of an entry's record; only bindings on that \
                  field re-resolve. `variant` is the discriminant the guest \
                  witnessed in the match that produced this write — the \
                  scene asserts it against the entry's stored variant, so a \
                  drifted model fails loudly; it never changes a \
                  constructor (update does).",
        },
        Record {
            kind: 16,
            name: "variant_case",
            fields: &[
                f("variant", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "Inside a For over a sum: the records that follow (until \
                  the next variant_case or template_end) are the blueprint \
                  for this variant. Cases must be total at template_end; an \
                  empty case renders a constructor as nothing, explicitly.",
        },
        Record {
            kind: 17,
            name: "widget_command",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("command", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "A one-shot command aimed at a live widget: momentary, \
                  fire-and-forget, never state at rest — the app's \
                  sanctioned crossing into widget-owned state (clear, \
                  focus). The widget answers through its normal occurrence \
                  path; nothing is recorded and nothing replays on rebuild. \
                  The command enum is the closed vocabulary; each verb is \
                  admitted by a real artifact, per the escalation policy.",
        },
        Record {
            kind: 18,
            name: "set_window_prop",
            fields: &[
                f("window", FieldTy::U64),
                f("prop", FieldTy::U32),
                f("source", FieldTy::U32),
            ],
            payload: None,
            doc: "Bind a window property (WINDOW_PROPS; window 0 = the \
                  primary surface). Same tail convention as \
                  SET_PROPERTY_NOTE, except SOURCE_ELEMENT is rejected — \
                  windows are not collection elements.",
        },
        Record {
            kind: 19,
            name: "create_window",
            fields: &[f("window_id", FieldTy::U64)],
            payload: None,
            doc: "Create an auxiliary window (capability-gated: a host \
                  without KAYA_CAP_AUX_WINDOWS rejects it at the root). \
                  Materializes hidden; mounting a root presents it. Ids are \
                  guest-allocated, below the internal bit; 0 is the primary \
                  and always exists.",
        },
        Record {
            kind: 20,
            name: "destroy_window",
            fields: &[f("window_id", FieldTy::U64)],
            payload: None,
            doc: "Close and forget an auxiliary window: the native window \
                  and its views are released wholesale, and the scene \
                  forgets the mounted tree (widget ids are never reused, so \
                  stale entries are inert). The primary is not destroyable: \
                  the process owns it.",
        },
        Record {
            kind: 21,
            name: "show_alert",
            fields: &[
                f("window", FieldTy::U64),
                f("alert", FieldTy::U64),
                f("actions", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("title", FieldTy::Value),
                f("message", FieldTy::Value),
                f("action0", FieldTy::Value),
                f("action1", FieldTy::Value),
                f("cancel", FieldTy::Value),
            ],
            payload: None,
            doc: "Request a modal alert over a live window (0 = primary): \
                  the request/result grammar's first client (DESIGN.md, \
                  Presentation contexts). One atomic record: title, \
                  message, `actions` action labels (0..=2 — the platform \
                  floor; ContentDialog's three slots are two actions plus \
                  close), and the always-present cancel slot, which is \
                  what EVERY platform-native dismissal (Esc, back, outside \
                  tap) resolves to. All five Values are Str; action slots \
                  beyond `actions` ride empty and are ignored. Alert ids \
                  are guest-chosen; one alert may be live per process, and \
                  the id retires when its result fires.",
        },
        Record {
            kind: 22,
            name: "push_entry",
            fields: &[f("window", FieldTy::U64), f("entry", FieldTy::U64)],
            payload: None,
            doc: "Push a navigation entry onto `window`'s stack (0 = the \
                  primary surface; no capability gate — every host \
                  materializes a serial stack natively). Entry ids share \
                  the surface namespace with windows: one guest-side \
                  allocator, and mount's target field addresses either. \
                  Materializes covered/incoming; mounting a root into it \
                  presents it. The covered root below stays alive — \
                  retained until popped (DESIGN.md, Navigation).",
        },
        Record {
            kind: 23,
            name: "pop_entry",
            fields: &[f("window", FieldTy::U64)],
            payload: None,
            doc: "Pop the top navigation entry from `window`'s stack and \
                  forget its mounted tree, exactly as destroy_window does \
                  (ids are never reused, so stale targets fail loudly). \
                  Popping an empty stack is a scene error. Multi-pop is \
                  binding sugar: N of these in one transaction, animated \
                  by backends as the NET stack change per batch.",
        },
        Record {
            kind: 24,
            name: "set_entry_prop",
            fields: &[
                f("entry", FieldTy::U64),
                f("prop", FieldTy::U32),
                f("source", FieldTy::U32),
            ],
            payload: None,
            doc: "Bind a navigation-entry property (ENTRY_PROPS). Same tail \
                  convention as SET_PROPERTY_NOTE, except SOURCE_ELEMENT is \
                  rejected — entries are not collection elements.",
        },
    ],
    apply: &[
        Record {
            kind: 1,
            name: "create",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("kind", FieldTy::U32),
                f("tag_len", FieldTy::U32),
            ],
            payload: None,
            doc: "Create a widget; tag_len bytes follow (padded to 8): the \
                  click tag an interactive widget emits verbatim.",
        },
        Record {
            kind: 2,
            name: "set_prop",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("prop", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("value", FieldTy::Value),
            ],
            payload: None,
            doc: "Set a property to an already-resolved value.",
        },
        Record {
            kind: 3,
            name: "add_child",
            fields: &[f("parent", FieldTy::U64), f("child", FieldTy::U64)],
            payload: None,
            doc: "Append `child` to `parent`.",
        },
        Record {
            kind: 4,
            name: "mount",
            fields: &[f("window", FieldTy::U64), f("root", FieldTy::U64)],
            payload: None,
            doc: "Mount a root into a window.",
        },
        Record {
            kind: 6,
            name: "move_child",
            fields: &[
                f("parent", FieldTy::U64),
                f("child", FieldTy::U64),
                f("before", FieldTy::U64),
            ],
            payload: None,
            doc: "Reposition `child` among `parent`'s children: before the \
                  sibling `before`, or to the end when `before` is 0 (widget \
                  ids start at 1).",
        },
        Record {
            kind: 5,
            name: "destroy",
            fields: &[f("widget_id", FieldTy::U64)],
            payload: None,
            doc: "Remove the widget from its parent and forget it; \
                  teardown arrives children-first.",
        },
        Record {
            kind: 7,
            name: "command",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("command", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "Execute a one-shot command on a widget, then let the \
                  widget report the result through its normal occurrence \
                  path (a clear arrives back as text_changed with empty \
                  text, through the same delegate a keystroke uses).",
        },
        Record {
            kind: 8,
            name: "set_window_prop",
            fields: &[
                f("window", FieldTy::U64),
                f("prop", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("value", FieldTy::Value),
            ],
            payload: None,
            doc: "Set a window property to an already-resolved value.",
        },
        Record {
            kind: 9,
            name: "create_window",
            fields: &[f("window_id", FieldTy::U64)],
            payload: None,
            doc: "Create the native window, hidden until a mount presents it.",
        },
        Record {
            kind: 10,
            name: "destroy_window",
            fields: &[f("window_id", FieldTy::U64)],
            payload: None,
            doc: "Close and release the native window.",
        },
        Record {
            kind: 11,
            name: "present_alert",
            fields: &[
                f("window", FieldTy::U64),
                f("alert", FieldTy::U64),
                f("actions", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("title", FieldTy::Value),
                f("message", FieldTy::Value),
                f("action0", FieldTy::Value),
                f("action1", FieldTy::Value),
                f("cancel", FieldTy::Value),
            ],
            payload: None,
            doc: "Present the platform's real modal dialog over the window \
                  (SHOW_ALERT, already validated by the core). The \
                  presentation answers with kaya_emit_alert_result exactly \
                  once — an action index, or the cancel sentinel for every \
                  platform-native dismissal.",
        },
        Record {
            kind: 12,
            name: "push_entry",
            fields: &[f("window", FieldTy::U64), f("entry", FieldTy::U64)],
            payload: None,
            doc: "Push a navigation entry onto the window's stack, hidden \
                  until a mount presents it. The covered root stays alive.",
        },
        Record {
            kind: 13,
            name: "pop_entry",
            fields: &[f("window", FieldTy::U64)],
            payload: None,
            doc: "Pop the window's top entry and release its views; the \
                  net stack change of the whole batch animates as ONE \
                  transition (the multi-pop obligation).",
        },
        Record {
            kind: 14,
            name: "set_entry_prop",
            fields: &[
                f("entry", FieldTy::U64),
                f("prop", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("value", FieldTy::Value),
            ],
            payload: None,
            doc: "Set a navigation-entry property to an already-resolved \
                  value.",
        },
    ],
    occurrence: &[
        Record {
            kind: 1,
            name: "button_clicked",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "path_len key values follow. path_len 0: id is a widget id. \
                  Otherwise: id is a template node id and the values are the \
                  copy's key path, outermost first.",
        },
        Record {
            kind: 2,
            name: "text_changed",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: Some(PropKind::Str),
            doc: "path_len key values follow, then the entry's new text as \
                  one value. Identity reads as in button_clicked. The widget \
                  owns its text; the app folds these into its own model. \
                  USER edits and commands (clear acts like the user) emit; \
                  a property write is configuration and never echoes.",
        },
        Record {
            kind: 3,
            name: "toggled",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: Some(PropKind::Bool),
            doc: "path_len key values follow, then the checkbox's new state \
                  as one Bool value. Same shape, ownership, and \
                  user-only-emits stance as text_changed.",
        },
        Record {
            kind: 4,
            name: "value_changed",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: Some(PropKind::F64),
            doc: "path_len key values follow, then the widget's new value as \
                  one F64 value: the slider's position, or the select's new \
                  selected index (integral, 0-based). One occurrence per \
                  USER change (programmatic writes never echo — without \
                  that, a handler writing back a different value would \
                  ping-pong forever); same ownership stance.",
        },
        Record {
            kind: 5,
            name: "close_requested",
            fields: &[f("window_id", FieldTy::U64)],
            payload: None,
            doc: "The user asked a veto_close window to close. Nothing has \
                  closed; the app answers with destroy_window if it agrees. \
                  No response is required and there are no correlation ids \
                  — the request/confirm veto class (see DESIGN.md).",
        },
        Record {
            kind: 6,
            name: "window_closed",
            fields: &[f("window_id", FieldTy::U64)],
            payload: None,
            doc: "A non-veto auxiliary window was closed by its chrome. \
                  Informational and post-fact: the native window is gone \
                  and the core has already pruned its tree.",
        },
        Record {
            kind: 7,
            name: "alert_result",
            fields: &[
                f("alert", FieldTy::U64),
                f("choice", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "The alert's one answer: choice is an ALERT_CHOICE value — \
                  an action index (0 or 1), or `cancel` for every \
                  platform-native dismissal (Esc, back, outside tap, the \
                  cancel button itself). The alert id retires here; the \
                  dialog is already gone when this fires.",
        },
        Record {
            kind: 8,
            name: "entry_popped",
            fields: &[f("entry", FieldTy::U64)],
            payload: None,
            doc: "The user's back affordance popped an entry natively \
                  (predictive back, swipe-back, the desktop back button) \
                  — informational and post-fact, the window_closed \
                  precedent; the core's stack has already reconciled. A \
                  programmatic pop_entry does not echo here: its caller \
                  already knows.",
        },
        Record {
            kind: 9,
            name: "back_requested",
            fields: &[f("entry", FieldTy::U64)],
            payload: None,
            doc: "The user drove the back affordance on an entry whose \
                  intercept_back is armed. Nothing has popped; the app \
                  answers with pop_entry if it agrees — the veto class, \
                  the close_requested precedent.",
        },
    ],
    enums: &[
        EnumSpec {
            name: "value",
            variants: &[("bool", 1), ("i64", 2), ("f64", 3), ("str", 4), ("blob", 5)],
        },
        EnumSpec {
            name: "kind",
            variants: &[
                ("column", 1),
                ("button", 2),
                ("label", 3),
                ("entry", 4),
                ("row", 5),
                ("checkbox", 6),
                ("slider", 7),
                ("image", 8),
                ("scroll", 9),
                ("progress", 10),
                ("select", 11),
            ],
        },
        EnumSpec {
            name: "prop",
            variants: &[
                ("text", 1),
                ("checked", 2),
                ("value", 3),
                ("min", 4),
                ("max", 5),
                ("source", 6),
                ("grow", 7),
                ("spacing", 8),
                ("align", 9),
                ("indeterminate", 10),
            ],
        },
        EnumSpec {
            name: "wprop",
            variants: &[
                ("title", 1),
                ("width", 2),
                ("height", 3),
                ("veto_close", 4),
            ],
        },
        EnumSpec {
            name: "eprop",
            variants: &[("title", 1), ("intercept_back", 2)],
        },
        EnumSpec {
            // The sentinel is deliberately not an index: any
            // platform-native dismissal resolves to it, and action
            // indices can grow without colliding.
            name: "alert_choice",
            variants: &[
                ("action0", 0),
                ("action1", 1),
                ("cancel", 4294967295),
            ],
        },
        EnumSpec {
            name: "align",
            variants: &[
                ("start", 0),
                ("center", 1),
                ("end", 2),
                ("stretch", 3),
                ("baseline", 4),
            ],
        },
        EnumSpec {
            name: "source",
            variants: &[("const", 0), ("signal", 1), ("element", 2)],
        },
        EnumSpec {
            name: "occurrence",
            variants: &[
                ("pad", 0),
                ("button_clicked", 1),
                ("text_changed", 2),
                ("toggled", 3),
                ("value_changed", 4),
            ],
        },
        EnumSpec {
            name: "command",
            variants: &[("clear", 1), ("focus", 2)],
        },
    ],
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{
        AlertId, AlertSpec, CollectionId, CommandKind, Prop, PropValue, SignalId, TxOp, Value,
        ValueType, WidgetId, WidgetKind, WindowId,
    };
    use crate::wire;

    /// A spec-driven generic encoder: what any generated binding does,
    /// expressed once here. If this encodes and wire.rs decodes to the
    /// expected op, the generated bindings agree with the core.
    struct GenericWriter {
        buf: Vec<u8>,
        // The batch's blob table, exactly as a generated binding and
        // the pump keep one: values reference bytes by 1-based index.
        blobs: Vec<std::sync::Arc<[u8]>>,
    }

    enum Arg {
        U32(u32),
        U64(u64),
        Value(Value),
        Values(Vec<Value>),
        VariantSchemas(Vec<Vec<u32>>),
    }

    impl GenericWriter {
        fn record(&mut self, rec: &Record, args: &[Arg]) {
            assert_eq!(rec.fields.len(), args.len(), "{} arity", rec.name);
            let start = self.buf.len();
            self.buf.extend_from_slice(&[0u8; 8]);
            for (field, arg) in rec.fields.iter().zip(args) {
                match (field.ty, arg) {
                    (FieldTy::U32, Arg::U32(v)) => self.buf.extend_from_slice(&v.to_le_bytes()),
                    (FieldTy::U64, Arg::U64(v)) => self.buf.extend_from_slice(&v.to_le_bytes()),
                    (FieldTy::Value, Arg::Value(v)) => self.value(v),
                    (FieldTy::Values, Arg::Values(p)) => {
                        self.buf.extend_from_slice(&(p.len() as u32).to_le_bytes());
                        self.buf.extend_from_slice(&0u32.to_le_bytes());
                        for v in p {
                            self.value(v);
                        }
                    }
                    (FieldTy::VariantSchemas, Arg::VariantSchemas(variants)) => {
                        self.buf
                            .extend_from_slice(&(variants.len() as u32).to_le_bytes());
                        self.buf.extend_from_slice(&0u32.to_le_bytes());
                        for schema in variants {
                            self.buf
                                .extend_from_slice(&(schema.len() as u32).to_le_bytes());
                            for tag in schema {
                                self.buf.extend_from_slice(&tag.to_le_bytes());
                            }
                        }
                        while self.buf.len() % 8 != 0 {
                            self.buf.push(0);
                        }
                    }
                    (ty, _) => panic!("{}.{}: wrong arg for {ty:?}", rec.name, field.name),
                }
            }
            while self.buf.len() % 8 != 0 {
                self.buf.push(0);
            }
            let size = (self.buf.len() - start) as u32;
            self.buf[start..start + 4].copy_from_slice(&size.to_le_bytes());
            self.buf[start + 4..start + 6].copy_from_slice(&rec.kind.to_le_bytes());
        }

        fn value(&mut self, v: &Value) {
            let (ty, payload): (u32, Vec<u8>) = match v {
                Value::Bool(b) => (1, vec![*b as u8]),
                Value::I64(n) => (2, n.to_le_bytes().to_vec()),
                Value::F64(x) => (3, x.to_le_bytes().to_vec()),
                Value::Str(s) => (4, s.as_bytes().to_vec()),
                // What a generated binding writes for a blob: the u64
                // registration handle, never the bytes. The test's
                // decode resolver maps handles back to bytes.
                Value::Blob(b) => {
                    self.blobs.push(b.0.clone());
                    (5, (self.blobs.len() as u64).to_le_bytes().to_vec())
                }
            };
            self.buf.extend_from_slice(&ty.to_le_bytes());
            self.buf.extend_from_slice(&(payload.len() as u32).to_le_bytes());
            self.buf.extend_from_slice(&payload);
            while self.buf.len() % 8 != 0 {
                self.buf.push(0);
            }
        }
    }

    fn tx_record(name: &str) -> &'static Record {
        SPEC.tx.iter().find(|r| r.name == name).unwrap()
    }

    /// The fingerprint is stable and nonzero; a spec edit that fails
    /// to change it would let revisions collide, so eat() separates
    /// every component.
    #[test]
    fn spec_hash_is_stable() {
        assert_ne!(hash(), 0);
        assert_eq!(hash(), hash());
    }

    /// Every tx record kind pins to wire.rs's constants.
    #[test]
    fn tx_kinds_match_wire() {
        let pins: &[(&str, u16)] = &[
            ("create_signal", wire::TX_CREATE_SIGNAL),
            ("write_signal", wire::TX_WRITE_SIGNAL),
            ("create_widget", wire::TX_CREATE_WIDGET),
            ("set_property", wire::TX_SET_PROPERTY),
            ("add_child", wire::TX_ADD_CHILD),
            ("mount", wire::TX_MOUNT),
            ("create_collection", wire::TX_CREATE_COLLECTION),
            ("collection_insert", wire::TX_COLLECTION_INSERT),
            ("collection_update", wire::TX_COLLECTION_UPDATE),
            ("collection_remove", wire::TX_COLLECTION_REMOVE),
            ("create_for", wire::TX_CREATE_FOR),
            ("create_when", wire::TX_CREATE_WHEN),
            ("template_end", wire::TX_TEMPLATE_END),
            ("collection_update_field", wire::TX_COLLECTION_UPDATE_FIELD),
            ("collection_move", wire::TX_COLLECTION_MOVE),
            ("variant_case", wire::TX_VARIANT_CASE),
            ("widget_command", wire::TX_WIDGET_COMMAND),
            ("set_window_prop", wire::TX_SET_WINDOW_PROP),
            ("create_window", wire::TX_CREATE_WINDOW),
            ("destroy_window", wire::TX_DESTROY_WINDOW),
            ("show_alert", wire::TX_SHOW_ALERT),
            ("push_entry", wire::TX_PUSH_ENTRY),
            ("pop_entry", wire::TX_POP_ENTRY),
            ("set_entry_prop", wire::TX_SET_ENTRY_PROP),
        ];
        assert_eq!(pins.len(), SPEC.tx.len());
        for (name, kind) in pins {
            assert_eq!(tx_record(name).kind, *kind, "{name}");
        }
    }

    #[test]
    fn apply_and_occurrence_kinds_match_wire() {
        let apply: Vec<(&str, u16)> = SPEC.apply.iter().map(|r| (r.name, r.kind)).collect();
        assert_eq!(
            apply,
            vec![
                ("create", wire::APPLY_CREATE),
                ("set_prop", wire::APPLY_SET_PROP),
                ("add_child", wire::APPLY_ADD_CHILD),
                ("mount", wire::APPLY_MOUNT),
                ("move_child", wire::APPLY_MOVE_CHILD),
                ("destroy", wire::APPLY_DESTROY),
                ("command", wire::APPLY_COMMAND),
                ("set_window_prop", wire::APPLY_SET_WINDOW_PROP),
                ("create_window", wire::APPLY_CREATE_WINDOW),
                ("destroy_window", wire::APPLY_DESTROY_WINDOW),
                ("present_alert", wire::APPLY_PRESENT_ALERT),
                ("push_entry", wire::APPLY_PUSH_ENTRY),
                ("pop_entry", wire::APPLY_POP_ENTRY),
                ("set_entry_prop", wire::APPLY_SET_ENTRY_PROP),
            ]
        );
        assert_eq!(SPEC.occurrence[0].kind, crate::ring::REC_BUTTON_CLICKED);
        assert_eq!(SPEC.occurrence[1].kind, crate::ring::REC_TEXT_CHANGED);
        assert_eq!(SPEC.occurrence[2].kind, crate::ring::REC_TOGGLED);
        assert_eq!(SPEC.occurrence[3].kind, crate::ring::REC_VALUE_CHANGED);
        assert_eq!(SPEC.occurrence[4].kind, crate::ring::REC_CLOSE_REQUESTED);
        assert_eq!(SPEC.occurrence[5].kind, crate::ring::REC_WINDOW_CLOSED);
        assert_eq!(SPEC.occurrence[6].kind, crate::ring::REC_ALERT_RESULT);
        assert_eq!(SPEC.occurrence[7].kind, crate::ring::REC_ENTRY_POPPED);
        assert_eq!(SPEC.occurrence[8].kind, crate::ring::REC_BACK_REQUESTED);
    }

    /// PROPS and the "prop" enum stay in lockstep: same names, same
    /// ids, same order — the enum feeds constants, PROPS feeds the
    /// typed setter generation.
    #[test]
    fn props_match_prop_enum() {
        let prop_enum = SPEC
            .enums
            .iter()
            .find(|e| e.name == "prop")
            .expect("spec has a prop enum");
        assert_eq!(PROPS.len(), prop_enum.variants.len());
        for ((name, id, _), (ename, eid)) in PROPS.iter().zip(prop_enum.variants) {
            assert_eq!(name, ename);
            assert_eq!(id, eid);
        }
        let wprop_enum = SPEC
            .enums
            .iter()
            .find(|e| e.name == "wprop")
            .expect("spec has a wprop enum");
        assert_eq!(WINDOW_PROPS.len(), wprop_enum.variants.len());
        for ((name, id, _), (ename, eid)) in WINDOW_PROPS.iter().zip(wprop_enum.variants) {
            assert_eq!(name, ename);
            assert_eq!(id, eid);
        }
        let eprop_enum = SPEC
            .enums
            .iter()
            .find(|e| e.name == "eprop")
            .expect("spec has an eprop enum");
        assert_eq!(ENTRY_PROPS.len(), eprop_enum.variants.len());
        for ((name, id, _), (ename, eid)) in ENTRY_PROPS.iter().zip(eprop_enum.variants) {
            assert_eq!(name, ename);
            assert_eq!(id, eid);
        }
    }

    #[test]
    fn enums_match_wire() {
        for e in SPEC.enums {
            for (name, value) in e.variants {
                let expected = match (e.name, *name) {
                    ("value", "bool") => wire::VALUE_BOOL,
                    ("value", "i64") => wire::VALUE_I64,
                    ("value", "f64") => wire::VALUE_F64,
                    ("value", "str") => wire::VALUE_STR,
                    ("value", "blob") => wire::VALUE_BLOB,
                    ("kind", "column") => wire::KIND_COLUMN,
                    ("kind", "button") => wire::KIND_BUTTON,
                    ("kind", "label") => wire::KIND_LABEL,
                    ("kind", "entry") => wire::KIND_ENTRY,
                    ("kind", "row") => wire::KIND_ROW,
                    ("kind", "checkbox") => wire::KIND_CHECKBOX,
                    ("kind", "slider") => wire::KIND_SLIDER,
                    ("kind", "image") => wire::KIND_IMAGE,
                    ("kind", "scroll") => wire::KIND_SCROLL,
                    ("kind", "progress") => wire::KIND_PROGRESS,
                    ("kind", "select") => wire::KIND_SELECT,
                    ("prop", "text") => wire::PROP_TEXT,
                    ("prop", "checked") => wire::PROP_CHECKED,
                    ("prop", "value") => wire::PROP_VALUE,
                    ("prop", "min") => wire::PROP_MIN,
                    ("prop", "max") => wire::PROP_MAX,
                    ("prop", "source") => wire::PROP_SOURCE,
                    ("prop", "grow") => wire::PROP_GROW,
                    ("prop", "spacing") => wire::PROP_SPACING,
                    ("prop", "align") => wire::PROP_ALIGN,
                    ("prop", "indeterminate") => wire::PROP_INDETERMINATE,
                    ("wprop", "title") => wire::WPROP_TITLE,
                    ("wprop", "width") => wire::WPROP_WIDTH,
                    ("wprop", "height") => wire::WPROP_HEIGHT,
                    ("wprop", "veto_close") => wire::WPROP_VETO_CLOSE,
                    ("eprop", "title") => wire::EPROP_TITLE,
                    ("eprop", "intercept_back") => wire::EPROP_INTERCEPT_BACK,
                    ("alert_choice", "action0") => wire::ALERT_CHOICE_ACTION0,
                    ("alert_choice", "action1") => wire::ALERT_CHOICE_ACTION1,
                    ("alert_choice", "cancel") => wire::ALERT_CHOICE_CANCEL,
                    ("align", "start") => wire::ALIGN_START,
                    ("align", "center") => wire::ALIGN_CENTER,
                    ("align", "end") => wire::ALIGN_END,
                    ("align", "stretch") => wire::ALIGN_STRETCH,
                    ("align", "baseline") => wire::ALIGN_BASELINE,
                    ("command", "clear") => wire::COMMAND_CLEAR,
                    ("command", "focus") => wire::COMMAND_FOCUS,
                    ("source", "const") => wire::SOURCE_CONST,
                    ("source", "signal") => wire::SOURCE_SIGNAL,
                    ("source", "element") => wire::SOURCE_ELEMENT,
                    ("occurrence", "pad") => crate::ring::REC_PAD as u32,
                    ("occurrence", "button_clicked") => crate::ring::REC_BUTTON_CLICKED as u32,
                    ("occurrence", "text_changed") => crate::ring::REC_TEXT_CHANGED as u32,
                    ("occurrence", "toggled") => crate::ring::REC_TOGGLED as u32,
                    ("occurrence", "value_changed") => crate::ring::REC_VALUE_CHANGED as u32,
                    other => panic!("unpinned enum variant {other:?}"),
                };
                assert_eq!(*value, expected, "{}::{}", e.name, name);
            }
        }
    }

    /// Encode every fixed-layout tx record through the spec and decode
    /// through wire.rs: what a generated binding writes is what the core
    /// reads.
    #[test]
    fn spec_encoding_round_trips_through_wire() {
        let mut w = GenericWriter { buf: Vec::new(), blobs: Vec::new() };
        w.record(
            tx_record("create_signal"),
            &[Arg::U64(1), Arg::Value(Value::from("step 0"))],
        );
        w.record(
            tx_record("create_widget"),
            &[Arg::U64(2), Arg::U32(wire::KIND_BUTTON), Arg::U32(0)],
        );
        w.record(
            tx_record("create_collection"),
            &[
                Arg::U64(3),
                // A sum: Note{Str} | Todo{Str, Bool} — the record
                // collection is the one-variant case of this encoding.
                Arg::VariantSchemas(vec![
                    vec![wire::VALUE_STR],
                    vec![wire::VALUE_STR, wire::VALUE_BOOL],
                ]),
            ],
        );
        w.record(
            tx_record("collection_insert"),
            &[
                Arg::U64(3),
                Arg::Values(vec![Value::from("g1")]),
                Arg::Value(Value::from("a")),
                Arg::U32(1),
                Arg::U32(0),
                Arg::Values(vec![Value::from("send report"), Value::Bool(false)]),
            ],
        );
        w.record(
            tx_record("collection_update_field"),
            &[
                Arg::U64(3),
                Arg::Values(vec![Value::from("g1")]),
                Arg::Value(Value::from("a")),
                Arg::U32(1),
                Arg::U32(1),
                Arg::Value(Value::Bool(true)),
            ],
        );
        w.record(tx_record("variant_case"), &[Arg::U32(1), Arg::U32(0)]);
        w.record(
            tx_record("collection_remove"),
            &[
                Arg::U64(3),
                Arg::Values(vec![]),
                Arg::Value(Value::from("g1")),
            ],
        );
        w.record(tx_record("create_for"), &[Arg::U64(4), Arg::U64(3)]);
        w.record(tx_record("template_end"), &[]);
        w.record(tx_record("mount"), &[Arg::U64(0), Arg::U64(2)]);
        w.record(
            tx_record("widget_command"),
            &[Arg::U64(2), Arg::U32(wire::COMMAND_FOCUS), Arg::U32(0)],
        );
        w.record(
            tx_record("show_alert"),
            &[
                Arg::U64(0),
                Arg::U64(9),
                Arg::U32(2),
                Arg::U32(0),
                Arg::Value(Value::from("delete item?")),
                Arg::Value(Value::from("this cannot be undone")),
                Arg::Value(Value::from("Delete")),
                Arg::Value(Value::from("Archive")),
                Arg::Value(Value::from("Keep")),
            ],
        );

        w.record(tx_record("push_entry"), &[Arg::U64(0), Arg::U64(7)]);
        // set_entry_prop carries the SET_PROPERTY variable tail after
        // its fixed fields — spliced by hand, as a generated helper
        // would (the set_property arm below is the same shape).
        {
            let start = w.buf.len();
            w.buf.extend_from_slice(&[0u8; 8]);
            w.buf.extend_from_slice(&7u64.to_le_bytes());
            w.buf.extend_from_slice(&wire::EPROP_TITLE.to_le_bytes());
            w.buf.extend_from_slice(&wire::SOURCE_CONST.to_le_bytes());
            w.value(&Value::from("detail"));
            let size = (w.buf.len() - start) as u32;
            w.buf[start..start + 4].copy_from_slice(&size.to_le_bytes());
            w.buf[start + 4..start + 6].copy_from_slice(&wire::TX_SET_ENTRY_PROP.to_le_bytes());
        }
        w.record(tx_record("pop_entry"), &[Arg::U64(0)]);

        let ops = wire::decode_transaction(&w.buf);
        let expected: Vec<TxOp> = vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: Value::from("step 0"),
            },
            TxOp::CreateWidget {
                id: WidgetId(2),
                kind: WidgetKind::Button,
            },
            TxOp::CreateCollection {
                id: CollectionId(3),
                variants: vec![
                    vec![ValueType::Str],
                    vec![ValueType::Str, ValueType::Bool],
                ],
            },
            TxOp::CollectionInsert {
                id: CollectionId(3),
                path: vec![Value::from("g1")],
                key: Value::from("a"),
                variant: 1,
                record: vec![Value::from("send report"), Value::Bool(false)],
            },
            TxOp::CollectionUpdateField {
                id: CollectionId(3),
                path: vec![Value::from("g1")],
                key: Value::from("a"),
                variant: 1,
                field: 1,
                value: Value::Bool(true),
            },
            TxOp::VariantCase { variant: 1 },
            TxOp::CollectionRemove {
                id: CollectionId(3),
                path: vec![],
                key: Value::from("g1"),
            },
            TxOp::CreateFor {
                id: 4,
                collection: CollectionId(3),
            },
            TxOp::TemplateEnd,
            TxOp::Mount {
                window: WindowId(0),
                root: WidgetId(2),
            },
            TxOp::WidgetCommand {
                widget: WidgetId(2),
                command: CommandKind::Focus,
            },
            TxOp::ShowAlert(AlertSpec {
                window: WindowId(0),
                alert: AlertId(9),
                title: "delete item?".into(),
                message: "this cannot be undone".into(),
                actions: vec!["Delete".into(), "Archive".into()],
                cancel: "Keep".into(),
            }),
            TxOp::PushEntry {
                window: WindowId(0),
                entry: WindowId(7),
            },
            TxOp::SetEntryProp {
                entry: WindowId(7),
                prop: crate::protocol::EntryProp::Title,
                value: PropValue::Const(Value::from("detail")),
            },
            TxOp::PopEntry {
                window: WindowId(0),
            },
        ];
        assert_eq!(ops.len(), expected.len());
        for (a, b) in ops.iter().zip(expected.iter()) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"));
        }
        // And the variable-tail record, one arm per source.
        let mut w = GenericWriter { buf: Vec::new(), blobs: Vec::new() };
        w.record(
            tx_record("set_property"),
            &[Arg::U64(2), Arg::U32(wire::PROP_TEXT), Arg::U32(wire::SOURCE_CONST)],
        );
        // Splice the const tail in by hand, as a generated helper would.
        let mut buf = w.buf;
        buf.truncate(buf.len()); // record already padded; rebuild with tail
        let mut w = GenericWriter { buf: Vec::new(), blobs: Vec::new() };
        let start = 0;
        w.buf.extend_from_slice(&[0u8; 8]);
        w.buf.extend_from_slice(&2u64.to_le_bytes());
        w.buf.extend_from_slice(&wire::PROP_TEXT.to_le_bytes());
        w.buf.extend_from_slice(&wire::SOURCE_CONST.to_le_bytes());
        w.value(&Value::from("step"));
        let size = (w.buf.len() - start) as u32;
        w.buf[0..4].copy_from_slice(&size.to_le_bytes());
        w.buf[4..6].copy_from_slice(&wire::TX_SET_PROPERTY.to_le_bytes());
        match &wire::decode_transaction(&w.buf)[0] {
            TxOp::SetProperty {
                widget,
                prop,
                value: PropValue::Const(v),
            } => {
                assert_eq!(*widget, WidgetId(2));
                assert_eq!(*prop, Prop::Text);
                assert_eq!(*v, Value::from("step"));
            }
            other => panic!("wrong op: {other:?}"),
        }
    }
}
