//! The app thread's view of the world: occurrences in, transactions out.

use std::cell::Cell;
use std::sync::mpsc::{Receiver, Sender};

use crate::protocol::{
    DEFAULT_WINDOW, Occurrence, Prop, PropValue, SignalId, Transaction, TxOp, Value, WidgetId,
    WidgetKind,
};

pub struct AppCtx {
    pub(crate) occurrences: Receiver<Occurrence>,
    pub(crate) transactions: Sender<Transaction>,
    next_signal: Cell<u64>,
    next_widget: Cell<u64>,
}

impl AppCtx {
    pub(crate) fn new(occurrences: Receiver<Occurrence>, transactions: Sender<Transaction>) -> Self {
        AppCtx {
            occurrences,
            transactions,
            next_signal: Cell::new(1),
            next_widget: Cell::new(1),
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
}

/// A transaction under construction. Everything queues locally; commit
/// sends the batch and rings the doorbell once.
pub struct Tx<'a> {
    ctx: &'a AppCtx,
    ops: Vec<TxOp>,
}

impl Tx<'_> {
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

    /// Mount into the default window; per-window targets arrive with the
    /// window vocabulary.
    pub fn mount(&mut self, root: WidgetId) {
        self.ops.push(TxOp::Mount {
            window: DEFAULT_WINDOW,
            root,
        });
    }

    /// Send the batch and wake the main loop to apply it.
    pub fn commit(self) {
        if self.ctx.transactions.send(self.ops).is_ok() {
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
}
