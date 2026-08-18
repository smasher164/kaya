//! The grow conformance scene: the one place the layout contract is
//! asserted rather than looked at. What each assertion is for, and why
//! shares rather than sizes, is tools/scenes/grow.steps.
//!
//! Two constraints on any edit here. EVERY CHILD OF EVERY ASSERTED
//! CONTAINER IS A GROWER, or the split is no longer weight/Σweight. And
//! there is exactly ONE column and ONE row: container targets index by
//! creation order, which legitimately differs per language, so a second
//! container of either kind makes `column#0`/`row#0` name different
//! widgets on different lanes (tools/check-steps.sh).

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let probe = tx.signal("grow probe");
        let one = tx.signal("one");

        let root = tx.column(|tx| {
            // THE SHARE ARITHMETIC, which docs/traps.md sends readers
            // here for — recompute it whenever a weight moves, or the
            // scene measures a platform's minimum control size instead
            // of the contract. Weights 1,2,1 divide the column 25/50/25
            // (never an even third, so an expand-flag implementation
            // cannot pass by luck). The desktops' 540x330 window less
            // the root's 16pt inset leaves ~250pt, so the tracks are
            // ~63/126/63: the textarea's declared 96pt floor is the
            // BINDING minimum and its 126pt track clears it by 30, and
            // the row's 63pt track clears GTK's 34pt minimum button
            // height by 29. Width is roomy — 25/75 of ~496pt (508 less
            // the 12-unit gap) is 124 and 372.
            tx.label(probe).grow(1.0); // label#0
            // The widget that must TAKE its track: a textarea's natural
            // size is a fixed box on every backend, and only
            // expect_fills (what it drew) beside expect_shares (what it
            // was given) can tell that apart.
            tx.textarea().grow(2.0); // textarea#0
            // The horizontal contract, and the spacing prop's exercise:
            // a non-default gap, so expect_fills fails on a backend that
            // ignores the write and keeps its 8-unit default.
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

    // The keep-alive idiom: blocks until the harness sends Shutdown.
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
