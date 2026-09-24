//! A row too wide for its window (docs/flex-shrink-plan.md): the fixed
//! cells shrink no further than their longest word and wrap, the row
//! growing in height, on every lane; on the phones the screen is the
//! window and the same row overflows it.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("flexshrink").size(360.0, 240.0);
        let title = tx.signal("Draft the third chapter");
        let when = tx.signal("Monday, September the seventh, Thesis");
        let root = tx
            .column(|tx| {
                tx.row(|tx| {
                    tx.label(title); // label#0
                    tx.caption(when); // label#1
                    tx.spacer().grow(1.0);
                    tx.button("Details"); // button#0
                })
                .spacing(8.0);
            })
            .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
