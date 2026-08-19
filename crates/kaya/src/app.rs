//! The app thread's view of the world: occurrences in, transactions out.
//!
//! Collections here follow the patch-producing doctrine: the collection
//! IS the model, the only copy. Every mutation op edits the model and
//! queues the wire delta in the same call, so reads are exactly the
//! writes. A transaction dropped without commit abandons its records,
//! and the model abandons the same writes.
//!
//! A [`Collection`] handle names one instance: the root handle is the
//! live-zone table, and `at(key)` selects the instance inside a stamped
//! copy, one key per enclosing For.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::marker::PhantomData;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};

use crate::protocol::{
    Inbox,
    AlertChoice, AlertId, AlertSpec,
    CollectionId, CommandKind, DEFAULT_WINDOW, EntryProp, MenuItemId, MenuItemKind, MenuProp,
    Occurrence, Path, Prop, PropValue,
    Record, SectionProp, SignalId, TypefaceRequest, WindowId, WindowProp,
    TemplateNodeId, TextRange, Transaction, TxOp, Value, ValueType, WidgetId, WidgetKind,
};

// --- Records: the app type is the schema --------------------------------
//
// The guest's own struct declaration is the single source of truth: the
// derive writes the wire schema, the conversions, and one field token per
// field, so schema, insert order and indexes cannot drift. Field tokens
// are typed projections, so binding a Bool field to a Str property is a
// compile error.

/// A value-kind marker, unifying field tokens with prop tokens at
/// compile time.
pub trait ValueKind {
    const TYPE: ValueType;
}
pub struct StrKind;
pub struct BoolKind;
pub struct I64Kind;
pub struct F64Kind;
/// The blob marker, so a record field of encoded bytes can address a
/// template image the way a Str field addresses a label. Added late:
/// Swift, C# and Java all shipped a per-row image (see
/// bindings/swift/KayaApp.swift) while Rust could not spell one — a
/// capability three bindings have and a fourth cannot express is
/// divergence, not a carve-out (invariant 1).
pub struct BlobKind;
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
impl ValueKind for BlobKind {
    const TYPE: ValueType = ValueType::Blob;
}

/// A first-class typed projection: one field of a record type, by
/// position. Exists because two sites have no record instance in hand —
/// binding a field in template position, and updating one field of one
/// entry.
pub struct Field<K> {
    pub index: u32,
    _kind: PhantomData<K>,
}

// A field token is a u32 and a marker, so it copies. Written by hand
// because `#[derive(Copy)]` would demand `K: Copy` of the marker types
// (the standard PhantomData workaround).
//
// IT IS NOT A NICETY: without it, binding one row field to two widgets in
// the same template fails to compile with a moved-value error.
impl<K> Clone for Field<K> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<K> Copy for Field<K> {}

/// One of the addressable sources a template property binds to: a
/// constant, a signal, or a field of the enclosing For's element — the
/// protocol's whole binding universe, as one argument. The kind parameter
/// keeps constants and fields honest at compile time; signals stay
/// runtime-checked.
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

/// The numeric constants, so a template's slider, progress bar or
/// choice index can be a literal where it does not vary per row —
/// `t.progress(0.5)` beside `t.progress(row.pct)`.
impl From<f64> for TplSource<F64Kind> {
    fn from(n: f64) -> Self {
        TplSource { inner: SourceInner::Const(Value::F64(n)), _kind: PhantomData }
    }
}

impl From<i64> for TplSource<I64Kind> {
    fn from(n: i64) -> Self {
        TplSource { inner: SourceInner::Const(Value::I64(n)), _kind: PhantomData }
    }
}

/// Encoded image bytes as a constant source. The owning conversions
/// only — `&[u8]` would need a lifetime the source outlives, and the
/// blob channel wants an Arc anyway.
impl<T: Into<crate::protocol::Blob>> From<T> for TplSource<BlobKind> {
    fn from(bytes: T) -> Self {
        TplSource { inner: SourceInner::Const(Value::Blob(bytes.into())), _kind: PhantomData }
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

impl Field<StrKind> {
    /// THE WHOLE ELEMENT OF A SCALAR COLLECTION, as a source.
    ///
    /// A template constructor's element source is a FIELD addressed by
    /// index off a record; a scalar collection has no record — its
    /// element IS the value. `PropValue::Element { level, field: 0 }` is
    /// exactly what a `Field` at index 0 produces, so this and the floor
    /// call put the same bytes on the wire.
    ///
    /// `StrKind` only, and that is a fact rather than a restriction:
    /// `String` is the sole non-derived `KayaSum` implementor.
    pub const fn element() -> Self {
        Field::new(0)
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
/// stable indexes. The typed product surfaces hang off this; sums reach
/// the same wire through their match-refined per-variant handles.
pub trait KayaRecord: KayaSum {
    const SCHEMA: &'static [ValueType];
    fn from_values(values: &[Value]) -> Self {
        Self::from_parts(0, values)
    }
}

/// The template eliminator for a sum `T`: a record of arms, one per
/// constructor, generated by the derive. The struct literal is the
/// totality check — a missing arm is a missing field, at compile time —
/// and each arm's returned handles ride out in the matching field of
/// `Out`. An arm spelled `|_| {}` renders that constructor as nothing.
/// (The scene re-checks totality for the languages that cannot.)
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
/// selected by `path` (empty for a live-zone collection). Entries keep
/// insertion order, matching the core's rendering.
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
    /// The for-statement form: `for mut row in todos.rows(&mut tx)` traces
    /// the record template — the body runs once, and the row's Drop closes
    /// the template (break- and panic-safe).
    ///
    /// The argument is the zone the For is declared in ([`ForScope`]), so
    /// a nested For is the same statement one level in.
    pub fn rows<'t, 'b, S: ForScope<'b>>(&self, scope: &'t mut S) -> Rows<'t, 'b> {
        assert_root(self);
        Rows {
            tx: Some(scope.zone_tx()),
            collection: self.id,
            nested: S::NESTED,
        }
    }

    /// A signal the binding recomputes from this collection's entries
    /// after every mutation, written into the same transaction. The
    /// closure is pure presentation; the core sees an ordinary signal.
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

/// One unit of posted work. `Send` because it crosses a thread boundary
/// to get here; the `Tx` it receives is made where it is used.
type PostedFn = Box<dyn for<'a, 'b> FnOnce(&'a mut Tx<'b>) -> () + Send>;

/// A handle for running work on the app thread from anywhere else.
///
/// Obtained with [`AppCtx::poster`], cheap to clone, and safe to send
/// wherever the work is. kaya has no runtime of its own and does not need
/// one — a plain `Send + Sync` handle is callable from all of them.
///
/// ```no_run
/// # fn slow_read() -> String { String::new() }
/// # fn demo(ctx: &kaya::AppCtx, content: kaya::SignalId) {
/// let poster = ctx.poster();
/// std::thread::spawn(move || {
///     let data = slow_read();          // blocks this thread, nothing else
///     poster.post(move |tx| {          // back on the app thread
///         tx.write(content, data);
///     });
/// });
/// # }
/// ```
#[derive(Clone)]
pub struct Poster {
    queue: Arc<Mutex<Vec<PostedFn>>>,
    wake: Sender<Inbox>,
}

impl Poster {
    /// Queue `body` to run as a transaction on the app thread, soon.
    ///
    /// The app thread runs it after whatever it is doing now, so posting
    /// from inside a handler queues for after and never nests. Posts run
    /// in the order they were made. After shutdown this is a no-op.
    pub fn post(&self, body: impl for<'a, 'b> FnOnce(&'a mut Tx<'b>) + Send + 'static) {
        self.queue.lock().unwrap().push(Box::new(body));
        // The app thread is parked in recv(); posted work is not an
        // occurrence, so this is the only way it hears about it.
        let _ = self.wake.send(Inbox::Woken);
    }
}

/// WHAT THIS HOST CAN DO — the canonical note for all eight bindings.
///
/// A handful of things in kaya's one surface are not everywhere: a
/// phone's system owns surface geometry, so there is no second window to
/// open there. A guest that needs to know asks HERE rather than reading
/// its own platform predicate — a guest's `#[cfg(target_os)]` is a SECOND
/// copy of a rule the core already holds, keyed on the platform rather
/// than on the capability, and the two drift in silence.
///
/// NAMED BOOLEANS, NEVER THE BITS. A bit test spelled by hand is the same
/// number written twice, in eight languages, against a core that is free
/// to renumber.
///
/// CAPABILITIES INFORM; WALLS REFUSE. Reading `false` here is not what
/// makes a call illegal — the core's wall does that
/// (crates/kaya/src/scene.rs's `CreateWindow` arm). This lets a guest ask
/// BEFORE it walks into it.
///
/// Constant for the life of the process.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Capabilities {
    /// The host can materialize a surface beside the primary one:
    /// [`Tx::create_window`] and mounting a root into it. Clear on iOS
    /// and Android, where `create_window` aborts at the root.
    pub aux_windows: bool,
}

/// This host's capabilities. See [`Capabilities`].
pub fn capabilities() -> Capabilities {
    // Through the C export the other seven bindings call, deliberately:
    // one door, so a break in it is a break for everyone rather than for
    // everyone else.
    let bits = crate::capi::kaya_capabilities();
    Capabilities {
        aux_windows: bits & crate::capi::KAYA_CAP_AUX_WINDOWS != 0,
    }
}

pub struct AppCtx {
    pub(crate) occurrences: Receiver<Inbox>,
    pub(crate) transactions: Sender<Transaction>,
    // Work handed over by other threads, waiting to run as transactions
    // here. Shared with every Poster, so it is behind a real lock —
    // unlike every other field, which is app-thread-only and uses Cell.
    posted: Arc<Mutex<Vec<PostedFn>>>,
    // How a Poster says "look at that queue". The app thread is parked
    // in `occurrences.recv()`, so the wake has to arrive there.
    wake: Sender<Inbox>,
    next_signal: Cell<u64>,
    next_widget: Cell<u64>,
    next_alert: Cell<u64>,
    next_collection: Cell<u64>,
    next_node: Cell<u64>,
    // Menu items get their OWN id space (the c_menu_item discipline):
    // dispatch tables key by item id, separate from every other table.
    next_menu_item: Cell<u64>,
    model: RefCell<HashMap<CollectionId, Vec<Instance>>>,
    // Collections declared inside a For's template: removing a parent
    // entry tears down the copy and every instance inside it, so the
    // model needs the same edge to purge along.
    children: RefCell<HashMap<CollectionId, Vec<CollectionId>>>,
    open_fors: RefCell<Vec<CollectionId>>,
    derived: RefCell<HashMap<CollectionId, Vec<Derived>>>,
    // The minter's counters: the highest I64 key each collection INSTANCE
    // has minted or absorbed. NOT part of the transaction journal — a
    // minted key is spent even if the transaction that spent it is
    // abandoned, so an id can never be handed out twice.
    fresh: RefCell<HashMap<CollectionId, Vec<(Vec<Value>, i64)>>>,
}

impl AppCtx {
    pub(crate) fn new(
        occurrences: Receiver<Inbox>,
        transactions: Sender<Transaction>,
        wake: Sender<Inbox>,
    ) -> Self {
        AppCtx {
            occurrences,
            transactions,
            posted: Arc::new(Mutex::new(Vec::new())),
            wake,
            next_signal: Cell::new(1),
            next_widget: Cell::new(1),
            next_alert: Cell::new(1),
            next_collection: Cell::new(1),
            next_node: Cell::new(1),
            next_menu_item: Cell::new(1),
            model: RefCell::new(HashMap::new()),
            children: RefCell::new(HashMap::new()),
            open_fors: RefCell::new(Vec::new()),
            derived: RefCell::new(HashMap::new()),
            fresh: RefCell::new(HashMap::new()),
        }
    }

    /// Block until the next occurrence arrives. A disconnected channel
    /// means the core is shutting down, which is an occurrence, not an
    /// error.
    pub fn next(&self) -> Occurrence {
        loop {
            // Posted work first, then the channel. Draining at the TOP is
            // what makes the wake sufficient: whatever brought this thread
            // back, it looks here before anywhere else.
            self.drain_posted();
            match self.occurrences.recv() {
                // Not the guest's business: the drain above already ran
                // whatever the wake was about.
                Ok(Inbox::Woken) => continue,
                Ok(Inbox::Occ(occ)) => {
                    // Taken off the transport (crate::stall). HERE and
                    // not after the handler: a long handler is work, and a
                    // handler that never returns shows up as the NEXT
                    // occurrence going unclaimed.
                    crate::stall::taken();
                    // An undo moved core state without a transaction, so
                    // the model mirror has to follow. HERE, at the ONE
                    // place both the raw loop and Messages::next take
                    // their occurrences from.
                    match &occ {
                        Occurrence::Undone { delta, .. } | Occurrence::Redone { delta, .. } => {
                            self.absorb_undo(delta)
                        }
                        _ => {}
                    }
                    return occ;
                }
                Err(_) => return Occurrence::Shutdown,
            }
        }
    }

    /// Fold an undo's payload into the collection mirror.
    ///
    /// The rollback journal in reverse: `Tx`'s Drop restores a snapshot
    /// because nothing was shipped, while an undo restores a delta because
    /// everything WAS. The payload is core-authoritative, so nothing here
    /// re-derives anything.
    ///
    /// Signals and text are not mirrored by this binding (no read-back for
    /// either, by doctrine), so those two runs pass straight to the app.
    ///
    /// NO DERIVED RECOMPUTE HERE, DELIBERATELY. A derived signal's write
    /// rode the SAME transaction as the mutation that caused it, so a
    /// named step banked the derived value in both directions and the core
    /// has already restored it. A recompute added here would write a value
    /// the ledger never banked, arriving between the core's restore and
    /// the app's own `on_undone`; where it disagreed, the screen and the
    /// ledger would drift apart (docs/deferred.md's one residual).
    fn absorb_undo(&self, delta: &crate::protocol::UndoDelta) {
        let mut model = self.model.borrow_mut();
        for entry in &delta.entries {
            let instances = model.entry(entry.collection).or_default();
            let at = match instances.iter().position(|i| i.path == entry.path) {
                Some(at) => at,
                None => {
                    instances.push(Instance {
                        path: entry.path.clone(),
                        entries: Vec::new(),
                    });
                    instances.len() - 1
                }
            };
            let table = &mut instances[at].entries;
            match &entry.state {
                Some((variant, record)) => {
                    match table.iter_mut().find(|(k, _, _)| k == &entry.key) {
                        Some((_, v, r)) => {
                            *v = *variant;
                            *r = record.clone();
                        }
                        None => table.push((entry.key.clone(), *variant, record.clone())),
                    }
                }
                None => table.retain(|(k, _, _)| k != &entry.key),
            }
        }
        for order in &delta.orders {
            let Some(instances) = model.get_mut(&order.collection) else {
                continue;
            };
            let Some(instance) = instances.iter_mut().find(|i| i.path == order.path) else {
                continue;
            };
            // Position by the payload's list, keeping anything the
            // payload does not name at the end: an entry it never mentions
            // is one this undo did not touch.
            let mut sorted: Vec<(Value, u32, Record)> = Vec::with_capacity(instance.entries.len());
            for key in &order.keys {
                if let Some(at) = instance.entries.iter().position(|(k, _, _)| k == key) {
                    sorted.push(instance.entries.remove(at));
                }
            }
            sorted.append(&mut instance.entries);
            instance.entries = sorted;
        }
    }

    /// Run everything posted, each in its own transaction, in order.
    ///
    /// The batch is taken and the lock released BEFORE any of it runs, so
    /// a closure that posts again lands in the NEXT batch. Holding the
    /// lock across the calls would let a self-posting closure drain
    /// forever and starve the occurrence channel.
    fn drain_posted(&self) {
        let batch = std::mem::take(&mut *self.posted.lock().unwrap());
        for f in batch {
            self.apply(|tx| f(tx));
        }
    }

    /// A handle for reaching this app thread from another thread.
    ///
    /// `AppCtx` itself cannot travel: it holds `Cell`s and `RefCell`s, so
    /// it is `!Sync`. That is deliberate — making it shareable would not
    /// fix the danger, it would legalize it, letting another thread mutate
    /// the model while a transaction is open here.
    pub fn poster(&self) -> Poster {
        Poster {
            queue: Arc::clone(&self.posted),
            wake: self.wake.clone(),
        }
    }

    /// Start a transaction: a batch of records applied atomically when
    /// committed. Ids are allocated here, a monotonic counter per space.
    /// Run `body` in a fresh transaction and commit it on return; the
    /// body's result comes back out. A panic inside the body abandons the
    /// transaction before the unwind continues — commit is never reached,
    /// and Tx's Drop rolls the model mirrors back.
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

    fn alloc_alert(&self) -> AlertId {
        let id = self.next_alert.get();
        self.next_alert.set(id + 1);
        AlertId(id)
    }

    /// File dialogs share the alert counter: both are
    /// one-live-per-process request ids that retire with their result, so
    /// one monotonic space keeps a stray id from naming the wrong kind.
    fn alloc_file_dialog(&self) -> crate::protocol::FileDialogId {
        let id = self.next_alert.get();
        self.next_alert.set(id + 1);
        crate::protocol::FileDialogId(id)
    }

    /// Clipboard reads share the same counter, for the same reason:
    /// a request id that retires with its one answer.
    fn alloc_clip_read(&self) -> u64 {
        let id = self.next_alert.get();
        self.next_alert.set(id + 1);
        id
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

    fn alloc_menu_item(&self) -> MenuItemId {
        let id = self.next_menu_item.get();
        self.next_menu_item.set(id + 1);
        MenuItemId(id)
    }

    /// One instance's counter, made if this is the first anyone has
    /// asked. Split out because both the mint and the absorb want the
    /// same lookup and neither may hold the borrow across the other.
    fn with_counter<R>(
        &self,
        collection: CollectionId,
        path: &[Value],
        body: impl FnOnce(&mut i64) -> R,
    ) -> R {
        let mut fresh = self.fresh.borrow_mut();
        let instances = fresh.entry(collection).or_default();
        let at = match instances.iter().position(|(p, _)| p == path) {
            Some(at) => at,
            None => {
                instances.push((path.to_vec(), 0));
                instances.len() - 1
            }
        };
        body(&mut instances[at].1)
    }

    /// The next fresh key for one instance: counter+1, and the counter
    /// keeps it. Monotonic by construction — nothing else writes it
    /// downwards (see `Tx::insert_fresh`).
    fn mint_key(&self, collection: CollectionId, path: &[Value]) -> i64 {
        self.with_counter(collection, path, |counter| {
            *counter += 1;
            *counter
        })
    }

    /// An explicit key, shown to the minter on its way into the table. A
    /// numeric key at or above the counter carries it up; anything else
    /// moves nothing, having no way to collide with an I64.
    fn absorb_key(&self, collection: CollectionId, path: &[Value], key: &Value) {
        let Value::I64(n) = *key else { return };
        self.with_counter(collection, path, |counter| *counter = (*counter).max(n));
    }

    /// A collection declared inside a For's template is torn down with
    /// its copies: record the edge so the model purges along it.
    fn register_collection(&self, id: CollectionId) {
        if let Some(&parent) = self.open_fors.borrow().last() {
            self.children.borrow_mut().entry(parent).or_default().push(id);
        }
    }
}

/// A container's cross-axis child placement — the align spec enum,
/// language-native. Baseline is rows-only (the scene rejects it on
/// columns at the root). Rides the wire as I64.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Align {
    Start,
    Center,
    End,
    Stretch,
    Baseline,
}

impl Align {
    fn wire(self) -> i64 {
        match self {
            Align::Start => 0,
            Align::Center => 1,
            Align::End => 2,
            Align::Stretch => 3,
            Align::Baseline => 4,
        }
    }
}

/// A just-built widget: the chain handle every live-zone constructor
/// returns. It reborrows the transaction, so it lives at most to the end
/// of its statement — chain construction props on it and end with
/// [`Widget::id`] where the handle must outlive the chain. Where Go and
/// Java police a chain outside its build with a runtime panic, here it
/// cannot compile. A container's body result rides along as `out`.
pub struct Widget<'t, 'b, R = ()> {
    /// The container body's own result, threaded out unchanged.
    pub out: R,
    id: WidgetId,
    tx: &'t mut Tx<'b>,
}

impl<'t, 'b, R> Widget<'t, 'b, R> {
    /// This widget's flex weight — the chained spelling of
    /// [`Tx::grow`], which remains the dynamic path.
    pub fn grow(self, weight: f64) -> Self {
        self.tx.grow(self.id, weight);
        self
    }

    /// This container's inter-child gap — the chained spelling of
    /// [`Tx::spacing`], which remains the dynamic path.
    pub fn spacing(self, gap: f64) -> Self {
        self.tx.spacing(self.id, gap);
        self
    }

    /// This container's own padding — the chained spelling of
    /// [`Tx::inset`]. The window's inset is [`WindowRef::inset`]; this is
    /// the same number one level down.
    pub fn inset(self, pad: f64) -> Self {
        self.tx.inset(self.id, pad);
        self
    }

    /// This container's cross-axis child placement — the chained
    /// spelling of [`Tx::align`], which remains the dynamic path.
    pub fn align(self, align: Align) -> Self {
        self.tx.align(self.id, align);
        self
    }

    /// This widget's accessibility identifier — the chained spelling of
    /// [`Tx::a11y_id`], which remains the dynamic path.
    pub fn a11y_id(self, id: &str) -> Self {
        self.tx.a11y_id(self.id, id);
        self
    }

    /// What this widget accepts from a paste. A SET, so a kind cannot be
    /// named twice: the root refuses a duplicate rather than letting one
    /// silently win.
    pub fn accepts(self, kinds: &[Accepts<'_>]) -> Self {
        let list: Vec<&str> = kinds.iter().map(|k| k.token()).collect();
        self.tx.accepts(self.id, &list.join(" "));
        self
    }

    /// This widget's spoken accessibility label — the chained spelling
    /// of [`Tx::a11y_label`], which remains the dynamic path.
    pub fn a11y_label(self, label: &str) -> Self {
        self.tx.a11y_label(self.id, label);
        self
    }

    /// What activating this widget does — the chained spelling of
    /// [`Tx::a11y_hint`], which remains the dynamic path.
    pub fn a11y_hint(self, hint: &str) -> Self {
        self.tx.a11y_hint(self.id, hint);
        self
    }

    /// SEMANTIC EMPHASIS (docs/styling-plan.md D4): what this widget
    /// MEANS, never how it looks. The root refuses a role on a kind it
    /// does not fit, at declare time, naming both sides.
    pub fn role(self, role: crate::Role) -> Self {
        self.tx.set(self.id, Prop::Role, role as i64);
        self
    }

    /// End the chain: the durable id, releasing the transaction
    /// borrow.
    pub fn id(self) -> WidgetId {
        self.id
    }

    /// End the chain keeping the container body's result too.
    pub fn into_parts(self) -> (WidgetId, R) {
        (self.id, self.out)
    }
}

impl<R> From<Widget<'_, '_, R>> for WidgetId {
    fn from(w: Widget<'_, '_, R>) -> WidgetId {
        w.id
    }
}

// --- Assets: the files the app's own BUILD shipped beside it ------------

/// An open asset: the bytes of one file the app's build put where the
/// running program can find it, asked for by the same name on five
/// platforms (docs/assets-plan.md).
///
/// `tx.asset("fonts/sora-wght.ttf")` is the whole call. WHERE that name
/// resolves is the core's knowledge and never the app's, and the rule
/// plus its failure sentence live once, in [`crate::assets`].
///
/// # Why Rust's asset is not a handle
///
/// The other seven bindings hold a `u64` from `kaya_asset_open` and have
/// to release it. Rust IS the core: this type holds the `Arc<[u8]>`, so
/// the release is the `Arc`'s. The observable semantics are the ones
/// every binding has — the bytes stay readable for exactly as long as the
/// guest holds the asset — and per invariant 1 that is what has to match.
///
/// # Two redemptions
///
/// - **Hand it to kaya.** [`Tx::brand_typeface_with`] and
///   [`Tx::app_identity`] take a [`BlobSource`], and an `Asset`'s impl
///   clones the `Arc`: a refcount bump, not a copy.
/// - **Read it yourself.** [`Asset::bytes`] and [`Asset::reader`].
///
/// Reading is READ-ONLY structurally: no mode argument anywhere on this
/// surface, so `tools/check-file-modes.sh`'s bug class cannot occur.
pub struct Asset {
    bytes: Arc<[u8]>,
}

impl Asset {
    /// The asset's bytes.
    ///
    /// A BORROW RATHER THAN A COPY, which is where Rust's spelling parts
    /// company with the other seven: theirs are behind a C pointer that a
    /// release invalidates, this one is the core's own allocation with the
    /// borrow checker keeping it alive. [`Asset::reader`] is there for the
    /// caller who wants an owned one.
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// The asset as something `std::io::Read` + `Seek`, for a parser that
    /// wants a stream rather than a slice.
    ///
    /// FILE-LIKE READING IS BINDING-SIDE SUGAR, with zero core surface
    /// (docs/assets-plan.md): each language wraps the bytes in its own
    /// standard in-memory reader. There is no file descriptor anywhere in
    /// the asset surface — that was `PickedFile`'s necessity, and kaya
    /// produced these bytes itself.
    pub fn reader(&self) -> std::io::Cursor<Vec<u8>> {
        std::io::Cursor::new(self.bytes.to_vec())
    }

    /// How many bytes the asset has.
    pub fn len(&self) -> usize {
        self.bytes.len()
    }

    /// Whether the asset has no bytes — which it never does: the core
    /// refuses a zero-byte asset at the open (assets.rs's wall 2). It is
    /// here because it MEASURES that rather than asserting it, and because
    /// a `len` without an `is_empty` is a lint.
    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }
}

impl std::ops::Deref for Asset {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        &self.bytes
    }
}

impl std::fmt::Debug for Asset {
    /// The byte count, never the bytes: a `{:?}` that dumped a font would
    /// turn a one-line assertion failure into a hundred-kilobyte diff.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Asset({} bytes)", self.bytes.len())
    }
}

