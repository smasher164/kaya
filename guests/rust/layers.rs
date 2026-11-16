//! The layers scene (tools/scenes/layers.steps; docs/layering-plan.md LY13): a
//! cover with a badge and a caption and a button on the fade form; a
//! button with a badge at its trailing end, a
//! button under a veil, an unfilled column spanning it with a panel at its
//! centre, that takes its taps until it is hidden; a cover with the
//! flat overlay panel; and the log of which handler answered each tap.

use kaya::{Place, Tint};

#[derive(Clone)]
enum Msg {
    Share,
    Side,
    Base,
    HideVeil,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (answered, veiled) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("layers").size(480.0, 860.0);
        let cover = tx.asset("covers/cover-600.jpg").bytes().to_vec();
        let small = tx.asset("covers/cover-320.jpg").bytes().to_vec();
        let (badge, caption, busy, flat) =
            (tx.signal("3"), tx.signal("Kind of Blue"), tx.signal("Busy"), tx.signal("Flat panel"));
        let count = tx.signal("5");
        let answered = tx.signal("taps:");
        let veiled = tx.signal(false);
        let root = tx
            .column(|tx| {
                tx.layers(|tx| {
                    tx.image(cover).max_width(320.0).a11y_label("Kind of Blue cover").a11y_id("photo");
                    tx.row(|tx| {
                        tx.label(badge).a11y_id("badge_text");
                    })
                    .filled(Tint::Accent)
                    .place(Place::TopTrailing)
                    .a11y_id("badge");
                    tx.row(|tx| {
                        tx.label(caption).grow(1.0).a11y_id("caption_text");
                        let share = tx.button("Share").a11y_id("share").id();
                        msgs.on_click(share, Msg::Share);
                    })
                    .filled(Tint::OverlayFade)
                    .place(Place::Bottom)
                    .a11y_id("caption");
                })
                .inset(8.0)
                .a11y_id("photostack");
                tx.layers(|tx| {
                    let base = tx.button("Press the base button here").a11y_id("base").id();
                    msgs.on_click(base, Msg::Base);
                    tx.column(|tx| {
                        tx.row(|tx| {
                            tx.label(busy);
                        })
                        .filled(Tint::Overlay);
                    })
                    .align(kaya::Align::Center)
                    .fill(true)
                    .hidden(veiled)
                    .a11y_id("busy");
                })
                .a11y_id("veilstack");
                tx.layers(|tx| {
                    let side = tx.button("Open the inbox").a11y_id("side").id();
                    msgs.on_click(side, Msg::Side);
                    tx.row(|tx| {
                        tx.label(count);
                    })
                    .filled(Tint::Accent)
                    .place(Place::Trailing)
                    .a11y_id("sidebadge");
                })
                .a11y_id("sidestack");
                tx.layers(|tx| {
                    tx.image(small).max_width(200.0).a11y_label("Small cover").a11y_id("smallphoto");
                    tx.row(|tx| {
                        tx.label(flat).a11y_id("flat_text");
                    })
                    .filled(Tint::Overlay)
                    .place(Place::TopLeading)
                    .a11y_id("flat");
                })
                .inset(8.0)
                .a11y_id("flatstack");
                tx.label(answered).a11y_id("answered");
                let hide = tx.button("Hide the veil").a11y_id("hideveil").id();
                msgs.on_click(hide, Msg::HideVeil);
            })
            .spacing(16.0)
            .id();
        tx.mount(root);
        (answered, veiled)
    });
    let mut log = String::from("taps:");
    while let Some(msg) = msgs.next(&ctx) {
        let word = match msg {
            Msg::Share => "share",
            Msg::Side => "side",
            Msg::Base => "base",
            Msg::HideVeil => "hide",
        };
        log.push(' ');
        log.push_str(word);
        ctx.apply(|tx| {
            tx.write(answered, log.clone());
            if matches!(msg, Msg::HideVeil) {
                tx.write(veiled, true);
            }
        });
    }
}

fn main() {
    kaya::run(app)
}
