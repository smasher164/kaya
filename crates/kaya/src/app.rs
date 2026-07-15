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
use std::sync::mpsc::{Receiver, Sender};

use crate::protocol::{
    CollectionId, DEFAULT_WINDOW, Occurrence, Prop, PropValue, SignalId, TemplateNodeId,
    Transaction, TxOp, Value, WidgetId, WidgetKind,
};

/// One instance of a collection: the table inside the stamped copy
/// selected by `path` (the empty path for a live-zone collection).
/// Entries keep insertion order, matching the core's rendering.
#[derive(Clone, Debug)]
struct Instance {
    path: Vec<Value>,
    entries: Vec<(Value, Value)>,
}

/// A collection instance handle: the collection plus the key path
/// selecting one stamped copy's table. `tx.collection()` returns the
/// root (empty-path, live-zone) handle; `at(key)` steps into a copy,
/// one key per enclosing For. Mutations and reads take the handle, so
/// the target is spelled once.
#[derive(Clone, Debug)]
pub struct Collection {
    id: CollectionId,
    path: Vec<Value>,
}

impl Collection {
    /// The instance of this collection inside the copy keyed by `key`
    /// of the next enclosing For; chain for deeper nesting.
    pub fn at(&self, key: impl Into<Value>) -> Collection {
        let mut path = self.path.clone();
        path.push(key.into());
        Collection { id: self.id, path }
    }
}

/// A For binds the collection itself — its template stamps per entry
/// of every instance — so handing it an `at(...)` handle is a bug.
fn assert_root(collection: &Collection) {
    assert!(
        collection.path.is_empty(),
        "kaya: for_each binds the collection itself, not an instance — drop the at(...)"
    );
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

    fn model_set(&mut self, collection: CollectionId, path: &[Value], key: &Value, value: &Value) {
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
            Some((_, v)) => *v = value.clone(),
            None => instance.entries.push((key.clone(), value.clone())),
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
    /// committed patch plus this transaction's own, in insertion order.
    pub fn items(&self, instance: &Collection) -> Vec<(Value, Value)> {
        self.ctx
            .model
            .borrow()
            .get(&instance.id)
            .and_then(|instances| instances.iter().find(|i| i.path == instance.path))
            .map(|i| i.entries.clone())
            .unwrap_or_default()
    }

    pub fn len(&self, instance: &Collection) -> usize {
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

    /// Declare a collection: a core-side keyed table a For renders.
    /// Returns the root instance handle (the live-zone table).
    pub fn collection(&mut self) -> Collection {
        let id = self.ctx.alloc_collection();
        self.ctx.register_collection(id);
        self.ops.push(TxOp::CreateCollection { id });
        Collection {
            id,
            path: Vec::new(),
        }
    }

    pub fn insert(
        &mut self,
        instance: &Collection,
        key: impl Into<Value>,
        value: impl Into<Value>,
    ) {
        let (key, value) = (key.into(), value.into());
        self.model_set(instance.id, &instance.path, &key, &value);
        self.ops.push(TxOp::CollectionInsert {
            id: instance.id,
            path: instance.path.clone(),
            key,
            value,
        });
    }

    pub fn update(
        &mut self,
        instance: &Collection,
        key: impl Into<Value>,
        value: impl Into<Value>,
    ) {
        let (key, value) = (key.into(), value.into());
        self.model_set(instance.id, &instance.path, &key, &value);
        self.ops.push(TxOp::CollectionUpdate {
            id: instance.id,
            path: instance.path.clone(),
            key,
            value,
        });
    }

    pub fn remove(&mut self, instance: &Collection, key: impl Into<Value>) {
        let key = key.into();
        self.model_remove(instance.id, &instance.path, &key);
        self.ops.push(TxOp::CollectionRemove {
            id: instance.id,
            path: instance.path.clone(),
            key,
        });
    }

    /// A For over `collection`: the closure declares the template — a
    /// blueprint stamped once per entry, rendering nothing by itself.
    /// Returns the For's widget id (a container in the live tree)
    /// alongside the body's result — the way handles declared inside
    /// the template (nested collections, buttons) reach the handlers.
    pub fn for_each<R>(
        &mut self,
        collection: &Collection,
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

    /// Bind a property to the element — the entry's value — of the
    /// enclosing For, `level` Fors up (0 = nearest).
    pub fn bind_element(&mut self, node: TemplateNodeId, prop: Prop, level: u32) {
        self.tx.ops.push(TxOp::SetProperty {
            widget: WidgetId(node.0),
            prop,
            value: PropValue::Element { level },
        });
    }

    pub fn add_child(&mut self, parent: TemplateNodeId, child: TemplateNodeId) {
        self.tx.ops.push(TxOp::AddChild {
            parent: WidgetId(parent.0),
            child: WidgetId(child.0),
        });
    }

    /// Declare a collection inside the template: each stamped copy gets
    /// its own instance, addressed via `at(key)` on the returned root
    /// handle. Return it from the template body so handlers can reach
    /// it — for_each hands the body's result back out.
    pub fn collection(&mut self) -> Collection {
        let id = self.tx.ctx.alloc_collection();
        self.tx.ctx.register_collection(id);
        self.tx.ops.push(TxOp::CreateCollection { id });
        Collection {
            id,
            path: Vec::new(),
        }
    }

    /// A nested For; its collection must be declared in this template.
    /// Returns the For's node alongside the body's result.
    pub fn for_each<R>(
        &mut self,
        collection: &Collection,
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

    use super::AppCtx;
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
                    | Occurrence::InstanceToggled { .. } => {}
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
        let groups = tx.collection();
        let (_list, items) = tx.for_each(&groups, |t| t.collection());

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
        let c = tx.collection();
        let _ = tx.for_each(&c.at("g1"), |_| ());
    }
}
