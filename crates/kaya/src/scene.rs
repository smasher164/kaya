//! The scene core: signal storage, the signal-to-binding index, and the
//! widget registry. Transactions come in; resolved apply-ops come out.
//! This is the whole of kaya's reactivity — backends apply what this
//! module emits and never see a signal.
//!
//! Lives on the UI thread, one instance per core. Validation fails
//! loudly: every panic here is a broken guest or binding, not a runtime
//! condition (the same policy as the full ring).

use std::collections::HashMap;

use crate::protocol::{
    ApplyOp, Prop, PropValue, SignalId, Transaction, TxOp, Value, WidgetId, WidgetKind,
};

#[derive(Default)]
pub(crate) struct Scene {
    signals: HashMap<SignalId, Value>,
    /// signal -> the (widget, property) pairs it feeds.
    bindings: HashMap<SignalId, Vec<(WidgetId, Prop)>>,
    widgets: HashMap<WidgetId, WidgetKind>,
    mounted: bool,
}

fn check_prop(kind: WidgetKind, prop: Prop) {
    let ok = match prop {
        Prop::Text => matches!(kind, WidgetKind::Button | WidgetKind::Label),
    };
    assert!(ok, "kaya: {kind:?} has no property {prop:?}");
}

fn check_type(current: &Value, incoming: &Value, id: SignalId) {
    let same = matches!(
        (current, incoming),
        (Value::Bool(_), Value::Bool(_))
            | (Value::I64(_), Value::I64(_))
            | (Value::F64(_), Value::F64(_))
            | (Value::Str(_), Value::Str(_))
    );
    assert!(same, "kaya: write changes the type of signal {id:?}");
}

