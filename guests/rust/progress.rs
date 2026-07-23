//! The progress conformance scene: a determinate bar at a quarter
//! and an indeterminate one — both read back from the REAL control
//! (fraction as integer percent; activity mode as "indeterminate").
//! Display-only, like image: no occurrence, no interaction.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("progress");
        let root = tx
            .column(|tx| {
                tx.progress(0.25); // progress#0
                tx.progress_indeterminate(); // progress#1
            })
            .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