/// What can become a blob on the wire: bytes the app computed, or an
/// [`Asset`] the core read.
///
/// ONE ARGUMENT TYPE RATHER THAN TWO FUNCTIONS. Every binding admits both
/// spellings and each pays for it in its own coin — C# overloads, Go
/// names a sibling — while Rust takes the trait object, so `Some(&font)`
/// reads identically whether `font` is a `Vec<u8>` or an `Asset`.
///
/// The impls differ in exactly one way, and that difference is the point
/// of the asset route: the byte spellings COPY into a fresh `Arc` (they
/// must — the caller owns those bytes and may edit them after this call
/// returns), while `Asset` CLONES the `Arc` it already holds.
pub trait BlobSource {
    /// The bytes this source contributes to the transaction's blob table.
    /// `Arc<[u8]>` rather than the protocol's `Blob` because that type is
    /// crate-private and this trait is not.
    fn blob_bytes(&self) -> Arc<[u8]>;
}

impl BlobSource for [u8] {
    fn blob_bytes(&self) -> Arc<[u8]> {
        Arc::from(self)
    }
}

/// The owned byte spelling, alongside `[u8]`'s, because `&some_vec` does
/// NOT reach `&dyn BlobSource` on its own: Rust will deref-coerce and it
/// will unsize, but it does not chain the two.
impl BlobSource for Vec<u8> {
    fn blob_bytes(&self) -> Arc<[u8]> {
        Arc::from(&self[..])
    }
}

impl BlobSource for Asset {
    fn blob_bytes(&self) -> Arc<[u8]> {
        Arc::clone(&self.bytes)
    }
}

/// A transaction under construction. Everything queues locally; commit
/// sends the batch and rings the doorbell once. Dropping a Tx without
/// committing abandons its records — and rolls the model back with them,
/// so reads never show writes that were never sent.
///
/// # A `Tx` never leaves the app thread
///
/// It borrows [`AppCtx`], which is `!Sync`, so `Tx` is `!Send` and the
/// compiler refuses to move one onto another thread. A guest may post a
/// closure to the app thread and capture ids on the way, but the
/// transaction itself stays put.
///
/// NOBODY DESIGNED THIS — it fell out of the interior mutability above,
/// and an innocent refactor (swapping a `Cell` for an atomic, say) would
/// delete the guard in silence. So it is pinned here. Go and Java police
/// the same rule with a runtime panic.
///
/// ```compile_fail
/// fn assert_send<T: Send>() {}
/// assert_send::<kaya::Tx<'static>>();
/// ```
///
/// A `compile_fail` that dies of an unrelated error pins nothing (this
/// crate has shipped that mistake), so the same assertion must PASS for
/// the ids a posted closure is meant to carry:
///
/// ```
/// fn assert_send<T: Send>() {}
/// assert_send::<kaya::SignalId>();
/// assert_send::<kaya::WidgetId>();
/// ```
///
/// Note the failing case says `Tx<'static>`: with a shorter lifetime it
/// would also fail the `'static` bound of anything like `thread::spawn`,
/// and the test would pass for the wrong reason.
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
    // sentinel. No ambient statics — the &mut Tx threading is the
    // ambience.
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

impl<'a> Tx<'a> {
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

    /// Recompute every derived signal rooted at this collection. Runs
    /// after each mutation of the LIVE-ZONE instance: deriveds are
    /// declared on root handles, so nested-instance mutations cannot
    /// change their input.
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
    /// committed patch plus this transaction's own, in insertion order.
    ///
    /// Reads are transaction-scoped, and the borrow checker is the
    /// record-time mirror-read guard: a template body cannot read the
    /// model, because the template records once and replays, so a read
    /// would bake today's value into the blueprint as silently dead data.
    /// Bind a signal, use the element's field, or `derive`. Pinned here:
    ///
    /// ```compile_fail
    /// fn zone_rule(tx: &mut kaya::Tx<'_>, todos: &kaya::Collection<String>) {
    ///     tx.for_each(todos, |_t| {
    ///         tx.len(todos); // cannot borrow `tx`: the body records a blueprint
    ///     });
    /// }
    /// ```
    ///
    /// The for-statement tracer holds the same wall — a `Row` borrows the
    /// transaction for as long as it lives:
    ///
    /// ```compile_fail
    /// fn zone_rule(tx: &mut kaya::Tx<'_>, todos: &kaya::Collection<String>) {
    ///     for _row in todos.rows(tx) {
    ///         tx.items(todos); // cannot borrow `tx`: the trace is recording
    ///     }
    /// }
    /// ```
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

    /// Make this transaction ONE undoable step, under `label`.
    ///
    /// The unit of undo is a NAMED GROUP declared at the opener, not every
    /// transaction: handlers fire per-gesture transactions constantly and
    /// most of them are consequences rather than intents, and a
    /// per-keystroke editor would earn one step per character
    /// (docs/undo-plan.md D2, D8).
    ///
    /// CALLABLE ANYWHERE IN THE CHAIN, and the marker still rides at the
    /// head: a handler naturally builds first and names the step when it
    /// knows what the step was.
    ///
    /// WHAT A GROUP MAY HOLD is the reactive half — signal writes and
    /// collection deltas. Focus is permitted and not restored. Anything
    /// else fails at apply, naming the op. The app hears the result as
    /// [`Messages::on_undone`].
    pub fn undoable(&mut self, label: impl Into<String>) {
        self.undoable_in(crate::protocol::DEFAULT_WINDOW, label);
    }

