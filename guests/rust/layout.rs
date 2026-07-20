//! The layout scene: the native-default observation vehicle. No layout
//! props exist yet — row/column carry only their axis — so this scene
//! exists to be *looked at* under KAYA_RECORD, not asserted on. It
//! stresses the axes where the seven backends' native defaults diverge:
//! main-axis free-space distribution, cross-axis alignment of
//! unequal-height children, and nesting. The recording tells us which
//! native defaults read as good, bad, or ugly before we design any
//! spacing/grow/align vocabulary.
//!
//! The two label expects (KAYA_SELFTEST=layout) only prove the tree
//! built end to end and clear the zero-expect guard — layout itself is
//! not yet harness-observable (there is no geometry Stage method; that
//! decision is deferred until after this observation).

pub(crate) fn app(ctx: kaya::AppCtx) {
    // No event vocabulary: this scene registers no handlers, so the
    // message type is unit.
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let probe = tx.signal("Layout probe");
        let tail = tx.signal("tail");
        let mixed = tx.signal("mixed");
        let nested = tx.signal("nested");
        let deep = tx.signal("deep");

        let (root, ()) = tx.column(|tx| {
            tx.label(probe); // label#0

            // Main-axis free space: three unequal children with leftover
            // room — how does each backend distribute it (pack leading,
            // center, spread evenly)?
            tx.row(|tx| {
                tx.button("A");
                tx.button("longer");
                tx.label(tail); // label#1
            });

            // Cross-axis alignment: a checkbox, a label, and a slider
            // carry three different intrinsic heights — where do the
            // short ones sit against the tall one (top, center, stretch)?
            tx.row(|tx| {
                tx.checkbox("check");
                tx.label(mixed); // label#2
                tx.slider(0.0, 1.0, 0.5);
            });

            // Nesting: a column inside the root column, with a row inside
            // that, down to a leaf label.
            tx.column(|tx| {
                tx.label(nested); // label#3
                tx.row(|tx| {
                    tx.label(deep); // label#4
                    tx.button("x");
                });
            });
        });
        tx.mount(root);
    });

    // No handlers: the controls exist for their intrinsic sizes, not
    // their events. The loop blocks on recv, keeping the app alive until
    // the harness finishes observing and sends Shutdown.
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
