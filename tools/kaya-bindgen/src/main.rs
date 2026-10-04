//! kaya-bindgen: emit each language's vocabulary file from the protocol
//! spec (kaya::spec::SPEC).
//!
//! Usage: kaya-bindgen <repo-root> [--check]; --check regenerates into
//! memory and fails if the checked-in files are stale, touching nothing.

use std::fmt::Write as _;

use kaya::spec::{Field, FieldTy, ProtocolSpec, Record, SPEC};

mod c;
mod csharp;
mod go;
mod haskell;
mod java;
mod js;
mod ocaml;
mod python;
mod swift;

fn main() {
    let mut args = std::env::args().skip(1);
    let root = args.next().expect("usage: kaya-bindgen <repo-root> [--check]");
    let check = args.next().as_deref() == Some("--check");

    // csharp is absent: its emitter escapes keywords with @.
    validate_identifiers(&SPEC, "python", python::RESERVED);
    validate_identifiers(&SPEC, "c", c::RESERVED);
    validate_identifiers(&SPEC, "go", go::RESERVED);
    validate_identifiers(&SPEC, "ocaml", ocaml::RESERVED);
    validate_identifiers(&SPEC, "haskell", haskell::RESERVED);
    validate_identifiers(&SPEC, "java", java::RESERVED);
    validate_identifiers(&SPEC, "swift", swift::RESERVED);
    validate_identifiers(&SPEC, "js", js::RESERVED);

    let outputs = generate_all(&SPEC);

    every_code_answer_is_decoded(&SPEC, &outputs);
    every_value_answer_is_decoded(&SPEC, &outputs);
    let bad = occurrence_decode_refusals(&SPEC, &outputs);
    assert!(bad.is_empty(), "kaya-bindgen: {}", bad.join("; "));

    let mut stale = false;
    for (rel, content) in &outputs {
        let path = std::path::Path::new(&root).join(rel);
        if check {
            let on_disk = std::fs::read_to_string(&path).unwrap_or_default();
            if on_disk != *content {
                eprintln!("{rel} is stale; regenerate with kaya-bindgen");
                stale = true;
            }
        } else {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, content).unwrap();
            println!("wrote {rel}");
        }
    }
    if stale {
        std::process::exit(1);
    }
}

/// The one line every code-answer decode arm carries, in all eight
/// languages' comment syntax stripped to its text. The arms are emitted
/// from a DERIVED family, so counting the mark counts the arms.
pub(crate) const CODE_ANSWER_MARK: &str = "A request's one answer: id + the u32 code.";

/// The value-answer arm's comment, counted like [`CODE_ANSWER_MARK`].
pub(crate) const VALUE_ANSWER_MARK: &str = "An answer carrying one value: id + the Value.";

/// EVERY CODE-ANSWER RECORD IS DECODED BY EVERY BINDING, checked on the
/// path nobody can avoid: this runs on a regeneration AND on `--check`,
/// and build.rs forces a regeneration the moment this generator moves.
///
/// The failure it exists to refuse is measured, not hypothetical
/// (2026-09-07): `notification_result` is byte-for-byte `alert_result`
/// — a u64 request id, a u32 code, `reserved` — and all eight decoders
/// named the alert's arm BY NAME, so the new record fell through to the
/// click tail, which took the OUTCOME for a key-path length: dropped
/// silently when it was 0 (`activated`), read one byte past the record
/// when it was 1 (`refused`). Nothing else could see it — the wire
/// round-trips, every gate passes, and the guest just never learns the
/// answer. A by-name arm coming back leaves the mark short here.
fn every_code_answer_is_decoded(spec: &ProtocolSpec, outputs: &[(&str, String)]) {
    let family = code_answer_occurrence_names(spec);
    let mut bad = Vec::new();
    for (rel, content) in outputs {
        // The C floor hands the record out whole; it has no dispatching
        // decoder to carry an arm.
        if rel.ends_with(".h") {
            continue;
        }
        let arms = content.matches(CODE_ANSWER_MARK).count();
        println!("kaya-bindgen: {rel}: {arms} code-answer decode arms");
        if arms != family.len() {
            bad.push(format!(
                "{rel} decodes {arms} of the {} code-answer occurrences \
                 ({}) — a record whose whole body is a request id and a u32 \
                 code is read by the CLICK tail otherwise, which takes that \
                 code for a key-path length. The arm is emitted from \
                 code_answer_occurrence_names; anything naming one record is \
                 how this broke before",
                family.len(),
                family.join(", ")
            ));
        }
    }
    assert!(bad.is_empty(), "kaya-bindgen: {}", bad.join("; "));
}

