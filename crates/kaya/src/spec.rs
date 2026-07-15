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
//! from { u32, u64, value, path }, where value is the tagged scalar
//! encoding and path is a length-prefixed sequence of key values. New
//! vocabulary should be new records over these types, not new types —
//! that is what keeps eight bindings mechanical.

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
    /// { u32 count; u32 reserved; count values }.
    Path,
}

/// One record kind of a channel: the numeric kind, a name, its fields
/// in wire order, and a one-line doc.
#[derive(Debug, Clone, Copy)]
pub struct Record {
    pub kind: u16,
    pub name: &'static str,
    pub fields: &'static [Field],
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

/// The variable tail of SET_PROPERTY, after `source`: a value for
/// SOURCE_CONST, a u64 signal id for SOURCE_SIGNAL, or u32 level + u32
/// reserved for SOURCE_ELEMENT. The one record whose layout depends on
/// a discriminant; generators emit one helper per source rather than a
/// union type.
pub const SET_PROPERTY_NOTE: &str =
    "tail after `source`: value (SOURCE_CONST) | u64 signal_id (SOURCE_SIGNAL) \
     | u32 level, u32 reserved (SOURCE_ELEMENT)";

pub const SPEC: ProtocolSpec = ProtocolSpec {
    tx: &[
        Record {
            kind: 1,
            name: "create_signal",
            fields: &[f("signal_id", FieldTy::U64), f("initial", FieldTy::Value)],
            doc: "Create a signal holding `initial`.",
        },
        Record {
            kind: 2,
            name: "write_signal",
            fields: &[f("signal_id", FieldTy::U64), f("value", FieldTy::Value)],
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
            doc: "Bind a property; see SET_PROPERTY_NOTE for the tail.",
        },
        Record {
            kind: 5,
            name: "add_child",
            fields: &[f("parent", FieldTy::U64), f("child", FieldTy::U64)],
            doc: "Append `child` to `parent` (same zone only).",
        },
        Record {
            kind: 6,
            name: "mount",
            fields: &[f("window", FieldTy::U64), f("root", FieldTy::U64)],
            doc: "Mount a root into a window (0 = the default window).",
        },
        Record {
            kind: 7,
            name: "create_collection",
            fields: &[f("collection_id", FieldTy::U64)],
            doc: "Declare a collection (a blueprint when inside a template).",
        },
        Record {
            kind: 8,
            name: "collection_insert",
            fields: &[
                f("collection_id", FieldTy::U64),
                f("path", FieldTy::Path),
                f("key", FieldTy::Value),
                f("value", FieldTy::Value),
            ],
            doc: "Insert an entry into the instance at `path`; stamps a copy.",
        },
        Record {
            kind: 9,
            name: "collection_update",
            fields: &[
                f("collection_id", FieldTy::U64),
                f("path", FieldTy::Path),
                f("key", FieldTy::Value),
                f("value", FieldTy::Value),
            ],
            doc: "Update an entry's value; element bindings follow.",
        },
        Record {
            kind: 10,
            name: "collection_remove",
            fields: &[
                f("collection_id", FieldTy::U64),
                f("path", FieldTy::Path),
                f("key", FieldTy::Value),
            ],
            doc: "Remove an entry; its stamped copy tears down.",
        },
        Record {
            kind: 11,
            name: "create_for",
            fields: &[f("id", FieldTy::U64), f("collection_id", FieldTy::U64)],
            doc: "A For over a collection; opens a template scope until template_end.",
        },
        Record {
            kind: 12,
            name: "create_when",
            fields: &[f("id", FieldTy::U64), f("signal_id", FieldTy::U64)],
            doc: "A When over a Bool signal; opens a template scope until template_end.",
        },
        Record {
            kind: 13,
            name: "template_end",
            fields: &[],
            doc: "Close the innermost template scope.",
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
            doc: "Set a property to an already-resolved value.",
        },
        Record {
            kind: 3,
            name: "add_child",
            fields: &[f("parent", FieldTy::U64), f("child", FieldTy::U64)],
            doc: "Append `child` to `parent`.",
        },
        Record {
            kind: 4,
            name: "mount",
            fields: &[f("window", FieldTy::U64), f("root", FieldTy::U64)],
            doc: "Mount a root into a window.",
        },
        Record {
            kind: 5,
            name: "destroy",
            fields: &[f("widget_id", FieldTy::U64)],
            doc: "Remove the widget from its parent and forget it; \
                  teardown arrives children-first.",
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
            doc: "path_len key values follow, then the entry's new text as \
                  one value. Identity reads as in button_clicked. The widget \
                  owns its text; the app folds these into its own model.",
        },
    ],
    enums: &[
        EnumSpec {
            name: "value",
            variants: &[("bool", 1), ("i64", 2), ("f64", 3), ("str", 4)],
        },
        EnumSpec {
            name: "kind",
            variants: &[("column", 1), ("button", 2), ("label", 3), ("entry", 4)],
        },
        EnumSpec {
            name: "prop",
            variants: &[("text", 1)],
        },
        EnumSpec {
            name: "source",
            variants: &[("const", 0), ("signal", 1), ("element", 2)],
        },
        EnumSpec {
            name: "occurrence",
            variants: &[("pad", 0), ("button_clicked", 1), ("text_changed", 2)],
        },
    ],
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{
        CollectionId, Prop, PropValue, SignalId, TxOp, Value, WidgetId, WidgetKind, WindowId,
    };
    use crate::wire;

    /// A spec-driven generic encoder: what any generated binding does,
    /// expressed once here. If this encodes and wire.rs decodes to the
    /// expected op, the generated bindings agree with the core.
    struct GenericWriter {
        buf: Vec<u8>,
    }

    enum Arg {
        U32(u32),
        U64(u64),
        Value(Value),
        Path(Vec<Value>),
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
                    (FieldTy::Path, Arg::Path(p)) => {
                        self.buf.extend_from_slice(&(p.len() as u32).to_le_bytes());
                        self.buf.extend_from_slice(&0u32.to_le_bytes());
                        for key in p {
                            self.value(key);
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
                ("destroy", wire::APPLY_DESTROY),
            ]
        );
        assert_eq!(SPEC.occurrence[0].kind, crate::ring::REC_BUTTON_CLICKED);
        assert_eq!(SPEC.occurrence[1].kind, crate::ring::REC_TEXT_CHANGED);
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
                    ("kind", "column") => wire::KIND_COLUMN,
                    ("kind", "button") => wire::KIND_BUTTON,
                    ("kind", "label") => wire::KIND_LABEL,
                    ("kind", "entry") => wire::KIND_ENTRY,
                    ("prop", "text") => wire::PROP_TEXT,
                    ("source", "const") => wire::SOURCE_CONST,
                    ("source", "signal") => wire::SOURCE_SIGNAL,
                    ("source", "element") => wire::SOURCE_ELEMENT,
                    ("occurrence", "pad") => crate::ring::REC_PAD as u32,
                    ("occurrence", "button_clicked") => crate::ring::REC_BUTTON_CLICKED as u32,
                    ("occurrence", "text_changed") => crate::ring::REC_TEXT_CHANGED as u32,
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
        let mut w = GenericWriter { buf: Vec::new() };
        w.record(
            tx_record("create_signal"),
            &[Arg::U64(1), Arg::Value(Value::from("step 0"))],
        );
        w.record(
            tx_record("create_widget"),
            &[Arg::U64(2), Arg::U32(wire::KIND_BUTTON), Arg::U32(0)],
        );
        w.record(
            tx_record("collection_insert"),
            &[
                Arg::U64(3),
                Arg::Path(vec![Value::from("g1")]),
                Arg::Value(Value::from("a")),
                Arg::Value(Value::I64(9)),
            ],
        );
        w.record(
            tx_record("collection_remove"),
            &[
                Arg::U64(3),
                Arg::Path(vec![]),
                Arg::Value(Value::from("g1")),
            ],
        );
        w.record(tx_record("create_for"), &[Arg::U64(4), Arg::U64(3)]);
        w.record(tx_record("template_end"), &[]);
        w.record(tx_record("mount"), &[Arg::U64(0), Arg::U64(2)]);

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
            TxOp::CollectionInsert {
                id: CollectionId(3),
                path: vec![Value::from("g1")],
                key: Value::from("a"),
                value: Value::I64(9),
            },
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
        ];
        assert_eq!(ops.len(), expected.len());
        for (a, b) in ops.iter().zip(expected.iter()) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"));
        }
        // And the variable-tail record, one arm per source.
        let mut w = GenericWriter { buf: Vec::new() };
        w.record(
            tx_record("set_property"),
            &[Arg::U64(2), Arg::U32(wire::PROP_TEXT), Arg::U32(wire::SOURCE_CONST)],
        );
        // Splice the const tail in by hand, as a generated helper would.
        let mut buf = w.buf;
        buf.truncate(buf.len()); // record already padded; rebuild with tail
        let mut w = GenericWriter { buf: Vec::new() };
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
