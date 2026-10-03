//! The capture (docs/capture-plan.md): a camera and a microphone in one
//! object, a preview, and the frames and samples the app's own code is
//! handed on kaya's capture thread. Under the harness the devices are kaya's
//! synthetic ones; the `capture_denied` scene answers the camera's prompt no.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use kaya::{CaptureId, CaptureKind, CaptureReading, CaptureState, Permission, SignalId};

const CAMERA_1: &str = "kaya-synthetic-camera-1";
const CAMERA_2: &str = "kaya-synthetic-camera-2";
const MICROPHONE_1: &str = "kaya-synthetic-microphone-1";
const MICROPHONE_2: &str = "kaya-synthetic-microphone-2";

#[derive(Clone, Copy)]
enum Msg {
    Devices,
    Permission,
    State(CaptureId),
    Ask,
    Start,
    Switch,
    Mute,
    CameraOff,
    Stop,
    Missing,
}

fn state_line(r: &CaptureReading) -> String {
    match r.state {
        CaptureState::Running => format!("running {}x{}@{}", r.width, r.height, r.frame_rate),
        CaptureState::Failed => format!("failed {}", r.failure.map_or("", |f| f.name())),
        CaptureState::Interrupted => format!("interrupted {}", r.interruption.map_or("", |i| i.name())),
        other => other.name().to_owned(),
    }
}

fn evidence(frames: Option<(u32, u32)>, chunk: Option<usize>) -> String {
    let frames = frames.map_or("app frames none".to_owned(), |(w, h)| format!("app frames {w}x{h}"));
    let chunks = chunk.map_or("app chunks none".to_owned(), |n| format!("app chunks of {n}"));
    format!("{frames}, {chunks}")
}

fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<Msg>::new();
    let (labels, call, missing) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("capture").size(520.0, 640.0);
        let labels: Vec<SignalId> = ["devices", "permissions", "idle", &evidence(None, None), "idle"]
            .into_iter()
            .map(|s| tx.signal(s))
            .collect();
        let call = tx.capture().camera(CAMERA_1).microphone(MICROPHONE_1).size(600.0, 400.0).frame_rate(30.0).id();
        let missing = tx.capture().camera("no-such-camera").id();
        let root = tx
            .column(|tx| {
                for label in &labels {
                    tx.label(*label); // label#0..#4
                }
                tx.video_capture(call).a11y_label("Self view"); // video#0
                for (title, msg) in [
                    ("Ask camera", Msg::Ask),
                    ("Start", Msg::Start),
                    ("Switch", Msg::Switch),
                    ("Mute", Msg::Mute),
                    ("Camera off", Msg::CameraOff),
                    ("Stop", Msg::Stop),
                    ("Open missing", Msg::Missing),
                ] {
                    let b = tx.button(title).id(); // button#0..#6
                    msgs.on_click(b, msg);
                }
            })
            .id();
        tx.mount(root);
        tx.watch_capture_devices(true);
        (labels, call, missing)
    });
    msgs.on_capture_devices(|_| Msg::Devices);
    msgs.on_permission(|_, _| Msg::Permission);
    msgs.on_capture_state(call, move |_| Msg::State(call));
    msgs.on_capture_state(missing, move |_| Msg::State(missing));

    // The app's own code on kaya's capture thread: it checks what it was
    // handed and posts what it saw, as a call's encoder would read it.
    let seen: Arc<Mutex<(Option<(u32, u32)>, Option<usize>)>> = Arc::new(Mutex::new((None, None)));
    let poster = ctx.poster();
    let shown = labels[3];
    let frames_seen = seen.clone();
    let frame_poster = poster.clone();
    ctx.on_capture_frame(call, move |f| {
        let whole = f.y.len() >= (f.y_stride * f.height) as usize
            && f.uv.len() >= (f.uv_stride * f.height.div_ceil(2)) as usize
            && f.y_stride >= f.width
            && f.uv_stride >= f.width;
        let size = whole.then_some((f.width, f.height));
        let mut s = frames_seen.lock().unwrap();
        if s.0 != size {
            s.0 = size;
            let line = evidence(s.0, s.1);
            frame_poster.post(move |tx| tx.write(shown, line));
        }
    });
    let posted = Arc::new(AtomicBool::new(false));
    ctx.on_capture_samples(call, move |chunk, _at| {
        if posted.swap(true, Ordering::AcqRel) {
            return;
        }
        let mut s = seen.lock().unwrap();
        s.1 = Some(chunk.len());
        let line = evidence(s.0, s.1);
        poster.post(move |tx| tx.write(shown, line));
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Devices => {
                let line: Vec<String> = ctx
                    .capture_devices()
                    .iter()
                    .map(|d| {
                        let mut s = format!("{} {}", d.kind.name(), d.id);
                        if d.kind == CaptureKind::Camera {
                            s += &format!(" {}", d.facing.name());
                        }
                        if d.preferred {
                            s += " preferred";
                        }
                        s
                    })
                    .collect();
                ctx.apply(|tx| tx.write(labels[0], line.join("; ")));
            }
            Msg::Permission => {
                let p = |k| match ctx.permission(k) {
                    Permission::Prompt => "prompt",
                    Permission::Granted => "granted",
                    Permission::Denied => "denied",
                };
                let line = format!("camera {}, microphone {}", p(CaptureKind::Camera), p(CaptureKind::Microphone));
                ctx.apply(|tx| tx.write(labels[1], line));
            }
            Msg::State(which) => {
                let line = state_line(&ctx.capture(which));
                let label = if which == call { labels[2] } else { labels[4] };
                ctx.apply(|tx| tx.write(label, line));
            }
            Msg::Ask => ctx.apply(|tx| tx.request_permission(CaptureKind::Camera)),
            Msg::Start => ctx.apply(|tx| tx.start_capture(call)),
            Msg::Switch => ctx.apply(|tx| {
                tx.capture_camera(call, Some(CAMERA_2));
                tx.capture_microphone(call, Some(MICROPHONE_2));
                tx.capture_size(call, 1280.0, 720.0);
                tx.capture_frame_rate(call, 15.0);
            }),
            Msg::Mute => ctx.apply(|tx| tx.capture_muted(call, true)),
            Msg::CameraOff => ctx.apply(|tx| tx.capture_camera(call, None)),
            Msg::Stop => ctx.apply(|tx| tx.stop_capture(call)),
            Msg::Missing => ctx.apply(|tx| tx.start_capture(missing)),
        }
    }
}

fn main() {
    kaya::run(app)
}
