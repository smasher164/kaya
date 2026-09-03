//! The typeface conformance scene (tools/scenes/typeface.steps): NAME NO
//! SIZE ANYWHERE, and the font is VENDORED so no fallback can pass.

use kaya::Occurrence;

pub(crate) fn app(ctx: kaya::AppCtx) {
    let (status, field, go) = ctx.apply(|tx| {
        // BEFORE THE FIRST MOUNT, per the set-once wall.
        let font = tx.asset("fonts/sora-wght.ttf");
        tx.brand_typeface_with("Sora", &[], Some(&font));
        tx.window(kaya::DEFAULT_WINDOW).title("typeface").size(480.0, 360.0);
        let heading = tx.signal("typeface");
        let status = tx.signal("ready");
        let (root, (field, go)) = tx
            .column(|tx| {
                // A heading OVERRIDES the root font: a root-only lowering shows.
                tx.label(heading).role(kaya::Role::Heading).a11y_id("title"); // label#0
                tx.label(status); // label#1
                // Two DIFFERENT routes: one alone cannot see a half swap.
                let field = tx.entry().id(); // entry#0
                tx.textarea(); // textarea#0
                let go = tx.button("Go").id(); // button#0
                (field, go)
            })
            .into_parts();
        tx.mount(root);
        (status, field, go)
    });

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
