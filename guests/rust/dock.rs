//! The dock scene (tools/scenes/dock.steps; docs/styling-pass-plan.md Y8): a
//! window with a now-playing bar docked under its content, gone while nothing
//! plays because the dock's root then holds no widget.

use kaya::{Fit, Shape};

#[derive(Clone)]
enum Msg {
    Stop,
    Play,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let playing = ctx.apply(|tx| {
        let art = tx.asset("covers/cover-600.jpg").bytes().to_vec();
        let playing = tx.signal(true);
        tx.window(kaya::DEFAULT_WINDOW).title("dock").size(720.0, 480.0).dock(kaya::WindowId(40), |tx| {
            let root = tx
                .column(|tx| {
                    tx.when(playing, |t| {
                        let (bar, _) = t.row(|t| {
                            let image = t.image(art);
                            t.fit(image, Fit::Cover);
                            t.max_width(image, 40.0);
                            t.max_height(image, 40.0);
                            t.shape(image, Shape::Rounded);
                            t.column(|t| {
                                t.label("Blue in Green");
                                t.caption("Miles Davis");
                            });
                            let progress = t.slider(0.0, 1.0, 0.4);
                            t.a11y_id(progress, "progress");
                            let pause = t.button("Pause");
                            t.a11y_id(pause, "pause");
                        });
                        t.a11y_id(bar, "bar");
                    });
                })
                .id();
            (root, ())
        });
        let library = tx.signal("Library");
        let root = tx
            .column(|tx| {
                tx.label(library);
                let stop = tx.button("stop").a11y_id("stop").id();
                msgs.on_click(stop, Msg::Stop);
                let play = tx.button("play").a11y_id("play").id();
                msgs.on_click(play, Msg::Play);
            })
            .id();
        tx.mount(root);
        playing
    });
    while let Some(msg) = msgs.next(&ctx) {
        let on = matches!(msg, Msg::Play);
        ctx.apply(|tx| tx.write(playing, on));
    }
}

fn main() {
    kaya::run(app)
}
