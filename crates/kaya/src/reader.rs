//! The media reader and the core-held images (docs/media-plan.md §8 rulings
//! 3 and 4): a reader's reads, their answers and their bound; the peaks
//! reduction, one Rust function for five platforms; and the image table the
//! canvas's `image` op draws from. A backend reports what its platform
//! decoded; this decides what the app hears.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use vello_cpu::Pixmap;
use vello_cpu::peniko::color::PremulRgba8;

use crate::media::{Resolved, TIMEOUT_MS, TIMEOUT_SLACK_MS};
use crate::protocol::{
    ApplyOp, FrameAccuracy, ImageId, MediaFailure, Occurrence, Peaks, ReadId, ReadOutcome, ReaderId, Value,
};

/// The largest image side kaya holds: the canvas raster's own clamp.
const MAX_SIDE: u32 = 16384;

pub(crate) fn pixmap(width: u32, height: u32, rgba: &[u8]) -> Result<Pixmap, String> {
    if width == 0 || height == 0 || width > MAX_SIDE || height > MAX_SIDE {
        return Err(format!(
            "kaya: an image of {width}x{height} pixels; kaya holds images from 1x1 to \
             {MAX_SIDE}x{MAX_SIDE}"
        ));
    }
    let want = width as usize * height as usize * 4;
    if rgba.len() != want {
        return Err(format!(
            "kaya: an image of {width}x{height} carries {} bytes of RGBA8, wanted {want}",
            rgba.len()
        ));
    }
    let data = rgba.chunks_exact(4).map(|p| PremulRgba8 { r: p[0], g: p[1], b: p[2], a: p[3] }).collect();
    Ok(Pixmap::from_parts(data, width as u16, height as u16))
}

/// Straight-alpha RGBA8 to premultiplied, rounding to nearest: ONE rule,
/// so a decoded asset hashes alike everywhere.
fn premultiply(rgba: &mut [u8]) {
    for p in rgba.chunks_exact_mut(4) {
        let a = u32::from(p[3]);
        if a == 255 {
            continue;
        }
        for c in &mut p[..3] {
            *c = ((u32::from(*c) * a + 127) / 255) as u8;
        }
    }
}

/// An image's bytes decoded IN THE CORE, so a drawing that names it is one
/// canonical hash on five platforms: PNG or JPEG, colour taken as sRGB
/// (embedded profiles are not applied). `Err` carries the reason and the
/// decoder's sentence.
pub(crate) fn decode(bytes: &[u8]) -> Result<Pixmap, (MediaFailure, String)> {
    let (width, height, mut rgba) = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        decode_png(bytes).map_err(|e| (MediaFailure::DecodeError, format!("kaya: the PNG would not decode: {e}")))?
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        decode_jpeg(bytes)
            .map_err(|e| (MediaFailure::DecodeError, format!("kaya: the JPEG would not decode: {e}")))?
    } else {
        let head: Vec<String> = bytes.iter().take(8).map(|b| format!("{b:02X}")).collect();
        return Err((
            MediaFailure::UnsupportedContainer,
            format!(
                "kaya: {} bytes beginning {} are neither PNG nor JPEG, the two image formats kaya \
                 decodes",
                bytes.len(),
                head.join(" ")
            ),
        ));
    };
    premultiply(&mut rgba);
    pixmap(width, height, &rgba).map_err(|e| (MediaFailure::DecodeError, e))
}

fn decode_png(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), String> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().map_err(|e| e.to_string())?;
    let size = reader.output_buffer_size().ok_or("the PNG's size overflows")?;
    let mut buf = vec![0u8; size];
    let info = reader.next_frame(&mut buf).map_err(|e| e.to_string())?;
    let (w, h) = (info.width, info.height);
    let n = w as usize * h as usize;
    let src = &buf[..info.buffer_size()];
    let rgba = match info.color_type {
        png::ColorType::Rgba => src.to_vec(),
        png::ColorType::Rgb => src.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        png::ColorType::GrayscaleAlpha => src.chunks_exact(2).flat_map(|p| [p[0], p[0], p[0], p[1]]).collect(),
        png::ColorType::Grayscale => src.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        png::ColorType::Indexed => return Err("an indexed PNG survived EXPAND".to_owned()),
    };
    if rgba.len() != n * 4 {
        return Err(format!("the PNG decoded to {} bytes for {w}x{h}", rgba.len()));
    }
    Ok((w, h, rgba))
}

fn decode_jpeg(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), String> {
    let options = zune_jpeg::zune_core::options::DecoderOptions::default()
        .jpeg_set_out_colorspace(zune_jpeg::zune_core::colorspace::ColorSpace::RGBA);
    let mut decoder = zune_jpeg::JpegDecoder::new_with_options(std::io::Cursor::new(bytes), options);
    let pixels = decoder.decode().map_err(|e| format!("{e:?}"))?;
    let (w, h) = decoder.dimensions().ok_or("the JPEG names no size")?;
    Ok((w as u32, h as u32, pixels))
}

#[derive(Debug, Clone)]
enum Slot {
    /// Reserved by a read_frames whose answer has not arrived.
    Pending { reader: ReaderId, read: ReadId },
    Ready(Arc<Pixmap>),
    /// No picture: the load or the read's sentence.
    Empty(String),
    Released,
}

