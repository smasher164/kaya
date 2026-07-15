//! Traffic types between the core (main thread) and app logic (its own
//! thread).
//!
//! Transport policy: while the crate is in-process-only, transactions ride
//! `std::sync::mpsc` as parsed values, and the Rust API constructs them
//! directly — serialization is for the C boundary (wire.rs), where foreign
//! guests submit the same records as bytes. Occurrences travel the
//! byte-record ring (ring.rs) or mpsc, per consumer.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WidgetId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SignalId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WindowId(pub u64);

/// A collection: a core-side ordered key→value table, the sibling of a
/// signal, changed with delta records and rendered by a For.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CollectionId(pub u64);

/// A template node: a blueprint entry, declared inside a For/When
/// template scope. Never on screen and never addressable alone — an
/// instance is named (template node, key path). Its own id space, so a
/// WidgetId always names exactly one live widget.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TemplateNodeId(pub u64);

/// The implicit window every scene can mount into until the window
/// vocabulary arrives (see DESIGN.md: windows are a scene layer).
pub const DEFAULT_WINDOW: WindowId = WindowId(0);

/// A key path: one key per enclosing For, outermost first. Selects one
/// stamped copy at each nesting level. Empty for the live (untemplated)
/// zone.
pub type Path = Vec<Value>;

/// Core -> app. Ordered, lossless, consumed exactly once.
#[derive(Debug, PartialEq)]
pub enum Occurrence {
    /// A click on a widget the guest created directly.
    ButtonClicked { id: WidgetId },
    /// A click on a stamped copy of a template button: which blueprint
    /// node, and the key path naming the copy.
    InstanceButtonClicked { node: TemplateNodeId, path: Path },
    /// The core is gone and no further occurrences will arrive; the app
    /// loop should end. First member of the lifecycle vocabulary.
    Shutdown,
}

/// A signal, property, element, or key value. The scalar set; records
/// and variant dispatch arrive with milestone 3.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Bool(bool),
    I64(i64),
    F64(f64),
    Str(String),
}

impl From<&str> for Value {
    fn from(s: &str) -> Self {
        Value::Str(s.to_owned())
    }
}
impl From<String> for Value {
    fn from(s: String) -> Self {
        Value::Str(s)
    }
}
impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::I64(v)
    }
}
impl From<bool> for Value {
    fn from(v: bool) -> Self {
        Value::Bool(v)
    }
}

/// A collection key, core-side: domain identity, unique per collection
/// instance. I64 and Str only — a float is not an identity, and a bool
/// key is a When in disguise. Hashable where Value cannot be.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Key {
    I64(i64),
    Str(String),
}

impl Key {
    /// Keys arrive on the wire as values; anything but I64/Str is a
    /// broken binding.
    pub fn from_value(v: &Value) -> Key {
        match v {
            Value::I64(n) => Key::I64(*n),
            Value::Str(s) => Key::Str(s.clone()),
            other => panic!("kaya: collection keys must be I64 or Str, got {other:?}"),
        }
    }

    pub fn to_value(&self) -> Value {
        match self {
            Key::I64(n) => Value::I64(*n),
            Key::Str(s) => Value::Str(s.clone()),
        }
    }
}

/// Widget kinds of the milestone-1 vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WidgetKind {
    Column,
    Button,
    Label,
}

/// Property keys. One so far; grows with widgets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Prop {
    Text,
}

/// A bound property's source: a constant, a signal reference, or —
/// inside a template — the element (the entry's value) of an enclosing
/// For, `level` Fors up (0 = nearest). Nothing else; the binding rule,
/// wire-concrete.
#[derive(Debug, Clone)]
pub enum PropValue {
    Const(Value),
    Signal(SignalId),
    Element { level: u32 },
}

