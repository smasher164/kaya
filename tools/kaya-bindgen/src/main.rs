//! kaya-bindgen: emit each language's vocabulary file from the protocol
//! spec (kaya::spec::SPEC). Constants, record packers and the occurrence
//! parser only — the runtime layer and the idiomatic surface are
//! hand-written per language beside the generated file.
//!
//! Usage: kaya-bindgen <repo-root> [--check]
//! --check regenerates into memory and fails if the checked-in files
//! are out of date, touching nothing.

use std::fmt::Write as _;

use kaya::spec::{Field, ProtocolSpec, Record, SPEC};

mod c;
mod csharp;
mod go;
mod haskell;
mod java;
mod ocaml;
mod python;
mod swift;

fn main() {
    let mut args = std::env::args().skip(1);
    let root = args.next().expect("usage: kaya-bindgen <repo-root> [--check]");
    let check = args.next().as_deref() == Some("--check");

    // Spec-derived identifiers must not collide with an emitter's own
    // helpers or a target language's keywords. csharp is absent: its
    // emitter escapes keywords with @, so a collision there is handled.
    validate_identifiers(&SPEC, "python", python::RESERVED);
    validate_identifiers(&SPEC, "c", c::RESERVED);
    validate_identifiers(&SPEC, "go", go::RESERVED);
    validate_identifiers(&SPEC, "ocaml", ocaml::RESERVED);
    validate_identifiers(&SPEC, "haskell", haskell::RESERVED);
    validate_identifiers(&SPEC, "java", java::RESERVED);
    validate_identifiers(&SPEC, "swift", swift::RESERVED);

    let outputs: Vec<(&str, String)> = vec![
        ("bindings/python/kaya/wire.py", python::emit(&SPEC)),
        ("bindings/c/kaya_wire.h", c::emit(&SPEC)),
        ("bindings/go/kaya_wire.go", go::emit(&SPEC)),
        ("bindings/csharp/KayaWire.cs", csharp::emit(&SPEC)),
        ("bindings/ocaml/kaya_wire.ml", ocaml::emit(&SPEC)),
        ("bindings/haskell/KayaWire.hs", haskell::emit(&SPEC)),
        ("bindings/java/dev/kaya/KayaWire.java", java::emit(&SPEC)),
        ("bindings/swift/KayaWire.swift", swift::emit(&SPEC)),
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

/// The property enum's variants: every emitter derives its per-prop
/// helper trio (set/bind/bind-element) from this.
pub(crate) use kaya::spec::PropKind;

/// The protocol fingerprint, baked into every generated file; runtimes
/// assert the loaded core's kaya_spec_hash() agrees before any bytes flow.
pub(crate) fn spec_hash() -> u64 {
    kaya::spec::hash()
}

/// Properties with their value kinds, driving typed setter generation:
/// set_text takes a string, set_checked a bool, in every language.
pub(crate) fn prop_variants(_spec: &ProtocolSpec) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::PROPS
}

/// Window properties, driving the typed window setters. Element sources
/// are rejected by the wire, so the emitters write const + signal duos,
/// never trios.
pub(crate) fn window_prop_variants(
    _spec: &ProtocolSpec,
) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::WINDOW_PROPS
}

/// Navigation-entry properties, their own table rather than WINDOW_PROPS
/// with applicability checks (DESIGN.md, Navigation). Const + signal
/// duos like windows.
pub(crate) fn entry_prop_variants(
    _spec: &ProtocolSpec,
) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::ENTRY_PROPS
}

/// Section properties (DESIGN.md, Sections). Const + signal duos; icon
/// rides the blob channel like the image source.
pub(crate) fn section_prop_variants(
    _spec: &ProtocolSpec,
) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::SECTION_PROPS
}

/// Menu-item properties (DESIGN.md, Menus). NOT plain duos: only the
/// menu_prop_bindable ones get a signal binder, and the wire rejects
/// SOURCE_SIGNAL on the rest at the root. The shortcut const setter is
/// the one place the generated canonicalizer is invoked.
pub(crate) fn menu_prop_variants(
    _spec: &ProtocolSpec,
) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::MENU_PROPS
}

