//! The gallery scene: the conformance pass for the widget vocabulary as
//! it grows — a row with a checkbox and its status label, and a row
//! with a slider and its volume label. Both controls own their state
//! (the box its checked bit, the slider its position) and report each
//! change as an occurrence; the app answers by writing the paired
//! signal — the entry's uncontrolled contract, with a bool and an f64.
//!
//! The backend selftest (KAYA_SELFTEST=gallery) clicks the checkbox,
//! sets the slider to 0.75 through the control's own event path, and
//! expects the labels to read exactly "urgent: true" and "volume: 75%".

/// The event vocabulary: the two controls' meanings.
#[derive(Clone)]
enum Msg {
    Urgent(bool),
    Volume(f64),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    // The construction sugar: constructors carry their props,
    // containers parent their bodies, and the Msg registrations sit
    // beside their widgets; the fold matches on the app's own
    // vocabulary.
    let msgs = kaya::Messages::new();
    let (status, volume_text) = ctx.apply(|tx| {
        let status = tx.signal("urgent: false");
        let volume_text = tx.signal("volume: 50%");

        let (root, ()) = tx.column(|tx| {
            tx.row(|tx| {
                let urgent = tx.checkbox("urgent");
                msgs.on_toggle(urgent, Msg::Urgent);
                tx.label(status);
            });
            tx.row(|tx| {
                let volume = tx.slider(0.0, 1.0, 0.5);
                msgs.on_value(volume, Msg::Volume);
                tx.label(volume_text);
            });
        });
        tx.mount(root);
        (status, volume_text)
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Urgent(checked) => {
                ctx.apply(|tx| {
                    tx.write(status, format!("urgent: {checked}"));
                });
            }
            Msg::Volume(value) => {
                // Integer percent, so every language's formatting
                // agrees on the selftest string.
                ctx.apply(|tx| {
                    tx.write(
                        volume_text,
                        format!("volume: {}%", (value * 100.0).round() as i64),
                    );
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
