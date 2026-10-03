//! The Windows lane's synthetic cameras (docs/capture-plan.md §7): a Frame
//! Server custom media source serving one flat colour as NV12, the shape of
//! Microsoft's SimpleMediaSource sample (Windows-Camera, Samples/VirtualCamera).
//! Two class ids, one per synthetic camera, each with the colour the core's
//! table gives it (crates/kaya/src/capture.rs SYNTHETIC). Registered once in
//! HKLM by the install recipe (docs/HACKING.md) and made a camera per leg by
//! kaya-capture-lane's MFCreateVirtualCamera.

#![cfg(windows)]
#![allow(non_snake_case)]

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use windows::core::{implement, Interface, Ref, BOOL, GUID, HRESULT, IUnknown, PCWSTR, PWSTR};
use windows::Win32::Foundation::{CLASS_E_CLASSNOTAVAILABLE, E_INVALIDARG, E_NOTIMPL, E_POINTER, S_FALSE, S_OK};
use windows::Win32::Media::KernelStreaming::{KSIDENTIFIER, IKsControl, IKsControl_Impl, PINNAME_VIDEO_CAPTURE};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
use windows::Win32::System::Com::{IClassFactory, IClassFactory_Impl};

/// The two synthetic cameras: class id and colour.
pub const CAMERAS: [(GUID, u32); 2] = [
    (GUID::from_u128(0x73D25515_3E88_5187_8020_696B652FA737), 0xC83C1E),
    (GUID::from_u128(0x9D4DF51D_C03E_5430_9201_371FF0648E12), 0x1E5AC8),
];

/// What each camera offers: the mac's synthetic source's sizes by rates, so
/// the core's one nearest_format rule picks the same format on both lanes.
pub const FORMATS: [(u32, u32, u32); 4] = [(640, 480, 30), (640, 480, 15), (1280, 720, 30), (1280, 720, 15)];

/// KSCAMERAPROFILE_Legacy (ksmedia.h), which the metadata does not carry.
const KSCAMERAPROFILE_LEGACY: GUID = GUID::from_u128(0xB4894D81_62B7_4EEC_8740_80658C4A9D3E);

/// ERROR_SET_NOT_FOUND as an HRESULT: the AVStream answer for a property set
/// nobody handles.
const SET_NOT_FOUND: HRESULT = HRESULT(0x8007_0492u32 as i32);

/// The flat colour as video-range BT.601 Y, U, V: the core's own formula
/// (capture.rs's tests), which `CaptureFrame::rgb_at` inverts.
pub fn yuv(rgb: u32) -> (u8, u8, u8) {
    let (r, g, b) = (f64::from((rgb >> 16) as u8), f64::from((rgb >> 8) as u8), f64::from(rgb as u8));
    let y = (16.0 + 0.257 * r + 0.504 * g + 0.098 * b).round() as u8;
    let u = (128.0 - 0.148 * r - 0.291 * g + 0.439 * b).round() as u8;
    let v = (128.0 + 0.439 * r - 0.368 * g - 0.071 * b).round() as u8;
    (y, u, v)
}

fn media_type(width: u32, height: u32, fps: u32) -> windows::core::Result<IMFMediaType> {
    unsafe {
        let t = MFCreateMediaType()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        t.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)?;
        t.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        t.SetUINT32(&MF_MT_ALL_SAMPLES_INDEPENDENT, 1)?;
        t.SetUINT64(&MF_MT_FRAME_SIZE, (u64::from(width) << 32) | u64::from(height))?;
        t.SetUINT64(&MF_MT_FRAME_RATE, (u64::from(fps) << 32) | 1)?;
        t.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1)?;
        t.SetUINT32(&MF_MT_DEFAULT_STRIDE, width)?;
        t.SetUINT32(&MF_MT_AVG_BITRATE, width * height * 12 * fps)?;
        // The samples' own colour, so a renderer reads C83C1E as C83C1E.
        t.SetUINT32(&MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT601.0 as u32)?;
        t.SetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235.0 as u32)?;
        Ok(t)
    }
}

fn frame_size(t: &IMFMediaType) -> (u32, u32, u32) {
    unsafe {
        let size = t.GetUINT64(&MF_MT_FRAME_SIZE).unwrap_or((640u64 << 32) | 480);
        let rate = t.GetUINT64(&MF_MT_FRAME_RATE).unwrap_or((30u64 << 32) | 1);
        let den = (rate & 0xFFFF_FFFF).max(1);
        ((size >> 32) as u32, size as u32, ((rate >> 32) / den).max(1) as u32)
    }
}