/// EVERY VALUE-ANSWER RECORD IS DECODED BY EVERY BINDING, the code-answer
/// rule one family over: `notification_replied` is a request id and one
/// Str, and a decoder with no arm for it hands it to the click tail, which
/// takes the value's TYPE word for a key-path length
/// (docs/notification-reply-plan.md).
fn every_value_answer_is_decoded(spec: &ProtocolSpec, outputs: &[(&str, String)]) {
    let family = value_answer_occurrence_names(spec);
    let mut bad = Vec::new();
    for (rel, content) in outputs {
        if rel.ends_with(".h") {
            continue;
        }
        let arms = content.matches(VALUE_ANSWER_MARK).count();
        println!("kaya-bindgen: {rel}: {arms} value-answer decode arms");
        if arms != family.len() {
            bad.push(format!(
                "{rel} decodes {arms} of the {} value-answer occurrences ({}) — a record \
                 whose whole body is a request id and one Value is read by the CLICK tail \
                 otherwise; the arm is emitted from value_answer_occurrence_names",
                family.len(),
                family.join(", ")
            ));
        }
    }
    assert!(bad.is_empty(), "kaya-bindgen: {}", bad.join("; "));
}

/// EVERY OCCURRENCE RECORD DECODES AS THE SHAPE IT HAS, checked where
/// the code- and value-answer rules are. A record with a key path must
/// carry it where the click tag reads one (a u64 id, then `path_len`);
/// every record without one falls into a derived family, the flat one
/// last; and every binding carries one flat arm per flat record. The
/// failure refused is measured (2026-09-30): player_changed,
/// player_tracks and session_action fell to the click tail in all eight
/// decoders, which took `state`, `audio_selected` and `reserved` for a
/// key-path length.
fn occurrence_decode_refusals(spec: &ProtocolSpec, outputs: &[(&str, String)]) -> Vec<String> {
    let mut bad = Vec::new();
    for r in spec.occurrence {
        if let Some(at) = r.fields.iter().position(|f| f.name == "path_len") {
            if at != 1 || !matches!(r.fields[0].ty, kaya::spec::FieldTy::U64) {
                bad.push(format!(
                    "occurrence {} carries `path_len` as field {at} after a {:?}, where the \
                     click tag reads a u64 id and then the key-path length",
                    r.name, r.fields[0].ty
                ));
            }
        }
        if matches!(r.fields.first().map(|f| f.ty), Some(kaya::spec::FieldTy::VariantSchemas))
            || (flat_occurrence_names(spec).contains(&r.name)
                && r.fields.iter().any(|f| matches!(f.ty, kaya::spec::FieldTy::VariantSchemas)))
        {
            bad.push(format!("occurrence {} is flat and carries variant schemas, which no flat arm reads", r.name));
        }
    }
    let family = flat_occurrence_names(spec);
    for (rel, content) in outputs {
        if rel.ends_with(".h") {
            continue;
        }
        let arms = content.matches(FLAT_MARK).count();
        println!("kaya-bindgen: {rel}: {arms} flat decode arms");
        if arms != family.len() {
            bad.push(format!(
                "{rel} decodes {arms} of the {} flat occurrences ({}) — a record with no key \
                 path is read by the CLICK tail otherwise; the arm is emitted from \
                 flat_occurrence_names",
                family.len(),
                family.join(", ")
            ));
        }
    }
    bad
}

