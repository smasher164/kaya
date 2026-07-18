//! The todos scene: records and field projection, end to end — the
//! design appendix's app on the structural core. The record! macro
//! derives the schema, the conversions, and the field tokens from one
//! struct; bind_field unifies each field's type with its property's at
//! compile time; toggling a row records one field's delta through the
//! generated patch builder — the title never travels — and the
//! items-left label is a derived signal the binding recomputes from
//! the collection after every mutation, so no handler mentions it.
//!
//! The backend selftest (KAYA_SELFTEST=todos) types "buy milk", clicks
//! Add, toggles the stamped row's checkbox, and expects the status
//! label to read exactly "0 items left".

use kaya::Occurrence;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Todo {
    title: String,
    done: bool,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    // The construction sugar: containers take their children, and the
    // build body reads as the tree (milestone2 keeps the fully
    // explicit floor on purpose; see guests/c). Handlers stay in the occurrence
    // loop, the Rust idiom.
    let (todos, field, add, check) = ctx.apply(|tx| {
        let todos = tx.collection::<Todo>();
        let items_left = todos.derive(tx, |items| {
            let n = items.iter().filter(|(_, t)| !t.done).count();
            if n == 1 { "1 item left".to_string() } else { format!("{n} items left") }
        });

        let (root, (field, add, check)) = tx.column(|tx| {
            let field = tx.entry();
            let add = tx.button("Add");
            tx.label(items_left);
            // The tracing tier: the for statement IS the For — the
            // body runs once, authoring the blueprint, and the row's
            // Drop closes the template (break- and panic-safe; while
            // the row lives, the transaction is reachable only
            // through it).
            let mut check = None;
            for mut row in todos.rows(tx) {
                let (_, c) = row.row(|t| {
                    let c = t.checkbox(Todo::done());
                    t.label(Todo::title());
                    c
                });
                check = Some(c);
            }
            (field, add, check.expect("rows yields one row"))
        });
        tx.mount(root);
        (todos, field, add, check)
    });

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this variable, not a widget read.
    let mut draft = String::new();
    let mut next_key = 0u32;
    loop {
        match ctx.next() {
            Occurrence::TextChanged { id, text } if id == field => draft = text,
            Occurrence::ButtonClicked { id } if id == add => {
                next_key += 1;
                ctx.apply(|tx| {
                    tx.insert(
                        &todos,
                        format!("t{next_key}"),
                        Todo { title: draft.clone(), done: false },
                    );
                });
            }
            Occurrence::InstanceToggled { node, path, checked } if node == check => {
                // One field's delta: the title never travels. The
                // patch builder is record!-generated — each setter is
                // one update_field.
                ctx.apply(|tx| {
                    todos.patch(tx, path[0].clone()).done(checked);
                });
            }
            Occurrence::Shutdown => break,
            _ => {}
        }
    }
}

fn main() {
    kaya::run(app)
}
