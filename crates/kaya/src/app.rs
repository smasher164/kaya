//! The app thread's view of the world: occurrences in, transactions out.
//!
//! Collections here follow the patch-producing doctrine: the collection
//! is the model — the only copy. Every mutation op edits the model and
//! queues the wire delta in the same call, so reads (`tx.items`,
//! `tx.len`) are exactly the writes, never a second bookkeeping copy.
//! A transaction dropped without commit abandons its records, and the
//! model abandons the same writes.
//!
//! A [`Collection`] handle names one instance: the root handle (what
//! `tx.collection()` returns) is the live-zone table, and `at(key)`
//! selects the instance inside a stamped copy, one key per enclosing
//! For. Mutations and reads take the same handle, so a handler binds
//! the instance once and uses it throughout.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::marker::PhantomData;
use std::sync::mpsc::{Receiver, Sender};

use crate::protocol::{
    CollectionId, CommandKind, DEFAULT_WINDOW, Occurrence, Path, Prop, PropValue, Record, SignalId,
    TemplateNodeId, Transaction, TxOp, Value, ValueType, WidgetId, WidgetKind,
};

// --- Records: the app type is the schema --------------------------------
//
// The guest's own struct declaration is the single source of truth: the
// record! macro derives the wire schema, the conversions, and one field
// token per field, so schema, insert order, and indexes cannot drift.
// Field tokens are typed projections — Field<K> carries the field's
// value kind — and the typed prop tokens (props::TEXT, props::CHECKED)
// carry theirs, so binding a Bool field to a Str property is a compile
// error, the earliest of the three agreeing layers (token unification,
// the scene's declaration-time check, the setters' signatures).

/// A value-kind marker, unifying field tokens with prop tokens at
/// compile time.
pub trait ValueKind {
    const TYPE: ValueType;
}
pub struct StrKind;
pub struct BoolKind;
pub struct I64Kind;
pub struct F64Kind;
impl ValueKind for StrKind {
    const TYPE: ValueType = ValueType::Str;
}
impl ValueKind for BoolKind {
    const TYPE: ValueType = ValueType::Bool;
}
impl ValueKind for I64Kind {
    const TYPE: ValueType = ValueType::I64;
}
impl ValueKind for F64Kind {
    const TYPE: ValueType = ValueType::F64;
}

/// A first-class typed projection: one field of a record type, by
/// position. Exists because two sites have no record instance in hand —
/// binding a field in template position, and updating one field of one
/// entry.
pub struct Field<K> {
    pub index: u32,
    _kind: PhantomData<K>,
}

/// One of the addressable sources a template property binds to: a
/// constant, a signal, or a field of the enclosing For's element —
/// the protocol's whole binding universe, as one argument. The kind
/// parameter keeps constants and fields honest at compile time;
/// signals stay runtime-checked (Rust signals carry no value type
/// yet).
pub struct TplSource<K> {
    inner: SourceInner,
    _kind: PhantomData<K>,
}

enum SourceInner {
    Const(Value),
    Signal(SignalId),
    Field(u32),
}

impl From<&str> for TplSource<StrKind> {
    fn from(s: &str) -> Self {
        TplSource { inner: SourceInner::Const(Value::Str(s.to_owned())), _kind: PhantomData }
    }
}

impl From<bool> for TplSource<BoolKind> {
    fn from(b: bool) -> Self {
        TplSource { inner: SourceInner::Const(Value::Bool(b)), _kind: PhantomData }
    }
}

impl<K> From<SignalId> for TplSource<K> {
    fn from(s: SignalId) -> Self {
        TplSource { inner: SourceInner::Signal(s), _kind: PhantomData }
    }
}

impl<K> From<Field<K>> for TplSource<K> {
    fn from(f: Field<K>) -> Self {
        TplSource { inner: SourceInner::Field(f.index), _kind: PhantomData }
    }
}

impl<K> Field<K> {
    pub const fn new(index: u32) -> Self {
        Field {
            index,
            _kind: PhantomData,
        }
    }
}

/// A property with its value kind in the type. The plain Prop enum
/// stays the wire form; these tokens exist so bind_field can unify the
/// prop's kind with the field's at compile time.
pub struct PropToken<K> {
    pub prop: Prop,
    _kind: PhantomData<K>,
}

pub mod props {
    use super::{BoolKind, PropToken, StrKind};
    use crate::protocol::Prop;
    use std::marker::PhantomData;

    pub const TEXT: PropToken<StrKind> = PropToken {
        prop: Prop::Text,
        _kind: PhantomData,
    };
    pub const CHECKED: PropToken<BoolKind> = PropToken {
        prop: Prop::Checked,
        _kind: PhantomData,
    };
}

/// A Rust type that can be one record field.
pub trait KayaField: Clone {
    type Kind: ValueKind;
    fn to_value(&self) -> Value;
    fn from_value(v: &Value) -> Self;
}

impl KayaField for String {
    type Kind = StrKind;
    fn to_value(&self) -> Value {
        Value::Str(self.clone())
    }
    fn from_value(v: &Value) -> Self {
        match v {
            Value::Str(s) => s.clone(),
            other => panic!("kaya: expected a Str field, model holds {other:?}"),
        }
    }
}

impl KayaField for bool {
    type Kind = BoolKind;
    fn to_value(&self) -> Value {
        Value::Bool(*self)
    }
    fn from_value(v: &Value) -> Self {
        match v {
            Value::Bool(b) => *b,
            other => panic!("kaya: expected a Bool field, model holds {other:?}"),
        }
    }
}

impl KayaField for i64 {
    type Kind = I64Kind;
    fn to_value(&self) -> Value {
        Value::I64(*self)
    }
    fn from_value(v: &Value) -> Self {
        match v {
            Value::I64(n) => *n,
            other => panic!("kaya: expected an I64 field, model holds {other:?}"),
        }
    }
}

impl KayaField for f64 {
    type Kind = F64Kind;
    fn to_value(&self) -> Value {
        Value::F64(*self)
    }
    fn from_value(v: &Value) -> Self {
        match v {
            Value::F64(x) => *x,
            other => panic!("kaya: expected an F64 field, model holds {other:?}"),
        }
    }
}

/// A collection element type: one field-type list per constructor,
/// with the conversions, derived by `#[derive(KayaGen)]` from the type's
/// own shape — an enum is a sum, a struct the one-variant case.
pub trait KayaSum: Clone {
    /// One schema per constructor, indexed by discriminant.
    const VARIANTS: &'static [&'static [ValueType]];
    /// The discriminant this value holds — what an insert or update
    /// witnesses onto the wire.
    fn variant(&self) -> u32;
    fn to_values(&self) -> Record;
    fn from_parts(variant: u32, values: &[Value]) -> Self;
}

/// The one-constructor refinement: a record type, whose fields have
/// stable indexes and whose eliminations are trivial. The typed
/// product surfaces (field tokens, update_field, patch builders) hang
/// off this; sums reach the same wire through their match-refined
/// per-variant handles instead.
pub trait KayaRecord: KayaSum {
    const SCHEMA: &'static [ValueType];
    fn from_values(values: &[Value]) -> Self {
        Self::from_parts(0, values)
    }
}

/// The template eliminator for a sum `T`: a record of arms, one per
/// constructor, generated by the derive (`PostCases { note: ..,
/// todo: .. }`). The struct literal is the totality check — a missing
/// arm is a missing field, at compile time — and each arm's returned
/// handles ride out in the matching field of `Out`. Declaring an arm
/// as `|_| {}` is the explicit way to render a constructor as
/// nothing. (The scene re-checks totality at declaration for the
/// bindings whose languages cannot.)
pub trait KayaCases<T: KayaSum> {
    type Out;
    #[doc(hidden)]
    fn declare(self, t: &mut Tpl<'_, '_>) -> Self::Out;
}

/// A scalar collection is the one-variant one-field case: a String
/// element, constructor 0, field 0.
impl KayaSum for String {
    const VARIANTS: &'static [&'static [ValueType]] = &[&[ValueType::Str]];
    fn variant(&self) -> u32 {
        0
    }
    fn to_values(&self) -> Record {
        vec![Value::Str(self.clone())]
    }
    fn from_parts(_variant: u32, values: &[Value]) -> Self {
        <String as KayaField>::from_value(&values[0])
    }
}

impl KayaRecord for String {
    const SCHEMA: &'static [ValueType] = &[ValueType::Str];
}

/// A record type with a generated patch builder — one typed setter per
/// field, each lowering to update_field. Derived by record!; the
/// builder type is the record's name plus `Patch`.
pub trait KayaPatch: KayaRecord {
    /// The generated builder, holding the transaction borrow.
    type Builder<'t, 'c>
    where
        'c: 't;
    #[doc(hidden)]
    fn patch_builder<'t, 'c>(
        tx: &'t mut Tx<'c>,
        instance: &Collection<Self>,
        key: Value,
    ) -> Self::Builder<'t, 'c>;
}

