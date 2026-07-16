//! kaya-bindgen: emit each language's vocabulary file from the protocol
//! spec (kaya::spec::SPEC — Rust is the root; this tool just walks it).
//!
//! The output is the mechanical layer of a binding: constants, record
//! packers, and the occurrence parser. The runtime layer (ring consumer,
//! loading, threading) is hand-written per language next to the
//! generated file, and any idiomatic surface builds on top — neither is
//! this tool's business.
//!
//! Usage: kaya-bindgen <repo-root> [--check]
//! --check regenerates into memory and fails if the checked-in files
//! are out of date, touching nothing (the gen-header.sh pattern).

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

    // Spec-derived identifiers must not collide with anything an emitter
    // authors (its helper functions) or a target language reserves (its
    // keywords). Checked here, at the root, so a collision is a loud
    // generation failure instead of a runtime surprise in one guest.
    // csharp is absent: its emitter escapes keywords with @ instead
    // (the prop "checked" is a C# keyword), so a collision there is
    // handled, not fatal.
    validate_identifiers(&SPEC, "python", python::RESERVED);
    validate_identifiers(&SPEC, "c", c::RESERVED);
    validate_identifiers(&SPEC, "go", go::RESERVED);
    validate_identifiers(&SPEC, "ocaml", ocaml::RESERVED);
    validate_identifiers(&SPEC, "haskell", haskell::RESERVED);
    validate_identifiers(&SPEC, "java", java::RESERVED);
    validate_identifiers(&SPEC, "swift", swift::RESERVED);

    let outputs: Vec<(&str, String)> = vec![
        ("bindings/python/kaya_wire.py", python::emit(&SPEC)),
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

/// Shared emitter helpers: the spec walk is the same in every language;
/// only the syntax differs.
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
    // Prop names become setter parameter names in every binding
    // ("checked" broke C# before props were validated here).
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
/// assert the loaded core's kaya_spec_hash() agrees before any bytes
/// flow (the stale-artifact guard).
pub(crate) fn spec_hash() -> u64 {
    kaya::spec::hash()
}

/// Properties with their value kinds, driving typed setter generation:
/// set_text takes a string, set_checked a bool, in every language.
/// (The spec pins PROPS to the "prop" enum, so constants and setters
/// cannot drift.)
pub(crate) fn prop_variants(_spec: &ProtocolSpec) -> &'static [(&'static str, u32, PropKind)] {
    kaya::spec::PROPS
}

pub(crate) fn record_params(rec: &Record) -> Vec<&'static Field> {
    rec.fields
        .iter()
        .filter(|f| f.name != "reserved" && f.name != "tag_len" && f.name != "path_len")
        .collect()
}

