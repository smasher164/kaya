//! The entry scene: the first widget with owned state, exercising the
//! uncontrolled contract end to end. The field owns its text and
//! reports each edit as a TextChanged occurrence; the app folds those
//! into a plain variable (`draft`) — its own model, per doctrine; there
//! is no read-back from the widget. The add button inserts the draft
//! into the todos collection and answers with the count read from the
//! collection model (the patch-producing fold, same as milestone 2).
//!
//! WHAT THIS SCENE DOCUMENTS IS THE RAW EVENT SURFACE. Every other
//! Rust guest folds through `kaya::Messages` — a meaning enum the
//! compiler holds total — and this one matches `ctx.next()` directly,
//! guarding on widget identity, which is the tier that surface is
//! built on. Construction is the ordinary sugar either way (DESIGN.md,
//! entry's scope ratified 2026-08-05): the carve-out is the event
//! mechanism, not the tree.
//!
//! The backend selftest (KAYA_SELFTEST=entry) types "milk", clicks add,
//! and expects the status label to read "added milk, 1 total", the
//! field cleared and refocused (the one-shot commands riding the same
//! transaction as the insert), and a second add to answer "nothing to
//! add, 1 total" — proving the clear's text_changed("") re-entered
//! through the normal fold and emptied the draft.

use kaya::Occurrence;

/// A todo is a title and nothing else, which is exactly why the app
/// authors no key for one (see the insert below). The derive turns the
/// struct's own shape into the schema and mints the field token the
/// row binds through.
#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Todo {
    title: String,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    // The construction sugar: constructors carry their props, the
    // container takes its children through the body, and the build
    // reads as the tree. The two widgets whose events this app wants
    // ride out of the body as its result — the raw loop below matches
    // on their ids.
    let (status, field, add, todos) = ctx.apply(|tx| {
        let status = tx.signal("no todos");
        let todos = tx.collection::<Todo>();

        let (root, (field, add)) = tx
            .column(|tx| {
                let field = tx.entry().id(); // entry#0
                let add = tx.button("add").id(); // button#0
                tx.label(status); // label#0
                // The tracing tier: the for statement IS the For — the
                // body runs once, authoring the blueprint, and the
                // row's Drop closes the template.
                for mut row in todos.rows(tx) {
                    row.label(Todo::title());
                }
                (field, add)
            })
            .into_parts();
        tx.mount(root);
        (status, field, add, todos)
    });

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this variable, not a widget read.
    let mut draft = String::new();
    loop {
        match ctx.next() {
            Occurrence::TextChanged { id, text } if id == field => draft = text,
            Occurrence::ButtonClicked { id } if id == add => {
                // The empty-draft guard every real form has — and the
                // scene's proof that clear emptied the draft through
                // the occurrence fold, not a side assignment.
                if draft.is_empty() {
                    ctx.apply(|tx| {
                        let total = tx.len(&todos);
                        tx.write(status, format!("nothing to add, {total} total"));
                    });
                    continue;
                }
                ctx.apply(|tx| {
                    // NO KEY, AND NO COUNTER TO GET WRONG: a line of
                    // text has no identity of its own, so the binding
                    // mints the name and hands it back
                    // (docs/fresh-key-plan.md). Rust discards a return
                    // by calling in statement position; an app that
                    // needed the name — to select the new row, say —
                    // takes it from here rather than inventing a second
                    // name for the same datum.
                    tx.insert_fresh(&todos, Todo { title: draft.clone() });
                    let total = tx.len(&todos);
                    tx.write(status, format!("added {draft}, {total} total"));
                    // Finish the form: drop the field's content and put
                    // the cursor back, atomically with the insert. The
                    // field answers with text_changed("") through its
                    // normal edit path, and the fold above empties the
                    // draft.
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
