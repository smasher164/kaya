//! Traffic types between the core (main thread) and app logic (its own
//! thread).
//!
//! Transport policy: while the crate is in-process-only, transactions ride
//! `std::sync::mpsc` as parsed values, and the Rust API constructs them
//! directly — serialization is for the C boundary (wire.rs), where foreign
//! guests submit the same records as bytes. Occurrences travel the
//! byte-record ring (ring.rs) or mpsc, per consumer.

use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WidgetId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SignalId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WindowId(pub u64);

/// A live alert request's id: guest-chosen, single-use — it retires
/// when its one AlertResult fires (reuse after retirement is legal;
/// reuse while live is a guest error).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AlertId(pub u64);

/// An alert's one answer. The wire carries a u32: action indices, or
/// the deliberately-not-an-index cancel sentinel (ALERT_CHOICE_CANCEL)
/// that every platform-native dismissal — Esc, back, outside tap, the
/// cancel button itself — resolves to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlertChoice {
    /// The action at this index (0 or 1) was chosen.
    Action(u32),
    /// The uniform dismissal slot fired.
    Cancel,
}

/// One modal alert request, atomic on the wire (SHOW_ALERT /
/// PRESENT_ALERT carry the same shape): the request/result grammar's
/// first client. `actions` holds 0..=2 labels — the platform floor
/// (ContentDialog's three slots are two actions plus close); `cancel`
/// is the always-present dismissal slot's label.
#[derive(Debug, Clone, PartialEq)]
pub struct AlertSpec {
    pub window: WindowId,
    pub alert: AlertId,
    pub title: String,
    pub message: String,
    pub actions: Vec<String>,
    pub cancel: String,
}

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
    /// The user asked a veto_close window to close. Nothing has
    /// closed; the app answers with destroy_window if it agrees (the
    /// request/confirm veto class — no response required, no
    /// correlation ids).
    CloseRequested { window: WindowId },
    /// A non-veto auxiliary window was closed by its chrome —
    /// informational and post-fact; destroy_window reconciles the
    /// scene (idempotent: the backend tolerates the native window
    /// already being gone).
    WindowClosed { window: WindowId },
    /// The alert's one answer; the dialog is already gone when this
    /// fires, and the alert id retired with it.
    AlertResult { alert: AlertId, choice: AlertChoice },
    /// The user's back affordance popped an entry natively —
    /// informational and post-fact (the WindowClosed precedent); the
    /// core's stack has already reconciled. A programmatic pop_entry
    /// does not echo here: its caller already knows.
    EntryPopped { entry: WindowId },
    /// The user drove the back affordance on an entry whose
    /// intercept_back is armed. Nothing has popped; the app answers
    /// with pop_entry if it agrees — the CloseRequested veto class.
    BackRequested { entry: WindowId },
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

/// Bulk payload bytes behind a cheap handle: the content-buffer arm of
/// the value set. The bytes live once, in core-owned memory; every
/// clone is an Arc clone (8 bytes of pointer, one refcount bump), so a
/// blob bound to N widgets or stamped into M rows never re-copies —
/// the scene's fan-out clones stay O(1) per reference. The last drop
/// frees: reclamation is refcount, resolving DESIGN's open question #2.
/// On the wire a blob travels as its u64 registration handle; the
/// bytes never enter a record stream.
#[derive(Clone)]
pub struct Blob(pub Arc<[u8]>);

impl std::fmt::Debug for Blob {
    /// Length plus a short FNV prefix, never the bytes: round-trip
    /// tests compare Debug strings, and a payload dump would make a
    /// megabyte diff out of a one-line mismatch (while a bare length
    /// would false-match different bytes of equal size).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in self.0.iter() {
            h ^= u64::from(*b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        write!(f, "Blob({} bytes, fnv={:08x})", self.0.len(), h as u32)
    }
}

impl PartialEq for Blob {
    /// Content equality: a decoded blob is a different allocation with
    /// the same bytes, and tests compare across that boundary.
    fn eq(&self, other: &Self) -> bool {
        self.0 == other.0
    }
}

impl From<Vec<u8>> for Blob {
    fn from(bytes: Vec<u8>) -> Self {
        Blob(bytes.into())
    }
}
impl From<&[u8]> for Blob {
    fn from(bytes: &[u8]) -> Self {
        Blob(bytes.into())
    }
}
impl From<Arc<[u8]>> for Blob {
    fn from(bytes: Arc<[u8]>) -> Self {
        Blob(bytes)
    }
}

/// A signal, property, element-field, or key value. The scalar set
/// plus the blob handle; there is deliberately no record *value* — a
/// collection entry is a Record (one Value per schema field), and
/// Value::Record waits for the feature that needs a record as a value
/// (nested fields, sum-typed payloads).
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Bool(bool),
    I64(i64),
    F64(f64),
    Str(String),
    /// Bulk payload bytes (an encoded image, a row batch): Arc'd core
    /// memory referenced by handle on the wire. Not a key type — a
    /// blob names content, never identity.
    Blob(Blob),
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
    Blob,
}

