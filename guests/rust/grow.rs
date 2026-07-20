//! The grow conformance scene: the one place the layout contract is
//! asserted rather than looked at.
//!
//! The shape is dictated by what can be checked identically on seven
//! backends. Absolute geometry is a *metric*, which DESIGN leaves
//! platform-flavored — a button is not the same height on GTK and
//! AppKit and never will be — so a size assertion could never be shared
//! byte-for-byte the way every other expect is. A *share* is semantics,
//! and a container holding nothing but growers splits weight/Σweight
//! exactly, whatever its children measure and whatever the container
//! itself measures. Hence: every child of every asserted container is a
//! grower.
//!
//! One column and one row, because container targets index by creation
//! order, which legitimately differs per language (statement-shaped
//! construction is parent-first, expression trees children-first). A
//! sole container of each kind is the same widget everywhere; a second
//! would make `column#0`/`row#0` mean different things on different
//! platforms. The observation scene next door keeps deeper nesting and
//! stays unasserted for exactly that reason.
//!
//! The row asserts the HORIZONTAL contract — before it existed, a
//! backend that grew only columns would have passed the whole matrix.

pub(crate) fn app(ctx: kaya::AppCtx) {
    // No event vocabulary: this scene registers no handlers, so the
    // message type is unit.
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let probe = tx.signal("grow probe");
        let one = tx.signal("one");

        let (root, ()) = tx.column(|tx| {
            // Column weights 1, 1, 2 — a 25/25/50 split, none of them
            // equal to an even division of three, so an implementation
            // that splits equally (the boolean expand-flag behaviour
            // most toolkits default to) fails here rather than passing
            // by luck.
            //
            // Every share stays clear of every platform's control
            // minimums, or the scene measures the minimums instead of
            // the contract: the window is 320x160 on the desktops, so
            // the column's ~152pt divide 38/38/76 — the 38pt button
            // track clearing GTK's 34pt minimum button height by the
            // same margin the old two-child 25/75 did.
            let label = tx.label(probe); // label#0
            tx.grow(label, 1.0);
            let quarter = tx.button("quarter");
            tx.grow(quarter, 1.0);
            // The horizontal contract: one row whose children split
            // its WIDTH 1:3. Its own weight (2) makes it a grower like
            // its siblings, keeping the column pure. Width tracks are
            // roomy — 25/75 of ~304pt is 76 and 228 — because height
            // was the scarce axis, not width.
            let (band, ()) = tx.row(|tx| {
                let tick = tx.label(one); // label#1
                tx.grow(tick, 1.0);
                let three = tx.button("three");
                tx.grow(three, 3.0);
            });
            tx.grow(band, 2.0);
        });
        tx.mount(root);
    });

    // No handlers: the controls exist for their sizes, not their
    // events. The loop blocks on recv, keeping the app alive until the
    // harness finishes observing and sends Shutdown.
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