impl<T: KayaPatch> Collection<T> {
    /// Typed field writes with the key spelled once:
    /// `todos.patch(tx, key).done(true).title("x")`.
    pub fn patch<'t, 'c>(&self, tx: &'t mut Tx<'c>, key: impl Into<Value>) -> T::Builder<'t, 'c> {
        T::patch_builder(tx, self, key.into())
    }
}

/// One instance of a collection: the table inside the stamped copy
/// selected by `path` (the empty path for a live-zone collection).
/// Entries keep insertion order, matching the core's rendering; values
/// are wire-shaped records, parsed to the element type on read.
#[derive(Clone, Debug)]
struct Instance {
    path: Vec<Value>,
    /// (key, variant, fields): the discriminant rides with the record,
    /// so first/last queries and refined accessors read the same fold
    /// the core holds.
    entries: Vec<(Value, u32, Record)>,
}

/// A collection instance handle, typed by its element: the collection
/// plus the key path selecting one stamped copy's table.
/// `tx.collection::<T>()` returns the root (empty-path, live-zone)
/// handle; `at(key)` steps into a copy, one key per enclosing For.
/// Mutations and reads take the handle, so the target is spelled once
/// and record/handle agreement is a type, not a convention.
#[derive(Debug)]
pub struct Collection<T: KayaSum = String> {
    id: CollectionId,
    path: Vec<Value>,
    _element: PhantomData<T>,
}

// Derived Clone would require T: Clone on the handle itself; the handle
// clones regardless of the element.
impl<T: KayaSum> Clone for Collection<T> {
    fn clone(&self) -> Self {
        Collection {
            id: self.id,
            path: self.path.clone(),
            _element: PhantomData,
        }
    }
}

impl<T: KayaSum> Collection<T> {
    /// The for-statement form: `for mut row in todos.rows(&mut tx)`
    /// traces the record template — the body runs once, and the row's
    /// Drop closes the template (break- and panic-safe).
    pub fn rows<'t, 'b>(&self, tx: &'t mut Tx<'b>) -> Rows<'t, 'b> {
        assert_root(self);
        Rows {
            tx: Some(tx),
            collection: self.id,
        }
    }

    /// A signal the binding recomputes from this collection's entries
    /// after every mutation, written into the same transaction — the
    /// items-left label without any handler remembering to update it.
    /// The closure is pure presentation: entries in, one value out;
    /// the core sees an ordinary signal.
    pub fn derive<V: Into<Value>>(
        &self,
        tx: &mut Tx<'_>,
        compute: impl Fn(&[(Value, T)]) -> V + Send + Sync + 'static,
    ) -> SignalId {
        assert_root(self);
        let compute = std::sync::Arc::new(move |entries: &[(Value, u32, Record)]| {
            let typed: Vec<(Value, T)> = entries
                .iter()
                .map(|(k, variant, record)| (k.clone(), T::from_parts(*variant, record)))
                .collect();
            compute(&typed).into()
        });
        // The initial value covers the entries already present — a
        // derive declared mid-transaction still starts consistent.
        let entries: Vec<(Value, u32, Record)> = tx
            .ctx
            .model
            .borrow()
            .get(&self.id)
            .and_then(|instances| instances.iter().find(|i| i.path.is_empty()))
            .map(|i| i.entries.clone())
            .unwrap_or_default();
        let initial = compute(&entries);
        let signal = tx.signal(initial);
        tx.pending_derived.push((self.id, Derived { signal, compute }));
        signal
    }

    /// The instance of this collection inside the copy keyed by `key`
    /// of the next enclosing For; chain for deeper nesting.
    pub fn at(&self, key: impl Into<Value>) -> Collection<T> {
        let mut path = self.path.clone();
        path.push(key.into());
        Collection {
            id: self.id,
            path,
            _element: PhantomData,
        }
    }
}

/// A For binds the collection itself — its template stamps per entry
/// of every instance — so handing it an `at(...)` handle is a bug.
fn assert_root<T: KayaSum>(collection: &Collection<T>) {
    assert!(
        collection.path.is_empty(),
        "kaya: for_each binds the collection itself, not an instance — drop the at(...)"
    );
}

/// One derived signal: recomputed from its collection's entries after
/// every mutation, written into the same transaction. The compute is
/// wire-level; Collection::derive wraps the typed closure once.
#[derive(Clone)]
struct Derived {
    signal: SignalId,
    // Arc, not Rc: AppCtx crosses into the app thread once at spawn,
    // so every field must be Send (and Arc<T>: Send wants T: Sync).
    compute: std::sync::Arc<dyn Fn(&[(Value, u32, Record)]) -> Value + Send + Sync>,
}

pub struct AppCtx {
    pub(crate) occurrences: Receiver<Occurrence>,
    pub(crate) transactions: Sender<Transaction>,
    next_signal: Cell<u64>,
    next_widget: Cell<u64>,
    next_collection: Cell<u64>,
    next_node: Cell<u64>,
    model: RefCell<HashMap<CollectionId, Vec<Instance>>>,
    // Collections declared inside a For's template: removing a parent
    // entry tears down the copy and every instance inside it, so the
    // model needs the same edge to purge along.
    children: RefCell<HashMap<CollectionId, Vec<CollectionId>>>,
    open_fors: RefCell<Vec<CollectionId>>,
    derived: RefCell<HashMap<CollectionId, Vec<Derived>>>,
}

impl AppCtx {
    pub(crate) fn new(occurrences: Receiver<Occurrence>, transactions: Sender<Transaction>) -> Self {
        AppCtx {
            occurrences,
            transactions,
            next_signal: Cell::new(1),
            next_widget: Cell::new(1),
            next_collection: Cell::new(1),
            next_node: Cell::new(1),
            model: RefCell::new(HashMap::new()),
            children: RefCell::new(HashMap::new()),
            open_fors: RefCell::new(Vec::new()),
            derived: RefCell::new(HashMap::new()),
        }
    }

    /// Block until the next occurrence arrives. A disconnected channel
    /// means the core is shutting down, which is an occurrence, not an
    /// error.
    pub fn next(&self) -> Occurrence {
        self.occurrences.recv().unwrap_or(Occurrence::Shutdown)
    }

    /// Start a transaction: a batch of records applied atomically when
    /// committed. Ids are allocated here — a monotonic counter per space,
    /// unique by construction.
    /// Run `body` in a fresh transaction and commit it on return —
    /// the closure-scoped form of begin/commit, and the body's result
    /// comes back out (the way a build's handles reach the occurrence
    /// loop). A panic inside the body abandons the transaction before
    /// the unwind continues: commit is never reached, and Tx's Drop
    /// rolls the model mirrors back.
    pub fn apply<R>(&self, body: impl FnOnce(&mut Tx<'_>) -> R) -> R {
        let mut tx = self.begin();
        let out = body(&mut tx);
        tx.commit();
        out
    }

    pub fn begin(&self) -> Tx<'_> {
        Tx {
            ctx: self,
            ops: Vec::new(),
            journal: Vec::new(),
            pending_derived: Vec::new(),
            parents: Vec::new(),
            committed: false,
        }
    }

    fn alloc_signal(&self) -> SignalId {
        let id = self.next_signal.get();
        self.next_signal.set(id + 1);
        SignalId(id)
    }

    fn alloc_widget(&self) -> WidgetId {
        let id = self.next_widget.get();
        self.next_widget.set(id + 1);
        WidgetId(id)
    }

    fn alloc_collection(&self) -> CollectionId {
        let id = self.next_collection.get();
        self.next_collection.set(id + 1);
        CollectionId(id)
    }

    fn alloc_node(&self) -> TemplateNodeId {
        let id = self.next_node.get();
        self.next_node.set(id + 1);
        TemplateNodeId(id)
    }

    /// A collection declared inside a For's template is torn down with
    /// its copies: record the edge so the model purges along it.
    fn register_collection(&self, id: CollectionId) {
        if let Some(&parent) = self.open_fors.borrow().last() {
            self.children.borrow_mut().entry(parent).or_default().push(id);
        }
    }
}

/// A transaction under construction. Everything queues locally; commit
/// sends the batch and rings the doorbell once. Dropping a Tx without
/// committing abandons its records — and rolls the model back with
/// them, so reads never show writes that were never sent.
pub struct Tx<'a> {
    ctx: &'a AppCtx,
    ops: Vec<TxOp>,
    // How to undo this transaction's model edits: a snapshot per
    // touched collection, taken on first touch.
    journal: Vec<(CollectionId, Vec<Instance>)>,
    // Deriveds registered in this transaction: promoted to the app
    // registry at commit, abandoned with an aborted Tx (their signals
    // were never created).
    pending_derived: Vec<(CollectionId, Derived)>,
    // The ambient parent stack: containers push their id around their
    // body, constructors parent to the top, and 0 is the template-root
    // sentinel (template bodies root themselves; a cross-zone
    // add_child is structurally impossible). No ambient statics — the
    // &mut Tx threading is the ambience, the egui shape.
    parents: Vec<u64>,
    committed: bool,
}

