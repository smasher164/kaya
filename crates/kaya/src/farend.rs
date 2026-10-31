//! The far end of a call (docs/capture-plan.md §5): the frames the app
//! submits to a surface, kept until the backend composites them, and the
//! samples the app writes to a voice output, queued until the platform's
//! voice path pulls them. Both are written from any thread and never ride
//! the ring; the harness reads what the platform took, never the app's word.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::capture::{CaptureFrame, SAMPLE_RATE};
use crate::protocol::{ApplyOp, Occurrence, VoiceId, VoiceRoute, WidgetId};

/// What a voice output holds ahead of the platform: past it, the oldest
/// samples are dropped, so a writer ahead of the voice path is heard late by
/// at most this much.
pub(crate) const VOICE_QUEUE_MS: u64 = 200;
const VOICE_QUEUE: usize = (SAMPLE_RATE as u64 * VOICE_QUEUE_MS / 1000) as usize;

/// The statistics' window, the capture's.
const WINDOW: Duration = Duration::from_millis(1000);

// ---------------------------------------------------------------------
// The surface half.
// ---------------------------------------------------------------------

/// One surface's last frame, its planes packed at their widths.
struct Slot {
    seq: u64,
    width: u32,
    height: u32,
    rotation: u32,
    y: Vec<u8>,
    uv: Vec<u8>,
    submitted: u64,
    submitted_at: Option<Instant>,
    taken: u64,
    taken_at: Option<Instant>,
    taken_seq: u64,
    /// The frame stood upright as RGBA, made at the submit, on the app's
    /// thread, for the backends that draw RGBA (docs/traps.md, a debug
    /// build's conversion on GTK's frame clock starved its main thread).
    rgba: Vec<u8>,
}

impl Slot {
    fn new() -> Self {
        Slot {
            seq: 0,
            width: 0,
            height: 0,
            rotation: 0,
            y: Vec::new(),
            uv: Vec::new(),
            submitted: 0,
            submitted_at: None,
            taken: 0,
            taken_at: None,
            taken_seq: 0,
            rgba: Vec::new(),
        }
    }
}

static SURFACES: Mutex<Option<HashMap<u64, Slot>>> = Mutex::new(None);

fn surfaces() -> MutexGuard<'static, Option<HashMap<u64, Slot>>> {
    SURFACES.lock().unwrap_or_else(|e| e.into_inner())
}

fn with_surfaces<T>(f: impl FnOnce(&mut HashMap<u64, Slot>) -> T) -> T {
    let mut slot = surfaces();
    f(slot.get_or_insert_with(HashMap::new))
}

pub(crate) fn open_surface(widget: WidgetId) {
    with_surfaces(|s| {
        s.insert(widget.0, Slot::new());
    });
}

pub(crate) fn close_surface(widget: WidgetId) {
    with_surfaces(|s| {
        s.remove(&widget.0);
    });
}

/// The app's frame for `widget`, from any thread: copied, replacing the
/// last. False when `widget` is not a live surface (released while the
/// app's transport still ran), and the frame is dropped.
pub(crate) fn submit(widget: WidgetId, frame: &CaptureFrame<'_>) -> bool {
    let (w, h) = (frame.width, frame.height);
    assert!(
        w > 0 && h > 0 && w % 2 == 0 && h % 2 == 0,
        "kaya: surface {} was submitted a {w}x{h} frame — NV12 is even in both sides and never empty \
         (docs/capture-plan.md §4)",
        widget.0
    );
    assert!(
        matches!(frame.rotation, 0 | 90 | 180 | 270),
        "kaya: surface {}'s frame carries a rotation of {} — 0, 90, 180 or 270 (docs/capture-plan.md §4)",
        widget.0,
        frame.rotation
    );
    let rows = |stride: u32, rows: u32, width: u32| u64::from(stride) * u64::from(rows - 1) + u64::from(width);
    assert!(
        frame.y_stride >= w
            && frame.uv_stride >= w
            && frame.y.len() as u64 >= rows(frame.y_stride, h, w)
            && frame.uv.len() as u64 >= rows(frame.uv_stride, h / 2, w),
        "kaya: surface {}'s {w}x{h} frame holds {} luma bytes at a stride of {} and {} chroma bytes at a \
         stride of {} — too few for its size",
        widget.0,
        frame.y.len(),
        frame.y_stride,
        frame.uv.len(),
        frame.uv_stride
    );
    with_surfaces(|s| {
        let Some(slot) = s.get_mut(&widget.0) else { return false };
        slot.y.clear();
        for row in 0..h {
            let at = (row * frame.y_stride) as usize;
            slot.y.extend_from_slice(&frame.y[at..at + w as usize]);
        }
        slot.uv.clear();
        for row in 0..h / 2 {
            let at = (row * frame.uv_stride) as usize;
            slot.uv.extend_from_slice(&frame.uv[at..at + w as usize]);
        }
        slot.width = w;
        slot.height = h;
        slot.rotation = frame.rotation;
        if RGBA_BACKEND {
            upright_rgba(frame, &mut slot.rgba);
        }
        slot.seq += 1;
        slot.submitted += 1;
        slot.submitted_at = Some(Instant::now());
        true
    })
}

