//! The media suite (docs/media-plan.md §7a): one player shown by one video
//! view. `media_formats` and `media_delivery` walk a list of items, each
//! loaded, played to its end and summed up in label#0; `media_session`
//! attaches the player to the app's session and answers `next` itself;
//! `media_tracks` lists and selects each item's audio and caption tracks
//! and reads the current cue; `media_feed` stamps a video view per row,
//! each showing its row's own player, and reads their visibility (§7b);
//! `media_picked` plays a clip the user picked through the platform's own
//! picker (§2); `media_timeout` loads a source the server sends a byte at a time,
//! hears `failed timeout`, and plays the next item on the same player (§7c);
//! `media_reader` draws a filmstrip and a waveform on canvases from a reader
//! with no player (§8 rulings 3 and 4).

use kaya::{MediaFailure, MediaSource, PathKey, PlayerId, PlayerState, PlayerTracks, SessionAction, SessionActionKind};

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

fn server_base(scene: &str) -> String {
    std::env::var("KAYA_MEDIA_URL").unwrap_or_else(|_| {
        panic!(
            "kaya: the {scene} scene reads KAYA_MEDIA_URL, the local server the lane \
             starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py"
        )
    })
}

/// The local server's items, and the three failures: a 404, a local file
/// that is not there, and a port nothing listens on.
fn delivery() -> Vec<Item> {
    let base = server_base("media_delivery");
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

/// A source the server sends a byte at a time, then the floor file from the
/// same server on the same player: the app's retry after `timeout`.
fn timeout() -> Vec<Item> {
    let base = server_base("media_timeout");
    vec![
        Item {
            name: "trickle.mp4".to_owned(),
            source: MediaSource::url(format!("{base}/trickle/h264_aac.mp4")),
            mime: "video/mp4",
            codecs: H264,
        },
        served(&base, "h264_aac.mp4", "video/mp4", H264),
    ]
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let scene = std::env::var("KAYA_SELFTEST").unwrap_or_default();
    match scene.as_str() {
        "media_tracks" => return tracks_app(ctx),
        "media_feed" => return feed_app(ctx),
        "media_picked" => return picked_app(ctx),
        "media_reader" => return reader_app(ctx),
        _ => {}
    }
    let session = scene == "media_session";
    let items = match scene.as_str() {
        "media_delivery" => delivery(),
        "media_timeout" => timeout(),
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

#[derive(Clone)]
enum PickMsg {
    Open,
    Picked(Option<kaya::PickedFile>),
    State(PlayerState),
    Failed(MediaFailure),
    Position(u64),
}

/// media_picked (docs/media-plan.md §2, the maintainer's ruling of
/// 2026-09-30): the file the picker answers with is handed to the player as
/// the platform names it, played to its end and summed up as media_delivery
/// does.
fn picked_app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<PickMsg>::new();
    let (summary, name, player) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("media picked");
        let summary = tx.signal("idle");
        let name = tx.signal("none");
        let player = tx.player().muted(true).id();
        let root = tx
            .column(|tx| {
                tx.label(summary); // label#0
                tx.label(name); // label#1
                tx.video(player).a11y_id("clip").a11y_label("Clip"); // video#0
                let open = tx.button("open").id(); // button#0
                msgs.on_click(open, PickMsg::Open);
            })
            .id();
        tx.mount(root);
        (summary, name, player)
    });
    msgs.on_player_state(player, PickMsg::State);
    msgs.on_failed(player, |why, _| PickMsg::Failed(why));
    msgs.on_position(player, PickMsg::Position);

    let mut can = false;
    let mut furthest = 0u64;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            PickMsg::Open => ctx.apply(|tx| {
                let dialog = tx.pick_file().show();
                msgs.on_files(dialog, |files| PickMsg::Picked(files.into_iter().next()));
            }),
            PickMsg::Picked(None) => ctx.apply(|tx| tx.write(summary, "cancelled")),
            PickMsg::Picked(Some(file)) => {
                furthest = 0;
                can = kaya::can_play("video/mp4", H264);
                ctx.apply(|tx| {
                    tx.player_source(player, &MediaSource::picked(&file));
                    tx.write(name, file.name.clone());
                    tx.write(summary, "loading");
                });
            }
            PickMsg::State(PlayerState::Ready) => ctx.apply(|tx| tx.play(player)),
            PickMsg::State(PlayerState::Ended) => {
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
            PickMsg::State(_) => {}
            PickMsg::Failed(why) => ctx.apply(|tx| {
                tx.write(summary, format!("failed {}, can_play {}", why.name(), if can { "yes" } else { "no" }));
            }),
            PickMsg::Position(ms) => furthest = furthest.max(ms),
        }
    }
}