impl Drop for Tx<'_> {
    fn drop(&mut self) {
        if !self.committed {
            let mut model = self.ctx.model.borrow_mut();
            for (id, snapshot) in self.journal.drain(..).rev() {
                model.insert(id, snapshot);
            }
        }
    }
}

impl Tx<'_> {
    fn touch(&mut self, collection: CollectionId) {
        if !self.journal.iter().any(|(c, _)| *c == collection) {
            let snapshot = self
                .ctx
                .model
                .borrow()
                .get(&collection)
                .cloned()
                .unwrap_or_default();
            self.journal.push((collection, snapshot));
        }
    }

    fn model_set(
        &mut self,
        collection: CollectionId,
        path: &[Value],
        key: &Value,
        variant: u32,
        record: &[Value],
    ) {
        self.touch(collection);
        let mut model = self.ctx.model.borrow_mut();
        let instances = model.entry(collection).or_default();
        let instance = match instances.iter_mut().position(|i| i.path == path) {
            Some(at) => &mut instances[at],
            None => {
                instances.push(Instance {
                    path: path.to_vec(),
                    entries: Vec::new(),
                });
                instances.last_mut().expect("just pushed")
            }
        };
        match instance.entries.iter_mut().find(|(k, _, _)| k == key) {
            Some((_, v, r)) => {
                *v = variant;
                *r = record.to_vec();
            }
            None => instance.entries.push((key.clone(), variant, record.to_vec())),
        }
    }

    fn model_set_field(
        &mut self,
        collection: CollectionId,
        path: &[Value],
        key: &Value,
        field: u32,
        value: &Value,
    ) {
        self.touch(collection);
        let mut model = self.ctx.model.borrow_mut();
        let record = model
            .get_mut(&collection)
            .and_then(|instances| instances.iter_mut().find(|i| i.path == path))
            .and_then(|i| i.entries.iter_mut().find(|(k, _, _)| k == key))
            .map(|(_, _, record)| record)
            .unwrap_or_else(|| panic!("kaya: update_field of missing key {key:?}"));
        record[field as usize] = value.clone();
    }

    /// Recompute every derived signal rooted at this collection and
    /// write each into this transaction. Runs after each mutation of
    /// the live-zone instance (deriveds are declared on root handles,
    /// so nested-instance mutations cannot change their input).
    fn recompute_derived(&mut self, collection: CollectionId) {
        let entries: Vec<(Value, u32, Record)> = self
            .ctx
            .model
            .borrow()
            .get(&collection)
            .and_then(|instances| instances.iter().find(|i| i.path.is_empty()))
            .map(|i| i.entries.clone())
            .unwrap_or_default();
        let mut derived: Vec<Derived> = self
            .ctx
            .derived
            .borrow()
            .get(&collection)
            .cloned()
            .unwrap_or_default();
        derived.extend(
            self.pending_derived
                .iter()
                .filter(|(c, _)| *c == collection)
                .map(|(_, d)| d.clone()),
        );
        for d in derived {
            let value = (d.compute)(&entries);
            self.ops.push(TxOp::WriteSignal { id: d.signal, value });
        }
    }

    fn model_remove(&mut self, collection: CollectionId, path: &[Value], key: &Value) {
        self.touch(collection);
        if let Some(instance) = self
            .ctx
            .model
            .borrow_mut()
            .get_mut(&collection)
            .and_then(|instances| instances.iter_mut().find(|i| i.path == path))
        {
    instance.entries.retain(|(k, _, _)| k != key);
        }
        // The core tears down the copy, taking descendant collection
        // instances with it; the model follows.
        let mut prefix = path.to_vec();
        prefix.push(key.clone());
        self.purge_children(collection, &prefix);
    }

    fn purge_children(&mut self, collection: CollectionId, prefix: &[Value]) {
        let kids = self
            .ctx
            .children
            .borrow()
            .get(&collection)
            .cloned()
            .unwrap_or_default();
        for kid in kids {
            self.touch(kid);
            if let Some(instances) = self.ctx.model.borrow_mut().get_mut(&kid) {
                instances.retain(|i| {
                    i.path.len() < prefix.len() || i.path[..prefix.len()] != *prefix
                });
            }
            self.purge_children(kid, prefix);
        }
    }

    /// The model: what this guest wrote, exactly — the fold of every
    /// committed patch plus this transaction's own, in insertion order,
    /// parsed to the element type on the way out.
    pub fn items<T: KayaSum>(&self, instance: &Collection<T>) -> Vec<(Value, T)> {
        self.ctx
            .model
            .borrow()
            .get(&instance.id)
            .and_then(|instances| instances.iter().find(|i| i.path == instance.path))
            .map(|i| {
                i.entries
                    .iter()
                    .map(|(k, variant, record)| (k.clone(), T::from_parts(*variant, record)))
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn len<T: KayaSum>(&self, instance: &Collection<T>) -> usize {
        self.ctx
            .model
            .borrow()
            .get(&instance.id)
            .and_then(|instances| instances.iter().find(|i| i.path == instance.path))
            .map(|i| i.entries.len())
            .unwrap_or(0)
    }

    pub fn signal(&mut self, initial: impl Into<Value>) -> SignalId {
        let id = self.ctx.alloc_signal();
        self.ops.push(TxOp::CreateSignal {
            id,
            initial: initial.into(),
        });
        id
    }

    pub fn write(&mut self, signal: SignalId, value: impl Into<Value>) {
        self.ops.push(TxOp::WriteSignal {
            id: signal,
            value: value.into(),
        });
    }

    pub fn widget(&mut self, kind: WidgetKind) -> WidgetId {
        let id = self.ctx.alloc_widget();
        self.ops.push(TxOp::CreateWidget { id, kind });
        self.auto_parent(id.0);
        id
    }

    /// The current ambient parent (0 when the scope roots itself:
    /// template bodies, or no open container).
    fn current_parent(&self) -> u64 {
        self.parents.last().copied().unwrap_or(0)
    }

    fn auto_parent(&mut self, id: u64) {
        let p = self.current_parent();
        if p != 0 {
            self.ops.push(TxOp::AddChild {
                parent: WidgetId(p),
                child: WidgetId(id),
            });
        }
    }

    pub fn set(&mut self, widget: WidgetId, prop: Prop, value: impl Into<Value>) {
        self.ops.push(TxOp::SetProperty {
            widget,
            prop,
            value: PropValue::Const(value.into()),
        });
    }

    pub fn bind(&mut self, widget: WidgetId, prop: Prop, signal: SignalId) {
        self.ops.push(TxOp::SetProperty {
            widget,
            prop,
            value: PropValue::Signal(signal),
        });
    }

    pub fn add_child(&mut self, parent: WidgetId, child: WidgetId) {
        self.ops.push(TxOp::AddChild { parent, child });
    }

    /// One-shot commands: momentary verbs into widget-owned state,
    /// riding this transaction like any write — the insert and the
    /// clear beside it commit together or not at all. Fire-and-forget:
    /// no state at rest, nothing to journal, and the widget answers
    /// through its normal occurrence path (a clear arrives back as
    /// TextChanged with empty text, so the app's draft fold empties
    /// itself — never a side assignment).
    pub fn clear(&mut self, widget: WidgetId) {
        self.ops.push(TxOp::WidgetCommand {
            widget,
            command: CommandKind::Clear,
        });
    }

    /// Give the widget keyboard focus (the post-submit refocus every
    /// real form wants).
    pub fn focus(&mut self, widget: WidgetId) {
        self.ops.push(TxOp::WidgetCommand {
            widget,
            command: CommandKind::Focus,
        });
    }

    /// Construction sugar: a container takes its body as a closure
    /// (the egui shape — the &mut Tx is passed back in) and parents
    /// everything declared inside it through the ambient stack, so the
    /// build body reads as the tree and a for statement over a row
    /// trace stands between siblings. The body's result comes back
    /// beside the container — the way handles reach the occurrence
    /// loop. Handlers stay in that loop, the Rust idiom; the C guests
    /// keep the fully explicit floor.
    pub fn column<R>(&mut self, body: impl FnOnce(&mut Self) -> R) -> (WidgetId, R) {
        self.container_of(WidgetKind::Column, body)
    }

    pub fn row<R>(&mut self, body: impl FnOnce(&mut Self) -> R) -> (WidgetId, R) {
        self.container_of(WidgetKind::Row, body)
    }

    fn container_of<R>(
        &mut self,
        kind: WidgetKind,
        body: impl FnOnce(&mut Self) -> R,
    ) -> (WidgetId, R) {
        let parent = self.widget(kind);
        self.parents.push(parent.0);
        let out = body(self);
        self.parents.pop();
        (parent, out)
    }

    /// A button with its caption.
    pub fn button(&mut self, text: &str) -> WidgetId {
        let w = self.widget(WidgetKind::Button);
        self.set(w, Prop::Text, text);
        w
    }

    /// A label bound to a signal.
    pub fn label(&mut self, signal: SignalId) -> WidgetId {
        let w = self.widget(WidgetKind::Label);
        self.bind(w, Prop::Text, signal);
        w
    }

    /// A single-line text field; edits arrive in the occurrence loop.
    pub fn entry(&mut self) -> WidgetId {
        self.widget(WidgetKind::Entry)
    }

    /// A labeled checkbox; toggles arrive in the occurrence loop.
    pub fn checkbox(&mut self, text: &str) -> WidgetId {
        let w = self.widget(WidgetKind::Checkbox);
        self.set(w, Prop::Text, text);
        w
    }

    /// A slider over min..max at value; moves arrive in the
    /// occurrence loop.
    pub fn slider(&mut self, min: f64, max: f64, value: f64) -> WidgetId {
        let w = self.widget(WidgetKind::Slider);
        self.set(w, Prop::Min, min);
        self.set(w, Prop::Max, max);
        self.set(w, Prop::Value, value);
        w
    }

    /// Declare a collection of `T` records: a core-side keyed table a
    /// For renders. The element type is the schema — `T::VARIANTS`
    /// goes on the wire here (one field-type list per constructor; a
    /// record is the one-variant case), and every field access derives
    /// from the same declaration. Returns the root instance handle.
    pub fn collection<T: KayaSum>(&mut self) -> Collection<T> {
        let id = self.ctx.alloc_collection();
        self.ctx.register_collection(id);
        self.ops.push(TxOp::CreateCollection {
            id,
            variants: T::VARIANTS.iter().map(|s| s.to_vec()).collect(),
        });
        Collection {
            id,
            path: Vec::new(),
            _element: PhantomData,
        }
    }

    pub fn insert<T: KayaSum>(
        &mut self,
        instance: &Collection<T>,
        key: impl Into<Value>,
        value: impl Into<T>,
    ) {
        let value = value.into();
        let (key, variant, record) = (key.into(), value.variant(), value.to_values());
        self.model_set(instance.id, &instance.path, &key, variant, &record);
        self.ops.push(TxOp::CollectionInsert {
            id: instance.id,
            path: instance.path.clone(),
            key,
            variant,
            record,
        });
        if instance.path.is_empty() {
            self.recompute_derived(instance.id);
        }
    }

    pub fn update<T: KayaSum>(
        &mut self,
        instance: &Collection<T>,
        key: impl Into<Value>,
        value: impl Into<T>,
    ) {
        let value = value.into();
        let (key, variant, record) = (key.into(), value.variant(), value.to_values());
        self.model_set(instance.id, &instance.path, &key, variant, &record);
        self.ops.push(TxOp::CollectionUpdate {
            id: instance.id,
            path: instance.path.clone(),
            key,
            variant,
            record,
        });
        if instance.path.is_empty() {
            self.recompute_derived(instance.id);
        }
    }

    /// One field's delta: the model mutates one slot, the wire carries
    /// one value, and only bindings on that field re-resolve. The field
    /// token pins the value's type to the field's at compile time.
    pub fn update_field<T: KayaRecord, K, V>(
        &mut self,
        instance: &Collection<T>,
        key: impl Into<Value>,
        field: Field<K>,
        value: V,
    ) where
        K: ValueKind,
        V: KayaField<Kind = K>,
    {
        let (key, value) = (key.into(), value.to_value());
        self.model_set_field(instance.id, &instance.path, &key, field.index, &value);
        self.ops.push(TxOp::CollectionUpdateField {
            id: instance.id,
            path: instance.path.clone(),
            key,
            // A product's witnessed discriminant is always 0: the
            // one-constructor match is trivial.
            variant: 0,
            field: field.index,
            value,
        });
        if instance.path.is_empty() {
            self.recompute_derived(instance.id);
        }
    }

    /// The discriminant an entry currently holds, or None for a
    /// missing key — the read the refined accessors match on.
    /// Transition code only, like items().
    pub fn variant_of<T: KayaSum>(
        &self,
        instance: &Collection<T>,
        key: &Value,
    ) -> Option<u32> {
        self.ctx
            .model
            .borrow()
            .get(&instance.id)
            .and_then(|instances| instances.iter().find(|i| i.path == instance.path))
            .and_then(|i| i.entries.iter().find(|(k, _, _)| k == key))
            .map(|(_, variant, _)| *variant)
    }

    /// One field's delta on one constructor: the update_field the
    /// derive's refined patch handles lower to, carrying the
    /// discriminant they witnessed in the match that produced them.
    /// Hidden because reaching it without that match would be exactly
    /// the unwitnessed write the surface exists to prevent.
    #[doc(hidden)]
    pub fn update_field_witnessed<T: KayaSum>(
        &mut self,
        instance: &Collection<T>,
        key: Value,
        variant: u32,
        field: u32,
        value: Value,
    ) {
        debug_assert_eq!(
            self.variant_of(instance, &key),
            Some(variant),
            "kaya: refined patch outlived its match"
        );
        self.model_set_field(instance.id, &instance.path, &key, field, &value);
        self.ops.push(TxOp::CollectionUpdateField {
            id: instance.id,
            path: instance.path.clone(),
            key,
            variant,
            field,
            value,
        });
        if instance.path.is_empty() {
            self.recompute_derived(instance.id);
        }
    }

    /// Reposition an entry before another's: order is collection data,
    /// so the model reorders and the wire carries the same keys-only
    /// delta. Anchor semantics match the protocol: keys, never indices.
    /// A missing key or anchor fails here, at the call site — the same
    /// check the scene applies; moving an entry before itself is a
    /// no-op, and nothing travels.
    pub fn move_before<T: KayaSum>(
        &mut self,
        instance: &Collection<T>,
        key: impl Into<Value>,
        anchor: impl Into<Value>,
    ) {
        self.move_entry(instance, key.into(), Some(anchor.into()));
    }

    /// Reposition an entry at the end of its collection.
    pub fn move_to_end<T: KayaSum>(
        &mut self,
        instance: &Collection<T>,
        key: impl Into<Value>,
    ) {
        self.move_entry(instance, key.into(), None);
    }

    /// Reposition an entry at the front: sugar for move_before the
    /// current first key, lowering to the same wire op.
    pub fn move_to_front<T: KayaSum>(
        &mut self,
        instance: &Collection<T>,
        key: impl Into<Value>,
    ) {
        let key = key.into();
        match self.keys_of(instance.id, &instance.path).into_iter().next() {
            Some(anchor) => self.move_entry(instance, key, Some(anchor)),
            None => panic!("kaya: move of missing key {key:?}"),
        }
    }

    /// Reposition an entry directly after another's: sugar for
    /// move_before the anchor's successor (move_to_end when the anchor
    /// is last), lowering to the same wire op.
    pub fn move_after<T: KayaSum>(
        &mut self,
        instance: &Collection<T>,
        key: impl Into<Value>,
        anchor: impl Into<Value>,
    ) {
        let key = key.into();
        let anchor = anchor.into();
        let keys = self.keys_of(instance.id, &instance.path);
        assert!(keys.contains(&key), "kaya: move of missing key {key:?}");
        let at = keys
            .iter()
            .position(|k| k == &anchor)
            .unwrap_or_else(|| panic!("kaya: move after missing key {anchor:?}"));
        if key == anchor {
            return;
        }
        match keys.get(at + 1) {
            // Already directly after the anchor: order unchanged.
            Some(succ) if *succ == key => {}
            Some(succ) => {
                let succ = succ.clone();
                self.move_entry(instance, key, Some(succ));
            }
            None => self.move_entry(instance, key, None),
        }
    }

    fn move_entry<T: KayaSum>(
        &mut self,
        instance: &Collection<T>,
        key: Value,
        before: Option<Value>,
    ) {
        if before.as_ref() == Some(&key) {
            // Moving before itself: order unchanged and nothing
            // travels — but the key must exist, the check the scene
            // would make.
            assert!(
                self.keys_of(instance.id, &instance.path).contains(&key),
                "kaya: move of missing key {key:?}"
            );
            return;
        }
        self.model_move(instance.id, &instance.path, &key, before.as_ref());
        self.ops.push(TxOp::CollectionMove {
            id: instance.id,
            path: instance.path.clone(),
            key,
            before,
        });
        if instance.path.is_empty() {
            self.recompute_derived(instance.id);
        }
    }

    fn keys_of(&self, collection: CollectionId, path: &[Value]) -> Vec<Value> {
        self.ctx
            .model
            .borrow()
            .get(&collection)
            .and_then(|instances| instances.iter().find(|i| i.path == path))
            .map(|i| i.entries.iter().map(|(k, _, _)| k.clone()).collect())
            .unwrap_or_default()
    }

    fn model_move(
        &mut self,
        collection: CollectionId,
        path: &[Value],
        key: &Value,
        before: Option<&Value>,
    ) {
        self.touch(collection);
        let mut model = self.ctx.model.borrow_mut();
        let instance = model
            .get_mut(&collection)
            .and_then(|instances| instances.iter_mut().find(|i| i.path == path))
            .unwrap_or_else(|| panic!("kaya: move of missing key {key:?}"));
        // The same checks the scene makes, made where the guest can
        // see the stack: a missing key or anchor is a guest bug, never
        // a fallback. Both validated before anything mutates.
        let pos = instance
            .entries
            .iter()
            .position(|(k, _, _)| k == key)
            .unwrap_or_else(|| panic!("kaya: move of missing key {key:?}"));
        if let Some(anchor) = before {
            assert!(
                instance.entries.iter().any(|(k, _, _)| k == anchor),
                "kaya: move before missing key {anchor:?}"
            );
        }
        let entry = instance.entries.remove(pos);
        let at = match before {
            Some(anchor) => instance
                .entries
                .iter()
                .position(|(k, _, _)| k == anchor)
                .expect("anchor presence checked above"),
            None => instance.entries.len(),
        };
        instance.entries.insert(at, entry);
    }

    pub fn remove<T: KayaSum>(&mut self, instance: &Collection<T>, key: impl Into<Value>) {
        let key = key.into();
        self.model_remove(instance.id, &instance.path, &key);
        self.ops.push(TxOp::CollectionRemove {
            id: instance.id,
            path: instance.path.clone(),
            key,
        });
        if instance.path.is_empty() {
            self.recompute_derived(instance.id);
        }
    }

    /// A For over `collection`: the closure declares the template — a
    /// blueprint stamped once per entry, rendering nothing by itself.
    /// Returns the For's widget id (a container in the live tree)
    /// alongside the body's result — the way handles declared inside
    /// the template (nested collections, buttons) reach the handlers.
    pub fn for_each<T: KayaSum, R>(
        &mut self,
        collection: &Collection<T>,
        body: impl FnOnce(&mut Tpl<'_, '_>) -> R,
    ) -> (WidgetId, R) {
        assert_root(collection);
        let id = self.ctx.alloc_widget();
        // The For parents into the enclosing scope, but the record
        // must land after template_end — an add_child inside the
        // blueprint would cross zones.
        let parent = self.current_parent();
        self.ops.push(TxOp::CreateFor {
            id: id.0,
            collection: collection.id,
        });
        self.ctx.open_fors.borrow_mut().push(collection.id);
        self.parents.push(0);
        let out = body(&mut Tpl { tx: self });
        self.parents.pop();
        self.ctx.open_fors.borrow_mut().pop();
        self.ops.push(TxOp::TemplateEnd);
        if parent != 0 {
            self.ops.push(TxOp::AddChild {
                parent: WidgetId(parent),
                child: WidgetId(id.0),
            });
        }
        (id, out)
    }

    /// A For over a sum eliminates it: the cases record declares one
    /// blueprint per constructor, and the compiler holds the record to
    /// totality the way a match holds its arms. Each arm's handles come
    /// back in the Out record's matching field.
    pub fn for_each_sum<T: KayaSum, C: KayaCases<T>>(
        &mut self,
        collection: &Collection<T>,
        cases: C,
    ) -> (WidgetId, C::Out) {
        self.for_each(collection, |t| cases.declare(t))
    }

    /// A When over a Bool signal: stamps its template on true, unstamps
    /// on false. Returns the When's widget id alongside the body's
    /// result.
    pub fn when<R>(
        &mut self,
        signal: SignalId,
        body: impl FnOnce(&mut Tpl<'_, '_>) -> R,
    ) -> (WidgetId, R) {
        let id = self.ctx.alloc_widget();
        let parent = self.current_parent();
        self.ops.push(TxOp::CreateWhen { id: id.0, signal });
        self.parents.push(0);
        let out = body(&mut Tpl { tx: self });
        self.parents.pop();
        self.ops.push(TxOp::TemplateEnd);
        if parent != 0 {
            self.ops.push(TxOp::AddChild {
                parent: WidgetId(parent),
                child: WidgetId(id.0),
            });
        }
        (id, out)
    }

    /// Mount into the default window; per-window targets arrive with the
    /// window vocabulary.
    pub fn mount(&mut self, root: WidgetId) {
        self.ops.push(TxOp::Mount {
            window: DEFAULT_WINDOW,
            root,
        });
    }

    /// Send the batch and wake the main loop to apply it. The model
    /// edits stand: they are exactly what was sent.
    pub fn commit(mut self) {
        for (collection, derived) in self.pending_derived.drain(..) {
            self.ctx.derived.borrow_mut().entry(collection).or_default().push(derived);
        }
        self.committed = true;
        let ops = std::mem::take(&mut self.ops);
        if self.ctx.transactions.send(ops).is_ok() {
            #[cfg(any(
                target_os = "macos",
                target_os = "windows",
                target_os = "linux",
                target_os = "ios",
                target_os = "android"
            ))]
            crate::backend::ring_doorbell();
        }
    }
}

