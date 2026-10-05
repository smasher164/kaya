//! The capture (docs/capture-plan.md): a camera and a microphone the app
//! holds as one object. The scene half is a state machine like the
//! player's; the pipe half receives what a backend captured on its capture
//! thread, keeps the harness's statistics, turns samples into 48 kHz mono
//! s16 chunks of 480 (§4) and hands both to the app's callbacks. Nothing of
//! a frame or a sample rides the ring.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::media::{TIMEOUT_MS, TIMEOUT_SLACK_MS};
use crate::protocol::{
    ApplyOp, CameraFacing, CaptureCommand, CaptureDevice, CaptureFailure, CaptureId, CaptureInterruption,
    CaptureKind, CaptureProp, CaptureState, Occurrence, Permission, Value,
};

/// §4: what every app's sample callback is handed.
pub(crate) const SAMPLE_RATE: u32 = 48_000;
pub(crate) const CHUNK: usize = 480;
const CHUNK_DURATION: Duration = Duration::from_millis(10);

/// How far behind the microphone a sample callback may fall before the
/// app is told (capture_overrun).
pub(crate) const OVERRUN_MS: u64 = 200;

/// The statistics' window: a frame or a sample older than this is gone.
const WINDOW: Duration = Duration::from_millis(1000);

/// expect_capture's tolerances: the centre colour per channel (a video
/// range NV12 round trip moves a channel by up to 2), and the tone.
pub(crate) const CAPTURE_INK_TOLERANCE: u8 = 3;
pub(crate) const CAPTURE_HZ_TOLERANCE: u32 = 10;

/// Below this RMS (on the s16 scale) the samples are `silent`.
const SILENCE_RMS: f64 = 64.0;

// ---------------------------------------------------------------------
// The synthetic devices (docs/capture-plan.md §7): ONE definition, read by
// every backend whose lane has no device of its own to point at.
// ---------------------------------------------------------------------

/// A synthetic device: what it is called and what it produces, a flat
/// colour for a camera and a tone for a microphone.
pub(crate) struct Synthetic {
    pub id: &'static str,
    pub name: &'static str,
    pub kind: CaptureKind,
    pub facing: CameraFacing,
    pub preferred: bool,
    /// 0xRRGGBB for a camera, Hz for a microphone.
    pub content: u32,
}

pub(crate) const SYNTHETIC: &[Synthetic] = &[
    Synthetic {
        id: "kaya-synthetic-camera-1",
        name: "kaya Synthetic Camera 1",
        kind: CaptureKind::Camera,
        facing: CameraFacing::Front,
        preferred: true,
        content: 0xC83C1E,
    },
    Synthetic {
        id: "kaya-synthetic-camera-2",
        name: "kaya Synthetic Camera 2",
        kind: CaptureKind::Camera,
        facing: CameraFacing::External,
        preferred: false,
        content: 0x1E5AC8,
    },
    Synthetic {
        id: "kaya-synthetic-microphone-1",
        name: "kaya Synthetic Microphone 1",
        kind: CaptureKind::Microphone,
        facing: CameraFacing::Unknown,
        preferred: true,
        content: 440,
    },
    Synthetic {
        id: "kaya-synthetic-microphone-2",
        name: "kaya Synthetic Microphone 2",
        kind: CaptureKind::Microphone,
        facing: CameraFacing::Unknown,
        preferred: false,
        content: 660,
    },
];

/// What a wish of 0 stands for: the platform's own choice, read as the
/// web's default 640x480 at 30.
const DEFAULT_WISH: (f64, f64, f64) = (640.0, 480.0, 30.0);

/// §2's wish met by the nearest format, ONE rule for every backend: the
/// size nearest the wished width plus height, then that size's rate
/// nearest the wished rate; a tie takes the larger. `offered` is every
/// (width, height, frame rate) the device can deliver.
pub(crate) fn nearest_format(offered: &[(u32, u32, u32)], wish: (f64, f64, f64)) -> Option<(u32, u32, u32)> {
    let or = |x: f64, d: f64| if x > 0.0 { x } else { d };
    let (w, h, fps) = (or(wish.0, DEFAULT_WISH.0), or(wish.1, DEFAULT_WISH.1), or(wish.2, DEFAULT_WISH.2));
    let size_cost = |&(ow, oh, _): &(u32, u32, u32)| (f64::from(ow) - w).abs() + (f64::from(oh) - h).abs();
    let size = offered.iter().copied().min_by(|a, b| {
        size_cost(a).total_cmp(&size_cost(b)).then((b.0 * b.1).cmp(&(a.0 * a.1)))
    })?;
    offered
        .iter()
        .copied()
        .filter(|o| (o.0, o.1) == (size.0, size.1))
        .min_by(|a, b| (f64::from(a.2) - fps).abs().total_cmp(&(f64::from(b.2) - fps).abs()).then(b.2.cmp(&a.2)))
}

/// A self-view's picture at its natural scale (docs/capture-plan.md §3): half
/// the frames as they arrive, 320x240 with no camera.
pub(crate) fn self_view_scale(frames: (u32, u32)) -> (u32, u32) {
    if frames.0 == 0 || frames.1 == 0 {
        return (320, 240);
    }
    (frames.0 / 2, frames.1 / 2)
}

/// A self-view's natural size, one rule for every backend (docs/capture-plan.md §3):
/// half the frames, and for frames whose `rotation` (the clockwise degrees
/// they carry) stands them on end, the upright picture fitted inside that box.
pub(crate) fn self_view_natural(frames: (u32, u32), rotation: u32) -> (u32, u32) {
    let (w, h) = self_view_scale(frames);
    if frames.0 == 0 || frames.1 == 0 || rotation % 180 != 90 {
        return (w, h);
    }
    let (uw, uh) = (u64::from(frames.1), u64::from(frames.0));
    let at_height = (u64::from(h) * uw + uh / 2) / uh;
    if at_height <= u64::from(w) {
        (at_height as u32, h)
    } else {
        (w, ((u64::from(w) * uh + uw / 2) / uw) as u32)
    }
}

/// The synthetic permission store: `prompt` until a kind is asked, then
/// what the harness said the user answers (`granted` unless
/// `answer_permission` said otherwise before the ask).
struct SyntheticPermissions {
    state: [Permission; 2],
    answer: [Permission; 2],
}

static SYNTHETIC_PERMISSIONS: Mutex<SyntheticPermissions> = Mutex::new(SyntheticPermissions {
    state: [Permission::Prompt, Permission::Prompt],
    answer: [Permission::Granted, Permission::Granted],
});

fn slot(kind: CaptureKind) -> usize {
    match kind {
        CaptureKind::Camera => 0,
        CaptureKind::Microphone => 1,
    }
}

fn permissions() -> MutexGuard<'static, SyntheticPermissions> {
    SYNTHETIC_PERMISSIONS.lock().unwrap_or_else(|e| e.into_inner())
}

/// A synthetic kind's permission now.
pub(crate) fn synthetic_permission(kind: CaptureKind) -> Permission {
    permissions().state[slot(kind)]
}

/// The synthetic prompt: a kind still at `prompt` takes the answer the
/// harness arranged; a decided kind keeps its decision, as a platform asks
/// nothing twice.
pub(crate) fn synthetic_ask(kind: CaptureKind) -> Permission {
    let mut p = permissions();
    let i = slot(kind);
    if p.state[i] == Permission::Prompt {
        p.state[i] = p.answer[i];
    }
    p.state[i]
}

