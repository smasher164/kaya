//! The entry scene: the first widget with owned state, exercising the
//! uncontrolled contract end to end. The field owns its text and
//! reports each edit as a TextChanged occurrence; the app folds those
//! into a plain variable (`draft`) — its own model, per doctrine; there
//! is no read-back from the widget. The add button inserts the draft
//! into the todos collection and answers with the count read from the
//! collection model (the patch-producing fold, same as milestone 2).
//!
//! The backend selftest (KAYA_SELFTEST=entry) types "milk", clicks add,
//! and expects the status label to read exactly "added milk, 1 total".

use kaya::{Occurrence, Prop, WidgetKind};

pub(crate) fn app(ctx: kaya::AppCtx) {
    let mut tx = ctx.begin();
    let status = tx.signal("no todos");

    let column = tx.widget(WidgetKind::Column);
    let field = tx.widget(WidgetKind::Entry);
    let add = tx.widget(WidgetKind::Button);
    tx.set(add, Prop::Text, "add");
    let status_label = tx.widget(WidgetKind::Label);
    tx.bind(status_label, Prop::Text, status);

    let todos = tx.collection();
    let (todo_list, ()) = tx.for_each(&todos, |t| {
        let label = t.widget(WidgetKind::Label);
        t.bind_element(label, Prop::Text, 0);
    });

    tx.add_child(column, field);
    tx.add_child(column, add);
    tx.add_child(column, status_label);
    tx.add_child(column, todo_list);
    tx.mount(column);
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
                tx.insert(&todos, format!("t{next_key}"), draft.clone());
                let total = tx.len(&todos);
                tx.write(status, format!("added {draft}, {total} total"));
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
