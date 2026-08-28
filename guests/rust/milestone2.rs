//! The milestone-2 scene: the structural operators live. The
//! byte-frozen contract is tools/scenes/milestone2.steps.
//!
//! ONE OF TWO RUST GUESTS ON THE RAW EVENT SURFACE (entry.rs is the
//! other): this matches `ctx.next()` directly instead of folding
//! through `kaya::Messages`. Construction is the ordinary sugar either
//! way — the carve-out is the event mechanism, not the tree (DESIGN.md,
//! scope ratified 2026-08-05).

use kaya::{Occurrence, Value};

/// A group is a name; an item is a line of text.
#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Group {
    name: String,
}

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Item {
    text: String,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let (status, extras, groups, step, items, remove_button) = ctx.apply(|tx| {
        let status = tx.signal("step 0");
        let extras = tx.signal(false);

        let groups = tx.collection::<Group>();
        let (root, (step, items, remove_button)) = tx
            .column(|tx| {
                let step = tx.button("step").id();
                tx.label(status);
                tx.when(extras, |t| {
                    t.label("extras on");
                });
                // The tracing tier: each `for` statement IS a For, its
                // body runs ONCE authoring the blueprint, and the row's
                // Drop closes the template. Being a statement it yields
                // nothing, so handles leave through slots the bodies
                // fill — filled exactly once, which no compiler can see.
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
            Occurrence::SortRequested { .. } | Occurrence::InstanceSortRequested { .. } => {}
            // This scene's canvases are `scale`, which asks for nothing
            // (docs/canvas-plan.md §3.2.1) — in fact it has none.
            Occurrence::DrawRequested { .. }
            | Occurrence::InstanceDrawRequested { .. }
            | Occurrence::Tick { .. }
            | Occurrence::InstanceTick { .. } => {}
            Occurrence::Shutdown => break,
        }
    }
}

fn main() {
    kaya::run(app)
}
