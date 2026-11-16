//! A self-view over a player's picture (tools/scenes/layersvideo.steps;
//! docs/layering-plan.md LY7, LY13): the overlay video is drawn over the base
//! video on every platform.

use kaya::{Fit, MediaSource, Place, PlayerState};

const CAMERA_2: &str = "kaya-synthetic-camera-2";

#[derive(Clone)]
enum Msg {
    State(PlayerState),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let player = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("layersvideo").size(480.0, 640.0);
        let player = tx.player().muted(true).looping(true).source(&MediaSource::asset("media/h264_aac.mp4")).id();
        let camera = tx.capture().camera(CAMERA_2).id();
        let root = tx
            .column(|tx| {
                tx.layers(|tx| {
                    tx.video(player).a11y_label("Picture").a11y_id("picture");
                    tx.column(|tx| {
                        tx.video_capture(camera).aspect(4, 3).fit(Fit::Cover).a11y_label("You").a11y_id("selfview");
                    })
                    .max_width(320.0 / 3.0)
                    .place(Place::BottomTrailing)
                    .a11y_id("selftile");
                })
                .inset(12.0)
                .grow(1.0)
                .a11y_id("pip");
            })
            .id();
        tx.mount(root);
        tx.start_capture(camera);
        player
    });
    msgs.on_player_state(player, Msg::State);
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::State(PlayerState::Ready) => ctx.apply(|tx| tx.play(player)),
            Msg::State(_) => {}
        }
    }
}

fn main() {
    kaya::run(app)
}
