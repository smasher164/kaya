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

use std::sync::Arc;

use crate::protocol::{
    ApplyOp, Blob, CollectionId, CommandKind, Occurrence, Path, Prop, PropValue, Record, SignalId,
    TemplateNodeId, Transaction, TxOp, Value, ValueType, WidgetId, WidgetKind, WindowId,
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
pub const TX_COLLECTION_UPDATE_FIELD: u16 = 14;
pub const TX_COLLECTION_MOVE: u16 = 15;
pub const TX_VARIANT_CASE: u16 = 16;
pub const TX_WIDGET_COMMAND: u16 = 17;

// Apply record kinds (core -> presentation pump).
pub const APPLY_CREATE: u16 = 1;
pub const APPLY_SET_PROP: u16 = 2;
pub const APPLY_ADD_CHILD: u16 = 3;
pub const APPLY_MOUNT: u16 = 4;
pub const APPLY_DESTROY: u16 = 5;
pub const APPLY_MOVE_CHILD: u16 = 6;
pub const APPLY_COMMAND: u16 = 7;

// Value types.
pub const VALUE_BOOL: u32 = 1;
pub const VALUE_I64: u32 = 2;
pub const VALUE_F64: u32 = 3;
pub const VALUE_STR: u32 = 4;
pub const VALUE_BLOB: u32 = 5;

// Widget kinds.
pub const KIND_COLUMN: u32 = 1;
pub const KIND_BUTTON: u32 = 2;
pub const KIND_LABEL: u32 = 3;
pub const KIND_ENTRY: u32 = 4;
pub const KIND_ROW: u32 = 5;
pub const KIND_CHECKBOX: u32 = 6;
pub const KIND_SLIDER: u32 = 7;
pub const KIND_IMAGE: u32 = 8;

// Property keys.
pub const PROP_TEXT: u32 = 1;
pub const PROP_CHECKED: u32 = 2;
pub const PROP_VALUE: u32 = 3;
pub const PROP_MIN: u32 = 4;
pub const PROP_MAX: u32 = 5;
pub const PROP_SOURCE: u32 = 6;
pub const PROP_GROW: u32 = 7;
pub const PROP_SPACING: u32 = 8;
pub const PROP_ALIGN: u32 = 9;

/// The align enum's wire values (spec enum "align").
pub const ALIGN_START: u32 = 0;
pub const ALIGN_CENTER: u32 = 1;
pub const ALIGN_END: u32 = 2;
pub const ALIGN_STRETCH: u32 = 3;
pub const ALIGN_BASELINE: u32 = 4;

// set_property sources.
pub const SOURCE_CONST: u32 = 0;
pub const SOURCE_SIGNAL: u32 = 1;
pub const SOURCE_ELEMENT: u32 = 2;

// One-shot commands.
pub const COMMAND_CLEAR: u32 = 1;
pub const COMMAND_FOCUS: u32 = 2;

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
            VALUE_I64 => Value::I64(i64::from_le_bytes(payload.try_into().unwrap())),
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
        other => panic!("kaya: unknown property {other}"),
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

// --- Writing -------------------------------------------------------------

pub struct Writer {
    buf: Vec<u8>,
    /// The batch's blob table: bytes referenced by the records just
    /// written, in first-reference order. A blob VALUE on the wire is
    /// a 1-based index into this table (0 is reserved as invalid) —
    /// handles are batch-local, and the consumer's fetch window is
    /// exactly one batch (kaya_blob_data serves the current table
    /// until the next kaya_next_commands call replaces it). Payload
    /// bytes never enter the record stream.
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
            ApplyOp::AddChild { parent, child } => self.record(APPLY_ADD_CHILD, |b, _| {
                b.extend_from_slice(&parent.0.to_le_bytes());
                b.extend_from_slice(&child.0.to_le_bytes());
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