/// The harness's `answer_permission`: what the next synthetic prompt for
/// `kind` answers. Only before it is asked, since a prompt answered is
/// answered.
pub(crate) fn answer_permission(kind: CaptureKind, answer: Permission) -> Result<(), String> {
    let mut p = permissions();
    let i = slot(kind);
    if p.state[i] != Permission::Prompt {
        return Err(format!(
            "answer_permission {}: the permission is already {} — a scene answers a prompt before the \
             app asks",
            kind.name(),
            p.state[i].name()
        ));
    }
    if answer == Permission::Prompt {
        return Err(format!("answer_permission {}: a prompt is answered granted or denied", kind.name()));
    }
    p.answer[i] = answer;
    Ok(())
}

// ---------------------------------------------------------------------
// The scene half: one state machine per capture.
// ---------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
struct Wish {
    camera: String,
    microphone: String,
}

#[derive(Debug, Clone)]
struct Capture {
    wish: Wish,
    state: CaptureState,
    failure: Option<CaptureFailure>,
    interruption: Option<CaptureInterruption>,
    format: (u32, u32, u32),
    detail: String,
    starting_since: Option<Instant>,
}

/// A backend's report about one capture, in the closed vocabulary its arm
/// already mapped the platform's error into.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Report {
    Running { width: u32, height: u32, frame_rate: u32 },
    Interrupted(CaptureInterruption),
    Failed(CaptureFailure, String),
    /// The bound passed since the start was handed over.
    Overdue,
}

#[derive(Default)]
pub(crate) struct Captures {
    live: HashMap<CaptureId, Capture>,
    released: HashSet<CaptureId>,
    permissions: HashMap<CaptureKind, Permission>,
    /// A device list being reported, between begin and end.
    listing: Option<Vec<CaptureDevice>>,
    /// docs/media-plan.md §7c's clock, replaceable in tests.
    #[cfg(test)]
    clock: Option<Instant>,
}

impl Captures {
    fn now(&self) -> Instant {
        #[cfg(test)]
        if let Some(t) = self.clock {
            return t;
        }
        Instant::now()
    }

    #[cfg(test)]
    pub(crate) fn set_clock(&mut self, at: Instant) {
        self.clock = Some(at);
    }

    pub(crate) fn is_live(&self, capture: CaptureId) -> bool {
        self.live.contains_key(&capture)
    }

    pub(crate) fn was_released(&self, capture: CaptureId) -> bool {
        self.released.contains(&capture)
    }

    pub(crate) fn create(&mut self, capture: CaptureId, out: &mut Vec<ApplyOp>) {
        assert!(
            !self.live.contains_key(&capture),
            "kaya: create_capture {} names a capture that is already live — release it first",
            capture.0
        );
        self.released.remove(&capture);
        self.live.insert(
            capture,
            Capture {
                wish: Wish::default(),
                state: CaptureState::Idle,
                failure: None,
                interruption: None,
                format: (0, 0, 0),
                detail: String::new(),
                starting_since: None,
            },
        );
        open_pipe(capture);
        out.push(ApplyOp::CreateCapture(capture));
    }

    fn live_mut(&mut self, capture: CaptureId, what: &str) -> &mut Capture {
        let released = self.released.contains(&capture);
        self.live.get_mut(&capture).unwrap_or_else(|| {
            if released {
                panic!("kaya: {what} names capture {}, which was released", capture.0)
            }
            panic!("kaya: {what} names capture {}, which was never created — create_capture first", capture.0)
        })
    }

    pub(crate) fn set_prop(&mut self, capture: CaptureId, prop: CaptureProp, value: Value, out: &mut Vec<ApplyOp>) {
        let c = self.live_mut(capture, "set_capture_prop");
        match (prop, &value) {
            (CaptureProp::Camera, Value::Str(id)) => c.wish.camera = id.clone(),
            (CaptureProp::Microphone, Value::Str(id)) => c.wish.microphone = id.clone(),
            (CaptureProp::Width | CaptureProp::Height | CaptureProp::FrameRate, Value::F64(x)) => {
                assert!(
                    x.is_finite() && *x >= 0.0,
                    "kaya: capture {}'s {prop:?} is a wish, a finite number of at least 0 (0: the \
                     platform's own choice), got {x}",
                    capture.0
                );
            }
            (CaptureProp::Muted, Value::Bool(on)) => set_muted(capture, *on),
            (prop, value) => panic!(
                "kaya: capture {}'s {prop:?} takes {} (spec::CAPTURE_PROPS), got {value:?}",
                capture.0,
                match prop {
                    CaptureProp::Camera | CaptureProp::Microphone => "a device id as a Str, \"\" for none",
                    CaptureProp::Muted => "a Bool",
                    _ => "an F64",
                }
            ),
        }
        out.push(ApplyOp::SetCaptureProp { capture, prop, value });
    }

    pub(crate) fn command(
        &mut self,
        capture: CaptureId,
        command: CaptureCommand,
        out: &mut Vec<ApplyOp>,
        asks: &mut Vec<Occurrence>,
    ) {
        let now = self.now();
        let c = self.live_mut(capture, "capture_command");
        match command {
            CaptureCommand::Start => {
                assert!(
                    !(c.wish.camera.is_empty() && c.wish.microphone.is_empty()),
                    "kaya: capture {} starts with neither a camera nor a microphone — set its camera or \
                     microphone to a device from capture_devices first",
                    capture.0
                );
                if matches!(c.state, CaptureState::Starting | CaptureState::Running | CaptureState::Interrupted) {
                    return;
                }
                c.state = CaptureState::Starting;
                c.failure = None;
                c.interruption = None;
                c.format = (0, 0, 0);
                c.detail.clear();
                c.starting_since = Some(now);
                asks.push(changed(capture, c));
            }
            CaptureCommand::Stop => {
                if c.state == CaptureState::Idle {
                    return;
                }
                c.state = CaptureState::Idle;
                c.failure = None;
                c.interruption = None;
                c.format = (0, 0, 0);
                c.detail.clear();
                c.starting_since = None;
                asks.push(changed(capture, c));
            }
        }
        out.push(ApplyOp::CaptureCommand { capture, command });
    }

    pub(crate) fn release(&mut self, capture: CaptureId, out: &mut Vec<ApplyOp>) {
        assert!(
            self.live.remove(&capture).is_some(),
            "kaya: release_capture names capture {}, which is not live",
            capture.0
        );
        self.released.insert(capture);
        close_pipe(capture);
        out.push(ApplyOp::ReleaseCapture(capture));
    }

