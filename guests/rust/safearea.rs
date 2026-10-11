//! The safe-area scene (tools/scenes/safearea.steps; docs/safe-area-plan.md
//! A3, A8): a picture bleeding past the top edge, a canvas past the bottom, and
//! the widgets between them inside the safe area, at the default inset and at 0.

use kaya::{FillRule, Paint, Viewbox};

const GROUND: Viewbox = Viewbox(300.0, 200.0);

#[derive(Clone)]
enum Msg {
    NoInset,
    Fullscreen,
}

fn ground(d: &mut kaya::Draw, size: Viewbox) {
    d.move_to(0.0, 0.0)
        .line_to(size.0, 0.0)
        .line_to(size.0, size.1)
        .line_to(0.0, size.1)
        .close()
        .fill(Paint::SeriesFill, FillRule::Nonzero);
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let caption = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("safearea").size(420.0, 640.0);
        let caption = tx.signal("inset 16");
        let photo = tx.asset("images/photo.jpg");
        let root = tx
            .column(|tx| {
                tx.image(&photo).max_height(160.0).bleed().a11y_id("picture").a11y_label("Photo");
                tx.label(caption).a11y_id("caption");
                let inset = tx.button("No inset").a11y_id("inset").id();
                msgs.on_click(inset, Msg::NoInset);
                let full = tx.button("Fullscreen").a11y_id("full").id();
                msgs.on_click(full, Msg::Fullscreen);
                tx.canvas(GROUND)
                    .grow(1.0)
                    .bleed()
                    .a11y_id("ground")
                    .a11y_label("Ground")
                    .on_draw(&msgs, |d, size| ground(d, size));
            })
            .id();
        tx.mount(root);
        caption
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::NoInset => ctx.apply(|tx| {
                tx.window(kaya::DEFAULT_WINDOW).inset(0.0);
                tx.write(caption, "inset 0");
            }),
            Msg::Fullscreen => ctx.apply(|tx| {
                tx.window(kaya::DEFAULT_WINDOW).fullscreen(true);
                tx.write(caption, "fullscreen");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
