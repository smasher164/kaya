//! THE READER ON WINDOWS (docs/media-plan.md §8 ruling 4): Media Foundation's
//! source reader on a thread per read, the one stream it needs selected and
//! every other deselected, NV12 out of the decoder converted only for the
//! frames kept (docs/probes/media-extraction-2026-10-01.md: converting every
//! decoded frame cost 38.7 s against 12.4 s), and the video edit list read by
//! kaya because Media Foundation ignores it (crates/kaya/src/edit_list.rs).
//! Every report reaches the core on the UI thread through `reader_report`.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
use windows_core::Interface;

use super::CoreState;
use crate::reader::{Flight, Owned, Then};

struct Reader {
    url: String,
    read: Option<(u64, Arc<Flight>)>,
    /// Bumped at every answer, so only the latest bound timer asks.
    answers: u64,
}

thread_local! {
    static READERS: RefCell<HashMap<u64, Reader>> = RefCell::new(HashMap::new());
}

/// The domain a Media Foundation HRESULT is reported under; the core's
/// failure table reads it (crate::media::failure_reason).
const DOMAIN: &str = "MediaFoundation";

struct Out {
    reader: u64,
    read: u64,
    flight: Arc<Flight>,
}

impl Out {
    fn send(&self, msg: Owned) {
        let (reader, read, flight) = (self.reader, self.read, self.flight.clone());
        super::media::post(move |core| reader_report(core, reader, read, &flight, msg));
    }

    fn wanted(&self) -> bool {
        self.flight.wanted()
    }

    /// THE ONE SITE a read for a track the source lacks is reported from;
    /// the core decides its reason (docs/deferred.md, the missing-track RULING).
    fn no_track(&self, kind: &str) {
        self.send(Owned::NoTrack(format!("kaya: the source has no {kind} track")));
    }

    fn failed(&self, what: &str, e: &windows_core::Error) {
        self.send(Owned::Failed {
            domain: DOMAIN.to_owned(),
            code: i64::from(e.code().0 as u32),
            underlying: 0,
            detail: format!("kaya: {what}: {} ({:#010X})", e.message(), e.code().0 as u32),
        });
    }
}

/// THE ONE DOOR every reader report takes: the core decides what the app
/// hears, and its answer stops the read or restarts the bound.
fn reader_report(core: &mut CoreState, reader: u64, read: u64, flight: &Flight, msg: Owned) {
    let (published, answer) =
        core.scene.reader_report(crate::protocol::ReaderId(reader), crate::protocol::ReadId(read), msg.report());
    for occ in published {
        core.occurrences.send(occ);
    }
    if matches!(msg, Owned::Pcm { .. }) {
        flight.taken();
    }
    match msg.then(answer) {
        Then::Stop => stop(reader, read),
        Then::Rebound => bound(reader, read),
        Then::Carry => {}
    }
}

/// The bound (docs/media-plan.md §7c) from the ask or the latest answer;
/// the core's clock decides.
fn bound(reader: u64, read: u64) {
    let Some((seen, flight)) = READERS.with_borrow_mut(|rs| {
        let r = rs.get_mut(&reader)?;
        let (current, flight) = r.read.as_ref()?;
        if *current != read {
            return None;
        }
        let flight = flight.clone();
        r.answers += 1;
        Some((r.answers, flight))
    }) else {
        return;
    };
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(crate::media::TIMEOUT_MS));
        if !flight.wanted() {
            return;
        }
        super::media::post(move |core| {
            let still = READERS.with_borrow(|rs| {
                rs.get(&reader).is_some_and(|r| r.answers == seen && r.read.as_ref().is_some_and(|(q, _)| *q == read))
            });
            if still {
                reader_report(core, reader, read, &flight, Owned::Overdue);
            }
        });
    });
}

fn stop(reader: u64, read: u64) {
    READERS.with_borrow_mut(|rs| {
        if let Some(r) = rs.get_mut(&reader) {
            if r.read.as_ref().is_some_and(|(q, _)| *q == read) {
                if let Some((_, flight)) = r.read.take() {
                    flight.stop();
                }
            }
        }
    });
}

pub(super) fn open(reader: u64, url: String) {
    READERS.with_borrow_mut(|rs| rs.insert(reader, Reader { url, read: None, answers: 0 }));
}

