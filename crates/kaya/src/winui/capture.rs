//! The capture on WinUI (docs/capture-plan.md, the WinUI rows): one
//! `MediaCapture` per capture over its chosen devices, `MediaFrameReader`
//! handing NV12 and float frames to the core on the reader's own thread, the
//! preview a `MediaPlayerElement` over `MediaSource.CreateFromMediaFrameSource`
//! (the video view's own element, media.rs), every report through the core's
//! one state machine on the UI thread.
//!
//! Under the harness the devices are the core's synthetic table, each entry
//! listed only while the lane's device carrying it is present: the two MF
//! virtual cameras kaya-capture-lane makes (tools/winvcam) and the VB-CABLE
//! output whose left channel is microphone 1 and right microphone 2
//! (docs/HACKING.md, the Windows capture install). THE WALL: `open_devices`
//! is the one function that opens a device, and under KAYA_SELFTEST it opens
//! only those carriers (tools/check-verbs.py holds it).

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use windows::Win32::System::WinRT::IMemoryBufferByteAccess;
use windows_core::{Interface as _, HSTRING};

use super::bindings::Windows::Devices::Enumeration::{DeviceClass, DeviceInformation, DeviceWatcher, Panel};
use super::bindings::Windows::Foundation::TypedEventHandler;
use super::bindings::Windows::Graphics::Imaging::{BitmapBufferAccessMode, BitmapPixelFormat};
use super::bindings::Windows::Media::AudioBufferAccessMode;
use super::bindings::Windows::Media::Capture::Frames::{
    MediaFrameArrivedEventArgs, MediaFrameReader, MediaFrameReaderAcquisitionMode, MediaFrameReaderStartStatus,
    MediaFrameSource, MediaFrameSourceKind,
};
use super::bindings::Windows::Media::Capture::{
    MediaCapture, MediaCaptureFailedEventArgs, MediaCaptureFailedEventHandler, MediaCaptureInitializationSettings,
    MediaCaptureMemoryPreference, MediaCaptureSharingMode, StreamingCaptureMode,
};
use super::bindings::Windows::Media::Core::MediaSource;
use super::bindings::Windows::Media::Devices::{AudioDeviceRole, MediaDevice};
use super::bindings::Windows::Media::Playback::{IMediaPlaybackSource, MediaPlayer};
use super::CoreState;
use crate::capture::{CaptureFrame, Report};
use crate::protocol::{
    CameraFacing, CaptureCommand, CaptureDevice, CaptureFailure, CaptureId, CaptureKind, CaptureProp, OccSink, Permission,
    Value,
};

/// What the lane's cable is called, both of whose channels carry a synthetic
/// microphone (the coordinator's OPEN B).
const CABLE: &str = "CABLE Output";

pub(super) fn under_harness() -> bool {
    std::env::var_os("KAYA_SELFTEST").is_some()
}

/// A WinRT object handed between the UI thread and a worker: the media
/// capture classes are agile, and every use is serialised by the generation.
struct Sendable<T>(T);
// SAFETY: see above; the objects carried are agile WinRT classes.
unsafe impl<T> Send for Sendable<T> {}

impl<T> Sendable<T> {
    /// By method, so a closure captures the whole wrapper and not its field.
    fn take(self) -> T {
        self.0
    }
}

/// One device as Windows lists it.
#[derive(Clone)]
struct Found {
    id: String,
    name: String,
    kind: CaptureKind,
    facing: CameraFacing,
    preferred: bool,
}

/// A device the app asked for, resolved: the platform's device and, for a
/// synthetic microphone, the cable channel it is.
#[derive(Clone)]
struct Resolved {
    found: Found,
    channel: Option<usize>,
    mirror: bool,
}

/// What an open capture holds.
struct Opened {
    media: MediaCapture,
    video: Option<MediaFrameReader>,
    audio: Option<MediaFrameReader>,
    preview: Option<MediaSource>,
}

struct WinCapture {
    camera: String,
    microphone: String,
    wish: (f64, f64, f64),
    running: bool,
    generation: Arc<AtomicU64>,
    opened: Option<Sendable<Opened>>,
}

#[derive(Default)]
struct Watch {
    watchers: Vec<DeviceWatcher>,
}

thread_local! {
    static CAPTURES: RefCell<HashMap<u64, WinCapture>> = RefCell::new(HashMap::new());
    static WATCH: RefCell<Option<Watch>> = const { RefCell::new(None) };
    /// The permission each kind last reported, so a kind is reported when it moves.
    static KNOWN: RefCell<HashMap<CaptureKind, Permission>> = RefCell::new(HashMap::new());
}

// ---- the doors to the core ----------------------------------------------------

/// THE ONE DOOR every capture report takes: the core's state machine, then
/// the keep-awake follows it.
fn report(core: &mut CoreState, capture: u64, report: Report) {
    let overdue = report == Report::Overdue;
    let published = core.scene.capture_report(CaptureId(capture), report);
    let torn_down = overdue && crate::capture::timed_out(&published);
    for occ in published {
        core.occurrences.send(occ);
    }
    if torn_down {
        close(core, capture);
    }
}

