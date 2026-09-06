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
                // grid@sheet: three columns at a regular width, one under
                // compact (docs/adaptive-layout-plan.md D6.2).
                tx.grid(3, |tx| {
                    for text in ["c1", "c2", "c3", "c4", "c5", "c6"] {
                        let cell = tx.signal(text);
                        tx.label(cell); // label#5..#10
                    }
                })
                .a11y_id("sheet")
                .columns_when(kaya::SizeClass::Compact, 1);
                // grid@fit: no count, a 240-point floor, the WIDTH decides
                // (docs/layout-knobs-plan.md §3). Buttons, so label ordinals
                // above stay put.
                tx.grid(3, |tx| {
                    tx.button("f1"); // button#1
                    tx.button("f2");
                    tx.button("f3");
                })
                .columns_auto(240.0)
                .a11y_id("fit");
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