    /// [`Tx::undoable`] against an auxiliary window's ledger. Each
    /// window has its own history, because Undo in one window has never
    /// meant "revert what happened in another".
    pub fn undoable_in(&mut self, window: WindowId, label: impl Into<String>) {
        assert!(
            !self
                .ops
                .iter()
                .any(|op| matches!(op, TxOp::UndoGroup { .. })),
            "kaya: this transaction is already an undo group — one name per step"
        );
        self.ops.insert(
            0,
            TxOp::UndoGroup {
                window,
                label: label.into(),
            },
        );
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

    /// Set a primary-surface property ([`WindowProp`]; window 0 —
    /// auxiliary windows are not in the vocabulary yet). The floor
    /// the sugar below rides.
    pub fn set_window(&mut self, prop: WindowProp, value: impl Into<Value>) {
        self.ops.push(TxOp::SetWindowProp {
            window: DEFAULT_WINDOW,
            prop,
            value: PropValue::Const(value.into()),
        });
    }

    /// Create an auxiliary window (capability-gated: a phone host rejects
    /// it at the root). Materializes hidden; mounting a root presents it.
    /// Returns a proxy for its props:
    /// `tx.create_window(WindowId(1)).title("inspector").size(480.0, 320.0)`.
    pub fn create_window(&mut self, window: WindowId) -> WindowRef<'_, 'a> {
        self.ops.push(TxOp::CreateWindow { window });
        WindowRef { tx: self, window }
    }

    /// REQUEST the app's brand accent (docs/styling-plan.md D1/D2): one
    /// hex is the whole call; the per-appearance overrides exist for a
    /// brand book that specifies a dark variant. Set ONCE, before the
    /// first mount — the root refuses a second or late write. The app
    /// never writes a foreground and never writes contrast variants: the
    /// core derives both.
    pub fn brand_accent(&mut self, seed: u32) {
        self.ops.push(TxOp::SetBrandAccent { seed, light: None, dark: None });
    }

    /// The per-appearance form: `seed` fills whatever `light`/`dark`
    /// leave unstated (D1's grammar).
    pub fn brand_accent_with(&mut self, seed: u32, light: Option<u32>, dark: Option<u32>) {
        self.ops.push(TxOp::SetBrandAccent { seed, light, dark });
    }

    /// Open an [`Asset`] — a file the app's own BUILD shipped beside it,
    /// named by a relative path under the asset root.
    ///
    /// TAKES `&self` DELIBERATELY: opening an asset queues no op and
    /// touches no model, so `tx.brand_typeface_with("Sora", &[],
    /// Some(&tx.asset(name)))` compiles.
    ///
    /// # A miss panics, with the core's sentence and nothing added
    ///
    /// A missing, unreadable, empty or malformed-name asset is a scene
    /// error in every binding, and each raises in its own idiom carrying
    /// [`crate::assets::asset_why_not`]'s sentence VERBATIM. THE BINDING
    /// WRITES NO PROSE OF ITS OWN: one author for that diagnostic, so one
    /// scene can freeze the words every guest is handed.
    ///
    /// This is the one call in the Rust surface that reads the filesystem,
    /// and it reads on EVERY call: no cache, no watch, no reload.
    pub fn asset(&self, name: &str) -> Asset {
        match crate::assets::read(name) {
            Ok(bytes) => Asset { bytes: Arc::from(bytes) },
            // The whole sentence, unwrapped and unprefixed. Anything
            // this line added would be a second author for it.
            Err(sentence) => panic!("{sentence}"),
        }
    }

    /// Why [`Tx::asset`] would fail for this name — the sentence it
    /// would raise, handed over without raising. `""` means it resolves.
    /// Two lines: line 1 (name, rule, census) is the same on every
    /// platform and is the one a scene freezes; line 2 names the
    /// resolved place, which three platforms spell three ways.
    ///
    /// Why a query and not just the raise: docs/deferred.md, the assets
    /// entry. It measures rather than predicts — `asset` reads on every
    /// call — so `""` is a fact about the moment it was asked.
    pub fn asset_miss_sentence(&self, name: &str) -> String {
        crate::assets::asset_why_not(name)
    }

    /// REQUEST the app's brand typeface (docs/styling-plan.md Slice 2b):
    /// one family name is the whole call. THE FAMILY, NEVER THE SCALE —
    /// sizes, weights and the whole type ramp stay the platform's. Set
    /// ONCE, before the first mount, the accent's wall verbatim.
    ///
    /// A family a platform does not have leaves that platform's own
    /// typeface in place, deliberately: every font API renders SOMETHING
    /// for a name it cannot match, so the lowerings gate on the family
    /// being installed rather than letting the platform pick a stranger.
    pub fn brand_typeface(&mut self, family: &str) {
        self.ops.push(TxOp::SetBrandTypeface(TypefaceRequest {
            family: family.to_string(),
            platforms: Vec::new(),
            font: None,
        }));
    }

    /// The per-platform form, plus the font-FILE form: `family` is the
    /// default and `platforms` overrides it for the platforms that name
    /// themselves, while `font` ships a font file whose bytes the backend
    /// registers with its platform's app-font API, taking the family that
    /// registration names in preference to any name above.
    ///
    /// THE PAIRS TRAVEL UNRESOLVED, unlike the accent's per-platform
    /// values: this binding cannot know its platform, but every lowering
    /// IS one.
    ///
    /// `font` is a [`BlobSource`], so both spellings fit:
    ///
    /// ```ignore
    /// let font = tx.asset("fonts/sora-wght.ttf");
    /// tx.brand_typeface_with("Sora", &[], Some(&font));   // no copy
    /// tx.brand_typeface_with("Sora", &[], Some(&my_vec)); // one copy
    /// ```
    ///
    /// The asset route costs a refcount bump: the core read those bytes
    /// and the same allocation reaches the platform's font API.
    pub fn brand_typeface_with(
        &mut self,
        family: &str,
        platforms: &[(Platform, &str)],
        font: Option<&dyn BlobSource>,
    ) {
        self.ops.push(TxOp::SetBrandTypeface(TypefaceRequest {
            family: family.to_string(),
            platforms: platforms
                .iter()
                .map(|(tag, f)| (*tag as u32, (*f).to_string()))
                .collect(),
            font: font.map(|source| crate::protocol::Blob(source.blob_bytes())),
        }));
    }

    /// DECLARE the app's identity (docs/app-identity-plan.md): the name it
    /// goes by and the picture that stands for it, as the bytes of one
    /// image file. Set ONCE, before the first mount — the brand's wall
    /// verbatim, and for the brand's reason: identity is not state.
    ///
    /// ONE PICTURE, FIVE PLATFORMS. The same bytes become the macOS Dock
    /// tile, the Windows taskbar icon and the caption's mark, and an X11
    /// window's icon; the same FILE, read at build time, becomes the
    /// Android launcher and iOS Home Screen icons. Send a PNG.
    ///
    /// THE BYTES ARE NEVER INSPECTED between here and the platform's own
    /// decoder — which is why the identity scene reads what the DECODER
    /// produced rather than echoing what was sent.
    ///
    /// `icon` is a [`BlobSource`]: `&tx.asset("icons/kaya-mark.png")` for
    /// the mark the app's build shipped (no copy), or a `&Vec<u8>`.
    pub fn app_identity(&mut self, name: &str, icon: &dyn BlobSource) {
        self.ops.push(TxOp::SetAppIdentity(crate::protocol::AppIdentity {
            name: name.to_string(),
            icon: Some(crate::protocol::Blob(icon.blob_bytes())),
        }));
    }

    /// The NAME-ONLY form. Its identity still reaches the surfaces a name
    /// reaches, and every icon surface keeps the platform's own default.
    pub fn app_identity_named(&mut self, name: &str) {
        self.ops.push(TxOp::SetAppIdentity(crate::protocol::AppIdentity {
            name: name.to_string(),
            icon: None,
        }));
    }

    pub fn window(&mut self, window: WindowId) -> WindowRef<'_, 'a> {
        WindowRef { tx: self, window }
    }

    /// Close and forget an auxiliary window. Also the veto grammar's
    /// confirmation: answer a close_requested with this, and the
    /// reconciliation after a window_closed.
    pub fn destroy_window(&mut self, window: WindowId) {
        self.ops.push(TxOp::DestroyWindow { window });
    }

    /// Push a navigation entry onto the primary surface's stack (entry ids
    /// are guest-allocated in the shared surface namespace). Materializes
    /// covered/incoming; mounting a root into it presents it:
    /// `let e = tx.push_entry(WindowId(7)).title("detail").id();`
    pub fn push_entry(&mut self, entry: WindowId) -> EntryRef<'_, 'a> {
        self.push_entry_in(DEFAULT_WINDOW, entry)
    }

    /// Push onto another window's stack (the System Settings shape:
    /// a stack inside a desktop auxiliary).
    pub fn push_entry_in(&mut self, window: WindowId, entry: WindowId) -> EntryRef<'_, 'a> {
        self.ops.push(TxOp::PushEntry { window, entry });
        EntryRef { tx: self, entry }
    }

    /// Pop the primary stack's top entry and forget its tree. Also
    /// the back-veto grammar's confirmation: answer a back_requested
    /// with this. Popping an empty stack is a scene error.
    pub fn pop_entry(&mut self) {
        self.pop_entry_in(DEFAULT_WINDOW);
    }

    pub fn pop_entry_in(&mut self, window: WindowId) {
        self.ops.push(TxOp::PopEntry { window });
    }

    /// Set a navigation-entry property to a constant ([`EntryProp`];
    /// the floor the [`EntryRef`] chain rides).
    pub fn set_entry_prop(&mut self, entry: WindowId, prop: EntryProp, value: impl Into<Value>) {
        self.ops.push(TxOp::SetEntryProp {
            entry,
            prop,
            value: PropValue::Const(value.into()),
        });
    }

    /// Append a section to the primary surface's section set (ids are
    /// guest-allocated in the shared surface namespace). The first added
    /// becomes selected; the set is append-only — this grammar has no
    /// destruction verbs. Mounting a root into it fills its pane.
    pub fn add_section(&mut self, section: WindowId) -> SectionRef<'_, 'a> {
        self.add_section_in(DEFAULT_WINDOW, section)
    }

    /// Append onto another window's section set.
    pub fn add_section_in(&mut self, window: WindowId, section: WindowId) -> SectionRef<'_, 'a> {
        self.ops.push(TxOp::AddSection { window, section });
        SectionRef { tx: self, section }
    }

    /// Select a section programmatically: configuration, never echoes
    /// section_selected (the echo doctrine).
    pub fn select_section(&mut self, section: WindowId) {
        self.select_section_in(DEFAULT_WINDOW, section);
    }

    pub fn select_section_in(&mut self, window: WindowId, section: WindowId) {
        self.ops.push(TxOp::SelectSection { window, section });
    }

    /// Set a section property to a constant ([`SectionProp`]; the
    /// floor the [`SectionRef`] chain rides).
    pub fn set_section_prop(
        &mut self,
        section: WindowId,
        prop: SectionProp,
        value: impl Into<Value>,
    ) {
        self.ops.push(TxOp::SetSectionProp {
            section,
            prop,
            value: PropValue::Const(value.into()),
        });
    }

    /// Request a modal alert (the request/result grammar): a chain ending
    /// in [`AlertRef::show`], which sends the one atomic record and
    /// returns the request's id.
    ///
    /// The id is binding-allocated: the result handler is bound to the
    /// REQUEST, never to the app, so the guest carries no correlation
    /// plumbing. Up to two actions (the platform floor); the cancel label
    /// is required and explicit — the slot every platform-native
    /// dismissal resolves to. One alert may be live per process.
    pub fn show_alert(&mut self) -> AlertRef<'_, 'a> {
        let alert = self.ctx.alloc_alert();
        AlertRef {
            tx: self,
            spec: AlertSpec {
                window: DEFAULT_WINDOW,
                alert,
                title: String::new(),
                message: String::new(),
                actions: Vec::new(),
                cancel: String::new(),
            },
        }
    }

    /// Ask the platform for files. THE PICK, not the open — the result
    /// carries handles you redeem later (DESIGN.md, File dialogs). One
    /// dialog may be live per process; show the next from the first's
    /// result handler. Cancel arrives as an EMPTY list.
    pub fn pick_files(&mut self) -> FileDialogRef<'_, 'a> {
        let dialog = self.ctx.alloc_file_dialog();
        FileDialogRef {
            tx: self,
            spec: crate::protocol::FileDialogSpec {
                window: DEFAULT_WINDOW,
                dialog,
                multiple: true,
                filters: Vec::new(),
            },
        }
    }

    /// Put one clip on the system clipboard, offered in as many
    /// representations as the app fills in.
    ///
    /// kaya DERIVES NOTHING between them: whether list bullets survive
    /// html-to-text is a rendering decision this app owns, and a bad
    /// auto-derivation degrades every paste silently. The one exception is
    /// a file list, which also gets the platform's text rendition.
    pub fn copy(&mut self) -> CopyRef<'_, 'a> {
        CopyRef { tx: self, clip: crate::protocol::Clip::default() }
    }

    /// Read the clipboard OUTSIDE any paste gesture — the privileged one.
    /// The platforms have deliberately made it expensive: iOS prompts for
    /// another app's content, Android answers nothing without focus,
    /// Wayland delivers no offer to an unfocused client. Reach for it when
    /// there IS no paste, not to implement Paste.
    pub fn read_clipboard(&mut self) -> ClipReadRef<'_, 'a> {
        let request = self.ctx.alloc_clip_read();
        ClipReadRef { tx: self, request, accepting: Vec::new() }
    }

    /// The single-file spelling. The floor always returns a LIST; this
    /// only asks the platform for one, so the result carries zero or
    /// one file.
    pub fn pick_file(&mut self) -> FileDialogRef<'_, 'a> {
        let mut r = self.pick_files();
        r.spec.multiple = false;
        r
    }

    /// Ask the platform WHERE TO SAVE. The picker's twin: one answer, one
    /// grammar, the same one-live-dialog slot — [`Messages::on_saved`]
    /// binds the handler and cancel arrives as `None`.
    ///
    /// `suggested_name` is the name the dialog OPENS with, and every
    /// platform treats it the way it treats a filter: it takes it, and
    /// guarantees nothing. Read the name you GOT.
    ///
    /// WHAT YOU GET BACK OPENS EMPTY: a save destination may not exist yet,
    /// so the handle's open CREATES and [`FileMode::Write`] yields an empty
    /// file on every platform (docs/save-plan.md D1).
    pub fn save_file(&mut self, suggested_name: impl Into<String>) -> SaveDialogRef<'_, 'a> {
        let dialog = self.ctx.alloc_file_dialog();
        SaveDialogRef {
            tx: self,
            spec: crate::protocol::SaveDialogSpec {
                window: DEFAULT_WINDOW,
                dialog,
                suggested_name: suggested_name.into(),
                filters: Vec::new(),
            },
        }
    }

    /// Set a property on any window ([`set_window`] targets the
    /// primary).
    pub fn set_window_prop(&mut self, window: WindowId, prop: WindowProp, value: impl Into<Value>) {
        self.ops.push(TxOp::SetWindowProp {
            window,
            prop,
            value: PropValue::Const(value.into()),
        });
    }

    /// The primary surface's ADVISORY content-size request, in DIP:
    /// honored where the window manager permits, recorded only where the
    /// system owns geometry. A request, never a guarantee — see
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

    /// A child's flex-grow weight within its enclosing row/column: 0 (the
    /// default) is natural size. Kind-agnostic. See [`Prop::Grow`] for the
    /// full contract.
    pub fn grow(&mut self, widget: WidgetId, weight: f64) {
        self.set(widget, Prop::Grow, weight);
    }

    /// A container's inter-child gap on its main axis, in DIP (default 8).
    /// Containers only. See [`Prop::Spacing`].
    pub fn spacing(&mut self, widget: WidgetId, gap: f64) {
        self.set(widget, Prop::Spacing, gap);
    }

    /// A container's own padding, uniform on all four sides. Containers
    /// only. See [`Prop::Inset`].
    pub fn inset(&mut self, widget: WidgetId, pad: f64) {
        self.set(widget, Prop::Inset, pad);
    }

    /// A container's cross-axis child placement (the normalized
    /// default is [`Align::Start`]). Containers only; baseline is
    /// rows-only. See [`Prop::Align`].
    pub fn align(&mut self, widget: WidgetId, align: Align) {
        self.set(widget, Prop::Align, align.wire());
    }

    /// This widget's accessibility IDENTIFIER: a stable authored key,
    /// NEVER spoken. Universal — every kind carries one. See
    /// [`Prop::A11yId`].
    pub fn a11y_id(&mut self, widget: WidgetId, id: &str) {
        self.set(widget, Prop::A11yId, id);
    }

    /// WHAT THIS WIDGET ACCEPTS FROM A PASTE: the closed kinds by name
    /// (`text`, `html`, `image`, `files`) and any custom format ids, space
    /// separated. [`Widget::accepts`] is the chained spelling.
    ///
    /// ONE DECLARATION, THREE JOBS. It drives whether the standard Paste
    /// command is live while this widget is focused, it filters what can
    /// reach the widget's paste hook, and on Android it IS the native
    /// registration. Per-widget because whether Paste should be enabled is
    /// the INTERSECTION of what the clipboard offers and what the focused
    /// target takes.
    ///
    /// A TEXT WIDGET THAT DECLARES NOTHING still pastes: the platform's own
    /// insertion happens and the existing change handler reports it.
    pub fn accepts(&mut self, widget: WidgetId, list: &str) {
        self.set(widget, Prop::Accepts, list);
    }

    /// This widget's accessibility LABEL: what an assistive client speaks
    /// for it. Deliberately separate from [`Tx::a11y_id`] — an automation
    /// key is not a spoken name. Leave it unset to keep whatever the
    /// platform derives from the control's own content; setting it
    /// OVERRIDES that.
    pub fn a11y_label(&mut self, widget: WidgetId, label: &str) {
        self.set(widget, Prop::A11yLabel, label);
    }

    /// This widget's accessibility HINT: what ACTIVATING it does, which is
    /// what every platform's hint means. Write it as a VERB PHRASE — "save
    /// the draft" — because VoiceOver speaks it as written while TalkBack
    /// prefixes "double tap to". Activation kinds only; the root rejects it
    /// elsewhere, since a hint with nothing to activate has no target on
    /// Android.
    pub fn a11y_hint(&mut self, widget: WidgetId, hint: &str) {
        self.set(widget, Prop::A11yHint, hint);
    }

    /// One-shot commands: momentary verbs into widget-owned state, riding
    /// this transaction like any write. Fire-and-forget — no state at
    /// rest, nothing to journal, and the widget answers through its normal
    /// occurrence path (a clear arrives back as TextChanged with empty
    /// text, so the app's draft fold empties itself).
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

    /// Put text into a text widget programmatically — the "open a document
    /// into the editor" write.
    ///
    /// SUGAR OVER THE GENERIC SETTER, and it earns its name because the
    /// widget is UNCONTROLLED: this is one write, handing the text back to
    /// the user who owns it from that moment. The field answers with its
    /// ordinary `text_changed` and the app's fold takes it from there.
    ///
    /// A write that CHANGES the text also drops whatever the app had
    /// declared over it: ranges are bound to the text they were declared
    /// against, and it spends the field's native undo history, which is why
    /// undo's D7 treats it as an episode boundary.
    pub fn set_text(&mut self, widget: WidgetId, text: &str) {
        self.set(widget, Prop::Text, text);
    }

    /// DECLARE the decorated ranges of a textarea, replacing whatever was
    /// declared before; an empty set is the clear.
    ///
    /// THE OFFSETS ARE RUST STRING INDICES — UTF-8 byte offsets into the
    /// widget's current text — so the ranges an app already has are the
    /// ranges kaya wants:
    ///
    /// ```ignore
    /// let hits: Vec<_> = doc.match_indices(needle)
    ///     .map(|(at, hit)| at..at + hit.len())
    ///     .collect();
    /// tx.highlight_ranges(editor, hits);
    /// ```
    ///
    /// kaya ships no search: what to highlight is the app's question, and
    /// a find engine belongs to the text editor (docs/ranges-plan.md §3).
    ///
    /// APP-OWNED AND NEVER TRACKED. A declared set is bound to the text it
    /// was declared against: the first edit of any kind drops it, and the
    /// app re-declares from the fold `text_changed` already drives.
    ///
    /// An offset past the end of the text, or one that splits a character,
    /// fails loudly here rather than in a backend: the five platforms
    /// answer a malformed offset five different ways and one aborts.
    pub fn highlight_ranges(
        &mut self,
        widget: WidgetId,
        ranges: impl IntoIterator<Item = std::ops::Range<usize>>,
    ) {
        self.ops.push(TxOp::HighlightRanges {
            widget,
            ranges: ranges
                .into_iter()
                .map(|r| TextRange::new(r.start as u64, r.end as u64))
                .collect(),
        });
    }

    /// Put the textarea's selection at one range (an empty range is a
    /// caret). Same offsets, same validation as
    /// [`Tx::highlight_ranges`].
    ///
    /// REFUSED WHILE THE USER IS COMPOSING through an input method, in
    /// every backend, because honouring it commits the composition
    /// mid-word — measured on macOS, where the half-typed kana land in
    /// the document and in the app's own model (docs/ranges-plan.md D4).
    /// The refusal is a no-op, not an error: composition state is on no
    /// kaya channel, so an app cannot avoid the race.
    pub fn select_range(&mut self, widget: WidgetId, range: std::ops::Range<usize>) {
        self.ops.push(TxOp::SelectRange {
            widget,
            range: TextRange::new(range.start as u64, range.end as u64),
        });
    }

    /// Scroll the textarea so a range is inside the viewport. A pure
    /// effect: undo does not put the scroll position back.
    pub fn reveal_range(&mut self, widget: WidgetId, range: std::ops::Range<usize>) {
        self.ops.push(TxOp::RevealRange {
            widget,
            range: TextRange::new(range.start as u64, range.end as u64),
        });
    }

    /// Construction sugar: a container takes its body as a closure and
    /// parents everything declared inside it through the ambient stack.
    /// The body's result rides the returned [`Widget`] as `.out`.
    pub fn column<R>(&mut self, body: impl FnOnce(&mut Self) -> R) -> Widget<'_, 'a, R> {
        self.container_of(WidgetKind::Column, body)
    }

    pub fn row<R>(&mut self, body: impl FnOnce(&mut Self) -> R) -> Widget<'_, 'a, R> {
        self.container_of(WidgetKind::Row, body)
    }

    /// A vertical scroll viewport over EXACTLY ONE child — declare
    /// the content container inside the body (the scene rejects a
    /// second child at the root). Vertical-only in v1.
    pub fn scroll<R>(&mut self, body: impl FnOnce(&mut Self) -> R) -> Widget<'_, 'a, R> {
        self.container_of(WidgetKind::Scroll, body)
    }

    /// A grid laying its children out row-major into `columns` columns —
    /// each column takes its NATURAL width, aligned across rows;
    /// `spacing` is the inter-cell gap on both axes.
    pub fn grid<R>(
        &mut self,
        columns: usize,
        body: impl FnOnce(&mut Self) -> R,
    ) -> Widget<'_, 'a, R> {
        let w = self.container_of(WidgetKind::Grid, body);
        let id = w.id;
        w.tx.set(id, Prop::Columns, columns as f64);
        Widget { id, out: w.out, tx: w.tx }
    }

    /// A spacer: PURE SUGAR for an empty grown column (weight 1). No new
    /// vocabulary — it lowers to what every backend already proves.
    pub fn spacer(&mut self) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Column);
        self.set(w, Prop::Grow, 1.0);
        Widget { id: w, out: (), tx: self }
    }

    fn container_of<R>(
        &mut self,
        kind: WidgetKind,
        body: impl FnOnce(&mut Self) -> R,
    ) -> Widget<'_, 'a, R> {
        let parent = self.widget(kind);
        self.parents.push(parent.0);
        let out = body(self);
        self.parents.pop();
        Widget { id: parent, out, tx: self }
    }

    /// A button with its caption.
    pub fn button(&mut self, text: &str) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Button);
        self.set(w, Prop::Text, text);
        Widget { id: w, out: (), tx: self }
    }

    /// A label bound to a signal.
    pub fn label(&mut self, signal: SignalId) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Label);
        self.bind(w, Prop::Text, signal);
        Widget { id: w, out: (), tx: self }
    }

    /// A single-line text field; edits arrive in the occurrence loop.
    pub fn entry(&mut self) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Entry);
        Widget { id: w, out: (), tx: self }
    }

    /// A multi-line text editor; the entry's uncontrolled contract
    /// (edits arrive in the occurrence loop, clear/focus commands
    /// apply) over the platform's real multi-line editor.
    pub fn textarea(&mut self) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Textarea);
        Widget { id: w, out: (), tx: self }
    }

    /// A labeled checkbox; toggles arrive in the occurrence loop.
    pub fn checkbox(&mut self, text: &str) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Checkbox);
        self.set(w, Prop::Text, text);
        Widget { id: w, out: (), tx: self }
    }

    /// A progress bar: display-only, like label and image. `value`
    /// is the determinate fraction (0..=1, domain-checked at the
    /// root); `progress_indeterminate` is the activity-mode arm.
    pub fn progress(&mut self, value: f64) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Progress);
        self.set(w, Prop::Value, value);
        Widget { id: w, out: (), tx: self }
    }

    /// A progress bar in the platform's activity mode (no fraction).
    pub fn progress_indeterminate(&mut self) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Progress);
        self.set(w, Prop::Indeterminate, true);
        Widget { id: w, out: (), tx: self }
    }

    /// A slider over min..max at value; moves arrive in the
    /// occurrence loop.
    pub fn slider(&mut self, min: f64, max: f64, value: f64) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Slider);
        self.set(w, Prop::Min, min);
        self.set(w, Prop::Max, max);
        self.set(w, Prop::Value, value);
        Widget { id: w, out: (), tx: self }
    }

    /// A slider whose position binds a float signal. Property writes never
    /// echo an occurrence, so a handler's own writes cannot loop back.
    pub fn slider_bound(&mut self, min: f64, max: f64, value: SignalId) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Slider);
        self.set(w, Prop::Min, min);
        self.set(w, Prop::Max, max);
        self.bind(w, Prop::Value, value);
        Widget { id: w, out: (), tx: self }
    }

    /// A dropdown select over its options — each option becomes a label
    /// child (labels only, scene-checked), `selected` the initial 0-based
    /// index (domain-checked at the root against the option count).
    pub fn select(&mut self, options: &[&str], selected: usize) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Select);
        self.parents.push(w.0);
        for option in options {
            let label = self.widget(WidgetKind::Label);
            self.set(label, Prop::Text, *option);
        }
        self.parents.pop();
        self.set(w, Prop::Value, selected as f64);
        Widget { id: w, out: (), tx: self }
    }

    /// A radio group over its options — the choice contract
    /// ([`Self::select`]) in its inline presentation; same option
    /// children, same index semantics, same [`Messages::on_select`].
    pub fn radio(&mut self, options: &[&str], selected: usize) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Radio);
        self.parents.push(w.0);
        for option in options {
            let label = self.widget(WidgetKind::Label);
            self.set(label, Prop::Text, *option);
        }
        self.parents.pop();
        self.set(w, Prop::Value, selected as f64);
        Widget { id: w, out: (), tx: self }
    }

    /// An image displaying encoded bytes: the toolkit decodes natively.
    /// The bytes ride the blob channel — one Arc'd copy in core memory, an
    /// 8-byte handle everywhere else — so a large image costs one
    /// registration copy and a decode, never a per-update re-copy.
    pub fn image(&mut self, bytes: impl Into<crate::protocol::Blob>) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Image);
        self.set(w, Prop::Source, Value::Blob(bytes.into()));
        Widget { id: w, out: (), tx: self }
    }

    /// Declare a collection of `T` records: a core-side keyed table a For
    /// renders. The element type IS the schema — `T::VARIANTS` goes on the
    /// wire here, one field-type list per constructor.
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
        // ABSORPTION, on the one path every explicit key travels: a
        // numeric key at or above the minter's counter carries it up, so
        // hand-chosen and minted keys share one space safely.
        self.ctx.absorb_key(instance.id, &instance.path, &key);
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

    /// Insert a record under a key the binding authors, and hand the key
    /// back.
    ///
    /// FOR DATA THAT HAS NO IDENTITY OF ITS OWN. Keys are domain identity
    /// and guest-chosen (DESIGN.md, the update algebra), so anything that
    /// already HAS a name passes it to [`insert`](Tx::insert). This is the
    /// other case, and the alternative is a hand-spelled counter beside
    /// the collection whose safety rests on a rule nobody wrote down.
    ///
    /// ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted key
    /// is `I64` and is counter+1. An instance is a table — the live-zone
    /// collection, or one stamped copy — and keys are unique within one.
    ///
    /// MIXING IS SAFE BY ABSORPTION: an explicit `insert` whose key is an
    /// I64 at or above the counter carries it up. A non-numeric key cannot
    /// collide with an I64 at all.
    ///
    /// NO DECREMENT IS EXPRESSIBLE. Undo and redo replay captured keys
    /// inside the core and never re-enter this path; an abandoned
    /// transaction does not move it back either (the rollback journal
    /// restores the model, not the counter). A fresh key is fresh forever.
    pub fn insert_fresh<T: KayaSum>(
        &mut self,
        instance: &Collection<T>,
        value: impl Into<T>,
    ) -> i64 {
        let key = self.ctx.mint_key(instance.id, &instance.path);
        self.insert(instance, key, value);
        key
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

    /// One field's delta on one constructor, carrying the discriminant the
    /// caller witnessed in the match. Hidden because reaching it without
    /// that match would be exactly the unwitnessed write the surface
    /// exists to prevent.
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

    /// Reposition an entry before another's: order is collection data, so
    /// the model reorders and the wire carries the same keys-only delta.
    /// Keys, never indices. A missing key or anchor fails here, at the call
    /// site; moving an entry before itself is a no-op.
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

    /// A For over `collection`: the closure declares the template, a
    /// blueprint stamped once per entry. Returns the For's widget id
    /// alongside the body's result, which is how handles declared inside
    /// the template reach the handlers.
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
    /// totality the way a match holds its arms.
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
        self.mount_in(DEFAULT_WINDOW, root);
    }

    /// Mount a root into a specific window — mounting presents an
    /// auxiliary.
    pub fn mount_in(&mut self, window: WindowId, root: WidgetId) {
        self.ops.push(TxOp::Mount { window, root });
    }

    // --- Menus: the dynamic floor and the transaction-level sugar ------
    //
    // Menu items live in their OWN guest-allocated id space, so cross-use
    // with a widget or surface id is a compile error. Items never host
    // content and never participate in layout — declaring one inside a
    // container body parents NOTHING through the ambient stack. Topology
    // is append-only and live; nothing is removed in v1 (DESIGN.md,
    // Menus).

    /// The floor: create a menu item of `kind` in the menu-item id
    /// space. The chains above ([`WindowRef::menu`],
    /// [`Tx::context_menu`], [`Tx::menu`]) ride exactly this.
    pub fn menu_item(&mut self, kind: MenuItemKind) -> MenuItemId {
        let item = self.ctx.alloc_menu_item();
        self.ops.push(TxOp::MenuItemCreate { item, kind });
        item
    }

    /// The floor: append `child` under grouping node `parent`
    /// (single-parent). The closed grammar and the depth cap are root
    /// errors.
    pub fn append_menu_item(&mut self, parent: MenuItemId, child: MenuItemId) {
        self.ops.push(TxOp::MenuItemAppend { parent, child });
    }

    /// The floor: append a top-level grouping node to `window`'s command
    /// catalog. The sugar spelling is [`WindowRef::menu`] /
    /// [`WindowRef::radio_group`].
    pub fn menubar_append(&mut self, window: WindowId, item: MenuItemId) {
        self.ops.push(TxOp::MenubarAppend { window, item });
    }

    /// Set a menu property to a constant ([`MenuProp`]; the floor the menu
    /// chains ride). A `shortcut` set through the floor must already be the
    /// CANONICAL wire spelling — the core validates and rejects, it never
    /// rewrites guest data. The chains normalize before emitting.
    pub fn set_menu_prop(&mut self, item: MenuItemId, prop: MenuProp, value: impl Into<Value>) {
        self.ops.push(TxOp::SetMenuProp {
            item,
            prop,
            value: PropValue::Const(value.into()),
        });
    }

    /// Bind a signal-bindable menu property (`label`, `enabled`,
    /// `checked`, `value`). `icon`, `primary` and `shortcut` are
    /// const-only — the root rejects a signal source on them.
    pub fn bind_menu_prop(&mut self, item: MenuItemId, prop: MenuProp, signal: SignalId) {
        self.ops.push(TxOp::SetMenuProp {
            item,
            prop,
            value: PropValue::Signal(signal),
        });
    }

    /// The floor: attach context-catalog root `item` to a live widget.
    /// Entry and Textarea reject attachment at the root — the editable
    /// text controls keep their native edit menus (dress).
    pub fn context_attach(&mut self, widget: WidgetId, item: MenuItemId) {
        self.ops.push(TxOp::ContextAttach { widget, item });
    }

    /// A context menu on a LIVE widget: the body declares the catalog's
    /// root items, each created and attached eagerly, and returns the
    /// body's result. Calling it again on the same widget appends more
    /// roots.
    ///
    /// Zone rules: this is the live-widget anchor. A template node takes
    /// [`Tx::context_catalog`] + [`Tpl::context_menu`] instead — items are
    /// live and shared across stamped copies, so the catalog is built
    /// before the template and only the attachment happens inside it.
    /// Context items take no shortcuts: spelled one is a compile error
    /// here, not a runtime one.
    pub fn context_menu<R>(
        &mut self,
        widget: WidgetId,
        body: impl FnOnce(&mut MenuItems<'_, 'a, ContextAnchor>) -> R,
    ) -> R {
        let mut items = MenuItems {
            tx: self,
            slot: ItemSlot::Widget(widget),
            roots: Vec::new(),
            _anchor: PhantomData,
        };
        body(&mut items)
    }

    /// Build a context catalog UNANCHORED — free root items for a
    /// template-node anchor. Menu items are live and shared across stamped
    /// copies, and the protocol forbids creating them inside a template
    /// scope: the catalog is built here, in the live zone, and
    /// [`Tpl::context_menu`] attaches it inside the template, where
    /// activations carry the copy's key path. The borrow checker already
    /// holds the zone wall:
    ///
    /// ```compile_fail
    /// fn zone_rule(tx: &mut kaya::Tx<'_>, groups: &kaya::Collection<String>) {
    ///     tx.for_each(groups, |t| {
    ///         tx.context_catalog(|m| {}); // cannot borrow `tx`: the body records a blueprint
    ///     });
    /// }
    /// ```
    pub fn context_catalog<R>(
        &mut self,
        body: impl FnOnce(&mut MenuItems<'_, 'a, ContextAnchor>) -> R,
    ) -> ContextCatalog<R> {
        let mut items = MenuItems {
            tx: self,
            slot: ItemSlot::Free,
            roots: Vec::new(),
            _anchor: PhantomData,
        };
        let out = body(&mut items);
        let roots = std::mem::take(&mut items.roots);
        ContextCatalog { out, roots }
    }

    /// The prop/append proxy for a RETAINED menu item — the [`Tx::window`]
    /// precedent, and the append-at-any-time spelling. Props mutate freely
    /// on every kind the prop applies to; the root rejects a misapplied
    /// prop. Programmatic `checked`/`value` writes are configuration and
    /// stay QUIET (the echo doctrine).
    pub fn menu(&mut self, item: MenuItemId) -> MenuItemRef<'_, 'a> {
        MenuItemRef { tx: self, item }
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
/// The for-statement tracer over a collection's rows: the loop body runs
/// once, authoring the blueprint, and the row's Drop closes the template
/// and parents the For into the enclosing container scope. RAII makes the
/// close structural: break- and panic-safe, and while the row lives the
/// transaction is statically unreachable except through it.
pub struct Rows<'t, 'b> {
    tx: Option<&'t mut Tx<'b>>,
    collection: CollectionId,
    /// Which id space this For's own node comes from — see
    /// [`ForScope`].
    nested: bool,
}

impl<'t, 'b> Iterator for Rows<'t, 'b> {
    type Item = Row<'t, 'b>;

    fn next(&mut self) -> Option<Row<'t, 'b>> {
        let tx = self.tx.take()?;
        let id = if self.nested {
            tx.ctx.alloc_node().0
        } else {
            tx.ctx.alloc_widget().0
        };
        let parent = tx.current_parent();
        tx.ops.push(TxOp::CreateFor {
            id,
            collection: self.collection,
        });
        tx.ctx.open_fors.borrow_mut().push(self.collection);
        tx.parents.push(0);
        Some(Row {
            tx: Some(tx),
            for_id: id,
            parent,
        })
    }
}

/// SEALED, AND SEALED FOR A REASON: the whole mechanism is `zone_tx`,
/// which hands out the transaction from inside a template body —
/// precisely what the template-zone discipline forbids. A
/// `#[doc(hidden)]` method would still be callable; a trait in a private
/// module cannot even be brought into scope outside this crate.
mod for_scope {
    use super::Tx;

    pub trait Zone<'b> {
        /// True inside a template body. Decides the id space of the
        /// For's own node, and nothing else — the records, the
        /// auto-parenting and the close are identical at both depths.
        const NESTED: bool;
        fn zone_tx(&mut self) -> &mut Tx<'b>;
    }
}

/// The zone a For is being traced in: the live tree (a [`Tx`]) or another
/// template's body (a [`Tpl`], or a [`Row`] directly).
/// [`Collection::rows`] takes either, so a nested For is the same for
/// statement one level in.
///
/// The zones differ in exactly one thing: a For declared inside a template
/// is itself a template node, and template nodes are a separate id space
/// from live widgets.
///
/// Taking a scope does NOT hand the transaction back to the guest — the
/// one method that could is sealed away. Pinned here rather than trusted:
///
/// ```compile_fail
/// fn zone_rule(t: &mut kaya::Tpl<'_, '_>, todos: &kaya::Collection<String>) {
///     t.zone_tx().len(todos); // no such method: the trait is unnameable
/// }
/// ```
pub trait ForScope<'b>: for_scope::Zone<'b> {}

impl<'b, T: for_scope::Zone<'b>> ForScope<'b> for T {}

impl<'b> for_scope::Zone<'b> for Tx<'b> {
    const NESTED: bool = false;
    fn zone_tx(&mut self) -> &mut Tx<'b> {
        self
    }
}

impl<'b> for_scope::Zone<'b> for Tpl<'_, 'b> {
    const NESTED: bool = true;
    fn zone_tx(&mut self) -> &mut Tx<'b> {
        self.tx
    }
}

impl<'b> for_scope::Zone<'b> for Row<'_, 'b> {
    const NESTED: bool = true;
    fn zone_tx(&mut self) -> &mut Tx<'b> {
        self.tx.as_mut().expect("kaya: row used after close")
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

    pub fn button(&mut self, src: impl Into<TplSource<StrKind>>) -> TemplateNodeId {
        self.tpl().button(src)
    }

    pub fn row<R>(&mut self, body: impl FnOnce(&mut Tpl<'_, 'b>) -> R) -> (TemplateNodeId, R) {
        self.tpl().row(body)
    }

    pub fn column<R>(&mut self, body: impl FnOnce(&mut Tpl<'_, 'b>) -> R) -> (TemplateNodeId, R) {
        self.tpl().column(body)
    }

    // THE REST OF THE ZONE, forwarded. Row is the for-STATEMENT façade
    // over the same template, so a constructor that exists on Tpl and not
    // here is reachable through `for row in rows` and not through
    // `for_each` — a difference no guest should have to know. The pair is
    // held level by check-sugar-surface's Row clause.

    pub fn entry(&mut self) -> TemplateNodeId {
        self.tpl().entry()
    }

    pub fn entry_bound(&mut self, src: impl Into<TplSource<StrKind>>) -> TemplateNodeId {
        self.tpl().entry_bound(src)
    }

    pub fn textarea(&mut self) -> TemplateNodeId {
        self.tpl().textarea()
    }

    pub fn textarea_bound(&mut self, src: impl Into<TplSource<StrKind>>) -> TemplateNodeId {
        self.tpl().textarea_bound(src)
    }

    pub fn scroll<R>(&mut self, body: impl FnOnce(&mut Tpl<'_, 'b>) -> R) -> (TemplateNodeId, R) {
        self.tpl().scroll(body)
    }

    pub fn grid<R>(
        &mut self,
        columns: usize,
        body: impl FnOnce(&mut Tpl<'_, 'b>) -> R,
    ) -> (TemplateNodeId, R) {
        self.tpl().grid(columns, body)
    }

    pub fn spacer(&mut self) -> TemplateNodeId {
        self.tpl().spacer()
    }

    pub fn progress(&mut self, src: impl Into<TplSource<F64Kind>>) -> TemplateNodeId {
        self.tpl().progress(src)
    }

    pub fn progress_indeterminate(&mut self) -> TemplateNodeId {
        self.tpl().progress_indeterminate()
    }

    pub fn slider(
        &mut self,
        min: f64,
        max: f64,
        src: impl Into<TplSource<F64Kind>>,
    ) -> TemplateNodeId {
        self.tpl().slider(min, max, src)
    }

    pub fn select(
        &mut self,
        options: &[&str],
        src: impl Into<TplSource<F64Kind>>,
    ) -> TemplateNodeId {
        self.tpl().select(options, src)
    }

    pub fn radio(
        &mut self,
        options: &[&str],
        src: impl Into<TplSource<F64Kind>>,
    ) -> TemplateNodeId {
        self.tpl().radio(options, src)
    }

