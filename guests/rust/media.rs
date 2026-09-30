//! The media suite (docs/media-plan.md §7a): one player shown by one video
//! view. `media_formats` and `media_delivery` walk a list of items, each
//! loaded, played to its end and summed up in label#0; `media_session`
//! attaches the player to the app's session and answers `next` itself.

use kaya::{MediaFailure, MediaSource, PlayerState, SessionAction, SessionActionKind};

#[derive(Clone)]
enum Msg {
    Next,
    Toggle,
    State(PlayerState),
    Failed(MediaFailure),
    Position(u64),
    Session(SessionAction),
}

/// One item: what the label names, where it comes from, and the type the
/// capability query is asked about.
struct Item {
    name: String,
    source: MediaSource,
    mime: &'static str,
    codecs: &'static str,
}

fn local(name: &str, mime: &'static str, codecs: &'static str) -> Item {
    Item { name: name.to_owned(), source: MediaSource::asset(format!("media/{name}")), mime, codecs }
}

fn served(base: &str, name: &str, mime: &'static str, codecs: &'static str) -> Item {
    Item { name: name.to_owned(), source: MediaSource::url(format!("{base}/{name}")), mime, codecs }
}

const H264: &str = "avc1.64000b, mp4a.40.2";
const HEVC: &str = "hvc1.1.6.L60.90, mp4a.40.2";
const AV1: &str = "av01.0.00M.08, mp4a.40.2";

fn formats() -> Vec<Item> {
    vec![
        local("h264_aac.mp4", "video/mp4", H264),
        local("hevc_aac.mp4", "video/mp4", HEVC),
        local("hevc_aac.mov", "video/quicktime", HEVC),
        local("vp9_opus.webm", "video/webm", "vp09.00.10.08, opus"),
        local("vp9_aac.mp4", "video/mp4", "vp09.00.10.08, mp4a.40.2"),
        local("av1_aac.mp4", "video/mp4", AV1),
        local("av1_opus.webm", "video/webm", "av01.0.00M.08, opus"),
        local("tone.mp3", "audio/mpeg", ""),
        local("tone.m4a", "audio/mp4", "mp4a.40.2"),
        local("tone.ogg", "audio/ogg", "opus"),
        local("tone_opus.webm", "audio/webm", "opus"),
        local("tone.flac", "audio/flac", ""),
        local("tone.wav", "audio/wav", ""),
    ]
}

/// The local server's items, and the three failures: a 404, a local file
/// that is not there, and a port nothing listens on.
fn delivery() -> Vec<Item> {
    let base = std::env::var("KAYA_MEDIA_URL").unwrap_or_else(|_| {
        panic!(
            "kaya: the media_delivery scene reads KAYA_MEDIA_URL, the local server the lane \
             starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py"
        )
    });
    let refused = base.rsplit_once(':').map_or(base.clone(), |(host, _)| format!("{host}:9"));
    vec![
        served(&base, "h264_aac.mp4", "video/mp4", H264),
        served(&base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""),
        served(&base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""),
        served(&base, "dash.mpd", "application/dash+xml", ""),
        served(&base, "nope.mp4", "video/mp4", H264),
        local("missing.mp4", "video/mp4", H264),
        Item {
            name: "refused.mp4".to_owned(),
            source: MediaSource::url(format!("{refused}/h264_aac.mp4")),
            mime: "video/mp4",
            codecs: H264,
        },
    ]
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let scene = std::env::var("KAYA_SELFTEST").unwrap_or_default();
    let session = scene == "media_session";
    let items = match scene.as_str() {
        "media_delivery" => delivery(),
        _ => formats(),
    };
    let msgs = kaya::Messages::<Msg>::new();
    let (summary, name, player) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("media");
        let summary = tx.signal("idle");
        let name = tx.signal(if session { "next 0" } else { "none" });
        let player = tx.player().muted(true).looping(session).id();
        let root = tx
            .column(|tx| {
                tx.label(summary); // label#0
                tx.label(name); // label#1
                tx.video(player).a11y_id("clip").a11y_label("Clip"); // video#0
                let next = tx.button(if session { "play" } else { "next" }).id(); // button#0
                msgs.on_click(next, if session { Msg::Toggle } else { Msg::Next });
            })
            .id();
        tx.mount(root);
        if session {
            tx.session()
                .player(player)
                .title("kaya media")
                .artist("kaya")
                .handles(&[SessionActionKind::Next])
                .declare();
        }
        (summary, name, player)
    });
    msgs.on_player_state(player, Msg::State);
    msgs.on_failed(player, |why, _| Msg::Failed(why));
    msgs.on_position(player, Msg::Position);
    msgs.on_session(Msg::Session);

    let mut at = 0usize;
    let mut can = false;
    let mut furthest = 0u64;
    let mut nexts = 0u32;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Next => {
                let Some(item) = items.get(at) else { continue };
                at += 1;
                can = kaya::can_play(item.mime, item.codecs);
                furthest = 0;
                ctx.apply(|tx| {
                    tx.player_source(player, &item.source);
                    tx.write(name, item.name.clone());
                    tx.write(summary, "loading");
                });
            }
            Msg::Toggle => ctx.apply(|tx| {
                if ctx.player(player).state == PlayerState::Idle {
                    tx.player_source(player, &MediaSource::asset("media/h264_aac.mp4"));
                }
                tx.play(player);
            }),
            Msg::State(state) if session => ctx.apply(|tx| {
                if matches!(state, PlayerState::Playing | PlayerState::Paused) {
                    tx.write(summary, state.name());
                }
            }),
            Msg::State(PlayerState::Ready) => ctx.apply(|tx| tx.play(player)),
            Msg::State(PlayerState::Ended) => {
                let r = ctx.player(player);
                let played = if furthest >= 1000 {
                    "played past 1s".to_owned()
                } else {
                    format!("played to {furthest}ms")
                };
                ctx.apply(|tx| {
                    tx.write(
                        summary,
                        format!(
                            "ready {:.1}s {}x{}, {played}, ended, can_play {}",
                            r.duration_ms as f64 / 1000.0,
                            r.width,
                            r.height,
                            if can { "yes" } else { "no" }
                        ),
                    );
                });
            }
            Msg::State(_) => {}
            Msg::Failed(why) => ctx.apply(|tx| {
                tx.write(
                    summary,
                    format!("failed {}, can_play {}", why.name(), if can { "yes" } else { "no" }),
                );
            }),
            Msg::Position(ms) => furthest = furthest.max(ms),
            Msg::Session(SessionAction::Next) => {
                nexts += 1;
                ctx.apply(|tx| tx.write(name, format!("next {nexts}")));
            }
            Msg::Session(_) => {}
        }
    }
}

fn main() {
    kaya::run(app)
}
