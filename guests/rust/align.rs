//! The align conformance scene: the cross-axis contract as an
//! assertion — see tools/scenes/align.steps for why exactly these two
//! modes carry the gate.
//!
//! The root column centers its children, whose natural widths all
//! differ (label, button, row), so the classification can only read
//! CENTER. The row aligns baselines across a label, a button, and a
//! slider — the two text children's baselines must coincide while
//! their tops do not (the button's caption sits deeper in its
//! chrome), and the slider follows the bottom-edge rule unasserted.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::Align;
    // No event vocabulary: the controls exist for their geometry.
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
/// row's separability. Under baseline alignment its bottom sits on the
/// text baseline (the CSS replaced-element rule), stretching the row's
/// cross axis far past every text child, so start/center/end/baseline
/// place the text at four distinct offsets whatever the platform's
/// control metrics are — kaya's text controls alone all share similar
/// baseline-to-height ratios, and a hug-height row collapses the modes
/// inside the classification tolerance (measured, not guessed: on
/// macOS baseline placement equals center exactly with a label beside
/// an entry).
const TALL_PNG: [u8; 75] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 64, 8, 2, 0, 0, 0, 191, 68, 49, 20, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 8, 8, 138, 2, 34, 134, 81, 106, 104, 82, 0, 67, 50, 126, 1, 49, 1, 65, 124, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
