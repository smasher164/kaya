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
            tx.row(|tx| {
                // The content-buffer row: a valid 2x2 PNG decodes and
                // reports its size, and deliberately invalid bytes
                // read 0x0 — decode failure is the placeholder class,
                // never a crash, on every backend.
                tx.image(&TEST_PNG[..]);
                tx.image(&b"not an image"[..]);
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

/// A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the first
/// binary asset, embedded as source per the include_str! doctrine —
/// scenes carry their inputs, no runtime file I/O.
const TEST_PNG: [u8; 75] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
