//! The typeface conformance scene (docs/styling-plan.md Slice 2b): the
//! brand typeface swaps the FAMILY and leaves the platform's ramp
//! alone.
//!
//! One call is the whole surface — a family name, plus the per-platform
//! rows a lane needs — and everything after it is ordinary widgets,
//! which is the claim the scene makes: a typeface is chrome, so the
//! field still takes text and the button still fires. What it does NOT
//! do is name a size anywhere.
//! Sizes, weights and metrics stay the platform's; the role tier is
//! what carries emphasis (`Heading` on the title label below), and that
//! is exactly what makes a family swap safe.
//!
//! WHY A BUNDLED FONT (maintainer, 2026-08-16): the scene requests the
//! VENDORED font's bytes (guests/assets/fonts/sora-wght.ttf, OFL —
//! see the README beside it), so the resolved family is the same one
//! string on every lane, the register-then-resolve blob path is
//! exercised everywhere, and the fallback can never equal the
//! expectation — no platform preinstalls "Sora". The file path rides
//! KAYA_FONT_FILE so a runner whose guest cannot see the repo (a
//! phone) can push the file and point at it; the default is the
//! repo-relative path every desktop lane's cwd satisfies.
//!
//! The byte-frozen contract is tools/scenes/typeface.steps.

use kaya::Occurrence;

pub(crate) fn app(ctx: kaya::AppCtx) {
    let (status, field, go) = ctx.apply(|tx| {
        // BEFORE THE FIRST MOUNT, per the set-once wall: brand is
        // identity, not state, and a backend never sees a typeface it
        // would have to un-apply.
        // THE VENDORED BYTES, then the family they carry: the blob
        // registers with the platform's app-font machinery and the
        // "Sora" request resolves to it — register-then-resolve, the
        // same call a brand book's licensed font would make.
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
                // The heading's text style OVERRIDES the root font, so
                // this label is the one a root-only lowering leaves in
                // the system face. expect_ax resolves it through its
                // authored id, the a11y scene's discipline.
                tx.label(heading).role(kaya::Role::Heading).a11y_id("title"); // label#0
                tx.label(status); // label#1
                // A FIELD AND A TEXTAREA, because they are the two
                // views the observation reads (NSTextField and
                // NSTextView on this platform) and they arrive by
                // DIFFERENT routes: the field inherits the root font,
                // the textarea names its own ramp rung and takes the
                // swap explicitly. A scene with one of them could not
                // tell a half-applied lowering from a whole one.
                let field = tx.entry().id(); // entry#0
                tx.textarea(); // textarea#0
                let go = tx.button("Go").id(); // button#0
                (field, go)
            })
            .into_parts();
        tx.mount(root);
        (status, field, go)
    });

    // The fold: widget-owned state arrives as occurrences, and the
    // app's copy is this variable rather than a widget read.
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
