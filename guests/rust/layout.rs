//! The layout scene: the native-default observation vehicle, stressing
//! the axes where the backends' defaults diverge. The recording
//! (KAYA_RECORD) is what it is for.
//!
//! IT ASSERTS NO GEOMETRY, and must not start: it has TWO columns, and
//! a container target indexes by creation order, which legitimately
//! differs per language, so no column here can be named safely
//! (tools/check-steps.sh). grow.rs asserts the contract instead.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let probe = tx.signal("Layout probe");
        let tail = tx.signal("tail");
        let mixed = tx.signal("mixed");
        let nested = tx.signal("nested");
        let deep = tx.signal("deep");

        let root = tx.column(|tx| {
            tx.label(probe); // label#0

            // Main-axis free space: three unequal children with leftover
            // room — how does each backend distribute it (pack leading,
            // center, spread evenly)?
            tx.row(|tx| {
                tx.button("A");
                tx.button("longer");
                tx.label(tail); // label#1
            });

            // Cross-axis alignment: three different intrinsic heights —
            // where do the short ones sit against the tall one?
            tx.row(|tx| {
                tx.checkbox("check");
                tx.label(mixed); // label#2
                tx.slider(0.0, 1.0, 0.5).grow(1.0);
            });

            // Proportional grow: TWO growers of unequal weight, because
            // a single grower only shows that leftover space is absorbed
            // — which an ordinal priority also does. Sliders because
            // they have an intrinsic width to be overridden.
            tx.row(|tx| {
                tx.slider(0.0, 1.0, 0.25).grow(1.0);
                tx.slider(0.0, 1.0, 0.75).grow(3.0);
            });

            // Nesting: the SECOND column, which is why nothing here can
            // be named ordinally.
            tx.column(|tx| {
                tx.label(nested); // label#3
                tx.row(|tx| {
                    tx.label(deep); // label#4
                    tx.button("x");
                });
            });
        })
        .id();
        tx.mount(root);
    });

    // The keep-alive idiom: blocks until the harness sends Shutdown.
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
