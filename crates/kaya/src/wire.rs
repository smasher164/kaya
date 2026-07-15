//! Byte encoding of the protocol for the C boundary.
//!
//! One framing serves every channel — u32 size, u16 kind, u16 flags,
//! 8-byte aligned, size includes the header, little-endian — but the
//! transports differ: occurrences ride the shared ring (ring.rs),
//! transactions arrive as a submitted buffer (one call commits one
//! buffer), and the presentation pump hands resolved apply-ops out as a
//! filled buffer. The Rust API skips this module entirely and constructs
//! protocol values directly; decoding is for foreign guests, encoding for
//! the pump and for tests.
//!
//! Values are encoded as { u32 type; u32 len; payload padded to 8 }.
//! Malformed input fails loudly: a bad buffer is a broken binding, not a
//! runtime condition.

use crate::protocol::{
    ApplyOp, CollectionId, Occurrence, Path, Prop, PropValue, SignalId, TemplateNodeId,
    Transaction, TxOp, Value, WidgetId, WidgetKind, WindowId,
};

pub const HEADER_SIZE: usize = 8;

// Transaction record kinds (guest -> core).
pub const TX_CREATE_SIGNAL: u16 = 1;
pub const TX_WRITE_SIGNAL: u16 = 2;
pub const TX_CREATE_WIDGET: u16 = 3;
pub const TX_SET_PROPERTY: u16 = 4;
pub const TX_ADD_CHILD: u16 = 5;
pub const TX_MOUNT: u16 = 6;
pub const TX_CREATE_COLLECTION: u16 = 7;
pub const TX_COLLECTION_INSERT: u16 = 8;
pub const TX_COLLECTION_UPDATE: u16 = 9;
pub const TX_COLLECTION_REMOVE: u16 = 10;
pub const TX_CREATE_FOR: u16 = 11;
pub const TX_CREATE_WHEN: u16 = 12;
pub const TX_TEMPLATE_END: u16 = 13;

// Apply record kinds (core -> presentation pump).
pub const APPLY_CREATE: u16 = 1;
pub const APPLY_SET_PROP: u16 = 2;
pub const APPLY_ADD_CHILD: u16 = 3;
pub const APPLY_MOUNT: u16 = 4;
pub const APPLY_DESTROY: u16 = 5;

// Value types.
pub const VALUE_BOOL: u32 = 1;
pub const VALUE_I64: u32 = 2;
pub const VALUE_F64: u32 = 3;
pub const VALUE_STR: u32 = 4;

// Widget kinds.
pub const KIND_COLUMN: u32 = 1;
pub const KIND_BUTTON: u32 = 2;
pub const KIND_LABEL: u32 = 3;
pub const KIND_ENTRY: u32 = 4;
pub const KIND_ROW: u32 = 5;
pub const KIND_CHECKBOX: u32 = 6;

// Property keys.
pub const PROP_TEXT: u32 = 1;
pub const PROP_CHECKED: u32 = 2;

// set_property sources.
pub const SOURCE_CONST: u32 = 0;
pub const SOURCE_SIGNAL: u32 = 1;
pub const SOURCE_ELEMENT: u32 = 2;

fn pad8(n: usize) -> usize {
    (n + 7) & !7
}

// --- Reading -------------------------------------------------------------

struct Reader<'a> {
    buf: &'a [u8],
    at: usize,
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
            VALUE_I64 => Value::I64(i64::from_le_bytes(payload.try_into().unwrap())),
            VALUE_F64 => Value::F64(f64::from_le_bytes(payload.try_into().unwrap())),
            VALUE_STR => Value::Str(
                std::str::from_utf8(payload)
                    .expect("kaya: string value is not UTF-8")
                    .to_owned(),
            ),
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
}

fn widget_kind(raw: u32) -> WidgetKind {
    match raw {
        KIND_COLUMN => WidgetKind::Column,
        KIND_BUTTON => WidgetKind::Button,
        KIND_LABEL => WidgetKind::Label,
        KIND_ENTRY => WidgetKind::Entry,
        KIND_ROW => WidgetKind::Row,
        KIND_CHECKBOX => WidgetKind::Checkbox,
        other => panic!("kaya: unknown widget kind {other}"),
    }
}

fn prop(raw: u32) -> Prop {
    match raw {
        PROP_TEXT => Prop::Text,
        PROP_CHECKED => Prop::Checked,
        other => panic!("kaya: unknown property {other}"),
    }
}

