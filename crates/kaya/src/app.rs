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
    CollectionId, DEFAULT_WINDOW, Occurrence, Prop, PropValue, Record, SignalId, TemplateNodeId,
    Transaction, TxOp, Value, ValueType, WidgetId, WidgetKind,
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

/// A collection element type: schema plus conversions, derived by
/// record! (or hand-written; the derive just deletes the sync
/// obligation between the three).
pub trait KayaRecord: Clone {
    const SCHEMA: &'static [ValueType];
    fn to_values(&self) -> Record;
    fn from_values(values: &[Value]) -> Self;
}

/// A scalar collection is the one-field case: a String element, field 0.
impl KayaRecord for String {
    const SCHEMA: &'static [ValueType] = &[ValueType::Str];
    fn to_values(&self) -> Record {
        vec![Value::Str(self.clone())]
    }
    fn from_values(values: &[Value]) -> Self {
        <String as KayaField>::from_value(&values[0])
    }
}

/// Declare a record type: the struct, its KayaRecord impl, and one
/// field-token fn per field (same name as the field; fns and fields
/// live in different namespaces).
///
/// ```ignore
/// kaya::record! {
///     pub struct Todo { pub title: String, pub done: bool }
/// }
/// let todos = tx.collection::<Todo>();
/// t.bind_field(check, kaya::props::CHECKED, 0, Todo::done());
/// ```
#[macro_export]
macro_rules! record {
    (
        $(#[$meta:meta])*
        $vis:vis struct $name:ident {
            $($fvis:vis $field:ident : $ty:ty),+ $(,)?
        }
    ) => {
        $(#[$meta])*
        #[derive(Clone, Debug, PartialEq)]
        $vis struct $name {
            $($fvis $field: $ty),+
        }

        impl $crate::KayaRecord for $name {
            const SCHEMA: &'static [$crate::ValueType] =
                &[$(<<$ty as $crate::KayaField>::Kind as $crate::ValueKind>::TYPE),+];

            fn to_values(&self) -> Vec<$crate::Value> {
                vec![$($crate::KayaField::to_value(&self.$field)),+]
            }

            fn from_values(values: &[$crate::Value]) -> Self {
                let mut at = 0usize;
                $(
                    let $field = <$ty as $crate::KayaField>::from_value(&values[at]);
                    at += 1;
                )+
                let _ = at;
                Self { $($field),+ }
            }
        }

        impl $name {
            $crate::__record_fields!(0u32; $($fvis $field : $ty),+);
        }

        $crate::__paste! {
            /// Typed field writes with the key spelled once; each
            /// setter records one update_field. A patch is recorded
            /// writes, never a diff — no clone, no comparison.
            #[allow(dead_code)]
            $vis struct [<$name Patch>]<'t, 'c> {
                tx: &'t mut $crate::Tx<'c>,
                instance: $crate::Collection<$name>,
                key: $crate::Value,
            }

            #[allow(dead_code)]
            impl<'t, 'c> [<$name Patch>]<'t, 'c> {
                $(
                    $fvis fn $field(self, value: impl Into<$ty>) -> Self {
                        let Self { tx, instance, key } = self;
                        tx.update_field(&instance, key.clone(), $name::$field(), value.into());
                        Self { tx, instance, key }
                    }
                )+
            }

            impl $crate::KayaPatch for $name {
                type Builder<'t, 'c> = [<$name Patch>]<'t, 'c> where 'c: 't;
                fn patch_builder<'t, 'c>(
                    tx: &'t mut $crate::Tx<'c>,
                    instance: &$crate::Collection<$name>,
                    key: $crate::Value,
                ) -> Self::Builder<'t, 'c> {
                    [<$name Patch>] { tx, instance: instance.clone(), key }
                }
            }
        }
    };
}

/// Internal: the field-token fns, indexed by position.
#[doc(hidden)]
#[macro_export]
macro_rules! __record_fields {
    ($idx:expr;) => {};
    ($idx:expr; $fvis:vis $field:ident : $ty:ty $(, $rvis:vis $rfield:ident : $rty:ty)*) => {
        $fvis fn $field() -> $crate::Field<<$ty as $crate::KayaField>::Kind> {
            $crate::Field::new($idx)
        }
        $crate::__record_fields!($idx + 1; $($rvis $rfield : $rty),*);
    };
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
    entries: Vec<(Value, Record)>,
}

/// A collection instance handle, typed by its element: the collection
/// plus the key path selecting one stamped copy's table.
/// `tx.collection::<T>()` returns the root (empty-path, live-zone)
/// handle; `at(key)` steps into a copy, one key per enclosing For.
/// Mutations and reads take the handle, so the target is spelled once
/// and record/handle agreement is a type, not a convention.
#[derive(Debug)]
pub struct Collection<T: KayaRecord = String> {
    id: CollectionId,
    path: Vec<Value>,
    _element: PhantomData<T>,
}

// Derived Clone would require T: Clone on the handle itself; the handle
// clones regardless of the element.
impl<T: KayaRecord> Clone for Collection<T> {
    fn clone(&self) -> Self {
        Collection {
            id: self.id,
            path: self.path.clone(),
            _element: PhantomData,
        }
    }
}

impl<T: KayaRecord> Collection<T> {
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
        let compute = std::sync::Arc::new(move |entries: &[(Value, Record)]| {
            let typed: Vec<(Value, T)> = entries
                .iter()
                .map(|(k, record)| (k.clone(), T::from_values(record)))
                .collect();
            compute(&typed).into()
        });
        // The initial value covers the entries already present — a
        // derive declared mid-transaction still starts consistent.
        let entries: Vec<(Value, Record)> = tx
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
fn assert_root<T: KayaRecord>(collection: &Collection<T>) {
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
    compute: std::sync::Arc<dyn Fn(&[(Value, Record)]) -> Value + Send + Sync>,
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
    pub fn begin(&self) -> Tx<'_> {
        Tx {
            ctx: self,
            ops: Vec::new(),
            journal: Vec::new(),
            pending_derived: Vec::new(),
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

    fn model_set(&mut self, collection: CollectionId, path: &[Value], key: &Value, record: &[Value]) {
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
        match instance.entries.iter_mut().find(|(k, _)| k == key) {
            Some((_, v)) => *v = record.to_vec(),
            None => instance.entries.push((key.clone(), record.to_vec())),
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
            .and_then(|i| i.entries.iter_mut().find(|(k, _)| k == key))
            .map(|(_, record)| record)
            .unwrap_or_else(|| panic!("kaya: update_field of missing key {key:?}"));
        record[field as usize] = value.clone();
    }

    /// Recompute every derived signal rooted at this collection and
    /// write each into this transaction. Runs after each mutation of
    /// the live-zone instance (deriveds are declared on root handles,
    /// so nested-instance mutations cannot change their input).
    fn recompute_derived(&mut self, collection: CollectionId) {
        let entries: Vec<(Value, Record)> = self
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
            instance.entries.retain(|(k, _)| k != key);
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
    pub fn items<T: KayaRecord>(&self, instance: &Collection<T>) -> Vec<(Value, T)> {
        self.ctx
            .model
            .borrow()
            .get(&instance.id)
            .and_then(|instances| instances.iter().find(|i| i.path == instance.path))
            .map(|i| {
                i.entries
                    .iter()
                    .map(|(k, record)| (k.clone(), T::from_values(record)))
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn len<T: KayaRecord>(&self, instance: &Collection<T>) -> usize {
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
        id
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

    /// Construction sugar: a container from its children, so the build
    /// body reads as the tree. Lowers to the same records — children
    /// were created by the caller, then the container, then the
    /// add_childs. Handlers stay in the occurrence loop, the Rust
    /// idiom; milestone2 keeps the fully explicit floor on purpose.
    pub fn column(&mut self, children: &[WidgetId]) -> WidgetId {
        self.container_of(WidgetKind::Column, children)
    }

    pub fn row(&mut self, children: &[WidgetId]) -> WidgetId {
        self.container_of(WidgetKind::Row, children)
    }

    fn container_of(&mut self, kind: WidgetKind, children: &[WidgetId]) -> WidgetId {
        let parent = self.widget(kind);
        for child in children {
            self.add_child(parent, *child);
        }
        parent
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
    /// For renders. The element type is the schema — `T::SCHEMA` goes
    /// on the wire here, and every field access derives from the same
    /// declaration. Returns the root instance handle.
    pub fn collection<T: KayaRecord>(&mut self) -> Collection<T> {
        let id = self.ctx.alloc_collection();
        self.ctx.register_collection(id);
        self.ops.push(TxOp::CreateCollection {
            id,
            schema: T::SCHEMA.to_vec(),
        });
        Collection {
            id,
            path: Vec::new(),
            _element: PhantomData,
        }
    }

    pub fn insert<T: KayaRecord>(
        &mut self,
        instance: &Collection<T>,
        key: impl Into<Value>,
        value: impl Into<T>,
    ) {
        let (key, record) = (key.into(), value.into().to_values());
        self.model_set(instance.id, &instance.path, &key, &record);
        self.ops.push(TxOp::CollectionInsert {
            id: instance.id,
            path: instance.path.clone(),
            key,
            record,
        });
        if instance.path.is_empty() {
            self.recompute_derived(instance.id);
        }
    }

    pub fn update<T: KayaRecord>(
        &mut self,
        instance: &Collection<T>,
        key: impl Into<Value>,
        value: impl Into<T>,
    ) {
        let (key, record) = (key.into(), value.into().to_values());
        self.model_set(instance.id, &instance.path, &key, &record);
        self.ops.push(TxOp::CollectionUpdate {
            id: instance.id,
            path: instance.path.clone(),
            key,
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
            field: field.index,
            value,
        });
        if instance.path.is_empty() {
            self.recompute_derived(instance.id);
        }
    }

    pub fn remove<T: KayaRecord>(&mut self, instance: &Collection<T>, key: impl Into<Value>) {
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
    pub fn for_each<T: KayaRecord, R>(
        &mut self,
        collection: &Collection<T>,
        body: impl FnOnce(&mut Tpl<'_, '_>) -> R,
    ) -> (WidgetId, R) {
        assert_root(collection);
        let id = self.ctx.alloc_widget();
        self.ops.push(TxOp::CreateFor {
            id: id.0,
            collection: collection.id,
        });
        self.ctx.open_fors.borrow_mut().push(collection.id);
        let out = body(&mut Tpl { tx: self });
        self.ctx.open_fors.borrow_mut().pop();
        self.ops.push(TxOp::TemplateEnd);
        (id, out)
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
        self.ops.push(TxOp::CreateWhen { id: id.0, signal });
        let out = body(&mut Tpl { tx: self });
        self.ops.push(TxOp::TemplateEnd);
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

    /// The template flavor of the container sugar.
    pub fn row(&mut self, children: &[TemplateNodeId]) -> TemplateNodeId {
        self.container_of(WidgetKind::Row, children)
    }

    pub fn column(&mut self, children: &[TemplateNodeId]) -> TemplateNodeId {
        self.container_of(WidgetKind::Column, children)
    }

    fn container_of(&mut self, kind: WidgetKind, children: &[TemplateNodeId]) -> TemplateNodeId {
        let parent = self.widget(kind);
        for child in children {
            self.add_child(parent, *child);
        }
        parent
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
    pub fn collection<T: KayaRecord>(&mut self) -> Collection<T> {
        let id = self.tx.ctx.alloc_collection();
        self.tx.ctx.register_collection(id);
        self.tx.ops.push(TxOp::CreateCollection {
            id,
            schema: T::SCHEMA.to_vec(),
        });
        Collection {
            id,
            path: Vec::new(),
            _element: PhantomData,
        }
    }

    /// A nested For; its collection must be declared in this template.
    /// Returns the For's node alongside the body's result.
    pub fn for_each<T: KayaRecord, R>(
        &mut self,
        collection: &Collection<T>,
        body: impl FnOnce(&mut Tpl<'_, '_>) -> R,
    ) -> (TemplateNodeId, R) {
        assert_root(collection);
        let id = self.tx.ctx.alloc_node();
        self.tx.ops.push(TxOp::CreateFor {
            id: id.0,
            collection: collection.id,
        });
        self.tx.ctx.open_fors.borrow_mut().push(collection.id);
        let out = body(&mut Tpl { tx: self.tx });
        self.tx.ctx.open_fors.borrow_mut().pop();
        self.tx.ops.push(TxOp::TemplateEnd);
        (id, out)
    }

    pub fn when<R>(
        &mut self,
        signal: SignalId,
        body: impl FnOnce(&mut Tpl<'_, '_>) -> R,
    ) -> (TemplateNodeId, R) {
        let id = self.tx.ctx.alloc_node();
        self.tx.ops.push(TxOp::CreateWhen { id: id.0, signal });
        let out = body(&mut Tpl { tx: self.tx });
        self.tx.ops.push(TxOp::TemplateEnd);
        (id, out)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;

    use super::{AppCtx, KayaRecord, Tx};
    use crate::protocol::{Value, ValueType};

    crate::record! {
        struct Todo {
            title: String,
            done: bool,
        }
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