    pub fn image(&mut self, src: impl Into<TplSource<BlobKind>>) -> TemplateNodeId {
        self.tpl().image(src)
    }

    pub fn a11y_id(&mut self, node: TemplateNodeId, src: impl Into<TplSource<StrKind>>) {
        self.tpl().a11y_id(node, src)
    }

    pub fn a11y_label(&mut self, node: TemplateNodeId, src: impl Into<TplSource<StrKind>>) {
        self.tpl().a11y_label(node, src)
    }

    pub fn a11y_hint(&mut self, node: TemplateNodeId, src: impl Into<TplSource<StrKind>>) {
        self.tpl().a11y_hint(node, src)
    }

    pub fn accepts(&mut self, node: TemplateNodeId, kinds: &[crate::Accepts<'_>]) {
        self.tpl().accepts(node, kinds)
    }

    pub fn role(&mut self, node: TemplateNodeId, role: crate::Role) {
        self.tpl().role(node, role)
    }

    pub fn inset(&mut self, node: TemplateNodeId, pad: f64) {
        self.tpl().inset(node, pad)
    }

    // Forwarded because a ROW TRACE legitimately anchors context menus.
    // context_menu left tpl-surfaces.py's NOT_FORWARDED set in the same
    // change, so the pair is HELD level rather than merely level;
    // context_attach (the raw item-id/node floor) stays excluded.
    pub fn context_menu<R>(&mut self, node: TemplateNodeId, catalog: ContextCatalog<R>) -> R {
        self.tpl().context_menu(node, catalog)
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
/// vocabulary. The guest declares its meaning enum, registers each
/// widget's mapping beside the widget, and folds one exhaustive match.
/// The registry converts runtime identity into the enum's tag, so the loop
/// needs no guards; a declared variant no widget produces trips rustc's
/// dead_code lint. Unmapped occurrences fold into nothing; Shutdown ends
/// the stream. The raw loop over `ctx.next()` stays the floor.
pub struct Messages<M> {
    // Widget ids and template-node ids collide numerically — two id
    // spaces, two tables.
    widgets: RefCell<HashMap<u64, Mapper<M>>>,
    nodes: RefCell<HashMap<u64, Mapper<M>>>,
    // Menu items are their own id space — their own table ("two
    // tables, always" is N tables by now, still always).
    menu_items: RefCell<HashMap<u64, Mapper<M>>>,
    // Window lifecycle: one handler each, receiving the window id —
    // close events are app-global grammar, not per-widget wiring.
    close_requested: RefCell<HashMap<u64, Box<dyn Fn() -> M>>>,
    window_closed: RefCell<HashMap<u64, Box<dyn Fn() -> M>>>,
    back_requested: RefCell<HashMap<u64, Box<dyn Fn() -> M>>>,
    entry_popped: RefCell<HashMap<u64, Box<dyn Fn() -> M>>>,
    section_selected: RefCell<HashMap<u64, Box<dyn Fn() -> M>>>,
    alerts: RefCell<HashMap<u64, Box<dyn Fn(AlertChoice) -> M>>>,
    /// Per-dialog, one-shot like an alert: the registration retires with
    /// the one result, so no guest ever inspects a dialog id.
    dialogs: RefCell<HashMap<u64, Box<dyn Fn(Vec<crate::protocol::PickedFile>) -> M>>>,
    /// Per-read, one-shot like a dialog. `None` is the universal no —
    /// denied, unfocused, empty, or nothing the request accepted — and
    /// the guest is not told which, because no platform says.
    clip_reads: RefCell<
        HashMap<u64, Box<dyn Fn(Option<crate::protocol::Representation>) -> M>>,
    >,
    /// Per-window and PERSISTENT — the on_section_selected shape, not
    /// the one-shot request shape: a window's history is walked as many
    /// times as the user likes, and the ledger is per window.
    undone: RefCell<HashMap<u64, Box<dyn Fn(String, crate::protocol::UndoDelta) -> M>>>,
    redone: RefCell<HashMap<u64, Box<dyn Fn(String, crate::protocol::UndoDelta) -> M>>>,
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
            menu_items: RefCell::new(HashMap::new()),
            close_requested: RefCell::new(HashMap::new()),
            window_closed: RefCell::new(HashMap::new()),
            back_requested: RefCell::new(HashMap::new()),
            entry_popped: RefCell::new(HashMap::new()),
            section_selected: RefCell::new(HashMap::new()),
            alerts: RefCell::new(HashMap::new()),
            dialogs: RefCell::new(HashMap::new()),
            clip_reads: RefCell::new(HashMap::new()),
            undone: RefCell::new(HashMap::new()),
            redone: RefCell::new(HashMap::new()),
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

    /// A select's picks: the new 0-based option index. Rides the
    /// value_changed record (the index travels as f64), so this is
    /// on_value with the index reading.
    pub fn on_select(&self, w: WidgetId, f: impl Fn(usize) -> M + 'static) {
        self.on_value(w, move |v| f(v as usize));
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

    /// A stamped copy's paste, with the copy's key path — the node flavor
    /// of [`Self::on_paste`]. Rust was the one binding of eight without
    /// this registrar while the other seven had the registrar and no way
    /// to spell `accepts` on a template node, so the hook was dead in all
    /// eight (docs/tpl-props-plan.md §1).
    ///
    /// Fires only for copies whose TEMPLATE declared what it accepts
    /// (`Tpl::accepts`) — without a declaration the platform's own
    /// insertion happens and the instance change handler reports it.
    pub fn on_paste_node(
        &self,
        n: TemplateNodeId,
        f: impl Fn(Path, crate::protocol::Representation) -> M + 'static,
    ) {
        self.nodes.borrow_mut().insert(
            n.0,
            Box::new(move |occ| match occ {
                Occurrence::InstancePasted { path, clip, .. } => {
                    Some(f(path.clone(), clip.clone()))
                }
                _ => None,
            }),
        );
    }

    /// A menu action's activation means this message. The action's click
    /// and its shortcut are ONE occurrence on one dispatch path, so this
    /// handler covers both.
    pub fn on_menu_item(&self, item: MenuItemId, msg: M)
    where
        M: Clone + 'static,
    {
        self.menu_items.borrow_mut().insert(
            item.0,
            Box::new(move |occ| match occ {
                Occurrence::MenuActivated { .. } => Some(msg.clone()),
                _ => None,
            }),
        );
    }

    /// A menu toggle's user flips map through `f` with the new state.
    /// Programmatic `checked` writes are quiet (the Checkbox contract).
    pub fn on_menu_toggle(&self, item: MenuItemId, f: impl Fn(bool) -> M + 'static) {
        self.menu_items.borrow_mut().insert(
            item.0,
            Box::new(move |occ| match occ {
                Occurrence::MenuToggled { checked, .. } => Some(f(*checked)),
                _ => None,
            }),
        );
    }

    /// A menu radio group's user picks: the new 0-based option index,
    /// registered on the GROUP handle. Programmatic `value` writes are
    /// quiet.
    pub fn on_menu_select(&self, group: MenuItemId, f: impl Fn(usize) -> M + 'static) {
        self.menu_items.borrow_mut().insert(
            group.0,
            Box::new(move |occ| match occ {
                Occurrence::MenuValueChanged { index, .. } => Some(f(*index as usize)),
                _ => None,
            }),
        );
    }

    /// The Tpl-zone flavor of [`Messages::on_menu_item`]: the occurrence
    /// carries the stamped copy's key path, outermost first — the keys ARE
    /// the noun the command acts on.
    pub fn on_menu_item_node(&self, item: MenuItemId, f: impl Fn(Path) -> M + 'static) {
        self.menu_items.borrow_mut().insert(
            item.0,
            Box::new(move |occ| match occ {
                Occurrence::InstanceMenuActivated { path, .. } => Some(f(path.clone())),
                _ => None,
            }),
        );
    }

    /// The Tpl-zone flavor of [`Messages::on_menu_toggle`]: the copy's
    /// key path plus the new state.
    pub fn on_menu_toggle_node(&self, item: MenuItemId, f: impl Fn(Path, bool) -> M + 'static) {
        self.menu_items.borrow_mut().insert(
            item.0,
            Box::new(move |occ| match occ {
                Occurrence::InstanceMenuToggled { path, checked, .. } => {
                    Some(f(path.clone(), *checked))
                }
                _ => None,
            }),
        );
    }

    /// The Tpl-zone flavor of [`Messages::on_menu_select`]: the copy's
    /// key path plus the new 0-based option index.
    pub fn on_menu_select_node(&self, group: MenuItemId, f: impl Fn(Path, usize) -> M + 'static) {
        self.menu_items.borrow_mut().insert(
            group.0,
            Box::new(move |occ| match occ {
                Occurrence::InstanceMenuValueChanged { path, index, .. } => {
                    Some(f(path.clone(), *index as usize))
                }
                _ => None,
            }),
        );
    }

    /// Bind the close-veto handler to ONE window (the veto class: nothing
    /// has closed; answer with destroy_window to agree). Fires per chrome
    /// close while veto_close is armed.
    pub fn on_close_requested(&self, window: WindowId, msg: M)
    where
        M: Clone + 'static,
    {
        self.close_requested
            .borrow_mut()
            .insert(window.0, Box::new(move || msg.clone()));
    }

    /// Bind the closed handler to ONE window: fires when the non-veto
    /// auxiliary is chrome-closed, and the registration retires with it —
    /// a window closes at most once (ids never reused).
    pub fn on_window_closed(&self, window: WindowId, msg: M)
    where
        M: Clone + 'static,
    {
        self.window_closed
            .borrow_mut()
            .insert(window.0, Box::new(move || msg.clone()));
    }

    /// Bind the back-veto handler to ONE entry: fires each time the user
    /// drives back on it while intercept_back is armed — nothing has
    /// popped; answer with pop_entry to agree.
    pub fn on_back_requested(&self, entry: WindowId, msg: M)
    where
        M: Clone + 'static,
    {
        self.back_requested
            .borrow_mut()
            .insert(entry.0, Box::new(move || msg.clone()));
    }

    /// Bind the popped handler to ONE entry: fires when the user's back
    /// affordance pops it natively (post-fact), and the registration
    /// retires with it. A programmatic pop_entry does not fire it.
    pub fn on_entry_popped(&self, entry: WindowId, msg: M)
    where
        M: Clone + 'static,
    {
        self.entry_popped
            .borrow_mut()
            .insert(entry.0, Box::new(move || msg.clone()));
    }

    /// Bind the selected handler to ONE section: fires each time the user
    /// switches TO it through the platform's switcher (post-fact). Not
    /// one-shot — sections never die.
    pub fn on_section_selected(&self, section: WindowId, msg: M)
    where
        M: Clone + 'static,
    {
        self.section_selected
            .borrow_mut()
            .insert(section.0, Box::new(move || msg.clone()));
    }

    /// Bind the one-shot result handler to a REQUEST (the id
    /// [`AlertRef::show`] returned): an action index or Cancel. The
    /// registration retires with the result — correlation is the
    /// library's, never the guest's.
    pub fn on_alert(&self, alert: AlertId, f: impl Fn(AlertChoice) -> M + 'static) {
        self.alerts.borrow_mut().insert(alert.0, Box::new(f));
    }

    /// Bind the one-shot result handler to a file-dialog request. Cancel
    /// arrives as an EMPTY list — no platform can confirm an empty
    /// selection, so it needs no sentinel.
    pub fn on_files(
        &self,
        dialog: crate::protocol::FileDialogId,
        f: impl Fn(Vec<crate::protocol::PickedFile>) -> M + 'static,
    ) {
        self.dialogs.borrow_mut().insert(dialog.0, Box::new(f));
    }

    /// Bind the one-shot result handler to a save-dialog request. CANCEL
    /// IS `None`: the wire's "one locator or none" is a fact of the
    /// request, not something every app should re-derive from a length.
    pub fn on_saved(
        &self,
        dialog: crate::protocol::FileDialogId,
        f: impl Fn(Option<crate::protocol::PickedFile>) -> M + 'static,
    ) {
        self.dialogs
            .borrow_mut()
            .insert(dialog.0, Box::new(move |files| f(files.into_iter().next())));
    }

    /// Content arriving at this widget because the USER pasted — the path
    /// an editor actually takes, and the one that costs nothing.
    ///
    /// A GESTURE IS ITS OWN AUTHORISATION: iOS raises no prompt for a
    /// paste, and the focus rules Android and Wayland impose are satisfied
    /// by construction. [`Tx::read_clipboard`] pays a permission prompt for
    /// content this delivers free.
    ///
    /// Fires only for widgets that DECLARED what they accept
    /// ([`Tx::accepts`]).
    pub fn on_paste(
        &self,
        w: WidgetId,
        f: impl Fn(crate::protocol::Representation) -> M + 'static,
    ) {
        self.widgets.borrow_mut().insert(
            w.0,
            Box::new(move |occ| match occ {
                Occurrence::Pasted { clip, .. } => Some(f(clip.clone())),
                _ => None,
            }),
        );
    }

    /// Bind the undone handler to ONE window: fires each time kaya routes
    /// an undo there, with the group's label (EMPTY for a typing episode)
    /// and what the core put back.
    ///
    /// NOT ONE-SHOT — a history is walked as often as the user likes. Per
    /// window because the ledger is: Undo in one window has never meant
    /// "revert what happened in another".
    ///
    /// THE DELTA IS THE ONLY NOTIFICATION. Applying an inverse is a
    /// programmatic write, so the echo doctrine silences every occurrence
    /// it would otherwise cause. The binding has already folded this
    /// payload into its own collection mirror before the handler runs.
    pub fn on_undone(
        &self,
        window: WindowId,
        f: impl Fn(String, crate::protocol::UndoDelta) -> M + 'static,
    ) {
        self.undone.borrow_mut().insert(window.0, Box::new(f));
    }

    /// The [`Messages::on_undone`] twin. A frontier typing episode
    /// redoes on the platform's own stack and reports itself as an
    /// ordinary edit, so it does not arrive here.
    pub fn on_redone(
        &self,
        window: WindowId,
        f: impl Fn(String, crate::protocol::UndoDelta) -> M + 'static,
    ) {
        self.redone.borrow_mut().insert(window.0, Box::new(f));
    }

    /// Bind the one-shot result handler to a clipboard read. The answer
    /// is at most one representation; `None` covers every way the
    /// platform declines to hand one over, and it is not an error.
    pub fn on_clipboard(
        &self,
        request: u64,
        f: impl Fn(Option<crate::protocol::Representation>) -> M + 'static,
    ) {
        self.clip_reads.borrow_mut().insert(request, Box::new(f));
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
                | Occurrence::ValueChanged { id, .. }
                | Occurrence::Pasted { id, .. } => {
                    self.widgets.borrow().get(&id.0).and_then(|f| f(&occ))
                }
                Occurrence::InstanceButtonClicked { node, .. }
                | Occurrence::InstanceTextChanged { node, .. }
                | Occurrence::InstanceToggled { node, .. }
                | Occurrence::InstanceValueChanged { node, .. }
                | Occurrence::InstancePasted { node, .. } => {
                    self.nodes.borrow().get(&node.0).and_then(|f| f(&occ))
                }
                Occurrence::CloseRequested { window } => {
                    self.close_requested.borrow().get(&window.0).map(|f| f())
                }
                Occurrence::WindowClosed { window } => {
                    // One-shot: the window is gone; both registrations
                    // retire with it.
                    self.close_requested.borrow_mut().remove(&window.0);
                    self.window_closed.borrow_mut().remove(&window.0).map(|f| f())
                }
                Occurrence::AlertResult { alert, choice } => {
                    // One-shot: the registration retires with the result.
                    self.alerts.borrow_mut().remove(&alert.0).map(|f| f(*choice))
                }
                Occurrence::FileDialogResult { dialog, files } => {
                    // One-shot, exactly as the alert: the registration
                    // retires with the result. Cancel arrives here as an
                    // EMPTY list, not a sentinel.
                    self.dialogs
                        .borrow_mut()
                        .remove(&dialog.0)
                        .map(|f| f(files.clone()))
                }
                Occurrence::ClipboardResult { request, clip } => {
                    // One-shot, exactly as the dialog: the registration
                    // retires with the answer, empty or not.
                    self.clip_reads
                        .borrow_mut()
                        .remove(request)
                        .map(|f| f(clip.clone()))
                }
                Occurrence::BackRequested { entry } => {
                    self.back_requested.borrow().get(&entry.0).map(|f| f())
                }
                Occurrence::EntryPopped { entry } => {
                    // One-shot: the entry is gone; both registrations
                    // retire with it.
                    self.back_requested.borrow_mut().remove(&entry.0);
                    self.entry_popped.borrow_mut().remove(&entry.0).map(|f| f())
                }
                Occurrence::SectionSelected { section, .. } => {
                    // NOT one-shot: sections never die and the user can
                    // return any number of times. Keyed by section —
                    // handlers scope to their creator.
                    self.section_selected.borrow().get(&section.0).map(|f| f())
                }
                // Menu occurrences key the menu-item table — their own id
                // space. Direct and node-anchored variants share it: an
                // item has exactly one anchor, so its registered mapper
                // matches the one variant that anchor can emit.
                Occurrence::MenuActivated { item }
                | Occurrence::InstanceMenuActivated { item, .. }
                | Occurrence::MenuToggled { item, .. }
                | Occurrence::InstanceMenuToggled { item, .. } => {
                    self.menu_items.borrow().get(&item.0).and_then(|f| f(&occ))
                }
                Occurrence::MenuValueChanged { group, .. }
                | Occurrence::InstanceMenuValueChanged { group, .. } => {
                    self.menu_items.borrow().get(&group.0).and_then(|f| f(&occ))
                }
                // NOT one-shot, and keyed by window. The collection mirror
                // was already reconciled in AppCtx::next, so a handler that
                // reads back sees the restored state.
                Occurrence::Undone { window, label, delta } => self
                    .undone
                    .borrow()
                    .get(&window.0)
                    .map(|f| f(label.clone(), delta.clone())),
                Occurrence::Redone { window, label, delta } => self
                    .redone
                    .borrow()
                    .get(&window.0)
                    .map(|f| f(label.clone(), delta.clone())),
            };
            if let Some(m) = mapped {
                return Some(m);
            }
        }
    }
}

/// The alert chain, in the construction-sugar tier: accumulates the
/// one atomic SHOW_ALERT record and sends it at [`AlertRef::show`]
/// (a request has a send moment, unlike a window declaration — hence
/// the terminal method, and #[must_use] so a chain that never shows
/// is a compiler warning, not a silent no-op).
#[must_use = "an alert chain sends nothing until .show()"]
pub struct AlertRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    spec: AlertSpec,
}

/// A file-picker request under construction — the alert chain's shape,
/// terminated by `show`.
pub struct FileDialogRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    spec: crate::protocol::FileDialogSpec,
}

impl FileDialogRef<'_, '_> {
    /// Present over this window instead of the primary.
    pub fn in_window(mut self, window: WindowId) -> Self {
        self.spec.window = window;
        self
    }

    /// Add an ADVISORY filter: a label and its extensions. Every
    /// platform treats these as a default view rather than a guarantee,
    /// so validate what you actually got.
    pub fn filter(mut self, label: impl Into<String>, extensions: impl Into<String>) -> Self {
        self.spec.filters.push((label.into(), extensions.into()));
        self
    }

    /// Send the request, returning its id — the handle
    /// [`Messages::on_files`] binds the one-shot result handler to.
    pub fn show(self) -> crate::protocol::FileDialogId {
        let id = self.spec.dialog;
        self.tx.ops.push(TxOp::ShowFileDialog(self.spec));
        id
    }
}

/// A save-dialog request under construction — the picker chain's shape,
/// terminated by `show`. The suggested name is not optional and rides the
/// constructor: a save dialog with no name in its box is one the platform
/// will not let the user complete.
pub struct SaveDialogRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    spec: crate::protocol::SaveDialogSpec,
}

impl SaveDialogRef<'_, '_> {
    /// Present over this window instead of the primary.
    pub fn in_window(mut self, window: WindowId) -> Self {
        self.spec.window = window;
        self
    }

    /// Add an ADVISORY filter: a label and its extensions, the picker's
    /// rule verbatim — a default view, never a guarantee.
    pub fn filter(mut self, label: impl Into<String>, extensions: impl Into<String>) -> Self {
        self.spec.filters.push((label.into(), extensions.into()));
        self
    }

    /// Send the request, returning its id — the handle
    /// [`Messages::on_saved`] binds the one-shot result handler to.
    pub fn show(self) -> crate::protocol::FileDialogId {
        let id = self.spec.dialog;
        self.tx.ops.push(TxOp::ShowSaveDialog(self.spec));
        id
    }
}

/// The copy chain: a clip record under construction. Each method fills one
/// representation, and the terminal puts it on the clipboard. A RECORD AND
/// NOT A LIST: a second `text` call replaces the field rather than needing
/// a duplicate check.
#[must_use = "a copy chain puts nothing on the clipboard until .send()"]
pub struct CopyRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    clip: crate::protocol::Clip,
}

impl CopyRef<'_, '_> {
    pub fn text(mut self, text: impl Into<String>) -> Self {
        self.clip.text = Some(text.into());
        self
    }

    pub fn html(mut self, html: impl Into<String>) -> Self {
        self.clip.html = Some(html.into());
        self
    }

    /// Encoded image bytes — the same currency the image property
    /// takes. What comes BACK from a paste may be a re-encode: the
    /// hosts convert freely between image types, so compare what the
    /// image IS, not the bytes it arrived in.
    pub fn image(mut self, bytes: impl Into<std::sync::Arc<[u8]>>) -> Self {
        self.clip.image = Some(crate::protocol::Blob(bytes.into()));
        self
    }

    /// Offer a picked file — the picker's own capability, put straight
    /// on the clipboard. The bytes never move through kaya.
    pub fn file(mut self, handle: crate::protocol::PickedId) -> Self {
        self.clip.files.push(handle);
        self
    }

    /// An app-defined format, round-tripped verbatim. The id reaches
    /// every platform's own registry unchanged — a UTI on Apple,
    /// RegisterClipboardFormat on Windows, a target atom on X11 and
    /// Wayland, a MIME type on Android — so it carries no spaces, and
    /// kaya does nothing clever with the bytes.
    pub fn custom(
        mut self,
        id: impl Into<String>,
        bytes: impl Into<std::sync::Arc<[u8]>>,
    ) -> Self {
        self.clip
            .custom
            .push((id.into(), crate::protocol::Blob(bytes.into())));
        self
    }

    pub fn send(self) {
        self.tx.ops.push(TxOp::Copy(self.clip));
    }
}

/// The read chain: which representations this read can use, and the
/// request id its one answer arrives under.
#[must_use = "a clipboard read asks nothing until .send()"]
pub struct ClipReadRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    request: u64,
    accepting: Vec<String>,
}

impl ClipReadRef<'_, '_> {
    pub fn text(mut self) -> Self {
        self.accepting.push("text".to_owned());
        self
    }

    pub fn html(mut self) -> Self {
        self.accepting.push("html".to_owned());
        self
    }

    pub fn image(mut self) -> Self {
        self.accepting.push("image".to_owned());
        self
    }

    pub fn files(mut self) -> Self {
        self.accepting.push("files".to_owned());
        self
    }

    /// Accept an app-defined format by id. Custom formats are tried
    /// FIRST, in the order named: an app's own format round-trips its
    /// data losslessly, which is the only reason to have one.
    pub fn custom(mut self, id: impl Into<String>) -> Self {
        self.accepting.push(id.into());
        self
    }

    /// Send the request, returning its id — the handle
    /// [`Messages::on_clipboard`] binds the one-shot handler to.
    pub fn send(self) -> u64 {
        self.tx.ops.push(TxOp::ReadClipboard {
            request: self.request,
            accepting: self.accepting.join(" "),
        });
        self.request
    }
}

impl AlertRef<'_, '_> {
    /// Present over this window instead of the primary.
    pub fn in_window(mut self, window: WindowId) -> Self {
        self.spec.window = window;
        self
    }

    pub fn title(mut self, title: &str) -> Self {
        self.spec.title = title.to_owned();
        self
    }

    pub fn message(mut self, message: &str) -> Self {
        self.spec.message = message.to_owned();
        self
    }

    /// Add an action button (at most two — the platform floor; the
    /// third is a construction-time error, matching the scene gate).
    pub fn action(mut self, label: &str) -> Self {
        assert!(
            self.spec.actions.len() < 2,
            "kaya: an alert carries at most 2 actions (the platform floor)"
        );
        self.spec.actions.push(label.to_owned());
        self
    }