fn permission(core: &mut CoreState, kind: CaptureKind, answer: Permission, detail: String) {
    let moved = KNOWN.with(|k| k.borrow_mut().insert(kind, answer) != Some(answer));
    if !moved && detail.is_empty() {
        return;
    }
    for occ in core.scene.capture_permission(kind, answer, detail) {
        core.occurrences.send(occ);
    }
}

fn failure_of(e: &windows_core::Error) -> (CaptureFailure, String) {
    let code = e.code().0 as u32;
    let detail = format!("{:#010X} {}", code, e.message());
    let reason = match code {
        // E_ACCESSDENIED: the desktop-apps switch is off (docs/capture-plan.md §2 rule 1).
        0x8007_0005 => CaptureFailure::Denied,
        // MF_E_HW_MFT_FAILED_START_STREAMING, MF_E_VIDEO_RECORDING_DEVICE_PREEMPTED,
        // MF_E_AUDIO_RECORDING_DEVICE_IN_USE: another app holds it.
        0xC00D_3704 | 0xC00D_ABE2 | 0xC00D_ABE4 => CaptureFailure::InUse,
        // MF_E_VIDEO_RECORDING_DEVICE_INVALIDATED, MF_E_AUDIO_RECORDING_DEVICE_INVALIDATED.
        0xC00D_ABE1 | 0xC00D_ABE3 => CaptureFailure::Disconnected,
        // MF_E_NO_CAPTURE_DEVICES_AVAILABLE, ERROR_NOT_FOUND, ERROR_FILE_NOT_FOUND.
        0xC00D_ABE0 | 0x8007_0490 | 0x8007_0002 => CaptureFailure::NotFound,
        _ => CaptureFailure::HardwareError,
    };
    (reason, detail)
}

// ---- the devices --------------------------------------------------------------

fn facing_of(info: &DeviceInformation) -> CameraFacing {
    match info.EnclosureLocation().and_then(|l| l.Panel()) {
        Ok(Panel::Front) => CameraFacing::Front,
        Ok(Panel::Back) => CameraFacing::Back,
        Ok(_) => CameraFacing::Unknown,
        // No enclosure location: a camera plugged in rather than built in.
        Err(_) => CameraFacing::External,
    }
}

/// Every camera and microphone Windows lists, on the calling (worker) thread.
fn list_platform() -> windows_core::Result<Vec<Found>> {
    let default_mic = MediaDevice::GetDefaultAudioCaptureId(AudioDeviceRole::Communications)
        .map(|s| s.to_string())
        .unwrap_or_default();
    let mut out = Vec::new();
    for (class, kind) in [(DeviceClass::VideoCapture, CaptureKind::Camera), (DeviceClass::AudioCapture, CaptureKind::Microphone)] {
        let all = DeviceInformation::FindAllAsyncDeviceClass(class)?.join()?;
        for i in 0..all.Size()? {
            let info = all.GetAt(i)?;
            if !info.IsEnabled().unwrap_or(true) {
                continue;
            }
            let id = info.Id()?.to_string();
            let facing = if kind == CaptureKind::Camera { facing_of(&info) } else { CameraFacing::Unknown };
            let preferred = match kind {
                // Windows names no preferred camera: the first one listed.
                CaptureKind::Camera => !out.iter().any(|f: &Found| f.kind == CaptureKind::Camera),
                CaptureKind::Microphone => id.eq_ignore_ascii_case(&default_mic),
            };
            out.push(Found { id, name: info.Name()?.to_string(), kind, facing, preferred });
        }
    }
    Ok(out)
}

/// The synthetic table as this lane carries it: each entry whose carrier is
/// present, its platform device and its cable channel (the coordinator's
/// OPEN A and B).
fn synthetic_carried(found: &[Found]) -> Vec<(&'static crate::capture::Synthetic, Resolved)> {
    let mut out = Vec::new();
    let mut microphones = 0;
    for s in crate::capture::SYNTHETIC {
        let carrier = match s.kind {
            CaptureKind::Camera => found.iter().find(|f| f.kind == CaptureKind::Camera && f.name.starts_with(s.name)),
            CaptureKind::Microphone => found.iter().find(|f| f.kind == CaptureKind::Microphone && f.name.starts_with(CABLE)),
        };
        let channel = (s.kind == CaptureKind::Microphone).then(|| {
            microphones += 1;
            microphones - 1
        });
        if let Some(f) = carrier {
            let mirror = matches!(s.facing, CameraFacing::Front | CameraFacing::External);
            out.push((s, Resolved { found: f.clone(), channel, mirror }));
        }
    }
    out
}

