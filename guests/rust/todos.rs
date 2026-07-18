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
    let todos = ctx.apply(|tx| {
        let todos = tx.collection::<Todo>();
        let items_left = todos.derive(tx, |items| {
            let n = items.iter().filter(|(_, t)| !t.done).count();
            if n == 1 { "1 item left".to_string() } else { format!("{n} items left") }
        });

        let (root, ()) = tx.column(|tx| {
            let field = tx.entry();
            msgs.on_change(field, Msg::Draft);
            let add = tx.button("Add");
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
        });
        tx.mount(root);
        todos
    });

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this variable, not a widget read.
    let mut draft = String::new();
    let mut next_key = 0u32;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Draft(text) => draft = text,
            Msg::Add => {
                next_key += 1;
                ctx.apply(|tx| {
                    tx.insert(
                        &todos,
                        format!("t{next_key}"),
                        Todo { title: draft.clone(), done: false },
                    );
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
