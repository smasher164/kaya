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
    /// The user edited an entry the guest created directly. The widget
    /// owns its text; the app folds these into its own model — there is
    /// no read-back, by doctrine.
    TextChanged { id: WidgetId, text: String },
    /// The user edited a stamped copy of a template entry.
    InstanceTextChanged { node: TemplateNodeId, path: Path, text: String },
    /// The user toggled a checkbox the guest created directly; carries
    /// the new state. Same ownership stance as TextChanged.
    Toggled { id: WidgetId, checked: bool },
    /// The user toggled a stamped copy of a template checkbox.
    InstanceToggled { node: TemplateNodeId, path: Path, checked: bool },
    /// The user moved a slider the guest created directly; carries the
    /// new value, one occurrence per change (the entry's per-edit
    /// granularity). Same ownership stance as TextChanged.
    ValueChanged { id: WidgetId, value: f64 },
    /// The user moved a stamped copy of a template slider.
    InstanceValueChanged { node: TemplateNodeId, path: Path, value: f64 },
    /// The core is gone and no further occurrences will arrive; the app
    /// loop should end. First member of the lifecycle vocabulary.
    Shutdown,
}

/// A signal, property, element-field, or key value. The scalar set;
/// there is deliberately no record *value* — a collection entry is a
/// Record (one Value per schema field), and Value::Record waits for
/// the feature that needs a record as a value (nested fields, sum-typed
/// payloads).
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Bool(bool),
    I64(i64),
    F64(f64),
    Str(String),
}

/// A value's type: the schema element. Every collection declares an
/// ordered list of these at creation, and every field access — inserts,
/// field updates, element bindings — is validated against it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValueType {
    Bool,
    I64,
    F64,
    Str,
}

impl Value {
    pub fn type_of(&self) -> ValueType {
        match self {
            Value::Bool(_) => ValueType::Bool,
            Value::I64(_) => ValueType::I64,
            Value::F64(_) => ValueType::F64,
            Value::Str(_) => ValueType::Str,
        }
    }
}

/// One collection entry's value: one Value per schema field, positional.
/// A scalar collection is the one-field case.
pub type Record = Vec<Value>;

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
impl From<f64> for Value {
    fn from(v: f64) -> Self {
        Value::F64(v)
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

/// The widget vocabulary, growing one conformance-gallery widget at a
/// time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WidgetKind {
    Column,
    Button,
    Label,
    /// A single-line text field. Uncontrolled: the widget owns its
    /// text and reports edits as TextChanged occurrences; Prop::Text
    /// sets the initial (or programmatic) content.
    Entry,
    /// A horizontal container: Column turned sideways.
    Row,
    /// A labeled on/off box. Prop::Text is the caption, Prop::Checked
    /// the state; user toggles report as Toggled occurrences.
    Checkbox,
    /// A continuous control over a numeric range. Prop::Value is the
    /// position, Prop::Min/Prop::Max the range (0..1 unless set); user
    /// drags report as ValueChanged occurrences, one per change.
    /// Uncontrolled, like the entry: the widget owns its position.
    Slider,
}

/// Property keys; grows with widgets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Prop {
    Text,
    /// A checkbox's state (Bool-valued).
    Checked,
    /// A slider's position (F64-valued).
    Value,
    /// A slider's range, lower bound (F64-valued).
    Min,
    /// A slider's range, upper bound (F64-valued).
    Max,
}

/// The one-shot command vocabulary: momentary verbs aimed at
/// widget-owned state, the third arm of the ownership rule (app-owned
/// state travels as props and deltas, widget-owned state comes back as
/// occurrences, and the app's momentary crossings into state it does
/// not own are commands). Fire-and-forget: no state at rest, nothing
/// replays on instance rebuild, and the widget reports the result
/// through its normal occurrence path. A closed set; each verb is
/// admitted by a real artifact, per the escalation policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandKind {
    /// Drop an entry's content now (the widget stays authoritative and
    /// answers with a TextChanged carrying the empty text).
    Clear,
    /// Give the widget the keyboard focus.
    Focus,
}