    /// Name the always-present cancel slot. Required — no binding
    /// invents a default label (no hidden English in the floor).
    pub fn cancel(mut self, label: &str) -> Self {
        self.spec.cancel = label.to_owned();
        self
    }

    /// Send the request, returning its id — the handle
    /// [`Messages::on_alert`] binds the one-shot result handler to.
    pub fn show(self) -> AlertId {
        assert!(
            !self.spec.cancel.is_empty(),
            "kaya: the cancel slot always exists and needs a name — \
             call .cancel(label) before .show()"
        );
        let id = self.spec.alert;
        self.tx.ops.push(TxOp::ShowAlert(self.spec));
        id
    }
}

/// The window-prop chain, in the construction-sugar tier: mirrors
/// the Widget proxy (`Binding conventions`: Rust chains).
pub struct WindowRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    window: WindowId,
}

impl<'t, 'a> WindowRef<'t, 'a> {
    /// Append a top-level menu to this window's command catalog — menu bars
    /// ride the window construct like every window attribute (DESIGN.md,
    /// Menus). `label` is constant text or a bound Str signal. The body
    /// declares the children through the [`MenuItems`] proxy; the returned
    /// chain carries the grouping node's own props and ends with
    /// [`MenuRef::id`] (or [`MenuRef::into_parts`] to keep the body's
    /// handles).
    ///
    /// Append-only and live: call this again for another top-level menu,
    /// and reopen a retained grouping item with [`Tx::menu`]. The bar
    /// accepts only grouping nodes.
    pub fn menu<R>(
        self,
        label: impl Into<MenuSource<StrKind>>,
        body: impl FnOnce(&mut MenuItems<'_, 'a, BarAnchor>) -> R,
    ) -> MenuRef<'t, 'a, R> {
        let WindowRef { tx, window } = self;
        let item = tx.menu_item(MenuItemKind::Menu);
        label.into().apply(tx, item, MenuProp::Label);
        tx.ops.push(TxOp::MenubarAppend { window, item });
        let out = {
            let mut children = MenuItems {
                tx: &mut *tx,
                slot: ItemSlot::Parent(item),
                roots: Vec::new(),
                _anchor: PhantomData,
            };
            body(&mut children)
        };
        MenuRef { out, item, tx }
    }

    /// Append a top-level radio group to this window's command catalog — a
    /// `radio_group` is admissible wherever a `menu` grouping node is,
    /// including at bar level. The body declares only options (the closed
    /// grammar, held by the [`RadioOptions`] type); chain
    /// [`RadioGroupRef::value`] AFTER the body so the selected index has
    /// options to address.
    pub fn radio_group<R>(
        self,
        label: impl Into<MenuSource<StrKind>>,
        body: impl FnOnce(&mut RadioOptions<'_, 'a, BarAnchor>) -> R,
    ) -> RadioGroupRef<'t, 'a, R> {
        let WindowRef { tx, window } = self;
        let item = tx.menu_item(MenuItemKind::RadioGroup);
        label.into().apply(tx, item, MenuProp::Label);
        tx.ops.push(TxOp::MenubarAppend { window, item });
        let out = {
            let mut options = RadioOptions {
                tx: &mut *tx,
                group: item,
                _anchor: PhantomData,
            };
            body(&mut options)
        };
        RadioGroupRef { out, item, tx }
    }
}

impl WindowRef<'_, '_> {
    /// The surface's title (title bar / switcher label / task label).
    pub fn title(self, title: &str) -> Self {
        self.tx
            .set_window_prop(self.window, WindowProp::Title, title);
        self
    }

    /// The ADVISORY content-size request in DIP.
    pub fn size(self, width: f64, height: f64) -> Self {
        self.tx
            .set_window_prop(self.window, WindowProp::Width, width);
        self.tx
            .set_window_prop(self.window, WindowProp::Height, height);
        self
    }

    /// Who owns the chrome close: true arms the veto class (the
    /// close button emits close_requested and nothing closes until
    /// destroy_window agrees).
    pub fn veto_close(self, on: bool) -> Self {
        self.tx
            .set_window_prop(self.window, WindowProp::VetoClose, on);
        self
    }

    /// Ask this window to present its ENTRY STACK as list-detail
    /// (DESIGN.md, Adaptive list-detail): on a REGULAR window the base root
    /// takes the leading pane and the top of the stack the trailing one; on
    /// a COMPACT one nothing changes. There is deliberately no argument for
    /// WHICH way it presents — that is the size class's answer.
    pub fn list_detail(self, on: bool) -> Self {
        self.tx
            .set_window_prop(self.window, WindowProp::ListDetail, on);
        self
    }

    /// Say this surface holds UNSAVED WORK: the backend shows its
    /// platform's own affordance, and nothing on the phones, which have
    /// none (docs/dirty-plan.md D2/D4).
    ///
    /// STATE, NOT CHROME, and the title you declared is left alone: no
    /// marker composed into it, no placeholder (the rejected Qt design). It
    /// ARMS NOTHING either — "unsaved changes, close anyway?" is
    /// `veto_close` plus a dialog, which is yours to compose.
    pub fn dirty(self, on: bool) -> Self {
        self.tx.set_window_prop(self.window, WindowProp::Dirty, on);
        self
    }

    /// The window CONTENT INSET, in layout units — LAYOUT, not appearance
    /// (docs/styling-plan.md D3). 16 unless you say otherwise; 0 is full
    /// bleed, honored unconditionally. A platform's safe area is a separate
    /// fact and is not removed by it.
    pub fn inset(self, units: f64) -> Self {
        self.tx.set_window_prop(self.window, WindowProp::Inset, units);
        self
    }

    /// How this window presents its sections — ADVISORY, the
    /// width/height precedent: honored where the platform has the
    /// idiom, nearest thing otherwise, ignored on the phones.
    pub fn sections_presentation(self, hint: crate::SectionsPresentation) -> Self {
        let raw = match hint {
            crate::SectionsPresentation::Auto => 0i64,
            crate::SectionsPresentation::Bar => 1,
            crate::SectionsPresentation::Sidebar => 2,
        };
        self.tx
            .set_window_prop(self.window, WindowProp::SectionsPresentation, raw);
        self
    }

    pub fn id(&self) -> WindowId {
        self.window
    }
}

/// The prop proxy a push_entry chain rides:
/// `tx.push_entry(WindowId(7)).title("detail").intercept_back(true)`.
pub struct EntryRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    entry: WindowId,
}

impl EntryRef<'_, '_> {
    /// The entry's title — the back affordance's label source (the
    /// iOS back button, the desktop headers).
    pub fn title(self, title: &str) -> Self {
        self.tx.set_entry_prop(self.entry, EntryProp::Title, title);
        self
    }

    /// The close-veto class transplanted to POP: armed, the back
    /// affordance emits back_requested and nothing pops until the
    /// app answers with pop_entry.
    pub fn intercept_back(self, on: bool) -> Self {
        self.tx
            .set_entry_prop(self.entry, EntryProp::InterceptBack, on);
        self
    }

    pub fn id(&self) -> WindowId {
        self.entry
    }
}

pub struct SectionRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    section: WindowId,
}

impl SectionRef<'_, '_> {
    /// The switcher item's label — the tab title on every platform.
    pub fn title(self, title: &str) -> Self {
        self.tx
            .set_section_prop(self.section, SectionProp::Title, title);
        self
    }

    /// The switcher item's icon (the blob channel, the image-source
    /// shape): rendered where the platform's switcher shows icons.
    pub fn icon(self, bytes: &[u8]) -> Self {
        self.tx
            .set_section_prop(self.section, SectionProp::Icon, Value::Blob(bytes.into()));
        self
    }

    /// The switcher item's SEMANTIC ICON ([`Symbol`]): a concept each
    /// backend draws in its own platform's symbol set — a tab bar
    /// without icons is not the platform's real thing, and a blob is
    /// the wrong primitive for a STANDARD one. Beside `icon`, not
    /// instead of it: app-specific art still rides the blob.
    pub fn symbol(self, symbol: crate::Symbol) -> Self {
        self.tx
            .set_section_prop(self.section, SectionProp::Symbol, symbol as i64);
        self
    }

    pub fn id(&self) -> WindowId {
        self.section
    }
}

// --- Menus: the command vocabulary's construction sugar ------------------
//
// One item vocabulary, two anchors (DESIGN.md, Menus): the anchor decides
// the SPELLING, never the item kinds. Chains are ephemeral borrow-checked
// proxies: they reborrow the transaction, die with their statement, and
// end with `.id()` where the durable handle must outlive them. Handlers
// scope to their creator — no app-global menu dispatcher exists.

/// The one shortcut-spelling parser in the Rust binding (layer 1: the
/// parser lives in ONE place per binding, never at call sites). Accepts
/// ASCII case variants and any modifier ordering, and canonicalizes to the
/// wire spelling — lowercase, in `primary`, `shift`, `alt`, key order.
/// Rejects whitespace, repeated modifiers, the platform aliases, and
/// multiple or missing keys. POLICY stays at the root: the binding spells,
/// the root judges.
fn normalize_shortcut(spelling: &str) -> String {
    assert!(!spelling.is_empty(), "kaya: shortcut spelling is empty");
    assert!(
        !spelling.chars().any(|c| c.is_whitespace()),
        "kaya: shortcut {spelling:?} contains whitespace"
    );
    let lower = spelling.to_ascii_lowercase();
    let parts: Vec<&str> = lower.split('+').collect();
    assert!(
        parts.iter().all(|p| !p.is_empty()),
        "kaya: shortcut {spelling:?} has an empty token"
    );
    let (mods, key) = parts.split_at(parts.len() - 1);
    let key = key[0];
    let (mut primary, mut shift, mut alt) = (false, false, false);
    for m in mods {
        let slot = match *m {
            "primary" => &mut primary,
            "shift" => &mut shift,
            "alt" => &mut alt,
            "ctrl" | "control" | "cmd" | "command" | "option" | "opt" | "meta" | "super"
            | "win" => panic!(
                "kaya: shortcut {spelling:?}: {m:?} is a platform alias — spell the \
                 platform-decided modifier \"primary\" (cmd on Apple hosts, ctrl elsewhere)"
            ),
            other => panic!(
                "kaya: shortcut {spelling:?} has an unknown modifier {other:?} \
                 (the portable modifiers are primary, shift, alt)"
            ),
        };
        assert!(!*slot, "kaya: shortcut {spelling:?} repeats modifier {m:?}");
        *slot = true;
    }
    assert!(
        !matches!(key, "primary" | "shift" | "alt"),
        "kaya: shortcut {spelling:?} has no key (modifiers only)"
    );
    let mut canonical = String::new();
    if primary {
        canonical.push_str("primary+");
    }
    if shift {
        canonical.push_str("shift+");
    }
    if alt {
        canonical.push_str("alt+");
    }
    canonical.push_str(key);
    canonical
}

/// One of the TWO addressable sources a menu property binds to: a constant
/// or a signal — the [`TplSource`] shape minus the element arm, because
/// menu items are not collection elements. The missing `Field` conversion
/// IS the rule, at compile time:
///
///
/// ```compile_fail
/// fn zone_rule(title: kaya::Field<<String as kaya::KayaField>::Kind>) {
///     let _: kaya::MenuSource<_> = title.into(); // no element sources on menu props
/// }
/// ```
///
/// Everywhere a bindable menu prop appears, both spellings work:
/// `m.item("Save")` and `m.item(title_signal)`.
pub struct MenuSource<K> {
    inner: MenuSourceInner,
    _kind: PhantomData<K>,
}

enum MenuSourceInner {
    Const(Value),
    Signal(SignalId),
}

impl From<&str> for MenuSource<StrKind> {
    fn from(s: &str) -> Self {
        MenuSource {
            inner: MenuSourceInner::Const(Value::Str(s.to_owned())),
            _kind: PhantomData,
        }
    }
}

impl From<bool> for MenuSource<BoolKind> {
    fn from(b: bool) -> Self {
        MenuSource {
            inner: MenuSourceInner::Const(Value::Bool(b)),
            _kind: PhantomData,
        }
    }
}

impl From<f64> for MenuSource<F64Kind> {
    fn from(x: f64) -> Self {
        MenuSource {
            inner: MenuSourceInner::Const(Value::F64(x)),
            _kind: PhantomData,
        }
    }
}

/// A radio group's `value` is a 0-based option index; the integer
/// spelling (`.value(1)`) is the natural one.
impl From<usize> for MenuSource<F64Kind> {
    fn from(n: usize) -> Self {
        MenuSource {
            inner: MenuSourceInner::Const(Value::F64(n as f64)),
            _kind: PhantomData,
        }
    }
}

impl<K> From<SignalId> for MenuSource<K> {
    fn from(s: SignalId) -> Self {
        MenuSource {
            inner: MenuSourceInner::Signal(s),
            _kind: PhantomData,
        }
    }
}

impl<K> MenuSource<K> {
    fn apply(self, tx: &mut Tx<'_>, item: MenuItemId, prop: MenuProp) {
        let value = match self.inner {
            MenuSourceInner::Const(v) => PropValue::Const(v),
            MenuSourceInner::Signal(s) => PropValue::Signal(s),
        };
        tx.ops.push(TxOp::SetMenuProp { item, prop, value });
    }
}

mod menu_sealed {
    pub trait Sealed {}
}

/// The anchor a catalog under construction belongs to — a zero-sized
/// marker threaded through [`MenuItems`] so the type system can carry
/// the one anchor-dependent rule (shortcuts) where the anchor is known
/// at build time. Sealed: the three anchors below are the vocabulary.
pub trait MenuAnchor: menu_sealed::Sealed {}

/// The anchors where a shortcut may be spelled: a shortcut needs a window
/// catalog as its native dispatch home, so [`ContextAnchor`] deliberately
/// lacks this — a shortcut on a context item is a COMPILE error where the
/// anchor is known:
///
/// ```compile_fail
/// fn zone_rule(m: &mut kaya::MenuItems<'_, '_, kaya::ContextAnchor>) {
///     m.item("Rename").shortcut("primary+r"); // no catalog home on a context anchor
/// }
/// ```
///
/// The rule covers every leaf kind — a checkable item and one option of a
/// group take chords in a catalog and nowhere else:
///
/// ```compile_fail
/// fn toggle_rule(m: &mut kaya::MenuItems<'_, '_, kaya::ContextAnchor>) {
///     m.toggle("Details").shortcut("primary+backslash"); // no catalog home
/// }
/// ```
///
/// ```compile_fail
/// fn option_rule(m: &mut kaya::MenuItems<'_, '_, kaya::ContextAnchor>) {
///     m.radio_group("Sort", |o| {
///         o.option("Name").shortcut("primary+1"); // no catalog home
///     });
/// }
/// ```
///
/// Those four are honest only if the same code MINUS the gated call
/// compiles — a compile_fail test that dies on an unrelated error pins
/// nothing (this crate has shipped that mistake). The base forms:
///
/// ```
/// fn legal_context_forms(m: &mut kaya::MenuItems<'_, '_, kaya::ContextAnchor>) {
///     m.item("Rename");
///     m.toggle("Details");
///     m.radio_group("Sort", |o| {
///         o.option("Name");
///     });
/// }
/// fn legal_catalog_forms(m: &mut kaya::MenuItems<'_, '_, kaya::BarAnchor>) {
///     m.item("Save").shortcut("primary+s");
///     m.item("Settings…").role(kaya::MenuRole::Settings);
///     m.toggle("Details").shortcut("primary+backslash");
///     m.radio_group("Sort", |o| {
///         o.option("Name").shortcut("primary+1");
///     });
/// }
/// ```
///
/// A role names a standard command in the window catalog, so it is a
/// compile error on a context anchor too:
///
/// ```compile_fail
/// fn role_rule(m: &mut kaya::MenuItems<'_, '_, kaya::ContextAnchor>) {
///     m.item("Settings…").role(kaya::MenuRole::Settings); // no catalog home
/// }
/// ```
///
/// [`AnyAnchor`] (reopened chains) keeps the method and defers the same
/// judgment to the root, which knows the retained item's real anchor.
pub trait CatalogHome: MenuAnchor {}

/// The window catalog (the bar): a catalog home — shortcuts and
/// roles live here.
pub struct BarAnchor;
/// A widget/node context menu: no shortcuts and no roles, held by
/// the type.
pub struct ContextAnchor;
/// A reopened chain over a retained item ([`Tx::menu`]): the anchor is
/// known to the root, not the type — shortcut stays spellable and the
/// root judges.
pub struct AnyAnchor;

impl menu_sealed::Sealed for BarAnchor {}
impl MenuAnchor for BarAnchor {}
impl CatalogHome for BarAnchor {}
impl menu_sealed::Sealed for ContextAnchor {}
impl MenuAnchor for ContextAnchor {}
impl menu_sealed::Sealed for AnyAnchor {}
impl MenuAnchor for AnyAnchor {}
impl CatalogHome for AnyAnchor {}

/// Where a builder seats the items it creates: under a grouping parent,
/// attached to a live widget's context anchor, or collected free for a
/// later template-node attach.
enum ItemSlot {
    Parent(MenuItemId),
    Widget(WidgetId),
    Free,
}

/// The menu-children builder: the body-closure proxy every grouping slot
/// hands out. Its creators are the closed child grammar for a `menu`/anchor
/// slot — `item` (action), `toggle`, `menu`, `radio_group`, `separator`; a
/// radio option is NOT in this vocabulary, so a loose option is a compile
/// error:
///
/// ```compile_fail
/// fn zone_rule(m: &mut kaya::MenuItems<'_, '_, kaya::BarAnchor>) {
///     m.option("Loose"); // options exist only inside a radio_group body
/// }
/// ```
///
/// Every creator emits the item, its label and its seating record eagerly,
/// then returns the kind's chain proxy. Labels take constant text or a Str
/// signal ([`MenuSource`]).
pub struct MenuItems<'t, 'b, A: MenuAnchor> {
    tx: &'t mut Tx<'b>,
    slot: ItemSlot,
    roots: Vec<MenuItemId>,
    _anchor: PhantomData<A>,
}

impl<'t, 'b, A: MenuAnchor> MenuItems<'t, 'b, A> {
    fn create(&mut self, kind: MenuItemKind, label: Option<MenuSource<StrKind>>) -> MenuItemId {
        let item = self.tx.menu_item(kind);
        if let Some(label) = label {
            label.apply(self.tx, item, MenuProp::Label);
        }
        match self.slot {
            ItemSlot::Parent(parent) => {
                self.tx.ops.push(TxOp::MenuItemAppend { parent, child: item })
            }
            ItemSlot::Widget(widget) => {
                self.tx.ops.push(TxOp::ContextAttach { widget, item })
            }
            ItemSlot::Free => self.roots.push(item),
        }
        item
    }

    /// An action — a leaf command firing exactly one `menu_activated`
    /// occurrence (click OR shortcut: one occurrence, one dispatch
    /// path). End with `.id()` and bind [`Messages::on_menu_item`] to
    /// the handle.
    pub fn item(&mut self, label: impl Into<MenuSource<StrKind>>) -> ActionRef<'_, 'b, A> {
        let item = self.create(MenuItemKind::Action, Some(label.into()));
        ActionRef {
            tx: &mut *self.tx,
            item,
            _anchor: PhantomData,
        }
    }

    /// A toggle — a stateful leaf reusing the Checkbox contract: user
    /// flips emit `menu_toggled`; programmatic `checked` writes are
    /// quiet. Bind [`Messages::on_menu_toggle`] to the handle.
    pub fn toggle(&mut self, label: impl Into<MenuSource<StrKind>>) -> ToggleRef<'_, 'b, A> {
        let item = self.create(MenuItemKind::Toggle, Some(label.into()));
        ToggleRef {
            tx: &mut *self.tx,
            item,
            _anchor: PhantomData,
        }
    }

    /// A nested menu — grouping, never navigation. One nested grouping
    /// level is the cap (root-checked): bar > menu > menu > leaf is the
    /// deepest legal bar shape.
    pub fn menu<R>(
        &mut self,
        label: impl Into<MenuSource<StrKind>>,
        body: impl FnOnce(&mut MenuItems<'_, 'b, A>) -> R,
    ) -> MenuRef<'_, 'b, R> {
        let item = self.create(MenuItemKind::Menu, Some(label.into()));
        let out = {
            let mut children = MenuItems {
                tx: &mut *self.tx,
                slot: ItemSlot::Parent(item),
                roots: Vec::new(),
                _anchor: PhantomData,
            };
            body(&mut children)
        };
        MenuRef {
            out,
            item,
            tx: &mut *self.tx,
        }
    }

    /// A nested radio group — the Choice contract inline, with the
    /// platform's checkmark idiom. The body declares only options;
    /// chain [`RadioGroupRef::value`] after it. Bind
    /// [`Messages::on_menu_select`] to the group handle.
    pub fn radio_group<R>(
        &mut self,
        label: impl Into<MenuSource<StrKind>>,
        body: impl FnOnce(&mut RadioOptions<'_, 'b, A>) -> R,
    ) -> RadioGroupRef<'_, 'b, R> {
        let item = self.create(MenuItemKind::RadioGroup, Some(label.into()));
        let out = {
            let mut options = RadioOptions {
                tx: &mut *self.tx,
                group: item,
                _anchor: PhantomData,
            };
            body(&mut options)
        };
        RadioGroupRef {
            out,
            item,
            tx: &mut *self.tx,
        }
    }

    /// Native grouping chrome: no label, no props, no handle.
    pub fn separator(&mut self) {
        let _ = self.create(MenuItemKind::Separator, None);
    }
}

/// The radio-group-children builder: a `radio_group` accepts ONLY
/// `radio_option` children, so this proxy has exactly one creator — any
/// other item kind inside a radio group is a compile error:
///
/// ```compile_fail
/// fn zone_rule(o: &mut kaya::RadioOptions<'_, '_>) {
///     o.item("Save"); // a radio group admits only options
/// }
/// ```
pub struct RadioOptions<'t, 'b, A: MenuAnchor> {
    tx: &'t mut Tx<'b>,
    group: MenuItemId,
    _anchor: PhantomData<A>,
}

impl<'t, 'b, A: MenuAnchor> RadioOptions<'t, 'b, A> {
    /// One labeled option, appended in declaration order — the order
    /// IS the index vocabulary the group's `value` selects over.
    pub fn option(&mut self, label: impl Into<MenuSource<StrKind>>) -> OptionRef<'_, 'b, A> {
        let item = self.tx.menu_item(MenuItemKind::RadioOption);
        label.into().apply(self.tx, item, MenuProp::Label);
        self.tx.ops.push(TxOp::MenuItemAppend {
            parent: self.group,
            child: item,
        });
        OptionRef {
            tx: &mut *self.tx,
            item,
            _anchor: PhantomData,
        }
    }
}

/// One entry of an accept list: a closed kind, or a custom format id.
///
/// A SUM AND NOT A MASK, because half the set is open-ended. A custom
/// format that could be written and never accepted would be an escape
/// hatch that only opens outward.
/// The role vocabulary (spec enum "role"): semantic emphasis, closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// An action whose press destroys something — the platform's own
    /// destructive affordance (red text on Apple, error-role container
    /// on Material, `.destructive-action` on GTK).
    Destructive = 1,
    /// THE primary action — one per dialog's worth of emphasis: the
    /// default-button treatment on every platform.
    Prominent = 2,
    /// A text hierarchy heading — the platform's heading text style AND
    /// the accessibility heading trait assistive users skim by.
    Heading = 3,
}

/// WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (spec enum "platform";
/// docs/styling-plan.md Slice 2b): one entry per backend roster row,
/// closed.
///
/// AN APP NAMES THESE, IT NEVER ASKS WHICH ONE IT IS. There is no
/// `Platform::current()` and there will not be: a binding cannot answer
/// that question (the JVM says "Linux" on Android), and it does not have
/// to — every row travels to every backend, and each backend picks its
/// own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Mac = 1,
    Ios = 2,
    Linux = 3,
    Windows = 4,
    Android = 5,
}

