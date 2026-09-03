//! The split scene, driven by TWO scripts (tools/scenes/split.steps and
//! listdetail.steps): the presentation is asked for ONCE and never again.

/// `split` drives the size class with real resizes; `listdetail` asserts
/// the bare invariant at whatever width its host gives.
pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::WindowId;

    #[derive(Clone, Copy)]
    enum Msg {
        OpenDetail,
        PoppedDetail,
    }

    const DETAIL: WindowId = WindowId(7);

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("split")
            .panes(2);
        let status = tx.signal("list pane");
        let root = tx
            .column(|tx| {
                // Authored ids: an index read passes for an empty arm.
                tx.label(status).a11y_id("list"); // label#0
                let open = tx.button("open detail").id(); // button#0
                msgs.on_click(open, Msg::OpenDetail);
            })
            .id();
        tx.mount(root);
        status
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::OpenDetail => {
                let entry = ctx.apply(|tx| {
                    let entry = tx.push_entry(DETAIL).title("detail").id();
                    let pane = tx
                        .column(|tx| {
                            let caption = tx.signal("detail pane");
                            tx.label(caption).a11y_id("detail");
                        })
                        .id();
                    tx.mount_in(entry, pane);
                    entry
                });
                msgs.on_entry_popped(entry, Msg::PoppedDetail);
            }
            // Retention: the base root took this write while covered.
            Msg::PoppedDetail => ctx.apply(|tx| {
                tx.write(status, "popped detail");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
