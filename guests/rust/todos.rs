//! The todos scene: records and field projection, end to end. The
//! byte-frozen contract is tools/scenes/todos.steps.
//!
//! IT REGISTERS NO `on_undone` ON PURPOSE. The derive's write lands in
//! the same batch as the insert, so the ledger banks the items-left
//! label in both directions of the step; a binding that recomputed the
//! derive while absorbing the payload would write a value the ledger
//! never banked (see AppCtx::absorb_undo).

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Todo {
    title: String,
    done: bool,
}

#[derive(Clone)]
enum Msg {
    Draft(String),
    Add,
    Toggle(kaya::Path, bool),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (todos, field) = ctx.apply(|tx| {
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
            // The tracing tier: the body runs ONCE, authoring the
            // blueprint, and the row's Drop closes the template.
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

    // The app's copy of the field's text: never a widget read.
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
                    // The derive's write must land in THIS batch: a
                    // named transaction banks every signal it dirtied in
                    // both directions, which is what brings the
                    // items-left label back with the todo.
                    tx.undoable(step);
                    tx.insert_fresh(&todos, Todo { title: draft.clone(), done: false });
                });
                // Its OWN transaction: the clear is not part of the step,
                // and `clear` inside a group is refused at apply (D4).
                ctx.apply(|tx| {
                    tx.clear(field);
                    tx.focus(field);
                });
            }
            Msg::Toggle(path, checked) => {
                // One field's delta: the title never travels.
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
