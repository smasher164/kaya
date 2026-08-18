//! The window conformance scene: the primary surface's properties as
//! assertions. The contract is tools/scenes/window.steps.
//!
//! 640x400 is deliberately OFF the 540x330 default, so an ignored size
//! request cannot pass by luck. Desktop-only: phones reject the size by
//! physics, so runners register this scene on the desktops alone.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("window probe")
            .size(640.0, 400.0);
        let probe = tx.signal("window probe");
        let root = tx
            .column(|tx| {
                tx.label(probe); // label#0
            })
            .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
