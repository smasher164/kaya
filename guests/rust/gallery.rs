//! The gallery scene: the uncontrolled contract with a bool and an f64.
//! The byte-frozen contract is tools/scenes/gallery.steps.
//!
//! The quarter button is the echo doctrine's half: a PROGRAMMATIC write
//! moves the control but must NOT emit, so the volume label keeps the
//! user's value.

#[derive(Clone)]
enum Msg {
    Urgent(bool),
    Volume(f64),
    Quarter,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, volume_text, pos) = ctx.apply(|tx| {
        let status = tx.signal("urgent: false");
        let volume_text = tx.signal("volume: 50%");
        let pos = tx.signal(0.5);

        let root = tx.column(|tx| {
            tx.row(|tx| {
                let urgent = tx.checkbox("urgent").id();
                msgs.on_toggle(urgent, Msg::Urgent);
                tx.label(status);
            });
            tx.row(|tx| {
                let volume = tx.slider_bound(0.0, 1.0, pos).id();
                msgs.on_value(volume, Msg::Volume);
                tx.label(volume_text);
                let quarter = tx.button("quarter").id();
                msgs.on_click(quarter, Msg::Quarter);
            });
            tx.row(|tx| {
                // Deliberately invalid bytes read 0x0: decode failure is
                // the placeholder class, never a crash, on every backend.
                tx.image(&TEST_PNG[..]);
                tx.image(&b"not an image"[..]);
            });
        })
        .id();
        tx.mount(root);
        (status, volume_text, pos)
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
            Msg::Quarter => {
                // Must NOT come back as a Volume occurrence.
                ctx.apply(|tx| {
                    tx.write(pos, 0.25);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}

/// A 2x2 RGB PNG (red/green over blue/white), 75 bytes. Embedded as
/// source: scenes carry their inputs, no runtime file I/O.
const TEST_PNG: [u8; 75] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
