//! The grow conformance scene (tools/scenes/grow.steps): EVERY CHILD IS A
//! GROWER, and there is exactly ONE column and ONE row.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let probe = tx.signal("grow probe");
        let one = tx.signal("one");

        let root = tx.column(|tx| {
            // THE SHARE ARITHMETIC (docs/traps.md): recompute it whenever a
            // weight moves, or the scene measures a platform minimum.
            tx.label(probe).grow(1.0); // label#0
            // Only expect_fills beside expect_shares tells "took its track"
            // from "was given one".
            tx.textarea().grow(2.0); // textarea#0
            // A non-default gap: a backend that ignores the write fails.
            tx.row(|tx| {
                tx.label(one).grow(1.0); // label#1
                tx.button("three").grow(3.0);
            })
            .grow(1.0)
            .spacing(12.0);
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