/// One record of a transaction, app -> core.
///
/// Zone rule: between CreateFor/CreateWhen and its matching TemplateEnd,
/// creation records describe a blueprint — their ids are read in the
/// template-node space (the WidgetId newtype in these ops carries a
/// template node id there; one wire vocabulary, two zones). Outside a
/// scope they create live things, as in milestone 1.
#[derive(Debug)]
pub enum TxOp {
    CreateSignal { id: SignalId, initial: Value },
    WriteSignal { id: SignalId, value: Value },
    CreateWidget { id: WidgetId, kind: WidgetKind },
    SetProperty { widget: WidgetId, prop: Prop, value: PropValue },
    AddChild { parent: WidgetId, child: WidgetId },
    Mount { window: WindowId, root: WidgetId },
    CreateCollection { id: CollectionId },
    /// Delta ops. `path` addresses the collection instance (one key per
    /// enclosing For of the collection's declaration site; empty for a
    /// top-level collection).
    CollectionInsert { id: CollectionId, path: Path, key: Value, value: Value },
    CollectionUpdate { id: CollectionId, path: Path, key: Value, value: Value },
    CollectionRemove { id: CollectionId, path: Path, key: Value },
    /// Opens a template scope; records until TemplateEnd are the
    /// blueprint. The For itself lives where it was declared (live
    /// widget at top level, template node inside another template).
    CreateFor { id: u64, collection: CollectionId },
    /// When is For over a zero-or-one collection wired to a Bool signal:
    /// false→true stamps the template, true→false unstamps.
    CreateWhen { id: u64, signal: SignalId },
    TemplateEnd,
}

/// A transaction: applied atomically, in submission order, last write
/// wins per signal within the batch.
pub type Transaction = Vec<TxOp>;

/// What a backend applies, produced by the scene core from a transaction
/// with every signal and element reference already resolved. Backends
/// stay appliers: no diffing, no reconciliation, no subscriptions.
///
/// Ids here are opaque u64 keys into the backend's widget map: guest
/// widget ids for the live zone, core-allocated instance ids (top bit
/// set) for stamped copies. Backends never tell them apart.
#[derive(Debug, PartialEq)]
pub enum ApplyOp {
    /// `tag`: for interactive widgets, the pre-encoded occurrence body
    /// the backend emits verbatim on activation (see wire::click_tag).
    /// The backend stores bytes and hands them back; identity stays a
    /// core concern.
    Create { id: WidgetId, kind: WidgetKind, tag: Option<Vec<u8>> },
    SetProp { id: WidgetId, prop: Prop, value: Value },
    AddChild { parent: WidgetId, child: WidgetId },
    Mount { window: WindowId, root: WidgetId },
    /// Remove the widget from its parent and forget it. The core emits
    /// one Destroy per widget of a torn-down instance, children before
    /// parents, so backends never walk anything.
    Destroy { id: WidgetId },
}

/// Where occurrences go: the Rust API consumes over mpsc, the C ABI over
/// the byte-record ring. One consumer either way.
#[derive(Clone)]
pub(crate) enum OccSink {
    Mpsc(std::sync::mpsc::Sender<Occurrence>),
    Ring(std::sync::Arc<crate::ring::OccRing>),
}

impl OccSink {
    pub(crate) fn send(&self, occurrence: Occurrence) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(occurrence);
            }
            OccSink::Ring(ring) => match occurrence {
                Occurrence::ButtonClicked { id } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    ring.push_record(crate::ring::REC_BUTTON_CLICKED, &tag);
                }
                Occurrence::InstanceButtonClicked { node, path } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    ring.push_record(crate::ring::REC_BUTTON_CLICKED, &tag);
                }
                Occurrence::Shutdown => ring.set_shutdown(),
            },
        }
    }

    /// The backend fast path: a stored click tag goes out verbatim (ring)
    /// or is parsed back into an Occurrence (mpsc).
    pub(crate) fn send_click_tag(&self, tag: &[u8]) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(crate::wire::decode_click_tag(tag));
            }
            OccSink::Ring(ring) => {
                ring.push_record(crate::ring::REC_BUTTON_CLICKED, tag);
            }
        }
    }
}
