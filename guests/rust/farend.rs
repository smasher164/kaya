//! The far end of a call (docs/capture-plan.md §5): a surface showing the
//! NV12 frames the app submits from its own thread, and a voice output
//! playing the samples it writes there on the platform's voice path. The
//! peer is a thread of the app's, standing in for a transport.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use kaya::{CaptureFrame, SurfaceFrames, VoiceId, VoiceRoute, VoiceWriter};

#[derive(Clone, Copy)]
enum Msg {
    Connect,
    Change,
    Quiet,
    HangUp,
    Route(VoiceRoute),
}

/// What the peer sends: a flat colour at a size, and a tone (0: silence).
#[derive(Clone, Copy)]
struct Peer {
    rgb: u32,
    size: (u32, u32),
    hz: f64,
    on: bool,
}

/// A flat colour as NV12, video-range BT.601.
fn nv12(width: u32, height: u32, rgb: u32) -> (Vec<u8>, Vec<u8>) {
    let (r, g, b) = (f64::from((rgb >> 16) as u8), f64::from((rgb >> 8) as u8), f64::from(rgb as u8));
    let y = (16.0 + 0.257 * r + 0.504 * g + 0.098 * b).round() as u8;
    let u = (128.0 - 0.148 * r - 0.291 * g + 0.439 * b).round() as u8;
    let v = (128.0 + 0.439 * r - 0.368 * g - 0.071 * b).round() as u8;
    (vec![y; (width * height) as usize], [u, v].repeat((width * height / 4) as usize))
}

/// The peer's thread: a frame every 1/15 s and 10 ms of samples every 10 ms,
/// paced by the clock, until hung up.
fn run_peer(peer: Arc<Mutex<Peer>>, frames: SurfaceFrames, voice: VoiceWriter) {
    let start = Instant::now();
    let (mut sent_frames, mut sent_samples) = (0u64, 0u64);
    let mut picture: Option<(u32, (u32, u32), Vec<u8>, Vec<u8>)> = None;
    let mut phase = 0.0f64;
    loop {
        let now = *peer.lock().unwrap();
        if !now.on {
            return;
        }
        let elapsed = start.elapsed();
        while sent_frames * 1_000_000 / 15 <= elapsed.as_micros() as u64 {
            if picture.as_ref().is_none_or(|p| p.0 != now.rgb || p.1 != now.size) {
                let (y, uv) = nv12(now.size.0, now.size.1, now.rgb);
                picture = Some((now.rgb, now.size, y, uv));
            }
            let (_, (w, h), y, uv) = picture.as_ref().unwrap();
            frames.submit(&CaptureFrame {
                width: *w,
                height: *h,
                y,
                y_stride: *w,
                uv,
                uv_stride: *w,
                timestamp_ns: elapsed.as_nanos() as u64,
                rotation: 0,
            });
            sent_frames += 1;
        }
        while sent_samples * 1_000 / 48 <= elapsed.as_micros() as u64 {
            let chunk: Vec<i16> = (0..480)
                .map(|_| {
                    let s = if now.hz > 0.0 { (phase.sin() * 12_000.0) as i16 } else { 0 };
                    phase = (phase + 2.0 * std::f64::consts::PI * now.hz / 48_000.0) % (2.0 * std::f64::consts::PI);
                    s
                })
                .collect();
            voice.write(&chunk);
            sent_samples += 480;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

pub fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<Msg>::new();
    let (route, surface) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("far end").size(520.0, 640.0);
        let route = tx.signal("voice none");
        let (root, surface) = tx
            .column(|tx| {
                tx.label(route); // label#0
                tx.row(|tx| {
                    for (title, msg) in
                        [("Connect", Msg::Connect), ("Change", Msg::Change), ("Quiet", Msg::Quiet), ("Hang up", Msg::HangUp)]
                    {
                        let b = tx.button(title).id(); // button#0..#3
                        msgs.on_click(b, msg);
                    }
                });
                tx.surface().a11y_label("Peer").id() // surface#0
            })
            .into_parts();
        tx.mount(root);
        (route, surface)
    });
    let peer = Arc::new(Mutex::new(Peer { rgb: 0x1E5AC8, size: (640, 480), hz: 660.0, on: false }));
    let mut call: Option<(VoiceId, std::thread::JoinHandle<()>)> = None;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Connect if call.is_none() => {
                let voice = ctx.apply(|tx| tx.voice());
                msgs.on_voice_route(voice, |r, _| Msg::Route(r));
                *peer.lock().unwrap() = Peer { rgb: 0x1E5AC8, size: (640, 480), hz: 660.0, on: true };
                let (p, frames, writer) = (peer.clone(), ctx.surface_frames(surface), ctx.voice_writer(voice));
                call = Some((voice, std::thread::spawn(move || run_peer(p, frames, writer))));
            }
            Msg::Connect => {}
            Msg::Change => {
                let mut p = peer.lock().unwrap();
                p.rgb = 0xC83C1E;
                p.size = (1280, 720);
                p.hz = 440.0;
            }
            Msg::Quiet => peer.lock().unwrap().hz = 0.0,
            Msg::HangUp => {
                if let Some((voice, thread)) = call.take() {
                    peer.lock().unwrap().on = false;
                    let _ = thread.join();
                    ctx.apply(|tx| {
                        tx.release_voice(voice);
                        tx.write(route, "voice none");
                    });
                }
            }
            Msg::Route(r) => {
                let line = match r {
                    VoiceRoute::Voice | VoiceRoute::Plain | VoiceRoute::Synthetic => "voice playing",
                    VoiceRoute::Failed => "voice failed",
                    VoiceRoute::None => "voice none",
                };
                ctx.apply(|tx| tx.write(route, line));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
