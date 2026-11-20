//! The voice output on GTK (docs/capture-plan.md §5): a PipeWire stream of
//! kaya's own (gtk/voice_stream.c) whose process callback pulls the core's
//! queue, as a `media.role=Phone` stream. The voice path is PipeWire's
//! echo-cancel sink when the desktop loaded the module, which the stream then
//! targets; kaya loads no module into a user's session, so without it the
//! stream plays `plain` (the Linux carve-out, stated once in §5).

use super::*;
use crate::protocol::{VoiceId, VoiceRoute};
use gstreamer as gst;
use gstreamer::prelude::{DeviceExt, DeviceMonitorExt, DeviceMonitorExtManual};
use std::ffi::{c_char, c_void, CStr, CString};

#[repr(C)]
struct VoiceStream {
    _opaque: [u8; 0],
}

type VoicePull = unsafe extern "C" fn(user: *mut c_void, out: *mut f32, frames: u32);
type VoiceFailed = unsafe extern "C" fn(user: *mut c_void, why: *const c_char);

unsafe extern "C" {
    fn voice_stream_new(
        target: *const c_char,
        rate: u32,
        pull: VoicePull,
        failed: VoiceFailed,
        user: *mut c_void,
        why: *mut c_char,
        why_len: usize,
    ) -> *mut VoiceStream;
    fn voice_stream_free(stream: *mut VoiceStream);
}

struct Output(*mut VoiceStream);

impl Drop for Output {
    fn drop(&mut self) {
        // SAFETY: the pointer came from voice_stream_new and is freed once, here.
        unsafe { voice_stream_free(self.0) }
    }
}

thread_local! {
    static OUTPUTS: std::cell::RefCell<HashMap<u64, Output>> = std::cell::RefCell::new(HashMap::new());
}

/// PipeWire's echo-cancel sink, as GStreamer's device monitor lists it.
fn echo_cancel_sink() -> Option<String> {
    let monitor = gst::DeviceMonitor::new();
    monitor.add_filter(Some("Audio/Sink"), None);
    if monitor.start().is_err() {
        return None;
    }
    let found = monitor.devices().iter().find_map(|d| {
        let name = d.properties()?.get::<String>("node.name").ok()?;
        name.contains("echo-cancel").then_some(name)
    });
    monitor.stop();
    found
}

fn report(core: &mut CoreState, id: u64, route: VoiceRoute, detail: String) {
    for occ in core.scene.voice_route(VoiceId(id), route, detail) {
        core.occurrences.send(occ);
    }
}

unsafe extern "C" fn pull(user: *mut c_void, out: *mut f32, frames: u32) {
    // SAFETY: voice_stream.c hands a mapped buffer of at least `frames` floats.
    let out = unsafe { std::slice::from_raw_parts_mut(out, frames as usize) };
    crate::farend::pull(VoiceId(user as u64), crate::capture::SAMPLE_RATE, 1, out);
}

unsafe extern "C" fn failed(user: *mut c_void, why: *const c_char) {
    let id = user as u64;
    // SAFETY: voice_stream.c passes a NUL-terminated message.
    let why = unsafe { CStr::from_ptr(why) }.to_string_lossy().into_owned();
    glib::MainContext::default().invoke(move || {
        CORE.with_borrow_mut(|core| {
            if let Some(core) = core.as_mut() {
                report(core, id, VoiceRoute::Failed, format!("the voice stream failed: {why}"));
            }
        });
    });
}

pub(super) fn create(core: &mut CoreState, id: u64) {
    if let Err(e) = gst::init() {
        return report(core, id, VoiceRoute::Failed, format!("GStreamer did not initialize: {e}"));
    }
    let canceller = echo_cancel_sink();
    let target = canceller.as_deref().map(|n| CString::new(n).expect("a node name holds no NUL"));
    let mut why = [0 as c_char; 256];
    // SAFETY: the callbacks are 'static; `user` is the voice id, not a pointer.
    let stream = unsafe {
        voice_stream_new(
            target.as_ref().map_or(std::ptr::null(), |t| t.as_ptr()),
            crate::capture::SAMPLE_RATE,
            pull,
            failed,
            id as *mut c_void,
            why.as_mut_ptr(),
            why.len(),
        )
    };
    if stream.is_null() {
        // SAFETY: voice_stream.c wrote a NUL-terminated message into `why`.
        let why = unsafe { CStr::from_ptr(why.as_ptr()) }.to_string_lossy().into_owned();
        return report(core, id, VoiceRoute::Failed, format!("the voice stream would not start: {why}"));
    }
    OUTPUTS.with_borrow_mut(|o| o.insert(id, Output(stream)));
    let (route, detail) = match canceller {
        Some(node) => (VoiceRoute::Voice, format!("a PipeWire stream, media.role=Phone, into PipeWire's echo-cancel sink {node:?}")),
        None => (
            VoiceRoute::Plain,
            "a PipeWire stream, media.role=Phone, on the default sink: PipeWire lists no echo-cancel sink, and kaya \
             loads no module into the session (docs/capture-plan.md §5)"
                .to_owned(),
        ),
    };
    report(core, id, route, detail);
}

pub(super) fn release(id: u64) {
    let out = OUTPUTS.with_borrow_mut(|o| o.remove(&id));
    drop(out);
}