/// The devices the app is told about: the synthetic table under the
/// harness, the platform's list otherwise.
fn listed(found: &[Found]) -> Vec<CaptureDevice> {
    if under_harness() {
        return synthetic_carried(found)
            .into_iter()
            .map(|(s, _)| CaptureDevice {
                id: s.id.to_owned(),
                name: s.name.to_owned(),
                kind: s.kind,
                facing: s.facing,
                preferred: s.preferred,
            })
            .collect();
    }
    found
        .iter()
        .map(|f| CaptureDevice { id: f.id.clone(), name: f.name.clone(), kind: f.kind, facing: f.facing, preferred: f.preferred })
        .collect()
}

/// An app's device id resolved against the platform's list.
fn resolve(found: &[Found], kind: CaptureKind, id: &str) -> Option<Resolved> {
    if under_harness() {
        return synthetic_carried(found).into_iter().find(|(s, _)| s.kind == kind && s.id == id).map(|(_, r)| r);
    }
    found.iter().find(|f| f.kind == kind && f.id == id).map(|f| Resolved {
        found: f.clone(),
        channel: None,
        mirror: matches!(f.facing, CameraFacing::Front | CameraFacing::External),
    })
}

fn report_devices(core: &mut CoreState, devices: Vec<CaptureDevice>) {
    core.scene.capture_devices_begin();
    for d in devices {
        core.scene.capture_device(d);
    }
    for occ in core.scene.capture_devices_end() {
        core.occurrences.send(occ);
    }
}

/// Run `f` on a worker in its own multithreaded apartment: device lists and
/// MediaCapture's async operations block, which the XAML thread may not.
fn on_worker(f: impl FnOnce() + Send + 'static) {
    std::thread::spawn(move || {
        // SAFETY: this thread's own apartment, ended with the thread.
        unsafe { super::CoInitializeEx(std::ptr::null(), 0x0) };
        f();
    });
}

pub(super) fn watch_devices(core: &mut CoreState, on: bool) {
    WATCH.with(|w| {
        if let Some(old) = w.borrow_mut().take() {
            for watcher in old.watchers {
                let _ = watcher.Stop();
            }
        }
    });
    if !on {
        return;
    }
    if under_harness() {
        for kind in [CaptureKind::Camera, CaptureKind::Microphone] {
            let standing = crate::capture::synthetic_permission(kind);
            KNOWN.with(|k| k.borrow_mut().insert(kind, standing));
            for occ in core.scene.capture_permission(kind, standing, String::new()) {
                core.occurrences.send(occ);
            }
        }
    } else {
        for kind in [CaptureKind::Camera, CaptureKind::Microphone] {
            let standing = KNOWN.with(|k| k.borrow().get(&kind).copied()).unwrap_or(Permission::Prompt);
            for occ in core.scene.capture_permission(
                kind,
                standing,
                "Windows answers an unpackaged app only when a device opens".to_owned(),
            ) {
                core.occurrences.send(occ);
            }
        }
        let mut watchers = Vec::new();
        for class in [DeviceClass::VideoCapture, DeviceClass::AudioCapture] {
            let Ok(watcher) = DeviceInformation::CreateWatcherDeviceClass(class) else { continue };
            let relist = || relist_later();
            let _ = watcher.Added(&TypedEventHandler::new(move |_, _| {
                relist();
                Ok(())
            }));
            let _ = watcher.Removed(&TypedEventHandler::new(move |_, _| {
                relist_later();
                Ok(())
            }));
            let _ = watcher.Updated(&TypedEventHandler::new(move |_, _| {
                relist_later();
                Ok(())
            }));
            let _ = watcher.Start();
            watchers.push(watcher);
        }
        WATCH.with(|w| *w.borrow_mut() = Some(Watch { watchers }));
    }
    relist_later();
}

/// The list read on a worker and reported on the UI thread.
fn relist_later() {
    on_worker(|| {
        let found = list_platform().unwrap_or_else(|e| {
            eprintln!("KAYA_DIAG winui capture: listing the devices failed: {}", e.message());
            Vec::new()
        });
        let devices = listed(&found);
        super::media::post(move |core| {
            if WATCH.with(|w| w.borrow().is_some()) {
                report_devices(core, devices);
            }
        });
    });
}

// ---- THE WALL -----------------------------------------------------------------

/// Under the harness a device is a lane synthetic carrier or nothing: a lane's
/// guest reaching any other camera or microphone (the VM's Line In is the
/// host's input) is a defect, fatal, named.
fn wall(device: &Found) {
    if !under_harness() {
        return;
    }
    let lane = match device.kind {
        CaptureKind::Camera => crate::capture::SYNTHETIC
            .iter()
            .any(|s| s.kind == CaptureKind::Camera && device.name.starts_with(s.name)),
        CaptureKind::Microphone => device.name.starts_with(CABLE),
    };
    if !lane {
        panic!(
            "kaya: the capture would open {:?} ({}) under the harness (KAYA_SELFTEST is set); a lane opens \
             kaya's synthetic devices only, the virtual cameras and the cable (docs/capture-plan.md §7)",
            device.name, device.id
        );
    }
}

