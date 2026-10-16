//! The grounds scene (tools/scenes/grounds.steps; docs/styling-pass-plan.md
//! Y2, Y3): an album header fading from the art's own colour into the page, an
//! artist header covered by the picture with the name on the platform's panel,
//! and a column with no ground.

use kaya::Tint;

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("grounds").size(480.0, 560.0);
        let art = tx.asset("covers/cover-600.jpg").bytes().to_vec();
        let colour = kaya::image_dominant(&art).expect("the cover decodes");
        let (title, artist, name, plain) =
            (tx.signal("Kind of Blue"), tx.signal("Miles Davis · 1959"), tx.signal("Miles Davis"), tx.signal("Plain"));
        let root = tx
            .column(|tx| {
                tx.column(|tx| {
                    tx.heading(title).a11y_id("title");
                    tx.caption(artist);
                })
                .inset(24.0)
                .ground_gradient(colour)
                .a11y_id("header");
                tx.column(|tx| {
                    tx.row(|tx| {
                        tx.label(name);
                    })
                    .filled(Tint::Overlay)
                    .a11y_id("scrim");
                })
                .inset(24.0)
                .ground_image(art)
                .a11y_id("hero");
                tx.column(|tx| {
                    tx.label(plain);
                })
                .inset(24.0)
                .a11y_id("plain");
            })
            .spacing(12.0)
            .id();
        tx.mount(root);
    });
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
