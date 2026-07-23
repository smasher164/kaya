//! The window conformance scene: the primary surface's properties as
//! assertions. The title must MATERIALIZE (the runner reads the real
//! title bar, never the model's copy), and the advisory size request
//! must be honored on a desktop — 640x400, deliberately off the
//! 540x330 default so an ignored request cannot pass by luck. A
//! desktop scene: phones reject the size by physics, so runners
//! register it on the desktops only (DESIGN.md, Presentation
//! contexts).

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