    /// RULES 2 AND 3, one state machine: what a report does to the capture
    /// and what the app hears. A report for a capture that is idle, failed
    /// or released changes nothing: the app stopped it, and the platform's
    /// late word is not news.
    pub(crate) fn report(&mut self, capture: CaptureId, report: Report) -> Vec<Occurrence> {
        let now = self.now();
        let Some(c) = self.live.get_mut(&capture) else { return Vec::new() };
        use CaptureState as S;
        let mut out = Vec::new();
        match (c.state, report) {
            (S::Starting | S::Running | S::Interrupted, Report::Running { width, height, frame_rate }) => {
                if c.state == S::Running && c.format == (width, height, frame_rate) {
                    return out;
                }
                c.state = S::Running;
                c.interruption = None;
                c.format = (width, height, frame_rate);
                c.starting_since = None;
                out.push(changed(capture, c));
            }
            (S::Running, Report::Interrupted(why)) => {
                c.state = S::Interrupted;
                c.interruption = Some(why);
                out.push(changed(capture, c));
            }
            (S::Starting | S::Running | S::Interrupted, Report::Failed(why, detail)) => {
                c.state = S::Failed;
                c.failure = Some(why);
                c.interruption = None;
                c.format = (0, 0, 0);
                c.starting_since = None;
                c.detail = detail;
                out.push(changed(capture, c));
            }
            (S::Starting, Report::Overdue)
                if c.starting_since.is_some_and(|since| {
                    now.saturating_duration_since(since).as_millis() as u64 + TIMEOUT_SLACK_MS >= TIMEOUT_MS
                }) =>
            {
                c.state = S::Failed;
                c.failure = Some(CaptureFailure::Timeout);
                c.starting_since = None;
                c.detail = format!(
                    "kaya: the capture did not start within {TIMEOUT_MS} ms, and the platform reported \
                     neither a running device nor a failure"
                );
                out.push(changed(capture, c));
            }
            _ => {}
        }
        out
    }

    pub(crate) fn permission(&mut self, kind: CaptureKind, permission: Permission, detail: String) -> Vec<Occurrence> {
        self.permissions.insert(kind, permission);
        vec![Occurrence::CapturePermission { kind, permission, detail }]
    }

    pub(crate) fn devices_begin(&mut self) {
        self.listing = Some(Vec::new());
    }

    pub(crate) fn device(&mut self, device: CaptureDevice) {
        self.listing.get_or_insert_with(Vec::new).push(device);
    }

    pub(crate) fn devices_end(&mut self) -> Vec<Occurrence> {
        let devices = self.listing.take().unwrap_or_default();
        vec![Occurrence::CaptureDevices { devices }]
    }
}

/// Whether a report's answer failed the capture `timeout`: the backend's
/// cue to tear its start down.
pub(crate) fn timed_out(published: &[Occurrence]) -> bool {
    published.iter().any(|o| {
        matches!(o, Occurrence::CaptureChanged { state: CaptureState::Failed, failure: Some(CaptureFailure::Timeout), .. })
    })
}

fn changed(capture: CaptureId, c: &Capture) -> Occurrence {
    Occurrence::CaptureChanged {
        capture,
        state: c.state,
        failure: c.failure,
        interruption: c.interruption,
        width: c.format.0,
        height: c.format.1,
        frame_rate: c.format.2,
        detail: c.detail.clone(),
    }
}

// ---------------------------------------------------------------------
// The pipe half: what a backend captured, on its capture thread.
// ---------------------------------------------------------------------

/// One NV12 frame as a backend hands it over: the Y plane, then the
/// interleaved UV plane at half resolution, video-range BT.601, each with
/// its own stride, borrowed for the call.
pub struct CaptureFrame<'a> {
    pub width: u32,
    pub height: u32,
    pub y: &'a [u8],
    pub y_stride: u32,
    pub uv: &'a [u8],
    pub uv_stride: u32,
    /// On the capture's own monotonic clock.
    pub timestamp_ns: u64,
    /// What the frame needs to stand upright: 0, 90, 180 or 270.
    pub rotation: u32,
}

impl CaptureFrame<'_> {
    /// The pixel at (x, y) in sRGB, from the frame's video-range BT.601
    /// samples.
    pub fn rgb_at(&self, x: u32, y: u32) -> [u8; 3] {
        let luma = f64::from(self.y[(y * self.y_stride + x) as usize]);
        let at = ((y / 2) * self.uv_stride + (x / 2) * 2) as usize;
        let (u, v) = (f64::from(self.uv[at]) - 128.0, f64::from(self.uv[at + 1]) - 128.0);
        let l = 1.164 * (luma - 16.0);
        let to = |c: f64| c.round().clamp(0.0, 255.0) as u8;
        [to(l + 1.596 * v), to(l - 0.392 * u - 0.813 * v), to(l + 2.017 * u)]
    }
}