fn media_url() -> String {
    std::env::var("KAYA_MEDIA_URL").unwrap_or_else(|_| {
        panic!(
            "kaya: the media scenes that stream read KAYA_MEDIA_URL, the local server the lane \
             starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py"
        )
    })
}

#[derive(Clone)]
enum TrackMsg {
    Next,
    SecondAudio,
    Captions,
    CaptionsOff,
    At(u64),
    PlayFromStart,
    State(PlayerState),
    Failed(MediaFailure),
    Tracks(PlayerTracks),
    Cue(String),
}

/// One track list as a line: `audio en, fr [2]`, the selection counting
/// from 1, `-` for none; `audio none` for an empty list.
fn track_line(what: &str, tags: &[String], selected: Option<usize>) -> String {
    if tags.is_empty() {
        return format!("{what} none");
    }
    let pick = selected.map_or("-".to_owned(), |i| (i + 1).to_string());
    format!("{what} {} [{pick}]", tags.join(", "))
}

/// media_tracks (docs/media-plan.md §3, §7a): each item's audio and caption
/// listing, a second audio track selected, the last caption track selected,
/// and the cue read at 0.5 s and 1.5 s with the player paused there. The
/// sidecar items are the suite's floor file with captions.vtt (the first over
/// h264_frames.mp4), which kaya parses, times and draws: an asset, then fetched
/// from the local server, then a 404 there.
fn tracks_app(ctx: kaya::AppCtx) {
    let base = media_url();
    let floor = |label: &str| Item { name: label.to_owned(), ..local("h264_aac.mp4", "video/mp4", H264) };
    let items: Vec<(Item, Option<MediaSource>)> = vec![
        (local("h264_2audio.mp4", "video/mp4", H264), None),
        (local("vp9_2audio.webm", "video/webm", "vp09.00.10.08, opus"), None),
        (served(&base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""), None),
        (served(&base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""), None),
        (local("h264_tx3g.mp4", "video/mp4", H264), None),
        (
            Item { name: "h264_frames.mp4 + captions.vtt".to_owned(), ..local("h264_frames.mp4", "video/mp4", H264) },
            Some(MediaSource::asset("media/captions.vtt")),
        ),
        (floor("h264_aac.mp4 + http captions.vtt"), Some(MediaSource::url(format!("{base}/captions.vtt")))),
        (floor("h264_aac.mp4 + http nope.vtt"), Some(MediaSource::url(format!("{base}/nope.vtt")))),
    ];
    let msgs = kaya::Messages::<TrackMsg>::new();
    let (summary, name, audio, captions, cue, player) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("media tracks");
        let summary = tx.signal("idle");
        let name = tx.signal("none");
        let audio = tx.signal("audio none");
        let captions = tx.signal("captions none");
        let cue = tx.signal("");
        let player = tx.player().muted(true).id();
        let root = tx
            .column(|tx| {
                tx.label(summary); // label#0
                tx.label(name); // label#1
                tx.label(audio); // label#2
                tx.label(captions); // label#3
                tx.label(cue); // label#4
                tx.video(player).a11y_id("clip").a11y_label("Clip"); // video#0
                for (caption, msg) in [
                    ("next", TrackMsg::Next),                // button#0
                    ("audio 2", TrackMsg::SecondAudio),      // button#1
                    ("captions", TrackMsg::Captions),        // button#2
                    ("at 0.5s", TrackMsg::At(500)),          // button#3
                    ("at 1.5s", TrackMsg::At(1500)),         // button#4
                    ("captions off", TrackMsg::CaptionsOff), // button#5
                    ("play", TrackMsg::PlayFromStart),       // button#6
                ] {
                    let b = tx.button(caption).id();
                    msgs.on_click(b, msg);
                }
            })
            .id();
        tx.mount(root);
        (summary, name, audio, captions, cue, player)
    });
    msgs.on_player_state(player, TrackMsg::State);
    msgs.on_failed(player, |why, _| TrackMsg::Failed(why));
    msgs.on_tracks(player, |t| TrackMsg::Tracks(t.clone()));
    msgs.on_cue(player, |text| TrackMsg::Cue(text.to_owned()));

    let mut at = 0usize;
    let mut can = false;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            TrackMsg::Next => {
                let Some((item, sidecar)) = items.get(at) else { continue };
                at += 1;
                can = kaya::can_play(item.mime, item.codecs);
                ctx.apply(|tx| {
                    if let Some(sidecar) = sidecar {
                        tx.player_captions(player, sidecar, "en");
                    } else {
                        tx.clear_captions(player);
                    }
                    tx.player_source(player, &item.source);
                    tx.write(name, item.name.clone());
                    tx.write(summary, "loading");
                    tx.write(cue, "");
                });
            }
            TrackMsg::SecondAudio => ctx.apply(|tx| tx.select_audio(player, 1)),
            TrackMsg::Captions => {
                let listed = ctx.tracks(player).captions.len();
                ctx.apply(|tx| {
                    if listed == 0 {
                        tx.write(cue, "captions none");
                    } else {
                        tx.select_captions(player, Some(listed - 1));
                    }
                });
            }
            TrackMsg::CaptionsOff => ctx.apply(|tx| tx.select_captions(player, None)),
            TrackMsg::At(ms) => ctx.apply(|tx| {
                tx.pause(player);
                tx.seek(player, ms);
            }),
            TrackMsg::PlayFromStart => ctx.apply(|tx| {
                tx.seek(player, 0);
                tx.play(player);
            }),
            TrackMsg::State(PlayerState::Ready) => ctx.apply(|tx| {
                tx.write(summary, format!("ready, can_play {}", if can { "yes" } else { "no" }));
            }),
            TrackMsg::State(_) => {}
            TrackMsg::Failed(why) => ctx.apply(|tx| {
                let line = format!("failed {}, can_play {}", why.name(), if can { "yes" } else { "no" });
                tx.write(summary, line.clone());
                tx.write(audio, line);
            }),
            TrackMsg::Tracks(t) => ctx.apply(|tx| {
                tx.write(audio, track_line("audio", &t.audio, t.audio_selected));
                tx.write(captions, track_line("captions", &t.captions, t.caption_selected));
            }),
            TrackMsg::Cue(text) => ctx.apply(|tx| tx.write(cue, text)),
        }
    }
}

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Clip {
    name: String,
    player: PlayerId,
}

