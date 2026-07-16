//! The todos scene: records and field projection, end to end — the
//! design appendix's app on the structural core. The record! macro
//! derives the schema, the conversions, and the field tokens from one
//! struct; bind_field unifies each field's type with its property's at
//! compile time; and toggling a row sends one field's delta through
//! update_field — the title never travels.
//!
//! The backend selftest (KAYA_SELFTEST=todos) types "buy milk", clicks
//! Add, toggles the stamped row's checkbox, and expects the status
//! label to read exactly "0 items left".

use kaya::{Occurrence, Prop, WidgetKind, props};

kaya::record! {
    struct Todo {
        title: String,
        done: bool,
    }
}

fn items_left_text(tx: &kaya::Tx<'_>, todos: &kaya::Collection<Todo>) -> String {
    let n = tx.items(todos).iter().filter(|(_, t)| !t.done).count();
    if n == 1 {
        "1 item left".to_string()
    } else {
        format!("{n} items left")
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let mut tx = ctx.begin();
    let items_left = tx.signal("0 items left");

    let column = tx.widget(WidgetKind::Column);
    let field = tx.widget(WidgetKind::Entry);
    let add = tx.widget(WidgetKind::Button);
    tx.set(add, Prop::Text, "Add");
    let status = tx.widget(WidgetKind::Label);
    tx.bind(status, Prop::Text, items_left);

    let todos = tx.collection::<Todo>();
    let (todo_list, check) = tx.for_each(&todos, |t| {
        let row = t.widget(WidgetKind::Row);
        let check = t.widget(WidgetKind::Checkbox);
        t.bind_field(check, props::CHECKED, 0, Todo::done());
        let title = t.widget(WidgetKind::Label);
        t.bind_field(title, props::TEXT, 0, Todo::title());
        t.add_child(row, check);
        t.add_child(row, title);
        check
    });

    tx.add_child(column, field);
    tx.add_child(column, add);
    tx.add_child(column, status);
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
                tx.insert(
                    &todos,
                    format!("t{next_key}"),
                    Todo { title: draft.clone(), done: false },
                );
                let status_text = items_left_text(&tx, &todos);
                tx.write(items_left, status_text);
                tx.commit();
            }
            Occurrence::InstanceToggled { node, path, checked } if node == check => {
                // One field's delta: the title never travels.
                let mut tx = ctx.begin();
                tx.update_field(&todos, path[0].clone(), Todo::done(), checked);
                let status_text = items_left_text(&tx, &todos);
                tx.write(items_left, status_text);
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