pub(crate) type FrameSink = Arc<dyn Fn(&CaptureFrame<'_>) + Send + Sync>;
/// A chunk of CHUNK samples, and its first sample's time on the capture's
/// clock.
pub(crate) type SampleSink = Arc<dyn Fn(&[i16], u64) + Send + Sync>;

/// One capture's pipe: the statistics, the sample conversion, and the
/// overrun account.
pub(crate) struct Pipe {
    order: u64,
    muted: bool,
    frames: u64,
    last_frame: Option<(Instant, u32, u32, [u8; 3])>,
    frame_busy: Arc<AtomicBool>,
    resampler: Resampler,
    pending: Vec<i16>,
    next_chunk_ns: Option<u64>,
    window: VecDeque<i16>,
    arrivals: VecDeque<(Instant, usize, u32)>,
    last_samples: Option<Instant>,
    backlog: Duration,
    behind: bool,
}

impl Pipe {
    fn new(order: u64) -> Self {
        Pipe {
            order,
            muted: false,
            frames: 0,
            last_frame: None,
            frame_busy: Arc::new(AtomicBool::new(false)),
            resampler: Resampler::default(),
            pending: Vec::new(),
            next_chunk_ns: None,
            window: VecDeque::new(),
            arrivals: VecDeque::new(),
            last_samples: None,
            backlog: Duration::ZERO,
            behind: false,
        }
    }

    /// A frame's statistics: counted, its size and its centre's colour.
    fn note_frame(&mut self, frame: &CaptureFrame<'_>, now: Instant) {
        self.frames += 1;
        let centre = frame.rgb_at(frame.width / 2, frame.height / 2);
        self.last_frame = Some((now, frame.width, frame.height, centre));
    }

    /// Samples as the platform delivered them, interleaved float at their
    /// own rate and channel count, into whole chunks of §4's format.
    fn convert(&mut self, channels: u32, rate: u32, samples: &[f32], timestamp_ns: u64, now: Instant) -> Vec<(Vec<i16>, u64)> {
        let channels = channels.max(1) as usize;
        let mono: Vec<f32> = samples
            .chunks_exact(channels)
            .map(|frame| frame.iter().sum::<f32>() / channels as f32)
            .collect();
        if mono.is_empty() {
            return Vec::new();
        }
        if self.next_chunk_ns.is_none() {
            self.next_chunk_ns = Some(timestamp_ns);
        }
        let resampled = self.resampler.run(rate, &mono);
        let muted = self.muted;
        self.pending.extend(resampled.into_iter().map(|x| {
            if muted {
                0
            } else {
                (f64::from(x) * 32767.0).round().clamp(-32768.0, 32767.0) as i16
            }
        }));
        self.last_samples = Some(now);
        self.arrivals.push_back((now, mono.len(), rate));
        while self.arrivals.front().is_some_and(|(at, ..)| now.saturating_duration_since(*at) > WINDOW) {
            self.arrivals.pop_front();
        }
        let mut chunks = Vec::new();
        while self.pending.len() >= CHUNK {
            let chunk: Vec<i16> = self.pending.drain(..CHUNK).collect();
            for s in &chunk {
                if self.window.len() == SAMPLE_RATE as usize {
                    self.window.pop_front();
                }
                self.window.push_back(*s);
            }
            let at = self.next_chunk_ns.unwrap_or(timestamp_ns);
            self.next_chunk_ns = Some(at + CHUNK as u64 * 1_000_000_000 / u64::from(SAMPLE_RATE));
            chunks.push((chunk, at));
        }
        chunks
    }

    /// The overrun account: each chunk is 10 ms of microphone, and a
    /// callback that takes longer puts the app that much further behind.
    /// Some(behind) once it falls OVERRUN_MS behind; again only after it
    /// caught up.
    fn account(&mut self, spent: Duration) -> Option<u64> {
        self.backlog = (self.backlog + spent).saturating_sub(CHUNK_DURATION);
        if self.backlog.is_zero() {
            self.behind = false;
            return None;
        }
        let behind = self.backlog.as_millis() as u64;
        if !self.behind && behind > OVERRUN_MS {
            self.behind = true;
            return Some(behind);
        }
        None
    }

    /// What the harness reads: the last frame's size and centre within the
    /// window, and the window's tone.
    fn describe(&self, now: Instant) -> Observed {
        let frames = self
            .last_frame
            .filter(|(at, ..)| now.saturating_duration_since(*at) <= WINDOW)
            .map(|(_, w, h, rgb)| (w, h, rgb));
        let samples = match self.last_samples {
            Some(at) if now.saturating_duration_since(at) <= WINDOW && !self.window.is_empty() => {
                Some(tone(self.window.iter().copied()))
            }
            _ => None,
        };
        let arrived: usize = self
            .arrivals
            .iter()
            .filter(|(at, ..)| now.saturating_duration_since(*at) <= WINDOW)
            .map(|(_, n, _)| n)
            .sum();
        let rate = self.arrivals.back().map_or(0, |(.., rate)| *rate);
        let spread = crossing_spread(self.window.iter().copied())
            .map_or("no upward crossings".to_owned(), |(lo, mid, hi)| {
                format!("upward crossings every {lo}/{mid}/{hi} samples (min/median/max)")
            });
        let detail = format!(
            "{arrived} samples arrived in the last {} ms at a declared {rate} Hz; the window's {spread}",
            WINDOW.as_millis()
        );
        Observed { frames, samples, detail }
    }
}

/// A linear resampler to SAMPLE_RATE that carries its position and the
/// last input sample across buffers.
#[derive(Default)]
struct Resampler {
    rate: u32,
    /// The next output's position in input samples, -1 naming `prev`.
    t: f64,
    prev: f32,
}

impl Resampler {
    fn run(&mut self, rate: u32, input: &[f32]) -> Vec<f32> {
        if rate == 0 {
            return Vec::new();
        }
        if rate != self.rate {
            self.rate = rate;
            self.t = 0.0;
            self.prev = input[0];
        }
        let step = f64::from(rate) / f64::from(SAMPLE_RATE);
        let n = input.len() as f64;
        let at = |i: isize| if i < 0 { self.prev } else { input[i as usize] };
        let mut out = Vec::with_capacity((n / step) as usize + 1);
        while self.t < n - 1.0 {
            let i = self.t.floor();
            let frac = (self.t - i) as f32;
            let (a, b) = (at(i as isize), at(i as isize + 1));
            out.push(a + (b - a) * frac);
            self.t += step;
        }
        self.t -= n;
        self.prev = input[input.len() - 1];
        out
    }
}

/// The window's dominant frequency by upward zero crossings, or None for
/// silence.
fn tone(samples: impl Iterator<Item = i16> + Clone) -> Option<u32> {
    let mut count = 0usize;
    let mut energy = 0f64;
    let mut crossings = 0usize;
    let mut prev: Option<i16> = None;
    for s in samples {
        count += 1;
        energy += f64::from(s) * f64::from(s);
        if let Some(p) = prev {
            if p < 0 && s >= 0 {
                crossings += 1;
            }
        }
        prev = Some(s);
    }
    if count == 0 || (energy / count as f64).sqrt() < SILENCE_RMS {
        return None;
    }
    Some((crossings as f64 * f64::from(SAMPLE_RATE) / count as f64).round() as u32)
}

/// The gaps between upward zero crossings in samples: (min, median, max).
fn crossing_spread(samples: impl Iterator<Item = i16>) -> Option<(usize, usize, usize)> {
    let mut gaps = Vec::new();
    let mut last = None;
    let mut prev: Option<i16> = None;
    for (i, s) in samples.enumerate() {
        if prev.is_some_and(|p| p < 0 && s >= 0) {
            if let Some(l) = last {
                gaps.push(i - l);
            }
            last = Some(i);
        }
        prev = Some(s);
    }
    gaps.sort_unstable();
    Some((*gaps.first()?, gaps[gaps.len() / 2], *gaps.last()?))
}

struct Observed {
    frames: Option<(u32, u32, [u8; 3])>,
    /// None: nothing in the window; Some(None): silent; Some(Some(hz)).
    samples: Option<Option<u32>>,
    /// The failure sentence's measurements (docs/traps.md, the android
    /// capture tone read high).
    detail: String,
}

impl Observed {
    fn text(&self) -> String {
        let frames = match self.frames {
            None => "frames none".to_owned(),
            Some((w, h, [r, g, b])) => format!("frames {w}x{h} {r:02X}{g:02X}{b:02X}"),
        };
        let samples = match self.samples {
            None => "samples none".to_owned(),
            Some(None) => "samples silent".to_owned(),
            Some(Some(hz)) => format!("samples {hz} Hz"),
        };
        format!("{frames}, {samples}")
    }

    /// Whether this is what `want` says, within the tolerances.
    fn matches(&self, want: &Want) -> bool {
        let frames = match (&want.frames, self.frames) {
            (None, None) => true,
            (Some((w, h, rgb)), Some((gw, gh, grgb))) => {
                *w == gw
                    && *h == gh
                    && rgb.iter().zip(grgb).all(|(a, b)| a.abs_diff(b) <= CAPTURE_INK_TOLERANCE)
            }
            _ => false,
        };
        let samples = match (&want.samples, self.samples) {
            (WantSamples::None, None) => true,
            (WantSamples::Silent, Some(None)) => true,
            (WantSamples::Hz(hz), Some(Some(got))) => hz.abs_diff(got) <= CAPTURE_HZ_TOLERANCE,
            _ => false,
        };
        frames && samples
    }
}

#[derive(Debug, PartialEq)]
enum WantSamples {
    None,
    Silent,
    Hz(u32),
}

#[derive(Debug, PartialEq)]
struct Want {
    frames: Option<(u32, u32, [u8; 3])>,
    samples: WantSamples,
}

/// expect_capture's grammar: `frames none|WxH RRGGBB, samples
/// none|silent|N Hz`.
fn parse_want(want: &str) -> Result<Want, String> {
    let bad = || {
        format!(
            "expect_capture wants \"frames none|<w>x<h> <RRGGBB>, samples none|silent|<n> Hz\", got {want:?}"
        )
    };
    let (frames, samples) = want.split_once(", ").ok_or_else(bad)?;
    let frames = match frames.strip_prefix("frames ").ok_or_else(bad)? {
        "none" => None,
        rest => {
            let (size, hex) = rest.split_once(' ').ok_or_else(bad)?;
            let (w, h) = size.split_once('x').ok_or_else(bad)?;
            let (w, h) = (w.parse().map_err(|_| bad())?, h.parse().map_err(|_| bad())?);
            if hex.len() != 6 || !hex.chars().all(|c| c.is_ascii_digit() || ('A'..='F').contains(&c)) {
                return Err(bad());
            }
            let rgb = u32::from_str_radix(hex, 16).map_err(|_| bad())?;
            Some((w, h, [(rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8]))
        }
    };
    let samples = match samples.strip_prefix("samples ").ok_or_else(bad)? {
        "none" => WantSamples::None,
        "silent" => WantSamples::Silent,
        rest => {
            let hz = rest.strip_suffix(" Hz").ok_or_else(bad)?;
            WantSamples::Hz(hz.parse().map_err(|_| bad())?)
        }
    };
    Ok(Want { frames, samples })
}

/// Every live capture's pipe and the app's callbacks, by capture id. A
/// process holds one scene, so one table.
#[derive(Default)]
struct Pipes {
    next_order: u64,
    pipes: HashMap<u64, Pipe>,
    frame_sinks: HashMap<u64, FrameSink>,
    sample_sinks: HashMap<u64, SampleSink>,
}

static PIPES: Mutex<Option<Pipes>> = Mutex::new(None);

fn pipes() -> MutexGuard<'static, Option<Pipes>> {
    PIPES.lock().unwrap_or_else(|e| e.into_inner())
}

fn with_pipes<T>(f: impl FnOnce(&mut Pipes) -> T) -> T {
    let mut slot = pipes();
    f(slot.get_or_insert_with(Pipes::default))
}

fn open_pipe(capture: CaptureId) {
    with_pipes(|p| {
        p.next_order += 1;
        let order = p.next_order;
        p.pipes.insert(capture.0, Pipe::new(order));
    });
}

fn close_pipe(capture: CaptureId) {
    with_pipes(|p| {
        p.pipes.remove(&capture.0);
        p.frame_sinks.remove(&capture.0);
        p.sample_sinks.remove(&capture.0);
    });
}

fn set_muted(capture: CaptureId, on: bool) {
    with_pipes(|p| {
        if let Some(pipe) = p.pipes.get_mut(&capture.0) {
            pipe.muted = on;
        }
    });
}

/// The app's frame callback for a capture, replacing the last; None drops it.
pub(crate) fn set_frame_sink(capture: CaptureId, sink: Option<FrameSink>) {
    with_pipes(|p| match sink {
        Some(s) => {
            p.frame_sinks.insert(capture.0, s);
        }
        None => {
            p.frame_sinks.remove(&capture.0);
        }
    });
}

/// The app's sample callback for a capture, replacing the last.
pub(crate) fn set_sample_sink(capture: CaptureId, sink: Option<SampleSink>) {
    with_pipes(|p| match sink {
        Some(s) => {
            p.sample_sinks.insert(capture.0, s);
        }
        None => {
            p.sample_sinks.remove(&capture.0);
        }
    });
}

/// DESIGN.md's abort rule on the capture thread: a callback that panics is
/// caught and logged naming the capture, and the capture keeps running, as
/// a binding's dispatch loop survives a handler that throws.
fn survive(capture: CaptureId, what: &str, call: impl FnOnce()) {
    if let Err(e) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(call)) {
        let why = e
            .downcast_ref::<&str>()
            .map(|s| (*s).to_owned())
            .or_else(|| e.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "a panic with no message".to_owned());
        eprintln!("kaya: capture {}'s {what} callback panicked ({why}); the capture keeps running", capture.0);
    }
}

