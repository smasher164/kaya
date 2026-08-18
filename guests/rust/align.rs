//! The align conformance scene: the cross-axis contract as an
//! assertion. Why exactly these two modes carry the gate is
//! tools/scenes/align.steps.
//!
//! The children's natural widths must all DIFFER, or the classifier
//! cannot read CENTER; and the two text children's baselines must
//! coincide while their tops do not.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::Align;
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let probe = tx.signal("align probe");
        let base = tx.signal("base");

        let root = tx
            .column(|tx| {
                tx.label(probe); // label#0
                tx.button("mid");
                tx.row(|tx| {
                    tx.label(base); // label#1
                    tx.button("tick");
                    tx.image(&TALL_PNG[..]);
                })
                .align(Align::Baseline);
            })
            .align(Align::Center)
            .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}

/// A 2x64 PNG: the tall no-baseline child that CONSTRUCTS the baseline
/// row's separability. Its bottom sits on the text baseline (the CSS
/// replaced-element rule), stretching the cross axis far past every
/// text child so the four modes land at four distinct offsets. Without
/// it a hug-height row collapses them inside the classification
/// tolerance (docs/traps.md, measured on macOS).
const TALL_PNG: [u8; 75] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 64, 8, 2, 0, 0, 0, 191, 68, 49, 20, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 8, 8, 138, 2, 34, 134, 81, 106, 104, 82, 0, 67, 50, 126, 1, 49, 1, 65, 124, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