/// A bound property's source: a constant, a signal reference, or —
/// inside a template — one field of the element (the entry's record)
/// of an enclosing For, `level` Fors up (0 = nearest). Nothing else;
/// the binding rule, wire-concrete.
#[derive(Debug, Clone)]
pub enum PropValue {
    Const(Value),
    Signal(SignalId),
    Element { level: u32, field: u32 },
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
    /// Declare a collection with its schema: one ordered field-type
    /// list per variant of the element sum. Mandatory — a record
    /// collection is the one-variant case and a scalar collection the
    /// one-variant one-field case, not separate modes. Variants are
    /// indices; variant names never travel, like field names.
    CreateCollection { id: CollectionId, variants: Vec<Vec<ValueType>> },
    /// Delta ops. `path` addresses the collection instance (one key per
    /// enclosing For of the collection's declaration site; empty for a
    /// top-level collection). `variant` selects which of the sum's
    /// schemas the record matches; an update whose variant differs from
    /// the entry's current one tears down its stamped copy and restamps
    /// from the new variant's case.
    CollectionInsert { id: CollectionId, path: Path, key: Value, variant: u32, record: Record },
    CollectionUpdate { id: CollectionId, path: Path, key: Value, variant: u32, record: Record },
    /// One field's delta: toggling a todo's `done` never resends its
    /// title, and only bindings on that field re-resolve. `variant` is
    /// the discriminant the guest witnessed in the match that produced
    /// this write — never a way to change it — and the scene asserts it
    /// against the entry's stored variant, so a binding whose model
    /// drifted from the core fails loudly instead of writing a
    /// type-correct field of the wrong constructor.
    CollectionUpdateField {
        id: CollectionId,
        path: Path,
        key: Value,
        variant: u32,
        field: u32,
        value: Value,
    },
    CollectionRemove { id: CollectionId, path: Path, key: Value },
    /// Reposition an entry in the ordered table: before the entry at
    /// `before`, or to the end when None. Keys, never indices.
    CollectionMove { id: CollectionId, path: Path, key: Value, before: Option<Value> },
    /// Opens a template scope; records until TemplateEnd are the
    /// blueprint. The For itself lives where it was declared (live
    /// widget at top level, template node inside another template).
    /// Over a multi-variant collection the scope is split by
    /// VariantCase records — one blueprint per constructor, checked
    /// total at TemplateEnd.
    CreateFor { id: u64, collection: CollectionId },
    /// When is For over a zero-or-one collection wired to a Bool signal:
    /// false→true stamps the template, true→false unstamps.
    CreateWhen { id: u64, signal: SignalId },
    /// Inside a For over a sum: the records that follow (until the next
    /// VariantCase or TemplateEnd) are the blueprint for this variant.
    /// Declaring a case with no records is the explicit way to render
    /// a constructor as nothing; omitting a case is a scene error.
    VariantCase { variant: u32 },
    TemplateEnd,
    /// A one-shot command aimed at a live widget. Live-zone targets
    /// only for now: a live id can only vanish by the guest's own hand,
    /// so a missing target is misuse and fails loudly, like
    /// SetProperty. Instance-addressed commands (a scrollTo naming a
    /// stamped row) arrive with their artifact and bring the silent
    /// vanished-target no-op with them — stamped copies legitimately
    /// disappear under rebuild.
    WidgetCommand { widget: WidgetId, command: CommandKind },
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
    /// Reposition `child` among `parent`'s children: before the
    /// sibling `before`, or to the end when None.
    MoveChild { parent: WidgetId, child: WidgetId, before: Option<WidgetId> },
    /// Remove the widget from its parent and forget it. The core emits
    /// one Destroy per widget of a torn-down instance, children before
    /// parents, so backends never walk anything.
    Destroy { id: WidgetId },
    /// Execute a one-shot command on the widget, then let it report
    /// the result through its normal occurrence path — a clear arrives
    /// back as TextChanged with empty text, through the same delegate
    /// a keystroke uses (programmatic mutations fire the change path
    /// explicitly on toolkits that don't, the Stage set_text
    /// precedent).
    Command { id: WidgetId, command: CommandKind },
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
                Occurrence::TextChanged { id, text } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    let body = crate::wire::text_changed_body(&tag, &text);
                    ring.push_record(crate::ring::REC_TEXT_CHANGED, &body);
                }
                Occurrence::InstanceTextChanged { node, path, text } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    let body = crate::wire::text_changed_body(&tag, &text);
                    ring.push_record(crate::ring::REC_TEXT_CHANGED, &body);
                }
                Occurrence::Toggled { id, checked } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    let body = crate::wire::toggled_body(&tag, checked);
                    ring.push_record(crate::ring::REC_TOGGLED, &body);
                }
                Occurrence::InstanceToggled { node, path, checked } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    let body = crate::wire::toggled_body(&tag, checked);
                    ring.push_record(crate::ring::REC_TOGGLED, &body);
                }
                Occurrence::ValueChanged { id, value } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    let body = crate::wire::value_changed_body(&tag, value);
                    ring.push_record(crate::ring::REC_VALUE_CHANGED, &body);
                }
                Occurrence::InstanceValueChanged { node, path, value } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    let body = crate::wire::value_changed_body(&tag, value);
                    ring.push_record(crate::ring::REC_VALUE_CHANGED, &body);
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

    /// The same fast path for a checkbox toggle: the stored tag plus
    /// the new state.
    pub(crate) fn send_toggle_tag(&self, tag: &[u8], checked: bool) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(crate::wire::decode_toggled_tag(tag, checked));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_TOGGLED,
                    &crate::wire::toggled_body(tag, checked),
                );
            }
        }
    }

    /// The same fast path for a slider move: the stored tag plus the
    /// new value.
    pub(crate) fn send_value_tag(&self, tag: &[u8], value: f64) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(crate::wire::decode_value_changed_tag(tag, value));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_VALUE_CHANGED,
                    &crate::wire::value_changed_body(tag, value),
                );
            }
        }
    }

    /// The same fast path for an entry edit: the stored tag plus the
    /// field's current text.
    pub(crate) fn send_text_tag(&self, tag: &[u8], text: &str) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(crate::wire::decode_text_changed_tag(tag, text));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_TEXT_CHANGED,
                    &crate::wire::text_changed_body(tag, text),
                );
            }
        }
    }
}
