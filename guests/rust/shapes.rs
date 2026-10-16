//! The shapes scene (tools/scenes/shapes.steps; docs/styling-pass-plan.md
//! Y6): one picture clipped three ways, a wider one in a circle, and a stamped
//! avatar that is round while it loads.

use kaya::{Fit, ImagePhase, Shape};

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Person {
    name: String,
    face: Vec<u8>,
    phase: ImagePhase,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("shapes").size(420.0, 360.0);
        let art = tx.asset("covers/cover-600.jpg").bytes().to_vec();
        let photo = tx.asset("images/photo.jpg").bytes().to_vec();
        let people = tx.collection::<Person>();
        let root = tx
            .column(|tx| {
                tx.row(|tx| {
                    for (id, shape) in [("rect", Shape::Rect), ("rounded", Shape::Rounded), ("circle", Shape::Circle)] {
                        let bytes = tx.signal(art.clone());
                        tx.image(bytes).max_width(48.0).max_height(48.0).fit(Fit::Cover).shape(shape).a11y_id(id);
                    }
                    let wide = tx.signal(photo.clone());
                    tx.image(wide).max_width(48.0).max_height(48.0).shape(Shape::Circle).a11y_id("wide");
                })
                .spacing(16.0);
                for mut row in people.rows(tx) {
                    row.row(|t| {
                        let face = t.image(Person::face());
                        t.fit(face, Fit::Cover);
                        t.max_width(face, 48.0);
                        t.max_height(face, 48.0);
                        t.phase(face, Person::phase());
                        t.shape(face, Shape::Circle);
                        t.a11y_id(face, "avatar");
                        t.label(Person::name());
                    });
                }
            })
            .spacing(16.0)
            .id();
        tx.mount(root);
        tx.insert(&people, "a1", Person { name: "Ada".to_owned(), face: Vec::new(), phase: ImagePhase::Loading });
    });
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