// ---- the stream -------------------------------------------------------------

/// COM objects handed between the Frame Server's threads and the producer;
/// Media Foundation's are free-threaded.
struct Shared<T>(T);
unsafe impl<T> Send for Shared<T> {}
unsafe impl<T> Sync for Shared<T> {}

struct StreamState {
    queue: Option<IMFMediaEventQueue>,
    descriptor: Option<IMFStreamDescriptor>,
    attributes: Option<IMFAttributes>,
    source: Option<IMFMediaSource>,
    allocator: Option<IMFVideoSampleAllocator>,
    state: MF_STREAM_STATE,
    format: (u32, u32, u32),
    tokens: VecDeque<Option<IUnknown>>,
}

struct StreamCore {
    colour: u32,
    inner: Mutex<StreamState>,
    /// Bumped at every start and stop: a producer of an older one leaves.
    generation: AtomicU64,
}

#[implement(IMFMediaStream2, IMFMediaStream, IMFMediaEventGenerator, IKsControl)]
struct Stream(Arc<StreamCore>);

// SAFETY: Media Foundation's objects are free-threaded; every field is
// behind the mutex or atomic.
unsafe impl Send for StreamCore {}
unsafe impl Sync for StreamCore {}

impl StreamCore {
    fn lock(&self) -> std::sync::MutexGuard<'_, StreamState> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn start(self: &Arc<Self>, t: Option<IMFMediaType>, event: bool) -> windows::core::Result<()> {
        let mut s = self.lock();
        let queue = s.queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        if let Some(t) = t {
            s.format = frame_size(&t);
            if s.allocator.is_none() {
                let mut raw = std::ptr::null_mut();
                unsafe { MFCreateVideoSampleAllocatorEx(&IMFVideoSampleAllocator::IID, &mut raw)? };
                s.allocator = Some(unsafe { IMFVideoSampleAllocator::from_raw(raw) });
            }
            if let Some(a) = &s.allocator {
                unsafe {
                    let _ = a.UninitializeSampleAllocator();
                    a.InitializeSampleAllocator(10, &t)?;
                }
            }
        }
        s.state = MF_STREAM_STATE_RUNNING;
        drop(s);
        if event {
            unsafe { queue.QueueEventParamVar(MEStreamStarted.0 as u32, &GUID::zeroed(), S_OK, std::ptr::null())? };
        }
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let me = self.clone();
        std::thread::spawn(move || me.produce(generation));
        Ok(())
    }

    fn stop(&self, event: bool) -> windows::core::Result<()> {
        self.generation.fetch_add(1, Ordering::SeqCst);
        let mut s = self.lock();
        s.state = MF_STREAM_STATE_STOPPED;
        s.tokens.clear();
        let queue = s.queue.clone();
        drop(s);
        if let (true, Some(q)) = (event, queue) {
            unsafe { q.QueueEventParamVar(MEStreamStopped.0 as u32, &GUID::zeroed(), S_OK, std::ptr::null())? };
        }
        Ok(())
    }

    /// The producer: one sample per pending request at the format's rate,
    /// on the clock rather than as fast as the Frame Server asks.
    fn produce(&self, generation: u64) {
        let started = Instant::now();
        let mut made: u64 = 0;
        loop {
            if self.generation.load(Ordering::SeqCst) != generation {
                return;
            }
            let fps = u64::from(self.lock().format.2.max(1));
            let due = started + Duration::from_nanos(made * 1_000_000_000 / fps);
            let now = Instant::now();
            if due > now {
                std::thread::sleep((due - now).min(Duration::from_millis(20)));
                continue;
            }
            let mut s = self.lock();
            if s.state != MF_STREAM_STATE_RUNNING {
                drop(s);
                std::thread::sleep(Duration::from_millis(5));
                continue;
            }
            let Some(token) = s.tokens.pop_front() else {
                drop(s);
                std::thread::sleep(Duration::from_millis(2));
                continue;
            };
            made += 1;
            if let Err(e) = self.deliver(&s, token) {
                let queue = s.queue.clone();
                drop(s);
                if let Some(q) = queue {
                    unsafe {
                        let _ = q.QueueEventParamVar(MEError.0 as u32, &GUID::zeroed(), e.code(), std::ptr::null());
                    }
                }
                return;
            }
        }
    }

    fn deliver(&self, s: &StreamState, token: Option<IUnknown>) -> windows::core::Result<()> {
        let allocator = s.allocator.as_ref().ok_or(windows::core::Error::from(MF_E_NOT_INITIALIZED))?;
        let queue = s.queue.as_ref().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        let (width, height, fps) = s.format;
        let (y, u, v) = yuv(self.colour);
        unsafe {
            let sample = allocator.AllocateSample()?;
            let buffer = sample.GetBufferByIndex(0)?;
            if let Ok(two) = buffer.cast::<IMF2DBuffer2>() {
                let mut scan0 = std::ptr::null_mut();
                let mut pitch = 0i32;
                let mut start = std::ptr::null_mut();
                let mut len = 0u32;
                two.Lock2DSize(MF2DBuffer_LockFlags_Write, &mut scan0, &mut pitch, &mut start, &mut len)?;
                fill(scan0, pitch.unsigned_abs() as usize, width as usize, height as usize, (y, u, v));
                two.Unlock2D()?;
            } else {
                let mut data = std::ptr::null_mut();
                buffer.Lock(&mut data, None, None)?;
                fill(data, width as usize, width as usize, height as usize, (y, u, v));
                buffer.Unlock()?;
                buffer.SetCurrentLength(width * height * 3 / 2)?;
            }
            sample.SetSampleTime(MFGetSystemTime())?;
            sample.SetSampleDuration(10_000_000 / i64::from(fps.max(1)))?;
            if let Some(token) = token {
                sample.SetUnknown(&MFSampleExtension_Token, &token)?;
            }
            queue.QueueEventParamUnk(MEMediaSample.0 as u32, &GUID::zeroed(), S_OK, &sample)?;
        }
        Ok(())
    }
}

