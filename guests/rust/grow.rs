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
//! itself measures. Hence: one column, every child a grower.
//!
//! One column, too, because container targets index by creation order,
//! which legitimately differs per language (statement-shaped
//! construction is parent-first, expression trees children-first). A
//! sole column is the same widget everywhere; a second one would make
//! `column#0` mean different things on different platforms. The
//! observation scene next door keeps the nesting and stays unasserted
//! for exactly that reason.

pub(crate) fn app(ctx: kaya::AppCtx) {
    // No event vocabulary: this scene registers no handlers, so the
    // message type is unit.
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let probe = tx.signal("grow probe");

        let (root, ()) = tx.column(|tx| {
            // Weights 1 and 3 — a 25/75 split, which is not 50/50, so an
            // implementation that divides space equally (the boolean
            // expand-flag behaviour most toolkits default to) fails here
            // rather than passing by luck.
            //
            // Two children and not three, deliberately: the window is
            // 320x160 everywhere, so three shares of a 144pt column put
            // the smallest at 28pt — under GTK's 34pt minimum button
            // height, at which point the toolkit clamps the allocation
            // and the split stops being the one that was asked for. A
            // conformance scene has to keep every share clear of every
            // platform's control minimums, or it measures the minimums
            // instead of the contract. At 25/75 of 152pt the shares are
            // 38 and 114, clear everywhere.
            let label = tx.label(probe); // label#0
            tx.grow(label, 1.0);
            let three = tx.button("three");
            tx.grow(three, 3.0);
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