#[derive(Clone)]
enum FeedMsg {
    Shown(kaya::Path, f64),
}

const FEED_ROWS: usize = 10;

/// media_feed (docs/media-plan.md §7b): a scroll of rows, each a video view
/// showing its row's own player, paused on its first frame; the first and
/// last rows' visibility in label#0 and label#1, as the feed app reads it to
/// keep players only for the rows on screen.
fn feed_app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<FeedMsg>::new();
    let (first, last) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("media feed").size(420.0, 480.0);
        let first = tx.signal("r0 out");
        let last = tx.signal(format!("r{} out", FEED_ROWS - 1));
        let clips = tx.collection::<Clip>();
        let mut video_node = None;
        let root = tx
            .column(|tx| {
                tx.label(first); // label#0
                tx.label(last); // label#1
                tx.scroll(|tx| {
                    tx.column(|tx| {
                        for mut row in clips.rows(tx) {
                            row.label(Clip::name());
                            video_node = Some(row.video(Clip::player()));
                        }
                    });
                })
                .grow(1.0);
            })
            .id();
        tx.mount(root);
        for i in 0..FEED_ROWS {
            let player = tx.player().muted(true).source(&MediaSource::asset("media/h264_aac.mp4")).id();
            tx.insert(&clips, i as i64, Clip { name: format!("r{i}"), player });
        }
        msgs.on_visibility_node(video_node.expect("the feed's template declared a video view"), FeedMsg::Shown);
        (first, last)
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            FeedMsg::Shown(path, shown) => {
                let row = path.key::<i64>(0) as usize;
                let word = if shown >= 0.999 {
                    "whole"
                } else if shown > 0.0 {
                    "in"
                } else {
                    "out"
                };
                ctx.apply(|tx| {
                    if row == 0 {
                        tx.write(first, format!("r0 {word}"));
                    }
                    if row == FEED_ROWS - 1 {
                        tx.write(last, format!("r{row} {word}"));
                    }
                });
            }
        }
    }
}

