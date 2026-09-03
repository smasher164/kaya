//! The native-default observation vehicle (KAYA_RECORD is what it is for).
//! IT ASSERTS NO GEOMETRY: it has TWO columns, and targets are ordinal.

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

            // Main-axis free space: who gets the leftover room?
            tx.row(|tx| {
                tx.button("A");
                tx.button("longer");
                tx.label(tail); // label#1
            });

            // Cross-axis alignment: where do the short ones sit?
            tx.row(|tx| {
                tx.checkbox("check");
                tx.label(mixed); // label#2
                tx.slider(0.0, 1.0, 0.5).grow(1.0);
            });

            // TWO growers of unequal weight: one alone only shows that
            // leftover space is absorbed.
            tx.row(|tx| {
                tx.slider(0.0, 1.0, 0.25).grow(1.0);
                tx.slider(0.0, 1.0, 0.75).grow(3.0);
            });

            // The SECOND column: why nothing here can be named ordinally.
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

    // Blocks until the harness sends Shutdown.
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
