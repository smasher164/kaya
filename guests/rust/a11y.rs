//! The accessibility conformance scene: the two universal props
//! (`a11y_id`, `a11y_label`) and the verb that reads them back out of
//! the PLATFORM'S OWN accessibility tree rather than kaya's model.
//!
//! What this scene exists to prove is DESIGN's central claim about the
//! wrap-native bet — that native widgets ARE the accessibility tree, so
//! roles and names are correct without kaya synthesizing anything. It
//! therefore asserts two different things on purpose:
//!
//!   * DERIVED names. The button and checkbox carry an identifier but
//!     NO authored label, so what an assistive client speaks is
//!     whatever the control derived from its own caption. That is the
//!     free-by-construction half, and nothing but a real tree read can
//!     show it.
//!   * AUTHORED names. The entry and the image have no caption to
//!     derive from, which is exactly where an app must supply one.
//!
//! The byte-frozen contract is tools/scenes/a11y.steps.

pub(crate) fn app(ctx: kaya::AppCtx) {
    // A static scene: nothing here needs a handler, so the message loop
    // exists purely to block until Shutdown (the keep-alive idiom every
    // handler-less scene uses — docs/deferred.md wants a `park`
    // primitive to replace it).
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let root = tx.column(|tx| {
            // Caption-bearing controls: identified, but deliberately
            // NOT labelled. The platform must speak the caption.
            tx.button("Save").a11y_id("save");
            tx.checkbox("Details").a11y_id("details");
            tx.button("Reset").a11y_id("reset");
            // Caption-less controls: an app MUST name these, and the
            // tree must report the authored name.
            tx.entry().a11y_id("name").a11y_label("Full name");
            // A container is a labelled group to an assistive client —
            // the reason these props are universal rather than
            // kind-scoped.
            // A container carries an IDENTIFIER but deliberately no
            // LABEL. Labelling a container makes it a single
            // accessibility element and HIDES its children — measured
            // 2026-07-25: with a label the row reported
            // `button/Actions` and neither button inside it was
            // reachable at all. That is correct platform behaviour (a
            // named thing is one thing), but it means a label on a
            // container is a decision to hide what is inside it.
            tx.row(|tx| {
                tx.button("Cancel").a11y_id("cancel");
                tx.button("OK").a11y_id("ok");
            })
            .a11y_id("actions")
            .a11y_label("Actions");
        })
        .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
