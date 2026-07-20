//! The layout scene: the native-default observation vehicle, and now
//! also the `grow` conformance scene. It stresses the axes where the
//! seven backends' native defaults diverge: main-axis free-space
//! distribution, cross-axis alignment of unequal-height children, and
//! nesting. The recording (KAYA_RECORD) tells us which native defaults
//! read as good, bad, or ugly before we design the rest of the
//! spacing/align vocabulary.
//!
//! The two label expects (KAYA_SELFTEST=layout) only prove the tree
//! built end to end and clear the zero-expect guard. This scene stays
//! an observation vehicle and asserts no geometry: it has two columns,
//! and a container target indexes by creation order, which legitimately
//! differs per language — so no column here can be named safely (see
//! tools/check-steps.sh). The `grow` contract is asserted in the `grow`
//! scene instead, whose single column is unambiguous.

pub(crate) fn app(ctx: kaya::AppCtx) {
    // No event vocabulary: this scene registers no handlers, so the
    // message type is unit.
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let probe = tx.signal("Layout probe");
        let tail = tx.signal("tail");
        let mixed = tx.signal("mixed");
        let nested = tx.signal("nested");
        let deep = tx.signal("deep");

        let (root, ()) = tx.column(|tx| {
            tx.label(probe); // label#0

            // Main-axis free space: three unequal children with leftover
            // room — how does each backend distribute it (pack leading,
            // center, spread evenly)?
            tx.row(|tx| {
                tx.button("A");
                tx.button("longer");
                tx.label(tail); // label#1
            });

            // Cross-axis alignment: a checkbox, a label, and a slider
            // carry three different intrinsic heights — where do the
            // short ones sit against the tall one (top, center, stretch)?
            tx.row(|tx| {
                tx.checkbox("check");
                tx.label(mixed); // label#2
                // grow=1: the slider fills the leftover row width instead
                // of hugging its intrinsic size — the first explicit
                // layout prop, exercised.
                let s = tx.slider(0.0, 1.0, 0.5);
                tx.grow(s, 1.0);
            });

            // Proportional grow: two growers of unequal weight in one
            // row. The single-grower case above only proves a grower
            // absorbs leftover space, which an ordinal priority also
            // does; only two growers pin down the actual contract, that
            // they divide the leftover 1:3 regardless of their own
            // intrinsic sizes. Sliders because they have an intrinsic
            // width to be overridden.
            tx.row(|tx| {
                let thin = tx.slider(0.0, 1.0, 0.25);
                tx.grow(thin, 1.0);
                let wide = tx.slider(0.0, 1.0, 0.75);
                tx.grow(wide, 3.0);
            });

            // Nesting: a column inside the root column, with a row inside
            // that, down to a leaf label.
            tx.column(|tx| {
                tx.label(nested); // label#3
                tx.row(|tx| {
                    tx.label(deep); // label#4
                    tx.button("x");
                });
            });
        });
        tx.mount(root);
    });

    // No handlers: the controls exist for their intrinsic sizes, not
    // their events. The loop blocks on recv, keeping the app alive until
    // the harness finishes observing and sends Shutdown.
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