/// What a backend reports about one read, in its platform's terms.
pub(crate) enum Report<'a> {
    /// Time `index` answered with premultiplied RGBA8 pixels.
    Frame { index: u32, actual_ms: u64, width: u32, height: u32, pixels: &'a [u8] },
    /// Interleaved float PCM at the track's own channel count; `total_ms`
    /// the track's duration, 0 if unknown.
    Pcm { channels: u32, sample_rate: u32, samples: &'a [f32], total_ms: u64 },
    /// The platform has nothing more for this read.
    Finished,
    Failed { domain: String, code: i64, underlying: i64, detail: String },
    /// The backend's timer, TIMEOUT_MS after the ask or the last answer.
    Overdue,
}

/// The audiowaveform reduction (docs/probes/media-extraction-2026-10-01.md):
/// per channel, the min and max 16-bit sample of each `samples_per_pair`
/// frames, the last pair from whatever frames remain.
struct PeakSum {
    samples_per_pair: u32,
    channels: u32,
    sample_rate: u32,
    in_pair: u32,
    current: Vec<(i16, i16)>,
    data: Vec<i16>,
    frames: u64,
}

/// One float sample as the 16-bit value it came from: an s16 source decoded
/// to float is v/32768 exactly, so this is the identity on it.
pub(crate) fn sample_i16(s: f32) -> i16 {
    ((s * 32768.0).round() as i32).clamp(-32768, 32767) as i16
}

impl PeakSum {
    fn new(samples_per_pair: u32) -> Self {
        PeakSum {
            samples_per_pair,
            channels: 0,
            sample_rate: 0,
            in_pair: 0,
            current: Vec::new(),
            data: Vec::new(),
            frames: 0,
        }
    }

    fn feed(&mut self, channels: u32, sample_rate: u32, samples: &[f32]) {
        if self.channels == 0 {
            assert!(channels > 0 && sample_rate > 0, "kaya: a PCM report of {channels} channels at {sample_rate} Hz");
            self.channels = channels;
            self.sample_rate = sample_rate;
            self.current = vec![(i16::MAX, i16::MIN); channels as usize];
        }
        assert!(
            channels == self.channels && sample_rate == self.sample_rate,
            "kaya: a peaks read's PCM changed shape mid-track, {} channels at {} Hz then {channels} at \
             {sample_rate}",
            self.channels,
            self.sample_rate
        );
        assert!(
            samples.len() % channels as usize == 0,
            "kaya: {} PCM samples are not whole frames of {channels} channels",
            samples.len()
        );
        for frame in samples.chunks_exact(channels as usize) {
            for (c, s) in frame.iter().enumerate() {
                let v = sample_i16(*s);
                let (lo, hi) = &mut self.current[c];
                *lo = (*lo).min(v);
                *hi = (*hi).max(v);
            }
            self.in_pair += 1;
            self.frames += 1;
            if self.in_pair == self.samples_per_pair {
                self.close_pair();
            }
        }
    }

    fn close_pair(&mut self) {
        for (lo, hi) in &mut self.current {
            self.data.push(*lo);
            self.data.push(*hi);
            *lo = i16::MAX;
            *hi = i16::MIN;
        }
        self.in_pair = 0;
    }

    fn done_ms(&self) -> u64 {
        if self.sample_rate == 0 { 0 } else { self.frames * 1000 / u64::from(self.sample_rate) }
    }

    fn finish(mut self) -> Peaks {
        if self.in_pair > 0 {
            self.close_pair();
        }
        Peaks {
            sample_rate: self.sample_rate,
            samples_per_pair: self.samples_per_pair,
            channels: self.channels,
            data: self.data,
        }
    }
}

enum Kind {
    Frames { times: Vec<u64>, first: u64, answered: Vec<bool> },
    Peaks { sum: PeakSum, total_ms: u64, tenth: u64 },
}

struct Read {
    id: ReadId,
    /// The ask, then each answer: the bound runs from the latest.
    last: Instant,
    kind: Kind,
}

struct Reader {
    /// A source the core refused before any backend saw it: every read
    /// answers failed with this.
    refused: Option<(MediaFailure, String)>,
    read: Option<Read>,
}

/// Every reader, the image table, and each reader's last peaks for the ring
/// consumers' pull, held by the scene.
#[derive(Default)]
pub(crate) struct Readers {
    readers: HashMap<ReaderId, Reader>,
    images: HashMap<ImageId, Slot>,
    peaks: HashMap<ReaderId, (ReadId, Peaks)>,
    /// Added to the clock, so a unit test can pass the bound.
    skew: Duration,
}

fn done(reader: ReaderId, read: ReadId, outcome: ReadOutcome) -> Occurrence {
    Occurrence::ReaderDone { reader, read, outcome }
}

impl Readers {
    fn now(&self) -> Instant {
        Instant::now() + self.skew
    }

    fn live_mut(&mut self, reader: ReaderId, what: &str) -> &mut Reader {
        self.readers.get_mut(&reader).unwrap_or_else(|| {
            panic!("kaya: {what} names reader {}, which is not open — open_reader first", reader.0)
        })
    }

    pub(crate) fn open(&mut self, reader: ReaderId, source: Value, out: &mut Vec<ApplyOp>) {
        assert!(reader.0 != 0, "kaya: reader id 0 is reserved");
        assert!(
            !self.readers.contains_key(&reader),
            "kaya: reader {} is already open — close_reader first",
            reader.0
        );
        let resolved = match &source {
            Value::Str(s) if s.is_empty() => {
                panic!("kaya: open_reader {} names no source; a reader opens on an asset, a URL or a picked file", reader.0)
            }
            Value::Str(s) => crate::media::resolve_source(s),
            Value::I64(handle) => crate::media::resolve_picked(&format!("reader {}", reader.0), *handle),
            other => panic!(
                "kaya: open_reader {} source is {other:?}; a source is an asset name or URL (Str) or a \
                 picked file's handle (I64)",
                reader.0
            ),
        };
        let refused = match resolved {
            Resolved::Url { url } => {
                out.push(ApplyOp::OpenReader { reader, url });
                None
            }
            Resolved::Refused(why, detail) => Some((why, detail)),
            Resolved::None => unreachable!("an empty source was refused above"),
        };
        self.readers.insert(reader, Reader { refused, read: None });
    }

    fn start(
        &mut self,
        reader: ReaderId,
        read: ReadId,
        what: &str,
        kind: Kind,
        reserved: &[ImageId],
        published: &mut Vec<Occurrence>,
    ) -> bool {
        let now = self.now();
        let r = self.live_mut(reader, what);
        if let Some(running) = &r.read {
            panic!(
                "kaya: {what} {} on reader {} while read {} is still running — one read is in flight \
                 per reader, and nothing is cancelled implicitly: cancel_read it or wait for its \
                 reader_done",
                read.0, reader.0, running.id.0
            );
        }
        if let Some((why, detail)) = r.refused.clone() {
            for id in reserved {
                self.images.insert(*id, Slot::Empty(format!("its read {} failed {}: {detail}", read.0, why.name())));
            }
            published.push(done(reader, read, ReadOutcome::Failed(why, detail)));
            return false;
        }
        r.read = Some(Read { id: read, last: now, kind });
        for id in reserved {
            self.images.insert(*id, Slot::Pending { reader, read });
        }
        true
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn frames(
        &mut self,
        reader: ReaderId,
        read: ReadId,
        first_image: ImageId,
        accuracy: FrameAccuracy,
        max_size: (u32, u32),
        times_ms: Vec<u64>,
        out: &mut Vec<ApplyOp>,
        published: &mut Vec<Occurrence>,
    ) {
        assert!(!times_ms.is_empty(), "kaya: read_frames {} on reader {} asks for no times", read.0, reader.0);
        assert!(first_image.0 != 0, "kaya: read_frames {}'s first_image is 0, which is reserved", read.0);
        let reserved: Vec<ImageId> = (0..times_ms.len() as u64)
            .map(|i| {
                let id = first_image.0.checked_add(i).expect("kaya: read_frames' image ids overflow u64");
                ImageId(id)
            })
            .collect();
        for id in &reserved {
            if matches!(self.images.get(id), Some(Slot::Pending { .. } | Slot::Ready(_) | Slot::Empty(_))) {
                panic!(
                    "kaya: read_frames {} would put frame {} in image {}, which is live — release_image \
                     it first or start the run elsewhere",
                    read.0,
                    id.0 - first_image.0,
                    id.0
                );
            }
        }
        let n = times_ms.len();
        let kind = Kind::Frames { times: times_ms.clone(), first: first_image.0, answered: vec![false; n] };
        if self.start(reader, read, "read_frames", kind, &reserved, published) {
            out.push(ApplyOp::ReadFrames { reader, read, accuracy, max_size, times_ms });
        }
    }

    pub(crate) fn peaks(
        &mut self,
        reader: ReaderId,
        read: ReadId,
        samples_per_pair: u32,
        out: &mut Vec<ApplyOp>,
        published: &mut Vec<Occurrence>,
    ) {
        assert!(
            samples_per_pair > 0,
            "kaya: read_peaks {} on reader {} asks for 0 samples per pair",
            read.0,
            reader.0
        );
        let kind = Kind::Peaks { sum: PeakSum::new(samples_per_pair), total_ms: 0, tenth: 0 };
        if self.start(reader, read, "read_peaks", kind, &[], published) {
            self.peaks.remove(&reader);
            out.push(ApplyOp::ReadPeaks { reader, read });
        }
    }

    fn empty_pending(&mut self, reader: ReaderId, read: ReadId, why: &str) {
        for slot in self.images.values_mut() {
            if matches!(slot, Slot::Pending { reader: r, read: q } if *r == reader && *q == read) {
                *slot = Slot::Empty(why.to_owned());
            }
        }
    }

    pub(crate) fn cancel(
        &mut self,
        reader: ReaderId,
        read: ReadId,
        out: &mut Vec<ApplyOp>,
        published: &mut Vec<Occurrence>,
    ) {
        let r = self.live_mut(reader, "cancel_read");
        if r.read.as_ref().map(|q| q.id) != Some(read) {
            return;
        }
        r.read = None;
        out.push(ApplyOp::CancelRead { reader, read });
        self.empty_pending(reader, read, &format!("its read {} was cancelled", read.0));
        published.push(done(reader, read, ReadOutcome::Cancelled));
    }

    pub(crate) fn close(&mut self, reader: ReaderId, out: &mut Vec<ApplyOp>, published: &mut Vec<Occurrence>) {
        let r = self.readers.remove(&reader).unwrap_or_else(|| {
            panic!("kaya: close_reader names reader {}, which is not open", reader.0)
        });
        self.peaks.remove(&reader);
        if let Some(read) = r.read {
            self.empty_pending(reader, read.id, &format!("its reader {} was closed", reader.0));
            published.push(done(reader, read.id, ReadOutcome::Cancelled));
        }
        if r.refused.is_none() {
            out.push(ApplyOp::CloseReader(reader));
        }
    }

    pub(crate) fn load_image(&mut self, image: ImageId, source: Value, published: &mut Vec<Occurrence>) {
        assert!(image.0 != 0, "kaya: image id 0 is reserved");
        assert!(
            matches!(self.images.get(&image), None | Some(Slot::Released)),
            "kaya: load_image {} names a live image — release_image it first",
            image.0
        );
        let bytes = match &source {
            Value::Str(s) if s.to_ascii_lowercase().starts_with("http://")
                || s.to_ascii_lowercase().starts_with("https://") =>
            {
                panic!(
                    "kaya: load_image {} names the URL {s}; an image loads from an asset or a picked \
                     file, and kaya fetches none (a reader's frames come from a URL)",
                    image.0
                )
            }
            Value::Str(name) => crate::assets::read(name).map_err(|why| (MediaFailure::NotFound, why)),
            Value::I64(handle) => {
                use std::io::Read;
                let source = crate::media::picked(&format!("image {}", image.0), "source", *handle);
                let mut bytes = Vec::new();
                source
                    .open(crate::protocol::FileMode::Read)
                    .and_then(|(raw, _)| unsafe { crate::protocol::file_from_raw(raw) }.read_to_end(&mut bytes))
                    .map(|_| bytes)
                    .map_err(|e| {
                        (
                            MediaFailure::NotFound,
                            format!(
                                "kaya: the picked file {:?} would not open: {e}",
                                crate::protocol::PickedSource::name(&*source)
                            ),
                        )
                    })
            }
            other => panic!(
                "kaya: load_image {} source is {other:?}; an image comes from an asset name (Str) or a \
                 picked file's handle (I64)",
                image.0
            ),
        };
        let decoded = bytes.and_then(|b| decode(&b));
        let occurrence = match decoded {
            Ok(pixmap) => {
                let (width, height) = (u32::from(pixmap.width()), u32::from(pixmap.height()));
                self.images.insert(image, Slot::Ready(Arc::new(pixmap)));
                Occurrence::ImageLoaded { image, width, height, failure: None }
            }
            Err((why, detail)) => {
                self.images.insert(image, Slot::Empty(format!("its load failed {}: {detail}", why.name())));
                Occurrence::ImageLoaded { image, width: 0, height: 0, failure: Some((why, detail)) }
            }
        };
        published.push(occurrence);
    }

    pub(crate) fn release_image(&mut self, image: ImageId) {
        match self.images.get_mut(&image) {
            None => panic!("kaya: release_image {} names an image that was never created", image.0),
            Some(Slot::Released) => panic!("kaya: release_image {} releases it a second time", image.0),
            Some(slot) => *slot = Slot::Released,
        }
    }

    pub(crate) fn lookup(&self, id: i64) -> Result<Arc<Pixmap>, String> {
        let slot = u64::try_from(id).ok().and_then(|id| self.images.get(&ImageId(id)));
        match slot {
            Some(Slot::Ready(pixmap)) => Ok(pixmap.clone()),
            Some(Slot::Pending { reader, read }) => Err(format!(
                "kaya: the canvas op `image` names image {id}, which read {} on reader {} has not \
                 answered yet — draw it once its reader_frame is heard",
                read.0, reader.0
            )),
            Some(Slot::Empty(why)) => {
                Err(format!("kaya: the canvas op `image` names image {id}, which holds no picture: {why}"))
            }
            Some(Slot::Released) => Err(format!("kaya: the canvas op `image` names image {id}, which was released")),
            None => Err(format!(
                "kaya: the canvas op `image` names image {id}, which was never created — an image comes \
                 from load_image or a read_frames"
            )),
        }
    }

    pub(crate) fn peaks_of(&self, reader: ReaderId, read: ReadId) -> Option<&Peaks> {
        self.peaks.get(&reader).filter(|(id, _)| *id == read).map(|(_, p)| p)
    }

    pub(crate) fn pixels(&self, image: ImageId) -> Option<(u32, u32, Vec<u8>)> {
        match self.images.get(&image) {
            Some(Slot::Ready(p)) => Some((
                u32::from(p.width()),
                u32::from(p.height()),
                p.data_as_u8_slice().to_vec(),
            )),
            _ => None,
        }
    }

    /// A backend's report: what the app hears, and whether the read is
    /// still the reader's (for Overdue, whether this report failed it).
    pub(crate) fn report(&mut self, reader: ReaderId, read: ReadId, report: Report<'_>) -> (Vec<Occurrence>, bool) {
        let now = self.now();
        let mut published = Vec::new();
        let Some(r) = self.readers.get_mut(&reader) else { return (published, false) };
        let Some(q) = r.read.as_mut().filter(|q| q.id == read) else { return (published, false) };
        let mut outcome = None;
        let mut overdue = false;
        let mut finished_peaks = false;
        let asked_overdue = matches!(report, Report::Overdue);
        match (report, &mut q.kind) {
            (Report::Frame { index, actual_ms, width, height, pixels }, Kind::Frames { times, first, answered }) => {
                let i = index as usize;
                assert!(
                    i < times.len() && !answered[i],
                    "kaya: reader {} read {} answered time {index} {} — it asked {} times",
                    reader.0,
                    read.0,
                    if i < times.len() { "twice" } else { "that was never asked" },
                    times.len()
                );
                answered[i] = true;
                q.last = now;
                let image = ImageId(*first + u64::from(index));
                let pixmap = pixmap(width, height, pixels).unwrap_or_else(|why| {
                    panic!("kaya: reader {} read {} time {index}: {why}", reader.0, read.0)
                });
                if !matches!(self.images.get(&image), Some(Slot::Released)) {
                    self.images.insert(image, Slot::Ready(Arc::new(pixmap)));
                }
                published.push(Occurrence::ReaderFrame {
                    reader,
                    read,
                    index,
                    image,
                    width,
                    height,
                    requested_ms: times[i],
                    actual_ms,
                });
                if answered.iter().all(|a| *a) {
                    outcome = Some(ReadOutcome::Completed);
                }
            }
            (Report::Pcm { channels, sample_rate, samples, total_ms }, Kind::Peaks { sum, total_ms: total, tenth }) => {
                q.last = now;
                sum.feed(channels, sample_rate, samples);
                *total = total_ms;
                if total_ms > 0 {
                    let reached = (sum.done_ms().min(total_ms) * 10 / total_ms).min(10);
                    if reached > *tenth {
                        *tenth = reached;
                        published.push(Occurrence::ReaderProgress {
                            reader,
                            read,
                            done_ms: sum.done_ms().min(total_ms),
                            total_ms,
                        });
                    }
                }
            }
            (Report::Finished, Kind::Frames { answered, .. }) => {
                let got = answered.iter().filter(|a| **a).count();
                outcome = Some(ReadOutcome::Failed(
                    MediaFailure::DecodeError,
                    format!("kaya: the platform finished after answering {got} of {} times", answered.len()),
                ));
            }
            (Report::Finished, Kind::Peaks { .. }) => finished_peaks = true,
            (Report::Failed { domain, code, underlying, detail }, _) => {
                outcome = Some(ReadOutcome::Failed(crate::media::failure_reason(&domain, code, underlying), detail));
            }
            (Report::Overdue, _) => {
                let quiet = now.saturating_duration_since(q.last);
                if quiet + Duration::from_millis(TIMEOUT_SLACK_MS) >= Duration::from_millis(TIMEOUT_MS) {
                    overdue = true;
                    outcome = Some(ReadOutcome::Failed(
                        MediaFailure::Timeout,
                        format!(
                            "kaya: read {} on reader {} heard nothing from the platform for {} ms, past \
                             the {TIMEOUT_MS} ms bound",
                            read.0,
                            reader.0,
                            quiet.as_millis()
                        ),
                    ));
                }
            }
            (Report::Frame { .. }, Kind::Peaks { .. }) | (Report::Pcm { .. }, Kind::Frames { .. }) => panic!(
                "kaya: reader {} read {} reported the other kind of answer than it asked for",
                reader.0, read.0
            ),
        }
        if finished_peaks {
            let Some(Read { kind: Kind::Peaks { sum, .. }, .. }) = r.read.take() else { unreachable!() };
            let peaks = sum.finish();
            published.push(Occurrence::ReaderPeaks { reader, read, peaks: peaks.clone() });
            self.peaks.insert(reader, (read, peaks));
            published.push(done(reader, read, ReadOutcome::Completed));
            return (published, false);
        }
        let Some(outcome) = outcome else { return (published, !asked_overdue) };
        r.read = None;
        if let ReadOutcome::Failed(why, detail) = &outcome {
            self.empty_pending(reader, read, &format!("its read {} failed {}: {detail}", read.0, why.name()));
        }
        published.push(done(reader, read, outcome));
        (published, overdue)
    }

    #[cfg(test)]
    fn pass(&mut self, ms: u64) {
        self.skew += Duration::from_millis(ms);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const R: ReaderId = ReaderId(3);

    fn open(local: &str) -> (Readers, Vec<ApplyOp>) {
        let _g = crate::assets::serially();
        let mut rs = Readers::default();
        let mut out = Vec::new();
        rs.open(R, Value::Str(local.to_owned()), &mut out);
        (rs, out)
    }

    fn frames(rs: &mut Readers, read: u64, first: u64, times: &[u64]) -> (Vec<ApplyOp>, Vec<Occurrence>) {
        let (mut out, mut published) = (Vec::new(), Vec::new());
        rs.frames(R, ReadId(read), ImageId(first), FrameAccuracy::Exact, (64, 0), times.to_vec(), &mut out, &mut published);
        (out, published)
    }

    fn px(w: u32, h: u32, v: u8) -> Vec<u8> {
        vec![v; (w * h * 4) as usize]
    }

    fn frame(rs: &mut Readers, read: u64, index: u32, actual: u64, pixels: &[u8]) -> (Vec<Occurrence>, bool) {
        rs.report(R, ReadId(read), Report::Frame { index, actual_ms: actual, width: 2, height: 1, pixels })
    }

    fn refused(body: impl FnOnce(), needle: &str) {
        let failure = std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)).expect_err("no refusal");
        let message = failure
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| failure.downcast_ref::<&str>().map(|s| (*s).to_owned()))
            .unwrap();
        assert!(message.contains(needle), "{message}");
    }

    #[test]
    fn the_peaks_are_audiowaveforms_min_and_max_per_channel_per_pair() {
        let mut sum = PeakSum::new(3);
        let s = |v: i16| f32::from(v) / 32768.0;
        // Two channels, seven frames: two whole pairs and a last one of one frame.
        let frames: [(i16, i16); 7] = [(1, -1), (5, 0), (-3, 2), (32767, -32768), (0, 0), (7, 9), (-2, 4)];
        let interleaved: Vec<f32> = frames.iter().flat_map(|(a, b)| [s(*a), s(*b)]).collect();
        sum.feed(2, 48000, &interleaved[..6]);
        sum.feed(2, 48000, &interleaved[6..]);
        let peaks = sum.finish();
        assert_eq!((peaks.channels, peaks.samples_per_pair, peaks.sample_rate, peaks.len()), (2, 3, 48000, 3));
        assert_eq!(peaks.pair(0, 0), (-3, 5));
        assert_eq!(peaks.pair(0, 1), (-1, 2));
        assert_eq!(peaks.pair(1, 0), (0, 32767));
        assert_eq!(peaks.pair(1, 1), (-32768, 9));
        assert_eq!(peaks.pair(2, 0), (-2, -2));
        assert_eq!(peaks.pair(2, 1), (4, 4));
    }

    #[test]
    fn a_float_sample_from_sixteen_bits_reads_back_exactly() {
        for v in [i16::MIN, -12345, -1, 0, 1, 4096, i16::MAX] {
            assert_eq!(sample_i16(f32::from(v) / 32768.0), v);
        }
        assert_eq!(sample_i16(2.0), i16::MAX);
        assert_eq!(sample_i16(-2.0), i16::MIN);
    }

    #[test]
    fn frames_answer_in_any_order_then_complete_once() {
        let (mut rs, out) = open("media/h264_frames.mp4");
        assert!(matches!(out.as_slice(), [ApplyOp::OpenReader { url, .. }] if url.starts_with("file://")));
        let (out, published) = frames(&mut rs, 9, 100, &[480, 1480]);
        assert!(published.is_empty());
        assert!(matches!(out.as_slice(), [ApplyOp::ReadFrames { times_ms, .. }] if *times_ms == vec![480, 1480]));
        assert!(rs.lookup(101).unwrap_err().contains("has not answered yet"));
        let (heard, live) = frame(&mut rs, 9, 1, 1480, &px(2, 1, 80));
        assert!(live);
        assert!(matches!(
            heard.as_slice(),
            [Occurrence::ReaderFrame { index: 1, image: ImageId(101), requested_ms: 1480, actual_ms: 1480, .. }]
        ));
        let (heard, live) = frame(&mut rs, 9, 0, 0, &px(2, 1, 160));
        assert!(!live);
        assert!(matches!(
            heard.as_slice(),
            [
                Occurrence::ReaderFrame { index: 0, image: ImageId(100), requested_ms: 480, actual_ms: 0, .. },
                Occurrence::ReaderDone { outcome: ReadOutcome::Completed, .. },
            ]
        ));
        assert_eq!(rs.pixels(ImageId(100)).unwrap(), (2, 1, px(2, 1, 160)));
        let (heard, live) = frame(&mut rs, 9, 1, 1480, &px(2, 1, 80));
        assert!(heard.is_empty() && !live, "a finished read hears nothing more");
    }

    #[test]
    fn one_read_in_flight_per_reader() {
        let (mut rs, _) = open("media/h264_frames.mp4");
        frames(&mut rs, 1, 10, &[0]);
        refused(|| drop(frames(&mut rs, 2, 20, &[0])), "while read 1 is still running");
        refused(|| drop(frames(&mut Readers::default(), 1, 1, &[0])), "which is not open");
    }

    #[test]
    fn a_reserved_image_must_not_be_live() {
        let (mut rs, _) = open("media/h264_frames.mp4");
        frames(&mut rs, 1, 10, &[0, 40]);
        let (mut out, mut published) = (Vec::new(), Vec::new());
        rs.cancel(R, ReadId(1), &mut out, &mut published);
        refused(|| drop(frames(&mut rs, 2, 11, &[0])), "which is live");
        rs.release_image(ImageId(10));
        rs.release_image(ImageId(11));
        let (out, _) = frames(&mut rs, 2, 10, &[0]);
        assert_eq!(out.len(), 1);
    }

    #[test]
    fn a_cancel_answers_at_once_and_drops_what_follows() {
        let (mut rs, _) = open("media/h264_frames.mp4");
        frames(&mut rs, 4, 50, &[0, 40]);
        let (mut out, mut published) = (Vec::new(), Vec::new());
        rs.cancel(R, ReadId(4), &mut out, &mut published);
        assert!(matches!(out.as_slice(), [ApplyOp::CancelRead { read: ReadId(4), .. }]));
        assert!(matches!(published.as_slice(), [Occurrence::ReaderDone { outcome: ReadOutcome::Cancelled, .. }]));
        let (heard, live) = frame(&mut rs, 4, 0, 0, &px(2, 1, 1));
        assert!(heard.is_empty() && !live);
        assert!(rs.lookup(50).unwrap_err().contains("was cancelled"));
        let (mut out, mut published) = (Vec::new(), Vec::new());
        rs.cancel(R, ReadId(4), &mut out, &mut published);
        assert!(out.is_empty() && published.is_empty(), "cancelling a finished read is not an error");
    }

    #[test]
    fn closing_the_reader_cancels_its_read() {
        let (mut rs, _) = open("media/h264_frames.mp4");
        frames(&mut rs, 4, 50, &[0]);
        let (mut out, mut published) = (Vec::new(), Vec::new());
        rs.close(R, &mut out, &mut published);
        assert!(matches!(out.as_slice(), [ApplyOp::CloseReader(R)]));
        assert!(matches!(published.as_slice(), [Occurrence::ReaderDone { outcome: ReadOutcome::Cancelled, .. }]));
        assert!(rs.lookup(50).unwrap_err().contains("was closed"));
    }

    #[test]
    fn a_missing_local_source_fails_every_read_without_the_platform() {
        let (mut rs, out) = open("media/missing.mp4");
        assert!(out.is_empty());
        let (out, published) = frames(&mut rs, 1, 5, &[0]);
        assert!(out.is_empty());
        assert!(matches!(
            published.as_slice(),
            [Occurrence::ReaderDone { outcome: ReadOutcome::Failed(MediaFailure::NotFound, _), .. }]
        ));
        assert!(rs.lookup(5).unwrap_err().contains("failed not_found"));
        let (mut out, mut published) = (Vec::new(), Vec::new());
        rs.close(R, &mut out, &mut published);
        assert!(out.is_empty(), "a reader the platform never saw is not closed there");
    }

    #[test]
    fn the_platforms_failure_reads_through_the_players_table() {
        let (mut rs, _) = open("media/h264_frames.mp4");
        frames(&mut rs, 2, 7, &[0]);
        let (heard, _) = rs.report(
            R,
            ReadId(2),
            Report::Failed {
                domain: "AVFoundationErrorDomain".to_owned(),
                code: -11828,
                underlying: 0,
                detail: "This media format is not supported.".to_owned(),
            },
        );
        assert!(matches!(
            heard.as_slice(),
            [Occurrence::ReaderDone { outcome: ReadOutcome::Failed(MediaFailure::UnsupportedContainer, _), .. }]
        ));
    }

    #[test]
    fn the_bound_runs_from_the_latest_answer() {
        let (mut rs, _) = open("media/h264_frames.mp4");
        frames(&mut rs, 2, 7, &[0, 40]);
        rs.pass(TIMEOUT_MS - 1000);
        let (heard, failed) = rs.report(R, ReadId(2), Report::Overdue);
        assert!(heard.is_empty() && !failed, "inside the bound");
        frame(&mut rs, 2, 0, 0, &px(2, 1, 1));
        rs.pass(TIMEOUT_MS - 1000);
        let (heard, failed) = rs.report(R, ReadId(2), Report::Overdue);
        assert!(heard.is_empty() && !failed, "the answer restarted the bound");
        rs.pass(1000);
        let (heard, failed) = rs.report(R, ReadId(2), Report::Overdue);
        assert!(failed);
        assert!(matches!(
            heard.as_slice(),
            [Occurrence::ReaderDone { outcome: ReadOutcome::Failed(MediaFailure::Timeout, _), .. }]
        ));
        assert!(rs.lookup(8).unwrap_err().contains("failed timeout"));
    }

    #[test]
    fn a_peaks_read_reports_progress_by_tenths_then_its_peaks() {
        let (mut rs, _) = open("media/tone.wav");
        let (mut out, mut published) = (Vec::new(), Vec::new());
        rs.peaks(R, ReadId(6), 100, &mut out, &mut published);
        assert!(matches!(out.as_slice(), [ApplyOp::ReadPeaks { .. }]));
        let chunk = vec![0.25f32; 1000];
        let mut progress = Vec::new();
        for _ in 0..10 {
            let (heard, live) =
                rs.report(R, ReadId(6), Report::Pcm { channels: 1, sample_rate: 1000, samples: &chunk, total_ms: 10_000 });
            assert!(live);
            progress.extend(heard);
        }
        assert_eq!(progress.len(), 10);
        assert!(matches!(progress[0], Occurrence::ReaderProgress { done_ms: 1000, total_ms: 10_000, .. }));
        let (heard, live) = rs.report(R, ReadId(6), Report::Finished);
        assert!(!live);
        match heard.as_slice() {
            [Occurrence::ReaderPeaks { peaks, .. }, Occurrence::ReaderDone { outcome: ReadOutcome::Completed, .. }] => {
                assert_eq!(peaks.len(), 100);
                assert_eq!(peaks.pair(99, 0), (8192, 8192));
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(rs.peaks_of(R, ReadId(6)).map(Peaks::len), Some(100));
    }

    #[test]
    fn the_image_table_says_why_a_drawing_cannot_have_an_image() {
        let mut rs = Readers::default();
        assert!(rs.lookup(4).unwrap_err().contains("never created"));
        let mut published = Vec::new();
        {
            let _g = crate::assets::serially();
            rs.load_image(ImageId(4), Value::Str("images/a11y-logo.png".to_owned()), &mut published);
            rs.load_image(ImageId(5), Value::Str("images/photo.jpg".to_owned()), &mut published);
            rs.load_image(ImageId(6), Value::Str("images/nope.png".to_owned()), &mut published);
            rs.load_image(ImageId(7), Value::Str("media/captions.vtt".to_owned()), &mut published);
        }
        assert!(matches!(
            published.as_slice(),
            [
                Occurrence::ImageLoaded { width: 2, height: 2, failure: None, .. },
                Occurrence::ImageLoaded { width: 800, height: 600, failure: None, .. },
                Occurrence::ImageLoaded { failure: Some((MediaFailure::NotFound, _)), .. },
                Occurrence::ImageLoaded { failure: Some((MediaFailure::UnsupportedContainer, _)), .. },
            ]
        ));
        let (_, _, logo) = rs.pixels(ImageId(4)).unwrap();
        assert_eq!(logo, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]);
        assert!(rs.lookup(4).is_ok());
        assert!(rs.lookup(6).unwrap_err().contains("failed not_found"));
        rs.release_image(ImageId(4));
        assert!(rs.lookup(4).unwrap_err().contains("was released"));
        refused(|| rs.release_image(ImageId(4)), "a second time");
        refused(|| rs.release_image(ImageId(40)), "never created");
    }

    /// A PNG carries straight alpha and the canvas draws premultiplied, so
    /// the decode converts (a translucent pixel is the only one that shows).
    #[test]
    fn a_decoded_png_is_premultiplied() {
        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, 1, 1);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            encoder.write_header().unwrap().write_image_data(&[200, 100, 3, 128]).unwrap();
        }
        let image = decode(&bytes).unwrap();
        assert_eq!(image.data_as_u8_slice(), [100, 50, 2, 128]);
    }

    #[test]
    fn straight_alpha_is_premultiplied_by_one_rounding() {
        let mut p = [200, 100, 3, 128, 9, 9, 9, 255, 255, 255, 255, 0];
        premultiply(&mut p);
        assert_eq!(p, [100, 50, 2, 128, 9, 9, 9, 255, 0, 0, 0, 0]);
    }

    /// tools/scenes/media_reader.steps' waveform canvas, FROZEN FROM THE
    /// CORE: tone.wav's 16-bit samples read here without any platform, the
    /// peaks reduced by the same PeakSum, the guest's own op stream
    /// (guests/rust/media.rs reader_app) and the two images decoded by the
    /// core. The scene's hash, its drawing and its two ink points are this
    /// test's numbers; a platform's PCM that differs from the file's samples
    /// moves the scene and not this.
    #[test]
    fn the_reader_scene_waveform_is_derived_from_the_core() {
        use crate::canvas::{drawing_observation, probe, validate_with};
        let (wav, logo, photo) = {
            let _g = crate::assets::serially();
            (
                crate::assets::read("media/tone.wav").unwrap(),
                decode(&crate::assets::read("images/a11y-logo.png").unwrap()).unwrap(),
                decode(&crate::assets::read("images/photo.jpg").unwrap()).unwrap(),
            )
        };
        let data = wav.windows(4).position(|w| w == b"data").expect("tone.wav has a data chunk");
        let len = u32::from_le_bytes(wav[data + 4..data + 8].try_into().unwrap()) as usize;
        let samples: Vec<f32> = wav[data + 8..data + 8 + len]
            .chunks_exact(2)
            .map(|b| f32::from(i16::from_le_bytes([b[0], b[1]])) / 32768.0)
            .collect();
        let mut sum = PeakSum::new(4800);
        sum.feed(1, 48000, &samples);
        let peaks = sum.finish();
        let lows = (0..peaks.len()).map(|i| peaks.pair(i, 0).0).min().unwrap();
        let highs = (0..peaks.len()).map(|i| peaks.pair(i, 0).1).max().unwrap();
        assert_eq!((peaks.len(), lows, highs), (20, -4095, 4095), "the scene's peaks label");

        let (n, i64v) = (Value::F64, Value::I64);
        let mut ops = Vec::new();
        let y = |v: i16| 30.0 - f64::from(v) * 25.0 / 8192.0;
        for i in 0..peaks.len() {
            let (lo, hi) = peaks.pair(i, 0);
            let x = 8.0 + 7.0 * i as f64;
            ops.extend([i64v(crate::wire::DRAW_MOVE_TO), n(x), n(y(hi))]);
            ops.extend([i64v(crate::wire::DRAW_LINE_TO), n(x + 5.0), n(y(hi))]);
            ops.extend([i64v(crate::wire::DRAW_LINE_TO), n(x + 5.0), n(y(lo))]);
            ops.extend([i64v(crate::wire::DRAW_LINE_TO), n(x), n(y(lo))]);
            ops.push(i64v(crate::wire::DRAW_CLOSE));
            ops.extend([i64v(crate::wire::DRAW_FILL), i64v(crate::wire::PAINT_SERIES), i64v(crate::wire::FILL_NONZERO)]);
        }
        ops.extend([i64v(crate::wire::DRAW_IMAGE), i64v(1), n(150.0), n(4.0), n(20.0), n(20.0)]);
        ops.extend([i64v(crate::wire::DRAW_IMAGE), i64v(2), n(150.0), n(30.0), n(40.0), n(30.0)]);
        let (logo, photo) = (Arc::new(logo), Arc::new(photo));
        let table = |id: i64| match id {
            1 => Ok(logo.clone()),
            2 => Ok(photo.clone()),
            other => Err(format!("no image {other}")),
        };
        let drawing = validate_with((200.0, 60.0), &ops, &table).unwrap();
        let p = probe(&drawing);
        let (hash, seen) = (format!("{:016x}", p.hash), drawing_observation(&p));
        // The two ink points the scene reads, at the harness's own rounding:
        // a hundredth of the box, truncated, on the canonical 200x60 raster.
        let raster = crate::canvas::canonical_raster(&drawing);
        let at = |px: f64, py: f64| {
            let (x, y) = ((200.0 * px / 100.0) as usize, (60.0 * py / 100.0) as usize);
            let i = (y * 200 + x) * 4;
            format!("{:02X}{:02X}{:02X}", raster.pixels[i], raster.pixels[i + 1], raster.pixels[i + 2])
        };
        let ink = format!("{}/{}", at(76.0, 10.0), at(85.0, 92.0));
        eprintln!("media_reader wave: hash {hash} drawing {seen} ink {ink}");
        assert_eq!(seen, "122/4,7,95,100");
        assert_eq!(hash, "4dc19c1911f74793");
        assert_eq!(ink, "FF0000/306F9A");
    }
}