/// A backend's frame, on its capture thread: counted, and handed to the
/// app's callback unless the last one is still running (keep-only-latest).
/// False when the capture is not live.
pub(crate) fn frame(capture: CaptureId, frame: &CaptureFrame<'_>) -> bool {
    let picked = with_pipes(|p| {
        let pipe = p.pipes.get_mut(&capture.0)?;
        pipe.note_frame(frame, Instant::now());
        Some((p.frame_sinks.get(&capture.0).cloned(), pipe.frame_busy.clone()))
    });
    let Some((sink, busy)) = picked else { return false };
    if let Some(sink) = sink {
        if busy.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_ok() {
            survive(capture, "frame", || sink(frame));
            busy.store(false, Ordering::Release);
        }
    }
    true
}

/// A backend's samples, on its capture thread: converted, chunked and
/// handed to the app's callback, every one; what the app is told when its
/// callback falls behind.
pub(crate) fn samples(capture: CaptureId, channels: u32, rate: u32, samples: &[f32], timestamp_ns: u64) -> Vec<Occurrence> {
    let picked = with_pipes(|p| {
        let pipe = p.pipes.get_mut(&capture.0)?;
        let chunks = pipe.convert(channels, rate, samples, timestamp_ns, Instant::now());
        Some((chunks, p.sample_sinks.get(&capture.0).cloned()))
    });
    let Some((chunks, sink)) = picked else { return Vec::new() };
    let Some(sink) = sink else { return Vec::new() };
    let mut out = Vec::new();
    for (chunk, at) in chunks {
        let started = Instant::now();
        survive(capture, "sample", || sink(&chunk, at));
        let spent = started.elapsed();
        let overrun = with_pipes(|p| p.pipes.get_mut(&capture.0).and_then(|pipe| pipe.account(spent)));
        if let Some(behind_ms) = overrun {
            out.push(Occurrence::CaptureOverrun { capture, behind_ms });
        }
    }
    out
}

