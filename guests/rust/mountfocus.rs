//! The mount-transaction focus scene (tools/scenes/mountfocus.steps;
//! docs/traps.md, the materialization class): the focus is set in the
//! transaction that mounts its target, ahead of the mount, so no window
//! holds the target yet when the command is applied.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("mountfocus").size(360.0, 240.0);
        let (root, target) = tx
            .column(|tx| {
                tx.entry().a11y_id("first").a11y_label("First");
                tx.entry().a11y_id("target").a11y_label("Target").id()
            })
            .into_parts();
        tx.focus(target);
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