/// An NV12 frame of one colour: `height` rows of Y, then `height / 2` rows
/// of interleaved U, V, each `pitch` bytes apart.
unsafe fn fill(scan0: *mut u8, pitch: usize, width: usize, height: usize, (y, u, v): (u8, u8, u8)) {
    for row in 0..height {
        unsafe { std::ptr::write_bytes(scan0.add(row * pitch), y, width) };
    }
    let uv = unsafe { scan0.add(pitch * height) };
    for row in 0..height / 2 {
        let line = unsafe { uv.add(row * pitch) };
        for col in 0..width / 2 {
            unsafe {
                *line.add(col * 2) = u;
                *line.add(col * 2 + 1) = v;
            }
        }
    }
}

impl IMFMediaEventGenerator_Impl for Stream_Impl {
    fn GetEvent(&self, flags: MEDIA_EVENT_GENERATOR_GET_EVENT_FLAGS) -> windows::core::Result<IMFMediaEvent> {
        let queue = self.0.lock().queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        unsafe { queue.GetEvent(flags.0 as u32) }
    }
    fn BeginGetEvent(&self, callback: Ref<IMFAsyncCallback>, state: Ref<IUnknown>) -> windows::core::Result<()> {
        let queue = self.0.lock().queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        unsafe { queue.BeginGetEvent(callback.as_ref(), state.as_ref()) }
    }
    fn EndGetEvent(&self, result: Ref<IMFAsyncResult>) -> windows::core::Result<IMFMediaEvent> {
        let queue = self.0.lock().queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        unsafe { queue.EndGetEvent(result.as_ref()) }
    }
    fn QueueEvent(&self, met: u32, ext: *const GUID, status: HRESULT, value: *const PROPVARIANT) -> windows::core::Result<()> {
        let queue = self.0.lock().queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        unsafe { queue.QueueEventParamVar(met, ext, status, value) }
    }
}

impl IMFMediaStream_Impl for Stream_Impl {
    fn GetMediaSource(&self) -> windows::core::Result<IMFMediaSource> {
        self.0.lock().source.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))
    }
    fn GetStreamDescriptor(&self) -> windows::core::Result<IMFStreamDescriptor> {
        self.0.lock().descriptor.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))
    }
    fn RequestSample(&self, token: Ref<IUnknown>) -> windows::core::Result<()> {
        let mut s = self.0.lock();
        if s.queue.is_none() {
            return Err(MF_E_SHUTDOWN.into());
        }
        if s.state != MF_STREAM_STATE_RUNNING {
            return Err(MF_E_INVALIDREQUEST.into());
        }
        s.tokens.push_back(token.cloned());
        Ok(())
    }
}

