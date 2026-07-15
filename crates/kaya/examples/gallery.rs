//! The gallery scene: the conformance pass for the widget vocabulary as
//! it grows — today a row container laying a checkbox and the status
//! label side by side. The box owns its checked bit and reports each
//! flip as a Toggled occurrence; the app answers by writing the status
//! signal — the same uncontrolled contract as the entry, with a bool.
//!
//! The backend selftest (KAYA_SELFTEST=gallery) clicks the checkbox and
//! expects the status label to read exactly "urgent: true".

use kaya::{Occurrence, Prop, WidgetKind};

pub(crate) fn app(ctx: kaya::AppCtx) {
    let mut tx = ctx.begin();
    let status = tx.signal("urgent: false");

    let column = tx.widget(WidgetKind::Column);
    let row = tx.widget(WidgetKind::Row);
    let urgent = tx.widget(WidgetKind::Checkbox);
    tx.set(urgent, Prop::Text, "urgent");
    let status_label = tx.widget(WidgetKind::Label);
    tx.bind(status_label, Prop::Text, status);

    tx.add_child(row, urgent);
    tx.add_child(row, status_label);
    tx.add_child(column, row);
    tx.mount(column);
    tx.commit();

    loop {
        match ctx.next() {
            Occurrence::Toggled { id, checked } if id == urgent => {
                let mut tx = ctx.begin();
                tx.write(status, format!("urgent: {checked}"));
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