/// A template body under declaration: the same creation vocabulary, but
/// ids come from the template-node space and nothing renders until data
/// stamps the blueprint. Occurrences from stamped copies name these node
/// ids plus the copy's key path.
/// The for-statement tracer over a collection's rows: `for mut row in
/// todos.rows(&mut tx)` opens the For template on the single yielded
/// element — the loop body runs once, authoring the blueprint — and
/// the row's Drop closes the template and parents the For into the
/// enclosing container scope. RAII makes the close structural: break-
/// and panic-safe, and while the row lives the transaction is
/// statically unreachable except through it — the template-zone
/// discipline enforced by the borrow checker.
pub struct Rows<'t, 'b> {
    tx: Option<&'t mut Tx<'b>>,
    collection: CollectionId,
}

impl<'t, 'b> Iterator for Rows<'t, 'b> {
    type Item = Row<'t, 'b>;

    fn next(&mut self) -> Option<Row<'t, 'b>> {
        let tx = self.tx.take()?;
        let id = tx.ctx.alloc_widget();
        let parent = tx.current_parent();
        tx.ops.push(TxOp::CreateFor {
            id: id.0,
            collection: self.collection,
        });
        tx.ctx.open_fors.borrow_mut().push(self.collection);
        tx.parents.push(0);
        Some(Row {
            tx: Some(tx),
            for_id: id.0,
            parent,
        })
    }
}

