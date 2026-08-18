//! The scroll conformance scene: the viewport's contract as assertions
//! — overflow, a real scroll to the end, and a trailing click proving
//! the scrolled-to content is live rather than painted. The byte-frozen
//! contract is tools/scenes/scroll.steps.

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        BottomClicked,
    }

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("scroll");
        let status = tx.signal("at top");
        let root = tx
            .column(|tx| {
                tx.label(status); // label#0
                // The viewport MUST GROW: an unconstrained one hugs its
                // content and nothing overflows.
                tx.scroll(|tx| {
                    // scroll#0
                    tx.column(|tx| {
                        for i in 1..=29 {
                            let caption = tx.signal(format!("row {i}"));
                            tx.label(caption);
                        }
                        let bottom = tx.button("bottom").id(); // button#0
                        msgs.on_click(bottom, Msg::BottomClicked);
                    });
                })
                .grow(1.0);
            })
            .id();
        tx.mount(root);
        status
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::BottomClicked => ctx.apply(|tx| {
                tx.write(status, "bottom clicked");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