fn start(reader: u64, read: u64, work: impl FnOnce(&IMFSourceReader, &str, &Out) + Send + 'static, kind: &'static str) {
    let flight = Arc::new(Flight::default());
    let Some(url) = READERS.with_borrow_mut(|rs| {
        let r = rs.get_mut(&reader)?;
        r.read = Some((read, flight.clone()));
        Some(r.url.clone())
    }) else {
        return;
    };
    bound(reader, read);
    let out = Out { reader, read, flight };
    std::thread::spawn(move || {
        // SAFETY: this thread's own apartment and Media Foundation startup,
        // each ended with the thread's work.
        unsafe { super::CoInitializeEx(std::ptr::null(), 0x0) };
        if let Err(e) = unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) } {
            out.failed("Media Foundation would not start", &e);
            return;
        }
        match open_source(&url, kind) {
            Ok(Some(source)) => work(&source, &url, &out),
            Ok(None) => out.no_track(kind),
            Err(e) => out.failed(&format!("Media Foundation would not open {url}"), &e),
        }
        let _ = unsafe { MFShutdown() };
    });
}

/// A source reader with the first `kind` stream alone selected; `None` when
/// the source has no such stream.
fn open_source(url: &str, kind: &str) -> windows_core::Result<Option<IMFSourceReader>> {
    let path = crate::edit_list::file_url_path(url).map(|p| p.replace('/', "\\"));
    let wide = windows_core::HSTRING::from(path.as_deref().unwrap_or(url));
    let source = unsafe { MFCreateSourceReaderFromURL(&wide, None)? };
    let stream = if kind == "video" { MF_SOURCE_READER_FIRST_VIDEO_STREAM } else { MF_SOURCE_READER_FIRST_AUDIO_STREAM };
    unsafe { source.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false)? };
    match unsafe { source.SetStreamSelection(stream.0 as u32, true) } {
        Ok(()) => {}
        Err(e) if e.code() == MF_E_INVALIDSTREAMNUMBER => return Ok(None),
        Err(e) => return Err(e),
    }
    let wanted = unsafe { MFCreateMediaType()? };
    unsafe {
        if kind == "video" {
            wanted.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            wanted.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)?;
        } else {
            wanted.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
            wanted.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_Float)?;
        }
        source.SetCurrentMediaType(stream.0 as u32, None, &wanted)?;
    }
    Ok(Some(source))
}

pub(super) fn frames(reader: u64, read: u64, exact: bool, max: (u32, u32), times: Vec<u64>) {
    start(
        reader,
        read,
        move |source, url, out| {
            if let Err(e) = frames_read(source, url, exact, max, &times, out) {
                out.failed("reading frames", &e);
            }
        },
        "video",
    );
}

pub(super) fn peaks(reader: u64, read: u64) {
    start(
        reader,
        read,
        |source, _, out| {
            if let Err(e) = peaks_read(source, out) {
                out.failed("reading the audio", &e);
            }
        },
        "audio",
    );
}

pub(super) fn cancel(reader: u64, read: u64) {
    stop(reader, read);
}

pub(super) fn close(reader: u64) {
    if let Some(r) = READERS.with_borrow_mut(|rs| rs.remove(&reader)) {
        if let Some((_, flight)) = r.read {
            flight.stop();
        }
    }
}

const VIDEO: u32 = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
const AUDIO: u32 = MF_SOURCE_READER_FIRST_AUDIO_STREAM.0 as u32;

/// The video edit list's start, which Media Foundation's timestamps carry
/// and the picture's time does not (docs/traps.md, the edit-list entry).
fn shift_hns(url: &str) -> i64 {
    let Some(path) = crate::edit_list::file_url_path(url) else { return 0 };
    let read = std::fs::File::open(&path)
        .map_err(|e| format!("opening {path}: {e}"))
        .and_then(|f| crate::edit_list::video_shift(&mut crate::edit_list::LocalFile(f)));
    match read {
        Ok(Some(crate::edit_list::Shift(hns))) => hns,
        Ok(None) => 0,
        Err(why) => {
            eprintln!("KAYA_DIAG winui reader: {url}'s edit list was not read, so its times are not moved: {why}");
            0
        }
    }
}