/// THE ONE FUNCTION that opens a camera or a microphone: every device passes
/// the wall first.
fn open_devices(
    camera: Option<&Found>,
    microphone: Option<&Found>,
    sharing: MediaCaptureSharingMode,
) -> windows_core::Result<MediaCapture> {
    for device in camera.into_iter().chain(microphone) {
        wall(device);
    }
    let settings = MediaCaptureInitializationSettings::new()?;
    settings.SetSharingMode(sharing)?;
    settings.SetMemoryPreference(MediaCaptureMemoryPreference::Cpu)?;
    settings.SetStreamingCaptureMode(match (camera, microphone) {
        (Some(_), Some(_)) => StreamingCaptureMode::AudioAndVideo,
        (Some(_), None) => StreamingCaptureMode::Video,
        _ => StreamingCaptureMode::Audio,
    })?;
    if let Some(c) = camera {
        settings.SetVideoDeviceId(&HSTRING::from(c.id.as_str()))?;
    }
    if let Some(m) = microphone {
        settings.SetAudioDeviceId(&HSTRING::from(m.id.as_str()))?;
    }
    let media = MediaCapture::new()?;
    media.InitializeWithSettingsAsync(&settings)?.join()?;
    Ok(media)
}

// ---- the capture ----------------------------------------------------------------

pub(super) fn create(_core: &mut CoreState, id: u64) {
    CAPTURES.with(|c| {
        c.borrow_mut().insert(
            id,
            WinCapture {
                camera: String::new(),
                microphone: String::new(),
                wish: (0.0, 0.0, 0.0),
                running: false,
                generation: Arc::new(AtomicU64::new(0)),
                opened: None,
            },
        )
    });
}

pub(super) fn set_prop(core: &mut CoreState, id: u64, prop: CaptureProp, value: Value) {
    let reopen = CAPTURES.with(|c| {
        let mut c = c.borrow_mut();
        let Some(cap) = c.get_mut(&id) else { return false };
        match (prop, value) {
            (CaptureProp::Camera, Value::Str(s)) => cap.camera = s,
            (CaptureProp::Microphone, Value::Str(s)) => cap.microphone = s,
            (CaptureProp::Width, Value::F64(x)) => cap.wish.0 = x,
            (CaptureProp::Height, Value::F64(x)) => cap.wish.1 = x,
            (CaptureProp::FrameRate, Value::F64(x)) => cap.wish.2 = x,
            // The core keeps the microphone open and delivers the silence.
            (CaptureProp::Muted, _) => return false,
            _ => return false,
        }
        // A device change while running reopens (docs/capture-plan.md §2).
        cap.running
    });
    if reopen {
        open(core, id);
    }
}

pub(super) fn command(core: &mut CoreState, id: u64, command: CaptureCommand) {
    match command {
        CaptureCommand::Start => {
            let start = CAPTURES.with(|c| {
                let mut c = c.borrow_mut();
                let Some(cap) = c.get_mut(&id) else { return false };
                if cap.running {
                    return false;
                }
                cap.running = true;
                true
            });
            if start {
                open(core, id);
            }
        }
        CaptureCommand::Stop => {
            CAPTURES.with(|c| {
                if let Some(cap) = c.borrow_mut().get_mut(&id) {
                    cap.running = false;
                }
            });
            close(core, id);
        }
    }
}

pub(super) fn release(core: &mut CoreState, id: u64) {
    close(core, id);
    CAPTURES.with(|c| c.borrow_mut().remove(&id));
}

/// Close what is open: the generation moves first, so anything still
/// arriving for the old devices is dropped, then the preview goes out.
fn close(core: &mut CoreState, id: u64) {
    let opened = CAPTURES.with(|c| {
        let mut c = c.borrow_mut();
        let cap = c.get_mut(&id)?;
        cap.generation.fetch_add(1, Ordering::SeqCst);
        cap.opened.take()
    });
    super::media::capture_preview(core, id, None);
    if let Some(Sendable(o)) = opened {
        let o = Sendable(o);
        on_worker(move || {
            let o = o.take();
            for reader in [o.video, o.audio].into_iter().flatten() {
                if let Ok(op) = reader.StopAsync() {
                    let _ = op.join();
                }
                let _ = reader.Close();
            }
            if let Some(p) = o.preview {
                let _ = p.Close();
            }
            let _ = o.media.Close();
        });
    }
}

