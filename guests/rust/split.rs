//! The split conformance scene: adaptive list-detail as assertions
//! (DESIGN.md, Adaptive list-detail). Nothing here is split-specific
//! except `list_detail(true)`, asked for ONCE — the stack is the
//! ordinary navigation stack, and every re-decision after that is the
//! platform's.

/// TWO scripts drive this ONE app — tools/scenes/split.steps drives the
/// size class with real resizes, tools/scenes/listdetail.steps asserts
/// the bare invariant at whatever width its host gives. A scene selects
/// a SCRIPT, never an app, so there is no second binary; the one
/// assertion that could not be shared is the window title, which
/// listdetail deliberately does not make.
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
            .list_detail(true);
        let status = tx.signal("list pane");
        let root = tx
            .column(|tx| {
                // Authored ids so the REAL-TREE read can address these:
                // `expect label#N` reads kaya's own model and passes
                // whether or not anything reached the screen, which is
                // what let a non-rendering split arm look green.
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
            // Retention: the base root took this write while the detail
            // was up, on a regular window where it stayed VISIBLE.
            Msg::PoppedDetail => ctx.apply(|tx| {
                tx.write(status, "popped detail");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