struct Sample {
    sample: IMFSample,
    hns: i64,
}

/// The next video sample, `None` at the end of the stream.
fn next(source: &IMFSourceReader) -> windows_core::Result<Option<Sample>> {
    loop {
        let (mut flags, mut hns, mut sample) = (0u32, 0i64, None);
        unsafe { source.ReadSample(VIDEO, 0, None, Some(&mut flags), Some(&mut hns), Some(&mut sample))? };
        if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
            return Ok(None);
        }
        if let Some(sample) = sample {
            return Ok(Some(Sample { sample, hns }));
        }
    }
}

fn frames_read(
    source: &IMFSourceReader,
    url: &str,
    exact: bool,
    max: (u32, u32),
    times: &[u64],
    out: &Out,
) -> windows_core::Result<()> {
    let shift = shift_hns(url);
    for (index, t) in times.iter().enumerate() {
        if !out.wanted() {
            return Ok(());
        }
        let target = (*t as i64).saturating_mul(10_000);
        let at = PROPVARIANT::from(target.saturating_add(shift));
        unsafe { source.SetCurrentPosition(&windows_core::GUID::zeroed(), &at)? };
        // Media Foundation seeks to the keyframe at or before; an exact
        // read decodes forward and keeps the last picture shown at `t`.
        let mut kept: Option<Sample> = None;
        while out.wanted() {
            let Some(s) = next(source)? else { break };
            if !exact {
                kept = Some(s);
                break;
            }
            // Half a millisecond either side of a picture's own time.
            let late = s.hns - shift > target + 5_000;
            if late && kept.is_some() {
                break;
            }
            kept = Some(s);
            if late {
                break;
            }
        }
        if !out.wanted() {
            return Ok(());
        }
        let Some(kept) = kept else {
            out.send(Owned::Finished);
            return Ok(());
        };
        let (width, height, pixels) = rgba(source, &kept.sample)?;
        let (width, height, pixels) = crate::reader::fit(width, height, &pixels, max);
        let actual_ms = ((kept.hns - shift).max(0) as u64 + 5_000) / 10_000;
        out.send(Owned::Frame { index: index as u32, actual_ms, width, height, pixels });
    }
    Ok(())
}

/// The current output type's display size, padded plane height, matrix and
/// range.
struct Geometry {
    width: u32,
    height: u32,
    plane_rows: u32,
    left: u32,
    top: u32,
    kr: f64,
    kb: f64,
    full_range: bool,
}

fn geometry(source: &IMFSourceReader) -> windows_core::Result<Geometry> {
    let ty = unsafe { source.GetCurrentMediaType(VIDEO)? };
    let size = unsafe { ty.GetUINT64(&MF_MT_FRAME_SIZE)? };
    let (fw, fh) = ((size >> 32) as u32, size as u32);
    let mut area = [0u8; std::mem::size_of::<MFVideoArea>()];
    let (left, top, width, height) = match unsafe { ty.GetBlob(&MF_MT_MINIMUM_DISPLAY_APERTURE, &mut area, None) } {
        Ok(()) => {
            // SAFETY: the blob is an MFVideoArea, read unaligned.
            let a: MFVideoArea = unsafe { std::ptr::read_unaligned(area.as_ptr() as *const MFVideoArea) };
            (a.OffsetX.value.max(0) as u32, a.OffsetY.value.max(0) as u32, a.Area.cx as u32, a.Area.cy as u32)
        }
        Err(_) => (0, 0, fw, fh),
    };
    // MFVideoTransferMatrix: 1 BT.709, 2 BT.601, 3 SMPTE 240M, 4 BT.2020.
    let matrix = unsafe { ty.GetUINT32(&MF_MT_YUV_MATRIX) }.unwrap_or(0);
    let (kr, kb) = match matrix {
        2 => crate::reader::Ycc::BT601,
        3 => crate::reader::Ycc::SMPTE240M,
        4 => crate::reader::Ycc::BT2020,
        1 => crate::reader::Ycc::BT709,
        _ => crate::reader::Ycc::unnamed(fh),
    };
    // MFNominalRange: 1 is 0-255, 2 is 16-235.
    let full_range = unsafe { ty.GetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE) }.is_ok_and(|r| r == 1);
    Ok(Geometry { width, height, plane_rows: fh, left, top, kr, kb, full_range })
}