#[derive(Clone)]
enum ReadMsg {
    Exact(kaya::Frame),
    Keyframe(kaya::Frame),
    Done(&'static str, kaya::ReadOutcome),
    Peaks(kaya::Peaks),
    Start,
    Cancel,
}

/// The answered times as the labels spell them: each time asked, then the
/// time of the picture the platform returned, in ms.
fn frame_line(what: &str, frames: &[kaya::Frame], outcome: &kaya::ReadOutcome) -> String {
    let mut sorted = frames.to_vec();
    sorted.sort_by_key(|f| f.index);
    let times: Vec<String> = sorted.iter().map(|f| format!("{}@{}", f.requested_ms, f.actual_ms)).collect();
    format!("{what} {} {}", times.join(" "), outcome_word(outcome))
}

fn outcome_word(outcome: &kaya::ReadOutcome) -> String {
    match outcome {
        kaya::ReadOutcome::Completed => "completed".to_owned(),
        kaya::ReadOutcome::Cancelled => "cancelled".to_owned(),
        kaya::ReadOutcome::Failed(why, _) => format!("failed {}", why.name()),
    }
}

const STRIP: kaya::Viewbox = kaya::Viewbox(320.0, 45.0);
const WAVE: kaya::Viewbox = kaya::Viewbox(200.0, 60.0);
/// h264_frames.mp4's grey bands: frame 12 (0x505050) and frame 37
/// (0xA0A0A0) at 25 fps, its one keyframe at 0 (tools/gen-media.py).
const BANDS: [u64; 2] = [480, 1480];

/// media_reader (docs/media-plan.md §8 rulings 3 and 4): a reader with no
/// player draws a filmstrip of h264_frames.mp4's exact and keyframe
/// pictures and a waveform of tone.wav's peaks beside two loaded images; a
/// read the server never finishes is cancelled and another is closed under
/// its reader; a file that is not media and a missing file fail.
fn reader_app(ctx: kaya::AppCtx) {
    use kaya::{FillRule, FrameAccuracy, Paint, ReadOutcome};
    let base = media_url();
    let msgs = kaya::Messages::<ReadMsg>::new();
    let (labels, strip, wave, clip, logo, photo) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("media reader").size(560.0, 560.0);
        let labels: Vec<_> =
            ["exact", "keyframe", "peaks", "cancel", "failures", "no track"].into_iter().map(|s| tx.signal(s)).collect();
        let mut canvases = None;
        let root = tx
            .column(|tx| {
                for label in &labels {
                    tx.label(*label); // label#0..#5
                }
                let strip = tx.canvas(STRIP).a11y_id("strip").a11y_label("Filmstrip").id();
                let wave = tx.canvas(WAVE).a11y_id("wave").a11y_label("Waveform").id();
                let start = tx.button("start").id(); // button#0
                msgs.on_click(start, ReadMsg::Start);
                let cancel = tx.button("cancel").id(); // button#1
                msgs.on_click(cancel, ReadMsg::Cancel);
                canvases = Some((strip, wave));
            })
            .id();
        tx.mount(root);
        let (strip, wave) = canvases.expect("the column declared its canvases");

        let clip = tx.reader(&MediaSource::asset("media/h264_frames.mp4"));
        let exact = tx.read_frames(clip, &BANDS, (80, 45), FrameAccuracy::Exact);
        msgs.on_frame(exact, ReadMsg::Exact);
        msgs.on_read_done(exact, |o| ReadMsg::Done("exact", o));

        let tone = tx.reader(&MediaSource::asset("media/tone.wav"));
        let peaks = tx.read_peaks(tone, 4800);
        msgs.on_peaks(peaks, |p| ReadMsg::Peaks(p.clone()));
        msgs.on_read_done(peaks, |o| ReadMsg::Done("peaks", o));

        for (what, source) in [("OFL.txt", "fonts/OFL.txt"), ("missing.mp4", "media/missing.mp4")] {
            let reader = tx.reader(&MediaSource::asset(source));
            let read = tx.read_frames(reader, &[0], (80, 45), FrameAccuracy::Exact);
            msgs.on_read_done(read, move |o| ReadMsg::Done(what, o));
        }

        let silent = tx.reader(&MediaSource::asset("media/h264_noaudio.mp4"));
        let read = tx.read_peaks(silent, 4800);
        msgs.on_read_done(read, |o| ReadMsg::Done("noaudio peaks", o));
        let song = tx.reader(&MediaSource::asset("media/tone.mp3"));
        let read = tx.read_frames(song, &[0], (80, 45), FrameAccuracy::Exact);
        msgs.on_read_done(read, |o| ReadMsg::Done("mp3 frames", o));

        let logo = tx.load_image(&MediaSource::asset("images/a11y-logo.png"));
        let photo = tx.load_image(&MediaSource::asset("images/photo.jpg"));
        (labels, strip, wave, clip, logo, photo)
    });

    let mut exact = Vec::new();
    let mut keyframe = Vec::new();
    let mut failures: Vec<String> = Vec::new();
    let mut missing: Vec<String> = Vec::new();
    let mut cancels: Vec<String> = Vec::new();
    let mut trickling = None;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            ReadMsg::Exact(f) => exact.push(f),
            ReadMsg::Keyframe(f) => keyframe.push(f),
            ReadMsg::Done("exact", outcome) => ctx.apply(|tx| {
                tx.write(labels[0], frame_line("exact", &exact, &outcome));
                let read = tx.read_frames(clip, &BANDS, (80, 45), FrameAccuracy::Keyframe);
                msgs.on_frame(read, ReadMsg::Keyframe);
                msgs.on_read_done(read, |o| ReadMsg::Done("keyframe", o));
            }),
            ReadMsg::Done("keyframe", outcome) => ctx.apply(|tx| {
                tx.write(labels[1], frame_line("keyframe", &keyframe, &outcome));
                exact.sort_by_key(|f: &kaya::Frame| f.index);
                keyframe.sort_by_key(|f: &kaya::Frame| f.index);
                let tiles: Vec<kaya::ImageId> = exact.iter().chain(&keyframe).map(|f| f.image).collect();
                tx.draw(strip, |d| {
                    for (i, image) in tiles.iter().enumerate() {
                        d.image(*image, 80.0 * i as f64, 0.0, 80.0, 45.0);
                    }
                });
            }),
            ReadMsg::Peaks(p) => ctx.apply(|tx| {
                let lows = (0..p.len()).map(|i| p.pair(i, 0).0).min().unwrap_or(0);
                let highs = (0..p.len()).map(|i| p.pair(i, 0).1).max().unwrap_or(0);
                tx.write(
                    labels[2],
                    format!(
                        "peaks {} Hz, {} ch, {} pairs of {}, {lows}..{highs}",
                        p.sample_rate,
                        p.channels,
                        p.len(),
                        p.samples_per_pair
                    ),
                );
                tx.draw(wave, |d| {
                    let y = |v: i16| 30.0 - f64::from(v) * 25.0 / 8192.0;
                    for i in 0..p.len() {
                        let (lo, hi) = p.pair(i, 0);
                        let x = 8.0 + 7.0 * i as f64;
                        d.move_to(x, y(hi)).line_to(x + 5.0, y(hi)).line_to(x + 5.0, y(lo)).line_to(x, y(lo)).close();
                        d.fill(Paint::Series, FillRule::Nonzero);
                    }
                    d.image(logo, 150.0, 4.0, 20.0, 20.0);
                    d.image(photo, 150.0, 30.0, 40.0, 30.0);
                });
            }),
            ReadMsg::Done("peaks", ReadOutcome::Completed) => {}
            ReadMsg::Done("peaks", outcome) => {
                ctx.apply(|tx| tx.write(labels[2], format!("peaks {}", outcome_word(&outcome))))
            }
            ReadMsg::Done(what @ ("OFL.txt" | "missing.mp4"), outcome) => {
                failures.push(format!("{what} {}", outcome_word(&outcome)));
                failures.sort();
                ctx.apply(|tx| tx.write(labels[4], failures.join("; ")));
            }
            ReadMsg::Done(what @ ("noaudio peaks" | "mp3 frames"), outcome) => {
                missing.push(format!("{what} {}", outcome_word(&outcome)));
                missing.sort();
                ctx.apply(|tx| tx.write(labels[5], missing.join("; ")));
            }
            ReadMsg::Start => ctx.apply(|tx| {
                let trickle = tx.reader(&MediaSource::url(format!("{base}/trickle/h264_frames.mp4")));
                let read = tx.read_frames(trickle, &[0], (80, 45), FrameAccuracy::Exact);
                msgs.on_read_done(read, |o| ReadMsg::Done("trickle", o));
                let closing = tx.reader(&MediaSource::url(format!("{base}/trickle/h264_aac.mp4")));
                let closing_read = tx.read_frames(closing, &[0], (80, 45), FrameAccuracy::Exact);
                msgs.on_read_done(closing_read, |o| ReadMsg::Done("closed", o));
                trickling = Some((trickle, read, closing));
                tx.write(labels[3], "reading");
            }),
            ReadMsg::Cancel => ctx.apply(|tx| {
                if let Some((trickle, read, closing)) = trickling.take() {
                    tx.cancel_read(trickle, read);
                    tx.close_reader(closing);
                }
            }),
            ReadMsg::Done(what, outcome) => {
                cancels.push(format!("{what} {}", outcome_word(&outcome)));
                cancels.sort();
                ctx.apply(|tx| tx.write(labels[3], cancels.join("; ")));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