/// The backend's look on its display clock: the last frame's (width,
/// height, rotation, seq) when it is newer than `seen`.
pub(crate) fn newer(widget: WidgetId, seen: u64) -> Option<(u32, u32, u32, u64)> {
    with_surfaces(|s| {
        let slot = s.get(&widget.0)?;
        (slot.seq > seen).then_some((slot.width, slot.height, slot.rotation, slot.seq))
    })
}

/// The backend takes the last frame: `f` sees it borrowed, packed (both
/// strides its width), and the take is counted for the harness. None when
/// there is none, or it is no longer `width` x `height`.
pub(crate) fn take<T>(widget: WidgetId, width: u32, height: u32, f: impl FnOnce(&CaptureFrame<'_>, u64) -> T) -> Option<T> {
    with_surfaces(|s| {
        let slot = s.get_mut(&widget.0)?;
        if slot.seq == 0 || slot.width != width || slot.height != height {
            return None;
        }
        slot.taken += 1;
        slot.taken_at = Some(Instant::now());
        slot.taken_seq = slot.seq;
        let frame = CaptureFrame {
            width,
            height,
            y: &slot.y,
            y_stride: width,
            uv: &slot.uv,
            uv_stride: width,
            timestamp_ns: 0,
            rotation: slot.rotation,
        };
        Some(f(&frame, slot.seq))
    })
}

/// The backend that draws RGBA takes the last frame newer than `seen` as
/// straight sRGB RGBA8 rows (BT.601 video range, the capture's one
/// conversion): (width, height, rotation, seq, pixels).
#[cfg_attr(not(any(target_os = "linux", target_os = "windows", target_os = "android")), allow(dead_code))]
pub(crate) fn take_rgba(widget: WidgetId, seen: u64) -> Option<(u32, u32, u32, u64, Vec<u8>)> {
    with_surfaces(|s| {
        let slot = s.get_mut(&widget.0)?;
        if slot.seq <= seen || slot.rgba.is_empty() {
            return None;
        }
        slot.taken += 1;
        slot.taken_at = Some(Instant::now());
        slot.taken_seq = slot.seq;
        Some((slot.width, slot.height, slot.rotation, slot.seq, slot.rgba.clone()))
    })
}

/// Whether this build's backend draws a surface from RGBA (GTK, WinUI,
/// Compose) rather than from the NV12 planes (the Apple arms).
const RGBA_BACKEND: bool = cfg!(any(test, target_os = "linux", target_os = "windows", target_os = "android"));

/// `frame` stood upright (its rotation applied clockwise) as straight sRGB
/// RGBA8 rows, video-range BT.601 in fixed point (rgb_at's coefficients
/// times 256), into `out`.
fn upright_rgba(frame: &CaptureFrame<'_>, out: &mut Vec<u8>) {
    let (w, h) = (frame.width as usize, frame.height as usize);
    let (uw, uh) = if frame.rotation % 180 == 90 { (h, w) } else { (w, h) };
    out.clear();
    out.reserve(uw * uh * 4);
    let clamp = |v: i32| v.clamp(0, 255) as u8;
    for oy in 0..uh {
        for ox in 0..uw {
            let (x, y) = match frame.rotation {
                90 => (oy, h - 1 - ox),
                180 => (w - 1 - ox, h - 1 - oy),
                270 => (w - 1 - oy, ox),
                _ => (ox, oy),
            };
            let c = 298 * (i32::from(frame.y[y * frame.y_stride as usize + x]) - 16);
            let at = (y / 2) * frame.uv_stride as usize + (x / 2) * 2;
            let d = i32::from(frame.uv[at]) - 128;
            let e = i32::from(frame.uv[at + 1]) - 128;
            out.extend_from_slice(&[
                clamp((c + 409 * e + 128) >> 8),
                clamp((c - 100 * d - 208 * e + 128) >> 8),
                clamp((c + 516 * d + 128) >> 8),
                255,
            ]);
        }
    }
}

/// A surface's frames as its backend lays it out: the last one's size and
/// rotation, (0, 0, 0) before the first.
#[cfg_attr(not(any(target_os = "linux", target_os = "windows")), allow(dead_code))]
pub(crate) fn frames(widget: WidgetId) -> (u32, u32, u32) {
    with_surfaces(|s| s.get(&widget.0).map_or((0, 0, 0), |slot| (slot.width, slot.height, slot.rotation)))
}

/// What a surface's pixel read prints beside a miss, so it says which half
/// failed: the app's submits or the backend's takes.
pub(crate) fn surface_detail(widget: WidgetId) -> String {
    let now = Instant::now();
    let ago = |at: Option<Instant>| {
        at.map_or("never".to_owned(), |t| format!("{} ms ago", now.saturating_duration_since(t).as_millis()))
    };
    with_surfaces(|s| match s.get(&widget.0) {
        None => format!("surface {} is not live in the core", widget.0),
        Some(slot) => format!(
            "the app submitted {} frame(s), the last {} ({}x{} at rotation {}); the backend took {}, the last \
             {} (frame {} of {})",
            slot.submitted,
            ago(slot.submitted_at),
            slot.width,
            slot.height,
            slot.rotation,
            slot.taken,
            ago(slot.taken_at),
            slot.taken_seq,
            slot.seq
        ),
    })
}

// ---------------------------------------------------------------------
// The voice half.
// ---------------------------------------------------------------------

struct Queue {
    order: u64,
    pending: VecDeque<i16>,
    written: u64,
    dropped: u64,
    /// The next output sample's place between pending[0] and pending[1].
    phase: f64,
    /// The last second of what the platform pulled, at 48 kHz, its underruns
    /// as silence.
    window: VecDeque<i16>,
    pulls: VecDeque<(Instant, usize, u32, u32, usize)>,
    underrun: u64,
    route: VoiceRoute,
    detail: String,
}

impl Queue {
    fn new(order: u64) -> Self {
        Queue {
            order,
            pending: VecDeque::new(),
            written: 0,
            dropped: 0,
            phase: 0.0,
            window: VecDeque::new(),
            pulls: VecDeque::new(),
            underrun: 0,
            route: VoiceRoute::None,
            detail: String::new(),
        }
    }

    fn write(&mut self, samples: &[i16]) {
        self.written += samples.len() as u64;
        self.pending.extend(samples.iter().copied());
        while self.pending.len() > VOICE_QUEUE {
            self.pending.pop_front();
            self.dropped += 1;
        }
    }

    fn heard(&mut self, s: i16) {
        if self.window.len() == SAMPLE_RATE as usize {
            self.window.pop_front();
        }
        self.window.push_back(s);
    }

    /// `frames` frames at `rate` and `channels`, interleaved float, from the
    /// queue by linear interpolation; silence past its end. Answers how many
    /// came from the app.
    fn pull(&mut self, rate: u32, channels: u32, out: &mut [f32], now: Instant) -> usize {
        let channels = channels.max(1) as usize;
        let frames = out.len() / channels;
        let step = f64::from(SAMPLE_RATE) / f64::from(rate.max(1));
        let mut real = 0;
        for frame in 0..frames {
            let value = match (self.pending.front(), self.pending.get(1)) {
                (Some(&a), Some(&b)) => {
                    real += 1;
                    f32::from(a) + (f32::from(b) - f32::from(a)) * self.phase as f32
                }
                _ => 0.0,
            };
            for c in 0..channels {
                out[frame * channels + c] = value / 32768.0;
            }
            self.phase += step;
            while self.phase >= 1.0 {
                self.phase -= 1.0;
                match self.pending.pop_front() {
                    Some(s) => self.heard(s),
                    None => self.underrun += 1,
                }
            }
        }
        self.pulls.push_back((now, frames, rate, channels as u32, real));
        while self.pulls.front().is_some_and(|(at, ..)| now.saturating_duration_since(*at) > WINDOW) {
            self.pulls.pop_front();
        }
        real
    }

    fn describe(&self, now: Instant) -> (Option<Option<u32>>, String) {
        let recent: Vec<_> = self.pulls.iter().filter(|(at, ..)| now.saturating_duration_since(*at) <= WINDOW).collect();
        let heard: usize = recent.iter().map(|p| p.4).sum();
        let tone = if recent.is_empty() {
            None
        } else if heard == 0 || self.window.is_empty() {
            Some(None)
        } else {
            Some(crate::capture::tone(self.window.iter().copied()))
        };
        let pulled: usize = recent.iter().map(|(_, n, ..)| n).sum();
        let shape = recent.last().map_or("nothing".to_owned(), |(_, _, rate, ch, _)| format!("{rate} Hz x{ch}"));
        let detail = format!(
            "the platform pulled {pulled} frame(s) as {shape} in the last {} ms, {heard} of them the app's; the app wrote {} sample(s), {} \
             dropped past the {VOICE_QUEUE_MS} ms queue, {} pulled past its end; route {} ({})",
            WINDOW.as_millis(),
            self.written,
            self.dropped,
            self.underrun,
            self.route.name(),
            if self.detail.is_empty() { "nothing reported" } else { &self.detail },
        );
        (tone, detail)
    }
}

#[derive(Default)]
struct Queues {
    next_order: u64,
    live: HashMap<u64, Queue>,
}

static VOICES: Mutex<Option<Queues>> = Mutex::new(None);

fn with_voices<T>(f: impl FnOnce(&mut Queues) -> T) -> T {
    let mut slot = VOICES.lock().unwrap_or_else(|e| e.into_inner());
    f(slot.get_or_insert_with(Queues::default))
}

/// The app's samples for `voice`, from any thread: 48 kHz mono s16, queued
/// for the platform. False when `voice` is not live, and they are dropped.
pub(crate) fn write(voice: VoiceId, samples: &[i16]) -> bool {
    with_voices(|q| match q.live.get_mut(&voice.0) {
        Some(queue) => {
            queue.write(samples);
            true
        }
        None => false,
    })
}

/// The platform's voice path pulls `out` (interleaved float at `rate` and
/// `channels`), on its own audio thread; silence where the app wrote
/// nothing. Answers how many frames the app's samples filled.
pub(crate) fn pull(voice: VoiceId, rate: u32, channels: u32, out: &mut [f32]) -> usize {
    out.fill(0.0);
    with_voices(|q| q.live.get_mut(&voice.0).map_or(0, |queue| queue.pull(rate, channels, out, Instant::now())))
}

/// The scene half: one record per voice output, live from create to release.
#[derive(Default)]
pub(crate) struct Voices {
    live: HashSet<VoiceId>,
    released: HashSet<VoiceId>,
}

impl Voices {
    pub(crate) fn create(&mut self, voice: VoiceId, out: &mut Vec<ApplyOp>) {
        assert!(
            self.live.insert(voice),
            "kaya: create_voice {} names a voice output that is already live — release it first",
            voice.0
        );
        self.released.remove(&voice);
        with_voices(|q| {
            q.next_order += 1;
            let order = q.next_order;
            q.live.insert(voice.0, Queue::new(order));
        });
        out.push(ApplyOp::CreateVoice(voice));
    }

    pub(crate) fn release(&mut self, voice: VoiceId, out: &mut Vec<ApplyOp>) {
        if !self.live.remove(&voice) {
            if self.released.contains(&voice) {
                panic!("kaya: release_voice names voice output {}, which was already released", voice.0)
            }
            panic!("kaya: release_voice names voice output {}, which was never created", voice.0)
        }
        self.released.insert(voice);
        with_voices(|q| q.live.remove(&voice.0));
        out.push(ApplyOp::ReleaseVoice(voice));
    }

    /// The backend's route for a live voice output; nothing for one the app
    /// released, whose late word is not news.
    pub(crate) fn route(&mut self, voice: VoiceId, route: VoiceRoute, detail: String) -> Vec<Occurrence> {
        if !self.live.contains(&voice) {
            return Vec::new();
        }
        with_voices(|q| {
            if let Some(queue) = q.live.get_mut(&voice.0) {
                queue.route = route;
                queue.detail = detail.clone();
            }
        });
        vec![Occurrence::VoiceChanged { voice, route, detail }]
    }
}

/// expect_voice's grammar: `<n> Hz`, `silent` or `none`.
#[derive(Debug, PartialEq)]
enum Want {
    None,
    Silent,
    Hz(u32),
}

fn parse_want(want: &str) -> Result<Want, String> {
    match want {
        "none" => Ok(Want::None),
        "silent" => Ok(Want::Silent),
        _ => want
            .strip_suffix(" Hz")
            .and_then(|hz| hz.parse().ok())
            .map(Want::Hz)
            .ok_or_else(|| format!("expect_voice wants \"<n> Hz\", \"silent\" or \"none\", got {want:?}")),
    }
}

/// expect_voice: the `index`th live voice output in creation order. What
/// the platform pulled in the last second, by the capture's tone rule, and,
/// for anything heard, a route on which the platform plays it.
pub(crate) fn expect(index: usize, want: &str) -> Result<String, String> {
    let wanted = parse_want(want)?;
    let now = Instant::now();
    let seen = with_voices(|q| {
        let mut live: Vec<&Queue> = q.live.values().collect();
        live.sort_by_key(|queue| queue.order);
        let count = live.len();
        live.get(index).map(|queue| (queue.describe(now), queue.route)).ok_or(count)
    });
    let ((tone, detail), route) = match seen {
        Err(count) => return Err(format!("expect_voice {index}: {count} voice output(s) live, so no voice {index}")),
        Ok(s) => s,
    };
    let heard = match tone {
        None => "none".to_owned(),
        Some(None) => "silent".to_owned(),
        Some(Some(hz)) => format!("{hz} Hz"),
    };
    let tone_ok = match (&wanted, tone) {
        (Want::None, None) => true,
        (Want::Silent, Some(None)) => true,
        (Want::Hz(hz), Some(Some(got))) => hz.abs_diff(got) <= crate::capture::CAPTURE_HZ_TOLERANCE,
        _ => false,
    };
    let route_ok = wanted == Want::None || matches!(route, VoiceRoute::Voice | VoiceRoute::Plain | VoiceRoute::Synthetic);
    if tone_ok && route_ok {
        return Ok(format!("voice {index} {want} on route {}", route.name()));
    }
    Err(format!(
        "voice {index} reads {heard}{}, wanted {want} (within {} Hz); {detail}",
        if route_ok { String::new() } else { format!(" on route {}, which plays nothing", route.name()) },
        crate::capture::CAPTURE_HZ_TOLERANCE
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(hz: f64, from: usize, n: usize) -> Vec<i16> {
        (from..from + n)
            .map(|i| ((2.0 * std::f64::consts::PI * hz * i as f64 / f64::from(SAMPLE_RATE)).sin() * 16000.0) as i16)
            .collect()
    }

    fn flat(width: u32, height: u32, y: u8, u: u8, v: u8) -> (Vec<u8>, Vec<u8>) {
        (vec![y; (width * height) as usize], [u, v].repeat((width * height / 4) as usize))
    }

    #[test]
    fn a_surface_keeps_the_last_frame_packed_and_counts_its_takes() {
        let id = WidgetId(9_301);
        open_surface(id);
        assert_eq!(newer(id, 0), None, "no frame yet");
        assert_eq!(frames(id), (0, 0, 0));
        // A padded stride, as a platform buffer has.
        let (mut y, mut uv) = (vec![0u8; 8 * 4], vec![0u8; 8 * 2]);
        for row in 0..4 {
            y[row * 8..row * 8 + 4].fill(100 + row as u8);
        }
        for row in 0..2 {
            uv[row * 8..row * 8 + 4].copy_from_slice(&[10, 20, 30, 40]);
        }
        let f = CaptureFrame { width: 4, height: 4, y: &y, y_stride: 8, uv: &uv, uv_stride: 8, timestamp_ns: 0, rotation: 90 };
        assert!(submit(id, &f));
        assert!(submit(id, &f));
        assert_eq!(newer(id, 0), Some((4, 4, 90, 2)));
        assert_eq!(newer(id, 2), None, "seen");
        assert_eq!(frames(id), (4, 4, 90));
        let packed = take(id, 4, 4, |f, seq| (f.y.to_vec(), f.uv.to_vec(), seq)).unwrap();
        assert_eq!(packed.0, [100, 100, 100, 100, 101, 101, 101, 101, 102, 102, 102, 102, 103, 103, 103, 103]);
        assert_eq!(packed.1, [10, 20, 30, 40, 10, 20, 30, 40]);
        assert_eq!(packed.2, 2);
        assert!(take(id, 8, 8, |_, _| ()).is_none(), "a take of another size finds nothing");
        let (w, h, rotation, seq, rgba) = take_rgba(id, 0).unwrap();
        assert_eq!((w, h, rotation, seq, rgba.len()), (4, 4, 90, 2, 64));
        // Stood upright clockwise: the first row's luma 100 (row 0) lands in
        // the right-hand column, row 3's luma 103 in the left-hand one.
        let luma = |px: &[u8]| px[1];
        assert!(luma(&rgba[12..16]) < luma(&rgba[0..4]), "row 0 on the right, row 3 on the left");
        assert!(take_rgba(id, 2).is_none(), "nothing newer than what was taken");
        assert!(surface_detail(id).contains("submitted 2 frame(s)"), "{}", surface_detail(id));
        assert!(surface_detail(id).contains("the backend took 2"), "{}", surface_detail(id));
        let (y, uv) = flat(4, 4, 81, 90, 240);
        let red = CaptureFrame { width: 4, height: 4, y: &y, y_stride: 4, uv: &uv, uv_stride: 4, timestamp_ns: 0, rotation: 0 };
        let mut px = Vec::new();
        upright_rgba(&red, &mut px);
        for (got, want) in px[..3].iter().zip(red.rgb_at(0, 0)) {
            assert!(got.abs_diff(want) <= 1, "fixed point within one of rgb_at: {:?} against {:?}", &px[..3], red.rgb_at(0, 0));
        }
        close_surface(id);
        assert!(!submit(id, &f), "a destroyed surface takes no frame");
        assert!(surface_detail(id).contains("not live"));
    }

    #[test]
    #[should_panic(expected = "NV12 is even in both sides")]
    fn an_odd_frame_is_refused() {
        let (y, uv) = flat(4, 4, 0, 0, 0);
        let f = CaptureFrame { width: 3, height: 4, y: &y, y_stride: 4, uv: &uv, uv_stride: 4, timestamp_ns: 0, rotation: 0 };
        submit(WidgetId(9_302), &f);
    }

    #[test]
    #[should_panic(expected = "too few for its size")]
    fn a_short_frame_is_refused() {
        let (y, uv) = flat(4, 4, 0, 0, 0);
        let f = CaptureFrame { width: 4, height: 4, y: &y[..10], y_stride: 4, uv: &uv, uv_stride: 4, timestamp_ns: 0, rotation: 0 };
        submit(WidgetId(9_303), &f);
    }

    #[test]
    #[should_panic(expected = "a rotation of 45")]
    fn a_crooked_frame_is_refused() {
        let (y, uv) = flat(4, 4, 0, 0, 0);
        let f = CaptureFrame { width: 4, height: 4, y: &y, y_stride: 4, uv: &uv, uv_stride: 4, timestamp_ns: 0, rotation: 45 };
        submit(WidgetId(9_304), &f);
    }

    /// One test, since expect_voice indexes every live voice output in the
    /// process and a parallel test's would shift the index.
    #[test]
    fn a_voice_plays_what_was_written_at_the_platform_s_rate_and_reads_its_tone() {
        let mut voices = Voices::default();
        let (id, mut out) = (VoiceId(9_401), Vec::new());
        voices.create(id, &mut out);
        assert_eq!(out, vec![ApplyOp::CreateVoice(id)]);
        assert!(expect(0, "none").is_ok(), "nothing pulled yet reads none");
        let now = Instant::now();
        let mut written = 0;
        let mut buf = vec![0f32; 441 * 2];
        // The platform pulls 10 ms at 44.1 kHz stereo while the app keeps
        // 10 ms ahead, for a second.
        for _ in 0..100 {
            assert!(write(id, &sine(660.0, written, 480)));
            written += 480;
            let real = with_voices(|q| q.live.get_mut(&id.0).unwrap().pull(44_100, 2, &mut buf, now));
            assert!(real > 400, "the app's samples fill the pull: {real}");
            assert_eq!(buf[0], buf[1], "both channels carry the one voice");
        }
        assert!(expect(0, "660 Hz").is_err(), "route none plays nothing: {:?}", expect(0, "660 Hz"));
        assert!(voices.route(id, VoiceRoute::Synthetic, "the harness's engine".into()).len() == 1);
        assert_eq!(expect(0, "660 Hz"), Ok("voice 0 660 Hz on route synthetic".to_owned()));
        let miss = expect(0, "440 Hz").unwrap_err();
        assert!(miss.starts_with("voice 0 reads 6") && miss.contains(" Hz, wanted 440 Hz"), "{miss}");
        assert!(miss.contains("route synthetic (the harness's engine)"), "{miss}");
        // The app stops writing: the platform keeps pulling, silence.
        let later = now + Duration::from_millis(1500);
        for _ in 0..100 {
            with_voices(|q| q.live.get_mut(&id.0).unwrap().pull(44_100, 2, &mut buf, later));
        }
        with_voices(|q| {
            let queue = q.live.get(&id.0).unwrap();
            assert_eq!(queue.describe(later).0, Some(None), "{}", queue.describe(later).1);
        });
        voices.release(id, &mut out);
        assert!(!write(id, &[1, 2, 3]), "a released voice takes no samples");
        assert!(voices.route(id, VoiceRoute::Voice, String::new()).is_empty(), "its late route is not news");
        assert!(expect(0, "none").unwrap_err().contains("0 voice output(s) live"));

        // A writer ahead of the voice path loses its oldest past the queue.
        let ahead = VoiceId(9_402);
        voices.create(ahead, &mut out);
        assert!(write(ahead, &vec![1; VOICE_QUEUE + 480]));
        with_voices(|q| {
            let queue = q.live.get(&ahead.0).unwrap();
            assert_eq!(queue.pending.len(), VOICE_QUEUE);
            assert_eq!(queue.dropped, 480);
        });
        let twice = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| voices.create(ahead, &mut Vec::new())));
        let why = twice.unwrap_err();
        assert!(why.downcast_ref::<String>().unwrap().contains("already live"));
        voices.release(ahead, &mut out);
        let gone = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| voices.release(ahead, &mut Vec::new())));
        assert!(gone.unwrap_err().downcast_ref::<String>().unwrap().contains("already released"));
        let never = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| voices.release(VoiceId(9_404), &mut Vec::new())));
        assert!(never.unwrap_err().downcast_ref::<String>().unwrap().contains("never created"));
    }

    #[test]
    #[should_panic(expected = "is a surface — a surface shows the frames the app submits")]
    fn a_row_template_holding_a_surface_is_refused() {
        use crate::protocol::{CollectionId, TxOp, ValueType, WidgetKind};
        let mut scene = crate::scene::Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::I64]] },
            TxOp::CreateFor { id: 2, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Surface },
        ]);
    }

    #[test]
    fn a_surface_s_slot_opens_with_its_widget() {
        use crate::protocol::{TxOp, WidgetKind, DEFAULT_WINDOW};
        let mut scene = crate::scene::Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(9_311), kind: WidgetKind::Surface },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(9_311) },
        ]);
        let (y, uv) = flat(4, 4, 81, 90, 240);
        let f = CaptureFrame { width: 4, height: 4, y: &y, y_stride: 4, uv: &uv, uv_stride: 4, timestamp_ns: 0, rotation: 0 };
        assert!(submit(WidgetId(9_311), &f), "a live surface takes a frame");
        assert!(!submit(WidgetId(9_312), &f), "a widget that is no surface does not");
    }

    #[test]
    fn expect_voice_s_grammar() {
        assert_eq!(parse_want("660 Hz"), Ok(Want::Hz(660)));
        assert_eq!(parse_want("silent"), Ok(Want::Silent));
        assert_eq!(parse_want("none"), Ok(Want::None));
        assert!(parse_want("660hz").is_err());
        assert!(parse_want("loud").is_err());
    }
}