/// The kept NV12 sample as premultiplied (opaque) RGBA8 at its display size.
fn rgba(source: &IMFSourceReader, sample: &IMFSample) -> windows_core::Result<(u32, u32, Vec<u8>)> {
    let g = geometry(source)?;
    let buffer = unsafe { sample.ConvertToContiguousBuffer()? };
    let out;
    if let Ok(two_d) = buffer.cast::<IMF2DBuffer>() {
        let (mut scan0, mut pitch) = (std::ptr::null_mut(), 0i32);
        unsafe { two_d.Lock2D(&mut scan0, &mut pitch)? };
        let len = pitch.unsigned_abs() as usize * g.plane_rows as usize * 3 / 2;
        // SAFETY: a locked NV12 surface of `plane_rows` luma rows and half
        // as many chroma rows at `pitch`.
        let bytes = unsafe { std::slice::from_raw_parts(scan0, len) };
        out = nv12(bytes, pitch.unsigned_abs() as usize, &g);
        unsafe { two_d.Unlock2D()? };
    } else {
        let (mut data, mut length) = (std::ptr::null_mut(), 0u32);
        unsafe { buffer.Lock(&mut data, None, Some(&mut length))? };
        // SAFETY: the locked buffer's current length.
        let bytes = unsafe { std::slice::from_raw_parts(data, length as usize) };
        let pitch = (length as usize * 2 / 3) / g.plane_rows.max(1) as usize;
        out = nv12(bytes, pitch, &g);
        unsafe { buffer.Unlock()? };
    }
    Ok((g.width, g.height, out))
}

/// NV12 to RGBA8 through the stream's own matrix and range
/// (crate::reader::Ycc), chroma taken from the 2x2 block each pixel sits in.
fn nv12(bytes: &[u8], pitch: usize, g: &Geometry) -> Vec<u8> {
    let ycc = crate::reader::Ycc { kr: g.kr, kb: g.kb, full_range: g.full_range };
    let chroma = pitch * g.plane_rows as usize;
    ycc.rgba(g.width, g.height, |x, y| {
        let (sx, sy) = (x + g.left as usize, y + g.top as usize);
        let c = chroma + (sy / 2) * pitch + (sx / 2) * 2;
        (
            bytes.get(sy * pitch + sx).copied().unwrap_or(0),
            bytes.get(c).copied().unwrap_or(128),
            bytes.get(c + 1).copied().unwrap_or(128),
        )
    })
}

fn peaks_read(source: &IMFSourceReader, out: &Out) -> windows_core::Result<()> {
    let ty = unsafe { source.GetCurrentMediaType(AUDIO)? };
    let channels = unsafe { ty.GetUINT32(&MF_MT_AUDIO_NUM_CHANNELS)? };
    let rate = unsafe { ty.GetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND)? };
    let total_ms = unsafe { source.GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE.0 as u32, &MF_PD_DURATION) }
        .ok()
        .and_then(|v| u64::try_from(&v).ok())
        .map(|hns| hns / 10_000)
        .unwrap_or(0);
    while out.wanted() {
        let (mut flags, mut sample) = (0u32, None);
        unsafe { source.ReadSample(AUDIO, 0, None, Some(&mut flags), None, Some(&mut sample))? };
        if let Some(sample) = sample {
            let buffer = unsafe { sample.ConvertToContiguousBuffer()? };
            let (mut data, mut length) = (std::ptr::null_mut(), 0u32);
            unsafe { buffer.Lock(&mut data, None, Some(&mut length))? };
            // SAFETY: the locked buffer's current length, float32 samples.
            let bytes = unsafe { std::slice::from_raw_parts(data, length as usize) };
            let samples: Vec<f32> = bytes.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
            unsafe { buffer.Unlock()? };
            if !samples.is_empty() {
                if !out.flight.make_room() {
                    return Ok(());
                }
                out.send(Owned::Pcm { channels, sample_rate: rate, samples, total_ms });
            }
        }
        if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
            out.send(Owned::Finished);
            return Ok(());
        }
    }
    Ok(())
}