/// One traced row: the template surface, borrowed out of the
/// transaction for exactly the loop body's extent.
pub struct Row<'t, 'b> {
    tx: Option<&'t mut Tx<'b>>,
    for_id: u64,
    parent: u64,
}

impl<'b> Row<'_, 'b> {
    fn tpl(&mut self) -> Tpl<'_, 'b> {
        Tpl {
            tx: self.tx.as_mut().expect("kaya: row used after close"),
        }
    }

    pub fn widget(&mut self, kind: WidgetKind) -> TemplateNodeId {
        self.tpl().widget(kind)
    }

    pub fn label(&mut self, src: impl Into<TplSource<StrKind>>) -> TemplateNodeId {
        self.tpl().label(src)
    }

    pub fn checkbox(&mut self, src: impl Into<TplSource<BoolKind>>) -> TemplateNodeId {
        self.tpl().checkbox(src)
    }

    pub fn row<R>(&mut self, body: impl FnOnce(&mut Tpl<'_, 'b>) -> R) -> (TemplateNodeId, R) {
        self.tpl().row(body)
    }

    pub fn column<R>(&mut self, body: impl FnOnce(&mut Tpl<'_, 'b>) -> R) -> (TemplateNodeId, R) {
        self.tpl().column(body)
    }
}

impl Drop for Row<'_, '_> {
    fn drop(&mut self) {
        if let Some(tx) = self.tx.take() {
            tx.parents.pop();
            tx.ctx.open_fors.borrow_mut().pop();
            tx.ops.push(TxOp::TemplateEnd);
            if self.parent != 0 {
                tx.ops.push(TxOp::AddChild {
                    parent: WidgetId(self.parent),
                    child: WidgetId(self.for_id),
                });
            }
        }
    }
}