fn generate_all(spec: &ProtocolSpec) -> Vec<(&'static str, String)> {
    vec![
        ("bindings/python/kaya/wire.py", python::emit(spec)),
        ("bindings/c/kaya_wire.h", c::emit(spec)),
        ("bindings/go/kaya_wire.go", go::emit(spec)),
        ("bindings/csharp/KayaWire.cs", csharp::emit(spec)),
        ("bindings/ocaml/kaya_wire.ml", ocaml::emit(spec)),
        ("bindings/haskell/KayaWire.hs", haskell::emit(spec)),
        ("bindings/java/dev/kaya/KayaWire.java", java::emit(spec)),
        ("bindings/swift/KayaWire.swift", swift::emit(spec)),
        ("bindings/js/kaya/wire.ts", js::emit(spec)),
    ]
}

/// Shared emitter helpers.
pub(crate) struct Ctx {
    pub out: String,
}

impl Ctx {
    pub fn line(&mut self, s: &str) {
        writeln!(self.out, "{s}").unwrap();
    }
}

fn validate_identifiers(spec: &ProtocolSpec, lang: &str, reserved: &[&str]) {
    let mut names: Vec<&str> = Vec::new();
    for records in [spec.tx, spec.apply, spec.occurrence] {
        for r in records {
            names.push(r.name);
            names.extend(r.fields.iter().map(|f| f.name));
        }
    }
    names.extend(spec.enums.iter().map(|e| e.name));
    // Prop names become setter parameter names in every binding.
    names.extend(kaya::spec::PROPS.iter().map(|(name, _, _)| *name));
    for name in names {
        assert!(
            !reserved.contains(&name),
            "spec identifier {name:?} collides with a reserved name in {lang}; \
             rename it in kaya::spec"
        );
    }
}

/// The property enum's variants.
pub(crate) use kaya::spec::PropKind;

/// What a Date or Time setter's components MEAN, said in the generated
/// doc comment: every binding's parameters are bare integers, so the
/// packing is stated where a reader of the setter will meet it.
pub(crate) fn date_note(kind: &PropKind) -> &'static str {
    match kind {
        PropKind::Date => " A civil date, packed YYYYMMDD on the wire.",
        PropKind::Time => " A civil time, packed HHMM on the wire.",
        PropKind::Color => " An sRGB colour, packed 0xRRGGBBAA on the wire.",
        PropKind::Aspect => " A width:height ratio, packed width << 32 | height on the wire, each a signed 32-bit integer.",
        _ => "",
    }
}

/// The protocol fingerprint, baked into every generated file.
pub(crate) fn spec_hash() -> u64 {
    kaya::spec::hash()
}

/// Properties with their value kinds, driving typed setter generation.
pub(crate) fn prop_variants(_spec: &ProtocolSpec) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::PROPS
}

/// Window properties, driving the typed window setters. Element sources
/// are rejected by the wire, so emitters write const + signal duos.
pub(crate) fn window_prop_variants(
    _spec: &ProtocolSpec,
) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::WINDOW_PROPS
}

/// Navigation-entry properties, their own table rather than WINDOW_PROPS
/// with applicability checks (DESIGN.md, Navigation).
pub(crate) fn entry_prop_variants(
    _spec: &ProtocolSpec,
) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::ENTRY_PROPS
}

/// Sheet properties (docs/sheet-plan.md §3).
pub(crate) fn sheet_prop_variants(
    _spec: &ProtocolSpec,
) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::SHEET_PROPS
}

/// Section properties (DESIGN.md, Sections).
pub(crate) fn section_prop_variants(
    _spec: &ProtocolSpec,
) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::SECTION_PROPS
}

/// Menu-item properties (DESIGN.md, Menus). NOT plain duos: only the
/// menu_prop_bindable ones get a signal binder.
pub(crate) fn menu_prop_variants(
    _spec: &ProtocolSpec,
) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::MENU_PROPS
}