/// Open the capture's devices: each kind's permission asked first, then the
/// devices resolved and opened on a worker, the result reported on the UI
/// thread if it is still the capture's latest.
fn open(core: &mut CoreState, id: u64) {
    close(core, id);
    let Some((camera, microphone, wish, generation)) = CAPTURES.with(|c| {
        c.borrow().get(&id).map(|cap| (cap.camera.clone(), cap.microphone.clone(), cap.wish, cap.generation.clone()))
    }) else {
        return;
    };
    let at = generation.load(Ordering::SeqCst);
    // docs/media-plan.md §7c's bound for a start the platform never answers.
    let bound = generation.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(crate::media::TIMEOUT_MS));
        if bound.load(Ordering::SeqCst) == at {
            super::media::post(move |core| {
                if CAPTURES.with(|c| c.borrow().get(&id).is_some_and(|cap| cap.running && cap.generation.load(Ordering::SeqCst) == at)) {
                    report(core, id, Report::Overdue);
                }
            });
        }
    });
    let kinds: Vec<CaptureKind> = [(!camera.is_empty()).then_some(CaptureKind::Camera), (!microphone.is_empty()).then_some(CaptureKind::Microphone)]
        .into_iter()
        .flatten()
        .collect();
    if under_harness() {
        // The core's synthetic prompt (the coordinator's OPEN C), each kind in turn.
        let mut denied = false;
        for kind in &kinds {
            let answer = crate::capture::synthetic_ask(*kind);
            permission(core, *kind, answer, String::new());
            denied |= answer == Permission::Denied;
        }
        if denied {
            report(
                core,
                id,
                Report::Failed(CaptureFailure::Denied, "the user denied this app the camera or the microphone".to_owned()),
            );
            return;
        }
    }
    let sink = core.occurrences.clone();
    on_worker(move || {
        let outcome = open_on_worker(id, &camera, &microphone, wish, sink, &generation, at);
        let outcome = Sendable(outcome);
        super::media::post(move |core| {
            let outcome = outcome.take();
            finish_open(core, id, at, outcome);
        });
    });
}

struct Outcome {
    opened: Opened,
    format: (u32, u32, u32),
    mirror: bool,
    kinds: Vec<CaptureKind>,
}

fn finish_open(core: &mut CoreState, id: u64, at: u64, outcome: Result<Outcome, (CaptureFailure, String)>) {
    let current = CAPTURES.with(|c| {
        c.borrow().get(&id).is_some_and(|cap| cap.running && cap.generation.load(Ordering::SeqCst) == at)
    });
    match outcome {
        Ok(o) if current => {
            if !under_harness() {
                for kind in &o.kinds {
                    permission(core, *kind, Permission::Granted, String::new());
                }
            }
            let preview = o.opened.preview.clone();
            CAPTURES.with(|c| {
                if let Some(cap) = c.borrow_mut().get_mut(&id) {
                    cap.opened = Some(Sendable(o.opened));
                }
            });
            if let Some(source) = preview {
                match preview_player(&source) {
                    Ok(player) => super::media::capture_preview(core, id, Some((player, (o.format.0, o.format.1), o.mirror))),
                    Err(e) => eprintln!("KAYA_DIAG winui capture {id}: the preview did not start: {}", e.message()),
                }
            }
            report(core, id, Report::Running { width: o.format.0, height: o.format.1, frame_rate: o.format.2 });
        }
        Ok(o) => {
            // Stopped or reopened meanwhile: this open is nobody's.
            let stale = Sendable(o.opened);
            on_worker(move || {
                let o = stale.take();
                let _ = o.media.Close();
            });
        }
        Err((reason, detail)) if current => {
            if reason == CaptureFailure::Denied && !under_harness() {
                let kinds: Vec<CaptureKind> = CAPTURES.with(|c| {
                    c.borrow()
                        .get(&id)
                        .map(|cap| {
                            [(!cap.camera.is_empty()).then_some(CaptureKind::Camera), (!cap.microphone.is_empty()).then_some(CaptureKind::Microphone)]
                                .into_iter()
                                .flatten()
                                .collect()
                        })
                        .unwrap_or_default()
                });
                for kind in kinds {
                    permission(core, kind, Permission::Denied, detail.clone());
                }
            }
            report(core, id, Report::Failed(reason, detail));
        }
        Err(_) => {}
    }
}

fn preview_player(source: &MediaSource) -> windows_core::Result<MediaPlayer> {
    let player = MediaPlayer::new()?;
    player.SetRealTimePlayback(true)?;
    player.SetAutoPlay(true)?;
    // The self-view is not Now Playing (docs/capture-plan.md §6).
    player.CommandManager()?.SetIsEnabled(false)?;
    player.SystemMediaTransportControls()?.SetIsEnabled(false)?;
    player.SetSource(&source.cast::<IMediaPlaybackSource>()?)?;
    player.Play()?;
    Ok(player)
}