/// The Msg tier: a compile-total eliminator over the app's event
/// vocabulary — the occurrence-side twin of the sum eliminators. The
/// guest declares its meaning enum, registers each widget's mapping
/// beside the widget (an enum tuple constructor is already a mapper:
/// `msgs.on_change(field, Msg::Draft)`), and folds one exhaustive
/// match. The registry converts runtime identity into the enum's tag —
/// `match` dispatches on tags — so the loop needs no guards; and a
/// declared variant no widget produces trips rustc's dead_code lint
/// ("variant is never constructed"). Unmapped occurrences fold into
/// nothing; Shutdown ends the stream. The raw loop over
/// `ctx.next()` stays the floor.
pub struct Messages<M> {
    // Widget ids and template-node ids collide numerically — two id
    // spaces, two tables.
    widgets: RefCell<HashMap<u64, Mapper<M>>>,
    nodes: RefCell<HashMap<u64, Mapper<M>>>,
}

type Mapper<M> = Box<dyn Fn(&Occurrence) -> Option<M>>;

impl<M> Default for Messages<M> {
    fn default() -> Self {
        Self::new()
    }
}

impl<M> Messages<M> {
    pub fn new() -> Self {
        Messages {
            widgets: RefCell::new(HashMap::new()),
            nodes: RefCell::new(HashMap::new()),
        }
    }

    /// A click means this message (cloned per fire).
    pub fn on_click(&self, w: WidgetId, msg: M)
    where
        M: Clone + 'static,
    {
        self.widgets.borrow_mut().insert(
            w.0,
            Box::new(move |occ| match occ {
                Occurrence::ButtonClicked { .. } => Some(msg.clone()),
                _ => None,
            }),
        );
    }

    /// An edit maps through `f` — an enum tuple constructor fits:
    /// `msgs.on_change(field, Msg::Draft)`.
    pub fn on_change(&self, w: WidgetId, f: impl Fn(String) -> M + 'static) {
        self.widgets.borrow_mut().insert(
            w.0,
            Box::new(move |occ| match occ {
                Occurrence::TextChanged { text, .. } => Some(f(text.clone())),
                _ => None,
            }),
        );
    }

    pub fn on_toggle(&self, w: WidgetId, f: impl Fn(bool) -> M + 'static) {
        self.widgets.borrow_mut().insert(
            w.0,
            Box::new(move |occ| match occ {
                Occurrence::Toggled { checked, .. } => Some(f(*checked)),
                _ => None,
            }),
        );
    }

    pub fn on_value(&self, w: WidgetId, f: impl Fn(f64) -> M + 'static) {
        self.widgets.borrow_mut().insert(
            w.0,
            Box::new(move |occ| match occ {
                Occurrence::ValueChanged { value, .. } => Some(f(*value)),
                _ => None,
            }),
        );
    }

    /// The template flavors: stamped-copy occurrences carry the key
    /// path naming the copy, outermost first.
    pub fn on_click_node(&self, n: TemplateNodeId, f: impl Fn(Path) -> M + 'static) {
        self.nodes.borrow_mut().insert(
            n.0,
            Box::new(move |occ| match occ {
                Occurrence::InstanceButtonClicked { path, .. } => Some(f(path.clone())),
                _ => None,
            }),
        );
    }

    pub fn on_change_node(&self, n: TemplateNodeId, f: impl Fn(Path, String) -> M + 'static) {
        self.nodes.borrow_mut().insert(
            n.0,
            Box::new(move |occ| match occ {
                Occurrence::InstanceTextChanged { path, text, .. } => {
                    Some(f(path.clone(), text.clone()))
                }
                _ => None,
            }),
        );
    }

    pub fn on_toggle_node(&self, n: TemplateNodeId, f: impl Fn(Path, bool) -> M + 'static) {
        self.nodes.borrow_mut().insert(
            n.0,
            Box::new(move |occ| match occ {
                Occurrence::InstanceToggled { path, checked, .. } => {
                    Some(f(path.clone(), *checked))
                }
                _ => None,
            }),
        );
    }

    pub fn on_value_node(&self, n: TemplateNodeId, f: impl Fn(Path, f64) -> M + 'static) {
        self.nodes.borrow_mut().insert(
            n.0,
            Box::new(move |occ| match occ {
                Occurrence::InstanceValueChanged { path, value, .. } => {
                    Some(f(path.clone(), *value))
                }
                _ => None,
            }),
        );
    }

    /// The mapped occurrence stream: blocks for the next occurrence
    /// with a registered meaning. Unmapped occurrences fold into
    /// nothing; None is Shutdown — `while let Some(msg) = msgs.next(&ctx)`.
    pub fn next(&self, ctx: &AppCtx) -> Option<M> {
        loop {
            let occ = ctx.next();
            let mapped = match &occ {
                Occurrence::Shutdown => return None,
                Occurrence::ButtonClicked { id }
                | Occurrence::TextChanged { id, .. }
                | Occurrence::Toggled { id, .. }
                | Occurrence::ValueChanged { id, .. } => {
                    self.widgets.borrow().get(&id.0).and_then(|f| f(&occ))
                }
                Occurrence::InstanceButtonClicked { node, .. }
                | Occurrence::InstanceTextChanged { node, .. }
                | Occurrence::InstanceToggled { node, .. }
                | Occurrence::InstanceValueChanged { node, .. } => {
                    self.nodes.borrow().get(&node.0).and_then(|f| f(&occ))
                }
            };
            if let Some(m) = mapped {
                return Some(m);
            }
        }
    }
}

pub struct Tpl<'a, 'b> {
    tx: &'a mut Tx<'b>,
}

impl Tpl<'_, '_> {
    pub fn widget(&mut self, kind: WidgetKind) -> TemplateNodeId {
        let id = self.tx.ctx.alloc_node();
        self.tx.ops.push(TxOp::CreateWidget {
            id: WidgetId(id.0),
            kind,
        });
        self.tx.auto_parent(id.0);
        id
    }

    pub fn set(&mut self, node: TemplateNodeId, prop: Prop, value: impl Into<Value>) {
        self.tx.ops.push(TxOp::SetProperty {
            widget: WidgetId(node.0),
            prop,
            value: PropValue::Const(value.into()),
        });
    }

    pub fn bind(&mut self, node: TemplateNodeId, prop: Prop, signal: SignalId) {
        self.tx.ops.push(TxOp::SetProperty {
            widget: WidgetId(node.0),
            prop,
            value: PropValue::Signal(signal),
        });
    }

    /// Bind a property to the element of the enclosing For, `level`
    /// Fors up (0 = nearest) — the scalar (one-field) case, field 0.
    /// Record collections bind through bind_field.
    pub fn bind_element(&mut self, node: TemplateNodeId, prop: Prop, level: u32) {
        self.tx.ops.push(TxOp::SetProperty {
            widget: WidgetId(node.0),
            prop,
            value: PropValue::Element { level, field: 0 },
        });
    }

    /// Bind a property to one field of the element of the enclosing
    /// For. The prop token and the field token share a value kind, so a
    /// Bool field on a Str property is a compile error — the earliest
    /// of the three agreeing layers (the scene re-checks at declaration,
    /// the setters at write).
    pub fn bind_field<K: ValueKind>(
        &mut self,
        node: TemplateNodeId,
        prop: PropToken<K>,
        level: u32,
        field: Field<K>,
    ) {
        self.tx.ops.push(TxOp::SetProperty {
            widget: WidgetId(node.0),
            prop: prop.prop,
            value: PropValue::Element {
                level,
                field: field.index,
            },
        });
    }

    pub fn add_child(&mut self, parent: TemplateNodeId, child: TemplateNodeId) {
        self.tx.ops.push(TxOp::AddChild {
            parent: WidgetId(parent.0),
            child: WidgetId(child.0),
        });
    }

    /// One arm boundary, emitted by the generated eliminators — the
    /// records that follow are the named constructor's blueprint.
    /// Hidden because reaching it outside a cases record would be a
    /// partial eliminator with only the scene's runtime check behind
    /// it; the record form makes the compiler hold totality.
    #[doc(hidden)]
    pub fn case_arm(&mut self, variant: u32) {
        self.tx.ops.push(TxOp::VariantCase { variant });
    }

    /// The template flavor of the container sugar: the body's
    /// constructors parent into it ambiently.
    pub fn row<R>(&mut self, body: impl FnOnce(&mut Self) -> R) -> (TemplateNodeId, R) {
        self.container_of(WidgetKind::Row, body)
    }

    pub fn column<R>(&mut self, body: impl FnOnce(&mut Self) -> R) -> (TemplateNodeId, R) {
        self.container_of(WidgetKind::Column, body)
    }

    fn container_of<R>(
        &mut self,
        kind: WidgetKind,
        body: impl FnOnce(&mut Self) -> R,
    ) -> (TemplateNodeId, R) {
        let parent = self.widget(kind);
        self.tx.parents.push(parent.0);
        let out = body(self);
        self.tx.parents.pop();
        (parent, out)
    }

    /// A label bound to any addressable source: a constant, a signal,
    /// or a field of the enclosing element.
    pub fn label(&mut self, src: impl Into<TplSource<StrKind>>) -> TemplateNodeId {
        let n = self.widget(WidgetKind::Label);
        self.apply_source(n, Prop::Text, src.into().inner);
        n
    }

