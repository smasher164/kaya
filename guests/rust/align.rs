//! The align conformance scene (tools/scenes/align.steps): the center trio's
//! widths must DIFFER, or the classifier cannot read CENTER.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::Align;
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let probe = tx.signal("align probe");
        let base = tx.signal("base");
        let anchor = tx.signal("anchor");
        let fit = tx.signal("fit");
        let plain = tx.signal("plain probe");

        let root = tx
            .column(|tx| {
                tx.column(|tx| {
                    // column#1: the center trio
                    tx.label(probe); // label#0
                    tx.button("mid");
                    tx.row(|tx| {
                        // row@baseline: the baseline trio
                        tx.label(base); // label#1
                        tx.button("tick");
                        tx.image(&TALL_PNG[..]);
                    })
                    .align(Align::Baseline)
                    .a11y_id("baseline");
                })
                .align(Align::Center)
                .a11y_id("centered");
                tx.row(|tx| {
                    // row#1: the stretch pair's host
                    tx.label(anchor); // label#2
                    tx.column(|tx| {
                        // column#2: the stretch pair
                        tx.label(fit); // label#3
                        tx.button("wide");
                    })
                    .grow(1.0)
                    .align(Align::Stretch)
                    .a11y_id("fitcol");
                });
                tx.row(|tx| {
                    // row@plain: NO align, so the core's centre default is
                    // what the scene reads
                    tx.label(plain).a11y_id("plainlabel"); // label#4
                    tx.image(&TALL_PNG[..]);
                })
                .a11y_id("plain");
                tx.column(|tx| {
                    // column@knobs: NO align; fill opts one child out of its
                    // default and one in
                    tx.textarea().fill(false).a11y_id("optout");
                    tx.button("fills").fill(true).a11y_id("fills");
                    // row@wrapped: six exact-width images flow onto two lines
                    tx.row(|tx| {
                        for _ in 0..6 {
                            tx.image(&WIDE_PNG[..]);
                        }
                    })
                    .wrap(true)
                    .a11y_id("wrapped");
                })
                .a11y_id("knobs");
            })
            .align(Align::Stretch)
            .a11y_id("root")
            .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}

/// A 100x20 PNG: exact pixel widths, so row@wrapped breaks onto two lines
/// in every lane's window (docs/layout-knobs-plan.md §2).
const WIDE_PNG: [u8; 113] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 100, 0, 0, 0, 20, 8, 2, 0, 0, 0, 244, 162, 15, 194, 0, 0, 0, 56, 73, 68, 65, 84, 120, 218, 237, 208, 1, 13, 0, 0, 8, 3, 160, 7, 177, 164, 109, 141, 99, 133, 7, 96, 35, 1, 153, 61, 74, 81, 32, 75, 150, 44, 89, 178, 100, 41, 144, 37, 75, 150, 44, 89, 178, 20, 200, 146, 37, 75, 150, 44, 89, 10, 122, 15, 34, 121, 229, 167, 65, 55, 75, 87, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];

/// A 2x64 PNG whose bottom sits ON the text baseline: without it a
/// hug-height row collapses the four modes into one (docs/traps.md).
const TALL_PNG: [u8; 75] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 64, 8, 2, 0, 0, 0, 191, 68, 49, 20, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 8, 8, 138, 2, 34, 134, 81, 106, 104, 82, 0, 67, 50, 126, 1, 49, 1, 65, 124, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