/// Which menu props accept SOURCE_SIGNAL, in lockstep with scene.rs's
/// is_bindable_menu_prop.
pub(crate) fn menu_prop_bindable(prop: &str) -> bool {
    match prop {
        "label" | "enabled" | "checked" | "value" => true,
        "icon" | "symbol" | "primary" | "shortcut" | "role" | "swipe" => false,
        other => panic!(
            "menu prop {other:?}: declare its signal bindability here, in \
             lockstep with scene.rs is_bindable_menu_prop"
        ),
    }
}

/// The shortcut spelling floor every generated canonicalizer transcribes
/// (DESIGN.md, Menus). This tier owns SPELLING only; `escape` is
/// deliberately IN the set and the CORE rejects it.
// The modifier list is baked into every emitter's control flow, so it is
// test-only from rustc's point of view — hence the cfg_attr.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) const SHORTCUT_MODIFIERS: &[&str] = &["primary", "shift", "alt"];
pub(crate) const SHORTCUT_NAMED_KEYS: &[&str] = &[
    "enter", "escape", "delete", "left", "right", "up", "down", "f1", "f2", "f3", "f4", "f5",
    "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    // Each names the UNSHIFTED US position, so there is no `plus` key
    // (DESIGN.md, Menus).
    "comma", "period", "slash", "backslash", "minus", "equal", "leftbracket", "rightbracket",
];

/// The normative canonicalizer every emitter transcribes, and the test
/// table below is the shared vector set. It does NOT reject escape,
/// shift-only or bare alphanumerics, or the reserved floor: that is root
/// policy, validated by the core on the canonical form.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn canonicalize_shortcut_reference(spelling: &str) -> Result<String, String> {
    if spelling.is_empty() {
        return Err("kaya: shortcut is empty".to_string());
    }
    if spelling.chars().any(|ch| " \t\n\x0b\x0c\r".contains(ch)) {
        return Err(format!("kaya: shortcut \"{spelling}\" contains whitespace"));
    }
    let lower = spelling.to_lowercase();
    let parts: Vec<&str> = lower.split('+').collect();
    if parts.iter().any(|p| p.is_empty()) {
        return Err(format!("kaya: shortcut \"{spelling}\" has an empty token"));
    }
    let (mods, key) = parts.split_at(parts.len() - 1);
    let key = key[0];
    let mut seen: Vec<&str> = Vec::new();
    for &m in mods {
        if !SHORTCUT_MODIFIERS.contains(&m) {
            return Err(format!(
                "kaya: shortcut \"{spelling}\" has an unknown modifier \"{m}\" \
                 (the portable modifiers are primary, shift, alt; aliases like \
                 ctrl, cmd, and option are not accepted)"
            ));
        }
        if seen.contains(&m) {
            return Err(format!(
                "kaya: shortcut \"{spelling}\" repeats modifier \"{m}\""
            ));
        }
        seen.push(m);
    }
    let alnum = key.len() == 1
        && key
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    if !alnum && !SHORTCUT_NAMED_KEYS.contains(&key) {
        return Err(format!(
            "kaya: shortcut \"{spelling}\" key \"{key}\" is outside the floor \
             (one of a-z, 0-9, or the closed named set)"
        ));
    }
    let mut out = String::new();
    for &m in SHORTCUT_MODIFIERS {
        if seen.contains(&m) {
            out.push_str(m);
            out.push('+');
        }
    }
    out.push_str(key);
    Ok(out)
}

/// Occurrence records, split by Record::payload.
pub(crate) fn occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence.iter().map(|r| r.name).collect()
}

/// Surface-lifecycle occurrences: records whose whole body is one u64
/// surface id. DERIVED, never listed by hand — a hand list leaves the 8
/// parsers reading a new one as click-shaped.
pub(crate) fn id_only_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            r.payload.is_none()
                && r.fields.len() == 1
                && matches!(r.fields[0].ty, kaya::spec::FieldTy::U64)
        })
        .map(|r| r.name)
        .collect()
}