impl Value {
    pub fn type_of(&self) -> ValueType {
        match self {
            Value::Bool(_) => ValueType::Bool,
            Value::I64(_) => ValueType::I64,
            Value::F64(_) => ValueType::F64,
            Value::Str(_) => ValueType::Str,
            Value::Blob(_) => ValueType::Blob,
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
impl From<Blob> for Value {
    fn from(b: Blob) -> Self {
        Value::Blob(b)
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
            Value::Blob(_) => panic!(
                "kaya: a blob names content, never identity — blobs cannot be \
                 collection keys (key by an id and keep the bytes as a field)"
            ),
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
    /// A displayed picture. Prop::Source carries the encoded bytes
    /// (PNG/JPEG/...) as a blob; the toolkit decodes natively.
    /// Display-only, like Label: no occurrence, no tag. The v1 vehicle
    /// for the content-buffer path (DESIGN: "Image covers content
    /// buffers").
    Image,
    /// A horizontal progress bar. Display-only, like Label and
    /// Image: no occurrence, no tag. Prop::Value carries the
    /// determinate fraction (0..=1, domain-checked at the root, the
    /// grow discipline); Prop::Indeterminate switches the bar to the
    /// platform's activity mode (pulse/animation) and Value is
    /// ignored while it is on.
    Progress,
    Select,
    Radio,
    /// A vertical scroll viewport over EXACTLY ONE child (usually a
    /// column) — the ScrolledWindow/SingleChildScrollView shape; the
    /// scene rejects a second child. Vertical-only in v1 (an axis
    /// enum is a later relaxation, the slider-step precedent). No
    /// occurrence: the position is widget-owned state, and no props
    /// of its own — Spacing/Align are container-of-many concerns and
    /// do not apply. Virtualization is explicitly out (ledgered; a
    /// For inside a scroll renders unvirtualized).
    Scroll,
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
    /// An image's encoded source bytes (Blob-valued).
    Source,
    /// A container's inter-child gap on its main axis (F64-valued,
    /// device-independent units; finite, non-negative). The normalized
    /// default is 8 — the prop overrides it per container. Spacing is
    /// a property OF the container, unlike grow, which rides the child.
    Spacing,
    /// A container's cross-axis child placement (I64-valued on the
    /// wire: one of the `align` spec enum's values — start 0, center
    /// 1, end 2, stretch 3, baseline 4). Baseline is rows-only; the
    /// scene rejects it on columns.
    Align,
    /// A child's flex-grow weight within its row/column (F64-valued;
    /// 0 = natural size, the default). Kind-agnostic — any child may
    /// grow.
    ///
    /// The normalized semantics, uniform on every backend: children
    /// with weight 0 are laid out at their natural main-axis size, and
    /// the children with weight > 0 divide the space left over in
    /// proportion to their weights. A grower's own natural size does
    /// not enter the division — weights 1 and 3 split the leftover
    /// 1:3 whatever the two children would have measured. This is the
    /// contract shared by CSS `flex-basis: 0`, Compose's
    /// `Modifier.weight`, XAML star sizing, and Android's
    /// `layout_weight` at a 0 main-axis size; the backends that have no
    /// native weight (AppKit, GTK) construct it explicitly rather than
    /// approximating it with a priority, which would be merely ordinal
    /// and would render differently per platform.
    Grow,
    /// Progress-only (Bool): the bar shows activity without a
    /// fraction — the platform's pulse/animation mode; Value is
    /// ignored while it is on.
    Indeterminate,
}

/// Window property keys — the presentation-context twin of [`Prop`],
/// separate because windows are not widgets (the widget domain checks
/// stay widget-pure; see DESIGN.md's Presentation contexts). Window 0
/// is the primary surface and always exists.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WindowProp {
    /// The surface's title (Str-valued). Uniform semantics with
    /// per-platform materialization: the title bar on the desktops,
    /// UIScene.title on iOS, the Activity task label on Android.
    Title,
    /// Requested content width in DIP (F64-valued; finite, positive).
    /// ADVISORY on every platform: a request the window manager may
    /// decline — tiling WMs on the desktops, the system on mobile —
    /// never a guarantee.
    Width,
    /// Requested content height in DIP; see `Width`.
    Height,
    /// Who owns the chrome close (Bool-valued; default false). False:
    /// native — an aux window just closes (window_closed reports it)
    /// and closing the primary exits the app. True: the close button
    /// emits close_requested and nothing closes until the app answers
    /// with destroy_window — the veto class, armed by opt-in. Inert
    /// on mobile: no chrome close, and back is not close.
    VetoClose,
}

/// Navigation-entry property keys — their own typed table (see
/// spec::ENTRY_PROPS and DESIGN.md's Navigation): a wrong-surface
/// prop dies at compile time in every binding rather than at the
/// scene. Entries share the surface-id namespace with windows (one
/// guest-side allocator; mount's target addresses either), so
/// [`WindowId`] carries entry ids too.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EntryProp {
    /// The entry's title (Str-valued): the back affordance's label
    /// source — the iOS back button, the desktop headers.
    Title,
    /// The close-veto class transplanted to POP (Bool-valued; default
    /// false). False: the platform pops natively with its full
    /// predictive animation. True: the back affordance emits
    /// back_requested and nothing pops until the app answers with
    /// pop_entry — Android's own declared-ahead OnBackPressedCallback
    /// model, not veto-at-gesture-time.
    InterceptBack,
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
    /// Bind a window property. Element sources are rejected at decode
    /// — windows are not collection elements; constants and signals
    /// both bind (a signal-bound title is the reactive title).
    SetWindowProp { window: WindowId, prop: WindowProp, value: PropValue },
    /// Create an auxiliary window (capability-gated; materializes
    /// hidden — mounting a root presents it).
    CreateWindow { window: WindowId },
    /// Close and forget an auxiliary window; its mounted tree is
    /// destroyed children-first. The primary is not destroyable.
    DestroyWindow { window: WindowId },
    /// Request a modal alert over a live window: one atomic record,
    /// answered by exactly one AlertResult (the request/result
    /// grammar). One alert may be live per process.
    ShowAlert(AlertSpec),
    /// Push a navigation entry onto `window`'s stack (no capability
    /// gate — every host materializes a serial stack natively).
    /// Materializes covered/incoming; mounting a root into it
    /// presents it. The covered root below stays alive: retained
    /// until popped.
    PushEntry { window: WindowId, entry: WindowId },
    /// Pop the window's top entry and forget its mounted tree, the
    /// destroy_window teardown discipline (ids never reused). Popping
    /// an empty stack is a scene error. Multi-pop is binding sugar —
    /// N of these in one transaction, one animated transition.
    PopEntry { window: WindowId },
    /// Bind a navigation-entry property. Element sources are rejected
    /// at decode — entries are not collection elements.
    SetEntryProp { entry: WindowId, prop: EntryProp, value: PropValue },
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
    SetWindowProp { window: WindowId, prop: WindowProp, value: Value },
    CreateWindow { window: WindowId },
    DestroyWindow { window: WindowId },
    /// Present the platform's real modal dialog (the core already
    /// validated the spec); answer exactly once with an AlertResult
    /// emission — an action index or the cancel sentinel.
    PresentAlert(AlertSpec),
    /// Push a navigation entry onto the window's stack, hidden until
    /// a mount presents it. The covered root stays alive.
    PushEntry { window: WindowId, entry: WindowId },
    /// Pop the window's top entry and release its views. The NET
    /// stack change of the whole batch animates as one transition
    /// (the multi-pop obligation; see DESIGN.md, Navigation).
    PopEntry { window: WindowId },
    SetEntryProp { entry: WindowId, prop: EntryProp, value: Value },
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
    // The Rust-native backends (GTK, WinUI) push through this; on the
    // interpreter platforms occurrences enter through the C API's
    // typed emit entries instead, so the method is dead there.
    #[cfg_attr(
        any(target_os = "macos", target_os = "ios", target_os = "android"),
        allow(dead_code)
    )]
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
                Occurrence::CloseRequested { window } => {
                    ring.push_record(
                        crate::ring::REC_CLOSE_REQUESTED,
                        &window.0.to_le_bytes(),
                    );
                }
                Occurrence::WindowClosed { window } => {
                    ring.push_record(
                        crate::ring::REC_WINDOW_CLOSED,
                        &window.0.to_le_bytes(),
                    );
                }
                Occurrence::AlertResult { alert, choice } => {
                    ring.push_record(
                        crate::ring::REC_ALERT_RESULT,
                        &crate::wire::alert_result_body(alert, choice),
                    );
                }
                Occurrence::EntryPopped { entry } => {
                    ring.push_record(crate::ring::REC_ENTRY_POPPED, &entry.0.to_le_bytes());
                }
                Occurrence::BackRequested { entry } => {
                    ring.push_record(crate::ring::REC_BACK_REQUESTED, &entry.0.to_le_bytes());
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Content is not identity: the blob arm of the key gate has its
    /// own sentence, because "must be I64 or Str" would leave an
    /// avatar-keyed collection author guessing at the doctrine.
    #[test]
    #[should_panic(expected = "a blob names content, never identity")]
    fn a_blob_cannot_be_a_key() {
        Key::from_value(&Value::Blob(Blob::from(&b"\x89PNG"[..])));
    }
}
