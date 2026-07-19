//! The entry scene: the first widget with owned state, exercising the
//! uncontrolled contract end to end. The field owns its text and
//! reports each edit as a TextChanged occurrence; the app folds those
//! into a plain variable (`draft`) — its own model, per doctrine; there
//! is no read-back from the widget. The add button inserts the draft
//! into the todos collection and answers with the count read from the
//! collection model (the patch-producing fold, same as milestone 2).
//!
//! The backend selftest (KAYA_SELFTEST=entry) types "milk", clicks add,
//! and expects the status label to read "added milk, 1 total", the
//! field cleared and refocused (the one-shot commands riding the same
//! transaction as the insert), and a second add to answer "nothing to
//! add, 1 total" — proving the clear's text_changed("") re-entered
//! through the normal fold and emptied the draft.

use kaya::{Occurrence, Prop, WidgetKind};

pub(crate) fn app(ctx: kaya::AppCtx) {
    let (status, field, add, todos) = ctx.apply(|tx| {
        let status = tx.signal("no todos");

        let column = tx.widget(WidgetKind::Column);
        let field = tx.widget(WidgetKind::Entry);
        let add = tx.widget(WidgetKind::Button);
        tx.set(add, Prop::Text, "add");
        let status_label = tx.widget(WidgetKind::Label);
        tx.bind(status_label, Prop::Text, status);

        let todos = tx.collection::<String>();
        let (todo_list, ()) = tx.for_each(&todos, |t| {
            let label = t.widget(WidgetKind::Label);
            t.bind_element(label, Prop::Text, 0);
        });

        tx.add_child(column, field);
        tx.add_child(column, add);
        tx.add_child(column, status_label);
        tx.add_child(column, todo_list);
        tx.mount(column);
        (status, field, add, todos)
    });

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this variable, not a widget read.
    let mut draft = String::new();
    let mut next_key = 0u32;
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
                next_key += 1;
                ctx.apply(|tx| {
                    tx.insert(&todos, format!("t{next_key}"), draft.clone());
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
