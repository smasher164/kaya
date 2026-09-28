//! The scroll conformance scene (tools/scenes/scroll.steps): the trailing
//! click proves the scrolled-to content is live rather than painted.

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        BottomClicked,
        LastCardClicked,
    }

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("scroll");
        let status = tx.signal("at top");
        let root = tx
            .column(|tx| {
                tx.label(status); // label#0
                // The viewport MUST GROW, or it hugs and nothing overflows.
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
                .grow(1.0)
                .a11y_id("rows");
                // A strip wider than the window, scrolled sideways
                // (docs/hscroll-plan.md), addressed as scroll@strip.
                tx.scroll(|tx| {
                    tx.row(|tx| {
                        for i in 1..=19 {
                            let caption = tx.signal(format!("card {i}"));
                            tx.label(caption);
                        }
                        let last = tx.button("last card").a11y_id("last").id();
                        msgs.on_click(last, Msg::LastCardClicked);
                    });
                })
                .axis(kaya::Axis::Horizontal)
                .a11y_id("strip");
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
            Msg::LastCardClicked => ctx.apply(|tx| {
                tx.write(status, "last card clicked");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
