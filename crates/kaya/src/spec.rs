//! The protocol, as data: the root document the binding generator walks
//! (invariant 7); wire.rs is the hand-written implementation and the
//! tests at the bottom hold the two together. New vocabulary is new
//! RECORDS over the existing field types, never new types.

/// THE SAFE-INTEGER CONTRACT (ruled 2026-08-31): a kaya integer is a
/// COUNT or a QUANTITY, exact to ±(2^53 − 1) in every binding, and the
/// wire refuses one beyond that at the value-decode chokepoint
/// (wire.rs). Identity rides as a string or an opaque tag instead.
/// pub(crate): a bare `pub` exports it into kaya.h, where cbindgen's
/// transliteration `((1 << 53) - 1)` shifts a 32-bit int — UB — and the
/// unprefixed name lands in every C guest.
pub(crate) const MAX_SAFE_INTEGER: i64 = (1 << 53) - 1;

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

/// One record kind of a channel. `payload` is the type of the one
/// trailing value an occurrence carries after its key path (None for
/// clicks and every non-occurrence record).
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
/// and names occurrence payload types (Record::payload).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PropKind {
    Str,
    Bool,
    F64,
    /// Bulk payload bytes BY HANDLE: the typed setter takes the
    /// language's bytes form, the wire carries the registration handle.
    Blob,
    /// One of the spec's enums, named here. Rides the wire as I64.
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
    // Progress-only: activity without a fraction. Value carries the
    // determinate fraction (0..=1, domain-checked at the root).
    ("indeterminate", 10, PropKind::Bool),
    // Grid-only: how many columns children fill row-major (integral
    // >= 1, domain-checked at the root).
    ("columns", 11, PropKind::F64),
    // The accessibility IDENTIFIER: a stable authored key, NEVER
    // spoken. Maps to accessibilityIdentifier, testTag,
    // AutomationProperties.AutomationId.
    ("a11y_id", 12, PropKind::Str),
    // The accessibility LABEL: what an assistive client SPEAKS. Kept
    // separate from a11y_id, which would otherwise be read aloud.
    ("a11y_label", 13, PropKind::Str),
    // The accessibility HINT: what happens when the user ACTIVATES this
    // control. ACTIVATION KINDS ONLY (button, checkbox, select, radio;
    // the root rejects it elsewhere) — on Android it rides an ACTION and
    // has no target without one. Authored text should be a VERB PHRASE
    // ("save the draft"): Apple speaks it as written, TalkBack prefixes
    // "double tap to", and only a verb phrase reads on both.
    ("a11y_hint", 14, PropKind::Str),
    // WHICH CLIP REPRESENTATIONS THIS WIDGET ACCEPTS: a space-separated
    // accept list, closed kinds plus open custom ids, so it cannot be a
    // mask. The id's grammar is MIME-SHAPED, validated at apply
    // (docs/clipboard-plan.md §5b finding 4).
        ("accepts", 15, PropKind::Str),
    // SEMANTIC EMPHASIS (docs/styling-plan.md D4): what this widget
    // MEANS, never how it looks. Which VARIANT fits which kind is the
    // root's check, not a type — the prop is one wire slot.
    ("role", 16, PropKind::Enum("role")),
    // A CONTAINER'S OWN PADDING, the window inset one level down
    // (docs/styling-plan.md D3): space between a container's bounds and
    // its children, in DIP, uniform on all four sides. LAYOUT, not
    // appearance — carried by the same kinds spacing is.
    ("inset", 17, PropKind::F64),
    // A CONTAINER'S ARRANGEMENT AXIS (docs/adaptive-layout-plan.md D1/D2):
    // row and column stay the wire's two constructor spellings — each
    // names the INITIAL axis, and the harness addresses by creation
    // kind — while every backend implements ONE node this prop
    // parameterizes. Mutable like any prop, which is what makes both
    // the breakpoint diff and the user-driven orientation toggle
    // ordinary property writes.
    ("axis", 18, PropKind::Enum("axis")),
];

