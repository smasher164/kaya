//! The adaptive conformance scene (tools/scenes/adaptive.steps). The two
//! labels' naturals DIFFER, so every flip moves the container's box.

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        Flip,
    }

    let msgs = kaya::Messages::<Msg>::new();
    let dash = ctx.apply(|tx| {
        // Must start ABOVE the breakpoint, so the resize crosses it.
        tx.window(kaya::DEFAULT_WINDOW).title("adaptive").size(900.0, 600.0);
        let alpha = tx.signal("alpha");
        let longer = tx.signal("a longer label");
        let steady = tx.signal("steady");
        let mut dash_id = None;
        let root = tx
            .column(|tx| {
                let dash = tx
                    .row(|tx| {
                        // row#0: the flip subject.
                        tx.label(alpha); // label#0
                        tx.label(longer); // label#1
                    })
                    .a11y_id("dash")
                    .id();
                dash_id = Some(dash);
                // column#1: the control group, whose axis never moves.
                tx.column(|tx| {
                    tx.label(steady); // label#2
                })
                .a11y_id("steady");
                let flip = tx.button("flip").id(); // button#0
                msgs.on_click(flip, Msg::Flip);
                // row#1: the BREAKPOINT subject; the handler never touches it.
                tx.row(|tx| {
                    let one = tx.signal("one");
                    let two = tx.signal("a wider two");
                    tx.label(one); // label#3
                    tx.label(two); // label#4
                })
                .a11y_id("narrow")
                .stack_when(kaya::SizeClass::Compact);
            })
            .id();
        tx.mount(root);
        dash_id.unwrap()
    });

    let mut vertical = false;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Flip => {
                vertical = !vertical;
                ctx.apply(|tx| {
                    tx.axis(
                        dash,
                        if vertical {
                            kaya::Axis::Vertical
                        } else {
                            kaya::Axis::Horizontal
                        },
                    )
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
