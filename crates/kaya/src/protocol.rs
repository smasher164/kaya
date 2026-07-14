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

/// The implicit window every scene can mount into until the window
/// vocabulary arrives (see DESIGN.md: windows are a scene layer).
pub const DEFAULT_WINDOW: WindowId = WindowId(0);

/// Core -> app. Ordered, lossless, consumed exactly once.
#[derive(Debug)]
pub enum Occurrence {
    ButtonClicked { id: WidgetId },
    /// The core is gone and no further occurrences will arrive; the app
    /// loop should end. First member of the lifecycle vocabulary.
    Shutdown,
}

/// A signal or property value. The milestone-1 set; grows with widgets.
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

/// A bound property's source: a constant, or a signal reference —
/// nothing else (the binding rule, wire-concrete).
#[derive(Debug, Clone)]
pub enum PropValue {
    Const(Value),
    Signal(SignalId),
}

/// One record of a transaction, app -> core.
#[derive(Debug)]
pub enum TxOp {
    CreateSignal { id: SignalId, initial: Value },
    WriteSignal { id: SignalId, value: Value },
    CreateWidget { id: WidgetId, kind: WidgetKind },
    SetProperty { widget: WidgetId, prop: Prop, value: PropValue },
    AddChild { parent: WidgetId, child: WidgetId },
    Mount { window: WindowId, root: WidgetId },
}

/// A transaction: applied atomically, in submission order, last write
/// wins per signal within the batch.
pub type Transaction = Vec<TxOp>;

/// What a backend applies, produced by the scene core from a transaction
/// with every signal reference already resolved. Backends stay appliers:
/// no diffing, no reconciliation, no subscriptions.
#[derive(Debug, PartialEq)]
pub enum ApplyOp {
    Create { id: WidgetId, kind: WidgetKind },
    SetProp { id: WidgetId, prop: Prop, value: Value },
    AddChild { parent: WidgetId, child: WidgetId },
    Mount { window: WindowId, root: WidgetId },
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
                    ring.push(crate::ring::REC_BUTTON_CLICKED, id.0);
                }
                Occurrence::Shutdown => ring.set_shutdown(),
            },
        }
    }
}