    /// A checkbox bound to any addressable source.
    pub fn checkbox(&mut self, src: impl Into<TplSource<BoolKind>>) -> TemplateNodeId {
        let n = self.widget(WidgetKind::Checkbox);
        self.apply_source(n, Prop::Checked, src.into().inner);
        n
    }

    fn apply_source(&mut self, node: TemplateNodeId, prop: Prop, src: SourceInner) {
        let value = match src {
            SourceInner::Const(v) => PropValue::Const(v),
            SourceInner::Signal(s) => PropValue::Signal(s),
            SourceInner::Field(field) => PropValue::Element { level: 0, field },
        };
        self.tx.ops.push(TxOp::SetProperty {
            widget: WidgetId(node.0),
            prop,
            value,
        });
    }

    /// Declare a collection inside the template: each stamped copy gets
    /// its own instance, addressed via `at(key)` on the returned root
    /// handle. Return it from the template body so handlers can reach
    /// it — for_each hands the body's result back out.
    pub fn collection<T: KayaSum>(&mut self) -> Collection<T> {
        let id = self.tx.ctx.alloc_collection();
        self.tx.ctx.register_collection(id);
        self.tx.ops.push(TxOp::CreateCollection {
            id,
            variants: T::VARIANTS.iter().map(|s| s.to_vec()).collect(),
        });
        Collection {
            id,
            path: Vec::new(),
            _element: PhantomData,
        }
    }

    /// A nested For; its collection must be declared in this template.
    /// Returns the For's node alongside the body's result.
    pub fn for_each<T: KayaSum, R>(
        &mut self,
        collection: &Collection<T>,
        body: impl FnOnce(&mut Tpl<'_, '_>) -> R,
    ) -> (TemplateNodeId, R) {
        assert_root(collection);
        let id = self.tx.ctx.alloc_node();
        let parent = self.tx.current_parent();
        self.tx.ops.push(TxOp::CreateFor {
            id: id.0,
            collection: collection.id,
        });
        self.tx.ctx.open_fors.borrow_mut().push(collection.id);
        self.tx.parents.push(0);
        let out = body(&mut Tpl { tx: self.tx });
        self.tx.parents.pop();
        self.tx.ctx.open_fors.borrow_mut().pop();
        self.tx.ops.push(TxOp::TemplateEnd);
        if parent != 0 {
            self.tx.ops.push(TxOp::AddChild {
                parent: WidgetId(parent),
                child: WidgetId(id.0),
            });
        }
        (id, out)
    }

    /// The nested flavor of the sum eliminator.
    pub fn for_each_sum<T: KayaSum, C: KayaCases<T>>(
        &mut self,
        collection: &Collection<T>,
        cases: C,
    ) -> (TemplateNodeId, C::Out) {
        self.for_each(collection, |t| cases.declare(t))
    }

    pub fn when<R>(
        &mut self,
        signal: SignalId,
        body: impl FnOnce(&mut Tpl<'_, '_>) -> R,
    ) -> (TemplateNodeId, R) {
        let id = self.tx.ctx.alloc_node();
        let parent = self.tx.current_parent();
        self.tx.ops.push(TxOp::CreateWhen { id: id.0, signal });
        self.tx.parents.push(0);
        let out = body(&mut Tpl { tx: self.tx });
        self.tx.parents.pop();
        self.tx.ops.push(TxOp::TemplateEnd);
        if parent != 0 {
            self.tx.ops.push(TxOp::AddChild {
                parent: WidgetId(parent),
                child: WidgetId(id.0),
            });
        }
        (id, out)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;

    use super::{AppCtx, KayaRecord, KayaSum, Tx};
    use crate::protocol::{Value, ValueType};
    use kaya_derive::KayaGen;

    #[derive(KayaGen, Clone, Debug, PartialEq)]
    struct Todo {
        title: String,
        done: bool,
    }

    /// One declaration drives all three: the schema, the conversions,
    /// and the field tokens — none can drift from the others.
    #[test]
    fn record_derives_schema_conversions_and_tokens() {
        assert_eq!(Todo::SCHEMA, &[ValueType::Str, ValueType::Bool]);
        let todo = Todo { title: "buy milk".into(), done: false };
        let values = todo.to_values();
        assert_eq!(values, vec![Value::from("buy milk"), Value::Bool(false)]);
        assert_eq!(Todo::from_values(&values), todo);
        assert_eq!(Todo::title().index, 0);
        assert_eq!(Todo::done().index, 1);
    }

    /// A command is one pushed op — pure wire data, no model state —
    /// and an abandoned transaction ships none of them: the ops vector
    /// dies with the Tx, which is the whole rollback story for
    /// commands ("insert + clear" aborting must not clear the field
    /// either, since the two were promised as atomic).
    #[test]
    fn commands_push_ops_and_die_with_an_abandoned_tx() {
        use crate::protocol::{CommandKind, TxOp, WidgetKind};

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx);

        let mut tx = ctx.begin();
        let field = tx.widget(WidgetKind::Entry);
        tx.clear(field);
        tx.focus(field);
        assert!(matches!(
            tx.ops[tx.ops.len() - 2],
            TxOp::WidgetCommand { command: CommandKind::Clear, .. }
        ));
        assert!(matches!(
            tx.ops[tx.ops.len() - 1],
            TxOp::WidgetCommand { command: CommandKind::Focus, .. }
        ));
        drop(tx); // abandoned: nothing may ship
        assert!(tx_rx.try_recv().is_err(), "an abandoned tx shipped its records");
    }

    /// A patch is recorded writes: each setter emits exactly one
    /// update_field op and mutates one model slot — no whole-record
    /// travel, no diff.
    #[test]
    fn patch_records_typed_field_writes() {
        use crate::protocol::TxOp;

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx);

        let mut tx = ctx.begin();
        let todos = tx.collection::<Todo>();
        tx.insert(&todos, "a", Todo { title: "milk".into(), done: false });
        let ops_before = tx.ops.len();

        todos.patch(&mut tx, "a").done(true).title("oat milk");