impl IMFMediaStream2_Impl for Stream_Impl {
    fn SetStreamState(&self, value: MF_STREAM_STATE) -> windows::core::Result<()> {
        let current = self.0.lock().state;
        if current == value {
            return Ok(());
        }
        match value {
            MF_STREAM_STATE_PAUSED if current == MF_STREAM_STATE_RUNNING => {
                self.0.lock().state = value;
                Ok(())
            }
            MF_STREAM_STATE_RUNNING => self.0.start(None, false),
            MF_STREAM_STATE_STOPPED => self.0.stop(false),
            _ => Err(MF_E_INVALID_STATE_TRANSITION.into()),
        }
    }
    fn GetStreamState(&self) -> windows::core::Result<MF_STREAM_STATE> {
        Ok(self.0.lock().state)
    }
}

impl IKsControl_Impl for Stream_Impl {
    fn KsProperty(&self, _: *const KSIDENTIFIER, _: u32, _: *mut core::ffi::c_void, _: u32, _: *mut u32) -> windows::core::Result<()> {
        Err(SET_NOT_FOUND.into())
    }
    fn KsMethod(&self, _: *const KSIDENTIFIER, _: u32, _: *mut core::ffi::c_void, _: u32, _: *mut u32) -> windows::core::Result<()> {
        Err(SET_NOT_FOUND.into())
    }
    fn KsEvent(&self, _: *const KSIDENTIFIER, _: u32, _: *mut core::ffi::c_void, _: u32, _: *mut u32) -> windows::core::Result<()> {
        Err(SET_NOT_FOUND.into())
    }
}

// ---- the source -------------------------------------------------------------

struct SourceState {
    queue: Option<IMFMediaEventQueue>,
    descriptor: Option<IMFPresentationDescriptor>,
    attributes: Option<IMFAttributes>,
    started: bool,
}

#[implement(IMFMediaSourceEx, IMFMediaSource, IMFMediaEventGenerator, IMFGetService, IKsControl, IMFSampleAllocatorControl)]
struct Source {
    inner: Mutex<SourceState>,
    stream: Arc<StreamCore>,
    stream_com: IMFMediaStream,
}