impl Scene {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Apply one transaction atomically, returning the ops a backend
    /// must perform. Construction ops come out in submission order;
    /// signal writes coalesce (last write wins per signal within the
    /// batch) and flush as targeted property sets at the end. A property
    /// bound mid-transaction is also set immediately at bind time, so a
    /// scene arrives fully valued; the end-of-batch flush may repeat
    /// such a set with the same value, which is harmless.
    pub(crate) fn apply(&mut self, tx: Transaction) -> Vec<ApplyOp> {
        let mut out = Vec::new();
        // First-dirtied order, deduped.
        let mut dirty: Vec<SignalId> = Vec::new();

        for op in tx {
            match op {
                TxOp::CreateSignal { id, initial } => {
                    let clash = self.signals.insert(id, initial).is_some();
                    assert!(!clash, "kaya: signal id {id:?} already exists");
                }
                TxOp::WriteSignal { id, value } => {
                    let current = self
                        .signals
                        .get_mut(&id)
                        .unwrap_or_else(|| panic!("kaya: write to unknown signal {id:?}"));
                    check_type(current, &value, id);
                    *current = value;
                    if !dirty.contains(&id) {
                        dirty.push(id);
                    }
                }
                TxOp::CreateWidget { id, kind } => {
                    let clash = self.widgets.insert(id, kind).is_some();
                    assert!(!clash, "kaya: widget id {id:?} already exists");
                    out.push(ApplyOp::Create { id, kind });
                }
                TxOp::SetProperty {
                    widget,
                    prop,
                    value,
                } => {
                    let kind = *self
                        .widgets
                        .get(&widget)
                        .unwrap_or_else(|| panic!("kaya: property on unknown widget {widget:?}"));
                    check_prop(kind, prop);
                    match value {
                        PropValue::Const(v) => out.push(ApplyOp::SetProp {
                            id: widget,
                            prop,
                            value: v,
                        }),
                        PropValue::Signal(id) => {
                            let current = self
                                .signals
                                .get(&id)
                                .unwrap_or_else(|| {
                                    panic!("kaya: binding to unknown signal {id:?}")
                                })
                                .clone();
                            self.bindings.entry(id).or_default().push((widget, prop));
                            out.push(ApplyOp::SetProp {
                                id: widget,
                                prop,
                                value: current,
                            });
                        }
                    }
                }
                TxOp::AddChild { parent, child } => {
                    assert!(
                        self.widgets.contains_key(&parent),
                        "kaya: add_child to unknown parent {parent:?}"
                    );
                    assert!(
                        self.widgets.contains_key(&child),
                        "kaya: add_child of unknown child {child:?}"
                    );
                    out.push(ApplyOp::AddChild { parent, child });
                }
                TxOp::Mount { window, root } => {
                    assert!(
                        self.widgets.contains_key(&root),
                        "kaya: mount of unknown root {root:?}"
                    );
                    assert!(
                        !self.mounted,
                        "kaya: one scene per window until the window vocabulary lands"
                    );
                    self.mounted = true;
                    out.push(ApplyOp::Mount { window, root });
                }
            }
        }

        for id in dirty {
            let value = self.signals[&id].clone();
            if let Some(bound) = self.bindings.get(&id) {
                for (widget, prop) in bound {
                    out.push(ApplyOp::SetProp {
                        id: *widget,
                        prop: *prop,
                        value: value.clone(),
                    });
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{DEFAULT_WINDOW, WindowId};

    fn milestone1_scene() -> Transaction {
        vec![
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
                window: DEFAULT_WINDOW,
                root: WidgetId(1),
            },
        ]
    }

    /// The milestone-1 scene: construction in order, the bound label
    /// valued at bind time, mount last.
    #[test]
    fn scene_applies_in_order_and_values_bindings() {
        let mut scene = Scene::new();
        let ops = scene.apply(milestone1_scene());
        assert_eq!(
            ops,
            vec![
                ApplyOp::Create {
                    id: WidgetId(1),
                    kind: WidgetKind::Column
                },
                ApplyOp::Create {
                    id: WidgetId(2),
                    kind: WidgetKind::Button
                },
                ApplyOp::SetProp {
                    id: WidgetId(2),
                    prop: Prop::Text,
                    value: Value::from("Click me")
                },
                ApplyOp::Create {
                    id: WidgetId(3),
                    kind: WidgetKind::Label
                },
                ApplyOp::SetProp {
                    id: WidgetId(3),
                    prop: Prop::Text,
                    value: Value::from("Clicked 0 times")
                },
                ApplyOp::AddChild {
                    parent: WidgetId(1),
                    child: WidgetId(2)
                },
                ApplyOp::AddChild {
                    parent: WidgetId(1),
                    child: WidgetId(3)
                },
                ApplyOp::Mount {
                    window: WindowId(0),
                    root: WidgetId(1)
                },
            ]
        );
    }

    /// A signal write becomes exactly the property sets its bindings
    /// dictate — the whole of reactivity, resolved core-side.
    #[test]
    fn write_resolves_to_targeted_sets() {
        let mut scene = Scene::new();
        scene.apply(milestone1_scene());
        let ops = scene.apply(vec![TxOp::WriteSignal {
            id: SignalId(1),
            value: Value::from("Clicked 1 time"),
        }]);
        assert_eq!(
            ops,
            vec![ApplyOp::SetProp {
                id: WidgetId(3),
                prop: Prop::Text,
                value: Value::from("Clicked 1 time")
            }]
        );
    }

    /// Last write wins within a batch: two writes, one set.
    #[test]
    fn writes_coalesce_within_a_transaction() {
        let mut scene = Scene::new();
        scene.apply(milestone1_scene());
        let ops = scene.apply(vec![
            TxOp::WriteSignal {
                id: SignalId(1),
                value: Value::from("Clicked 1 time"),
            },
            TxOp::WriteSignal {
                id: SignalId(1),
                value: Value::from("Clicked 2 times"),
            },
        ]);
        assert_eq!(
            ops,
            vec![ApplyOp::SetProp {
                id: WidgetId(3),
                prop: Prop::Text,
                value: Value::from("Clicked 2 times")
            }]
        );
    }

    /// One signal can feed many properties; one write fans out.
    #[test]
    fn one_signal_many_bindings() {
        let mut scene = Scene::new();
        let mut tx = milestone1_scene();
        tx.push(TxOp::SetProperty {
            widget: WidgetId(2),
            prop: Prop::Text,
            value: PropValue::Signal(SignalId(1)),
        });
        scene.apply(tx);
        let ops = scene.apply(vec![TxOp::WriteSignal {
            id: SignalId(1),
            value: Value::from("both"),
        }]);
        assert_eq!(ops.len(), 2);
    }

    #[test]
    #[should_panic(expected = "already exists")]
    fn id_collisions_fail_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: Value::Bool(false),
            },
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: Value::Bool(true),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "changes the type")]
    fn type_changes_fail_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: Value::I64(0),
            },
            TxOp::WriteSignal {
                id: SignalId(1),
                value: Value::from("nope"),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "has no property")]
    fn wrong_property_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget {
                id: WidgetId(1),
                kind: WidgetKind::Column,
            },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Text,
                value: PropValue::Const(Value::from("x")),
            },
        ]);
    }
}
