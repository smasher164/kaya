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

#[derive(kaya::Kaya, Clone, Debug, PartialEq)]
struct Todo {
    title: String,
    done: bool,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    // The construction sugar: containers take their children, and the
    // build body reads as the tree (milestone2 keeps the fully
    // explicit floor on purpose; see guests/c). Handlers stay in the occurrence
    // loop, the Rust idiom.
    let mut tx = ctx.begin();
    let todos = tx.collection::<Todo>();
    let items_left = todos.derive(&mut tx, |items| {
        let n = items.iter().filter(|(_, t)| !t.done).count();
        if n == 1 { "1 item left".to_string() } else { format!("{n} items left") }
    });

    let field = tx.entry();
    let add = tx.button("Add");
    let status = tx.label(items_left);
    let (todo_list, check) = tx.for_each(&todos, |t| {
        let check = t.checkbox(Todo::done());
        let title = t.label(Todo::title());
        t.row(&[check, title]);
        check
    });
    let root = tx.column(&[field, add, status, todo_list]);
    tx.mount(root);
    tx.commit();

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this variable, not a widget read.
    let mut draft = String::new();
    let mut next_key = 0u32;
    loop {
        match ctx.next() {
            Occurrence::TextChanged { id, text } if id == field => draft = text,
            Occurrence::ButtonClicked { id } if id == add => {
                next_key += 1;
                let mut tx = ctx.begin();
                tx.insert(
                    &todos,
                    format!("t{next_key}"),
                    Todo { title: draft.clone(), done: false },
                );
                tx.commit();
            }
            Occurrence::InstanceToggled { node, path, checked } if node == check => {
                // One field's delta: the title never travels. The
                // patch builder is record!-generated — each setter is
                // one update_field.
                let mut tx = ctx.begin();
                todos.patch(&mut tx, path[0].clone()).done(checked);
                tx.commit();
            }
            Occurrence::Shutdown => break,
            _ => {}
        }
    }
}

fn main() {
    kaya::run(app)
}