impl Source {
    fn lock(&self) -> std::sync::MutexGuard<'_, SourceState> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

fn create_source(colour: u32, activate_attributes: &IMFAttributes) -> windows::core::Result<IMFMediaSource> {
    unsafe {
        let mut attributes = None;
        MFCreateAttributes(&mut attributes, 4)?;
        let attributes = attributes.ok_or(windows::core::Error::from(E_POINTER))?;
        activate_attributes.CopyAllItems(&attributes)?;
        // A legacy profile is mandatory, so profile-unaware apps still work.
        let profiles = MFCreateSensorProfileCollection()?;
        let profile = MFCreateSensorProfile(&KSCAMERAPROFILE_LEGACY, 0, PCWSTR::null())?;
        profile.AddProfileFilter(0, windows::core::w!("((RES==;FRT<=30,1;SUT==))"))?;
        profiles.AddProfile(&profile)?;
        attributes.SetUnknown(&MF_DEVICEMFT_SENSORPROFILE_COLLECTION, &profiles)?;

        let types: Vec<Option<IMFMediaType>> =
            FORMATS.iter().map(|&(w, h, f)| media_type(w, h, f).ok()).collect();
        if types.iter().any(Option::is_none) {
            return Err(E_INVALIDARG.into());
        }
        let descriptor = MFCreateStreamDescriptor(0, &types)?;
        descriptor.GetMediaTypeHandler()?.SetCurrentMediaType(types[0].as_ref().unwrap())?;
        for store in [&descriptor.cast::<IMFAttributes>()?] {
            store.SetGUID(&MF_DEVICESTREAM_STREAM_CATEGORY, &PINNAME_VIDEO_CAPTURE)?;
            store.SetUINT32(&MF_DEVICESTREAM_STREAM_ID, 0)?;
            store.SetUINT32(&MF_DEVICESTREAM_FRAMESERVER_SHARED, 1)?;
            store.SetUINT32(&MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, MFFrameSourceTypes_Color.0 as u32)?;
        }
        let mut stream_attributes = None;
        MFCreateAttributes(&mut stream_attributes, 4)?;
        let stream_attributes = stream_attributes.ok_or(windows::core::Error::from(E_POINTER))?;
        stream_attributes.SetGUID(&MF_DEVICESTREAM_STREAM_CATEGORY, &PINNAME_VIDEO_CAPTURE)?;
        stream_attributes.SetUINT32(&MF_DEVICESTREAM_STREAM_ID, 0)?;
        stream_attributes.SetUINT32(&MF_DEVICESTREAM_FRAMESERVER_SHARED, 1)?;
        stream_attributes.SetUINT32(&MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, MFFrameSourceTypes_Color.0 as u32)?;

        let core = Arc::new(StreamCore {
            colour,
            inner: Mutex::new(StreamState {
                queue: Some(MFCreateEventQueue()?),
                descriptor: Some(descriptor.clone()),
                attributes: Some(stream_attributes),
                source: None,
                allocator: None,
                state: MF_STREAM_STATE_STOPPED,
                format: FORMATS[0],
                tokens: VecDeque::new(),
            }),
            generation: AtomicU64::new(0),
        });
        let stream_com: IMFMediaStream = Stream(core.clone()).into();
        let presentation = MFCreatePresentationDescriptor(Some(&[Some(descriptor)]))?;
        let source: IMFMediaSource = Source {
            inner: Mutex::new(SourceState {
                queue: Some(MFCreateEventQueue()?),
                descriptor: Some(presentation),
                attributes: Some(attributes),
                started: false,
            }),
            stream: core.clone(),
            stream_com,
        }
        .into();
        core.lock().source = Some(source.clone());
        Ok(source)
    }
}

impl IMFMediaEventGenerator_Impl for Source_Impl {
    fn GetEvent(&self, flags: MEDIA_EVENT_GENERATOR_GET_EVENT_FLAGS) -> windows::core::Result<IMFMediaEvent> {
        let queue = self.lock().queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        unsafe { queue.GetEvent(flags.0 as u32) }
    }
    fn BeginGetEvent(&self, callback: Ref<IMFAsyncCallback>, state: Ref<IUnknown>) -> windows::core::Result<()> {
        let queue = self.lock().queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        unsafe { queue.BeginGetEvent(callback.as_ref(), state.as_ref()) }
    }
    fn EndGetEvent(&self, result: Ref<IMFAsyncResult>) -> windows::core::Result<IMFMediaEvent> {
        let queue = self.lock().queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        unsafe { queue.EndGetEvent(result.as_ref()) }
    }
    fn QueueEvent(&self, met: u32, ext: *const GUID, status: HRESULT, value: *const PROPVARIANT) -> windows::core::Result<()> {
        let queue = self.lock().queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        unsafe { queue.QueueEventParamVar(met, ext, status, value) }
    }
}

impl IMFMediaSource_Impl for Source_Impl {
    fn GetCharacteristics(&self) -> windows::core::Result<u32> {
        Ok(MFMEDIASOURCE_IS_LIVE.0 as u32)
    }
    fn CreatePresentationDescriptor(&self) -> windows::core::Result<IMFPresentationDescriptor> {
        let pd = self.lock().descriptor.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?;
        unsafe { pd.Clone() }
    }
    fn Start(&self, pd: Ref<IMFPresentationDescriptor>, format: *const GUID, start: *const PROPVARIANT) -> windows::core::Result<()> {
        let pd = pd.ok()?;
        if start.is_null() {
            return Err(E_INVALIDARG.into());
        }
        if !format.is_null() && unsafe { *format } != GUID::zeroed() {
            return Err(MF_E_UNSUPPORTED_TIME_FORMAT.into());
        }
        let (queue, ours) = {
            let s = self.lock();
            (
                s.queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?,
                s.descriptor.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?,
            )
        };
        unsafe {
            let mut selected = BOOL(0);
            let mut desc = None;
            pd.GetStreamDescriptorByIndex(0, &mut selected, &mut desc)?;
            let desc = desc.ok_or(windows::core::Error::from(E_INVALIDARG))?;
            let mut was = BOOL(0);
            let mut _ours_desc = None;
            ours.GetStreamDescriptorByIndex(0, &mut was, &mut _ours_desc)?;
            if selected.as_bool() {
                ours.SelectStream(0)?;
                let t = desc.GetMediaTypeHandler()?.GetCurrentMediaType()?;
                let met = if was.as_bool() { MEUpdatedStream } else { MENewStream };
                queue.QueueEventParamUnk(met.0 as u32, &GUID::zeroed(), S_OK, &self.stream_com)?;
                self.stream.start(Some(t), true)?;
            } else if was.as_bool() {
                ours.DeselectStream(0)?;
                self.stream.stop(false)?;
            }
            let mut time = PROPVARIANT::default();
            (*time.Anonymous.Anonymous).vt = windows::Win32::System::Variant::VT_I8;
            (*time.Anonymous.Anonymous).Anonymous.hVal = MFGetSystemTime();
            queue.QueueEventParamVar(MESourceStarted.0 as u32, &GUID::zeroed(), S_OK, &time)?;
        }
        self.lock().started = true;
        Ok(())
    }
    fn Stop(&self) -> windows::core::Result<()> {
        let (queue, pd) = {
            let mut s = self.lock();
            s.started = false;
            (
                s.queue.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?,
                s.descriptor.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))?,
            )
        };
        self.stream.stop(true)?;
        unsafe {
            pd.DeselectStream(0)?;
            let mut time = PROPVARIANT::default();
            (*time.Anonymous.Anonymous).vt = windows::Win32::System::Variant::VT_I8;
            (*time.Anonymous.Anonymous).Anonymous.hVal = MFGetSystemTime();
            queue.QueueEventParamVar(MESourceStopped.0 as u32, &GUID::zeroed(), S_OK, &time)
        }
    }
    fn Pause(&self) -> windows::core::Result<()> {
        Err(MF_E_INVALID_STATE_TRANSITION.into())
    }
    fn Shutdown(&self) -> windows::core::Result<()> {
        let _ = self.stream.stop(false);
        {
            let mut st = self.stream.lock();
            if let Some(q) = st.queue.take() {
                unsafe {
                    let _ = q.Shutdown();
                }
            }
            st.source = None;
            st.descriptor = None;
            st.attributes = None;
            if let Some(a) = st.allocator.take() {
                unsafe {
                    let _ = a.UninitializeSampleAllocator();
                }
            }
        }
        let mut s = self.lock();
        if let Some(q) = s.queue.take() {
            unsafe {
                let _ = q.Shutdown();
            }
        }
        s.descriptor = None;
        s.attributes = None;
        Ok(())
    }
}

