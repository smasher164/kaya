//! The typeface conformance scene (docs/styling-plan.md Slice 2b): the
//! brand typeface swaps the FAMILY and leaves the platform's ramp
//! alone. The byte-frozen contract is tools/scenes/typeface.steps.
//!
//! NAME NO SIZE ANYWHERE — sizes, weights and metrics stay the
//! platform's, and the role tier carries emphasis. The font is the
//! VENDORED one (guests/assets/fonts/sora-wght.ttf, OFL) because no
//! platform preinstalls "Sora", so no fallback can equal the
//! expectation; KAYA_FONT_FILE is how a runner that cannot see the repo
//! points at a pushed copy.

use kaya::Occurrence;

pub(crate) fn app(ctx: kaya::AppCtx) {
    let (status, field, go) = ctx.apply(|tx| {
        // BEFORE THE FIRST MOUNT, per the set-once wall.
        let font_path = std::env::var("KAYA_FONT_FILE")
            .unwrap_or_else(|_| "guests/assets/fonts/sora-wght.ttf".into());
        let font = std::fs::read(&font_path).unwrap_or_else(|e| {
            panic!(
                "kaya: the typeface scene needs the vendored font at \
                 {font_path} (set KAYA_FONT_FILE or run from the repo \
                 root): {e}"
            )
        });
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