/// Surface-pair occurrences: records whose whole body is two u64 surface
/// ids. Parsers yield the SECOND id as the handler key (handlers scope
/// to the section) and the first as the payload.
pub(crate) fn id_pair_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            r.payload.is_none()
                && r.fields.len() == 2
                && r.fields
                    .iter()
                    .all(|f| matches!(f.ty, kaya::spec::FieldTy::U64))
        })
        .map(|r| r.name)
        .collect()
}

/// Occurrences carrying ONE REPRESENTATION: records whose last three
/// fields are `clip` (u32), a reserved u32, and a `value` Values block.
/// DERIVED — a hand list leaves seven decoders taking a new one's clip
/// kind for a key-path length.
fn representation_shaped(rec: &Record) -> bool {
    let n = rec.fields.len();
    n >= 3
        && rec.fields[n - 3].name == "clip"
        && matches!(rec.fields[n - 3].ty, kaya::spec::FieldTy::U32)
        && matches!(rec.fields[n - 2].ty, kaya::spec::FieldTy::U32)
        && rec.fields[n - 1].name == "value"
        && matches!(rec.fields[n - 1].ty, kaya::spec::FieldTy::Values)
}

/// The representation-carrying occurrences that are CLICK-SHAPED.
pub(crate) fn pasted_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| representation_shaped(r) && r.fields.len() > 1 && r.fields[1].name == "path_len")
        .map(|r| r.name)
        .collect()
}

/// The representation-carrying occurrences that answer a REQUEST: no key
/// path, and an empty answer meaning denied, absent, unfocused and
/// nothing-we-accept alike.
pub(crate) fn clip_answer_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            representation_shaped(r) && !(r.fields.len() > 1 && r.fields[1].name == "path_len")
        })
        .map(|r| r.name)
        .collect()
}

/// ONE-SHOT REQUEST ANSWERS: a request id and a u32 CODE, nothing else.
/// `alert_result`'s choice and `notification_result`'s outcome are the
/// same three words on the wire. DERIVED, for `id_only`'s reason one
/// record over: the alert's arm was hand-listed BY NAME, so the day
/// notification_result landed all eight parsers read it as click-shaped
/// — the outcome taken for a key-path length, silently dropped when it
/// was 0 and read one byte past the record when it was 1.
pub(crate) fn code_answer_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            r.payload.is_none()
                && r.fields.len() == 3
                && matches!(r.fields[0].ty, kaya::spec::FieldTy::U64)
                && matches!(r.fields[1].ty, kaya::spec::FieldTy::U32)
                // `path_len` is the click tag, whose u32 counts KEYS.
                && r.fields[1].name != "path_len"
                && r.fields[2].name == "reserved"
        })
        .map(|r| r.name)
        .collect()
}

/// ONE-SHOT ANSWERS CARRYING A VALUE: a request id and one Value, nothing
/// else (`notification_replied`'s text). Derived, for the code answers'
/// reason.
pub(crate) fn value_answer_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            r.payload.is_none()
                && r.fields.len() == 2
                && matches!(r.fields[0].ty, kaya::spec::FieldTy::U64)
                && matches!(r.fields[1].ty, kaya::spec::FieldTy::Value)
        })
        .map(|r| r.name)
        .collect()
}

pub(crate) fn payload_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| r.payload.is_some() && !rich_shaped(r))
        .map(|r| r.name)
        .collect()
}

/// An addressed edit (docs/rich-text-plan.md R1): a click tag with the
/// SOURCE in its reserved u32, the range, the runs in FOURS, then the text.
/// Derived, not named: the generic payload tail would read `start` as a
/// tagged value and die on an unknown value type.
pub(crate) fn rich_edit_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| r.payload.is_some() && rich_shaped(r))
        .map(|r| r.name)
        .collect()
}

