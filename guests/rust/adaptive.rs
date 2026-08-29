//! The adaptive conformance scene, depth half
//! (docs/adaptive-layout-plan.md §2): the arrangement axis is a
//! PROPERTY on one node with two constructor spellings, flipped here by
//! a HANDLER — D2's user-driven toggle, the breakpoint mechanism's
//! effect without its trigger. The subject stays addressed as `row#0`
//! through both states: identity is the creation kind, presentation is
//! the prop. The byte-frozen contract is tools/scenes/adaptive.steps.
//!
//! The two labels' naturals DIFFER on purpose: the flip then always
//! moves the container's box, so the geometry reader re-records on
//! every crossing (its axis-change hook covers the equal-box corner).

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        Flip,
    }

    let msgs = kaya::Messages::<Msg>::new();
    let dash = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("adaptive");
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
                // column#1: the control group — its axis answers the
                // creation kind's own and never moves.
                tx.column(|tx| {
                    tx.label(steady); // label#2
                })
                .a11y_id("steady");
                let flip = tx.button("flip").id(); // button#0
                msgs.on_click(flip, Msg::Flip);
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