/// The worker half of an open: resolve, open, choose the format, start the
/// readers and make the preview's source.
fn open_on_worker(
    id: u64,
    camera: &str,
    microphone: &str,
    wish: (f64, f64, f64),
    sink: OccSink,
    generation: &Arc<AtomicU64>,
    at: u64,
) -> Result<Outcome, (CaptureFailure, String)> {
    let found = list_platform().map_err(|e| failure_of(&e))?;
    let pick = |kind: CaptureKind, want: &str| -> Result<Option<Resolved>, (CaptureFailure, String)> {
        if want.is_empty() {
            return Ok(None);
        }
        resolve(&found, kind, want).map(Some).ok_or_else(|| {
            (
                CaptureFailure::NotFound,
                if under_harness() {
                    format!("no device {want:?}: under the harness only kaya's synthetic devices exist, each while its lane device runs")
                } else {
                    format!("no {} {want:?} is attached", kind.name())
                },
            )
        })
    };
    let cam = pick(CaptureKind::Camera, camera)?;
    let mic = pick(CaptureKind::Microphone, microphone)?;
    let media = open_devices(cam.as_ref().map(|r| &r.found), mic.as_ref().map(|r| &r.found), MediaCaptureSharingMode::ExclusiveControl)
        .map_err(|e| failure_of(&e))?;
    let fail = |media: &MediaCapture, why: (CaptureFailure, String)| {
        let _ = media.Close();
        why
    };
    let started = Instant::now();
    let mut format = (0, 0, 0);
    let mut video = None;
    let mut preview = None;
    if cam.is_some() {
        let source = frame_source(&media, MediaFrameSourceKind::Color).ok_or_else(|| {
            fail(&media, (CaptureFailure::HardwareError, "the camera offers no colour frame source".to_owned()))
        })?;
        format = choose_format(&source, wish).map_err(|why| fail(&media, why))?;
        let reader = media
            .CreateFrameReaderWithSubtypeAsync(&source, &HSTRING::from("NV12"))
            .and_then(|op| op.join())
            .map_err(|e| fail(&media, failure_of(&e)))?;
        reader.SetAcquisitionMode(MediaFrameReaderAcquisitionMode::Realtime).map_err(|e| fail(&media, failure_of(&e)))?;
        let live = generation.clone();
        reader
            .FrameArrived(&TypedEventHandler::<MediaFrameReader, MediaFrameArrivedEventArgs>::new(move |reader, _| {
                if live.load(Ordering::SeqCst) != at {
                    return Ok(());
                }
                if let Some(reader) = reader.as_ref() {
                    if let Err(e) = video_frame(reader, id, started) {
                        eprintln!("KAYA_DIAG winui capture {id}: a video frame could not be read: {}", e.message());
                    }
                }
                Ok(())
            }))
            .map_err(|e| fail(&media, failure_of(&e)))?;
        start_reader(&reader).map_err(|why| fail(&media, why))?;
        preview = Some(MediaSource::CreateFromMediaFrameSource(&source).map_err(|e| fail(&media, failure_of(&e)))?);
        video = Some(reader);
    }
    let mut audio = None;
    if let Some(m) = &mic {
        let source = frame_source(&media, MediaFrameSourceKind::Audio).ok_or_else(|| {
            fail(&media, (CaptureFailure::HardwareError, "the microphone offers no audio frame source".to_owned()))
        })?;
        let reader = media.CreateFrameReaderAsync(&source).and_then(|op| op.join()).map_err(|e| fail(&media, failure_of(&e)))?;
        let live = generation.clone();
        let channel = m.channel;
        reader
            .FrameArrived(&TypedEventHandler::<MediaFrameReader, MediaFrameArrivedEventArgs>::new(move |reader, _| {
                if live.load(Ordering::SeqCst) != at {
                    return Ok(());
                }
                if let Some(reader) = reader.as_ref() {
                    if let Err(e) = audio_frame(reader, id, started, channel, &sink) {
                        eprintln!("KAYA_DIAG winui capture {id}: an audio frame could not be read: {}", e.message());
                    }
                }
                Ok(())
            }))
            .map_err(|e| fail(&media, failure_of(&e)))?;
        start_reader(&reader).map_err(|why| fail(&media, why))?;
        audio = Some(reader);
    }
    let live = generation.clone();
    let _ = media.Failed(&MediaCaptureFailedEventHandler::new(move |_, args: windows_core::Ref<MediaCaptureFailedEventArgs>| {
        if live.load(Ordering::SeqCst) != at {
            return Ok(());
        }
        let (code, message) = args
            .as_ref()
            .map(|a| (a.Code().unwrap_or(0), a.Message().map(|m| m.to_string()).unwrap_or_default()))
            .unwrap_or((0, String::new()));
        let (reason, detail) = failure_of(&windows_core::Error::new(windows_core::HRESULT(code as i32), message));
        super::media::post(move |core| report(core, id, Report::Failed(reason, detail)));
        Ok(())
    }));
    let mirror = cam.as_ref().is_some_and(|c| c.mirror);
    let kinds = [cam.is_some().then_some(CaptureKind::Camera), mic.is_some().then_some(CaptureKind::Microphone)]
        .into_iter()
        .flatten()
        .collect();
    Ok(Outcome { opened: Opened { media, video, audio, preview }, format, mirror, kinds })
}