/// A toolbar act: the same tag with REMOVED in the reserved slot, the
/// range, and the attribute as a name/value pair.
pub(crate) fn rich_format_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| r.payload.is_none() && r.fields.iter().any(|f| f.name == "attr"))
        .map(|r| r.name)
        .collect()
}

fn rich_shaped(rec: &Record) -> bool {
    let n = rec.fields.len();
    n >= 3
        && rec.fields[n - 1].name == "runs"
        && matches!(rec.fields[n - 1].ty, kaya::spec::FieldTy::Values)
        && rec.fields[n - 3].name == "count"
}

/// THE DROP (docs/dnd-plan.md D1): a click identity tag, then four words
/// — operation, before, anchor_len, clip — the point as two F64 values,
/// the anchor's keys, and the representation in pasted's own layout
/// (`wire::dropped_body`). DERIVED off `anchor_len`, which no other
/// record carries: the generic tail hands the app a drop with NO payload
/// at all, which is what all eight bindings did before the sweep.
pub(crate) fn dropped_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| r.fields.iter().any(|f| f.name == "anchor_len"))
        .map(|r| r.name)
        .collect()
}

/// THE DRAG'S OUTCOME: a click identity tag and one `operation` word
/// after the key path (`wire::drag_ended_body`). Its slot is PAST the
/// path, so the u32-slot family below cannot see it.
pub(crate) fn drag_outcome_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            r.payload.is_none()
                && r.fields.len() == 5
                && r.fields[0].name == "id"
                && r.fields[1].name == "path_len"
                && r.fields[3].name == "operation"
                && !r.fields.iter().any(|f| f.name == "anchor_len")
        })
        .map(|r| r.name)
        .collect()
}

/// Occurrences whose THIRD field — the u32 at offset 20, where the
/// click-tag family writes `reserved` — is a NAMED value the handler
/// needs. The generic tag fallthrough skips that slot, so every parser
/// needs one extra read for these.
pub(crate) fn u32_slot_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            r.fields.len() >= 3
                && matches!(r.fields[2].ty, kaya::spec::FieldTy::U32)
                && r.fields[2].name != "reserved"
                && r.fields[0].name == "id"
                // The rich pair reads its own slot in its own arm.
                && !rich_shaped(r)
                && !r.fields.iter().any(|f| f.name == "attr")
        })
        .map(|r| r.name)
        .collect()
}

/// THE CANVAS ASKS: a click identity tag followed by a run of BARE f64
/// values (docs/canvas-plan.md §3.2.1). `wire::draw_body` writes them
/// with no count in front, so a reader takes values UNTIL THE RECORD
/// ENDS and one arm serves both arities.
pub(crate) fn values_tail_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            r.payload.is_none()
                && r.fields.len() == 4
                && r.fields[0].name == "id"
                && r.fields[1].name == "path_len"
                && r.fields[2].name == "reserved"
                && matches!(r.fields[3].ty, kaya::spec::FieldTy::Values)
        })
        .map(|r| r.name)
        .collect()
}

/// Occurrences carrying an UNDO DELTA: a window, four u32 run lengths,
/// the group's `label`, and one flat `delta` Values tail the runs cut up
/// (docs/undo-plan.md D5, and `wire::undo_body`). DERIVED, and it has to
/// be: the generic tail would take `window` for a widget and the SIGNAL
/// COUNT for a key-path length.
pub(crate) fn undo_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            let n = r.fields.len();
            n >= 2
                && r.fields[n - 2].name == "label"
                && matches!(r.fields[n - 2].ty, kaya::spec::FieldTy::Value)
                && r.fields[n - 1].name == "delta"
                && matches!(r.fields[n - 1].ty, kaya::spec::FieldTy::Values)
        })
        .map(|r| r.name)
        .collect()
}

/// The records every emitter decodes BY NAME in an arm of its own.
const NAMED_DECODE_ARMS: &[&str] = &["file_dialog_result", "link_opened"];

