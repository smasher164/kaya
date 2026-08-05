//! The milestone-2 scene: the structural operators live.
//!
//! A driver button steps the app through data changes; a status label
//! (signal-bound) reports what happened; a When shows a banner while
//! "extras" is on; a For over groups nests a For over items, each item
//! carrying a remove button whose click comes back as a template node
//! plus key path — which the app answers by removing that entry, the
//! screen following the data.
//!
//! WHAT THIS SCENE DOCUMENTS IS THE RAW EVENT SURFACE. Every other
//! Rust guest folds through `kaya::Messages` — a meaning enum the
//! compiler holds total — and this one matches `ctx.next()` directly,
//! guarding on widget and template-node identity, which is the tier
//! that surface is built on. Construction is the ordinary sugar either
//! way (DESIGN.md, scope ratified 2026-08-05): the carve-out is the
//! event mechanism, not the tree.
//!
//! AND THE KEYS HERE ARE THE APP'S OWN. "g1" and "a" are names this
//! scene chose and later reads back out loud ("removed g2/a"), so they
//! are data — `insert_fresh` (entry, todos) is for the other case,
//! where a line of text identifies nothing and the binding may as well
//! mint the name.
//!
//! The selftest (in each backend) clicks the driver twice, then the most
//! recently stamped remove button, and expects the status label to read
//! "removed g2/a, 0 left" — the count read back from the collection
//! model right after the remove, proving the patch-producing fold: the
//! collection is the model, and reads are exactly the writes.

use kaya::{Occurrence, Value};

/// A group is a name; an item is a line of text. One field each, so
/// each derive turns the struct's own shape into the schema and mints
/// the field token its template binds through.
#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Group {
    name: String,
}

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Item {
    text: String,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    // The construction sugar: constructors carry their props, the
    // container takes its children through the body, and the build
    // reads as the tree. Handlers stay in the occurrence loop, the
    // Rust idiom; C's guests keep the fully explicit floor.
    let (status, extras, groups, step, items, remove_button) = ctx.apply(|tx| {
        let status = tx.signal("step 0");
        let extras = tx.signal(false);

        // Auto-parenting puts the templates where they stand: the When
        // and the For are declared inside the column, between their
        // siblings, and parent themselves there.
        let groups = tx.collection::<Group>();
        let (root, (step, items, remove_button)) = tx
            .column(|tx| {
                let step = tx.button("step").id();
                tx.label(status);
                tx.when(extras, |t| {
                    t.label("extras on");
                });
                // The tracing tier, nested the way the data nests: each
                // for statement IS a For — the body runs once, authoring
                // the blueprint, and the row's Drop closes the template
                // (break- and panic-safe; while a row lives, the
                // transaction is reachable only through it).
                //
                // A for statement is a statement, so the handles the
                // app still needs afterwards leave through slots the
                // bodies fill: the per-group items collection, and the
                // remove button's node that the loop below matches on.
                // Each trace yields exactly one row, so each slot is
                // filled exactly once.
                let mut items = None;
                let mut remove_button = None;
                for mut group in groups.rows(tx) {
                    group.column(|t| {
                        t.label(Group::name());
                        let per_group = t.collection::<Item>();
                        for mut item in per_group.rows(t) {
                            let (_, remove) = item.column(|t| {
                                t.label(Item::text());
                                t.button("remove")
                            });
                            remove_button = Some(remove);
                        }
                        items = Some(per_group);
                    });
                }
                (
                    step,
                    items.expect("the group trace yields one row"),
                    remove_button.expect("the item trace yields one row"),
                )
            })
            .into_parts();
        tx.mount(root);
        (status, extras, groups, step, items, remove_button)
    });

    let mut steps = 0u32;
    let mut extras_on = false;
    loop {
        match ctx.next() {
            Occurrence::ButtonClicked { id } if id == step => {
                steps += 1;
                ctx.apply(|tx| match steps {
                    1 => {
                        tx.insert(&groups, "g1", Group { name: "Work".into() });
                        let todos = items.at("g1");
                        tx.insert(&todos, "a", Item { text: "send report".into() });
                        tx.insert(&todos, "b", Item { text: "buy milk".into() });
                        extras_on = true;
                    }
                    2 => {
                        tx.insert(&groups, "g2", Group { name: "Home".into() });
                        tx.insert(&items.at("g2"), "a", Item { text: "water plants".into() });
                        tx.update(&groups, "g1", Group { name: "Office".into() });
                        extras_on = false;
                    }
                    _ => {}
                });
                ctx.apply(|tx| {
                    tx.write(extras, extras_on);
                    tx.write(status, format!("step {steps}"));
                });
            }
            Occurrence::InstanceButtonClicked { node, path } if node == remove_button => {
                let [Value::Str(group), Value::Str(item)] = &path[..] else {
                    panic!("remove click carries [group, item], got {path:?}");
                };
                // The instance handle names the target once; mutation
                // and read hang off the same value. The collection is
                // the model: the count read is the fold of the
                // patches, this one included.
                let todos = items.at(path[0].clone());
                ctx.apply(|tx| {
                    tx.remove(&todos, path[1].clone());
                    let left = tx.len(&todos);
                    tx.write(status, format!("removed {group}/{item}, {left} left"));
                });
            }
            Occurrence::ButtonClicked { .. } | Occurrence::InstanceButtonClicked { .. } => {}
            Occurrence::AlertResult { .. }
            | Occurrence::FileDialogResult { .. }
            | Occurrence::ClipboardResult { .. }
            | Occurrence::Pasted { .. }
            | Occurrence::InstancePasted { .. }
            | Occurrence::TextChanged { .. } | Occurrence::InstanceTextChanged { .. } => {}
            Occurrence::Toggled { .. } | Occurrence::InstanceToggled { .. } => {}
            Occurrence::ValueChanged { .. } | Occurrence::InstanceValueChanged { .. } => {}
            Occurrence::CloseRequested { .. } | Occurrence::WindowClosed { .. } => {}
            Occurrence::EntryPopped { .. }
            | Occurrence::BackRequested { .. }
            | Occurrence::SectionSelected { .. } => {}
            Occurrence::MenuActivated { .. }
            | Occurrence::InstanceMenuActivated { .. }
            | Occurrence::MenuToggled { .. }
            | Occurrence::InstanceMenuToggled { .. }
            | Occurrence::MenuValueChanged { .. }
            | Occurrence::InstanceMenuValueChanged { .. } => {}
            Occurrence::Undone { .. } | Occurrence::Redone { .. } => {}
            Occurrence::Shutdown => break,
        }
    }
}

fn main() {
    kaya::run(app)
}
