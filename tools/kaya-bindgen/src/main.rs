//! kaya-bindgen: emit each language's vocabulary file from the protocol
//! spec (kaya::spec::SPEC).
//!
//! Usage: kaya-bindgen <repo-root> [--check]; --check regenerates into
//! memory and fails if the checked-in files are stale, touching nothing.

use std::fmt::Write as _;

use kaya::spec::{Field, ProtocolSpec, Record, SPEC};

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

    let outputs: Vec<(&str, String)> = vec![
        ("bindings/python/kaya/wire.py", python::emit(&SPEC)),
        ("bindings/c/kaya_wire.h", c::emit(&SPEC)),
        ("bindings/go/kaya_wire.go", go::emit(&SPEC)),
        ("bindings/csharp/KayaWire.cs", csharp::emit(&SPEC)),
        ("bindings/ocaml/kaya_wire.ml", ocaml::emit(&SPEC)),
        ("bindings/haskell/KayaWire.hs", haskell::emit(&SPEC)),
        ("bindings/java/dev/kaya/KayaWire.java", java::emit(&SPEC)),
        ("bindings/swift/KayaWire.swift", swift::emit(&SPEC)),
        ("bindings/js/kaya/wire.ts", js::emit(&SPEC)),
    ];

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
        "icon" | "symbol" | "primary" | "shortcut" | "role" => false,
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

pub(crate) fn payload_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| r.payload.is_some())
        .map(|r| r.name)
        .collect()
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

pub(crate) fn record_params(rec: &Record) -> Vec<&'static Field> {
    rec.fields.iter().filter(|f| !is_padding(f)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

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

