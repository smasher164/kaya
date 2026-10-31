//! The voice output on GTK (docs/capture-plan.md §5): GStreamer beside GTK,
//! an appsrc pulling the core's queue at the rate PipeWire consumes it, into
//! pipewiresink as a `media.role=Phone` stream. The voice path is PipeWire's
//! echo-cancel sink when the desktop loaded the module, which the stream then
//! targets; kaya loads no module into a user's session, so without it the
//! stream plays `plain` (the Linux carve-out, stated once in §5).

use super::*;
use crate::protocol::{VoiceId, VoiceRoute};
use gstreamer as gst;
use gstreamer::prelude::{DeviceExt, DeviceMonitorExt, DeviceMonitorExtManual, ElementExt, GstBinExtManual};

/// The frames each pull asks for: 10 ms at 48 kHz, the core's chunk.
const PULL: usize = 480;

struct Output {
    pipeline: gst::Pipeline,
    _watch: gst::bus::BusWatchGuard,
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

fn fail_later(id: u64, detail: String) {
    glib::idle_add_local_once(move || {
        CORE.with_borrow_mut(|core| {
            if let Some(core) = core.as_mut() {
                report(core, id, VoiceRoute::Failed, detail);
            }
        });
    });
}

pub(super) fn create(core: &mut CoreState, id: u64) {
    let built = (|| -> Result<(gst::Pipeline, VoiceRoute, String), String> {
        gst::init().map_err(|e| format!("GStreamer did not initialize: {e}"))?;
        let make = |name: &str| gst::ElementFactory::make(name).build().map_err(|e| format!("no {name}: {e}"));
        let src = gstreamer_app::AppSrc::builder()
            .caps(
                &gst::Caps::builder("audio/x-raw")
                    .field("format", "F32LE")
                    .field("layout", "interleaved")
                    .field("rate", crate::capture::SAMPLE_RATE as i32)
                    .field("channels", 1i32)
                    .build(),
            )
            .format(gst::Format::Time)
            .is_live(true)
            .max_bytes((PULL * 4 * 4) as u64)
            .build();
        let pushed = std::cell::Cell::new(0u64);
        src.set_callbacks(
            gstreamer_app::AppSrcCallbacks::builder()
                .need_data(move |src, _| {
                    let mut chunk = vec![0f32; PULL];
                    crate::farend::pull(VoiceId(id), crate::capture::SAMPLE_RATE, 1, &mut chunk);
                    let bytes: Vec<u8> = chunk.iter().flat_map(|s| s.to_le_bytes()).collect();
                    let mut buffer = gst::Buffer::from_mut_slice(bytes);
                    let at = pushed.get();
                    if let Some(b) = buffer.get_mut() {
                        b.set_pts(gst::ClockTime::from_nseconds(at * 1_000_000_000 / u64::from(crate::capture::SAMPLE_RATE)));
                        b.set_duration(gst::ClockTime::from_mseconds(10));
                    }
                    pushed.set(at + PULL as u64);
                    let _ = src.push_buffer(buffer);
                })
                .build(),
        );
        let convert = make("audioconvert")?;
        let resample = make("audioresample")?;
        let sink = make("pipewiresink")?;
        sink.set_property("stream-properties", gst::Structure::builder("props").field("media.role", "Phone").build());
        let canceller = echo_cancel_sink();
        let (route, detail) = match &canceller {
            Some(node) => {
                sink.set_property("target-object", node);
                (VoiceRoute::Voice, format!("pipewiresink, media.role=Phone, into PipeWire's echo-cancel sink {node:?}"))
            }
            None => (
                VoiceRoute::Plain,
                "pipewiresink, media.role=Phone, on the default sink: PipeWire lists no echo-cancel sink, and kaya \
                 loads no module into the session (docs/capture-plan.md §5)"
                    .to_owned(),
            ),
        };
        let pipeline = gst::Pipeline::new();
        let src: gst::Element = src.upcast();
        pipeline.add_many([&src, &convert, &resample, &sink]).map_err(|e| e.to_string())?;
        gst::Element::link_many([&src, &convert, &resample, &sink]).map_err(|e| e.to_string())?;
        Ok((pipeline, route, detail))
    })();
    let (pipeline, route, detail) = match built {
        Ok(b) => b,
        Err(why) => return report(core, id, VoiceRoute::Failed, format!("the voice pipeline would not build: {why}")),
    };
    let bus = pipeline.bus().expect("a pipeline has a bus");
    let watch = bus
        .add_watch_local(move |_, msg| {
            if let gst::MessageView::Error(e) = msg.view() {
                fail_later(id, format!("{} ({})", e.error(), e.debug().unwrap_or_default()));
            }
            glib::ControlFlow::Continue
        })
        .expect("one watch per bus");
    if let Err(e) = pipeline.set_state(gst::State::Playing) {
        return report(core, id, VoiceRoute::Failed, format!("the voice pipeline would not play: {e}"));
    }
    OUTPUTS.with_borrow_mut(|o| o.insert(id, Output { pipeline, _watch: watch }));
    report(core, id, route, detail);
}

pub(super) fn release(id: u64) {
    if let Some(out) = OUTPUTS.with_borrow_mut(|o| o.remove(&id)) {
        let _ = out.pipeline.set_state(gst::State::Null);
    }
}
