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
        // Explicit size: the desktop start must sit ABOVE the
        // breakpoint's threshold so the scene's resize half crosses it
        // both ways deterministically.
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
                // column#1: the control group — its axis answers the
                // creation kind's own and never moves.
                tx.column(|tx| {
                    tx.label(steady); // label#2
                })
                .a11y_id("steady");
                let flip = tx.button("flip").id(); // button#0
                msgs.on_click(flip, Msg::Flip);
                // row#1: the BREAKPOINT subject (D3) — declared data,
                // core-evaluated: below 520 points of window width its
                // axis goes vertical, and crossing back it reverts to
                // the creation kind's own. The handler never touches it.
                let narrow = tx
                    .row(|tx| {
                        let one = tx.signal("one");
                        let two = tx.signal("a wider two");
                        tx.label(one); // label#3
                        tx.label(two); // label#4
                    })
                    .a11y_id("narrow")
                    .id();
                tx.breakpoint_below(520.0, |bp| {
                    bp.axis(narrow, kaya::Axis::Vertical);
                });
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
