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
    // Grid-only: how many columns children fill row-major (F64 like
    // every numeric slot; integral >= 1, domain-checked at the root).
    ("columns", 11, PropKind::F64),
    // The accessibility IDENTIFIER: a stable authored key, never
    // spoken. Its platform mappings are the automation identifiers —
    // accessibilityIdentifier, testTag, AutomationProperties.AutomationId
    // — so it is a real product surface (a11y tooling and UI automation
    // both key on it) with kaya's own harness as first consumer, not
    // test plumbing on the production wire.
    ("a11y_id", 12, PropKind::Str),
    // The accessibility LABEL: what an assistive client SPEAKS for this
    // widget. Deliberately separate from a11y_id — conflating them
    // would read every automation key aloud to screen-reader users.
    // Maps to accessibilityLabel, contentDescription,
    // AutomationProperties.Name, and GTK's LABEL accessible property.
    ("a11y_label", 13, PropKind::Str),
    // The accessibility HINT: what happens when the user activates this
    // control, which is what every platform's hint actually means —
    // Apple defines accessibilityHint as describing the RESULT OF
    // PERFORMING AN ACTION, and Android's author-supplied hint IS the
    // action's label (TalkBack speaks it as "double tap to <label>").
    // Maps to .accessibilityHint (AXHelp on macOS), the click action's
    // label on Compose, GTK's DESCRIPTION accessible property, and
    // AutomationProperties.HelpText.
    //
    // ACTIVATION KINDS ONLY (button, checkbox, select, radio; the root
    // rejects it elsewhere). A hint answers "what does activating this
    // do", so it needs something to activate: on Android it rides an
    // ACTION and has no target without one, and Apple's own guidance
    // scopes it to actions too. Authored text should be a VERB PHRASE
    // ("save the draft"): Apple speaks it as written and forbids naming
    // the gesture, while TalkBack prefixes "double tap to", so only the
    // verb phrase reads correctly on both.
    ("a11y_hint", 14, PropKind::Str),
    // WHICH CLIP REPRESENTATIONS THIS WIDGET ACCEPTS: a space-separated
    // ACCEPT LIST — the closed kinds by name (`text`, `html`, `image`,
    // `files`) and any number of custom format ids, which are open by
    // nature and so cannot be a mask. `"text html dev.kaya/note"` is a
    // whole declaration. Per-widget and not app-global, because whether
    // Paste should be live is the INTERSECTION of what the clipboard
    // offers and what the focused target takes: a search field wants
    // plain text, a rich editor also wants images. Every platform asks
    // exactly this of the focused target — canPerformAction on Apple,
    // and Android's setOnReceiveContentListener takes the accepted MIME
    // types as an argument ON THE VIEW.
    //
    // It does three jobs from one declaration: it drives whether the
    // standard Paste command is enabled while this widget is focused,
    // it filters what can ever reach the widget's paste hook, and on
    // Android it IS the native registration. Text widgets default to
    // text alone.
    //
    // A STRING AND NOT A MASK, which the first cut had: a mask can name
    // the four closed kinds and NOTHING ELSE, and a custom format that
    // can be written but never accepted is not an escape hatch at all —
    // the whole point of one is an app round-tripping its own data. A
    // custom id reaches every platform's own registry verbatim (a UTI on
    // Apple, RegisterClipboardFormat on Windows, a target atom on X11 and
    // Wayland, a MIME type on Android), which is kaya's narrow promise
    // here. The id's grammar is MIME-SHAPED — a slash, lowercase, no
    // whitespace — validated at apply: GDK's serving path interns the
    // requested type as a mime type, so a slashless id would be
    // advertised and never served on GTK, and the same path lowercases
    // (docs/clipboard-plan.md §5b finding 4). read_clipboard takes the
    // same string for the same reason.
        ("accepts", 15, PropKind::Str),
    // SEMANTIC EMPHASIS, the styling pass's role tier (docs/
    // styling-plan.md D4): what this widget MEANS, never how it looks —
    // destructive and prominent on buttons, heading on labels. A closed
    // enum for the same reason align is one, and value-dependent
    // kind-legality (which VARIANT fits which kind) is the root's check,
    // not a type: the prop is one wire slot, the variants divide it.
    // The comparative survey's sharpest finding sits behind this row:
    // Qt and SWT both broke their styling ceilings because they shipped
    // colors WITHOUT semantics ("red text for potentially destructive
    // push buttons" is Qt's own sentence for what a palette cannot say),
    // so the role tier ships WITH the brand tier, not after it.
    ("role", 16, PropKind::Enum("role")),
    // A CONTAINER'S OWN PADDING, the window inset one level down
    // (docs/styling-plan.md D3): space between a container's bounds and
    // its children, in DIP, uniform on all four sides like the window's.
    // LAYOUT, not appearance — it joins grow/spacing/align, carried by
    // the same kinds spacing is (a leaf has no children to hold away
    // from its edge). Born from the first full-bleed app: the editor's
    // Inset(0) window put the BUFFER on the window edge as designed and
    // took the status row and the find bar with it, and no prop could
    // give the chrome rows their margin back (maintainer, 2026-08-12).
    ("inset", 17, PropKind::F64),
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
    // How this window presents its sections (DESIGN.md, Sections).
    // ADVISORY, the width/height precedent: honored where the platform
    // has the idiom, resolved to the nearest thing otherwise, ignored
    // on the phones where physics decides (bottom bar regardless).
    // Scoped to the window because the GROUP is the unit — no platform
    // mixes per-section presentations. `auto` (the default) resolves
    // to each platform's dominant sections idiom.
    ("sections_presentation", 5, PropKind::Enum("sections_presentation")),
    // How this window presents its ENTRY STACK (DESIGN.md, Adaptive
    // list-detail). False (the default): the stack is serial — one
    // entry visible, which is what navigation has always done. True:
    // on a REGULAR window the base root takes the leading pane and the
    // top of the stack the trailing one; on a COMPACT one the
    // behavior is unchanged, because the compact case IS the default.
    // A window prop, not an entry prop: the stack is per-window, and
    // "how does this surface present its stack" is the window's
    // question. Adaptive by construction — there is no prop for WHICH
    // way it presents, since that is the size class's answer, not the
    // app's.
    ("list_detail", 6, PropKind::Bool),
    // WHETHER THIS SURFACE HOLDS UNSAVED WORK (docs/dirty-plan.md D1).
    // The app declares STATE; the backend spells the chrome, and the
    // spellings genuinely differ — macOS puts the whole signal in the
    // close button's dot (measured: 88 backing pixels change and the
    // title string does not), Windows composes a leading `*` into the
    // rendered caption, GTK draws a bullet beside the header-bar title,
    // and the phones show nothing at all because they have no chrome to
    // show it in (D4: the prop still applies and reads back there —
    // their unsaved-work affordances are FLOW, which kaya spells
    // through veto_close and navigation).
    //
    // A BOOLEAN AND NOT A TITLE TEMPLATE, which is Qt's design and the
    // named rejection: `setWindowModified` requires the app's own title
    // to carry a `[*]` placeholder, so the mechanism leaks into
    // app-facing text, the constraint lives on a STRING no type system
    // sees (Qt's own answer is a runtime warning that fires only when
    // the window is dirty AND the platform has no native support), and
    // kaya's scene titles are compared byte-for-byte across platforms —
    // the declared string must stay identical everywhere while the
    // chrome diverges.
    //
    // IT ARMS NOTHING (D3). "Unsaved changes, close anyway?" is already
    // expressible from veto_close plus the dialog machinery, apps
    // legitimately differ on what it should do, and macOS attaches no
    // behavior of its own: measured, a real Cmd+W on an edited window
    // calls windowShouldClose exactly once and closes, with no sheet and
    // no alert. One attribute, one meaning: show the platform's
    // unsaved-work affordance.
    ("dirty", 7, PropKind::Bool),
    // THE WINDOW CONTENT INSET, in layout units — LAYOUT, not appearance
    // (ratified 2026-08-12, docs/styling-plan.md D3): the space kaya's
    // interpreters put around the mounted root, which was a hard-coded
    // 16 in every backend until the text editor needed 0 and could not
    // say so (a Sublime-shaped buffer, a canvas, a photo view — full
    // bleed was inexpressible). Defaults to 16, so no existing scene
    // moves. It is KAYA'S OWN padding, applied inside the root, so 0 is
    // honored unconditionally on every platform; what it does NOT
    // remove is a platform's safe area (notch, home indicator) — those
    // regions were never kaya's inset, and content extends to the
    // safe-area edge, not past it.
    ("inset", 8, PropKind::F64),
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