/// FLAT RECORDS: no key path and no payload, in no family above
/// (player_changed, player_tracks, session_action). Every decoder reads
/// their fields IN ORDER from offset 8 into the generic tail: the first
/// field is the id when it is a u64 (else the id is 0) and is not repeated;
/// u32 and u64 read as I64, `reserved` skipped; a Value as itself; a
/// Values block as I64(count) then its values. Without this arm the click
/// tail takes the second field for a key-path length
/// (scratchpad finding, docs/media-plan.md §2).
pub(crate) fn flat_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    let id_only = id_only_occurrence_names(spec);
    let id_pair = id_pair_occurrence_names(spec);
    let code = code_answer_occurrence_names(spec);
    let value = value_answer_occurrence_names(spec);
    let undo = undo_occurrence_names(spec);
    spec.occurrence
        .iter()
        .filter(|r| {
            r.payload.is_none()
                && !r.fields.iter().any(|f| f.name == "path_len")
                && !representation_shaped(r)
                && !NAMED_DECODE_ARMS.contains(&r.name)
                && ![&id_only, &id_pair, &code, &value, &undo].iter().any(|fam| fam.contains(&r.name))
        })
        .map(|r| r.name)
        .collect()
}

/// The flat arm's comment, counted like [`CODE_ANSWER_MARK`].
pub(crate) const FLAT_MARK: &str = "A flat record: its fields in order, into the tail.";

/// Click-shaped occurrences without a payload: {u64 id, u32 path_len,
/// u32 reserved}, then the key path. Needed because the C floor emits
/// one named parser per record.
pub(crate) fn click_shaped_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            r.payload.is_none()
                && r.fields.len() == 3
                && matches!(r.fields[0].ty, kaya::spec::FieldTy::U64)
                && r.fields[1].name == "path_len"
                // The third slot must be PADDING: a record with a real
                // value there is the u32-slot family, and a click-shaped
                // parse would drop it silently.
                && r.fields[2].name == "reserved"
        })
        .map(|r| r.name)
        .collect()
}

/// The only tx field a guest never passes: `reserved` is padding and
/// always encodes 0.
///
/// ONE PREDICATE FOR THE SIGNATURE AND THE BODY — record_params and all
/// 8 emit_packer()s read it, so a field dropped from a signature can
/// never still be emitted by name.
pub(crate) fn is_padding(f: &Field) -> bool {
    f.name == "reserved"
}

/// A tx record's PAYLOAD (spec.rs `payload: Some(PropKind::Str)`) is one
/// trailing Str value after the fields, exactly as wire.rs's TxOp::SetRichText
/// encoder writes it; every emitter takes it as a last `text` parameter
/// (docs/rich-text-plan.md §7 — the first tx records with a payload).
pub(crate) static PAYLOAD_FIELD: Field = Field { name: "text", ty: FieldTy::Value };

pub(crate) fn tx_fields(rec: &Record) -> Vec<&'static Field> {
    let mut out: Vec<&'static Field> = rec.fields.iter().collect();
    if rec.payload.is_some() {
        out.push(&PAYLOAD_FIELD);
    }
    out
}

