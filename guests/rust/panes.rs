//! The panes scene (tools/scenes/panes.steps): nothing here is
//! panes-specific except `panes(3)`, asked for ONCE.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::WindowId;

    #[derive(Clone, Copy)]
    enum Msg {
        OpenContent,
        OpenDetail,
    }

    const CONTENT: WindowId = WindowId(7);
    const DETAIL: WindowId = WindowId(8);

    let msgs = kaya::Messages::<Msg>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("panes").panes(3);
        let root = tx
            .column(|tx| {
                let caption = tx.signal("root pane");
                tx.label(caption).a11y_id("root"); // label#0
                let open = tx.button("open content").id(); // button#0
                msgs.on_click(open, Msg::OpenContent);
            })
            .id();
        tx.mount(root);
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::OpenContent => ctx.apply(|tx| {
                let entry = tx.push_entry(CONTENT).title("content").id();
                let pane = tx
                    .column(|tx| {
                        let caption = tx.signal("content pane");
                        tx.label(caption).a11y_id("content"); // label#1
                        let open = tx.button("open detail").id(); // button#1
                        msgs.on_click(open, Msg::OpenDetail);
                    })
                    .id();
                tx.mount_in(entry, pane);
            }),
            Msg::OpenDetail => ctx.apply(|tx| {
                let entry = tx.push_entry(DETAIL).title("detail").id();
                let pane = tx
                    .column(|tx| {
                        let caption = tx.signal("detail pane");
                        tx.label(caption).a11y_id("detail"); // label#last
                    })
                    .id();
                tx.mount_in(entry, pane);
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