fn frame_source(media: &MediaCapture, kind: MediaFrameSourceKind) -> Option<MediaFrameSource> {
    let sources = media.FrameSources().ok()?;
    let it = sources.First().ok()?;
    while it.HasCurrent().ok()? {
        let pair = it.Current().ok()?;
        let source = pair.Value().ok()?;
        if source.Info().and_then(|i| i.SourceKind()).ok() == Some(kind) {
            return Some(source);
        }
        it.MoveNext().ok()?;
    }
    None
}

/// The wish met by the core's one rule (crate::capture::nearest_format) over
/// what the camera offers, NV12 where it offers that.
fn choose_format(source: &MediaFrameSource, wish: (f64, f64, f64)) -> Result<(u32, u32, u32), (CaptureFailure, String)> {
    let err = |e: windows_core::Error| failure_of(&e);
    let formats = source.SupportedFormats().map_err(err)?;
    let mut all = Vec::new();
    for i in 0..formats.Size().map_err(err)? {
        let f = formats.GetAt(i).map_err(err)?;
        let Ok(video) = f.VideoFormat() else { continue };
        let rate = f.FrameRate().map_err(err)?;
        let fps = rate.Numerator().map_err(err)? / rate.Denominator().map_err(err)?.max(1);
        let nv12 = f.Subtype().map(|s| s.to_string().eq_ignore_ascii_case("NV12")).unwrap_or(false);
        all.push(((video.Width().map_err(err)?, video.Height().map_err(err)?, fps), nv12, f));
    }
    let offered: Vec<(u32, u32, u32)> = all.iter().map(|(t, ..)| *t).collect();
    let chosen = crate::capture::nearest_format(&offered, wish).ok_or_else(|| {
        (CaptureFailure::Unsupported, "the camera offers no video format at all".to_owned())
    })?;
    let pick = all
        .iter()
        .filter(|(t, ..)| *t == chosen)
        .max_by_key(|(_, nv12, _)| *nv12)
        .map(|(.., f)| f.clone())
        .ok_or_else(|| (CaptureFailure::Unsupported, "the chosen format vanished".to_owned()))?;
    source.SetFormatAsync(&pick).and_then(|op| op.join()).map_err(err)?;
    Ok(chosen)
}

fn start_reader(reader: &MediaFrameReader) -> Result<(), (CaptureFailure, String)> {
    let status = reader.StartAsync().and_then(|op| op.join()).map_err(|e| failure_of(&e))?;
    match status {
        MediaFrameReaderStartStatus::Success => Ok(()),
        MediaFrameReaderStartStatus::ExclusiveControlNotAvailable => {
            Err((CaptureFailure::InUse, "MediaFrameReader.StartAsync: ExclusiveControlNotAvailable".to_owned()))
        }
        MediaFrameReaderStartStatus::DeviceNotAvailable => {
            Err((CaptureFailure::Disconnected, "MediaFrameReader.StartAsync: DeviceNotAvailable".to_owned()))
        }
        MediaFrameReaderStartStatus::OutputFormatNotSupported => {
            Err((CaptureFailure::Unsupported, "MediaFrameReader.StartAsync: OutputFormatNotSupported".to_owned()))
        }
        other => Err((CaptureFailure::HardwareError, format!("MediaFrameReader.StartAsync answered {}", other.0))),
    }
}

/// The reader's thread: the latest NV12 frame to the core, its planes as the
/// bitmap lays them out.
fn video_frame(reader: &MediaFrameReader, id: u64, started: Instant) -> windows_core::Result<()> {
    let Ok(frame) = reader.TryAcquireLatestFrame() else { return Ok(()) };
    let bitmap = frame.VideoMediaFrame()?.SoftwareBitmap()?;
    if bitmap.BitmapPixelFormat()? != BitmapPixelFormat::Nv12 {
        return Err(windows_core::Error::new(
            windows_core::HRESULT(0x8000_4001u32 as i32),
            format!("the frame is {:?}, not NV12", bitmap.BitmapPixelFormat()?.0),
        ));
    }
    let (width, height) = (bitmap.PixelWidth()? as u32, bitmap.PixelHeight()? as u32);
    let buffer = bitmap.LockBuffer(BitmapBufferAccessMode::Read)?;
    let (y, uv) = (buffer.GetPlaneDescription(0)?, buffer.GetPlaneDescription(1)?);
    let reference = buffer.CreateReference()?;
    let access: IMemoryBufferByteAccess = reference.cast()?;
    let mut data = std::ptr::null_mut();
    let mut capacity = 0u32;
    // SAFETY: the reference keeps the buffer locked until it is closed below.
    unsafe { access.GetBuffer(&mut data, &mut capacity)? };
    let (y_stride, uv_stride) = (y.Stride as u32, uv.Stride as u32);
    let y_len = (y_stride * height) as usize;
    let uv_len = (uv_stride * height.div_ceil(2)) as usize;
    if !data.is_null() && y.StartIndex as usize + y_len <= capacity as usize && uv.StartIndex as usize + uv_len <= capacity as usize {
        // SAFETY: both ranges were just checked against the buffer's capacity.
        let (ys, uvs) = unsafe {
            (
                std::slice::from_raw_parts(data.add(y.StartIndex as usize), y_len),
                std::slice::from_raw_parts(data.add(uv.StartIndex as usize), uv_len),
            )
        };
        crate::capture::frame(
            CaptureId(id),
            &CaptureFrame {
                width,
                height,
                y: ys,
                y_stride,
                uv: uvs,
                uv_stride,
                timestamp_ns: started.elapsed().as_nanos() as u64,
                rotation: 0,
            },
        );
    }
    drop(access);
    let _ = reference.Close();
    let _ = buffer.Close();
    let _ = bitmap.Close();
    let _ = frame.Close();
    Ok(())
}

