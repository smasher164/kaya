//! Milestone 0's scene through milestone 1's surface: the scene arrives
//! as one transaction, and the label's text is a signal binding — a
//! click makes the round trip from the occurrence ring to the app thread
//! and back as a signal write, resolved core-side into the label's
//! property set.
//!
//! Run with KAYA_SELFTEST=1 to click programmatically and verify the label.

use kaya::{Occurrence, Prop, WidgetKind};

pub(crate) fn app(ctx: kaya::AppCtx) {
    let mut tx = ctx.begin();
    let text = tx.signal("Clicked 0 times");
    let column = tx.widget(WidgetKind::Column);
    let button = tx.widget(WidgetKind::Button);
    tx.set(button, Prop::Text, "Click me");
    let label = tx.widget(WidgetKind::Label);
    tx.bind(label, Prop::Text, text);
    tx.add_child(column, button);
    tx.add_child(column, label);
    tx.mount(column);
    tx.commit();

    let mut count = 0u64;
    loop {
        match ctx.next() {
            Occurrence::ButtonClicked { .. } => {
                count += 1;
                let noun = if count == 1 { "time" } else { "times" };
                let mut tx = ctx.begin();
                tx.write(text, format!("Clicked {count} {noun}"));
                tx.commit();
            }
            Occurrence::Shutdown => break,
        }
    }
}

fn main() {
    kaya::run(app);
}
