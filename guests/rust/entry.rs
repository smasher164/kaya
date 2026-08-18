//! The entry scene: the uncontrolled contract end to end. The
//! byte-frozen contract is tools/scenes/entry.steps.
//!
//! ONE OF TWO RUST GUESTS ON THE RAW EVENT SURFACE (milestone2.rs is
//! the other): this matches `ctx.next()` directly instead of folding
//! through `kaya::Messages`. Construction is the ordinary sugar either
//! way — the carve-out is the event mechanism, not the tree (DESIGN.md,
//! scope ratified 2026-08-05).

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
                // The tracing tier: the body runs ONCE, authoring the
                // blueprint, and the row's Drop closes the template.
                for mut row in todos.rows(tx) {
                    row.label(Todo::title());
                }
                (field, add)
            })
            .into_parts();
        tx.mount(root);
        (status, field, add, todos)
    });

    // The app's copy of the field's text: never a widget read.
    let mut draft = String::new();
    loop {
        match ctx.next() {
            Occurrence::TextChanged { id, text } if id == field => draft = text,
            Occurrence::ButtonClicked { id } if id == add => {
                // The empty-draft guard, and the scene's proof that the
                // clear below emptied the draft through the occurrence
                // fold rather than a side assignment.
                if draft.is_empty() {
                    ctx.apply(|tx| {
                        let total = tx.len(&todos);
                        tx.write(status, format!("nothing to add, {total} total"));
                    });
                    continue;
                }
                ctx.apply(|tx| {
                    // The binding mints the key and hands it back
                    // (docs/fresh-key-plan.md); this app has no use for
                    // it, so the call sits in statement position.
                    tx.insert_fresh(&todos, Todo { title: draft.clone() });
                    let total = tx.len(&todos);
                    tx.write(status, format!("added {draft}, {total} total"));
                    // Atomic with the insert. The field answers with
                    // text_changed("") through its normal edit path.
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