/// Section properties: the third typed surface table (the ENTRY_PROPS
/// stance — spec facts with typed setters, never applicability
/// checks). `title` labels the switcher item on every platform;
/// `icon` rides the blob channel (the image-source precedent) — a
/// tab bar without icons is not the platform's real thing, so the
/// slot is day-one even though desktop switchers may not render it.
pub const SECTION_PROPS: &[(&'static str, u32, PropKind)] = &[
    ("title", 1, PropKind::Str),
    ("icon", 2, PropKind::Blob),
    // THE SEMANTIC ICON NAME (docs/styling-plan.md D6; DESIGN.md,
    // "Icons want names, not bytes"): a closed vocabulary each backend
    // maps to its own symbol set, beside — never instead of — the Blob
    // above, which stays for genuinely app-specific art. A tab bar
    // wants `home`, and the glyph that means home is a house on Apple,
    // a different house on Material, and a third on Adwaita; no single
    // asset is right on all three, and the platform sets metric-match
    // the text beside them while a blob cannot.
    ("symbol", 3, PropKind::Enum("symbol")),
];

/// Menu-item properties: the fifth typed surface table (the
/// SECTION_PROPS stance — spec facts with typed setters, never
/// applicability checks; DESIGN.md, Menus). `label` and `enabled` apply
/// to every kind but `separator`; `checked` is toggle-only, `value`
/// radio-group-only, `primary`/`shortcut` action-only — the scene core
/// enforces the kind scoping, keeping this table a flat spec fact. The
/// signal-bindable slots are `label`, `enabled`, `checked`, and
/// `value`; `icon`, `primary`, and `shortcut` are const-only (enforced
/// at the root). `value` rides F64 like every numeric slot (integral,
/// 0-based option index, domain-checked at the root); `shortcut` is a
/// normalized spelling the core validates but never rewrites.
pub const MENU_PROPS: &[(&'static str, u32, PropKind)] = &[
    ("label", 1, PropKind::Str),
    ("enabled", 2, PropKind::Bool),
    ("checked", 3, PropKind::Bool),
    ("value", 4, PropKind::F64),
    ("icon", 5, PropKind::Blob),
    ("primary", 6, PropKind::Bool),
    ("shortcut", 7, PropKind::Str),
    ("role", 8, PropKind::Str),
    // The semantic icon name (docs/styling-plan.md D6) — const-only,
    // like `icon` beside it. NOT id 6: these ids are wire facts and are
    // append-only, so a new prop takes the next free number rather than
    // renumbering `primary` out from under every generated surface.
    ("symbol", 9, PropKind::Enum("symbol")),
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

/// The layout of `undone`/`redone`'s one flat `delta` list, read as
/// four runs in this order. It lives here, as a fingerprinted string,
/// for the reason the record's own fields do: a reader with the wrong
/// SHAPE decodes garbage SILENTLY — the counts still parse, the values
/// are still values, and only the meanings slide. Every other part of
/// the vocabulary is hashed, so a binding built against an older
/// revision refuses to load; a run layout described only in a doc
/// comment was the one part of the wire that could change under a
/// binding without the fingerprint moving.
///
/// Keep it in step with the `undone` record's doc, which is the prose
/// version of the same sentence. Changing a run's shape here is what
/// moves the spec hash (2026-08-06, when `texts` became arity-first so
/// a stamped copy's field could be named at all).
pub const UNDO_DELTA_RUNS: &str = "\
    signals: pairs(i64 signal_id, value); \
    texts: groups(i64 size, i64 id, i64 path_len, path_len key values, str text); \
    entries: groups(i64 size, i64 collection, i64 flags, i64 variant, \
    i64 path_len, path_len key values, key, record fields); \
    orders: groups(i64 size, i64 collection, i64 path_len, path_len key values, keys)";

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
    eat(b"menu_props");
    for (name, id, kind) in MENU_PROPS {
        eat(name.as_bytes());
        eat(&id.to_le_bytes());
        eat(format!("{kind:?}").as_bytes());
    }
    // The one part of the vocabulary that is a LAYOUT rather than a
    // field: the undo payload's runs. Hashed for the same reason the
    // fields are — a binding that reads the old shape out of new bytes
    // gets values of the right types in the wrong places, which no
    // assertion downstream can catch.
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
                  (scratchpad/ranges-units.md §3: an out-of-range \
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
                  them against (scratchpad/ranges-units.md §7). UTF-16 code \
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
    ],
    enums: &[
        EnumSpec {
            name: "value",
            variants: &[("bool", 1), ("i64", 2), ("f64", 3), ("str", 4), ("blob", 5)],
        },
        EnumSpec {
            // WHAT A CLIP CAN BE OFFERED AS. Closed on purpose
            // (docs/clipboard-plan.md §0): the platform lowerings are
            // real work only kaya can absorb — CF_HTML's mandatory
            // offset header, Android's content:// URI for an image,
            // CF_HDROP's DROPFILES struct — and an open MIME map would
            // push every one of them onto guest authors in eight
            // languages. `custom` is the escape hatch, passed through
            // opaquely under an app-chosen id: it round-trips within
            // an app and kaya does nothing clever with it.
            //
            // The VALUES double as bit positions: a copy says which
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
                ("columns", 11),
                ("a11y_id", 12),
                ("a11y_label", 13),
                ("a11y_hint", 14),
                ("accepts", 15),
                ("role", 16),
                ("inset", 17),
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
                ("list_detail", 6),
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
            // The presentation hint's closed set (DESIGN.md, Sections):
            // auto = the platform's dominant sections idiom, bar = the
            // horizontal spelling, sidebar = the leading-edge list.
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
            // What kaya_open_picked opens a handle for. Three modes
            // cover every platform: Android takes them as the mode
            // string of openFileDescriptor, WinUI as FileAccessMode,
            // iOS and the desktops as ordinary open flags. Writability
            // is DISCOVERABLE but not REQUESTABLE — no open picker on
            // any platform takes an access mode — so the open is
            // fallible in ways the pick is not.
            name: "file_mode",
            variants: &[("read", 0), ("write", 1), ("read_write", 2)],
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
            name: "role",
            variants: &[
                ("destructive", 1),
                ("prominent", 2),
                ("heading", 3),
            ],
        },
        EnumSpec {
            // THE SEMANTIC ICON VOCABULARY (docs/styling-plan.md D6;
            // DESIGN.md, "Icons want names, not bytes"). Closed and
            // SMALL on purpose, the `role` trick one tier over: an app
            // names a CONCEPT and each backend draws its own platform's
            // glyph for it, because the platforms draw the same concept
            // differently and their symbol sets metric-match the text
            // beside them. Apple maintains exactly this shape and keeps
            // it to fifteen entries
            // (CoreGlyphs' semantic_to_descriptive_name.strings).
            //
            // THE IDS ARE APPEND-ONLY, FOREVER. They are wire values in
            // eight generated bindings and four backends' lowering
            // tables; a renumber would silently redraw every shipped
            // app's menus. A new concept takes 21.
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
        AlertId, AlertSpec, CollectionId, CommandKind, MenuItemId, MenuItemKind, MenuProp, Prop,
        PropValue, SignalId, TemplateNodeId, TextRange, TxOp, Value, ValueType, WidgetId,
        WidgetKind, WindowId,
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
            ]
        );
        // THE SAME TABLE SHAPE AS THE TWO ABOVE, and it was not always:
        // this pin used to be a list of indexed asserts, which pinned
        // the first fourteen occurrences and said nothing at all about
        // a fifteenth. Two new clipboard occurrences passed it without
        // touching it. A guard that cannot fail for the case it exists
        // for is worse than none, so it compares the WHOLE list.
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
            ]
        );
    }

    /// PROPS and the "prop" enum stay in lockstep: same names, same
    /// A BACKEND MAY ONLY UNWRAP A TAG THE CORE PROMISES TO SET.
    ///
    /// The sibling test in scene.rs holds the two core paths in
    /// agreement with each other, which is not the same as holding them
    /// in agreement with the BACKENDS: flip `carries_tag` to false for a
    /// kind and both paths would still agree, on None, while
    /// `tag.expect("selects carry a tag")` aborts the process on GTK and
    /// WinUI. That is the failure D1 actually shipped, one layer down,
    /// and it is invisible from mac — gtk.rs is cfg'd out here, so no
    /// build a mac session runs ever compiles the line.
    ///
    /// `include_str!` reads the text regardless of cfg, so this runs on
    /// every platform, in rung 1, in the suite every lane already runs
    /// (CLAUDE.md: put the wall where someone walks into it). Each
    /// `expect` sentence names its kind in plain words, which is what
    /// makes the pairing readable rather than a comment nobody updates.
    #[test]
    fn backends_only_unwrap_tags_the_core_sets() {
        let sources: &[(&str, &str)] = &[
            ("gtk.rs", include_str!("gtk.rs")),
            ("winui/mod.rs", include_str!("winui/mod.rs")),
        ];
        // "textareas carry a tag" -> Textarea. The sentence is the
        // backend author's own, so the match is on the kind's name
        // rather than on a list this test would have to carry.
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
                // "entries carry a tag", "radio groups carry a tag".
                // Match the leading noun against each kind's spellings
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
        // ANTI-VACUITY. A pairing that finds nothing passes for the
        // wrong reason, and this one reads source text through a
        // substring — exactly the shape that rots into "always green"
        // when a backend rewords its expects (docs/traps.md).
        assert!(
            seen >= 6,
            "kaya: found only {seen} tag `expect`s across the two backends that \
             have them — this pairing has stopped seeing the lines it exists to \
             check, so it can no longer fail"
        );
    }

    /// `WidgetKind::ALL` IS THE SPEC'S KIND LIST, one entry per variant.
    /// The sweeps that must not miss a kind walk ALL rather than repeat
    /// a list — the live-vs-stamped tag agreement is the first of them
    /// (scene.rs, `a_stamped_copy_is_tagged_exactly_where_a_live_one_is`)
    /// — so a kind added to the spec and NOT added to ALL would join the
    /// wire vocabulary while silently sitting outside every one of them.
    /// The spec is the root (invariant 7); this is the line that makes
    /// ALL follow it instead of drifting behind it.
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
                    ("wprop", "title") => wire::WPROP_TITLE,
                    ("wprop", "width") => wire::WPROP_WIDTH,
                    ("wprop", "height") => wire::WPROP_HEIGHT,
                    ("wprop", "veto_close") => wire::WPROP_VETO_CLOSE,
                    ("wprop", "list_detail") => wire::WPROP_LIST_DETAIL,
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
                    ("clip", "text") => wire::CLIP_TEXT,
                    ("clip", "html") => wire::CLIP_HTML,
                    ("clip", "image") => wire::CLIP_IMAGE,
                    ("clip", "files") => wire::CLIP_FILES,
                    ("clip", "custom") => wire::CLIP_CUSTOM,
                    ("role", "destructive") => wire::ROLE_DESTRUCTIVE,
                    ("role", "prominent") => wire::ROLE_PROMINENT,
                    ("role", "heading") => wire::ROLE_HEADING,
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
                    other => panic!("unpinned enum variant {other:?}"),
                };
                assert_eq!(*value, expected, "{}::{}", e.name, name);
            }
        }
    }

    /// wire::SYMBOLS is a SECOND spelling of the symbol vocabulary —
    /// the (id, name) table the root's value wall and every diagnostic
    /// print from. enums_match_wire pins the VALUES; nothing pinned the
    /// NAMES, and a drifted name there is the worst shape of this bug:
    /// the wall still fires, but its sentence names a concept the app
    /// never wrote and the reader chases the wrong slot.
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
        // The wall's own domain, from both ends: nothing outside the
        // table resolves, including the off-by-one neighbours and the
        // negative a signed wire slot can carry.
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