/// expect_capture: the `index`th live capture in creation order against
/// `want`. Ok(want) to record, Err(the sentence) to fail with.
pub(crate) fn expect(index: usize, want: &str) -> Result<String, String> {
    let wanted = parse_want(want)?;
    let observed = with_pipes(|p| {
        let mut live: Vec<&Pipe> = p.pipes.values().collect();
        live.sort_by_key(|pipe| pipe.order);
        let count = live.len();
        live.get(index).map(|pipe| pipe.describe(Instant::now())).ok_or(count)
    });
    match observed {
        Err(count) => Err(format!("expect_capture {index}: {count} capture(s) live, so no capture {index}")),
        Ok(o) if o.matches(&wanted) => Ok(format!("capture {want}")),
        Ok(o) => Err(format!(
            "capture {index} reads {}, wanted {want} (within {CAPTURE_INK_TOLERANCE} a channel and \
             {CAPTURE_HZ_TOLERANCE} Hz); {}",
            o.text(),
            o.detail
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nv12(width: u32, height: u32, rgb: u32) -> (Vec<u8>, Vec<u8>) {
        let (r, g, b) = (f64::from((rgb >> 16) as u8), f64::from((rgb >> 8) as u8), f64::from(rgb as u8));
        let y = (16.0 + 0.257 * r + 0.504 * g + 0.098 * b).round() as u8;
        let u = (128.0 - 0.148 * r - 0.291 * g + 0.439 * b).round() as u8;
        let v = (128.0 + 0.439 * r - 0.368 * g - 0.071 * b).round() as u8;
        let luma = vec![y; (width * height) as usize];
        let chroma = [u, v].repeat((width * height / 4) as usize);
        (luma, chroma)
    }

    fn sine(hz: f64, rate: u32, channels: usize, frames: usize, from: usize) -> Vec<f32> {
        (0..frames)
            .flat_map(|i| {
                let x = (2.0 * std::f64::consts::PI * hz * (from + i) as f64 / f64::from(rate)).sin() as f32 * 0.5;
                std::iter::repeat_n(x, channels)
            })
            .collect()
    }

    #[test]
    fn a_self_view_is_half_its_frames_and_320x240_with_no_camera() {
        assert_eq!(self_view_natural((640, 480), 0), (320, 240));
        assert_eq!(self_view_natural((1280, 720), 0), (640, 360));
        assert_eq!(self_view_natural((0, 0), 0), (320, 240));
        assert_eq!(self_view_natural((640, 0), 0), (320, 240));
        assert_eq!(self_view_natural((640, 480), 180), (320, 240));
        assert_eq!(self_view_natural((640, 480), 90), (180, 240));
        assert_eq!(self_view_natural((1280, 720), 270), (203, 360));
        assert_eq!(self_view_natural((480, 640), 90), (240, 180));
        assert_eq!(self_view_natural((0, 0), 90), (320, 240));
        assert_eq!(self_view_scale((640, 480)), (320, 240));
        assert_eq!(self_view_scale((0, 480)), (320, 240));
        assert_eq!(self_view_scale((1280, 720)), (640, 360));
    }

    #[test]
    fn a_synthetic_frame_reads_back_its_colour() {
        for rgb in [0xC83C1E, 0x1E5AC8] {
            let (y, uv) = nv12(64, 48, rgb);
            let f = CaptureFrame {
                width: 64,
                height: 48,
                y: &y,
                y_stride: 64,
                uv: &uv,
                uv_stride: 64,
                timestamp_ns: 0,
                rotation: 0,
            };
            let got = f.rgb_at(32, 24);
            let want = [(rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8];
            assert!(
                got.iter().zip(want).all(|(a, b)| a.abs_diff(b) <= CAPTURE_INK_TOLERANCE),
                "{got:?} against {want:?}"
            );
        }
    }

    #[test]
    fn samples_become_48k_mono_chunks_of_480_and_keep_their_tone() {
        let mut pipe = Pipe::new(1);
        let now = Instant::now();
        let mut chunks = Vec::new();
        let mut from = 0;
        // 44.1 kHz stereo in 512-frame buffers, the synthetic microphone's
        // shape: one second of it.
        while from < 44_100 {
            let buf = sine(440.0, 44_100, 2, 512, from);
            chunks.extend(pipe.convert(2, 44_100, &buf, from as u64 * 1_000_000_000 / 44_100, now));
            from += 512;
        }
        assert!(chunks.iter().all(|(c, _)| c.len() == CHUNK));
        let produced = chunks.len() * CHUNK;
        assert!((47_900..=48_600).contains(&produced), "{produced} samples for one second");
        assert_eq!(chunks[1].1 - chunks[0].1, 10_000_000, "a chunk is 10 ms on the capture's clock");
        assert_eq!(tone(pipe.window.iter().copied()), Some(440));
        let peak = pipe.window.iter().map(|s| s.unsigned_abs()).max().unwrap();
        assert!((16_000..=16_500).contains(&peak), "a half-scale sine peaks at half of i16, got {peak}");
    }

    /// expect_capture's failure says what arrived and how evenly the tone
    /// crossed zero: a clean tone's gaps are all one length, and a tone
    /// with silence spliced into it has short ones.
    #[test]
    fn the_capture_failure_names_arrivals_and_the_crossing_spread() {
        let now = Instant::now();
        let mut clean = Pipe::new(1);
        let mut from = 0;
        while from < 48_000 {
            clean.convert(1, 48_000, &sine(660.0, 48_000, 1, 480, from), 0, now);
            from += 480;
        }
        let seen = clean.describe(now);
        assert_eq!(seen.text(), "frames none, samples 660 Hz");
        assert!(seen.detail.starts_with("48000 samples arrived in the last 1000 ms at a declared 48000 Hz; "), "{}", seen.detail);
        let (lo, _, hi) = crossing_spread(clean.window.iter().copied()).unwrap();
        assert!(hi - lo <= 1, "a clean 660 Hz tone crosses every 72 or 73 samples, got {lo}..{hi}");
        let mut gappy = Pipe::new(2);
        let (mut from, mut made) = (0, 0);
        while made < 48_000 {
            gappy.convert(1, 48_000, &sine(660.0, 48_000, 1, 470, from), 0, now);
            gappy.convert(1, 48_000, &[0.0; 10], 0, now);
            from += 470;
            made += 480;
        }
        let (lo, mid, _) = crossing_spread(gappy.window.iter().copied()).unwrap();
        assert!(lo < 60 && (72..=73).contains(&mid), "spliced silence shortens some gaps: {lo}/{mid}");
    }

    /// The rate holds across buffers: a resampler that restarted at each
    /// one would make 557 samples of every 512 and drift the clock.
    #[test]
    fn the_resampler_keeps_the_rate_across_buffers() {
        let mut r = Resampler::default();
        let mut made = 0;
        for i in 0..86 {
            made += r.run(44_100, &sine(440.0, 44_100, 1, 512, i * 512)).len();
        }
        let want = 86 * 512 * 48_000 / 44_100;
        assert!(made.abs_diff(want) <= 1, "{made} samples from {} at 44.1 kHz, wanted {want}", 86 * 512);
    }

    #[test]
    fn muted_samples_are_silence_and_still_delivered() {
        let mut pipe = Pipe::new(1);
        pipe.muted = true;
        let buf = sine(660.0, 48_000, 1, 4800, 0);
        let chunks = pipe.convert(1, 48_000, &buf, 0, Instant::now());
        assert_eq!(chunks.len(), 9, "a muted microphone still delivers its chunks");
        assert!(chunks.iter().all(|(c, _)| c.iter().all(|s| *s == 0)));
        assert_eq!(tone(pipe.window.iter().copied()), None);
    }

    #[test]
    fn a_slow_sample_callback_is_told_once_until_it_catches_up() {
        let mut pipe = Pipe::new(1);
        let mut told = Vec::new();
        for _ in 0..200 {
            told.extend(pipe.account(Duration::from_millis(12)));
        }
        assert_eq!(told.len(), 1, "told once, as it fell behind: {told:?}");
        assert!(told[0] > OVERRUN_MS);
        for _ in 0..500 {
            assert_eq!(pipe.account(Duration::from_millis(1)), None);
        }
        assert!(!pipe.behind, "caught up");
        let mut again = Vec::new();
        for _ in 0..200 {
            again.extend(pipe.account(Duration::from_millis(12)));
        }
        assert_eq!(again.len(), 1, "told again after catching up");
        let mut fast = Pipe::new(2);
        for _ in 0..1000 {
            assert_eq!(fast.account(Duration::from_millis(9)), None, "a callback inside its 10 ms is never behind");
        }
    }

    #[test]
    fn the_harness_reads_frames_and_tone_and_their_absence() {
        let mut pipe = Pipe::new(1);
        let t0 = Instant::now();
        assert_eq!(pipe.describe(t0).text(), "frames none, samples none");
        let (y, uv) = nv12(640, 480, 0xC83C1E);
        let f = CaptureFrame {
            width: 640,
            height: 480,
            y: &y,
            y_stride: 640,
            uv: &uv,
            uv_stride: 640,
            timestamp_ns: 0,
            rotation: 0,
        };
        pipe.note_frame(&f, t0);
        pipe.convert(1, 48_000, &sine(440.0, 48_000, 1, 48_000, 0), 0, t0);
        let seen = pipe.describe(t0);
        assert!(seen.matches(&parse_want("frames 640x480 C83C1E, samples 440 Hz").unwrap()), "{}", seen.text());
        assert!(!seen.matches(&parse_want("frames 640x480 1E5AC8, samples 440 Hz").unwrap()));
        assert!(!seen.matches(&parse_want("frames 640x480 C83C1E, samples 660 Hz").unwrap()));
        assert!(!seen.matches(&parse_want("frames 1280x720 C83C1E, samples 440 Hz").unwrap()));
        let later = pipe.describe(t0 + Duration::from_millis(1500));
        assert_eq!(later.text(), "frames none, samples none", "a second without either reads none");
        assert!(parse_want("frames 640x480 c83c1e, samples 440 Hz").is_err());
        assert!(parse_want("frames none samples none").is_err());
        assert!(parse_want("frames none, samples loud").is_err());
    }

    #[test]
    fn the_state_machine_follows_the_reports_it_has_a_transition_for() {
        let mut c = Captures::default();
        let (id, mut out, mut asks) = (CaptureId(9_101), Vec::new(), Vec::new());
        c.create(id, &mut out);
        c.set_prop(id, CaptureProp::Camera, Value::from("kaya-synthetic-camera-1"), &mut out);
        assert!(c.report(id, Report::Running { width: 640, height: 480, frame_rate: 30 }).is_empty(), "idle hears nothing");
        c.command(id, CaptureCommand::Start, &mut out, &mut asks);
        assert!(matches!(asks.as_slice(), [Occurrence::CaptureChanged { state: CaptureState::Starting, .. }]));
        let ran = c.report(id, Report::Running { width: 640, height: 480, frame_rate: 30 });
        assert!(matches!(
            ran.as_slice(),
            [Occurrence::CaptureChanged { state: CaptureState::Running, width: 640, height: 480, frame_rate: 30, .. }]
        ));
        assert!(c.report(id, Report::Running { width: 640, height: 480, frame_rate: 30 }).is_empty(), "no news");
        let paused = c.report(id, Report::Interrupted(CaptureInterruption::AnotherApp));
        assert!(matches!(
            paused.as_slice(),
            [Occurrence::CaptureChanged { state: CaptureState::Interrupted, interruption: Some(CaptureInterruption::AnotherApp), .. }]
        ));
        let back = c.report(id, Report::Running { width: 640, height: 480, frame_rate: 30 });
        assert!(matches!(back.as_slice(), [Occurrence::CaptureChanged { state: CaptureState::Running, interruption: None, .. }]));
        let gone = c.report(id, Report::Failed(CaptureFailure::Disconnected, "unplugged".into()));
        assert!(matches!(
            gone.as_slice(),
            [Occurrence::CaptureChanged { state: CaptureState::Failed, failure: Some(CaptureFailure::Disconnected), width: 0, .. }]
        ));
        assert!(c.report(id, Report::Running { width: 640, height: 480, frame_rate: 30 }).is_empty(), "failed stays failed");
        asks.clear();
        c.command(id, CaptureCommand::Start, &mut out, &mut asks);
        assert!(matches!(asks.as_slice(), [Occurrence::CaptureChanged { state: CaptureState::Starting, failure: None, .. }]));
        asks.clear();
        c.command(id, CaptureCommand::Stop, &mut out, &mut asks);
        assert!(matches!(asks.as_slice(), [Occurrence::CaptureChanged { state: CaptureState::Idle, .. }]));
        assert!(c.report(id, Report::Failed(CaptureFailure::InUse, String::new())).is_empty(), "stopped is not news");
        c.release(id, &mut out);
        assert!(c.report(id, Report::Running { width: 1, height: 1, frame_rate: 1 }).is_empty());
        assert!(c.was_released(id));
    }

    #[test]
    fn a_start_the_platform_never_answers_fails_timeout() {
        let mut c = Captures::default();
        let (id, mut out, mut asks) = (CaptureId(9_102), Vec::new(), Vec::new());
        let t0 = Instant::now();
        c.set_clock(t0);
        c.create(id, &mut out);
        c.set_prop(id, CaptureProp::Microphone, Value::from("kaya-synthetic-microphone-1"), &mut out);
        c.command(id, CaptureCommand::Start, &mut out, &mut asks);
        c.set_clock(t0 + Duration::from_millis(TIMEOUT_MS / 2));
        assert!(c.report(id, Report::Overdue).is_empty(), "early: the bound has not passed");
        c.set_clock(t0 + Duration::from_millis(TIMEOUT_MS));
        let late = c.report(id, Report::Overdue);
        assert!(timed_out(&late), "{late:?}");
        assert!(c.report(id, Report::Overdue).is_empty(), "failed once");
        close_pipe(id);
    }

    #[test]
    #[should_panic(expected = "starts with neither a camera nor a microphone")]
    fn a_start_with_no_device_is_refused() {
        let mut c = Captures::default();
        let (id, mut out, mut asks) = (CaptureId(9_103), Vec::new(), Vec::new());
        c.create(id, &mut out);
        c.command(id, CaptureCommand::Start, &mut out, &mut asks);
    }

    use crate::protocol::{PropValue, TxOp, WidgetId, WidgetKind, DEFAULT_WINDOW};

    fn preview(widget: u64, capture: u64) -> TxOp {
        TxOp::SetProperty {
            widget: WidgetId(widget),
            prop: crate::protocol::Prop::Capture,
            value: PropValue::Const(Value::I64(capture as i64)),
        }
    }

    /// Two video views in a column, and a capture.
    fn two_views(capture: u64, more: Vec<TxOp>) -> (crate::scene::Scene, Vec<ApplyOp>) {
        let mut scene = crate::scene::Scene::new();
        let mut tx = vec![
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Video },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Video },
            TxOp::AddChild { parent: WidgetId(3), child: WidgetId(1) },
            TxOp::AddChild { parent: WidgetId(3), child: WidgetId(2) },
            TxOp::CreateCapture { capture: CaptureId(capture) },
        ];
        tx.extend(more);
        tx.push(TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(3) });
        let ops = scene.apply(tx);
        (scene, ops)
    }

    #[test]
    fn a_video_view_previews_a_live_capture_and_blanks_when_it_is_released() {
        let (mut scene, ops) = two_views(9_201, vec![preview(1, 9_201)]);
        assert!(ops.contains(&ApplyOp::SetVideoCapture { widget: WidgetId(1), capture: Some(CaptureId(9_201)) }));
        let ops = scene.apply(vec![TxOp::ReleaseCapture { capture: CaptureId(9_201) }, preview(2, 9_201)]);
        assert!(ops.contains(&ApplyOp::ReleaseCapture(CaptureId(9_201))));
        assert!(
            ops.contains(&ApplyOp::SetVideoCapture { widget: WidgetId(2), capture: None }),
            "a released capture previews as nothing: {ops:?}"
        );
    }

    #[test]
    #[should_panic(expected = "capture 9202 is previewed by video view 1 and by video view 2")]
    fn two_views_previewing_one_capture_are_refused_naming_both() {
        two_views(9_202, vec![preview(1, 9_202), preview(2, 9_202)]);
    }

    #[test]
    #[should_panic(expected = "video view 1 shows player 4 and previews capture 9203")]
    fn a_view_showing_a_player_and_a_capture_is_refused() {
        two_views(
            9_203,
            vec![
                TxOp::CreatePlayer { player: crate::protocol::PlayerId(4) },
                TxOp::SetProperty {
                    widget: WidgetId(1),
                    prop: crate::protocol::Prop::Player,
                    value: PropValue::Const(Value::I64(4)),
                },
                preview(1, 9_203),
            ],
        );
    }

    #[test]
    #[should_panic(expected = "previews capture 77, which was never created")]
    fn a_view_previewing_an_unknown_capture_is_refused() {
        two_views(9_204, vec![preview(1, 77)]);
    }

    #[test]
    #[should_panic(expected = "a capture is shown by a live video view only")]
    fn a_row_template_previewing_a_capture_is_refused() {
        let mut scene = crate::scene::Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateCollection {
                id: crate::protocol::CollectionId(1),
                variants: vec![vec![crate::protocol::ValueType::I64]],
            },
            TxOp::CreateFor { id: 2, collection: crate::protocol::CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Video },
            preview(10, 1),
        ]);
    }

    #[test]
    #[should_panic(expected = "Label has no property Capture")]
    fn only_a_video_view_previews_a_capture() {
        let mut scene = crate::scene::Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            TxOp::CreateCapture { capture: CaptureId(9_205) },
            preview(1, 9_205),
        ]);
    }

    #[test]
    #[should_panic(expected = "takes a device id as a Str")]
    fn a_camera_is_named_by_its_id() {
        let mut c = Captures::default();
        let mut out = Vec::new();
        c.create(CaptureId(9_206), &mut out);
        c.set_prop(CaptureId(9_206), CaptureProp::Camera, Value::I64(1), &mut out);
    }

    #[test]
    fn a_muted_capture_is_muted_in_its_pipe_and_released_ones_drop_their_callbacks() {
        let mut c = Captures::default();
        let (id, mut out) = (CaptureId(9_207), Vec::new());
        c.create(id, &mut out);
        let heard = Arc::new(Mutex::new(Vec::<i16>::new()));
        let into = heard.clone();
        set_sample_sink(id, Some(Arc::new(move |chunk: &[i16], _| into.lock().unwrap().extend_from_slice(chunk))));
        samples(id, 1, SAMPLE_RATE, &sine(440.0, SAMPLE_RATE, 1, 960, 0), 0);
        assert!(heard.lock().unwrap().iter().any(|s| *s != 0), "a live microphone is heard");
        c.set_prop(id, CaptureProp::Muted, Value::Bool(true), &mut out);
        heard.lock().unwrap().clear();
        // What was captured before the mute is delivered as it was; what is
        // captured after it is silence, and still delivered.
        samples(id, 1, SAMPLE_RATE, &sine(440.0, SAMPLE_RATE, 1, 1920, 960), 0);
        let muted = heard.lock().unwrap().clone();
        assert!(muted.len() >= 3 * CHUNK, "a muted microphone still delivers: {}", muted.len());
        assert!(muted[muted.len() - 2 * CHUNK..].iter().all(|s| *s == 0), "muted delivers silence");
        c.release(id, &mut out);
        heard.lock().unwrap().clear();
        assert!(samples(id, 1, SAMPLE_RATE, &sine(440.0, SAMPLE_RATE, 1, 960, 0), 0).is_empty());
        assert!(heard.lock().unwrap().is_empty(), "a released capture's callback is dropped");
    }

    #[test]
    fn a_frame_callback_still_running_drops_the_next_frame() {
        let mut c = Captures::default();
        let (id, mut out) = (CaptureId(9_208), Vec::new());
        c.create(id, &mut out);
        let (y, uv) = nv12(4, 4, 0xC83C1E);
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = calls.clone();
        let reentered = Arc::new(Mutex::new(None::<bool>));
        let report = reentered.clone();
        set_frame_sink(
            id,
            Some(Arc::new(move |f: &CaptureFrame<'_>| {
                counted.fetch_add(1, Ordering::SeqCst);
                if report.lock().unwrap().is_none() {
                    *report.lock().unwrap() = Some(true);
                    // The platform hands the next frame while this one runs.
                    assert!(frame(id, f));
                }
            })),
        );
        let f = CaptureFrame { width: 4, height: 4, y: &y, y_stride: 4, uv: &uv, uv_stride: 4, timestamp_ns: 0, rotation: 0 };
        assert!(frame(id, &f));
        assert_eq!(calls.load(Ordering::SeqCst), 1, "the frame that arrived during the callback was dropped");
        assert!(frame(id, &f));
        assert_eq!(calls.load(Ordering::SeqCst), 2, "the next one after it returned is handed over");
        c.release(id, &mut out);
        assert!(!frame(id, &f), "a released capture takes no frame");
    }

    #[test]
    fn a_panicking_callback_is_logged_and_the_capture_keeps_running() {
        let mut c = Captures::default();
        let (id, mut out) = (CaptureId(9_209), Vec::new());
        c.create(id, &mut out);
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = calls.clone();
        set_frame_sink(
            id,
            Some(Arc::new(move |_: &CaptureFrame<'_>| {
                counted.fetch_add(1, Ordering::SeqCst);
                panic!("the app's encoder failed");
            })),
        );
        let heard = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let into = heard.clone();
        set_sample_sink(
            id,
            Some(Arc::new(move |_: &[i16], _| {
                into.fetch_add(1, Ordering::SeqCst);
                panic!("the app's voice path failed");
            })),
        );
        let (y, uv) = nv12(4, 4, 0xC83C1E);
        let f = CaptureFrame { width: 4, height: 4, y: &y, y_stride: 4, uv: &uv, uv_stride: 4, timestamp_ns: 0, rotation: 0 };
        assert!(frame(id, &f));
        assert!(frame(id, &f), "a frame after the panic is still taken");
        assert_eq!(calls.load(Ordering::SeqCst), 2, "the callback is not left marked busy by its panic");
        samples(id, 1, SAMPLE_RATE, &sine(440.0, SAMPLE_RATE, 1, 1920, 0), 0);
        assert_eq!(heard.load(Ordering::SeqCst), 3, "every chunk is still handed over after a panic");
        c.release(id, &mut out);
    }

    #[test]
    fn a_wish_meets_its_nearest_format() {
        let offered = [(640, 480, 15), (640, 480, 30), (1280, 720, 15), (1280, 720, 30), (320, 240, 30)];
        assert_eq!(nearest_format(&offered, (600.0, 400.0, 30.0)), Some((640, 480, 30)));
        assert_eq!(nearest_format(&offered, (1280.0, 720.0, 15.0)), Some((1280, 720, 15)));
        assert_eq!(nearest_format(&offered, (0.0, 0.0, 0.0)), Some((640, 480, 30)), "0 is the platform's default");
        assert_eq!(nearest_format(&offered, (1920.0, 1080.0, 60.0)), Some((1280, 720, 30)));
        assert_eq!(nearest_format(&offered, (300.0, 200.0, 22.0)), Some((320, 240, 30)));
        assert_eq!(nearest_format(&[(640, 480, 20), (640, 480, 10)], (640.0, 480.0, 15.0)), Some((640, 480, 20)), "a tie takes the larger");
        assert_eq!(nearest_format(&[(800, 600, 30), (480, 360, 30)], (640.0, 480.0, 30.0)), Some((800, 600, 30)), "a tie takes the larger");
        assert_eq!(nearest_format(&[], (640.0, 480.0, 30.0)), None);
    }

    #[test]
    fn the_synthetic_table_is_two_of_each_with_one_preferred() {
        for kind in [CaptureKind::Camera, CaptureKind::Microphone] {
            let of: Vec<_> = SYNTHETIC.iter().filter(|s| s.kind == kind).collect();
            assert_eq!(of.len(), 2);
            assert_eq!(of.iter().filter(|s| s.preferred).count(), 1);
            assert_ne!(of[0].content, of[1].content, "the device choice must be assertable");
        }
    }
}