impl IMFMediaSourceEx_Impl for Source_Impl {
    fn GetSourceAttributes(&self) -> windows::core::Result<IMFAttributes> {
        self.lock().attributes.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))
    }
    fn GetStreamAttributes(&self, id: u32) -> windows::core::Result<IMFAttributes> {
        if id != 0 {
            return Err(MF_E_NOT_FOUND.into());
        }
        self.stream.lock().attributes.clone().ok_or(windows::core::Error::from(MF_E_SHUTDOWN))
    }
    fn SetD3DManager(&self, _: Ref<IUnknown>) -> windows::core::Result<()> {
        // CPU samples only: the frames are one memset of a colour.
        Err(E_NOTIMPL.into())
    }
}

impl IMFGetService_Impl for Source_Impl {
    fn GetService(&self, _: *const GUID, _: *const GUID, out: *mut *mut core::ffi::c_void) -> windows::core::Result<()> {
        if !out.is_null() {
            unsafe { *out = std::ptr::null_mut() };
        }
        Err(MF_E_UNSUPPORTED_SERVICE.into())
    }
}

impl IKsControl_Impl for Source_Impl {
    fn KsProperty(&self, _: *const KSIDENTIFIER, _: u32, _: *mut core::ffi::c_void, _: u32, _: *mut u32) -> windows::core::Result<()> {
        Err(SET_NOT_FOUND.into())
    }
    fn KsMethod(&self, _: *const KSIDENTIFIER, _: u32, _: *mut core::ffi::c_void, _: u32, _: *mut u32) -> windows::core::Result<()> {
        Err(SET_NOT_FOUND.into())
    }
    fn KsEvent(&self, _: *const KSIDENTIFIER, _: u32, _: *mut core::ffi::c_void, _: u32, _: *mut u32) -> windows::core::Result<()> {
        Err(SET_NOT_FOUND.into())
    }
}

impl IMFSampleAllocatorControl_Impl for Source_Impl {
    fn SetDefaultAllocator(&self, id: u32, allocator: Ref<IUnknown>) -> windows::core::Result<()> {
        if id != 0 {
            return Err(MF_E_NOT_FOUND.into());
        }
        let allocator: IMFVideoSampleAllocator = allocator.ok()?.cast()?;
        self.stream.lock().allocator = Some(allocator);
        Ok(())
    }
    fn GetAllocatorUsage(&self, id: u32, input: *mut u32, usage: *mut MFSampleAllocatorUsage) -> windows::core::Result<()> {
        if input.is_null() || usage.is_null() {
            return Err(E_POINTER.into());
        }
        unsafe {
            *input = id;
            *usage = MFSampleAllocatorUsage_UsesProvidedAllocator;
        }
        Ok(())
    }
}

// ---- the activator and the class factory -------------------------------------

#[implement(IMFActivate, IMFAttributes)]
struct Activate {
    colour: u32,
    attributes: IMFAttributes,
    source: Mutex<Option<Shared<IMFMediaSource>>>,
}

