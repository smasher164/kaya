//! The typeface conformance scene (docs/styling-plan.md Slice 2b): the
//! brand typeface swaps the FAMILY and leaves the platform's ramp
//! alone. The byte-frozen contract is tools/scenes/typeface.steps.
//!
//! NAME NO SIZE ANYWHERE — sizes, weights and metrics stay the
//! platform's, and the role tier carries emphasis. The font is the
//! VENDORED one (guests/assets/fonts/sora-wght.ttf, OFL) because no
//! platform preinstalls "Sora", so no fallback can equal the
//! expectation.
//!
//! THE FONT IS AN ASSET NOW (docs/assets-plan.md, ratified 2026-08-18).
//! This scene used to read `KAYA_FONT_FILE` with a repo-relative default
//! and panic in its own words, and its seven siblings each did the same
//! thing in their own language — eight copies of one resolution rule and
//! eight sentences for one failure. `tx.asset(name)` is the whole thing
//! now: WHERE the file lives is the core's knowledge (a repo checkout, a
//! bundle's Resources, an APK's packaged assets/ with no path at all)
//! and the failure sentence has one author, so a runner that cannot see
//! the repo stages the asset ROOT and names it once rather than
//! per-asset.

use kaya::Occurrence;

pub(crate) fn app(ctx: kaya::AppCtx) {
    let (status, field, go) = ctx.apply(|tx| {
        // BEFORE THE FIRST MOUNT, per the set-once wall. The asset's
        // bytes go from the core's read straight to the platform's font
        // API: nothing here copies them, and this scene never sees them.
        let font = tx.asset("fonts/sora-wght.ttf");
        tx.brand_typeface_with("Sora", &[], Some(&font));
        tx.window(kaya::DEFAULT_WINDOW).title("typeface").size(480.0, 360.0);
        let heading = tx.signal("typeface");
        let status = tx.signal("ready");
        let (root, (field, go)) = tx
            .column(|tx| {
                // The heading's text style OVERRIDES the root font, so a
                // root-only lowering leaves this one in the system face.
                tx.label(heading).role(kaya::Role::Heading).a11y_id("title"); // label#0
                tx.label(status); // label#1
                // A field AND a textarea: they take the swap by
                // DIFFERENT routes (inherited root font vs its own ramp
                // rung), so one alone cannot tell a half-applied
                // lowering from a whole one.
                let field = tx.entry().id(); // entry#0
                tx.textarea(); // textarea#0
                let go = tx.button("Go").id(); // button#0
                (field, go)
            })
            .into_parts();
        tx.mount(root);
        (status, field, go)
    });

    // The app's copy of the field's text: never a widget read.
    let mut draft = String::new();
    loop {
        match ctx.next() {
            Occurrence::TextChanged { id, text } if id == field => draft = text,
            Occurrence::ButtonClicked { id } if id == go => {
                let text = draft.clone();
                ctx.apply(|tx| tx.write(status, format!("clicked {text}")));
            }
            _ => {}
        }
    }
}

fn main() {
    kaya::run(app)
}