pub(crate) fn record_params(rec: &Record) -> Vec<&'static Field> {
    tx_fields(rec).into_iter().filter(|f| !is_padding(f)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doctored(name: &str, fields: &'static [Field]) -> ProtocolSpec {
        let occ: Vec<Record> = SPEC
            .occurrence
            .iter()
            .map(|r| if r.name == name { Record { fields, ..*r } } else { *r })
            .collect();
        ProtocolSpec { tx: SPEC.tx, apply: SPEC.apply, occurrence: Box::leak(occ.into_boxed_slice()), enums: SPEC.enums }
    }

    /// The guard's two refusals, each made to fire (counts printed).
    #[test]
    fn occurrence_decode_refusals_fire() {
        let outputs = generate_all(&SPEC);
        let clean = occurrence_decode_refusals(&SPEC, &outputs);
        assert!(clean.is_empty(), "{clean:?}");
        static MOVED: &[Field] = &[
            Field { name: "id", ty: FieldTy::U64 },
            Field { name: "reserved", ty: FieldTy::U32 },
            Field { name: "path_len", ty: FieldTy::U32 },
        ];
        let spec = doctored("button_clicked", MOVED);
        let bad = occurrence_decode_refusals(&spec, &generate_all(&spec));
        println!("path_len moved: {} refusal(s)", bad.len());
        assert!(bad.iter().any(|b| b.contains("button_clicked")), "{bad:?}");
        let mut short = outputs.clone();
        let (_, swift) = short.iter_mut().find(|(rel, _)| rel.ends_with(".swift")).unwrap();
        let before = swift.matches(FLAT_MARK).count();
        *swift = swift.replacen(FLAT_MARK, "cut", 1);
        println!("flat arm cut: {} -> {}", before, swift.matches(FLAT_MARK).count());
        let bad = occurrence_decode_refusals(&SPEC, &short);
        println!("flat arm cut: {} refusal(s)", bad.len());
        assert!(bad.len() == 1 && bad[0].contains("flat occurrences"), "{bad:?}");
    }

    /// The shared vector table for the shortcut canonicalizer. `escape`,
    /// shift-only/bare alphanumerics and the reserved floor are ACCEPTED
    /// on purpose — they canonicalize fine and die at the core.
    #[test]
    fn shortcut_canonicalizer_accepts_and_canonicalizes() {
        let accept: &[(&str, &str)] = &[
            ("primary+s", "primary+s"),
            ("PRIMARY+S", "primary+s"),
            ("Primary+Shift+S", "primary+shift+s"),
            ("shift+primary+s", "primary+shift+s"),
            ("alt+shift+f5", "shift+alt+f5"),
            ("ALT+ENTER", "alt+enter"),
            ("primary+alt+0", "primary+alt+0"),
            ("enter", "enter"),
            ("f12", "f12"),
            ("delete", "delete"),
            ("left", "left"),
            // Recognized here, rejected by the core (policy):
            ("escape", "escape"),
            ("Escape", "escape"),
            ("shift+s", "shift+s"),
            ("q", "q"),
            ("primary+q", "primary+q"),
            ("alt+f4", "alt+f4"),
            ("shift+enter", "shift+enter"),
        ];
        for (input, want) in accept {
            assert_eq!(
                canonicalize_shortcut_reference(input).as_deref(),
                Ok(*want),
                "canonicalize({input:?})"
            );
        }
    }

    #[test]
    fn shortcut_canonicalizer_rejects_bad_spellings() {
        let reject: &[&str] = &[
            "",
            "primary + s",
            " primary+s",
            "primary+s ",
            "primary\t+s",
            "ctrl+s",
            "cmd+s",
            "option+p",
            "control+s",
            "command+s",
            "meta+s",
            "primary+primary+s",
            "primary+shift+shift+s",
            "primary+",
            "+s",
            "primary++s",
            "+",
            "primary+s+k",
            "s+primary",
            "primary",
            "shift+alt",
            "primary+esc",
            "primary+f13",
            "primary+f0",
            "primary+f01",
            "primary+ss",
            "primary+ß",
            "primary-s",
        ];
        for input in reject {
            assert!(
                canonicalize_shortcut_reference(input).is_err(),
                "canonicalize({input:?}) should be rejected"
            );
        }
    }

    /// Walking the whole table triggers menu_prop_bindable's panic for an
    /// undeclared prop in CI rather than at someone's regeneration.
    #[test]
    fn every_menu_prop_declares_bindability() {
        let bindable: Vec<&str> = kaya::spec::MENU_PROPS
            .iter()
            .filter(|(name, _, _)| menu_prop_bindable(name))
            .map(|(name, _, _)| *name)
            .collect();
        assert_eq!(bindable, ["label", "enabled", "checked", "value"]);
    }
}