/// The reader's thread: float samples to the core at their own rate and
/// channels, or under the harness the bound cable channel alone.
fn audio_frame(reader: &MediaFrameReader, id: u64, started: Instant, channel: Option<usize>, sink: &OccSink) -> windows_core::Result<()> {
    let Ok(frame) = reader.TryAcquireLatestFrame() else { return Ok(()) };
    let audio = frame.AudioMediaFrame()?;
    let props = audio.AudioEncodingProperties()?;
    let (rate, channels) = (props.SampleRate()?, props.ChannelCount()?.max(1));
    if !props.Subtype()?.to_string().eq_ignore_ascii_case("Float") || props.BitsPerSample()? != 32 {
        return Err(windows_core::Error::new(
            windows_core::HRESULT(0x8000_4001u32 as i32),
            format!("the microphone delivers {} at {} bits, not 32-bit float", props.Subtype()?, props.BitsPerSample()?),
        ));
    }
    let buffer = audio.GetAudioFrame()?.LockBuffer(AudioBufferAccessMode::Read)?;
    let length = buffer.Length()? as usize;
    let reference = buffer.CreateReference()?;
    let access: IMemoryBufferByteAccess = reference.cast()?;
    let mut data = std::ptr::null_mut();
    let mut capacity = 0u32;
    // SAFETY: the reference keeps the buffer locked until it is closed below.
    unsafe { access.GetBuffer(&mut data, &mut capacity)? };
    let count = length.min(capacity as usize) / 4;
    if !data.is_null() && count > 0 {
        // SAFETY: `count` floats lie within the locked buffer's capacity.
        let samples = unsafe { std::slice::from_raw_parts(data as *const f32, count) };
        let at = started.elapsed().as_nanos() as u64;
        let published = match channel {
            Some(c) if (c as u32) < channels => {
                let mono: Vec<f32> = samples.chunks_exact(channels as usize).map(|f| f[c]).collect();
                crate::capture::samples(CaptureId(id), 1, rate, &mono, at)
            }
            _ => crate::capture::samples(CaptureId(id), channels, rate, samples, at),
        };
        for occ in published {
            sink.send(occ);
        }
    }
    drop(access);
    let _ = reference.Close();
    let _ = buffer.Close();
    let _ = frame.Close();
    Ok(())
}

// ---- permission ------------------------------------------------------------------

/// request_permission: the core's synthetic prompt under the harness; off it,
/// the one answer an unpackaged app has, an open of the kind's default device
/// (docs/capture-plan.md §2 rule 1: E_ACCESSDENIED is denied; CheckAccess
/// answered Allowed with the switch off, docs/probes/capture-2026-10-01/windows-measured.md).
pub(super) fn request_permission(core: &mut CoreState, kind: CaptureKind) {
    if under_harness() {
        let answer = crate::capture::synthetic_ask(kind);
        permission(core, kind, answer, String::new());
        return;
    }
    on_worker(move || {
        let answer = (|| -> windows_core::Result<(Permission, String)> {
            let found = list_platform()?;
            let Some(device) = found.iter().find(|f| f.kind == kind && f.preferred).or_else(|| found.iter().find(|f| f.kind == kind)) else {
                return Ok((Permission::Prompt, format!("no {} is attached to ask about", kind.name())));
            };
            let (camera, microphone) = if kind == CaptureKind::Camera { (Some(device), None) } else { (None, Some(device)) };
            match open_devices(camera, microphone, MediaCaptureSharingMode::SharedReadOnly) {
                Ok(media) => {
                    let _ = media.Close();
                    Ok((Permission::Granted, String::new()))
                }
                Err(e) if e.code().0 as u32 == 0x8007_0005 => Ok((Permission::Denied, failure_of(&e).1)),
                Err(e) => Ok((Permission::Prompt, failure_of(&e).1)),
            }
        })()
        .unwrap_or_else(|e| (Permission::Prompt, e.message()));
        super::media::post(move |core| permission(core, kind, answer.0, answer.1));
    });
}
