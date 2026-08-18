//! The progress conformance scene: a determinate bar and an
//! indeterminate one, both read back from the REAL control. The
//! contract is tools/scenes/progress.steps.

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