/// Window properties: the presentation-context twin of PROPS, in its
/// own table because windows are not widgets (DESIGN.md, Presentation
/// contexts). `width`/`height` are ADVISORY initial content size in DIP.
/// Window 0 is the primary surface and always exists.
pub const WINDOW_PROPS: &[(&'static str, u32, PropKind)] = &[
    ("title", 1, PropKind::Str),
    ("width", 2, PropKind::F64),
    ("height", 3, PropKind::F64),
    // Who owns the chrome close. False (the default): native — an aux
    // window just closes (window_closed reports it), and closing the
    // primary exits the app. True: the close button EMITS
    // close_requested and nothing closes until the app answers with
    // destroy_window. Inert on mobile: no chrome close, and back is not
    // close (DESIGN.md, Presentation contexts).
    ("veto_close", 4, PropKind::Bool),
    // How this window presents its sections (DESIGN.md, Sections).
    // ADVISORY, the width/height precedent. Scoped to the window
    // because the GROUP is the unit — no platform mixes per-section
    // presentations. `auto` (the default) resolves to each platform's
    // dominant idiom.
    ("sections_presentation", 5, PropKind::Enum("sections_presentation")),
    // How this window presents its ENTRY STACK (DESIGN.md; the ruling,
    // the mechanics and their measurements are docs/multicolumn-plan.md's
    // Status block). The DECLARED CEILING on how many stack entries
    // present side by side: 1 (the default) is the serial stack, and the
    // shallowest column sheds first as the window narrows. The root wall
    // refuses 0 and anything above 3.
    ("panes", 6, PropKind::Enum("panes")),
    // WHETHER THIS SURFACE HOLDS UNSAVED WORK (docs/dirty-plan.md
    // D1-D4, which carries the per-backend chrome, the Qt `[*]`
    // rejection and the mobile carve-out). The app declares STATE and
    // never spells chrome; it arms nothing.
    ("dirty", 7, PropKind::Bool),
    // THE WINDOW CONTENT INSET, in layout units — LAYOUT, not
    // appearance (docs/styling-plan.md D3). Defaults to 16. KAYA'S OWN
    // padding inside the root, so 0 is honored unconditionally; it does
    // NOT remove a platform's safe area.
    ("inset", 8, PropKind::F64),
];

/// Navigation-entry properties: their own typed table, deliberately
/// not WINDOW_PROPS with applicability checks, so a wrong-surface prop
/// dies at compile time in every binding rather than at the scene.
/// `intercept_back` is the close-veto class transplanted to POP: true
/// means the back affordance emits back_requested and nothing pops
/// until the app answers with pop_entry (DESIGN.md, Navigation).
pub const ENTRY_PROPS: &[(&'static str, u32, PropKind)] = &[
    ("title", 1, PropKind::Str),
    ("intercept_back", 2, PropKind::Bool),
];

/// Section properties: the third typed surface table (the ENTRY_PROPS
/// stance — spec facts with typed setters, never applicability checks).
pub const SECTION_PROPS: &[(&'static str, u32, PropKind)] = &[
    ("title", 1, PropKind::Str),
    ("icon", 2, PropKind::Blob),
    // THE SEMANTIC ICON NAME (docs/styling-plan.md D6): a closed
    // vocabulary each backend maps to its own symbol set, BESIDE the
    // Blob above, which stays for app-specific art.
    ("symbol", 3, PropKind::Enum("symbol")),
];

/// Menu-item properties (DESIGN.md, Menus), a flat spec fact: the scene
/// core enforces the per-kind scoping. `label`/`enabled`/`checked`/`value`
/// are signal-bindable, `icon`/`primary`/`shortcut` const-only.
pub const MENU_PROPS: &[(&'static str, u32, PropKind)] = &[
    ("label", 1, PropKind::Str),
    ("enabled", 2, PropKind::Bool),
    ("checked", 3, PropKind::Bool),
    ("value", 4, PropKind::F64),
    ("icon", 5, PropKind::Blob),
    ("primary", 6, PropKind::Bool),
    ("shortcut", 7, PropKind::Str),
    ("role", 8, PropKind::Str),
    // The semantic icon name (docs/styling-plan.md D6) — const-only.
    // NOT id 6: these ids are wire facts and APPEND-ONLY.
    ("symbol", 9, PropKind::Enum("symbol")),
];

/// The variable tail of SET_PROPERTY, after `source`. The one record
/// whose layout depends on a discriminant; generators emit one helper
/// per source rather than a union type.
pub const SET_PROPERTY_NOTE: &str =
    "tail after `source`: value (SOURCE_CONST) | u64 signal_id (SOURCE_SIGNAL) \
     | u32 level, u32 field (SOURCE_ELEMENT — which field of the element's \
     record; 0 for a scalar collection)";

/// The layout of `undone`/`redone`'s one flat `delta` list, read as four
/// runs in this order. A FINGERPRINTED STRING because a reader with the
/// wrong shape decodes garbage silently — the counts still parse and only
/// the meanings slide — so a layout described in a doc comment alone
/// could change under a binding without the spec hash moving. Keep it in
/// step with the `undone` record's doc (docs/undo-plan.md).
pub const UNDO_DELTA_RUNS: &str = "\
    signals: pairs(i64 signal_id, value); \
    texts: groups(i64 size, i64 id, i64 path_len, path_len key values, str text); \
    entries: groups(i64 size, i64 collection, i64 flags, i64 variant, \
    i64 path_len, path_len key values, key, record fields); \
    orders: groups(i64 size, i64 collection, i64 path_len, path_len key values, keys)";

/// A deterministic fingerprint of the whole vocabulary: every record
/// kind, field name and type, enum variant, and prop. The core exports
/// it (capi::kaya_spec_hash), the generator bakes it into every wire
/// file, and every runtime asserts the two agree at load.
pub fn hash() -> u64 {
    // FNV-1a over a canonical walk: stable across platforms and builds
    // by construction.
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
    eat(b"menu_props");
    for (name, id, kind) in MENU_PROPS {
        eat(name.as_bytes());
        eat(&id.to_le_bytes());
        eat(format!("{kind:?}").as_bytes());
    }
    // The undo payload's runs are a LAYOUT rather than a field, and are
    // hashed for the same reason the fields are: a binding reading the
    // old shape out of new bytes gets values of the right types in the
    // wrong places, which no assertion downstream can catch.
    eat(b"undo_delta_runs");
    eat(UNDO_DELTA_RUNS.as_bytes());
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
        Record {
            kind: 25,
            name: "add_section",
            fields: &[f("window", FieldTy::U64), f("section", FieldTy::U64)],
            payload: None,
            doc: "Append a section to `window`'s section set (0 = the \
                  primary surface; no capability gate — every platform has \
                  a sections idiom). Section ids share the surface \
                  namespace with windows and entries: one guest-side \
                  allocator, and mount's target field addresses any of \
                  them. The first section added becomes the selected one; \
                  the set is APPEND-ONLY — this grammar has no destruction \
                  verbs by design, and every section's root is retained \
                  while covered (DESIGN.md, Sections).",
        },
        Record {
            kind: 26,
            name: "select_section",
            fields: &[f("window", FieldTy::U64), f("section", FieldTy::U64)],
            payload: None,
            doc: "Select a section programmatically: configuration, not a \
                  user act — it never echoes section_selected (the echo \
                  doctrine). The section must already be added to \
                  `window`; switching is SELECTION, not lifecycle — the \
                  covered root stays alive.",
        },
        Record {
            kind: 27,
            name: "set_section_prop",
            fields: &[
                f("section", FieldTy::U64),
                f("prop", FieldTy::U32),
                f("source", FieldTy::U32),
            ],
            payload: None,
            doc: "Bind a section property (SECTION_PROPS). Same tail \
                  convention as SET_PROPERTY_NOTE, except SOURCE_ELEMENT is \
                  rejected — sections are not collection elements.",
        },
        Record {
            kind: 28,
            name: "menu_item_create",
            fields: &[
                f("item", FieldTy::U64),
                f("kind", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "Create a menu item of `kind` (menu_kind) in the menu-item \
                  id space — its own guest allocator (c_menu_item), distinct \
                  from every widget, node, and surface space. Items are \
                  live, append-only, and never removed in v1 (DESIGN.md, \
                  Menus).",
        },
        Record {
            kind: 29,
            name: "menu_item_append",
            fields: &[f("parent", FieldTy::U64), f("child", FieldTy::U64)],
            payload: None,
            doc: "Append `child` under grouping node `parent`. Single-parent: \
                  an item acquires exactly one parent or anchor and ids are \
                  never reused. The closed parent/child grammar (menu accepts \
                  menu/radio_group/action/toggle/separator; radio_group \
                  accepts only radio_option; leaves accept nothing) and the \
                  depth cap are validated at the root.",
        },
        Record {
            kind: 30,
            name: "menubar_append",
            fields: &[f("window", FieldTy::U64), f("item", FieldTy::U64)],
            payload: None,
            doc: "Append a top-level grouping node (menu or radio_group) to \
                  `window`'s command catalog — the window anchor, riding the \
                  window construct under the window-attribute unification \
                  rule (0 = the primary surface). The bar accepts only \
                  grouping nodes; duplicate shortcuts within the window's \
                  catalog are a root error.",
        },
        Record {
            kind: 31,
            name: "context_attach",
            fields: &[f("widget", FieldTy::U64), f("item", FieldTy::U64)],
            payload: None,
            doc: "Attach a context catalog rooted at `item` to a live \
                  widget — the same command vocabulary scoped to a noun. The \
                  editable text controls (entry, textarea) reject attachment \
                  (their native edit menus are dress), a context root cannot \
                  be a radio_option, and a shortcut anywhere in the subtree \
                  is a root error (shortcuts need a window catalog home).",
        },
        Record {
            kind: 32,
            name: "context_attach_node",
            fields: &[f("node", FieldTy::U64), f("item", FieldTy::U64)],
            payload: None,
            doc: "Attach a context catalog to a template node (the Tpl \
                  zone): every stamped copy shows the same catalog, and an \
                  activation carries that copy's key path — the keys ARE the \
                  noun (the on_click_node encoding). Same rejections as \
                  context_attach.",
        },
        Record {
            kind: 33,
            name: "set_menu_prop",
            fields: &[
                f("item", FieldTy::U64),
                f("prop", FieldTy::U32),
                f("source", FieldTy::U32),
            ],
            payload: None,
            doc: "Bind a menu property (MENU_PROPS). Same tail convention as \
                  SET_PROPERTY_NOTE, except SOURCE_ELEMENT is rejected — menu \
                  items are not collection elements — and icon/primary/ \
                  shortcut reject SOURCE_SIGNAL (const-only). label and \
                  enabled fan out through the signal-write path; the domain \
                  of a signal-bound value is validated on the COMPLETE \
                  coalesced value at the transaction barrier.",
        },
        Record {
            kind: 34,
            name: "show_file_dialog",
            fields: &[
                f("window", FieldTy::U64),
                f("dialog", FieldTy::U64),
                f("multiple", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("filters", FieldTy::Values),
            ],
            payload: None,
            doc: "Request the platform's file picker over a live window \
                  (0 = primary), on the alert's request/result grammar \
                  (DESIGN.md, File dialogs). Dialog ids are guest-chosen; \
                  one dialog may be live per process, and the id retires \
                  when its result fires. `multiple` is 0 or 1 — every \
                  backend supports both, spelled four ways (a flag on \
                  SwiftUI and AppKit, a different METHOD on GTK and \
                  WinUI, a different CONTRACT on Android). `filters` is \
                  advisory and rides as alternating Str values, a label \
                  then its space-separated extensions: every platform \
                  treats them as a default view rather than a guarantee, \
                  so the guest still validates what it got.",
        },
        Record {
            kind: 35,
            name: "copy",
            fields: &[
                f("present", FieldTy::U32),
                f("file_count", FieldTy::U32),
                f("custom_count", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("reps", FieldTy::Values),
            ],
            payload: None,
            doc: "Put one clip on the system clipboard, offered in \
                  several REPRESENTATIONS at once (DESIGN.md, Clipboard; \
                  docs/clipboard-plan.md). A clip is not a string: every \
                  platform models it as one item available in several \
                  types, and the consumer takes the richest it \
                  understands — so an app offers html AND text, and \
                  pasting into Pages keeps the formatting while a plain \
                  field still works. A RECORD RATHER THAN A LIST, which \
                  is what makes at-most-one-per-kind structural instead \
                  of a runtime duplicate check. `present` is a mask over \
                  the `clip` enum for the single-valued kinds; the two \
                  plural ones carry counts. `reps` holds the populated \
                  ones in the CANONICAL ORDER, which kaya fixes once \
                  because richness \
                  is a property of the kind rather than of the app's \
                  intent, and the wire's preference order (macOS type \
                  order, X11 TARGETS) has to be right whoever wrote the \
                  guest. THE ORDER IS DESCENDING CLIP VALUE, which is \
                  descending richness, so a backend writes what it is \
                  handed in the order it is handed: `custom_count` pairs \
                  of Str id and I64 blob, `file_count` I64 handles, I64 \
                  image blob, Str html, Str text. Files are the SAME \
                  CAPABILITY the picker returns — a handle redeemed with \
                  kaya_open_picked — so copying a file and picking one \
                  are one currency and the bytes never move through \
                  kaya.",
        },
        Record {
            kind: 36,
            name: "read_clipboard",
            fields: &[
                f("request", FieldTy::U64),
                f("accepting", FieldTy::Value),
            ],
            payload: None,
            doc: "Read the clipboard OUTSIDE any paste gesture, on the \
                  alert's request/result grammar. `accepting` is an \
                  ACCEPT LIST, the same space-separated Str the widget \
                  prop carries: the closed kinds by name plus any custom \
                  ids, which are open and so could never be a mask. The \
                  answer carries the first match by canonical richness, \
                  so exactly one representation is ever materialised. THIS IS THE \
                  PRIVILEGED ONE, and it is named for what it is rather \
                  than for pasting. A user's paste arrives at the \
                  widget's hook and costs nothing; this asks without a \
                  gesture, which the platforms have deliberately made \
                  expensive — iOS 16 PROMPTS when the content came from \
                  another app, and the read blocks until the user \
                  answers (measured); Android returns nothing unless the \
                  app has focus; Wayland delivers no offer to an \
                  unfocused client. Reaching for a thing called paste in \
                  an editor would have cost a permission prompt for \
                  content the hook delivers free, which is why this name \
                  is not that one. An empty answer covers denied, \
                  absent, and nothing-we-accept alike.",
        },
        Record {
            kind: 37,
            name: "undo_group",
            fields: &[f("window", FieldTy::U64), f("label", FieldTy::Value)],
            payload: None,
            doc: "Mark this transaction as ONE undoable step in `window`'s \
                  ledger, under `label` (a non-empty Str, validated at the \
                  root like every other authored grammar). MUST BE THE \
                  FIRST RECORD OF THE BATCH and may appear once: a \
                  transaction is a bare list with no header, so \
                  per-transaction metadata has nowhere else to live, and \
                  head-of-batch is the one position that cannot be \
                  ambiguous (docs/undo-plan.md D2). A WIRE FACT AND NOT A \
                  BINDING CONVENTION, so both interpreters and check-verbs \
                  see it and a binding that forgets to emit it fails a \
                  byte-compared scene instead of grouping wrong in \
                  silence.\n\n\
                  THE UNDOABLE SET IS THE REACTIVE HALF (D4): a marked \
                  batch may hold signal writes and the five collection \
                  deltas, whose inverse the core derives from state it \
                  already keeps. PURE EFFECTS — focus today, scroll when \
                  it lands — are permitted and simply not restored (A2): \
                  undo restores state, not where you were looking. \
                  Anything else (const prop sets, create/destroy/mount, \
                  window/nav/section/menu structure, clear, commands, \
                  dialog and clipboard requests) is REFUSED at apply, \
                  loudly, naming the op — an app that wants a widget \
                  property undoable binds it to a signal, which is the \
                  reactive doctrine saying what it already said. A refused \
                  group leaves the scene exactly as it was.\n\n\
                  The window is explicit because the core cannot derive \
                  it: a signal write names no surface, and the scene keeps \
                  no widget-to-window map. 0 is the primary.",
        },
        Record {
            kind: 38,
            name: "highlight_ranges",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("count", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("ranges", FieldTy::Values),
            ],
            payload: None,
            doc: "DECLARE the set of decorated ranges on a textarea, \
                  replacing whatever was declared before (docs/ranges-plan.md \
                  D1/D2). `ranges` holds 2*`count` I64 values — start then \
                  end, in UTF-8 BYTE offsets into the widget's current \
                  guest-visible text; an empty set is the clear.\n\n\
                  THE OFFSET UNIT AND ITS THREE RULES, once, here, because \
                  four of the five platforms answer a malformed offset \
                  differently and one of them ABORTS THE PROCESS \
                  (docs/ranges-units.md §3: an out-of-range \
                  NSTextStorage attribute is an NSRangeException, exit 134). \
                  The core refuses before lowering: `start <= end`, `end <= \
                  text.len()`, and both endpoints on a CODE-POINT boundary. \
                  A GRAPHEME split is deliberately NOT refused and is the \
                  stated carve-out — the platforms disagree about what a \
                  grapheme is (java.text.BreakIterator counts the ZWJ family \
                  as 11 clusters where .NET and Swift count 5, measured), so \
                  a core that refused by its own table would refuse ranges \
                  three platforms honor. The range covers exactly the code \
                  points it names; a platform may widen what it PAINTS to \
                  the whole cluster.\n\n\
                  APP-OWNED AND NEVER TRACKED. kaya adjusts nothing across \
                  edits: a declared set is bound to the text it was \
                  declared against, and a backend paints it only while the \
                  widget still holds that text — the first keystroke, \
                  programmatic write or native undo drops the set with \
                  nothing said. The app re-declares from the fold \
                  `text_changed` already drives, which is the same \
                  uncontrolled contract the text itself has. Range \
                  tracking is editor-component work and lives in the app.\n\n\
                  TEXTAREA ONLY this milestone. The entry is deferred with \
                  measured per-platform reasons (docs/deferred.md): GTK's \
                  entry highlight rides absolute byte offsets that do not \
                  follow edits and is not readable over AT-SPI, macOS \
                  destroys an entry's highlight the moment it loses focus \
                  (the field editor is the window's, not the field's), and \
                  no consumer wants it — an editor's find bar decorates a \
                  document.",
        },
        Record {
            kind: 39,
            name: "select_range",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("start", FieldTy::U64),
                f("stop", FieldTy::U64),
            ],
            payload: None,
            doc: "Put the textarea's SELECTION at one range (UTF-8 byte \
                  offsets, validated exactly as highlight_ranges is). \
                  `start == end` is a caret and is legal — every platform's \
                  text object models a degenerate range.\n\n\
                  ITS OWN RECORD RATHER THAN A `widget_command`, which it \
                  otherwise is exactly (momentary, fire-and-forget, the \
                  app's sanctioned crossing into widget-owned state): that \
                  record's layout has nowhere to put offsets, and growing \
                  it two U64s would hang two dead fields on `clear` and \
                  `focus` and make `focus(w, 0, 0)` representable.\n\n\
                  REFUSED DURING AN INPUT-METHOD COMPOSITION, in every \
                  backend, under the reason `ime_composition` \
                  (docs/ranges-plan.md D4). Measured on macOS: honoring it \
                  COMMITS the marked text into the document and into the \
                  app's model mid-word, which is data loss shaped like a \
                  feature, and it shifts every later offset by the \
                  committed length. A refusal here is a NO-OP AND NOT A \
                  PANIC — unlike undo's D4, which refuses an app-programming \
                  error the app can fix. Composition state is on no kaya \
                  channel and never will be (there are no widget mirror \
                  reads), so the same app code is correct one millisecond \
                  and refused the next; the app that wants the selection \
                  waits for the composition to end, which `text_changed` \
                  announces anyway. HIGHLIGHT and REVEAL do not disturb a \
                  composition and are not refused (measured, same probe).",
        },
        Record {
            kind: 40,
            name: "reveal_range",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("start", FieldTy::U64),
                f("stop", FieldTy::U64),
            ],
            payload: None,
            doc: "Scroll the textarea so a range is inside the viewport \
                  (UTF-8 byte offsets, validated exactly as \
                  highlight_ranges is). A PURE EFFECT: it moves no state, \
                  the selection is untouched, and per docs/undo-plan.md A2 \
                  undo does not restore it — undo restores state, not where \
                  you were looking, which is why it is permitted inside an \
                  undo group and simply not inverted.\n\n\
                  WHAT `inside the viewport` MEANS IS THE PLATFORM'S, not \
                  kaya's: each backend calls its own scroll-to-range \
                  (scrollRangeToVisible, ScrollIntoView, \
                  gtk_text_view_scroll_to_iter, bringIntoView), so how much \
                  context lands around the range is native behaviour. The \
                  observable kaya fixes is containment, which is the only \
                  thing every platform agrees on.",
        },
        Record {
            kind: 41,
            name: "show_save_dialog",
            fields: &[
                f("window", FieldTy::U64),
                f("dialog", FieldTy::U64),
                f("suggested_name", FieldTy::Value),
                f("filters", FieldTy::Values),
            ],
            payload: None,
            doc: "Request the platform's save dialog over a live window \
                  (0 = primary), on the SAME request/result grammar as the \
                  open picker (docs/save-plan.md D2): guest-chosen dialog \
                  ids out of the one id space, one dialog live per process \
                  whichever kind it is, and the answer arriving as a \
                  file_dialog_result whose id retires there. `filters` is \
                  the picker's advisory encoding unchanged — alternating \
                  Str values, a label then its space-separated extensions. \
                  `suggested_name` is the name the dialog opens with, which \
                  every platform takes (nameFieldStringValue, \
                  GtkFileDialog's initial name, IFileSaveDialog's \
                  SetFileName, EXTRA_TITLE, the export controller's \
                  filename) and none guarantees: the user renames it, and \
                  Android may append an extension matching the mime type, \
                  so a guest reads the name it GOT rather than the name it \
                  asked for.\n\n\
                  THE ANSWER IS EXACTLY ONE LOCATOR OR NONE, and there is \
                  no `multiple` twin of the picker's flag: no platform's \
                  save dialog names two destinations. Cancel is the empty \
                  answer, the picker's rule verbatim.\n\n\
                  WHAT THE DESTINATION IS FOR is the decision with the \
                  semantics in it (docs/save-plan.md D1): the result's \
                  handle opens with CREATE, so opening a name the dialog \
                  invented succeeds and yields an EMPTY file on every \
                  platform. Android and iOS hand back a document that \
                  already exists; macOS, GTK and Windows hand back a name \
                  for a file nobody has made (measured: macOS does not even \
                  truncate on Replace). The core absorbs that, not the \
                  guest, and NOT a fourth file mode — creation is a property \
                  of the destination the dialog promised, never of the \
                  caller's intent, and a mode would let a guest ask for it \
                  on a file it merely opened.",
        },
        Record {
            kind: 42,
            name: "set_brand_accent",
            fields: &[
                f("seed", FieldTy::U32),
                f("mask", FieldTy::U32),
                f("light", FieldTy::U32),
                f("dark", FieldTy::U32),
            ],
            payload: None,
            doc: "REQUEST the app's brand accent (docs/styling-plan.md D1/D2). \
                  `seed` is one packed sRGB (0xRRGGBB) — the only value most \
                  apps write; `mask` says which per-appearance overrides are \
                  present (bit 0 = light, bit 1 = dark) and `light`/`dark` \
                  carry them when set, 0 otherwise. Per-PLATFORM values never \
                  ride the wire: the binding resolves its platform at runtime \
                  and sends one resolved trio (values may vary per platform; \
                  code and wire shape never do).\n\n\
                  A REQUEST, uniformly: a platform may let its user override \
                  the app's accent — macOS does today (an app accent applies \
                  only while the system accent is multicolor), and the \
                  semantics does not change if another platform grows the \
                  preference. The app states a brand; the platform stays the \
                  judge of its chrome.\n\n\
                  SET ONCE, before the first mount: the root refuses a second \
                  write and a late one — brand is identity, not state, and a \
                  slot that could flip at runtime would promise a theme- \
                  switching surface the vocabulary deliberately does not \
                  have.\n\n\
                  The app NEVER writes a foreground and NEVER writes contrast \
                  variants; the core derives fill/on-fill/standalone and a \
                  hover/pressed ramp per appearance (the danger-band clamp, \
                  docs/styling-plan.md D1) and hands every backend VALUES. \
                  Backends do not re-derive — except Compose, which receives \
                  the SEED as well because Material 3's own documented flow \
                  derives a full role scheme from it, and kaya defers to the \
                  platform's derivation where one exists.",
        },
        Record {
            kind: 43,
            name: "set_brand_typeface",
            fields: &[
                f("mask", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("family", FieldTy::Value),
                f("platforms", FieldTy::Values),
                f("font", FieldTy::Value),
            ],
            payload: None,
            doc: "REQUEST the app's brand typeface (docs/styling-plan.md D6, \
                  Slice 2b). `family` is the default family name every \
                  platform falls back to; `platforms` carries the optional \
                  per-platform overrides as PAIRS — an I64 platform tag from \
                  the `platform` enum, then that platform's family as a Str — \
                  and `mask` bit 0 says a `font` BLOB is present (an empty \
                  Str rides in its slot when it is not).\n\n\
                  THE FAMILY, NEVER THE SCALE (ratified DESIGN.md): sizes, \
                  weights, metrics and the whole type ramp stay the \
                  platform's. Substituting a family into the platform's own \
                  ramp is what makes the swap safe, and it is the role tier — \
                  not a font size — that carries emphasis.\n\n\
                  PER-PLATFORM VALUES RIDE THE WIRE, unlike the accent's, and \
                  the asymmetry is the design (Slice 2b): a BINDING cannot \
                  know its platform — the JVM says \"Linux\" on Android — but \
                  a LOWERING is its platform, so each backend picks its own \
                  row out of `platforms` and no platform id is ever needed on \
                  the guest side. A colour resolves to one number a binding \
                  can compute anywhere; a family name has to survive to the \
                  backend that will look it up.\n\n\
                  FONT BYTES RIDE THE BLOB CHANNEL, register-then-resolve: \
                  when `font` carries bytes the backend hands them to its \
                  platform's app-font API (CTFontManager, fontconfig, the \
                  Compose/DWrite routes), reads back the family name the \
                  registration produced, and the NAME machinery takes over \
                  unchanged — one resolution, one observation, one fallback \
                  for both forms. A registered blob's own family wins over \
                  `family` on the backend that registered it.\n\n\
                  SET ONCE, before the first mount — the accent's wall \
                  verbatim, and for its reason: a typeface that could flip at \
                  runtime would promise the theme-switching surface the \
                  vocabulary deliberately does not have.\n\n\
                  THE RISK IS THE SILENT FALLBACK. Every platform's font API \
                  renders SOMETHING for a family it does not have, so a typo \
                  is invisible to every other observation: each backend gates \
                  on the family being PRESENT and otherwise leaves the \
                  platform default in place, and `expect_typeface` reads the \
                  RESOLVED family off the real views rather than echoing the \
                  request.",
        },
        Record {
            kind: 44,
            name: "set_app_identity",
            fields: &[
                f("mask", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("name", FieldTy::Value),
                f("icon", FieldTy::Value),
            ],
            payload: None,
            doc: "DECLARE the app's identity — the name it goes by and the \
                  picture that stands for it (docs/app-identity-plan.md, \
                  ratified 2026-08-18). `name` is a Str; `mask` bit 0 says an \
                  `icon` BLOB is present, and an empty Str rides its slot when \
                  it is not — the typeface's mask-plus-always-written-slot \
                  convention, copied rather than reinvented, so the two \
                  records decode the same way and one mask/slot disagreement \
                  test covers the shape.\n\n\
                  A TRANSACTION VERB AND NOT A WINDOW PROP, because identity \
                  is per-APP where WINDOW_PROPS is per-window. `title` already \
                  lives there and is the WINDOW's title; the identity name is \
                  a different thing and the vocabulary must not conflate them \
                  (on Windows the two meet in one string, and it is the \
                  backend's single caption writer that composes them, never \
                  two authors).\n\n\
                  ONE PICTURE, FIVE ROUTES. The same PNG reaches the macOS \
                  Dock, the Windows taskbar/alt-tab and caption, an X11 \
                  window's _NET_WM_ICON, the Android launcher and the iOS Home \
                  Screen — each by its platform's own route, some at runtime \
                  off these bytes and some at build time off the same file in \
                  the tree. One PNG goes in and each lowering converts \
                  (NSImage(data:), BitmapImage.SetSource, an HICON, a \
                  GdkTexture); no .ico, no .icns, no per-platform artwork on \
                  the wire.\n\n\
                  THE FOUR WALLS ARE THE BRAND'S, VERBATIM, and for the \
                  brand's reasons. SET ONCE: a second write dies in the root, \
                  in every language at once. BEFORE THE FIRST MOUNT: so no \
                  backend shows an unidentified frame it must repaint. EMPTY \
                  IS REFUSED: an app that wants the platform's own identity \
                  declares none at all, and an empty string would sail through \
                  five lowerings indistinguishable from a default. NOT \
                  UNDOABLE: identity is not state.\n\n\
                  THE BYTES ARE NOT INSPECTED IN THE CORE — the typeface's \
                  rule transfers exactly. Whether a blob is an image is a \
                  question only the platform's own decoder can answer, and a \
                  guess that disagreed with the decoder would be worse than no \
                  answer. Each backend decodes, and the observation reports \
                  what the DECODER produced (a size, sampled pixels) rather \
                  than echoing the request, so bytes that are not an image \
                  fail exactly like an icon that never applied.",
        },
        Record {
            kind: 45,
            name: "set_column_headers",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("sorted", FieldTy::U32),
                f("direction", FieldTy::U32),
                f("count", FieldTy::U32),
                f("path_len", FieldTy::U32),
                f("titles", FieldTy::Values),
            ],
            payload: None,
            doc: "DECLARE the column header bar on a For's container, \
                  replacing whatever was declared before \
                  (docs/tables-plan.md). `titles` holds `count` Str values, \
                  one per column in visual order; `sorted` is the 0-based \
                  index of the column showing the sort indicator, or \
                  u32::MAX for none (alert_choice's cancel-sentinel \
                  precedent); `direction` is 0 ascending, 1 descending, \
                  read only when `sorted` names a column.\n\n\
                  ONE RECORD FOR THE WHOLE BAR, titles and indicator \
                  together, because the header's state is one declaration: \
                  a sort flip re-sends a handful of short strings and buys \
                  atomicity — no window where new titles show a stale \
                  indicator. A dedicated record and not a prop because a \
                  prop carries ONE Value and titles are many, with spaces \
                  (`accepts`' space-separated trick is out); the carrier is \
                  highlight_ranges' count-plus-Values shape.\n\n\
                  THE TARGET IS THE FOR'S CONTAINER — there is no List \
                  widget; a For materializes as a Column and this record is \
                  what turns that container into a table where the size \
                  class and the platform have the idiom (DESIGN.md's \
                  column-props ruling). The root refuses a target that is \
                  not a For container, a `count` of 0, an empty title, a \
                  `sorted` outside 0..count that is not the sentinel, and a \
                  `direction` past 1.\n\n\
                  PATH ADDRESSING (dynamic tables, docs/tables-plan.md): \
                  the Values carry `path_len` KEY values FIRST, then the \
                  `count` titles — sort_requested's identity convention \
                  pointed the other way. path_len 0 with a live For's \
                  container id is the flat case above; path_len 0 with a \
                  nested For's TEMPLATE NODE id declares the bar for EVERY \
                  copy (stored on the site, applied at each stamp); \
                  path_len > 0 with the template node id and keys \
                  outermost-first re-declares ONE stamped copy's bar — the \
                  per-copy sort indicator. A keyed target that names no \
                  stamped copy is refused loudly.\n\n\
                  ROWS MUST FIT THE COLUMNS: with N columns declared, every \
                  stamped row's template root must be a Row with exactly N \
                  children, checked at stamp time in the core so every \
                  backend inherits the wall — a mismatched template dies \
                  naming the row and both counts instead of rendering N-1 \
                  cells under N headers on some platforms and not others.\n\n\
                  THE INDICATOR IS THE GUEST'S: a header click emits \
                  sort_requested and changes nothing; the guest reorders \
                  its collection by key and re-declares this record with \
                  the new indicator. Configuration, not an occurrence \
                  source — the echo doctrine. Not undoable: the header bar \
                  is not state, and the order underneath it already rides \
                  collection_move's undo run.",
        },
        Record {
            kind: 46,
            name: "set_drawing",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("vb_w", FieldTy::Value),
                f("vb_h", FieldTy::Value),
                f("count", FieldTy::U32),
                f("path_len", FieldTy::U32),
                f("ops", FieldTy::Values),
            ],
            payload: None,
            doc: "DECLARE the whole drawing on a canvas widget, replacing \
                  whatever was declared before (docs/canvas-plan.md §3.1). \
                  `ops` holds `path_len` KEY values FIRST, then `count` op \
                  values — set_column_headers' convention verbatim, and what \
                  lets a canvas live inside a For row template: path_len 0 \
                  with a live widget id is the flat case, path_len 0 with a \
                  template node id declares the drawing for every stamped \
                  copy, path_len > 0 re-declares one copy's.\n\n\
                  THE OP STREAM IS A FLAT RUN OF TAGGED VALUES: an i64 \
                  `draw_op` opcode followed by its operands (§3.3). \
                  `vb_w`/`vb_h` are the VIEWBOX — the coordinate system the \
                  guest draws in AND the canvas's natural size in \
                  device-independent points — which is what keeps one op \
                  stream identical on five platforms (§3.2, invariant 6).\n\n\
                  ONE RECORD FOR THE WHOLE DRAWING, never a patch, on \
                  set_column_headers' reasoning: a half-updated chart is the \
                  same defect as new titles under a stale indicator. NOT \
                  UNDOABLE: a drawing renders app state, it is not state.\n\n\
                  THE CORE RASTERIZES AND THE BACKEND BLITS (ruling 1). No \
                  backend interprets an op, so every refusal in §3.5 happens \
                  in the only place that draws.",
        },
        Record {
            kind: 47,
            name: "set_size_policy",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("policy", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "WHAT THIS CANVAS DOES WITH A TRACK THAT IS NOT ITS VIEWBOX \
                  (`size_policy`; docs/canvas-plan.md §3.2.1). A drawing is a \
                  FUNCTION OF SIZE and `redraw`/`tick` say so: the core hands \
                  the canvas the size it was assigned, through \
                  draw_requested/tick, and rasterizes what comes back at that \
                  size. `scale` and `fixed` DECLARE THE FUNCTION CONSTANT, \
                  which is what lets the core answer a size change by itself — \
                  `scale` re-rasterizes the held display list under a UNIFORM \
                  FIT with a letterbox, `fixed` never adapts at all.\n\n\
                  NOT SENT FOR `scale`: it is the default a guest that \
                  declares nothing gets. THE GUEST NEVER SPELLS THIS NUMBER — \
                  the binding lowers `fixed` (the one true property) and the \
                  presence of an on_draw/on_tick handler; a canvas with no \
                  policy record is `scale`.\n\n\
                  LIVE CANVASES ONLY in this slice: a template node is refused \
                  by name (docs/deferred.md's template-zone size policy entry).",
        },
        Record {
            kind: 48,
            name: "create_breakpoint",
            fields: &[
                f("window", FieldTy::U64),
                f("size_class", FieldTy::Value),
                f("count", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("setters", FieldTy::Values),
            ],
            payload: None,
            doc: "A size-class breakpoint on a window: while the window's \
                  size class equals `size_class` (i64; SIZE_CLASS_COMPACT is \
                  the only class a guest may name today), the core applies the \
                  setter list; leaving the class it restores the \
                  guest-authored value, or the widget's own default where the \
                  guest never wrote one — the adaptation is a DIFF against \
                  the base declaration (docs/adaptive-layout-plan.md D3, \
                  size classes ruled 2026-08-31). The guest NEVER writes a \
                  width: iOS answers with the platform's own size class, and \
                  every other platform derives it from the latched width at \
                  the kaya-owned SIZE_CLASS_COMPACT_BELOW boundary.\n\n\
                  THE CORE EVALUATES THE CONDITION, never the platform's \
                  breakpoint machinery and never a guest round trip: width \
                  and platform class are LATCHED from the backend's metrics \
                  reports, a breakpoint declared before any report applies \
                  at the first — the phone that never resizes — and a \
                  same-metrics report moves nothing.\n\n\
                  `setters` is count triples flat: widgets (i64), then props \
                  (i64), then values, thirds by position. Setters may name \
                  `axis` only until the settable-prop ruling widens the list; \
                  anything else fails the batch by name.",
        },
        Record {
            kind: 49,
            name: "set_drag_source",
            fields: &[
                f("widget", FieldTy::U64),
                f("present", FieldTy::U32),
                f("file_count", FieldTy::U32),
                f("custom_count", FieldTy::U32),
                f("operations", FieldTy::U32),
                f("path_len", FieldTy::U32),
                f("bound", FieldTy::U32),
                f("reps", FieldTy::Values),
            ],
            payload: None,
            doc: "DECLARE that `widget` can be dragged, and what it hands over \
                  (docs/dnd-plan.md D1): the copy record's body — a clip in \
                  several representations, descending clip value, `present` \
                  a mask over the single-valued kinds and the two plural \
                  ones counted — plus `operations`, a mask over the drag_op \
                  enum naming what the source allows (copy 1, move 2). \
                  App-updated state: a widget whose payload changes \
                  re-declares, and a `present` of zero with no files and no \
                  custom ids withdraws the declaration. The core answers \
                  every hover from this and the destination's own \
                  declaration with no app round trip (D2). `path_len` keys \
                  after the header address ONE stamped copy the way \
                  set_column_headers' do. INSIDE A FOR'S BODY the widget is \
                  a template node and `bound` is a mask over the reps' slot \
                  indices (canonical order: custom id and bytes per pair, \
                  then files, image, html, text): a bound slot carries an \
                  i64 `level << 32 | field` — set_property's element source \
                  — and every stamped copy resolves it from its own row, \
                  re-declaring when that field changes (docs/dnd-plan.md \
                  §4). A live widget refuses a bound slot by name; a file \
                  slot never binds.",
        },
        Record {
            kind: 50,
            name: "set_drop_target",
            fields: &[
                f("widget", FieldTy::U64),
                f("operations", FieldTy::U32),
                f("path_len", FieldTy::U32),
                f("keys", FieldTy::Values),
            ],
            payload: None,
            doc: "DECLARE that `widget` receives drops, with `operations` a \
                  mask over the drag_op enum naming what it will perform \
                  (copy 1, move 2; copy alone by default). WHAT it accepts \
                  is the existing `accepts` prop — the same list a paste \
                  consults, so a widget declares its vocabulary once. The \
                  hover verdict is the intersection of the source's \
                  operations with these, over a type the accept list names; \
                  a foreign source into kaya is always answered copy (D2). A \
                  zero mask withdraws the declaration. Keys as in \
                  set_drag_source.",
        },
        Record {
            kind: 51,
            name: "set_reorderable",
            fields: &[
                f("container", FieldTy::U64),
                f("enabled", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "Make every stamped row of a live For draggable within its \
                  own collection (docs/dnd-plan.md D8): each row is a source \
                  whose payload is its key, and a destination that accepts \
                  only its own collection's rows. The drop arrives as \
                  `dropped` with the ANCHOR — the key of the row it landed \
                  on and a before/onto bit — and the app confirms with the \
                  collection_move it already has; the core reorders nothing \
                  on its own. `enabled` 0 withdraws it.",
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
                  identity tag the widget's occurrences carry verbatim. A \
                  live widget carries one where its kind reports; a STAMPED \
                  copy of any kind carries (template node, keys), which is \
                  what a keyed harness target and a reorder's row identity \
                  read.",
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
        Record {
            kind: 15,
            name: "add_section",
            fields: &[f("window", FieldTy::U64), f("section", FieldTy::U64)],
            payload: None,
            doc: "Append a section to a window's section set; the first \
                  added becomes selected.",
        },
        Record {
            kind: 16,
            name: "select_section",
            fields: &[f("window", FieldTy::U64), f("section", FieldTy::U64)],
            payload: None,
            doc: "Select a section, quietly: programmatic selection never \
                  echoes section_selected.",
        },
        Record {
            kind: 17,
            name: "set_section_prop",
            fields: &[
                f("section", FieldTy::U64),
                f("prop", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("value", FieldTy::Value),
            ],
            payload: None,
            doc: "Set a section property to an already-resolved value.",
        },
        Record {
            kind: 18,
            name: "menu_item_create",
            fields: &[
                f("item", FieldTy::U64),
                f("kind", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "Create a presentation-side menu item; the backend keys its \
                  dispatch by item id and emits menu occurrences carrying it.",
        },
        Record {
            kind: 19,
            name: "menu_item_append",
            fields: &[f("parent", FieldTy::U64), f("child", FieldTy::U64)],
            payload: None,
            doc: "Append `child` under grouping node `parent`.",
        },
        Record {
            kind: 20,
            name: "menubar_append",
            fields: &[f("window", FieldTy::U64), f("item", FieldTy::U64)],
            payload: None,
            doc: "Append a top-level grouping node to the window's catalog; \
                  the bar materializes per platform (native menu chrome on \
                  desktop, top-bar overflow on the phones).",
        },
        Record {
            kind: 21,
            name: "context_attach",
            fields: &[f("widget", FieldTy::U64), f("item", FieldTy::U64)],
            payload: None,
            doc: "Attach a context catalog to a live widget.",
        },
        Record {
            kind: 22,
            name: "context_attach_node",
            fields: &[
                f("widget", FieldTy::U64),
                f("item", FieldTy::U64),
                f("path", FieldTy::Values),
            ],
            payload: None,
            doc: "Attach a context catalog to a stamped widget, carrying the \
                  anchor copy's key path — the noun every activation from \
                  this attachment stamps into its occurrence (the \
                  on_click_node encoding). One of these per stamped copy.",
        },
        Record {
            kind: 23,
            name: "set_menu_prop",
            fields: &[
                f("item", FieldTy::U64),
                f("prop", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("value", FieldTy::Value),
            ],
            payload: None,
            doc: "Set a menu property to an already-resolved value.",
        },
        Record {
            kind: 24,
            name: "present_file_dialog",
            fields: &[
                f("window", FieldTy::U64),
                f("dialog", FieldTy::U64),
                f("multiple", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("filters", FieldTy::Values),
            ],
            payload: None,
            doc: "Present the platform's real file picker over the window \
                  (SHOW_FILE_DIALOG, already validated by the core). The \
                  presentation answers with kaya_emit_file_dialog_result \
                  exactly once — the chosen files, or an EMPTY list for \
                  cancel.",
        },
        Record {
            kind: 25,
            name: "copy",
            fields: &[
                f("present", FieldTy::U32),
                f("file_count", FieldTy::U32),
                f("custom_count", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("reps", FieldTy::Values),
            ],
            payload: None,
            doc: "The tx record's twin, byte-identical in layout \
                  (one encoder writes both, so the canonical order \
                  cannot drift between the channels): put this clip on \
                  the system clipboard. THE VALUES ARRIVE IN PREFERENCE \
                  ORDER, descending richness, so a backend offers them \
                  in the order it reads them and needs no table of its \
                  own. Blob values are batch-local out-table handles \
                  here, resolved with kaya_blob_data like any other \
                  apply-side blob.\n\n\
                  FILES ARE STR LOCATORS ON THIS CHANNEL and I64 picked \
                  handles on the tx one — the single difference between \
                  the twins, and it is the difference between what a \
                  GUEST names (a capability it can open) and what a \
                  BACKEND needs (a file URL, a content:// URI, a path \
                  inside a DROPFILES struct). The core resolves it once, \
                  where the picked table lives. The bytes never move \
                  through kaya either way.",
        },
        Record {
            kind: 26,
            name: "read_clipboard",
            fields: &[
                f("request", FieldTy::U64),
                f("accepting", FieldTy::Value),
            ],
            payload: None,
            doc: "Read the clipboard and answer this request with at \
                  most one representation, through \
                  kaya_emit_clipboard_result (rust-native backends send \
                  ClipboardResult on their own sink). `accepting` is the \
                  accept list; the backend takes the FIRST match in \
                  descending richness, which is the same order copy \
                  writes, and custom ids lead. \
                  ANSWERING EMPTY IS ALWAYS CORRECT and is what a \
                  backend does when the platform declines — an iOS \
                  prompt the user refused, an unfocused Android or \
                  Wayland reader, an empty clipboard, or content in no \
                  accepted kind. Exactly one answer per request, always: \
                  the guest's handler retires on it.",
        },
        Record {
            kind: 27,
            name: "clear_undo",
            fields: &[f("window", FieldTy::U64)],
            payload: None,
            doc: "Reset the NATIVE undo history of whatever editable holds \
                  the keyboard focus in this window; do nothing if that is \
                  nothing (docs/undo-plan.md A1). TARGETLESS ON PURPOSE — \
                  the core does not know what is focused and by doctrine \
                  never will (there are no widget mirror reads), while \
                  every backend already asks itself exactly this question \
                  to compute role enablement. Per-platform spelling, one \
                  semantics: GTK's begin/end_irreversible_action bracket, \
                  WinUI's ClearUndoRedoHistory, Compose's \
                  undoState.clearHistory, AppKit's removeAllActions on the \
                  first responder's manager AFTER the value has reached \
                  AppKit.\n\n\
                  THE KEYSTONE OF THE LEDGER (docs/undo-plan.md §3): the \
                  core emits this when an undo GROUP commits, so \
                  everything left in a native stack is strictly newer than \
                  everything in the core's ledger. The episode was banked \
                  before the clear, so the clear costs no history — it \
                  costs GRANULARITY, and it is what makes \"ask the \
                  focused text first\" mean \"ask the most recent first\". \
                  The OTHER trigger — a programmatic write that CHANGES a \
                  field's text (D7, narrowed by A3) — rides no record: the \
                  backend is already standing at its set_prop/command arm \
                  with the widget in hand and the old text to compare \
                  against, which is a comparison the core cannot make.",
        },
        Record {
            kind: 28,
            name: "highlight_ranges",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("count", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("ranges", FieldTy::Values),
            ],
            payload: None,
            doc: "The tx record's twin in layout, and NOT in unit: these \
                  offsets are already in THIS BACKEND'S NATIVE UNIT, \
                  converted by the core against the same text it validated \
                  them against (docs/ranges-units.md §7). UTF-16 code \
                  units on mac, iOS, Windows and Android; CODE POINTS on \
                  GTK. A backend does no Unicode arithmetic on this path and \
                  must not: the two interpreters are string-matched rather \
                  than compile-checked, and an off-by-one in one of them is \
                  invisible to every gate the compiler runs.\n\n\
                  THE LOWERING CONTRACT, one sentence for five backends: \
                  REPLACE the widget's decorated set with these ranges, and \
                  RECORD THE WIDGET'S TEXT AS IT IS AT THIS MOMENT. Paint \
                  the set only while the widget still holds that text; on \
                  the first edit of any kind, drop it. That compare is what \
                  makes D2's clear-on-edit structural rather than a message \
                  that can arrive late — and late is this milestone's \
                  measured hazard (range-probe-mac.md H2: SwiftUI's own \
                  text push landed 11ms after the app's write and destroyed \
                  everything declared before it). The invariant it buys, \
                  stated as the reader wants it: PAINTED OFFSETS WERE \
                  VALIDATED AGAINST THE TEXT THEY ARE PAINTED ON.\n\n\
                  WHAT TO PAINT WITH is per platform and is decided by what \
                  the platform's own ACCESSIBILITY layer publishes, because \
                  that is what a harness leg reads: a background colour on \
                  the text runs (NSTextStorage's .backgroundColor, a \
                  GtkTextTag, a SpanStyle, a CharacterFormat.BackColor). On \
                  macOS the alternatives were measured and rejected — \
                  TextKit 2 rendering attributes and NSTextHighlightStyle \
                  both render and are both INVISIBLE to accessibility, and \
                  TextKit 1 temporary attributes require reading \
                  `.layoutManager`, which silently and permanently \
                  downgrades the view (range-probe-mac.md §1).",
        },
        Record {
            kind: 29,
            name: "select_range",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("start", FieldTy::U64),
                f("stop", FieldTy::U64),
            ],
            payload: None,
            doc: "Move the widget's selection, in the backend's native \
                  unit (see the highlight twin). REFUSE IT SILENTLY, under \
                  the reason `ime_composition`, while an input-method \
                  composition is active on that widget — the one thing on \
                  this channel a backend is expected NOT to do, and the \
                  only party that can know it (composition state is on no \
                  kaya channel).",
        },
        Record {
            kind: 30,
            name: "reveal_range",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("start", FieldTy::U64),
                f("stop", FieldTy::U64),
            ],
            payload: None,
            doc: "Scroll the range into the widget's viewport, in the \
                  backend's native unit (see the highlight twin). Touches \
                  no selection and no composition.",
        },
        Record {
            kind: 31,
            name: "present_save_dialog",
            fields: &[
                f("window", FieldTy::U64),
                f("dialog", FieldTy::U64),
                f("suggested_name", FieldTy::Value),
                f("filters", FieldTy::Values),
            ],
            payload: None,
            doc: "Present the platform's real save dialog over the window \
                  (SHOW_SAVE_DIALOG, already validated by the core). The \
                  presentation answers with kaya_emit_save_dialog_result \
                  exactly once — ONE locator, or a null one for cancel. \
                  That entry is what makes the destination a destination: \
                  it registers a source whose open creates, so the two \
                  platforms that hand back a name for a file nobody has \
                  made behave like the two that hand back a document.",
        },
        Record {
            kind: 32,
            name: "set_brand",
            fields: &[
                f("seed", FieldTy::U32),
                f("light_fill", FieldTy::U32),
                f("light_on_fill", FieldTy::U32),
                f("light_standalone", FieldTy::U32),
                f("light_hover", FieldTy::U32),
                f("light_pressed", FieldTy::U32),
                f("dark_fill", FieldTy::U32),
                f("dark_on_fill", FieldTy::U32),
                f("dark_standalone", FieldTy::U32),
                f("dark_hover", FieldTy::U32),
                f("dark_pressed", FieldTy::U32),
            ],
            payload: None,
            doc: "The brand accent, DERIVED — eleven packed sRGB words \
                  (docs/styling-plan.md D1). Backends apply VALUES and \
                  re-derive nothing: fill is the accent as a background, \
                  on_fill its fixed foreground (chosen by the core's \
                  danger-band clamp so every platform's own foreground rule \
                  agrees with it), standalone is accent-colored text on a \
                  neutral surface (a different number than a fill — \
                  libadwaita's clamp verbatim), hover/pressed the \
                  interaction ramp. The SEED rides along for the one \
                  platform whose own documented derivation kaya defers to: \
                  Material builds its role scheme from the seed. Emitted \
                  once, before the first mount; a backend never sees a \
                  brand it must un-apply.",
        },
        Record {
            kind: 33,
            name: "set_typeface",
            fields: &[
                f("mask", FieldTy::U32),
                f("platform", FieldTy::U32),
                f("family", FieldTy::Value),
                f("platforms", FieldTy::Values),
                f("font", FieldTy::Value),
            ],
            payload: None,
            doc: "The brand typeface, as REQUESTED (docs/styling-plan.md D6, \
                  Slice 2b). The tx record's body verbatim — the default \
                  family, every per-platform pair, and the font blob when one \
                  was sent — because THE LOWERING IS WHAT RESOLVES IT: a \
                  backend picks its own row out of `platforms` (falling back \
                  to `family`), registers `font` with its platform's app-font \
                  API when present and prefers the family that registration \
                  named, then gates on the family being installed and applies \
                  it into its platform's own type ramp. The core resolves \
                  nothing here, which is the opposite of set_brand and for \
                  the reason Slice 2b gives: a colour is a number every \
                  platform means the same way, a family name is a lookup only \
                  the platform can do.\n\n\
                  `platform` IS THE ONE WORD THE CORE FILLS: the tag of the \
                  platform this core was compiled for, so a lowering asks \
                  \"is this row mine?\" without carrying a copy of the \
                  vocabulary. The two INTERPRETER backends are not Rust and \
                  cannot read the spec's constants, and a private copy in \
                  Swift and another in Kotlin is the CLIP_* mirror trap — a \
                  drifted value picking the wrong row with nothing pinning \
                  either side. The core may answer this where a BINDING may \
                  not: a guest cannot tell (the JVM says \"Linux\" on \
                  Android) while this crate is compiled once per target.\n\n\
                  Emitted once, before the first mount's ops, by the root's \
                  set-once arm — a backend never sees a typeface it must \
                  un-apply.",
        },
        Record {
            kind: 34,
            name: "set_app_identity",
            fields: &[
                f("mask", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("name", FieldTy::Value),
                f("icon", FieldTy::Value),
            ],
            payload: None,
            doc: "The app's identity, as DECLARED (docs/app-identity-plan.md). \
                  The tx record's body verbatim — the core resolves nothing \
                  here, the typeface's rule and for its reason: whether a blob \
                  is an image, and what picture it holds, is a question only \
                  the platform's own decoder can answer.\n\n\
                  EACH BACKEND ROUTES IT ITSELF, and the routes are not alike: \
                  the Windows one is TWO sinks from one declaration (the \
                  window's icon, which the system caption, the taskbar and \
                  alt-tab all read, and the XAML TitleBar's IconSource, which \
                  repairs what a custom caption takes away from the first); \
                  macOS hands the picture to the Dock under the regular \
                  activation policy declaring an identity implies; GTK decodes \
                  to textures and hands them to the toplevel. What a person \
                  sees is one mark on every platform.\n\n\
                  Emitted once, before the first mount's ops, by the root's \
                  set-once arm — a backend never sees an identity it must \
                  un-apply.",
        },
        Record {
            kind: 35,
            name: "set_column_headers",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("sorted", FieldTy::U32),
                f("direction", FieldTy::U32),
                f("count", FieldTy::U32),
                f("tag_len", FieldTy::U32),
                f("titles", FieldTy::Values),
            ],
            payload: None,
            doc: "The tx record's body with the target resolved to the live \
                  container's widget id (a nested For's declaration reaches \
                  each stamped copy through the ordinary template replay), \
                  plus `tag_len` bytes of core-minted SORT TAG after the \
                  titles — the click-tag mechanism (create's convention): a \
                  header click hands the tag to kaya_emit_sort_requested \
                  verbatim with the column index, because a stamped copy's \
                  identity is a node id plus key path no backend can \
                  compute. The backend that has the idiom and a regular \
                  size class presents the container as a table — native \
                  headers, platform-managed resize, the indicator on \
                  `sorted` — and the one that does not synthesizes a header \
                  row above the stack or, on compact, shows none: \
                  presentation degrades, the declaration does not \
                  (docs/tables-plan.md). Nothing here reorders anything.",
        },
        Record {
            kind: 36,
            name: "set_drawing",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("width", FieldTy::U32),
                f("height", FieldTy::U32),
                f("scale", FieldTy::Value),
                f("pixels", FieldTy::Value),
            ],
            payload: None,
            doc: "THE RASTER, not the ops (docs/canvas-plan.md §1.1): \
                  `pixels` is a blob of `width` x `height` PREMULTIPLIED \
                  RGBA8 device pixels — tiny-skia's Pixmap layout — and \
                  `scale` is the display scale they were drawn at, so the \
                  logical size is width/scale by height/scale. The backend's \
                  arm is the raw-pixel sibling of its Image arm; it \
                  interprets no op and owns no drawing API (§8).\n\n\
                  RE-EMITTED WHENEVER THE RASTER CHANGES: a new declaration, \
                  a scale report, or an appearance flip. A width or height of \
                  0 means the drawing is declared and empty — the node stays \
                  present with no picture, never absent \
                  (tools/check-empty-child.py's rule).",
        },
        Record {
            kind: 37,
            name: "fold",
            fields: &[f("child", FieldTy::U64), f("table", FieldTy::U64)],
            payload: None,
            doc: "THE STACKED FOLD (docs/adaptive-layout-plan.md D7): render \
                  `child` inside the viewport of the grown table `table` as \
                  scroll-away content above row 0, in sibling order; `table` \
                  0 restores the child to its structural parent's layout. \
                  APPLY-ONLY AND DERIVED: no guest spells this — the core \
                  computes it from a `stack_when` row's own shape when the \
                  breakpoint crosses, which is why it is a record here and \
                  not a prop (a PROPS entry generates a guest setter in \
                  every binding). The tree does not change: the child keeps \
                  its parent, its id and its addressing; only where it \
                  RENDERS moves, exactly as the axis prop moves arrangement \
                  without moving identity.",
        },
        Record {
            kind: 38,
            name: "set_drag_source",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("present", FieldTy::U32),
                f("file_count", FieldTy::U32),
                f("custom_count", FieldTy::U32),
                f("operations", FieldTy::U32),
                f("tag_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("reps", FieldTy::Values),
            ],
            payload: None,
            doc: "The tx record's twin with the target resolved to a live \
                  widget id, files as Str locators the way the copy twin \
                  carries them, and the widget's identity TAG riding after \
                  the values, 8-aligned (set_column_headers' shape): the \
                  backend installs the platform's drag source over this \
                  payload and hands the tag to kaya_emit_drag_ended verbatim \
                  when the session ends.",
        },
        Record {
            kind: 39,
            name: "set_drop_target",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("operations", FieldTy::U32),
                f("tag_len", FieldTy::U32),
            ],
            payload: None,
            doc: "The tx record's twin: the backend registers the widget as a \
                  platform drop destination and asks the core, at every hover \
                  and at the drop, through kaya_drag_verdict — it decides \
                  nothing itself. The identity tag rides after the header, \
                  8-aligned, and goes to kaya_emit_dropped verbatim.",
        },
        Record {
            kind: 40,
            name: "set_reorderable",
            fields: &[
                f("widget_id", FieldTy::U64),
                f("enabled", FieldTy::U32),
                f("tag_len", FieldTy::U32),
            ],
            payload: None,
            doc: "Rows of this live For container become drag sources and \
                  destinations within the collection, in the platform's own \
                  reorder idiom (docs/dnd-plan.md D8). The container's \
                  identity tag rides after the header, 8-aligned, and is the \
                  identity of every landing the backend reports through \
                  kaya_emit_dropped: the moved row's key rides as the clip's \
                  custom representation under the kaya-private id, the row it \
                  landed on as the anchor (its own create tag — every stamped \
                  copy carries one), and the model does not move until the \
                  app's collection_move.",
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
                  selected index (integral, 0-based; the radio group is \
                  the same contract in its inline presentation). One \
                  occurrence per USER change (programmatic writes never \
                  echo — without that, a handler writing back a different \
                  value would ping-pong forever); same ownership stance.",
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
        Record {
            kind: 10,
            name: "section_selected",
            fields: &[f("window", FieldTy::U64), f("section", FieldTy::U64)],
            payload: None,
            doc: "The user switched sections through the platform's own \
                  switcher (tab bar, toolbar tabs, NavigationView, stack \
                  switcher). Only the user's act emits — a programmatic \
                  select_section is configuration and stays silent (the \
                  echo doctrine). Informational and post-fact: the \
                  selection has already changed on screen.",
        },
        Record {
            kind: 11,
            name: "menu_activated",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: None,
            doc: "An action fired — clicked OR invoked through its shortcut: \
                  ONE occurrence, one dispatch path. path_len 0: id is the \
                  menu item id (a bar or live-widget context action). \
                  Otherwise id is the item id and the values are the anchor \
                  copy's key path, outermost first (the on_click_node \
                  encoding — the keys are the noun).",
        },
        Record {
            kind: 12,
            name: "menu_toggled",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: Some(PropKind::Bool),
            doc: "path_len key values follow, then the toggle's new state as \
                  one Bool value. Identity reads as in menu_activated. The \
                  Checkbox contract: user activation emits; a programmatic \
                  checked write is configuration and never echoes.",
        },
        Record {
            kind: 13,
            name: "menu_value_changed",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
            ],
            payload: Some(PropKind::F64),
            doc: "path_len key values follow, then the radio group's new \
                  selected option index as one F64 value (integral, 0-based; \
                  the Choice contract, the select's precedent). id is the \
                  group. User picks only emit; a programmatic value write \
                  never echoes.",
        },
        Record {
            kind: 14,
            name: "file_dialog_result",
            fields: &[
                f("dialog", FieldTy::U64),
                f("count", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("files", FieldTy::Values),
            ],
            payload: None,
            doc: "The picker's one answer: `count` files, each three \
                  consecutive values in `files` — an I64 handle, a Str \
                  display name, and a Str `local_path`. THE GROUPING IS \
                  THE ENCODING: Values already carries \"an entry's \
                  record\", so N files ride one flat list read in threes \
                  rather than needing a repeated-record field type. \
                  CANCEL IS COUNT ZERO, faithfully — no platform can \
                  confirm an empty selection, so the empty list needs no \
                  sentinel (contrast alert_choice, where dismissal is not \
                  an action index). `local_path` is a RE-OPENABLE NAME, \
                  empty unless re-opening it actually works — measured \
                  EPERM on iOS once the security scope drops, so it is \
                  empty on both phones. The handle is redeemed with \
                  kaya_open_picked; the dialog id retires here.",
        },
        Record {
            kind: 15,
            name: "clipboard_result",
            fields: &[
                f("request", FieldTy::U64),
                f("clip", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("value", FieldTy::Values),
            ],
            payload: None,
            doc: "The privileged read's one answer. `clip` is a SINGLE \
                  member of the clip enum and not a mask — the request \
                  said which representations it could use, and exactly \
                  one is ever materialised, so the answer names which \
                  one arrived. `value` carries it: a Str for text and \
                  html, a Blob for image and custom, an I64 handle per \
                  file. EMPTY IS THE UNIVERSAL NO, with `clip` zero: it \
                  covers a denied prompt on iOS, an unfocused reader on \
                  Android or Wayland, an empty clipboard, and content in \
                  no representation this request accepted. The guest \
                  cannot tell those apart and should not try — the \
                  platforms deliberately refuse to say which, and a \
                  binding that invented a distinction would be inventing \
                  it.",
        },
        Record {
            kind: 16,
            name: "pasted",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("clip", FieldTy::U32),
                f("clip_reserved", FieldTy::U32),
                f("value", FieldTy::Values),
            ],
            payload: None,
            doc: "Content arriving at a widget because the USER pasted, \
                  which is the path an editor actually takes. The same \
                  one-representation answer the privileged read gives, \
                  reaching the widget that declared it accepts that kind \
                  — so a guest matches one shape whether it asked or was \
                  told, and only the trigger differs.\n\n\
                  COSTS NOTHING ON ANY PLATFORM, unlike the read: it is \
                  a user gesture, so iOS raises no prompt and the \
                  focus rules are satisfied by construction. An editor \
                  that reaches for the read instead pays a permission \
                  prompt for content this delivers free.\n\n\
                  IDENTITY READS AS IN button_clicked, and the identity \
                  tag is byte-identical to one: path_len key values \
                  follow the header (path_len 0 meaning `id` is a widget \
                  id), and `clip` sits AFTER them, the way text_changed's \
                  payload does. A paste onto a stamped row is the same \
                  event as a paste onto a live one, exactly as a click \
                  is. Drag and drop \
                  lands here too when it comes: Android built \
                  onReceiveContent as ONE api for paste, drop and \
                  autofill, and Wayland uses one data offer for both.",
        },
        Record {
            kind: 17,
            name: "undone",
            fields: &[
                f("window", FieldTy::U64),
                f("signals", FieldTy::U32),
                f("texts", FieldTy::U32),
                f("entries", FieldTy::U32),
                f("orders", FieldTy::U32),
                f("label", FieldTy::Value),
                f("delta", FieldTy::Values),
            ],
            payload: None,
            doc: "kaya routed an undo, and this is what the CORE put back \
                  (docs/undo-plan.md D5). `label` is the group's authored \
                  name, or EMPTY for a typing episode — kaya invents no \
                  user-facing strings, and \"Undo Typing\" is an Apple \
                  convention scene strings do not carry.\n\n\
                  APPLYING AN INVERSE EMITS NOTHING ELSE. It is \
                  programmatic by construction, so the echo doctrine \
                  covers it — no text_changed for the text this restores, \
                  no value_changed for the signals, no section_selected. \
                  That is exactly why the payload is fat: this record is \
                  the ONLY thing the app hears, so the eight bindings \
                  update their mirrors from it the way they already \
                  journal a rollback, and mirror drift across eight \
                  languages has ONE source instead of eight \
                  reimplementations.\n\n\
                  A STATEMENT OF THE RESTORED STATE, NOT A REPLAY OF OPS. \
                  The reader does not re-derive anything: every group says \
                  what a thing now IS, so applying the payload twice is \
                  the same as applying it once. `delta` is one flat list \
                  read as FOUR RUNS in this order — the \
                  grouping-is-the-encoding shape file_dialog_result uses, \
                  with the counts in the fixed head the way copy carries \
                  them:\n\n\
                  1. `signals` PAIRS: I64 signal id, then its restored \
                  value.\n\
                  2. `texts` GROUPS, arity-first like the two below: I64 \
                  size, I64 id, I64 path_len, path_len instance-path key \
                  values, then the restored Str. IDENTITY READS AS IN \
                  button_clicked and text_changed: path_len 0 means `id` is \
                  a live widget id, and a non-empty path means `id` is the \
                  TEMPLATE NODE of a stamped copy addressed by that key \
                  path — the same identity the edit arrived under, so an \
                  app folds the restore into the model its own occurrence \
                  handler fills. A coarse episode restore is a \
                  programmatic write, so nothing else would ever tell an \
                  app that folds text_changed into its model. THE GROUP \
                  SHAPE IS NECESSARY RATHER THAN TIDY: this run was fixed \
                  arity pairs, which had nowhere to put a path, so a \
                  collection row's typing could not be named here and was \
                  not banked at all (docs/undo-plan.md §3b; RULED \
                  2026-08-06).\n\
                  3. `entries` GROUPS, each ARITY-FIRST so a reader needs \
                  no schema: I64 size (values in this group, including the \
                  size itself), I64 collection, I64 flags (bit 0 = the \
                  entry EXISTS; clear means it is gone), I64 variant, I64 \
                  path_len, path_len instance-path key values, the entry's \
                  key value, then the record's fields — size says how \
                  many, and an absent entry carries none.\n\
                  4. `orders` GROUPS, arity-first likewise: I64 size, I64 \
                  collection, I64 path_len, path_len path key values, then \
                  the instance's keys IN ORDER. Present only for \
                  instances whose order the step changed, because \
                  position is the one thing per-entry statements cannot \
                  carry — and an insert or a remove CHANGES the order \
                  (every key after it moves), so those emit one too; \
                  move-only is a misreading this sentence has already \
                  cost one binding author.",
        },
        Record {
            kind: 18,
            name: "redone",
            fields: &[
                f("window", FieldTy::U64),
                f("signals", FieldTy::U32),
                f("texts", FieldTy::U32),
                f("entries", FieldTy::U32),
                f("orders", FieldTy::U32),
                f("label", FieldTy::Value),
                f("delta", FieldTy::Values),
            ],
            payload: None,
            doc: "The undone record's twin, byte-identical in layout (one \
                  encoder writes both, so the two directions cannot \
                  drift): kaya routed a redo, and this is the state the \
                  core put back. Symmetric in every respect — same silence \
                  from the echo doctrine, same four runs, same \
                  statement-not-replay reading. A redo of a group restores \
                  the values that group wrote; a redo of a banked typing \
                  episode restores its after-image. Only the FRONTIER \
                  episode redoes natively, and that one does not come \
                  through here: it is the platform's own stack moving, \
                  which emits its ordinary text_changed (the A6 gap, \
                  bounded by the clear).",
        },
        Record {
            kind: 19,
            name: "sort_requested",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("column", FieldTy::U32),
            ],
            payload: None,
            doc: "The user clicked a column header. path_len key values \
                  follow; identity reads as in button_clicked (path_len 0: \
                  id is the For container's widget id; otherwise a template \
                  node id plus the copy's key path, outermost first). \
                  `column` is the 0-based index in the declared order.\n\n\
                  A REQUEST, NOT A REPORT: nothing has changed on screen. \
                  The platform never sorts the model — the guest reorders \
                  its collection by key (collection_move: order is data) \
                  and re-declares set_columns with the new indicator, the \
                  same one-way flow as every control. Direction cycling is \
                  guest policy, which is why no direction rides here. Only \
                  the user's gesture emits — a programmatic set_columns is \
                  configuration and stays silent (the echo doctrine). \
                  Unclaimed, it drops like any unhandled occurrence.",
        },
        Record {
            kind: 20,
            name: "draw_requested",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("size", FieldTy::Values),
            ],
            payload: None,
            doc: "A `redraw` canvas is asked for its drawing AT THE SIZE IT \
                  WAS ASSIGNED (docs/canvas-plan.md §3.2.1). path_len key \
                  values follow, then WIDTH and HEIGHT as two f64 values in \
                  device-independent points; identity reads as in \
                  button_clicked. The size is the guest's next viewbox: it \
                  answers with set_drawing and the core rasterizes that \
                  stream at that size, 1:1.\n\n\
                  LATEST-WINS MAILBOX. The pending request is a SINGLE ENTRY \
                  that a newer size REPLACES rather than queues behind, and \
                  sizes the guest never caught up with are DROPPED, not drawn \
                  late — Vulkan's word for exactly this shape, and the \
                  alternative is the buffer-stuffing defect Android's frame \
                  pacing library exists to name (§15).",
        },
        Record {
            kind: 21,
            name: "tick",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("frame", FieldTy::Values),
            ],
            payload: None,
            doc: "A FRAME for a canvas with an on_tick handler: \
                  draw_requested's body plus a third f64 value, the frame's \
                  TIME in seconds.\n\n\
                  THE TIME IS THE PLATFORM'S, never the guest's own clock. \
                  Android documents that Choreographer.doFrame's frame time \
                  \"should be used instead of uptimeMillis() or nanoTime()\" \
                  because it is fixed at schedule time, and CADisplayLink \
                  exposes targetTimestamp; a guest reading its own clock \
                  re-imports exactly the jitter both platforms removed \
                  (§15.4). Under the harness the clock is the CORE'S OWN \
                  deterministic step, advanced by a verb, so a leg's frame \
                  count is part of the scene and never a fact about the \
                  machine's load.",
        },
        Record {
            kind: 22,
            name: "dropped",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("operation", FieldTy::U32),
                f("before", FieldTy::U32),
                f("anchor_len", FieldTy::U32),
                f("clip", FieldTy::U32),
                f("value", FieldTy::Values),
            ],
            payload: None,
            doc: "Content DROPPED on a widget (docs/dnd-plan.md D1): the \
                  paste occurrence with a position, an operation and, for a \
                  reorder, an anchor. IDENTITY READS AS IN button_clicked — \
                  path_len key values follow the header — then the four \
                  words: `operation` from the drag_op enum (copy or move, the \
                  one the core settled on), `before` 1 when a reorder lands \
                  before its anchor row and 0 onto it, `anchor_len` the \
                  anchor row's key count (0 when there is no anchor), `clip` \
                  the single representation kind that arrived; then the \
                  point as two F64 values in the destination's own \
                  coordinates, the anchor's keys, and the representation's \
                  values in pasted's own layout. THE APP'S TRANSACTION AFTER \
                  THIS IS THE VISIBLE EFFECT: a same-app move removes its \
                  original in the same batch; a reorder confirms with \
                  collection_move against the anchor. Files are picked \
                  handles, redeemed with kaya_open_picked (D6).",
        },
        Record {
            kind: 23,
            name: "drag_ended",
            fields: &[
                f("id", FieldTy::U64),
                f("path_len", FieldTy::U32),
                f("reserved", FieldTy::U32),
                f("operation", FieldTy::U32),
                f("reserved2", FieldTy::U32),
            ],
            payload: None,
            doc: "A drag that began on this widget has ended, and this is \
                  what the destination did with it: `operation` from the \
                  drag_op enum, `none` for a cancelled or refused drag. The \
                  source of a move removes its original HERE for a drop that \
                  landed outside this app; a same-app move was already one \
                  transaction with its `dropped`. Identity as in \
                  button_clicked, key values after the header.",
        },
    ],
    enums: &[
        EnumSpec {
            name: "value",
            variants: &[("bool", 1), ("i64", 2), ("f64", 3), ("str", 4), ("blob", 5)],
        },
        EnumSpec {
            // What a clip can be offered as. Closed on purpose
            // (docs/clipboard-plan.md §0); `custom` is the escape
            // hatch, passed through opaquely under an app-chosen id.
            //
            // The VALUES DOUBLE AS BIT POSITIONS: a copy says which
            // representations it carries, and a widget says which it
            // accepts, as a mask over these.
            name: "clip",
            variants: &[
                ("text", 1),
                ("html", 2),
                ("image", 4),
                ("files", 8),
                ("custom", 16),
            ],
        },
        EnumSpec {
            // What a drop settles on (docs/dnd-plan.md D3): the source's
            // mask and the destination's meet here, and `none` is the
            // outcome of a cancelled or refused drag. copy and move only;
            // link and ask are refused on the record.
            name: "drag_op",
            variants: &[("none", 0), ("copy", 1), ("move", 2)],
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
                ("radio", 12),
                ("grid", 13),
                ("textarea", 14),
                ("canvas", 15),
            ],
        },
        EnumSpec {
            // THE DRAW OPCODES (docs/canvas-plan.md §3.3): five geometry
            // ops and two text ops, each followed on the wire by its own
            // operands as tagged values. Curves, dashes, joins, blends,
            // gradients and antialiasing control are refusals, not
            // omissions (§3.3). THE IDS ARE APPEND-ONLY: wire values in
            // eight bindings and three interpreter copies.
            name: "draw_op",
            variants: &[
                ("move_to", 1),
                ("line_to", 2),
                ("close", 3),
                ("stroke", 4),
                ("fill", 5),
                ("font", 6),
                ("text", 7),
            ],
        },
        EnumSpec {
            // PAINT IS A ROLE, NEVER RGB (§3.4): the roles resolve in the
            // core, per appearance, so a series line is legible in both
            // modes and the buffer is byte-identical per mode. Literal
            // RGB is the named escalation, gated on an artifact.
            name: "paint",
            variants: &[
                ("series", 1),
                ("series_fill", 2),
                ("grid", 3),
                ("axis", 4),
                ("ground", 5),
            ],
        },
        EnumSpec {
            name: "fill_rule",
            variants: &[("nonzero", 0), ("even_odd", 1)],
        },
        EnumSpec {
            // WHAT A CANVAS DOES WITH A TRACK THAT IS NOT ITS VIEWBOX
            // (docs/canvas-plan.md §3.2.1). `scale` and `fixed` declare
            // the drawing CONSTANT in size, which licenses the core to
            // answer a size change by itself. `scale` is 0 because it is
            // what a guest that declares nothing gets; `tick` IS `redraw`
            // plus the frame drive, not a fourth geometry (§15.4).
            name: "size_policy",
            variants: &[("scale", 0), ("fixed", 1), ("redraw", 2), ("tick", 3)],
        },
        EnumSpec {
            // SVG's `text-anchor`, deliberately. Separate from the
            // `align` enum, which is a layout cross-axis rule and has no
            // `middle`.
            name: "text_align",
            variants: &[("start", 0), ("middle", 1), ("end", 2)],
        },
        EnumSpec {
            // SVG's `dominant-baseline`, same reasoning as text_align.
            name: "text_baseline",
            variants: &[("alphabetic", 0), ("middle", 1), ("top", 2), ("bottom", 3)],
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
                ("columns", 11),
                ("a11y_id", 12),
                ("a11y_label", 13),
                ("a11y_hint", 14),
                ("accepts", 15),
                ("role", 16),
                ("inset", 17),
                ("axis", 18),
            ],
        },
        EnumSpec {
            name: "wprop",
            variants: &[
                ("title", 1),
                ("width", 2),
                ("height", 3),
                ("veto_close", 4),
                ("sections_presentation", 5),
                ("panes", 6),
                ("dirty", 7),
                ("inset", 8),
            ],
        },
        EnumSpec {
            name: "eprop",
            variants: &[("title", 1), ("intercept_back", 2)],
        },
        EnumSpec {
            name: "sprop",
            variants: &[("title", 1), ("icon", 2), ("symbol", 3)],
        },
        EnumSpec {
            // The menu item vocabulary (DESIGN.md, Menus). `menu` and
            // `radio_group` are the grouping nodes; the rest are leaves.
            name: "menu_kind",
            variants: &[
                ("menu", 1),
                ("action", 2),
                ("toggle", 3),
                ("radio_group", 4),
                ("radio_option", 5),
                ("separator", 6),
            ],
        },
        EnumSpec {
            // Menu-item properties, in lockstep with MENU_PROPS (pinned
            // by test): the enum feeds constants, MENU_PROPS feeds the
            // typed setter generation.
            name: "mprop",
            variants: &[
                ("label", 1),
                ("enabled", 2),
                ("checked", 3),
                ("value", 4),
                ("icon", 5),
                ("primary", 6),
                ("shortcut", 7),
                ("role", 8),
                ("symbol", 9),
            ],
        },
        EnumSpec {
            // DESIGN.md, Sections: auto = the platform's dominant
            // idiom, bar = horizontal, sidebar = the leading-edge list.
            name: "sections_presentation",
            variants: &[("auto", 0), ("bar", 1), ("sidebar", 2)],
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
            // What kaya_open_picked opens a handle for (Android's
            // openFileDescriptor mode string, WinUI's FileAccessMode,
            // ordinary open flags elsewhere). Writability is
            // DISCOVERABLE but not REQUESTABLE — no open picker on any
            // platform takes an access mode — so the open is fallible
            // in ways the pick is not.
            name: "file_mode",
            variants: &[("read", 0), ("write", 1), ("read_write", 2)],
        },
        EnumSpec {
            // WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR
            // (docs/styling-plan.md Slice 2b), one entry per BACKEND
            // ROSTER row. A TAG NEVER REACHES A GUEST'S PLATFORM
            // QUESTION: the binding cannot resolve it (the JVM says
            // "Linux" on Android). The ids are APPEND-ONLY.
            name: "platform",
            variants: &[
                ("mac", 1),
                ("ios", 2),
                ("linux", 3),
                ("windows", 4),
                ("android", 5),
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
            // The arrangement axis (docs/adaptive-layout-plan.md D1).
            // horizontal = row's initial value, vertical = column's.
            name: "axis",
            variants: &[
                ("horizontal", 0),
                ("vertical", 1),
            ],
        },
        EnumSpec {
            // A window's named size class (ruled 2026-08-31): what a
            // breakpoint's `size_class` value and the metrics report's
            // platform class speak. `none` is the report's "this
            // platform has no class of its own — derive from the
            // width"; a breakpoint may name `compact` alone today.
            name: "size_class",
            variants: &[
                ("none", 0),
                ("compact", 1),
                ("regular", 2),
            ],
        },
        EnumSpec {
            name: "role",
            variants: &[
                ("destructive", 1),
                ("prominent", 2),
                ("heading", 3),
                ("caption", 4),
            ],
        },
        EnumSpec {
            // THE SEMANTIC ICON VOCABULARY (docs/styling-plan.md D6;
            // DESIGN.md, "Icons want names, not bytes"): an app names a
            // CONCEPT and each backend draws its own platform's glyph.
            // THE IDS ARE APPEND-ONLY, FOREVER: wire values in eight
            // generated bindings and four backends' lowering tables, so
            // a renumber would silently redraw every shipped app's menus.
            // A new concept takes 21.
            name: "symbol",
            variants: &[
                ("add", 1),
                ("remove", 2),
                ("delete", 3),
                ("edit", 4),
                ("done", 5),
                ("close", 6),
                ("search", 7),
                ("settings", 8),
                ("refresh", 9),
                ("info", 10),
                ("warning", 11),
                ("back", 12),
                ("forward", 13),
                ("more", 14),
                ("copy", 15),
                ("paste", 16),
                ("star", 17),
                ("lock", 18),
                ("person", 19),
                ("home", 20),
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
        AlertId, AlertSpec, Blob, CollectionId, CommandKind, MenuItemId, MenuItemKind, MenuProp,
        Prop, PropValue, SignalId, TemplateNodeId, TextRange, TxOp, Value, ValueType, WidgetId,
        WidgetKind, WindowId,
    };
    use crate::wire;

    /// A spec-driven generic encoder: what any generated binding does,
    /// expressed once here.
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

    /// The fingerprint is stable and nonzero; a spec edit that failed to
    /// change it would let revisions collide.
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
            ("add_section", wire::TX_ADD_SECTION),
            ("select_section", wire::TX_SELECT_SECTION),
            ("set_section_prop", wire::TX_SET_SECTION_PROP),
            ("menu_item_create", wire::TX_MENU_ITEM_CREATE),
            ("menu_item_append", wire::TX_MENU_ITEM_APPEND),
            ("menubar_append", wire::TX_MENUBAR_APPEND),
            ("context_attach", wire::TX_CONTEXT_ATTACH),
            ("context_attach_node", wire::TX_CONTEXT_ATTACH_NODE),
            ("set_menu_prop", wire::TX_SET_MENU_PROP),
            ("show_file_dialog", wire::TX_SHOW_FILE_DIALOG),
            ("copy", wire::TX_COPY),
            ("read_clipboard", wire::TX_READ_CLIPBOARD),
            ("undo_group", wire::TX_UNDO_GROUP),
            ("highlight_ranges", wire::TX_HIGHLIGHT_RANGES),
            ("select_range", wire::TX_SELECT_RANGE),
            ("reveal_range", wire::TX_REVEAL_RANGE),
            ("show_save_dialog", wire::TX_SHOW_SAVE_DIALOG),
            ("set_brand_accent", wire::TX_SET_BRAND_ACCENT),
            ("set_brand_typeface", wire::TX_SET_BRAND_TYPEFACE),
            ("set_app_identity", wire::TX_SET_APP_IDENTITY),
            ("set_column_headers", wire::TX_SET_COLUMN_HEADERS),
            ("set_drawing", wire::TX_SET_DRAWING),
            ("set_size_policy", wire::TX_SET_SIZE_POLICY),
            ("create_breakpoint", wire::TX_CREATE_BREAKPOINT),
            ("set_drag_source", wire::TX_SET_DRAG_SOURCE),
            ("set_drop_target", wire::TX_SET_DROP_TARGET),
            ("set_reorderable", wire::TX_SET_REORDERABLE),
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
                ("add_section", wire::APPLY_ADD_SECTION),
                ("select_section", wire::APPLY_SELECT_SECTION),
                ("set_section_prop", wire::APPLY_SET_SECTION_PROP),
                ("menu_item_create", wire::APPLY_MENU_ITEM_CREATE),
                ("menu_item_append", wire::APPLY_MENU_ITEM_APPEND),
                ("menubar_append", wire::APPLY_MENUBAR_APPEND),
                ("context_attach", wire::APPLY_CONTEXT_ATTACH),
                ("context_attach_node", wire::APPLY_CONTEXT_ATTACH_NODE),
                ("set_menu_prop", wire::APPLY_SET_MENU_PROP),
                ("present_file_dialog", wire::APPLY_PRESENT_FILE_DIALOG),
                ("copy", wire::APPLY_COPY),
                ("read_clipboard", wire::APPLY_READ_CLIPBOARD),
                ("clear_undo", wire::APPLY_CLEAR_UNDO),
                ("highlight_ranges", wire::APPLY_HIGHLIGHT_RANGES),
                ("select_range", wire::APPLY_SELECT_RANGE),
                ("reveal_range", wire::APPLY_REVEAL_RANGE),
                ("present_save_dialog", wire::APPLY_PRESENT_SAVE_DIALOG),
            ("set_brand", wire::APPLY_SET_BRAND),
            ("set_typeface", wire::APPLY_SET_TYPEFACE),
            ("set_app_identity", wire::APPLY_SET_APP_IDENTITY),
                ("set_column_headers", wire::APPLY_SET_COLUMN_HEADERS),
                ("set_drawing", wire::APPLY_SET_DRAWING),
                ("fold", wire::APPLY_FOLD),
                ("set_drag_source", wire::APPLY_SET_DRAG_SOURCE),
                ("set_drop_target", wire::APPLY_SET_DROP_TARGET),
                ("set_reorderable", wire::APPLY_SET_REORDERABLE),
            ]
        );
        // The WHOLE list, not indexed asserts: an indexed pin says
        // nothing about a record appended past its last index.
        let occurrence: Vec<(&str, u16)> =
            SPEC.occurrence.iter().map(|r| (r.name, r.kind)).collect();
        assert_eq!(
            occurrence,
            vec![
                ("button_clicked", crate::ring::REC_BUTTON_CLICKED),
                ("text_changed", crate::ring::REC_TEXT_CHANGED),
                ("toggled", crate::ring::REC_TOGGLED),
                ("value_changed", crate::ring::REC_VALUE_CHANGED),
                ("close_requested", crate::ring::REC_CLOSE_REQUESTED),
                ("window_closed", crate::ring::REC_WINDOW_CLOSED),
                ("alert_result", crate::ring::REC_ALERT_RESULT),
                ("entry_popped", crate::ring::REC_ENTRY_POPPED),
                ("back_requested", crate::ring::REC_BACK_REQUESTED),
                ("section_selected", crate::ring::REC_SECTION_SELECTED),
                ("menu_activated", crate::ring::REC_MENU_ACTIVATED),
                ("menu_toggled", crate::ring::REC_MENU_TOGGLED),
                ("menu_value_changed", crate::ring::REC_MENU_VALUE_CHANGED),
                ("file_dialog_result", crate::ring::REC_FILE_DIALOG_RESULT),
                ("clipboard_result", crate::ring::REC_CLIPBOARD_RESULT),
                ("pasted", crate::ring::REC_PASTED),
                ("undone", crate::ring::REC_UNDONE),
                ("redone", crate::ring::REC_REDONE),
                ("sort_requested", crate::ring::REC_SORT_REQUESTED),
                ("draw_requested", crate::ring::REC_DRAW_REQUESTED),
                ("tick", crate::ring::REC_TICK),
                ("dropped", crate::ring::REC_DROPPED),
                ("drag_ended", crate::ring::REC_DRAG_ENDED),
            ]
        );
    }

    /// A BACKEND MAY ONLY UNWRAP A TAG THE CORE PROMISES TO SET — the
    /// scene.rs sibling holds the two CORE paths together, which is not
    /// the same thing: flip `carries_tag` to false and both still agree,
    /// on None, while `tag.expect(...)` aborts on GTK and WinUI, a line
    /// no mac build compiles.
    #[test]
    fn backends_only_unwrap_tags_the_core_sets() {
        let sources: &[(&str, &str)] = &[
            ("gtk.rs", include_str!("gtk.rs")),
            ("winui/mod.rs", include_str!("winui/mod.rs")),
        ];
        // The match is on the kind's name rather than on a list this
        // test would carry.
        let mut seen = 0usize;
        for (file, src) in sources {
            for (i, line) in src.lines().enumerate() {
                let Some(rest) = line.split("expect(\"").nth(1) else {
                    continue;
                };
                let Some(sentence) = rest.split('"').next() else {
                    continue;
                };
                if !sentence.contains("carry a tag") {
                    continue;
                }
                seen += 1;
                // The sentences are English, so the noun is plural:
                // match the leading noun against each kind's spellings
                // rather than making the backends write "entrys".
                let noun = sentence.split_whitespace().next().unwrap_or("");
                let named = WidgetKind::ALL.iter().find(|k| {
                    let base = format!("{k:?}").to_lowercase();
                    let plural_y = base
                        .strip_suffix('y')
                        .map(|stem| format!("{stem}ies"))
                        .unwrap_or_default();
                    noun == base
                        || noun == format!("{base}s")
                        || noun == format!("{base}es")
                        || (!plural_y.is_empty() && noun == plural_y)
                });
                let kind = named.unwrap_or_else(|| {
                    panic!(
                        "kaya: {file}:{} unwraps a tag with the sentence {sentence:?}, \
                         which names no widget kind. A tag `expect` says which kind \
                         it speaks for so this pairing can read it.",
                        i + 1
                    )
                });
                assert!(
                    kind.carries_tag(),
                    "kaya: {file}:{} unwraps the identity tag for {kind:?}, but \
                     WidgetKind::carries_tag says {kind:?} carries none — the core \
                     sends None and this line aborts the process on that backend. \
                     Either the kind reports (add it to carries_tag) or this \
                     backend must handle the absent tag.",
                    i + 1
                );
            }
        }
        // ANTI-VACUITY: this reads source text through a substring, the
        // shape that rots into "always green" when a backend rewords
        // its expects (docs/traps.md).
        assert!(
            seen >= 6,
            "kaya: found only {seen} tag `expect`s across the two backends that \
             have them — this pairing has stopped seeing the lines it exists to \
             check, so it can no longer fail"
        );
    }

    /// `WidgetKind::ALL` IS THE SPEC'S KIND LIST, one entry per variant:
    /// a kind added to the spec and NOT to ALL would join the wire
    /// vocabulary while sitting outside every sweep that walks ALL.
    #[test]
    fn all_widget_kinds_are_the_spec_s_kinds() {
        let kind_enum = SPEC
            .enums
            .iter()
            .find(|e| e.name == "kind")
            .expect("spec has a kind enum");
        assert_eq!(
            WidgetKind::ALL.len(),
            kind_enum.variants.len(),
            "kaya: the spec declares {} widget kinds and WidgetKind::ALL lists {} \
             — a kind added to the spec must join ALL, or every sweep that walks \
             ALL skips it silently",
            kind_enum.variants.len(),
            WidgetKind::ALL.len()
        );
        // Same order, so the pairing below is the spec's own and not a
        // coincidence of two lists that happen to be the same length.
        for (kind, (name, _)) in WidgetKind::ALL.iter().zip(kind_enum.variants) {
            let spelled = format!("{kind:?}").to_lowercase();
            assert_eq!(
                &spelled, name,
                "kaya: WidgetKind::ALL is out of order with the spec's kind enum \
                 ({spelled} sits where {name} is declared)"
            );
        }
    }

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
        let sprop_enum = SPEC
            .enums
            .iter()
            .find(|e| e.name == "sprop")
            .expect("spec has an sprop enum");
        assert_eq!(SECTION_PROPS.len(), sprop_enum.variants.len());
        for ((name, id, _), (ename, eid)) in SECTION_PROPS.iter().zip(sprop_enum.variants) {
            assert_eq!(name, ename);
            assert_eq!(id, eid);
        }
        let mprop_enum = SPEC
            .enums
            .iter()
            .find(|e| e.name == "mprop")
            .expect("spec has an mprop enum");
        assert_eq!(MENU_PROPS.len(), mprop_enum.variants.len());
        for ((name, id, _), (ename, eid)) in MENU_PROPS.iter().zip(mprop_enum.variants) {
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
                    ("kind", "radio") => wire::KIND_RADIO,
                    ("kind", "grid") => wire::KIND_GRID,
                    ("kind", "textarea") => wire::KIND_TEXTAREA,
                    ("kind", "canvas") => wire::KIND_CANVAS,
                    ("draw_op", _) => canvas_pin(wire::DRAW_OPS, name),
                    ("paint", _) => canvas_pin(wire::PAINTS, name),
                    ("fill_rule", _) => canvas_pin(wire::FILL_RULES, name),
                    ("text_align", _) => canvas_pin(wire::TEXT_ALIGNS, name),
                    ("text_baseline", _) => canvas_pin(wire::TEXT_BASELINES, name),
                    ("size_policy", _) => canvas_pin(wire::SIZE_POLICIES, name),
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
                    ("prop", "columns") => wire::PROP_COLUMNS,
                    ("prop", "a11y_id") => wire::PROP_A11Y_ID,
                    ("prop", "a11y_label") => wire::PROP_A11Y_LABEL,
                    ("prop", "a11y_hint") => wire::PROP_A11Y_HINT,
                    ("prop", "accepts") => wire::PROP_ACCEPTS,
                    ("prop", "role") => wire::PROP_ROLE,
                    ("prop", "inset") => wire::PROP_INSET,
                    ("prop", "axis") => wire::PROP_AXIS,
                    ("wprop", "title") => wire::WPROP_TITLE,
                    ("wprop", "width") => wire::WPROP_WIDTH,
                    ("wprop", "height") => wire::WPROP_HEIGHT,
                    ("wprop", "veto_close") => wire::WPROP_VETO_CLOSE,
                    ("wprop", "panes") => wire::WPROP_PANES,
                    ("wprop", "dirty") => wire::WPROP_DIRTY,
                    ("wprop", "inset") => wire::WPROP_INSET,
                    ("wprop", "sections_presentation") => wire::WPROP_SECTIONS_PRESENTATION,
                    ("eprop", "title") => wire::EPROP_TITLE,
                    ("eprop", "intercept_back") => wire::EPROP_INTERCEPT_BACK,
                    ("sprop", "title") => wire::SPROP_TITLE,
                    ("sprop", "icon") => wire::SPROP_ICON,
                    ("sprop", "symbol") => wire::SPROP_SYMBOL,
                    ("menu_kind", "menu") => wire::MENU_KIND_MENU,
                    ("menu_kind", "action") => wire::MENU_KIND_ACTION,
                    ("menu_kind", "toggle") => wire::MENU_KIND_TOGGLE,
                    ("menu_kind", "radio_group") => wire::MENU_KIND_RADIO_GROUP,
                    ("menu_kind", "radio_option") => wire::MENU_KIND_RADIO_OPTION,
                    ("menu_kind", "separator") => wire::MENU_KIND_SEPARATOR,
                    ("mprop", "label") => wire::MPROP_LABEL,
                    ("mprop", "enabled") => wire::MPROP_ENABLED,
                    ("mprop", "checked") => wire::MPROP_CHECKED,
                    ("mprop", "value") => wire::MPROP_VALUE,
                    ("mprop", "icon") => wire::MPROP_ICON,
                    ("mprop", "primary") => wire::MPROP_PRIMARY,
                    ("mprop", "shortcut") => wire::MPROP_SHORTCUT,
                    ("mprop", "role") => wire::MPROP_ROLE,
                    ("mprop", "symbol") => wire::MPROP_SYMBOL,
                    ("sections_presentation", "auto") => wire::SECTIONS_PRESENTATION_AUTO,
                    ("sections_presentation", "bar") => wire::SECTIONS_PRESENTATION_BAR,
                    ("sections_presentation", "sidebar") => {
                        wire::SECTIONS_PRESENTATION_SIDEBAR
                    }
                    ("alert_choice", "action0") => wire::ALERT_CHOICE_ACTION0,
                    ("alert_choice", "action1") => wire::ALERT_CHOICE_ACTION1,
                    ("alert_choice", "cancel") => wire::ALERT_CHOICE_CANCEL,
                    ("axis", "horizontal") => wire::AXIS_HORIZONTAL,
                    ("axis", "vertical") => wire::AXIS_VERTICAL,
                    ("size_class", "none") => wire::SIZE_CLASS_NONE,
                    ("size_class", "compact") => wire::SIZE_CLASS_COMPACT,
                    ("size_class", "regular") => wire::SIZE_CLASS_REGULAR,
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
                    ("drag_op", "none") => wire::DRAG_OP_NONE,
                    ("drag_op", "copy") => wire::DRAG_OP_COPY,
                    ("drag_op", "move") => wire::DRAG_OP_MOVE,
                    ("clip", "text") => wire::CLIP_TEXT,
                    ("clip", "html") => wire::CLIP_HTML,
                    ("clip", "image") => wire::CLIP_IMAGE,
                    ("clip", "files") => wire::CLIP_FILES,
                    ("clip", "custom") => wire::CLIP_CUSTOM,
                    ("role", "destructive") => wire::ROLE_DESTRUCTIVE,
                    ("role", "prominent") => wire::ROLE_PROMINENT,
                    ("role", "heading") => wire::ROLE_HEADING,
                    ("role", "caption") => wire::ROLE_CAPTION,
                    ("symbol", "add") => wire::SYMBOL_ADD,
                    ("symbol", "remove") => wire::SYMBOL_REMOVE,
                    ("symbol", "delete") => wire::SYMBOL_DELETE,
                    ("symbol", "edit") => wire::SYMBOL_EDIT,
                    ("symbol", "done") => wire::SYMBOL_DONE,
                    ("symbol", "close") => wire::SYMBOL_CLOSE,
                    ("symbol", "search") => wire::SYMBOL_SEARCH,
                    ("symbol", "settings") => wire::SYMBOL_SETTINGS,
                    ("symbol", "refresh") => wire::SYMBOL_REFRESH,
                    ("symbol", "info") => wire::SYMBOL_INFO,
                    ("symbol", "warning") => wire::SYMBOL_WARNING,
                    ("symbol", "back") => wire::SYMBOL_BACK,
                    ("symbol", "forward") => wire::SYMBOL_FORWARD,
                    ("symbol", "more") => wire::SYMBOL_MORE,
                    ("symbol", "copy") => wire::SYMBOL_COPY,
                    ("symbol", "paste") => wire::SYMBOL_PASTE,
                    ("symbol", "star") => wire::SYMBOL_STAR,
                    ("symbol", "lock") => wire::SYMBOL_LOCK,
                    ("symbol", "person") => wire::SYMBOL_PERSON,
                    ("symbol", "home") => wire::SYMBOL_HOME,
                    ("file_mode", "read") => wire::FILE_MODE_READ,
                    ("file_mode", "write") => wire::FILE_MODE_WRITE,
                    ("file_mode", "read_write") => wire::FILE_MODE_READ_WRITE,
                    ("platform", "mac") => wire::PLATFORM_MAC,
                    ("platform", "ios") => wire::PLATFORM_IOS,
                    ("platform", "linux") => wire::PLATFORM_LINUX,
                    ("platform", "windows") => wire::PLATFORM_WINDOWS,
                    ("platform", "android") => wire::PLATFORM_ANDROID,
                    other => panic!("unpinned enum variant {other:?}"),
                };
                assert_eq!(*value, expected, "{}::{}", e.name, name);
            }
        }
    }

    /// Look one canvas enum variant up in wire.rs's own (value, name)
    /// table BY NAME, so a variant the table does not carry fails here
    /// rather than resolving to some other variant's number.
    fn canvas_pin(table: &[(i64, &str)], name: &str) -> u32 {
        let (value, _) = table
            .iter()
            .find(|(_, n)| *n == name)
            .unwrap_or_else(|| panic!("wire.rs's table carries no {name:?}"));
        u32::try_from(*value).expect("a canvas enum value is a small non-negative number")
    }

    /// The six canvas vocabularies are each spelled TWICE — the spec's
    /// enum and wire.rs's (value, name) table, which the core's refusals
    /// and every canvas diagnostic print from. enums_match_wire pins the
    /// VALUES; this pins the NAMES and the COVERAGE, because a drifted
    /// name leaves a refusal naming an opcode the app never wrote.
    #[test]
    fn canvas_names_match_the_spec_enums() {
        let pairs: &[(&str, &[(i64, &str)])] = &[
            ("draw_op", wire::DRAW_OPS),
            ("paint", wire::PAINTS),
            ("fill_rule", wire::FILL_RULES),
            ("text_align", wire::TEXT_ALIGNS),
            ("text_baseline", wire::TEXT_BASELINES),
            ("size_policy", wire::SIZE_POLICIES),
        ];
        for (enum_name, table) in pairs {
            let e = SPEC
                .enums
                .iter()
                .find(|e| e.name == *enum_name)
                .unwrap_or_else(|| panic!("spec has a {enum_name} enum"));
            assert_eq!(e.variants.len(), table.len(), "{enum_name} coverage");
            for ((name, value), (id, table_name)) in e.variants.iter().zip(*table) {
                assert_eq!(name, table_name, "{enum_name} name drift at id {id}");
                assert_eq!(i64::from(*value), *id, "{enum_name} id drift at {name}");
            }
        }
        // Nothing outside a table resolves, including the neighbours and
        // the negative a signed wire slot can carry.
        for (table, outside) in [
            (wire::DRAW_OPS, [0i64, 8, -1].as_slice()),
            (wire::PAINTS, &[0, 6, -1]),
            (wire::FILL_RULES, &[-1, 2, 3]),
            (wire::TEXT_ALIGNS, &[-1, 3, 4]),
            (wire::TEXT_BASELINES, &[-1, 4, 5]),
            (wire::SIZE_POLICIES, &[-1, 4, 5]),
        ] {
            for value in outside {
                assert_eq!(wire::vocab_name(table, *value), None, "{value} resolved");
            }
        }
    }

    /// wire::SYMBOLS is a SECOND spelling of the symbol vocabulary — the
    /// (id, name) table the root's wall and every diagnostic print from.
    /// enums_match_wire pins the VALUES; this pins the NAMES, because a
    /// drifted name leaves the wall naming a concept the app never wrote.
    #[test]
    fn symbol_names_match_the_spec_enum() {
        let e = SPEC
            .enums
            .iter()
            .find(|e| e.name == "symbol")
            .expect("spec has a symbol enum");
        assert_eq!(e.variants.len(), wire::SYMBOLS.len());
        for ((name, value), (id, table_name)) in e.variants.iter().zip(wire::SYMBOLS) {
            assert_eq!(name, table_name, "symbol name drift at id {id}");
            assert_eq!(value, id, "symbol id drift at {name}");
            assert_eq!(wire::symbol_name(i64::from(*value)), Some(*name));
        }
        // Nothing outside the table resolves, including the off-by-one
        // neighbours and the negative a signed wire slot can carry.
        assert_eq!(wire::symbol_name(0), None);
        assert_eq!(wire::symbol_name(21), None);
        assert_eq!(wire::symbol_name(-1), None);
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

        // Menus: a bar catalog (File > Save), a context attach on a live
        // widget and a template node, and a const-tail set_menu_prop.
        w.record(
            tx_record("menu_item_create"),
            &[Arg::U64(100), Arg::U32(wire::MENU_KIND_ACTION), Arg::U32(0)],
        );
        w.record(
            tx_record("menu_item_create"),
            &[Arg::U64(101), Arg::U32(wire::MENU_KIND_MENU), Arg::U32(0)],
        );
        w.record(tx_record("menu_item_append"), &[Arg::U64(101), Arg::U64(100)]);
        w.record(tx_record("menubar_append"), &[Arg::U64(0), Arg::U64(101)]);
        w.record(tx_record("context_attach"), &[Arg::U64(5), Arg::U64(101)]);
        w.record(tx_record("context_attach_node"), &[Arg::U64(8), Arg::U64(101)]);
        // set_menu_prop carries the SET_PROPERTY variable tail (spliced
        // by hand, as a generated helper would).
        {
            let start = w.buf.len();
            w.buf.extend_from_slice(&[0u8; 8]);
            w.buf.extend_from_slice(&100u64.to_le_bytes());
            w.buf.extend_from_slice(&wire::MPROP_LABEL.to_le_bytes());
            w.buf.extend_from_slice(&wire::SOURCE_CONST.to_le_bytes());
            w.value(&Value::from("Save"));
            let size = (w.buf.len() - start) as u32;
            w.buf[start..start + 4].copy_from_slice(&size.to_le_bytes());
            w.buf[start + 4..start + 6].copy_from_slice(&wire::TX_SET_MENU_PROP.to_le_bytes());
        }

        // Text ranges: a two-range declaration through the Values list,
        // then the two single-range commands. The offsets are UTF-8 BYTE
        // offsets — this test proves the ENCODING round-trips; the core's
        // validation and unit conversion are scene.rs's tests.
        w.record(
            tx_record("highlight_ranges"),
            &[
                Arg::U64(2),
                Arg::U32(2),
                Arg::U32(0),
                Arg::Values(vec![
                    Value::I64(4),
                    Value::I64(9),
                    Value::I64(20),
                    Value::I64(25),
                ]),
            ],
        );
        w.record(tx_record("select_range"), &[Arg::U64(2), Arg::U64(20), Arg::U64(25)]);
        w.record(tx_record("reveal_range"), &[Arg::U64(2), Arg::U64(20), Arg::U64(25)]);

        // The brand typeface. The PAIR SHAPE is what this proves: the
        // spec says `platforms` is one Values field and wire.rs reads
        // it in twos, and nothing but a round trip holds the two
        // readings together.
        w.record(
            tx_record("set_brand_typeface"),
            &[
                Arg::U32(0),
                Arg::U32(0),
                Arg::Value(Value::from("Georgia")),
                Arg::Values(vec![
                    Value::I64(i64::from(wire::PLATFORM_LINUX)),
                    Value::from("DejaVu Serif"),
                    Value::I64(i64::from(wire::PLATFORM_ANDROID)),
                    Value::from("serif"),
                ]),
                Arg::Value(Value::from("")),
            ],
        );

        // The app identity: no icon — mask bit 0 clear and an empty Str
        // riding the always-written blob slot. Written through the SAME
        // generic writer as the typeface, because two records claiming
        // one shape have to decode through one reader to prove it.
        w.record(
            tx_record("set_app_identity"),
            &[
                Arg::U32(0),
                Arg::U32(0),
                Arg::Value(Value::from("Aurora Notes")),
                Arg::Value(Value::from("")),
            ],
        );

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
            TxOp::MenuItemCreate {
                item: MenuItemId(100),
                kind: MenuItemKind::Action,
            },
            TxOp::MenuItemCreate {
                item: MenuItemId(101),
                kind: MenuItemKind::Menu,
            },
            TxOp::MenuItemAppend {
                parent: MenuItemId(101),
                child: MenuItemId(100),
            },
            TxOp::MenubarAppend {
                window: WindowId(0),
                item: MenuItemId(101),
            },
            TxOp::ContextAttach {
                widget: WidgetId(5),
                item: MenuItemId(101),
            },
            TxOp::ContextAttachNode {
                node: TemplateNodeId(8),
                item: MenuItemId(101),
            },
            TxOp::SetMenuProp {
                item: MenuItemId(100),
                prop: MenuProp::Label,
                value: PropValue::Const(Value::from("Save")),
            },
            TxOp::HighlightRanges {
                widget: WidgetId(2),
                ranges: vec![TextRange::new(4, 9), TextRange::new(20, 25)],
            },
            TxOp::SelectRange {
                widget: WidgetId(2),
                range: TextRange::new(20, 25),
            },
            TxOp::RevealRange {
                widget: WidgetId(2),
                range: TextRange::new(20, 25),
            },
            TxOp::SetBrandTypeface(crate::protocol::TypefaceRequest {
                family: "Georgia".into(),
                platforms: vec![
                    (wire::PLATFORM_LINUX, "DejaVu Serif".into()),
                    (wire::PLATFORM_ANDROID, "serif".into()),
                ],
                font: None,
            }),
            TxOp::SetAppIdentity(crate::protocol::AppIdentity {
                name: "Aurora Notes".into(),
                icon: None,
            }),
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

    /// THE MASK AND THE SLOT MAY NOT DISAGREE: a clear mask bit with a
    /// real blob in the font slot would drop the brand's licensed face
    /// with no error anywhere. wire.rs dies on the disagreement, and
    /// the record below is exactly what a buggy encoder would emit.
    #[test]
    #[should_panic(expected = "carries a font blob but its mask")]
    fn typeface_mask_slot_disagreement_is_loud() {
        let mut w = GenericWriter { buf: Vec::new(), blobs: Vec::new() };
        w.record(
            tx_record("set_brand_typeface"),
            &[
                Arg::U32(0), // mask bit 0 CLEAR: "no font present"
                Arg::U32(0),
                Arg::Value(Value::from("Sora")),
                Arg::Values(vec![]),
                // ...while the always-written slot carries a real blob.
                Arg::Value(Value::Blob(Blob::from(&b"not a font"[..]))),
            ],
        );
        let blobs = w.blobs.clone();
        wire::decode_transaction_with_blobs(&w.buf, &move |h| {
            blobs.get(h as usize - 1).cloned()
        });
    }

    /// THE IDENTITY'S SLOT, THE SAME WALL: the record copies the
    /// typeface's mask-plus-always-written-slot convention, so a clear
    /// mask bit over a real blob would drop the app's MARK silently.
    #[test]
    #[should_panic(expected = "carries an icon blob but its mask")]
    fn identity_mask_slot_disagreement_is_loud() {
        let mut w = GenericWriter { buf: Vec::new(), blobs: Vec::new() };
        w.record(
            tx_record("set_app_identity"),
            &[
                Arg::U32(0), // mask bit 0 CLEAR: "no icon present"
                Arg::U32(0),
                Arg::Value(Value::from("Aurora Notes")),
                // ...while the always-written slot carries a real blob.
                Arg::Value(Value::Blob(Blob::from(&b"not an icon"[..]))),
            ],
        );
        let blobs = w.blobs.clone();
        wire::decode_transaction_with_blobs(&w.buf, &move |h| {
            blobs.get(h as usize - 1).cloned()
        });
    }
}