impl IMFActivate_Impl for Activate_Impl {
    fn ActivateObject(&self, riid: *const GUID, ppv: *mut *mut core::ffi::c_void) -> windows::core::Result<()> {
        if ppv.is_null() {
            return Err(E_POINTER.into());
        }
        let mut slot = self.source.lock().unwrap_or_else(|e| e.into_inner());
        if slot.is_none() {
            *slot = Some(Shared(create_source(self.colour, &self.attributes)?));
        }
        let source = &slot.as_ref().unwrap().0;
        unsafe { source.query(riid, ppv).ok() }
    }
    fn ShutdownObject(&self) -> windows::core::Result<()> {
        Ok(())
    }
    fn DetachObject(&self) -> windows::core::Result<()> {
        *self.source.lock().unwrap_or_else(|e| e.into_inner()) = None;
        Ok(())
    }
}

impl IMFAttributes_Impl for Activate_Impl {
    fn GetItem(&self, key: *const GUID, value: *mut PROPVARIANT) -> windows::core::Result<()> {
        unsafe { self.attributes.GetItem(key, (!value.is_null()).then_some(value)) }
    }
    fn GetItemType(&self, key: *const GUID) -> windows::core::Result<MF_ATTRIBUTE_TYPE> {
        unsafe { self.attributes.GetItemType(key) }
    }
    fn CompareItem(&self, key: *const GUID, value: *const PROPVARIANT) -> windows::core::Result<BOOL> {
        unsafe { self.attributes.CompareItem(key, value) }
    }
    fn Compare(&self, theirs: Ref<IMFAttributes>, how: MF_ATTRIBUTES_MATCH_TYPE) -> windows::core::Result<BOOL> {
        unsafe { self.attributes.Compare(theirs.as_ref(), how) }
    }
    fn GetUINT32(&self, key: *const GUID) -> windows::core::Result<u32> {
        unsafe { self.attributes.GetUINT32(key) }
    }
    fn GetUINT64(&self, key: *const GUID) -> windows::core::Result<u64> {
        unsafe { self.attributes.GetUINT64(key) }
    }
    fn GetDouble(&self, key: *const GUID) -> windows::core::Result<f64> {
        unsafe { self.attributes.GetDouble(key) }
    }
    fn GetGUID(&self, key: *const GUID) -> windows::core::Result<GUID> {
        unsafe { self.attributes.GetGUID(key) }
    }
    fn GetStringLength(&self, key: *const GUID) -> windows::core::Result<u32> {
        unsafe { self.attributes.GetStringLength(key) }
    }
    fn GetString(&self, key: *const GUID, out: PWSTR, cap: u32, len: *mut u32) -> windows::core::Result<()> {
        let buf = unsafe { std::slice::from_raw_parts_mut(out.0, cap as usize) };
        unsafe { self.attributes.GetString(key, buf, (!len.is_null()).then_some(len)) }
    }
    fn GetAllocatedString(&self, key: *const GUID, out: *mut PWSTR, len: *mut u32) -> windows::core::Result<()> {
        unsafe { self.attributes.GetAllocatedString(key, out, len) }
    }
    fn GetBlobSize(&self, key: *const GUID) -> windows::core::Result<u32> {
        unsafe { self.attributes.GetBlobSize(key) }
    }
    fn GetBlob(&self, key: *const GUID, buf: *mut u8, cap: u32, size: *mut u32) -> windows::core::Result<()> {
        let buf = unsafe { std::slice::from_raw_parts_mut(buf, cap as usize) };
        unsafe { self.attributes.GetBlob(key, buf, (!size.is_null()).then_some(size)) }
    }
    fn GetAllocatedBlob(&self, key: *const GUID, buf: *mut *mut u8, size: *mut u32) -> windows::core::Result<()> {
        unsafe { self.attributes.GetAllocatedBlob(key, buf, size) }
    }
    fn GetUnknown(&self, key: *const GUID, riid: *const GUID, ppv: *mut *mut core::ffi::c_void) -> windows::core::Result<()> {
        unsafe { (Interface::vtable(&self.attributes).GetUnknown)(Interface::as_raw(&self.attributes), key, riid, ppv).ok() }
    }
    fn SetItem(&self, key: *const GUID, value: *const PROPVARIANT) -> windows::core::Result<()> {
        unsafe { self.attributes.SetItem(key, value) }
    }
    fn DeleteItem(&self, key: *const GUID) -> windows::core::Result<()> {
        unsafe { self.attributes.DeleteItem(key) }
    }
    fn DeleteAllItems(&self) -> windows::core::Result<()> {
        unsafe { self.attributes.DeleteAllItems() }
    }
    fn SetUINT32(&self, key: *const GUID, value: u32) -> windows::core::Result<()> {
        unsafe { self.attributes.SetUINT32(key, value) }
    }
    fn SetUINT64(&self, key: *const GUID, value: u64) -> windows::core::Result<()> {
        unsafe { self.attributes.SetUINT64(key, value) }
    }
    fn SetDouble(&self, key: *const GUID, value: f64) -> windows::core::Result<()> {
        unsafe { self.attributes.SetDouble(key, value) }
    }
    fn SetGUID(&self, key: *const GUID, value: *const GUID) -> windows::core::Result<()> {
        unsafe { self.attributes.SetGUID(key, value) }
    }
    fn SetString(&self, key: *const GUID, value: &PCWSTR) -> windows::core::Result<()> {
        unsafe { self.attributes.SetString(key, *value) }
    }
    fn SetBlob(&self, key: *const GUID, buf: *const u8, size: u32) -> windows::core::Result<()> {
        let buf = unsafe { std::slice::from_raw_parts(buf, size as usize) };
        unsafe { self.attributes.SetBlob(key, buf) }
    }
    fn SetUnknown(&self, key: *const GUID, value: Ref<IUnknown>) -> windows::core::Result<()> {
        unsafe { self.attributes.SetUnknown(key, value.as_ref()) }
    }
    fn LockStore(&self) -> windows::core::Result<()> {
        unsafe { self.attributes.LockStore() }
    }
    fn UnlockStore(&self) -> windows::core::Result<()> {
        unsafe { self.attributes.UnlockStore() }
    }
    fn GetCount(&self) -> windows::core::Result<u32> {
        unsafe { self.attributes.GetCount() }
    }
    fn GetItemByIndex(&self, index: u32, key: *mut GUID, value: *mut PROPVARIANT) -> windows::core::Result<()> {
        unsafe { self.attributes.GetItemByIndex(index, key, (!value.is_null()).then_some(value)) }
    }
    fn CopyAllItems(&self, dest: Ref<IMFAttributes>) -> windows::core::Result<()> {
        unsafe { self.attributes.CopyAllItems(dest.as_ref()) }
    }
}