/// THE SEMANTIC ICON VOCABULARY (spec enum "symbol";
/// docs/styling-plan.md D6, DESIGN.md "Icons want names, not bytes").
///
/// An app names a CONCEPT and each backend draws its own platform's glyph:
/// `Copy` is `doc.on.doc` on Apple, `content_copy` on Material,
/// `edit-copy-symbolic` on Adwaita, and no single asset is right on all
/// three — SF Symbols are license-locked to Apple platforms, so a shared
/// one is not even legal. The platform sets also metric-match the text
/// beside them while a blob cannot. The Blob `icon` slot stays for
/// genuinely app-specific art.
///
/// Closed, and small on purpose. Growing it is a spec change with its
/// gates, never a per-app escape hatch (D5).
///
/// THE DISCRIMINANTS ARE WIRE VALUES AND ARE APPEND-ONLY. A new concept
/// takes 21; renumbering silently redraws every shipped app's menus.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Symbol {
    Add = 1,
    Remove = 2,
    /// Destroying something, the wastebasket idiom — distinct from
    /// `Remove`, which takes an item out of a list.
    Delete = 3,
    Edit = 4,
    /// Confirmation, the checkmark idiom.
    Done = 5,
    /// Dismissal, the ✕ idiom — not `Delete`.
    Close = 6,
    Search = 7,
    Settings = 8,
    Refresh = 9,
    Info = 10,
    Warning = 11,
    /// The direction-relative pair: every platform mirrors these under
    /// a right-to-left layout, so they mean BACKWARD and FORWARD in
    /// reading order, never "left" and "right".
    Back = 12,
    Forward = 13,
    /// The overflow affordance (the ellipsis idiom).
    More = 14,
    Copy = 15,
    Paste = 16,
    /// Favourite.
    Star = 17,
    Lock = 18,
    /// A person or account.
    Person = 19,
    Home = 20,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Accepts<'a> {
    Text,
    Html,
    Image,
    Files,
    /// An app-defined format, by the id it round-trips under. Reaches
    /// every platform's own registry verbatim, so it carries no spaces.
    Custom(&'a str),
}

impl Accepts<'_> {
    fn token(&self) -> &str {
        match self {
            Accepts::Text => "text",
            Accepts::Html => "html",
            Accepts::Image => "image",
            Accepts::Files => "files",
            Accepts::Custom(id) => id,
        }
    }
}

/// A standard-command role (DESIGN.md, Menus): a uniform declaration whose
/// PLACEMENT is each platform's business. `Settings` tells macOS to show
/// the command in the application menu; every other host leaves the item
/// where the app declared it. The vocabulary is closed — one role names one
/// command per app.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum MenuRole {
    /// The app's settings command.
    Settings,
    /// The three standard clipboard commands. They act on the FOCUSED
    /// widget, lower to the platform's own command, and configure their own
    /// enablement.
    ///
    /// THEY ARE NOT SUGAR OVER `copy`: kaya has no selection API, so only
    /// the widget knows what is selected and an app cannot assemble the
    /// payload for "copy the selection" itself. The data layer is for
    /// overriding that default and for targets with no native behaviour.
    Cut,
    Copy,
    Paste,
    /// The two history commands, and the same gesture layer one tier deeper
    /// (docs/undo-plan.md D6). They ask the FOCUSED widget first — a text
    /// field whose own edit history has something to give answers before
    /// the app's ledger does, which is what an editor user expects.
    /// Enablement is that same question, and kaya computes it.
    ///
    /// AN APP OPTS IN TO THE OTHER TIER BY NAMING ITS STEPS
    /// ([`Tx::undoable`]) and hears the result as [`Messages::on_undone`].
    /// An app that names none still gets working text undo from these
    /// items, because the first tier is the platform's.
    Undo,
    Redo,
}

impl MenuRole {
    /// The canonical wire spelling the root validates against its
    /// closed vocabulary.
    fn wire(self) -> &'static str {
        match self {
            MenuRole::Settings => "settings",
            MenuRole::Cut => "cut",
            MenuRole::Copy => "copy",
            MenuRole::Paste => "paste",
            MenuRole::Undo => "undo",
            MenuRole::Redo => "redo",
        }
    }
}

/// A just-built action's chain: `enabled`/`icon`/`primary`, plus
/// `shortcut` and `role` where the anchor is a catalog home
/// ([`CatalogHome`]).
/// `primary` and `shortcut` are const-only by signature — no signal
/// spelling exists. Ends with [`ActionRef::id`].
#[must_use = "end the chain with .id() — handlers bind to the item handle"]
pub struct ActionRef<'t, 'b, A: MenuAnchor> {
    tx: &'t mut Tx<'b>,
    item: MenuItemId,
    _anchor: PhantomData<A>,
}

impl<A: MenuAnchor> ActionRef<'_, '_, A> {
    /// Whether the item is enabled (default true): a constant or a
    /// bound Bool signal. Enablement writes never emit anything.
    pub fn enabled(self, src: impl Into<MenuSource<BoolKind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Enabled);
        self
    }

    /// An optional icon (the blob channel): used by phone promotion,
    /// ignored where native menu dress has no icons. Const-only.
    pub fn icon(self, bytes: &[u8]) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Icon, Value::Blob(bytes.into()));
        self
    }

    /// The item's SEMANTIC ICON ([`Symbol`]): the closed concept
    /// vocabulary each backend maps to its own platform's symbol set.
    /// Const-only, beside `icon` — a name for the standard concepts, a
    /// blob for app-specific art.
    pub fn symbol(self, symbol: crate::Symbol) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Symbol, symbol as i64);
        self
    }

    /// The phone-bar promotion hint (default false): promoted actions
    /// become real top-bar actions in catalog preorder, the rest stay
    /// in overflow. INERT on desktops — not a toolbar grammar.
    /// Const-only.
    pub fn primary(self, on: bool) -> Self {
        self.tx.set_menu_prop(self.item, MenuProp::Primary, on);
        self
    }

    /// End the chain: the durable handle, releasing the transaction
    /// borrow.
    pub fn id(self) -> MenuItemId {
        self.item
    }
}

impl<A: CatalogHome> ActionRef<'_, '_, A> {
    /// The action's shortcut. Any ASCII case and modifier order is accepted
    /// and canonicalized here (the binding's ONE parser); policy is judged
    /// at the root. The shortcut is another affordance of the same item: it
    /// fires the SAME `menu_activated` occurrence as a click. Const-only,
    /// window-anchored actions only.
    pub fn shortcut(self, spelling: &str) -> Self {
        let canonical = normalize_shortcut(spelling);
        self.tx
            .set_menu_prop(self.item, MenuProp::Shortcut, canonical);
        self
    }

    /// Declare this action a standard command ([`MenuRole`]). The
    /// declaration is uniform; where it lands is the host's business. One
    /// item per role, judged at the root. The role never invents a chord:
    /// an app that wants Command-comma spells `.shortcut("primary+comma")`.
    /// Const-only, window-anchored actions only.
    pub fn role(self, role: MenuRole) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Role, role.wire());
        self
    }
}

/// A just-built toggle's chain: `enabled`, `checked`, `icon`. Ends with
/// [`ToggleRef::id`].
#[must_use = "end the chain with .id() — handlers bind to the item handle"]
pub struct ToggleRef<'t, 'b, A: MenuAnchor> {
    tx: &'t mut Tx<'b>,
    item: MenuItemId,
    _anchor: PhantomData<A>,
}

impl<A: MenuAnchor> ToggleRef<'_, '_, A> {
    /// Whether the item is enabled (default true): constant or bound.
    pub fn enabled(self, src: impl Into<MenuSource<BoolKind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Enabled);
        self
    }

    /// The toggle's state — the Checkbox contract: a constant or a
    /// signal bound both ways. User flips emit `menu_toggled`;
    /// programmatic writes through the signal are quiet.
    pub fn checked(self, src: impl Into<MenuSource<BoolKind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Checked);
        self
    }

    /// An optional icon (the blob channel). Const-only.
    pub fn icon(self, bytes: &[u8]) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Icon, Value::Blob(bytes.into()));
        self
    }

    /// The item's SEMANTIC ICON ([`Symbol`]): the closed concept
    /// vocabulary each backend maps to its own platform's symbol set.
    /// Const-only, beside `icon` — a name for the standard concepts, a
    /// blob for app-specific art.
    pub fn symbol(self, symbol: crate::Symbol) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Symbol, symbol as i64);
        self
    }

    /// End the chain: the durable handle.
    pub fn id(self) -> MenuItemId {
        self.item
    }
}

/// A toggle's chord, where the anchor is a catalog home: "Show
/// Sidebar" wants its checkmark AND its key, and every desktop toolkit
/// has always allowed both. Same canonicalizer, same root policy, same
/// one occurrence as a click.
impl<A: CatalogHome> ToggleRef<'_, '_, A> {
    /// The toggle's shortcut — see [`ActionRef::shortcut`]. Const-only,
    /// window-anchored.
    pub fn shortcut(self, spelling: &str) -> Self {
        let canonical = normalize_shortcut(spelling);
        self.tx
            .set_menu_prop(self.item, MenuProp::Shortcut, canonical);
        self
    }
}

/// A just-built radio option's chain: `enabled`, `icon`. Options carry
/// no state of their own — selection lives on the group (`value`).
pub struct OptionRef<'t, 'b, A: MenuAnchor> {
    tx: &'t mut Tx<'b>,
    item: MenuItemId,
    _anchor: PhantomData<A>,
}

impl<A: MenuAnchor> OptionRef<'_, '_, A> {
    /// Whether the option is enabled (default true): constant or bound.
    pub fn enabled(self, src: impl Into<MenuSource<BoolKind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Enabled);
        self
    }

    /// An optional icon (the blob channel). Const-only.
    pub fn icon(self, bytes: &[u8]) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Icon, Value::Blob(bytes.into()));
        self
    }

    /// The item's SEMANTIC ICON ([`Symbol`]): the closed concept
    /// vocabulary each backend maps to its own platform's symbol set.
    /// Const-only, beside `icon` — a name for the standard concepts, a
    /// blob for app-specific art.
    pub fn symbol(self, symbol: crate::Symbol) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Symbol, symbol as i64);
        self
    }

    /// End the chain: the durable handle.
    pub fn id(self) -> MenuItemId {
        self.item
    }
}

/// One option's chord, where the anchor is a catalog home: the
/// view-mode pattern (Command-1, Command-2) selects a single option
/// straight from the keyboard, emitting the group's own
/// `menu_value_changed`.
impl<A: CatalogHome> OptionRef<'_, '_, A> {
    /// The option's shortcut — see [`ActionRef::shortcut`]. Const-only,
    /// window-anchored.
    pub fn shortcut(self, spelling: &str) -> Self {
        let canonical = normalize_shortcut(spelling);
        self.tx
            .set_menu_prop(self.item, MenuProp::Shortcut, canonical);
        self
    }
}

/// A just-built menu grouping node's chain (bar-level or nested):
/// `enabled`, `icon`, and the body's result riding along as `out` — the
/// [`Widget`] shape. End with [`MenuRef::id`] or
/// [`MenuRef::into_parts`].
#[must_use = "end the chain with .id()/.into_parts() — the handle reopens the menu later"]
pub struct MenuRef<'t, 'b, R = ()> {
    /// The children body's own result, threaded out unchanged.
    pub out: R,
    item: MenuItemId,
    tx: &'t mut Tx<'b>,
}

impl<R> MenuRef<'_, '_, R> {
    /// Whether the whole grouping node is enabled (default true):
    /// constant or bound. Disabling a menu disables its subtree on
    /// every platform (the inherited-disabled contract).
    pub fn enabled(self, src: impl Into<MenuSource<BoolKind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Enabled);
        self
    }

    /// An optional icon (the blob channel). Const-only.
    pub fn icon(self, bytes: &[u8]) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Icon, Value::Blob(bytes.into()));
        self
    }

    /// The item's SEMANTIC ICON ([`Symbol`]): the closed concept
    /// vocabulary each backend maps to its own platform's symbol set.
    /// Const-only, beside `icon` — a name for the standard concepts, a
    /// blob for app-specific art.
    pub fn symbol(self, symbol: crate::Symbol) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Symbol, symbol as i64);
        self
    }

    /// End the chain: the durable handle — what [`Tx::menu`] reopens.
    pub fn id(self) -> MenuItemId {
        self.item
    }

    /// End the chain keeping the body's result too.
    pub fn into_parts(self) -> (MenuItemId, R) {
        (self.item, self.out)
    }
}

/// A just-built radio group's chain: `value` (chain it AFTER the body
/// so the index has options to address), `enabled`, `icon`, and the
/// body's result as `out`.
#[must_use = "end the chain with .id()/.into_parts() — on_menu_select binds to the group handle"]
pub struct RadioGroupRef<'t, 'b, R = ()> {
    /// The options body's own result, threaded out unchanged.
    pub out: R,
    item: MenuItemId,
    tx: &'t mut Tx<'b>,
}

impl<R> RadioGroupRef<'_, '_, R> {
    /// The selected option index (0-based, in option declaration
    /// order) — the Choice contract: a constant or a signal bound both
    /// ways. User picks emit `menu_value_changed`; programmatic writes
    /// are quiet.
    pub fn value(self, src: impl Into<MenuSource<F64Kind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Value);
        self
    }

    /// Whether the group is enabled (default true): constant or bound.
    pub fn enabled(self, src: impl Into<MenuSource<BoolKind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Enabled);
        self
    }

    /// An optional icon (the blob channel). Const-only.
    pub fn icon(self, bytes: &[u8]) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Icon, Value::Blob(bytes.into()));
        self
    }

    /// The item's SEMANTIC ICON ([`Symbol`]): the closed concept
    /// vocabulary each backend maps to its own platform's symbol set.
    /// Const-only, beside `icon` — a name for the standard concepts, a
    /// blob for app-specific art.
    pub fn symbol(self, symbol: crate::Symbol) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Symbol, symbol as i64);
        self
    }

    /// End the chain: the durable handle [`Messages::on_menu_select`]
    /// binds to.
    pub fn id(self) -> MenuItemId {
        self.item
    }

    /// End the chain keeping the body's result too.
    pub fn into_parts(self) -> (MenuItemId, R) {
        (self.item, self.out)
    }
}

/// The reopening chain for a RETAINED item ([`Tx::menu`]): every
/// mutable prop, each judged by the root against the item's kind and
/// anchor (the dynamic tier — [`Tx::set_menu_prop`] is the floor it
/// rides), plus [`MenuItemRef::append`]/[`MenuItemRef::options`] for
/// the append-at-any-time discipline on grouping nodes.
pub struct MenuItemRef<'t, 'b> {
    tx: &'t mut Tx<'b>,
    item: MenuItemId,
}

impl<'t, 'b> MenuItemRef<'t, 'b> {
    /// Rename the item: constant text or a bound Str signal. Label
    /// writes never emit anything.
    pub fn label(self, src: impl Into<MenuSource<StrKind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Label);
        self
    }

    /// Whether the item is enabled: constant or bound.
    pub fn enabled(self, src: impl Into<MenuSource<BoolKind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Enabled);
        self
    }

    /// A toggle's state (toggle items only — root-checked). The
    /// programmatic write is configuration: QUIET, no `menu_toggled`
    /// echo (the echo doctrine).
    pub fn checked(self, src: impl Into<MenuSource<BoolKind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Checked);
        self
    }

    /// A radio group's selected option index (radio groups only —
    /// root-checked). QUIET, like `checked`.
    pub fn value(self, src: impl Into<MenuSource<F64Kind>>) -> Self {
        src.into().apply(&mut *self.tx, self.item, MenuProp::Value);
        self
    }

    /// The item's icon (the blob channel). Const-only.
    pub fn icon(self, bytes: &[u8]) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Icon, Value::Blob(bytes.into()));
        self
    }

    /// The item's SEMANTIC ICON ([`Symbol`]): the closed concept
    /// vocabulary each backend maps to its own platform's symbol set.
    /// Const-only, beside `icon` — a name for the standard concepts, a
    /// blob for app-specific art.
    pub fn symbol(self, symbol: crate::Symbol) -> Self {
        self.tx
            .set_menu_prop(self.item, MenuProp::Symbol, symbol as i64);
        self
    }

    /// The phone-bar promotion hint (actions only — root-checked).
    /// Flipping it recomputes the promoted set deterministically.
    pub fn primary(self, on: bool) -> Self {
        self.tx.set_menu_prop(self.item, MenuProp::Primary, on);
        self
    }

    /// The action's shortcut (window-anchored actions only — the root
    /// knows the retained item's anchor and judges). Normalized here,
    /// like [`ActionRef::shortcut`]; a re-set replaces the item's
    /// previous spelling.
    pub fn shortcut(self, spelling: &str) -> Self {
        let canonical = normalize_shortcut(spelling);
        self.tx
            .set_menu_prop(self.item, MenuProp::Shortcut, canonical);
        self
    }

    /// Reopen a retained `menu` grouping node and append more children —
    /// the terminal of the chain, returning the body's result. The root
    /// re-validates each appended subtree in the retained item's real
    /// anchor context (depth, shortcuts, duplicates).
    pub fn append<R>(self, body: impl FnOnce(&mut MenuItems<'_, 'b, AnyAnchor>) -> R) -> R {
        let mut children = MenuItems {
            tx: self.tx,
            slot: ItemSlot::Parent(self.item),
            roots: Vec::new(),
            _anchor: PhantomData,
        };
        body(&mut children)
    }

    /// Reopen a retained `radio_group` and append more options — the
    /// option-flavored terminal.
    pub fn options<R>(self, body: impl FnOnce(&mut RadioOptions<'_, 'b, AnyAnchor>) -> R) -> R {
        let mut options = RadioOptions {
            tx: self.tx,
            group: self.item,
            _anchor: PhantomData,
        };
        body(&mut options)
    }
}

/// A context catalog built free of any anchor ([`Tx::context_catalog`])
/// for a template node: the body's result rides as `out`, and the catalog
/// moves INTO [`Tpl::context_menu`] — an item takes exactly one anchor, so
/// attaching the same catalog twice is a compile error:
///
/// ```compile_fail
/// fn zone_rule(
///     t: &mut kaya::Tpl<'_, '_>,
///     a: kaya::TemplateNodeId,
///     b: kaya::TemplateNodeId,
///     catalog: kaya::ContextCatalog<()>,
/// ) {
///     t.context_menu(a, catalog);
///     t.context_menu(b, catalog); // moved: one catalog, one anchor
/// }
/// ```
#[must_use = "a context catalog attaches nowhere until Tpl::context_menu"]
pub struct ContextCatalog<R = ()> {
    /// The builder body's own result, threaded out unchanged.
    pub out: R,
    roots: Vec<MenuItemId>,
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

    /// A button whose caption comes from any addressable source — a
    /// constant per stamped copy, a signal, or the element's own field.
    /// Clicks on a stamped copy arrive as `InstanceButtonClicked`,
    /// naming this node plus the copy's key path.
    pub fn button(&mut self, src: impl Into<TplSource<StrKind>>) -> TemplateNodeId {
        let n = self.widget(WidgetKind::Button);
        self.apply_source(n, Prop::Text, src.into().inner);
        n
    }

    /// A single-line text field per stamped copy. UNCONTROLLED, which is
    /// why this takes nothing: the copy owns its text, edits arrive as
    /// `InstanceTextChanged` naming this node and the copy's key path. Use
    /// [`Self::entry_bound`] when each copy should START from its row's own
    /// data.
    pub fn entry(&mut self) -> TemplateNodeId {
        self.widget(WidgetKind::Entry)
    }

    /// An entry whose INITIAL text comes from any addressable source —
    /// a constant, a signal, or the row's own field. The uncontrolled
    /// contract is unchanged: this seeds the copy, the user owns it
    /// afterwards. (The live zone has no twin for this because a live
    /// widget has no row to read.)
    pub fn entry_bound(&mut self, src: impl Into<TplSource<StrKind>>) -> TemplateNodeId {
        let n = self.widget(WidgetKind::Entry);
        self.apply_source(n, Prop::Text, src.into().inner);
        n
    }

    /// A multi-line editor per stamped copy — the entry's contract over
    /// the platform's real multi-line control.
    pub fn textarea(&mut self) -> TemplateNodeId {
        self.widget(WidgetKind::Textarea)
    }

    /// A textarea seeded from any addressable source; [`Self::entry_bound`]'s
    /// reasoning, one kind over.
    pub fn textarea_bound(&mut self, src: impl Into<TplSource<StrKind>>) -> TemplateNodeId {
        let n = self.widget(WidgetKind::Textarea);
        self.apply_source(n, Prop::Text, src.into().inner);
        n
    }

    /// A vertical scroll viewport over exactly one child, per copy.
    pub fn scroll<R>(&mut self, body: impl FnOnce(&mut Self) -> R) -> (TemplateNodeId, R) {
        self.container_of(WidgetKind::Scroll, body)
    }

    /// A grid laying each copy's children row-major into `columns`
    /// columns. The column count describes the PROTOTYPE, so it is a
    /// constant rather than a source — every stamped copy has the same
    /// shape, and only the values inside it vary.
    pub fn grid<R>(
        &mut self,
        columns: usize,
        body: impl FnOnce(&mut Self) -> R,
    ) -> (TemplateNodeId, R) {
        let (node, out) = self.container_of(WidgetKind::Grid, body);
        self.set(node, Prop::Columns, columns as f64);
        (node, out)
    }

    /// A spacer: an empty grown column, the same pure sugar the live
    /// zone spells (no new vocabulary reaches a backend).
    pub fn spacer(&mut self) -> TemplateNodeId {
        let n = self.widget(WidgetKind::Column);
        self.set(n, Prop::Grow, 1.0);
        n
    }

    /// A progress bar whose fraction comes from any addressable source —
    /// the per-row case this zone exists for (`t.progress(row.done)`).
    pub fn progress(&mut self, src: impl Into<TplSource<F64Kind>>) -> TemplateNodeId {
        let n = self.widget(WidgetKind::Progress);
        self.apply_source(n, Prop::Value, src.into().inner);
        n
    }

    /// A progress bar in the platform's activity mode: no fraction, so
    /// nothing to source.
    pub fn progress_indeterminate(&mut self) -> TemplateNodeId {
        let n = self.widget(WidgetKind::Progress);
        self.set(n, Prop::Indeterminate, true);
        n
    }

    /// A slider over `min..max` whose POSITION comes from a source. The
    /// range describes the prototype and is constant; the position is
    /// the part that varies per row. Moves arrive as
    /// `InstanceValueChanged` naming this node and the copy's key path.
    pub fn slider(
        &mut self,
        min: f64,
        max: f64,
        src: impl Into<TplSource<F64Kind>>,
    ) -> TemplateNodeId {
        let n = self.widget(WidgetKind::Slider);
        self.set(n, Prop::Min, min);
        self.set(n, Prop::Max, max);
        self.apply_source(n, Prop::Value, src.into().inner);
        n
    }

    /// A dropdown over its options, with the SELECTED INDEX from a source.
    /// The options are label children of the prototype, so every copy
    /// offers the same list and only the choice varies — a per-row option
    /// list would need a collection inside the choice widget, which the
    /// scene rejects (labels only; docs/sugar-pass-plan.md §2).
    pub fn select(
        &mut self,
        options: &[&str],
        src: impl Into<TplSource<F64Kind>>,
    ) -> TemplateNodeId {
        self.choice(WidgetKind::Select, options, src.into().inner)
    }

    /// A radio group: [`Self::select`]'s contract in its inline
    /// presentation — same option children, same index semantics.
    pub fn radio(
        &mut self,
        options: &[&str],
        src: impl Into<TplSource<F64Kind>>,
    ) -> TemplateNodeId {
        self.choice(WidgetKind::Radio, options, src.into().inner)
    }

    fn choice(
        &mut self,
        kind: WidgetKind,
        options: &[&str],
        src: SourceInner,
    ) -> TemplateNodeId {
        let n = self.widget(kind);
        self.tx.parents.push(n.0);
        for option in options {
            let label = self.widget(WidgetKind::Label);
            self.set(label, Prop::Text, *option);
        }
        self.tx.parents.pop();
        self.apply_source(n, Prop::Value, src);
        n
    }

    /// An image from any addressable source, INCLUDING the row's own
    /// blob field — each copy showing its own picture, which is what a
    /// list of anything with a thumbnail wants. Swift, C# and Java had
    /// shipped this and Rust could not spell it, for want of
    /// [`BlobKind`] alone (docs/sugar-pass-plan.md S4).
    pub fn image(&mut self, src: impl Into<TplSource<BlobKind>>) -> TemplateNodeId {
        let n = self.widget(WidgetKind::Image);
        self.apply_source(n, Prop::Source, src.into().inner);
        n
    }