        let field_writes: Vec<_> = tx.ops[ops_before..]
            .iter()
            .map(|op| match op {
                TxOp::CollectionUpdateField { field, value, .. } => (*field, value.clone()),
                other => panic!("patch lowered to {other:?}, not update_field"),
            })
            .collect();
        assert_eq!(
            field_writes,
            vec![(1, Value::Bool(true)), (0, Value::from("oat milk"))]
        );
        assert_eq!(
            tx.items(&todos),
            vec![(Value::from("a"), Todo { title: "oat milk".into(), done: true })]
        );
    }

    /// A move is a keyed reposition: the model reorders (items reads
    /// the new order back) and the wire carries the same keys-only
    /// delta. The sugar verbs (front, after) lower to the same op, and
    /// order-preserving calls are no-ops that ship nothing — mirroring
    /// the scene's own semantics exactly.
    #[test]
    fn move_reorders_model_and_records_keys() {
        use crate::protocol::TxOp;

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx);

        let mut tx = ctx.begin();
        let todos = tx.collection::<Todo>();
        for key in ["a", "b", "c"] {
            tx.insert(&todos, key, Todo { title: key.into(), done: false });
        }
        let keys = |tx: &Tx<'_>| -> Vec<Value> {
            tx.items(&todos).iter().map(|(k, _)| k.clone()).collect()
        };

        tx.move_to_end(&todos, "a");
        assert_eq!(keys(&tx), vec![Value::from("b"), Value::from("c"), Value::from("a")]);
        tx.move_before(&todos, "a", "b");
        assert_eq!(keys(&tx), vec![Value::from("a"), Value::from("b"), Value::from("c")]);
        tx.move_to_front(&todos, "c");
        assert_eq!(keys(&tx), vec![Value::from("c"), Value::from("a"), Value::from("b")]);
        match tx.ops.last() {
            // move_to_front is sugar: the wire carries the same
            // anchored move_before.
            Some(TxOp::CollectionMove { key, before, .. }) => {
                assert_eq!(key, &Value::from("c"));
                assert_eq!(before, &Some(Value::from("a")));
            }
            other => panic!("expected a collection_move, got {other:?}"),
        }
        tx.move_after(&todos, "c", "a");
        assert_eq!(keys(&tx), vec![Value::from("a"), Value::from("c"), Value::from("b")]);
        tx.move_after(&todos, "b", "c");
        assert_eq!(keys(&tx), vec![Value::from("a"), Value::from("c"), Value::from("b")]);
        tx.move_after(&todos, "b", "b");

        // Order-preserving calls are no-ops that emit nothing: the two
        // trailing move_after calls (already directly after, after
        // itself) shipped no records, and neither does moving before
        // itself or fronting the current first.
        let ops = tx.ops.len();
        tx.move_before(&todos, "a", "a");
        tx.move_to_front(&todos, "a");
        assert_eq!(tx.ops.len(), ops);
    }

    #[test]
    #[should_panic(expected = "move of missing key")]
    fn move_of_missing_key_panics() {
        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx);
        let mut tx = ctx.begin();
        let todos = tx.collection::<Todo>();
        tx.insert(&todos, "a", Todo { title: "a".into(), done: false });
        tx.move_to_end(&todos, "missing");
    }

    #[test]
    #[should_panic(expected = "move before missing key")]
    fn move_before_missing_anchor_panics() {
        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx);
        let mut tx = ctx.begin();
        let todos = tx.collection::<Todo>();
        tx.insert(&todos, "a", Todo { title: "a".into(), done: false });
        tx.move_before(&todos, "a", "missing");
    }

    /// A derived signal recomputes from the collection after every
    /// mutation, into the same transaction — and an abandoned Tx
    /// abandons its registration with its records.
    #[test]
    fn derived_signal_recomputes_per_mutation() {
        use crate::protocol::TxOp;

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx);

        let mut tx = ctx.begin();
        let todos = tx.collection::<Todo>();
        let items_left = todos.derive(&mut tx, |items| {
            let n = items.iter().filter(|(_, t)| !t.done).count();
            format!("{n} left")
        });

        let last_write = |tx: &Tx<'_>| match tx.ops.last() {
            Some(TxOp::WriteSignal { id, value }) => (id.0, value.clone()),
            other => panic!("expected a derived write, got {other:?}"),
        };

        tx.insert(&todos, "a", Todo { title: "milk".into(), done: false });
        assert_eq!(last_write(&tx), (items_left.0, Value::from("1 left")));
        todos.patch(&mut tx, "a").done(true);
        assert_eq!(last_write(&tx), (items_left.0, Value::from("0 left")));
        tx.remove(&todos, "a");
        assert_eq!(last_write(&tx), (items_left.0, Value::from("0 left")));
        tx.commit();

        // A second transaction still recomputes (the registration was
        // promoted at commit) ...
        let mut tx = ctx.begin();
        tx.insert(&todos, "b", Todo { title: "eggs".into(), done: false });
        assert_eq!(last_write(&tx), (items_left.0, Value::from("1 left")));
        tx.commit();

        // ... but a derive registered in an abandoned Tx never lands.
        let mut tx = ctx.begin();
        let _dropped = todos.derive(&mut tx, |items| items.len() as i64);
        drop(tx);
        assert_eq!(ctx.derived.borrow()[&todos.id].len(), 1);
    }

    use crate::protocol::{Occurrence, Prop, WidgetId, WidgetKind};
    use crate::scene::Scene;

    /// The Msg tier maps, skips, and ends: a registered widget's
    /// occurrence comes back as the guest's own variant, an unmapped
    /// occurrence folds into nothing, and Shutdown is None.
    #[test]
    fn messages_map_skip_and_end() {
        use super::Messages;
        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _keep) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx);

        let mut tx = ctx.begin();
        let add = tx.widget(WidgetKind::Button);
        let other = tx.widget(WidgetKind::Button);
        tx.commit();

        #[derive(Clone, Debug, PartialEq)]
        enum Msg {
            Add,
        }
        let msgs = Messages::new();
        msgs.on_click(add, Msg::Add);

        occ_tx.send(Occurrence::ButtonClicked { id: other }).unwrap();
        occ_tx.send(Occurrence::ButtonClicked { id: add }).unwrap();
        occ_tx.send(Occurrence::Shutdown).unwrap();
        assert_eq!(msgs.next(&ctx), Some(Msg::Add));
        assert_eq!(msgs.next(&ctx), None);
    }

    /// The row trace's Drop is the close: a break mid-loop still ends
    /// the template and parents the For — RAII, not a guard.
    #[test]
    fn row_trace_closes_on_break() {
        use crate::protocol::TxOp;
        let (_occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx);

        let mut tx = ctx.begin();
        let todos = tx.collection::<Todo>();
        let (root, ()) = tx.column(|tx| {
            for mut row in todos.rows(tx) {
                row.label(Todo::title());
                break; // the row drops here; Drop closes the template
            }
        });
        tx.mount(root);
        tx.commit();

        let ops = tx_rx.try_recv().expect("committed ops");
        let end = ops
            .iter()
            .position(|op| matches!(op, TxOp::TemplateEnd))
            .expect("template closed despite the break");
        // The For's add_child lands after template_end (the cross-zone
        // rule), parenting it into the column.
        assert!(
            ops[end..].iter().any(|op| matches!(
                op,
                TxOp::AddChild { parent, .. } if *parent == root
            )),
            "the For parented into the enclosing container"
        );
    }

    /// The round trip minus any backend: the app builds the milestone-1
    /// scene, an occurrence reaches it, and the answering write resolves
    /// through the scene into the label's property set.
    #[test]
    fn occurrence_to_resolved_set_round_trip() {
        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx);

        let app = std::thread::spawn(move || {
            let mut tx = ctx.begin();
            let text = tx.signal("Clicked 0 times");
            let column = tx.widget(WidgetKind::Column);
            let button = tx.widget(WidgetKind::Button);
            tx.set(button, Prop::Text, "Click me");
            let label = tx.widget(WidgetKind::Label);
            tx.bind(label, Prop::Text, text);
            tx.add_child(column, button);
            tx.add_child(column, label);
            tx.mount(column);
            tx.commit();

            let mut count = 0u64;
            loop {
                match ctx.next() {
                    Occurrence::ButtonClicked { .. } => {
                        count += 1;
                        let mut tx = ctx.begin();
                        tx.write(text, format!("Clicked {count} times"));
                        tx.commit();
                    }
                    Occurrence::InstanceButtonClicked { .. } => {}
                    Occurrence::TextChanged { .. }
                    | Occurrence::InstanceTextChanged { .. }
                    | Occurrence::Toggled { .. }
                    | Occurrence::InstanceToggled { .. }
                    | Occurrence::ValueChanged { .. }
                    | Occurrence::InstanceValueChanged { .. } => {}
                    Occurrence::Shutdown => break,
                }
            }
        });

        // Play the core's role: apply the construction, click twice,
        // apply the writes, and check the label's resolved text.
        let mut scene = Scene::new();
        let construction = tx_rx.recv().unwrap();
        let ops = scene.apply(construction);
        assert!(ops.len() >= 8);

        occ_tx.send(Occurrence::ButtonClicked { id: WidgetId(2) }).unwrap();
        occ_tx.send(Occurrence::ButtonClicked { id: WidgetId(2) }).unwrap();

        let _ = scene.apply(tx_rx.recv().unwrap());
        let last = scene.apply(tx_rx.recv().unwrap());
        match &last[..] {
            [crate::protocol::ApplyOp::SetProp { value, .. }] => {
                assert_eq!(*value, crate::protocol::Value::from("Clicked 2 times"));
            }
            other => panic!("unexpected ops: {other:?}"),
        }

        drop(occ_tx);
        app.join().unwrap();
    }

    /// The patch-producing contract: reads are the fold of the patches
    /// (this transaction's included), a removed parent entry purges
    /// descendant instances, and a dropped (uncommitted) transaction
    /// rolls its model edits back. Template-declared handles escape as
    /// the template body's return value.
    #[test]
    fn collection_model_folds_purges_and_rolls_back() {
        let (_occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx);

        let mut tx = ctx.begin();
        let groups = tx.collection::<String>();
        let (_list, items) = tx.for_each(&groups, |t| t.collection::<String>());

        let g1_items = items.at("g1");
        tx.insert(&groups, "g1", "Work");
        tx.insert(&g1_items, "a", "send report");
        tx.insert(&g1_items, "b", "buy milk");
        assert_eq!(tx.len(&groups), 1);
        assert_eq!(tx.len(&g1_items), 2);
        tx.update(&g1_items, "a", "file report");
        assert_eq!(tx.items(&g1_items)[0], ("a".into(), "file report".into()));

        // Removing the group tears down its copy; the items instance
        // inside it purges along the declared-parent edge.
        tx.remove(&groups, "g1");
        assert_eq!(tx.len(&groups), 0);
        assert_eq!(tx.len(&g1_items), 0);
        tx.commit();
        let _ = tx_rx.recv().unwrap();

        // An abandoned transaction abandons its model edits too.
        {
            let mut tx = ctx.begin();
            tx.insert(&groups, "g2", "Home");
            assert_eq!(tx.len(&groups), 1);
        }
        assert_eq!(ctx.begin().len(&groups), 0);
    }

    /// The root-handle guard: a For binds the collection, never an
    /// `at(...)` instance.
    #[test]
    #[should_panic(expected = "not an instance")]
    fn for_each_rejects_instance_handles() {
        let (_occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx);
        let mut tx = ctx.begin();
        let c = tx.collection::<String>();
        let _ = tx.for_each(&c.at("g1"), |_| ());
    }
}