#[implement(IClassFactory)]
struct Factory {
    clsid: GUID,
    colour: u32,
}

impl IClassFactory_Impl for Factory_Impl {
    fn CreateInstance(&self, outer: Ref<IUnknown>, riid: *const GUID, ppv: *mut *mut core::ffi::c_void) -> windows::core::Result<()> {
        if ppv.is_null() {
            return Err(E_POINTER.into());
        }
        unsafe { *ppv = std::ptr::null_mut() };
        if outer.is_some() {
            return Err(windows::Win32::Foundation::CLASS_E_NOAGGREGATION.into());
        }
        let attributes = unsafe {
            let mut a = None;
            MFCreateAttributes(&mut a, 2)?;
            a.ok_or(windows::core::Error::from(E_POINTER))?
        };
        unsafe {
            attributes.SetUINT32(&MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES, 1)?;
            attributes.SetGUID(&MFT_TRANSFORM_CLSID_Attribute, &self.clsid)?;
        }
        let activate: IMFActivate = Activate { colour: self.colour, attributes, source: Mutex::new(None) }.into();
        unsafe { activate.query(riid, ppv).ok() }
    }
    fn LockServer(&self, _: BOOL) -> windows::core::Result<()> {
        Ok(())
    }
}

/// # Safety
/// COM's own entry: the pointers are COM's.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn DllGetClassObject(clsid: *const GUID, riid: *const GUID, ppv: *mut *mut core::ffi::c_void) -> HRESULT {
    if clsid.is_null() || riid.is_null() || ppv.is_null() {
        return E_POINTER;
    }
    unsafe { *ppv = std::ptr::null_mut() };
    let wanted = unsafe { *clsid };
    let Some(&(clsid, colour)) = CAMERAS.iter().find(|(c, _)| *c == wanted) else {
        return CLASS_E_CLASSNOTAVAILABLE;
    };
    let factory: IClassFactory = Factory { clsid, colour }.into();
    unsafe { factory.query(riid, ppv) }
}

/// The Frame Server keeps the DLL loaded while it serves a camera.
#[unsafe(no_mangle)]
pub extern "system" fn DllCanUnloadNow() -> HRESULT {
    S_FALSE
}
