//! The scroll conformance scene: the scroll viewport's contract as
//! assertions. Twelve rows in a 330-high window overflow the
//! viewport (expect_overflow — content extent vs viewport extent,
//! both geometry); scroll_end drives the toolkit's REAL scrolling
//! API to the bottom, and expect_at_end reads the content's end edge
//! back from the toolkit. A trailing click proves the scrolled-to
//! content is live, not painted: the last row's button writes the
//! status label at the top.

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
                // The viewport GROWS: it takes the column's leftover
                // track, which is what CONSTRAINS it — an
                // unconstrained viewport hugs its content and nothing
                // overflows (the first thing this scene caught).
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
