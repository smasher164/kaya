//! The entry scene (tools/scenes/entry.steps). ONE OF TWO RUST GUESTS ON
//! THE RAW EVENT SURFACE: it matches `ctx.next()` directly.

use kaya::Occurrence;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Todo {
    title: String,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let (status, field, add, todos) = ctx.apply(|tx| {
        let status = tx.signal("no todos");
        let todos = tx.collection::<Todo>();

        let (root, (field, add)) = tx
            .column(|tx| {
                let field = tx.entry().id(); // entry#0
                let add = tx.button("add").id(); // button#0
                tx.label(status); // label#0
                // The body runs ONCE; the row's Drop closes the template.
                for mut row in todos.rows(tx) {
                    row.label(Todo::title());
                }
                (field, add)
            })
            .into_parts();
        tx.mount(root);
        (status, field, add, todos)
    });

    let mut draft = String::new();
    loop {
        match ctx.next() {
            Occurrence::TextChanged { id, text } if id == field => draft = text,
            Occurrence::ButtonClicked { id } if id == add => {
                // The guard, and the proof that the clear below folded.
                if draft.is_empty() {
                    ctx.apply(|tx| {
                        let total = tx.len(&todos);
                        tx.write(status, format!("nothing to add, {total} total"));
                    });
                    continue;
                }
                ctx.apply(|tx| {
                    // The binding mints the key (docs/fresh-key-plan.md).
                    tx.insert_fresh(&todos, Todo { title: draft.clone() });
                    let total = tx.len(&todos);
                    tx.write(status, format!("added {draft}, {total} total"));
                    // Atomic with the insert; the field answers with
                    // text_changed("").
                    tx.clear(field);
                    tx.focus(field);
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