    /// A stamped copy's accessibility IDENTIFIER, from any addressable
    /// source. A CONST gives every copy the same key, which is legal —
    /// nothing in the core deduplicates ids — but know what it costs:
    /// the harness's MODEL resolution addresses by kind#index and never
    /// notices, while `expect_ax`, the one verb that goes through the
    /// authored id into the platform's real tree, REFUSES a duplicated
    /// id rather than guessing among the elements that carry it
    /// (measured guessing wrong first, 2026-08-11). Copies automation
    /// must tell apart want a sourced id — the row's own field.
    pub fn a11y_id(&mut self, node: TemplateNodeId, src: impl Into<TplSource<StrKind>>) {
        self.apply_source(node, Prop::A11yId, src.into().inner);
    }

    /// A stamped copy's SPOKEN accessibility label, from any
    /// addressable source — and the row's own field is the whole point:
    /// a list row announcing its own name to assistive tech is the
    /// assertion no a11y leg had ever made of a stamped widget
    /// (docs/tpl-props-plan.md P3).
    pub fn a11y_label(&mut self, node: TemplateNodeId, src: impl Into<TplSource<StrKind>>) {
        self.apply_source(node, Prop::A11yLabel, src.into().inner);
    }

    /// What activating a stamped copy does. The root admits this on the
    /// activation kinds alone (button, checkbox, select, radio) and a
    /// misuse dies at DECLARE time in the root's own words, before a
    /// single row stamps — which is why there is no type-level wall
    /// here (crates/kaya/src/scene.rs, check_prop's A11yHint arm).
    pub fn a11y_hint(&mut self, node: TemplateNodeId, src: impl Into<TplSource<StrKind>>) {
        self.apply_source(node, Prop::A11yHint, src.into().inner);
    }

    /// What every stamped copy accepts from a paste. CONST ONLY, unlike the
    /// sourced props above, because an accept list describes the PROTOTYPE:
    /// what a control can take is a fact about the control, not about the
    /// row's data.
    ///
    /// THIS SETTER IS THE PASTE HOOK'S KEYSTONE. Every backend gates the
    /// paste occurrence on the focused widget's accept list, so before this
    /// existed `on_paste_node` registered a handler that could never fire,
    /// in every binding, silently (docs/tpl-props-plan.md §1).
    pub fn accepts(&mut self, node: TemplateNodeId, kinds: &[crate::Accepts<'_>]) {
        let list: Vec<&str> = kinds.iter().map(|k| k.token()).collect();
        self.set(node, Prop::Accepts, list.join(" ").as_str());
    }

    /// What a stamped copy MEANS — semantic emphasis, never appearance
    /// (docs/styling-plan.md D4). The template zone could not spell it at
    /// all until this, so a stamped "Delete" button inside a For was
    /// declarable as destructive in no language.
    ///
    /// CONST, like [`Self::accepts`] and for its reason. The root refuses a
    /// role on a kind it does not fit at DECLARE time — before a single row
    /// stamps, naming both the role and the kind — which is why there is no
    /// type-level wall here either.
    pub fn role(&mut self, node: TemplateNodeId, role: crate::Role) {
        self.set(node, Prop::Role, role as i64);
    }

    /// A stamped CONTAINER's own padding, in layout units — the window
    /// inset one level down (docs/styling-plan.md D3), the same number
    /// [`Widget::inset`] spells in the live zone.
    ///
    /// THE FORCING CASE IS A STAMPED ROW: the editor's find bar is a copy
    /// stamped from a template and sat flush against a full-bleed window's
    /// edge, because the template zone carried exactly one layout prop
    /// (grow). Const for [`Self::role`]'s reason. Container kinds only, and
    /// the root says so at declare time.
    pub fn inset(&mut self, node: TemplateNodeId, pad: f64) {
        self.set(node, Prop::Inset, pad);
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

    /// Attach a live-built context catalog to a template node — the
    /// Tpl-zone anchor. Zone rules: menu items are LIVE and shared across
    /// stamped copies, so the catalog is built BEFORE the template with
    /// [`Tx::context_catalog`] and only the attachment is declared here;
    /// the node must belong to this template case (root-checked). An
    /// activation carries the copy's key path, received by the `_node`
    /// handler flavors. The catalog moves in (one catalog, one anchor).
    pub fn context_menu<R>(&mut self, node: TemplateNodeId, catalog: ContextCatalog<R>) -> R {
        let ContextCatalog { out, roots } = catalog;
        for item in roots {
            self.tx.ops.push(TxOp::ContextAttachNode { node, item });
        }
        out
    }

    /// The floor: attach one context-catalog root to a template node.
    pub fn context_attach(&mut self, node: TemplateNodeId, item: MenuItemId) {
        self.tx.ops.push(TxOp::ContextAttachNode { node, item });
    }
}

#[cfg(test)]
mod tests {
    use crate::protocol::{Inbox, Transaction};
    use std::sync::mpsc::Receiver;
    use std::sync::{Arc, Mutex};


    // THE RULE TRIANGLE, checked by the compiler rather than documented:
    // Tx cannot cross a thread (the compile_fail doctest on Tx), AppCtx
    // cannot either (it holds Cell/RefCell, so !Sync), and Poster can.
    // Only the third is assertable positively, so it is asserted here.
    #[test]
    fn a_poster_crosses_threads() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<Poster>();
    }

    fn posting_ctx() -> (AppCtx, Poster, Receiver<Transaction>) {
        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, occ_tx);
        let poster = ctx.poster();
        (ctx, poster, tx_rx)
    }

    // POST MUST QUEUE, NOT RUN. A closure executed on the caller's thread
    // would touch AppCtx's Cells concurrently with the app thread, which
    // is precisely what !Sync exists to prevent — so the first assertion
    // is the load-bearing one, and it is a fact rather than a race
    // because the posting thread has been joined by then.
    #[test]
    fn post_queues_for_the_app_thread_in_order() {
        let (ctx, poster, _tx_rx) = posting_ctx();
        let order = Arc::new(Mutex::new(String::new()));

        let worker = {
            let poster = poster.clone();
            let order = Arc::clone(&order);
            std::thread::spawn(move || {
                for c in ["1", "2", "3"] {
                    let order = Arc::clone(&order);
                    poster.post(move |_tx| order.lock().unwrap().push_str(c));
                }
            })
        };
        worker.join().unwrap();
        assert_eq!(
            *order.lock().unwrap(),
            "",
            "post ran the closure on the CALLER's thread"
        );

        ctx.drain_posted();
        assert_eq!(*order.lock().unwrap(), "123", "posts run in the order made");
    }

    // A POST FROM INSIDE A TRANSACTION QUEUES FOR AFTER; IT NEVER NESTS.
    // "ac" then "acb" if queued; "abc" is the only thing nesting can
    // produce, and the two are unreachable from each other — the same
    // discriminator the scene uses (docs/background-work-plan.md §5).
    #[test]
    fn post_from_inside_a_transaction_queues_for_after() {
        let (ctx, poster, _tx_rx) = posting_ctx();
        let seq = Arc::new(Mutex::new(String::new()));

        ctx.apply(|_tx| {
            seq.lock().unwrap().push('a');
            let inner = Arc::clone(&seq);
            poster.post(move |_tx| inner.lock().unwrap().push('b'));
            seq.lock().unwrap().push('c');
        });
        assert_eq!(*seq.lock().unwrap(), "ac", "the post nested inside its transaction");

        ctx.drain_posted();
        assert_eq!(*seq.lock().unwrap(), "acb");
    }

    // A CLOSURE THAT POSTS AGAIN LANDS IN THE NEXT BATCH. drain_posted
    // takes the queue and drops the lock before running any of it, so a
    // self-posting closure cannot loop inside one drain and starve the
    // occurrence channel — an app that re-posts would otherwise never see
    // another click.
    #[test]
    fn a_self_post_waits_for_the_next_drain() {
        let (ctx, poster, _tx_rx) = posting_ctx();
        let ran = Arc::new(Mutex::new(0u32));

        fn again(poster: Poster, ran: Arc<Mutex<u32>>) {
            let p = poster.clone();
            poster.post(move |_tx| {
                let mut n = ran.lock().unwrap();
                *n += 1;
                let keep_going = *n < 3;
                drop(n);
                if keep_going {
                    again(p, ran);
                }
            });
        }
        again(poster, Arc::clone(&ran));

        ctx.drain_posted();
        assert_eq!(*ran.lock().unwrap(), 1, "a self-post must wait for the next batch");
        ctx.drain_posted();
        assert_eq!(*ran.lock().unwrap(), 2);
    }

    /// A wake sender for tests that never post. Deliberately NOT a clone
    /// of the test's own occ_tx: a live clone keeps the inbox connected,
    /// and the tests that `drop(occ_tx)` are asserting exactly that
    /// disconnect. Tests that DO post make a real clone themselves.
    fn no_wake() -> mpsc::Sender<Inbox> {
        mpsc::channel().0
    }
    use std::sync::mpsc;

    use super::{AppCtx, KayaRecord, KayaSum, Poster, Tx};
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
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

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

    /// A context for the asset tests: they send nothing and receive
    /// nothing, they only need a Tx to hang the call off.
    fn asset_ctx() -> AppCtx {
        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        AppCtx::new(occ_rx, tx_tx, no_wake())
    }

    /// `tx.asset(name)` answers the bytes of the file the build shipped,
    /// and the three ways of reading them agree: the borrow, the
    /// `Deref`, and the owned reader.
    #[test]
    fn an_asset_reads_the_file_the_build_shipped() {
        use std::io::Read;

        let ctx = asset_ctx();
        let tx = ctx.begin();
        let font = tx.asset("fonts/sora-wght.ttf");

        // The vendored font's byte count, the same fact assets.rs pins,
        // asserted again HERE because a truncated or short read would
        // otherwise reach a scene as a font the platform silently
        // declines to register.
        assert_eq!(font.len(), 111400);
        assert!(!font.is_empty());
        assert_eq!(font.bytes().len(), font.len());
        assert_eq!(&font[..8], &font.bytes()[..8], "Deref and bytes() disagree");

        let mut owned = Vec::new();
        font.reader().read_to_end(&mut owned).expect("an in-memory cursor cannot fail");
        assert_eq!(owned, font.bytes(), "the reader is not the asset's bytes");

        // Debug prints the count and never the font.
        assert_eq!(format!("{font:?}"), "Asset(111400 bytes)");
    }

    /// THE PROPERTY THE ASSET ROUTE EXISTS FOR: an asset handed to a blob
    /// consumer is not copied. The op carries the SAME allocation the core
    /// read into, and a byte spelling necessarily carries a different one.
    /// Asserted on the POINTER rather than the contents, because equal
    /// contents is exactly what a copy would also produce.
    #[test]
    fn an_asset_reaches_a_blob_consumer_without_a_copy() {
        use crate::protocol::TxOp;

        let ctx = asset_ctx();
        let mut tx = ctx.begin();
        let font = tx.asset("fonts/sora-wght.ttf");
        let read_into = font.bytes().as_ptr();

        tx.brand_typeface_with("Sora", &[], Some(&font));
        let TxOp::SetBrandTypeface(request) = tx.ops.last().expect("the op queued") else {
            panic!("brand_typeface_with lowered to something that is not a typeface request");
        };
        let blob = request.font.as_ref().expect("the font rode along");
        assert_eq!(blob.0.as_ptr(), read_into, "the asset's bytes were COPIED into the op");
        assert_eq!(blob.0.len(), font.len());

        let owned: Vec<u8> = font.bytes().to_vec();
        let guest_owns = owned.as_ptr();
        tx.brand_typeface_with("Sora", &[], Some(&owned));
        let TxOp::SetBrandTypeface(request) = tx.ops.last().expect("the second op queued") else {
            panic!("brand_typeface_with lowered to something that is not a typeface request");
        };
        let blob = request.font.as_ref().expect("the font rode along");
        assert_ne!(blob.0.as_ptr(), guest_owns, "a guest's own bytes must be copied, not aliased");
        assert_eq!(&blob.0[..], &owned[..], "the copy is not the bytes it was made from");

        // The icon consumer takes the same trait, so both spellings fit
        // there too — the one call that would not compile if
        // app_identity had kept its `&[u8]`.
        tx.app_identity("Aurora Notes", &font);
        let TxOp::SetAppIdentity(identity) = tx.ops.last().expect("the identity op queued") else {
            panic!("app_identity lowered to something that is not an identity");
        };
        assert_eq!(
            identity.icon.as_ref().expect("the icon rode along").0.as_ptr(),
            read_into
        );
    }

