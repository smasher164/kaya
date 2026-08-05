//! The todos scene: records and field projection, end to end — the
//! design appendix's app on the structural core. The record! macro
//! derives the schema, the conversions, and the field tokens from one
//! struct; bind_field unifies each field's type with its property's at
//! compile time; toggling a row records one field's delta through the
//! generated patch builder — the title never travels — and the
//! items-left label is a derived signal the binding recomputes from
//! the collection after every mutation, so no handler mentions it.
//!
//! AND THE APP NAMES NO TODO. A todo here is a title and a done flag,
//! and neither of them identifies it, so the key comes from
//! `insert_fresh`: the binding mints one per collection instance and
//! hands it back (docs/fresh-key-plan.md). The row's checkbox carries
//! that key back out through the stamped path and straight into
//! `patch`, which is the whole of what this scene asks of a key — the
//! app never reads it, formats it or compares it, and so has no reason
//! to author it.
//!
//! AND THE DERIVED LABEL SURVIVES AN UNDO WITHOUT ANYONE RESTORING IT.
//! The add is a named step (`tx.undoable`), and the derive's write is
//! in that same batch — the binding recomputes after the insert and
//! pushes an ordinary signal write into the transaction that caused it
//! — so the core banks the label in both directions of the step and
//! hands it back with the collection. That is why this file registers
//! no `on_undone`: there is nothing for a handler to fix up, and a
//! binding that recomputed the derive while absorbing the payload would
//! be writing a value the ledger never banked (see AppCtx::absorb_undo).
//!
//! The backend selftest (KAYA_SELFTEST=todos) types "buy milk", clicks
//! Add, reads "1 item left", walks the add back and forward through the
//! Edit menu reading the label at each end, then toggles the stamped
//! row's checkbox and expects the label to read exactly "0 items left".

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Todo {
    title: String,
    done: bool,
}

/// The app's event vocabulary: the occurrence-side eliminator. The
/// match below is held to totality by the compiler, and a variant no
/// widget produces trips dead_code ("variant is never constructed").
#[derive(Clone)]
enum Msg {
    Draft(String),
    Add,
    Toggle(kaya::Path, bool),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    // The construction sugar: containers take their children, and the
    // build body reads as the tree (milestone2 keeps the fully
    // explicit floor on purpose; see guests/c). Handlers stay in the occurrence
    // loop, the Rust idiom.
    let msgs = kaya::Messages::new();
    let (todos, field) = ctx.apply(|tx| {
        // THE GESTURE LAYER, and the two items are the whole of it: an
        // app declares them and writes nothing else. They act on what
        // is focused, lower to the platform's own command where it has
        // one, and work out their own enablement from what the ledger
        // holds (docs/undo-plan.md D1-D6).
        tx.window(kaya::DEFAULT_WINDOW)
            .title("todos")
            .menu("Edit", |m| {
                m.item("Undo").role(kaya::MenuRole::Undo).id();
                m.item("Redo").role(kaya::MenuRole::Redo).id();
            })
            .id();
        let todos = tx.collection::<Todo>();
        let items_left = todos.derive(tx, |items| {
            let n = items.iter().filter(|(_, t)| !t.done).count();
            if n == 1 { "1 item left".to_string() } else { format!("{n} items left") }
        });

        let (root, field) = tx
            .column(|tx| {
                let field = tx.entry().id();
                msgs.on_change(field, Msg::Draft);
                let add = tx.button("Add").id();
                msgs.on_click(add, Msg::Add);
            tx.label(items_left);
            // The tracing tier: the for statement IS the For — the
            // body runs once, authoring the blueprint, and the row's
            // Drop closes the template (break- and panic-safe; while
            // the row lives, the transaction is reachable only
            // through it).
            for mut row in todos.rows(tx) {
                row.row(|t| {
                    let c = t.checkbox(Todo::done());
                    msgs.on_toggle_node(c, Msg::Toggle);
                    t.label(Todo::title());
                });
            }
                field
            })
            .into_parts();
        tx.mount(root);
        (todos, field)
    });

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this variable, not a widget read.
    let mut draft = String::new();
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Draft(text) => draft = text,
            Msg::Add => {
                if draft.is_empty() {
                    continue;
                }
                let step = format!("add {draft}");
                ctx.apply(|tx| {
                    // ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. What
                    // makes the ITEMS-LEFT LABEL come back with the todo
                    // is that the derive's write is in this batch:
                    // `insert_fresh` recomputes and pushes an ordinary
                    // signal write, and a named transaction banks every
                    // signal it dirtied in both directions. So the
                    // step's inverse carries "0 items left" and its
                    // forward carries "1 item left", and the label is
                    // restored by the same mechanism as the collection.
                    tx.undoable(step);
                    // NO KEY, AND NO COUNTER TO GET WRONG: the binding
                    // mints the name and hands it back. This app has no
                    // use for the returned key — a todo is looked up by
                    // nothing, and the checkbox's own path names its row
                    // — so the call is made for effect.
                    tx.insert_fresh(&todos, Todo { title: draft.clone(), done: false });
                });
                // FINISHING THE FORM IS NOT PART OF THE STEP. Its own
                // transaction, so undoing the add does not put the draft
                // back beside a todo that is gone — and `clear` inside a
                // group would be refused at apply anyway (D4), because
                // it destroys widget-owned text the core never held. The
                // field empties on screen and reports text_changed("")
                // through its normal edit path (the fold empties the
                // draft), and the cursor lands back in it.
                ctx.apply(|tx| {
                    tx.clear(field);
                    tx.focus(field);
                });
            }
            Msg::Toggle(path, checked) => {
                // One field's delta: the title never travels. The
                // patch builder is derive-generated — each setter is
                // one update_field.
                ctx.apply(|tx| {
                    todos.patch(tx, path[0].clone()).done(checked);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