/// Which menu props accept SOURCE_SIGNAL. Mirrors scene.rs's
/// is_bindable_menu_prop; the match is exhaustive over today's table, so
/// a NEW menu prop fails generation until it is declared here.
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
/// (DESIGN.md, Menus). f1..f12 are expanded so every binding does flat
/// membership. `escape` is deliberately IN the set: the binding tier
/// canonicalizes it and the CORE rejects it. This tier owns SPELLING
/// only; policy lives at the core.
// The modifier list is baked into every emitter's control flow, so it is
// test-only from rustc's point of view — hence the cfg_attr.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) const SHORTCUT_MODIFIERS: &[&str] = &["primary", "shift", "alt"];
pub(crate) const SHORTCUT_NAMED_KEYS: &[&str] = &[
    "enter", "escape", "delete", "left", "right", "up", "down", "f1", "f2", "f3", "f4", "f5",
    "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    // Named rather than spelled with the character, to keep the wire
    // spelling clear of what the step grammar and menu paths use. Each
    // names the UNSHIFTED US position, so Command-plus is asked for as
    // primary+shift+equal and no `plus` key exists.
    "comma", "period", "slash", "backslash", "minus", "equal", "leftbracket", "rightbracket",
];

/// The normative canonicalizer every emitter transcribes, kept here so
/// the algorithm has ONE statement and the test table below is the
/// shared vector set. Accepts ASCII case variants and any modifier order
/// before the final key; emits lowercase `primary`,`shift`,`alt`,key.
/// Rejects whitespace, empty tokens, repeated modifiers, aliases, and
/// unknown or multiple or missing keys. It does NOT reject escape,
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

/// Occurrence records, split by whether they carry a trailing payload
/// value after the key path — a spec fact (Record::payload).
pub(crate) fn occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence.iter().map(|r| r.name).collect()
}

/// Surface-lifecycle occurrences: records whose whole body is one u64
/// surface id. DERIVED from the record shapes, so a new id-only
/// occurrence reaches all 8 parsers with zero emitter edits; a
/// hand-copied list left them parsing it as click-shaped.
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
/// ids. Derived like id_only. Parsers yield the SECOND id as the handler
/// key (handlers scope to the section) and the first as the payload.
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
/// DERIVED, on the id_only stance: a third one added by hand-copied
/// lists would meet seven decoders that silently take its clip kind for
/// a key-path length.
fn representation_shaped(rec: &Record) -> bool {
    let n = rec.fields.len();
    n >= 3
        && rec.fields[n - 3].name == "clip"
        && matches!(rec.fields[n - 3].ty, kaya::spec::FieldTy::U32)
        && matches!(rec.fields[n - 2].ty, kaya::spec::FieldTy::U32)
        && rec.fields[n - 1].name == "value"
        && matches!(rec.fields[n - 1].ty, kaya::spec::FieldTy::Values)
}

/// The representation-carrying occurrences that are CLICK-SHAPED: an
/// identity tag (id + path_len + reserved, then the key path) with the
/// clip after it.
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

/// Occurrences whose THIRD field — the u32 at offset 20, where the
/// click-tag family writes `reserved` — is a NAMED value the handler
/// needs (today: sort_requested's `column`). The generic tag
/// fallthrough reads {u64 id, u32 path_len} and skips that slot, so
/// every parser needs one extra read for these, DERIVED from the field
/// name rather than listed by hand.
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

/// Occurrences carrying an UNDO DELTA: a window, four u32 run lengths,
/// the group's `label`, and one flat `delta` Values tail the runs cut up
/// (docs/undo-plan.md D5, and `wire::undo_body`).
///
/// DERIVED, and it has to be: the generic tail every parser falls
/// through to reads {u64 id, u32 path_len} and would take `window` for a
/// widget and the SIGNAL COUNT for a key-path length.
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
/// u32 reserved}, then the key path. The 7 generic parsers fall through
/// to the click path via occurrence_names, but the C floor emits one
/// named parser per record, so this list is DERIVED too.
pub(crate) fn click_shaped_occurrence_names(spec: &ProtocolSpec) -> Vec<&'static str> {
    spec.occurrence
        .iter()
        .filter(|r| {
            r.payload.is_none()
                && r.fields.len() == 3
                && matches!(r.fields[0].ty, kaya::spec::FieldTy::U64)
                && r.fields[1].name == "path_len"
                // The third slot must be PADDING: a record carrying a
                // real value there (sort_requested's column) is the
                // u32-slot family, and a click-shaped parse would drop
                // the value silently.
                && r.fields[2].name == "reserved"
        })
        .map(|r| r.name)
        .collect()
}

pub(crate) fn record_params(rec: &Record) -> Vec<&'static Field> {
    rec.fields
        .iter()
        .filter(|f| f.name != "reserved" && f.name != "tag_len" && f.name != "path_len")
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shared vector table for the shortcut canonicalizer: every
    /// per-language negative check draws its cases from here. `escape`,
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

    /// The bindability split covers exactly the spec's menu-prop table.
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

