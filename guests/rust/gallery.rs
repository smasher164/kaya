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

use kaya::Occurrence;

pub(crate) fn app(ctx: kaya::AppCtx) {
    // The construction sugar: constructors carry their props,
    // containers take their children, and the build body reads as the
    // tree. Handlers stay in the occurrence loop, the Rust idiom.
    let mut tx = ctx.begin();
    let status = tx.signal("urgent: false");
    let volume_text = tx.signal("volume: 50%");

    let (root, (urgent, volume)) = tx.column(|tx| {
        let (_, urgent) = tx.row(|tx| {
            let urgent = tx.checkbox("urgent");
            tx.label(status);
            urgent
        });
        let (_, volume) = tx.row(|tx| {
            let volume = tx.slider(0.0, 1.0, 0.5);
            tx.label(volume_text);
            volume
        });
        (urgent, volume)
    });
    tx.mount(root);
    tx.commit();

    loop {
        match ctx.next() {
            Occurrence::Toggled { id, checked } if id == urgent => {
                let mut tx = ctx.begin();
                tx.write(status, format!("urgent: {checked}"));
                tx.commit();
            }
            Occurrence::ValueChanged { id, value } if id == volume => {
                // Integer percent, so every language's formatting
                // agrees on the selftest string.
                let mut tx = ctx.begin();
                tx.write(volume_text, format!("volume: {}%", (value * 100.0).round() as i64));
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