    /// A MISS PANICS WITH THE CORE'S SENTENCE, byte for byte. The
    /// binding writes no prose of its own: assets.rs is the one author,
    /// so a Rust guest and a Haskell guest are handed the same words and
    /// one scene can freeze them (docs/assets-plan.md, invariant 1).
    #[test]
    fn a_missing_asset_panics_with_the_cores_sentence_verbatim() {
        let ctx = asset_ctx();
        let tx = ctx.begin();

        // The default hook would print the panic to stderr and read as
        // a failure in a passing run; it goes back the way it was.
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            tx.asset("fonts/nope.ttf");
        }));
        std::panic::set_hook(previous);

        let payload = caught.expect_err("a missing asset must not return an Asset");
        let message = payload
            .downcast_ref::<String>()
            .expect("a formatted panic carries a String")
            .clone();
        assert_eq!(message, crate::assets::asset_why_not("fonts/nope.ttf"));
        assert!(message.contains("no asset named \"fonts/nope.ttf\""), "{message}");
        assert!(message.contains("fonts/sora-wght.ttf"), "the census is missing: {message}");
    }

    /// The walls are the CORE's, reached through this surface: a name
    /// that climbs out of the root is refused before any filesystem is
    /// touched, and the raise says which rule it broke.
    #[test]
    fn asset_refuses_a_name_that_escapes_the_root() {
        let ctx = asset_ctx();
        let tx = ctx.begin();

        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            tx.asset("../../Cargo.toml");
        }));
        std::panic::set_hook(previous);

        let payload = caught.expect_err("an escaping name must not resolve");
        let message = payload.downcast_ref::<String>().expect("a String payload").clone();
        assert!(message.contains("climbs out of the asset root"), "{message}");
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
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

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
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

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
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());
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
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());
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
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

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
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

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

        occ_tx.send(Inbox::Occ(Occurrence::ButtonClicked { id: other })).unwrap();
        occ_tx.send(Inbox::Occ(Occurrence::ButtonClicked { id: add })).unwrap();
        occ_tx.send(Inbox::Occ(Occurrence::Shutdown)).unwrap();
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
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let todos = tx.collection::<Todo>();
        let root = tx
            .column(|tx| {
                for mut row in todos.rows(tx) {
                    row.label(Todo::title());
                    break; // the row drops here; Drop closes the template
                }
            })
            .id();
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

    /// THE NESTED TRACE AND THE TEMPLATE-ZONE BUTTON ARE SPELLING:
    /// milestone2's shape built at the explicit floor and built in the
    /// sugar emits the same records in the same order. IDS INCLUDED, which
    /// is the clause that can actually break — the two zones allocate from
    /// separate counters, so a nested For that took a widget id instead of
    /// a template-node id would renumber everything after it while still
    /// rendering something plausible.
    #[test]
    fn nested_row_trace_matches_the_floor_records() {
        use crate::protocol::{Prop, WidgetKind};

        fn floor() -> String {
            let (_occ_tx, occ_rx) = mpsc::channel();
            let (tx_tx, tx_rx) = mpsc::channel();
            let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());
            let mut tx = ctx.begin();
            let groups = tx.collection::<Todo>();
            let root = tx
                .column(|tx| {
                    tx.for_each(&groups, |t| {
                        t.column(|t| {
                            let name = t.widget(WidgetKind::Label);
                            t.bind_element(name, Prop::Text, 0);
                            let items = t.collection::<Todo>();
                            t.for_each(&items, |t| {
                                t.column(|t| {
                                    let text = t.widget(WidgetKind::Label);
                                    t.bind_element(text, Prop::Text, 0);
                                    let remove = t.widget(WidgetKind::Button);
                                    t.set(remove, Prop::Text, "remove");
                                });
                            });
                        });
                    });
                })
                .id();
            tx.mount(root);
            tx.commit();
            format!("{:#?}", tx_rx.try_recv().expect("committed ops"))
        }

        fn sugar() -> String {
            let (_occ_tx, occ_rx) = mpsc::channel();
            let (tx_tx, tx_rx) = mpsc::channel();
            let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());
            let mut tx = ctx.begin();
            let groups = tx.collection::<Todo>();
            let root = tx
                .column(|tx| {
                    for mut group in groups.rows(tx) {
                        group.column(|t| {
                            t.label(Todo::title());
                            let items = t.collection::<Todo>();
                            for mut item in items.rows(t) {
                                item.column(|t| {
                                    t.label(Todo::title());
                                    t.button("remove");
                                });
                            }
                        });
                    }
                })
                .id();
            tx.mount(root);
            tx.commit();
            format!("{:#?}", tx_rx.try_recv().expect("committed ops"))
        }

        assert_eq!(sugar(), floor());
    }

    /// The round trip minus any backend: the app builds the milestone-1
    /// scene, an occurrence reaches it, and the answering write resolves
    /// through the scene into the label's property set.
    #[test]
    fn occurrence_to_resolved_set_round_trip() {
        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

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
                    | Occurrence::CloseRequested { .. }
                    | Occurrence::WindowClosed { .. }
                    | Occurrence::AlertResult { .. }
                    | Occurrence::FileDialogResult { .. }
                    | Occurrence::EntryPopped { .. }
                    | Occurrence::BackRequested { .. }
                    | Occurrence::SectionSelected { .. }
                    | Occurrence::ValueChanged { .. }
                    | Occurrence::InstanceValueChanged { .. }
                    | Occurrence::MenuActivated { .. }
                    | Occurrence::InstanceMenuActivated { .. }
                    | Occurrence::MenuToggled { .. }
                    | Occurrence::InstanceMenuToggled { .. }
                    | Occurrence::MenuValueChanged { .. }
                    | Occurrence::InstanceMenuValueChanged { .. }
                    | Occurrence::ClipboardResult { .. }
                    | Occurrence::Pasted { .. }
                    | Occurrence::InstancePasted { .. }
                    | Occurrence::Undone { .. }
                    | Occurrence::Redone { .. } => {}
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

        occ_tx.send(Inbox::Occ(Occurrence::ButtonClicked { id: WidgetId(2) })).unwrap();
        occ_tx.send(Inbox::Occ(Occurrence::ButtonClicked { id: WidgetId(2) })).unwrap();

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
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

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

    /// The minter, on its own terms: one counter per INSTANCE starting
    /// at 0, mint = counter+1 — and an abandoned transaction does NOT
    /// hand the key back. A key that two commits could both be given is
    /// not an identity, so the counter is deliberately outside the
    /// rollback journal (which puts the model back, and only that).
    #[test]
    fn fresh_keys_are_minted_per_instance_and_never_rewind() {
        let (_occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let groups = tx.collection::<String>();
        let (_list, items) = tx.for_each(&groups, |t| t.collection::<String>());
        let (g1, g2) = (items.at("g1"), items.at("g2"));

        assert_eq!(tx.insert_fresh(&groups, "Work"), 1);
        assert_eq!(tx.insert_fresh(&groups, "Home"), 2);
        // A SEPARATE TABLE IS A SEPARATE SEQUENCE: keys are unique
        // within an instance, so that is what a counter is per.
        assert_eq!(tx.insert_fresh(&g1, "send report"), 1);
        assert_eq!(tx.insert_fresh(&g1, "buy milk"), 2);
        assert_eq!(tx.insert_fresh(&g2, "water the plants"), 1);
        assert_eq!(
            tx.items(&g1),
            vec![
                (Value::I64(1), "send report".to_string()),
                (Value::I64(2), "buy milk".to_string()),
            ],
            "the minted key is what the entry is filed under"
        );
        tx.commit();

        // An abandoned transaction takes its records with it — and
        // leaves the counter where it is.
        {
            let mut tx = ctx.begin();
            assert_eq!(tx.insert_fresh(&groups, "Errands"), 3);
        }
        let mut tx = ctx.begin();
        assert_eq!(tx.len(&groups), 2, "the abandoned insert is gone");
        assert_eq!(
            tx.insert_fresh(&groups, "Errands"),
            4,
            "a spent key is spent: the minter never hands 3 out again"
        );
    }

    /// Absorption: an explicit I64 key at or above the counter carries
    /// it up, so hand-chosen and minted keys share one space in either
    /// order and a mint can never collide. A key of any other type
    /// cannot collide with an I64 at all and moves nothing.
    #[test]
    fn an_explicit_i64_key_carries_the_minter_past_it() {
        let (_occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let todos = tx.collection::<String>();
        tx.insert(&todos, 7i64, "imported");
        assert_eq!(tx.insert_fresh(&todos, "typed"), 8, "past the explicit key");
        // At the counter, not above it: 8 is taken, so the next mint is
        // still the one after it.
        tx.insert(&todos, 8i64, "reimported");
        assert_eq!(tx.insert_fresh(&todos, "typed again"), 9);
        // Below the counter: nothing to clear.
        tx.insert(&todos, 2i64, "older");
        assert_eq!(tx.insert_fresh(&todos, "and again"), 10);
        // A Str key shares no space with an I64.
        tx.insert(&todos, "t99", "named");
        assert_eq!(tx.insert_fresh(&todos, "last"), 11);
    }

    /// THE RULE THE HAND-SPELLED COUNTERS RESTED ON, now the binding's.
    /// A history walk replays captured keys inside the core and never
    /// re-enters this insert path, so an undo cannot rewind the counter
    /// and the next mint is still fresh — the duplicate-key panic nine
    /// guests were one undo/redo/add interleave away from.
    #[test]
    fn a_mint_after_an_undo_and_a_redo_is_still_fresh() {
        use crate::protocol::{DEFAULT_WINDOW, Occurrence, UndoDelta, UndoEntry, UndoOrder};

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let todos = tx.collection::<Todo>();
        let milk = tx.insert_fresh(&todos, Todo { title: "milk".into(), done: false });
        assert_eq!(milk, 1);
        tx.commit();

        // The core's inverse for that add, then its forward again: the
        // same key both ways, authored where the entry was captured.
        let step = |state: Option<(u32, Vec<Value>)>, order: Vec<Value>| UndoDelta {
            entries: vec![UndoEntry {
                collection: todos.id,
                path: vec![],
                key: Value::I64(milk),
                state,
            }],
            orders: if order.is_empty() {
                vec![]
            } else {
                vec![UndoOrder { collection: todos.id, path: vec![], keys: order }]
            },
            ..UndoDelta::default()
        };
        occ_tx
            .send(Inbox::Occ(Occurrence::Undone {
                window: DEFAULT_WINDOW,
                label: "add milk".into(),
                delta: step(None, vec![]),
            }))
            .unwrap();
        assert!(matches!(ctx.next(), Occurrence::Undone { .. }));

        // THE INTERLEAVE, which is the whole danger: the table is empty
        // again, so a counter that reads the model (its length, or its
        // highest key — both hand-spellings this replaces) mints 1 a
        // second time and the redo below lands on top of it.
        let mut tx = ctx.begin();
        assert_eq!(tx.len(&todos), 0, "the undo took the entry out");
        assert_eq!(
            tx.insert_fresh(&todos, Todo { title: "tea".into(), done: false }),
            2,
            "the undo moved no counter"
        );
        tx.commit();

        occ_tx
            .send(Inbox::Occ(Occurrence::Redone {
                window: DEFAULT_WINDOW,
                label: "add milk".into(),
                delta: step(
                    Some((0, vec![Value::from("milk"), Value::Bool(false)])),
                    vec![Value::I64(1), Value::I64(2)],
                ),
            }))
            .unwrap();
        assert!(matches!(ctx.next(), Occurrence::Redone { .. }));

        let mut tx = ctx.begin();
        assert_eq!(
            tx.items(&todos),
            vec![
                (Value::I64(1), Todo { title: "milk".into(), done: false }),
                (Value::I64(2), Todo { title: "tea".into(), done: false }),
            ],
            "two adds, two entries, two names — the redo overwrote nothing"
        );
        assert_eq!(
            tx.insert_fresh(&todos, Todo { title: "buns".into(), done: false }),
            3,
            "and the walk left the sequence where it was"
        );
    }

    /// The root-handle guard: a For binds the collection, never an
    /// `at(...)` instance.
    #[test]
    #[should_panic(expected = "not an instance")]
    fn for_each_rejects_instance_handles() {
        let (_occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());
        let mut tx = ctx.begin();
        let c = tx.collection::<String>();
        let _ = tx.for_each(&c.at("g1"), |_| ());
    }

    /// EVERY TEMPLATE CONSTRUCTOR'S ELEMENT-SOURCE ARM IS REACHABLE — not
    /// merely declared.
    ///
    /// Python shipped `progress(value=<element field>)` for months with the
    /// FieldRef accessors misspelled, so the constructor existed, every
    /// "does it exist" check passed, and calling it raised AttributeError
    /// (docs/sugar-pass-plan.md D3).
    ///
    /// So this walks the value-bearing constructors, hands each one a FIELD
    /// of the row's element, and requires the op that comes out to be
    /// `PropValue::Element` naming that field.
    #[test]
    fn every_template_source_arm_binds_the_row_s_own_field() {
        use crate::protocol::{PropValue, TxOp};
        use super::{BoolKind, F64Kind, Field, StrKind};

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());
        let mut tx = ctx.begin();

        let rows = tx.collection::<String>();
        let text: Field<StrKind> = Field::new(0);
        let num: Field<F64Kind> = Field::new(0);
        // One node per source-taking constructor, each fed the row's
        // own field. `label`, `checkbox` and `button` are the three that
        // predate this pass and ride along, so the sweep is every
        // value-bearing constructor in the zone rather than the new ones.
        let (_list, nodes) = tx.for_each(&rows, |t| {
            // The PROP setters join the sweep the same way
            // (docs/tpl-props-plan.md P1): each is handed the row's own
            // field and must emit the Element binding. A setter that took
            // the argument and dropped it is exactly Python's D3.
            let e = t.entry();
            t.a11y_id(e, text);
            t.a11y_label(e, text);
            let b = t.button(text);
            t.a11y_hint(b, text);
            vec![
                ("label", t.label(text), Prop::Text),
                ("checkbox", t.checkbox(Field::<BoolKind>::new(0)), Prop::Checked),
                ("button", b, Prop::Text),
                ("entry_bound", t.entry_bound(text), Prop::Text),
                ("textarea_bound", t.textarea_bound(text), Prop::Text),
                ("progress", t.progress(num), Prop::Value),
                ("slider", t.slider(0.0, 1.0, num), Prop::Value),
                ("select", t.select(&["a", "b"], num), Prop::Value),
                ("radio", t.radio(&["a", "b"], num), Prop::Value),
                ("a11y_id", e, Prop::A11yId),
                ("a11y_label", e, Prop::A11yLabel),
                ("a11y_hint", b, Prop::A11yHint),
            ]
        });

        for (what, node, want) in &nodes {
            // Matched per (node, PROP), not per node: two sourced props
            // on one node would otherwise vouch for each other, and a
            // setter that dropped its argument would hide behind its
            // sibling's Element bind.
            let bound = tx.ops.iter().any(|op| {
                matches!(
                    op,
                    TxOp::SetProperty {
                        widget,
                        prop,
                        value: PropValue::Element { level: 0, field: 0 },
                    } if widget.0 == node.0 && prop == want
                )
            });
            assert!(
                bound,
                "kaya: the template `{what}` constructor accepted a field of the \
                 row's element and emitted no Element binding for it — the source \
                 arm is declared but not reachable, which is exactly the shape \
                 that shipped in Python for months and passed every check that \
                 only asked whether the constructor exists"
            );
        }

        // ANTI-VACUITY: a loop over an empty list asserts nothing, and a
        // template body that returned early would leave one.
        assert_eq!(
            nodes.len(),
            12,
            "kaya: the source-arm sweep walked {} constructors, not the 9 the \
             zone has — a constructor added without a row here is one this test \
             cannot speak for",
            nodes.len()
        );
    }

    // --- Menus ----------------------------------------------------------

    /// The bar chain's emission shape, record by record: create, label,
    /// bar-append (the anchor), then each child's create + label +
    /// append + chained props — and the chain's shortcut goes out
    /// CANONICALIZED (case and modifier order), the binding's one
    /// parser at work.
    #[test]
    fn menu_chains_emit_the_wire_shapes() {
        use crate::protocol::{DEFAULT_WINDOW, MenuItemKind, MenuProp, PropValue, TxOp};

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let can_save = tx.signal(false);
        let start = tx.ops.len();
        let (file, save) = tx
            .window(DEFAULT_WINDOW)
            .menu("File", |m| {
                m.item("Save").shortcut("Shift+PRIMARY+s").enabled(can_save).id()
            })
            .into_parts();

        let ops = &tx.ops[start..];
        assert_eq!(ops.len(), 8, "got {ops:?}");
        assert!(matches!(ops[0],
            TxOp::MenuItemCreate { item, kind: MenuItemKind::Menu } if item == file));
        assert!(matches!(&ops[1],
            TxOp::SetMenuProp { item, prop: MenuProp::Label, value: PropValue::Const(Value::Str(s)) }
                if *item == file && s == "File"));
        assert!(matches!(ops[2],
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item } if item == file));
        assert!(matches!(ops[3],
            TxOp::MenuItemCreate { item, kind: MenuItemKind::Action } if item == save));
        assert!(matches!(&ops[4],
            TxOp::SetMenuProp { item, prop: MenuProp::Label, value: PropValue::Const(Value::Str(s)) }
                if *item == save && s == "Save"));
        assert!(matches!(ops[5],
            TxOp::MenuItemAppend { parent, child } if parent == file && child == save));
        assert!(matches!(&ops[6],
            TxOp::SetMenuProp { item, prop: MenuProp::Shortcut, value: PropValue::Const(Value::Str(s)) }
                if *item == save && s == "primary+shift+s"));
        assert!(matches!(&ops[7],
            TxOp::SetMenuProp { item, prop: MenuProp::Enabled, value: PropValue::Signal(sig) }
                if *item == save && *sig == can_save));
    }

    /// The two stateful contracts: a toggle's `checked` binds a signal
    /// (the Checkbox contract), and a radio group emits its options in
    /// declaration order with `value` chained AFTER the body — a const
    /// integral index.
    #[test]
    fn toggle_and_radio_group_chains_emit_their_contracts() {
        use crate::protocol::{DEFAULT_WINDOW, MenuItemKind, MenuProp, PropValue, TxOp};

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let details_on = tx.signal(false);
        let start = tx.ops.len();
        let details = tx
            .window(DEFAULT_WINDOW)
            .menu("View", |m| m.toggle("Details").checked(details_on).id())
            .out;
        let ops = &tx.ops[start..];
        assert_eq!(ops.len(), 7, "got {ops:?}");
        assert!(matches!(ops[3],
            TxOp::MenuItemCreate { item, kind: MenuItemKind::Toggle } if item == details));
        assert!(matches!(&ops[6],
            TxOp::SetMenuProp { item, prop: MenuProp::Checked, value: PropValue::Signal(sig) }
                if *item == details && *sig == details_on));

        let start = tx.ops.len();
        let sort = tx
            .window(DEFAULT_WINDOW)
            .radio_group("Sort", |o| {
                o.option("Name");
                o.option("Date");
            })
            .value(1)
            .id();
        let ops = &tx.ops[start..];
        assert_eq!(ops.len(), 10, "got {ops:?}");
        assert!(matches!(ops[0],
            TxOp::MenuItemCreate { item, kind: MenuItemKind::RadioGroup } if item == sort));
        assert!(matches!(ops[2],
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item } if item == sort));
        assert!(matches!(ops[3], TxOp::MenuItemCreate { kind: MenuItemKind::RadioOption, .. }));
        assert!(matches!(ops[5],
            TxOp::MenuItemAppend { parent, .. } if parent == sort));
        assert!(matches!(ops[6], TxOp::MenuItemCreate { kind: MenuItemKind::RadioOption, .. }));
        assert!(matches!(&ops[9],
            TxOp::SetMenuProp { item, prop: MenuProp::Value, value: PropValue::Const(Value::F64(x)) }
                if *item == sort && *x == 1.0));
    }

    /// A live-widget context menu: each body root is created and
    /// attached eagerly (the anchor decides the spelling, never the
    /// kinds), and a separator carries no label record.
    #[test]
    fn context_menu_attaches_roots_to_a_live_widget() {
        use crate::protocol::{MenuItemKind, TxOp};

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let status = tx.signal("ready");
        let target = tx.label(status).id();
        let start = tx.ops.len();
        let rename = tx.context_menu(target, |m| {
            let rename = m.item("Rename").id();
            m.separator();
            rename
        });
        let ops = &tx.ops[start..];
        assert_eq!(ops.len(), 5, "got {ops:?}");
        assert!(matches!(ops[0],
            TxOp::MenuItemCreate { item, kind: MenuItemKind::Action } if item == rename));
        assert!(matches!(ops[2],
            TxOp::ContextAttach { widget, item } if widget == target && item == rename));
        assert!(matches!(ops[3], TxOp::MenuItemCreate { kind: MenuItemKind::Separator, .. }));
        assert!(matches!(ops[4],
            TxOp::ContextAttach { widget, .. } if widget == target));
    }

    /// The Tpl-zone split the protocol forces: the catalog's items are
    /// LIVE — created before the template opens — and only the
    /// attachment record sits between CreateFor and TemplateEnd.
    #[test]
    fn node_context_catalogs_build_live_and_attach_in_template() {
        use crate::protocol::TxOp;

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let catalog = tx.context_catalog(|m| m.item("Remove").id());
        let remove = catalog.out;
        let groups = tx.collection::<String>();
        let (_list, returned) = tx.for_each(&groups, |t| {
            let name = t.label("g");
            t.context_menu(name, catalog)
        });
        assert_eq!(returned, remove, "the catalog's out threads back through the attach");

        let at = |pred: &dyn Fn(&TxOp) -> bool| tx.ops.iter().position(|op| pred(op)).unwrap();
        let create_at = at(&|op| matches!(op, TxOp::MenuItemCreate { .. }));
        let for_at = at(&|op| matches!(op, TxOp::CreateFor { .. }));
        let attach_at =
            at(&|op| matches!(op, TxOp::ContextAttachNode { item, .. } if *item == remove));
        let end_at = at(&|op| matches!(op, TxOp::TemplateEnd));
        assert!(
            create_at < for_at && for_at < attach_at && attach_at < end_at,
            "items live, attach templated: {create_at} < {for_at} < {attach_at} < {end_at}"
        );
    }

    /// The append-at-any-time reopening chain: rename the retained
    /// grouping item, append a child with its own chained props, and
    /// mutate a sibling's prop — each one record, in call order.
    #[test]
    fn reopening_retained_items_chains_props_and_appends() {
        use crate::protocol::{DEFAULT_WINDOW, MenuItemKind, MenuProp, PropValue, TxOp};

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let (file, save) = tx
            .window(DEFAULT_WINDOW)
            .menu("File", |m| m.item("Save").id())
            .into_parts();
        let start = tx.ops.len();
        let publish = tx
            .menu(file)
            .label("Document")
            .append(|m| m.item("Publish").primary(true).id());
        tx.menu(save).primary(false);

        let ops = &tx.ops[start..];
        assert_eq!(ops.len(), 6, "got {ops:?}");
        assert!(matches!(&ops[0],
            TxOp::SetMenuProp { item, prop: MenuProp::Label, value: PropValue::Const(Value::Str(s)) }
                if *item == file && s == "Document"));
        assert!(matches!(ops[1],
            TxOp::MenuItemCreate { item, kind: MenuItemKind::Action } if item == publish));
        assert!(matches!(ops[3],
            TxOp::MenuItemAppend { parent, child } if parent == file && child == publish));
        assert!(matches!(&ops[4],
            TxOp::SetMenuProp { item, prop: MenuProp::Primary, value: PropValue::Const(Value::Bool(true)) }
                if *item == publish));
        assert!(matches!(&ops[5],
            TxOp::SetMenuProp { item, prop: MenuProp::Primary, value: PropValue::Const(Value::Bool(false)) }
                if *item == save));
    }

    /// The whole sugar surface against the real root: the scene accepts
    /// the canonical catalog, a stamp attaches the shared node catalog
    /// carrying the copy's key path (the noun), and a later transaction
    /// reopens the catalog live.
    #[test]
    fn menu_construction_round_trips_the_root() {
        use crate::protocol::{ApplyOp, DEFAULT_WINDOW};

        let (_occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let can_save = tx.signal(false);
        let details_on = tx.signal(false);
        let status = tx.signal("ready");
        let groups = tx.collection::<String>();
        let (root, (target, remove)) = tx
            .column(|tx| {
                let target = tx.label(status).id();
                let catalog = tx.context_catalog(|m| m.item("Remove").id());
                let remove = catalog.out;
                let _ = tx.for_each(&groups, |t| {
                    let name = t.label("g");
                    t.context_menu(name, catalog);
                });
                (target, remove)
            })
            .into_parts();
        tx.mount(root);
        let (file, save) = tx
            .window(DEFAULT_WINDOW)
            .menu("File", |m| {
                m.item("Save").shortcut("Primary+S").enabled(can_save).id()
            })
            .into_parts();
        let _details = tx
            .window(DEFAULT_WINDOW)
            .menu("View", |m| m.toggle("Details").checked(details_on).id())
            .out;
        let _sort = tx
            .window(DEFAULT_WINDOW)
            .radio_group("Sort", |o| {
                o.option("Name");
                o.option("Date");
            })
            .value(0)
            .id();
        let _rename = tx.context_menu(target, |m| m.item("Rename").id());
        tx.commit();

        let mut scene = Scene::new();
        let applied = scene.apply(tx_rx.recv().unwrap());
        assert_eq!(
            applied
                .iter()
                .filter(|op| matches!(op, ApplyOp::MenubarAppend { .. }))
                .count(),
            3
        );
        assert_eq!(
            applied
                .iter()
                .filter(|op| matches!(op, ApplyOp::ContextAttach { .. }))
                .count(),
            1
        );

        // Stamping an entry attaches the SHARED catalog to the copy,
        // carrying the copy's key path.
        let mut tx = ctx.begin();
        tx.insert(&groups, "g2", "Home");
        tx.commit();
        let applied = scene.apply(tx_rx.recv().unwrap());
        let (item, path) = applied
            .iter()
            .find_map(|op| match op {
                ApplyOp::ContextAttachNode { item, path, .. } => Some((*item, path.clone())),
                _ => None,
            })
            .expect("the stamp attached the shared catalog");
        assert_eq!(item, remove);
        assert_eq!(path, vec![Value::from("g2")]);

        // Reopen live: rename File, append Publish, add a fourth
        // top-level menu, demote Save — the root re-validates each
        // against the retained anchors.
        let mut tx = ctx.begin();
        let publish = tx
            .menu(file)
            .label("Document")
            .append(|m| m.item("Publish").primary(true).id());
        let _tools = tx
            .window(DEFAULT_WINDOW)
            .menu("Tools", |m| m.item("Inspect").id())
            .id();
        tx.menu(save).primary(false);
        tx.commit();
        let applied = scene.apply(tx_rx.recv().unwrap());
        assert!(applied.iter().any(
            |op| matches!(op, ApplyOp::MenuItemAppend { child, .. } if *child == publish)
        ));
        assert_eq!(
            applied
                .iter()
                .filter(|op| matches!(op, ApplyOp::MenubarAppend { .. }))
                .count(),
            1
        );
    }

    /// The Msg tier over menus: one table keyed by item id, all three
    /// contracts, and the node flavors carrying the copy's key path.
    /// Unmapped items fold into nothing.
    #[test]
    fn menu_messages_map_the_three_contracts_and_node_flavors() {
        use super::Messages;
        use crate::protocol::{MenuItemId, Occurrence, Path};

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _keep) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let save = MenuItemId(1);
        let details = MenuItemId(2);
        let sort = MenuItemId(3);
        let remove = MenuItemId(4);
        let unmapped = MenuItemId(9);

        #[derive(Clone, Debug, PartialEq)]
        enum Msg {
            Save,
            Details(bool),
            Sorted(usize),
            Removed(Path),
        }
        let msgs = Messages::new();
        msgs.on_menu_item(save, Msg::Save);
        msgs.on_menu_toggle(details, Msg::Details);
        msgs.on_menu_select(sort, Msg::Sorted);
        msgs.on_menu_item_node(remove, Msg::Removed);

        let keys: Path = vec![Value::from("g2"), Value::from("a")];
        occ_tx.send(Inbox::Occ(Occurrence::MenuActivated { item: unmapped })).unwrap();
        occ_tx.send(Inbox::Occ(Occurrence::MenuActivated { item: save })).unwrap();
        occ_tx
            .send(Inbox::Occ(Occurrence::MenuToggled { item: details, checked: true }))
            .unwrap();
        occ_tx
            .send(Inbox::Occ(Occurrence::MenuValueChanged { group: sort, index: 1.0 }))
            .unwrap();
        occ_tx
            .send(Inbox::Occ(Occurrence::InstanceMenuActivated { item: remove, path: keys.clone() }))
            .unwrap();
        occ_tx.send(Inbox::Occ(Occurrence::Shutdown)).unwrap();

        assert_eq!(msgs.next(&ctx), Some(Msg::Save));
        assert_eq!(msgs.next(&ctx), Some(Msg::Details(true)));
        assert_eq!(msgs.next(&ctx), Some(Msg::Sorted(1)));
        assert_eq!(msgs.next(&ctx), Some(Msg::Removed(keys)));
        assert_eq!(msgs.next(&ctx), None);
    }

    /// The binding's one shortcut parser: ASCII case variants and any
    /// modifier order canonicalize to lowercase primary, shift, alt,
    /// key. Policy (key floor, shift rules, escape, the reserved
    /// union) is the root's — not re-judged here.
    #[test]
    fn shortcut_spellings_canonicalize() {
        for (raw, canonical) in [
            ("primary+s", "primary+s"),
            ("PRIMARY+S", "primary+s"),
            ("Shift+Primary+s", "primary+shift+s"),
            ("alt+SHIFT+primary+F5", "primary+shift+alt+f5"),
            ("Alt+Enter", "alt+enter"),
            ("delete", "delete"),
        ] {
            assert_eq!(super::normalize_shortcut(raw), canonical, "spelling {raw:?}");
        }
    }

    #[test]
    #[should_panic(expected = "contains whitespace")]
    fn shortcut_whitespace_is_rejected() {
        super::normalize_shortcut("primary + s");
    }

    #[test]
    #[should_panic(expected = "platform alias")]
    fn shortcut_aliases_are_rejected() {
        super::normalize_shortcut("Ctrl+S");
    }

    #[test]
    #[should_panic(expected = "repeats modifier")]
    fn shortcut_repeated_modifiers_are_rejected() {
        super::normalize_shortcut("primary+primary+s");
    }

    #[test]
    #[should_panic(expected = "has no key")]
    fn shortcut_without_a_key_is_rejected() {
        super::normalize_shortcut("primary+shift");
    }

    #[test]
    #[should_panic(expected = "empty token")]
    fn shortcut_with_an_empty_token_is_rejected() {
        super::normalize_shortcut("primary+");
    }

    #[test]
    #[should_panic(expected = "unknown modifier")]
    fn shortcut_with_two_keys_is_rejected() {
        super::normalize_shortcut("primary+s+t");
    }

    // --- Undo (docs/undo-plan.md D2, D5) --------------------------------

    /// The marker rides at the head however late it is named. A handler
    /// naturally builds first and knows what the step WAS afterwards, so
    /// the wire's head-of-batch rule must not turn ordinary code into a
    /// footgun.
    #[test]
    fn undoable_puts_the_marker_at_the_head_whenever_it_is_called() {
        use crate::protocol::TxOp;

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let todos = tx.collection::<Todo>();
        tx.insert(&todos, "a", Todo { title: "milk".into(), done: false });
        tx.undoable("add todo");
        match &tx.ops[0] {
            TxOp::UndoGroup { window, label } => {
                assert_eq!(*window, crate::protocol::DEFAULT_WINDOW);
                assert_eq!(label, "add todo");
            }
            other => panic!("the marker is not at the head: {other:?}"),
        }
        assert_eq!(
            tx.ops
                .iter()
                .filter(|op| matches!(op, TxOp::UndoGroup { .. }))
                .count(),
            1
        );
    }

    #[test]
    #[should_panic(expected = "already an undo group")]
    fn a_transaction_takes_one_name() {
        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        drop(occ_tx);
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());
        let mut tx = ctx.begin();
        tx.undoable("first");
        tx.undoable("second");
    }

    /// THE MIRROR FOLLOWS THE CORE, and it follows it at `AppCtx::next`
    /// — the one place the raw loop and Messages both take occurrences
    /// from. An undo moved core state without a transaction, so a mirror
    /// that did not reconcile would answer every read-back with state
    /// the core has already left behind.
    #[test]
    fn an_undone_delta_reconciles_the_model_mirror() {
        use crate::protocol::{
            Occurrence, UndoDelta, UndoEntry, UndoOrder, DEFAULT_WINDOW,
        };

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());

        let mut tx = ctx.begin();
        let todos = tx.collection::<Todo>();
        for key in ["a", "b"] {
            tx.insert(&todos, key, Todo { title: key.into(), done: false });
        }
        tx.commit();

        // What the core would send after undoing "add c, retitle a,
        // drop b, reorder": every run at once.
        let delta = UndoDelta {
            signals: vec![],
            texts: vec![],
            entries: vec![
                UndoEntry {
                    collection: todos.id,
                    path: vec![],
                    key: Value::from("c"),
                    state: None,
                },
                UndoEntry {
                    collection: todos.id,
                    path: vec![],
                    key: Value::from("a"),
                    state: Some((0, vec![Value::from("Alpha"), Value::Bool(true)])),
                },
            ],
            orders: vec![UndoOrder {
                collection: todos.id,
                path: vec![],
                keys: vec![Value::from("b"), Value::from("a")],
            }],
        };
        occ_tx
            .send(Inbox::Occ(Occurrence::Undone {
                window: DEFAULT_WINDOW,
                label: "shuffle".into(),
                delta,
            }))
            .unwrap();
        // The RAW loop, deliberately: the floor is the documented
        // fallback, so it cannot be the tier that misses this.
        let occ = ctx.next();
        assert!(matches!(occ, Occurrence::Undone { .. }));

        let tx = ctx.begin();
        assert_eq!(
            tx.items(&todos),
            vec![
                (Value::from("b"), Todo { title: "b".into(), done: false }),
                (Value::from("a"), Todo { title: "Alpha".into(), done: true }),
            ],
            "the payload's order and states, not the mirror's memory of them"
        );
    }

    /// Per window and PERSISTENT — the section handler's stance, not the
    /// alert's: a history is walked as often as the user likes.
    #[test]
    fn on_undone_and_on_redone_stay_registered() {
        use crate::protocol::{Occurrence, UndoDelta, DEFAULT_WINDOW};

        #[derive(Debug, PartialEq)]
        enum Msg {
            Undid(String),
            Redid(String),
        }

        let (occ_tx, occ_rx) = mpsc::channel();
        let (tx_tx, _tx_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, no_wake());
        let msgs = super::Messages::<Msg>::new();
        msgs.on_undone(DEFAULT_WINDOW, |label, _| Msg::Undid(label));
        msgs.on_redone(DEFAULT_WINDOW, |label, _| Msg::Redid(label));

        let undone = |window| {
            Inbox::Occ(Occurrence::Undone {
                window,
                label: "add todo".into(),
                delta: UndoDelta::default(),
            })
        };
        // EVERYTHING QUEUED, THEN THE CHANNEL CLOSED, and only then read.
        // `next` blocks until something maps, so a version of this test
        // that sent one at a time would HANG rather than fail if the
        // registration turned out to be one-shot — and a negative test that
        // hangs is not a test.
        for occ in [
            undone(DEFAULT_WINDOW),
            undone(DEFAULT_WINDOW),
            Inbox::Occ(Occurrence::Redone {
                window: DEFAULT_WINDOW,
                label: "add todo".into(),
                delta: UndoDelta::default(),
            }),
            // Another window's history is not this one's.
            undone(crate::protocol::WindowId(2)),
        ] {
            occ_tx.send(occ).unwrap();
        }
        drop(occ_tx);
        assert_eq!(msgs.next(&ctx), Some(Msg::Undid("add todo".into())));
        assert_eq!(
            msgs.next(&ctx),
            Some(Msg::Undid("add todo".into())),
            "the registration outlives its first step"
        );
        assert_eq!(msgs.next(&ctx), Some(Msg::Redid("add todo".into())));
        assert_eq!(msgs.next(&ctx), None, "unmapped folds into nothing");
    }
}