/// Decode a submitted transaction buffer. Panics on malformed input; a
/// bad buffer is a broken binding and the failure should be loud.
pub fn decode_transaction(buf: &[u8]) -> Transaction {
    assert!(buf.len() % 8 == 0, "kaya: transaction length not 8-aligned");
    let mut ops = Vec::new();
    let mut at = 0;
    while at < buf.len() {
        let mut r = Reader { buf, at };
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
                        let _pad = r.u32();
                        PropValue::Element { level }
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
            },
            TX_COLLECTION_INSERT => TxOp::CollectionInsert {
                id: CollectionId(r.u64()),
                path: r.path(),
                key: r.value(),
                value: r.value(),
            },
            TX_COLLECTION_UPDATE => TxOp::CollectionUpdate {
                id: CollectionId(r.u64()),
                path: r.path(),
                key: r.value(),
                value: r.value(),
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
            other => panic!("kaya: unknown transaction record kind {other}"),
        });
        at += size;
    }
    ops
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
        write_value(&mut b, key);
    }
    b
}

pub fn decode_click_tag(tag: &[u8]) -> Occurrence {
    let mut r = Reader { buf: tag, at: 0 };
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

// A text-changed occurrence body: the widget's stored tag (identity,
// same layout as a click) followed by the new text as a value. The
// backend never learns what the tag means; it appends what the user
// typed.
pub fn text_changed_body(tag: &[u8], text: &str) -> Vec<u8> {
    let mut b = Vec::with_capacity(tag.len() + 8 + text.len());
    b.extend_from_slice(tag);
    write_value(&mut b, &Value::Str(text.to_owned()));
    b
}

// A toggled occurrence body: the checkbox's stored tag (identity, same
// layout as a click) followed by the new state as a value.
pub fn toggled_body(tag: &[u8], checked: bool) -> Vec<u8> {
    let mut b = Vec::with_capacity(tag.len() + 16);
    b.extend_from_slice(tag);
    write_value(&mut b, &Value::Bool(checked));
    b
}

pub fn decode_toggled_tag(tag: &[u8], checked: bool) -> Occurrence {
    let mut r = Reader { buf: tag, at: 0 };
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
    let mut r = Reader { buf: tag, at: 0 };
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

// --- Writing -------------------------------------------------------------

pub struct Writer {
    buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Self {
        Writer { buf: Vec::new() }
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.buf
    }

    fn record(&mut self, kind: u16, body: impl FnOnce(&mut Vec<u8>)) {
        let start = self.buf.len();
        self.buf.extend_from_slice(&[0; HEADER_SIZE]);
        body(&mut self.buf);
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
            ApplyOp::Create { id, kind, tag } => self.record(APPLY_CREATE, |b| {
                b.extend_from_slice(&id.0.to_le_bytes());
                b.extend_from_slice(&kind_raw(*kind).to_le_bytes());
                let tag = tag.as_deref().unwrap_or(&[]);
                b.extend_from_slice(&(tag.len() as u32).to_le_bytes());
                b.extend_from_slice(tag);
            }),
            ApplyOp::SetProp { id, prop, value } => self.record(APPLY_SET_PROP, |b| {
                b.extend_from_slice(&id.0.to_le_bytes());
                b.extend_from_slice(&prop_raw(*prop).to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
                write_value(b, value);
            }),
            ApplyOp::AddChild { parent, child } => self.record(APPLY_ADD_CHILD, |b| {
                b.extend_from_slice(&parent.0.to_le_bytes());
                b.extend_from_slice(&child.0.to_le_bytes());
            }),
            ApplyOp::Mount { window, root } => self.record(APPLY_MOUNT, |b| {
                b.extend_from_slice(&window.0.to_le_bytes());
                b.extend_from_slice(&root.0.to_le_bytes());
            }),
            ApplyOp::Destroy { id } => self.record(APPLY_DESTROY, |b| {
                b.extend_from_slice(&id.0.to_le_bytes());
            }),
        }
    }

    /// Transaction encoding: exercised by the round-trip tests; the Rust
    /// API sends parsed values, and foreign guests pack their own bytes.
    #[cfg(test)]
    pub fn tx_op(&mut self, op: &TxOp) {
        match op {
            TxOp::CreateSignal { id, initial } => self.record(TX_CREATE_SIGNAL, |b| {
                b.extend_from_slice(&id.0.to_le_bytes());
                write_value(b, initial);
            }),
            TxOp::WriteSignal { id, value } => self.record(TX_WRITE_SIGNAL, |b| {
                b.extend_from_slice(&id.0.to_le_bytes());
                write_value(b, value);
            }),
            TxOp::CreateWidget { id, kind } => self.record(TX_CREATE_WIDGET, |b| {
                b.extend_from_slice(&id.0.to_le_bytes());
                b.extend_from_slice(&kind_raw(*kind).to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
            }),
            TxOp::SetProperty {
                widget,
                prop,
                value,
            } => self.record(TX_SET_PROPERTY, |b| {
                b.extend_from_slice(&widget.0.to_le_bytes());
                b.extend_from_slice(&prop_raw(*prop).to_le_bytes());
                match value {
                    PropValue::Const(v) => {
                        b.extend_from_slice(&SOURCE_CONST.to_le_bytes());
                        write_value(b, v);
                    }
                    PropValue::Signal(id) => {
                        b.extend_from_slice(&SOURCE_SIGNAL.to_le_bytes());
                        b.extend_from_slice(&id.0.to_le_bytes());
                    }
                    PropValue::Element { level } => {
                        b.extend_from_slice(&SOURCE_ELEMENT.to_le_bytes());
                        b.extend_from_slice(&level.to_le_bytes());
                        b.extend_from_slice(&0u32.to_le_bytes());
                    }
                }
            }),
            TxOp::AddChild { parent, child } => self.record(TX_ADD_CHILD, |b| {
                b.extend_from_slice(&parent.0.to_le_bytes());
                b.extend_from_slice(&child.0.to_le_bytes());
            }),
            TxOp::Mount { window, root } => self.record(TX_MOUNT, |b| {
                b.extend_from_slice(&window.0.to_le_bytes());
                b.extend_from_slice(&root.0.to_le_bytes());
            }),
            TxOp::CreateCollection { id } => self.record(TX_CREATE_COLLECTION, |b| {
                b.extend_from_slice(&id.0.to_le_bytes());
            }),
            TxOp::CollectionInsert { id, path, key, value } => {
                self.record(TX_COLLECTION_INSERT, |b| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    write_path(b, path);
                    write_value(b, key);
                    write_value(b, value);
                })
            }
            TxOp::CollectionUpdate { id, path, key, value } => {
                self.record(TX_COLLECTION_UPDATE, |b| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    write_path(b, path);
                    write_value(b, key);
                    write_value(b, value);
                })
            }
            TxOp::CollectionRemove { id, path, key } => {
                self.record(TX_COLLECTION_REMOVE, |b| {
                    b.extend_from_slice(&id.0.to_le_bytes());
                    write_path(b, path);
                    write_value(b, key);
                })
            }
            TxOp::CreateFor { id, collection } => self.record(TX_CREATE_FOR, |b| {
                b.extend_from_slice(&id.to_le_bytes());
                b.extend_from_slice(&collection.0.to_le_bytes());
            }),
            TxOp::CreateWhen { id, signal } => self.record(TX_CREATE_WHEN, |b| {
                b.extend_from_slice(&id.to_le_bytes());
                b.extend_from_slice(&signal.0.to_le_bytes());
            }),
            TxOp::TemplateEnd => self.record(TX_TEMPLATE_END, |_| {}),
        }
    }
}

#[cfg(test)]
fn write_path(b: &mut Vec<u8>, path: &Path) {
    b.extend_from_slice(&(path.len() as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    for key in path {
        write_value(b, key);
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
    }
}

fn prop_raw(prop: Prop) -> u32 {
    match prop {
        Prop::Text => PROP_TEXT,
        Prop::Checked => PROP_CHECKED,
    }
}

fn write_value(b: &mut Vec<u8>, value: &Value) {
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
    }
    let _ = start;
    while b.len() % 8 != 0 {
        b.push(0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every record kind survives the encode/decode round trip byte-for
    /// semantics: what a foreign guest packs is what the core parses.
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
            TxOp::CreateCollection { id: CollectionId(1) },
            TxOp::CreateFor { id: 2, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(3),
                prop: Prop::Text,
                value: PropValue::Element { level: 0 },
            },
            TxOp::TemplateEnd,
            TxOp::CreateWhen { id: 4, signal: SignalId(9) },
            TxOp::TemplateEnd,
            TxOp::CollectionInsert {
                id: CollectionId(1),
                path: vec![],
                key: Value::from("g1"),
                value: Value::from("Work"),
            },
            TxOp::CollectionUpdate {
                id: CollectionId(7),
                path: vec![Value::from("g1"), Value::I64(4)],
                key: Value::I64(4),
                value: Value::Bool(true),
            },
            TxOp::CollectionRemove {
                id: CollectionId(7),
                path: vec![Value::from("g1")],
                key: Value::from("a"),
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
        let mut r = Reader { buf: &body, at: 0 };
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
        let mut r = Reader { buf: &body, at: 0 };
        assert_eq!(r.u64(), 5);
        assert!(r.path().is_empty());
        assert_eq!(r.value(), Value::Bool(true));
        assert!(body.len() % 8 == 0, "bodies must stay 8-aligned for the ring");
    }

    #[test]
    fn values_round_trip() {
        for v in [
            Value::Bool(true),
            Value::I64(i64::MIN),
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
