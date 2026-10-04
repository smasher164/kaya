//! The capture arm (docs/capture-plan.md): GStreamer beside GTK. A camera is
//! a PipeWire node reached through the camera portal (AccessCamera, then
//! OpenPipeWireRemote) and on PipeWire directly when no portal answers (§9
//! ruling 5); a microphone is a PipeWire node, which no portal covers. One
//! pipeline per open: pipewiresrc into a tee whose branches are the preview
//! (a GtkPicture over gtk4paintablesink) and the app's NV12 frames (an
//! appsink), and pipewiresrc into an appsink for the samples. Every report
//! reaches the core through `capture_report`, the one door.

use super::*;
use crate::capture::Report;
use crate::protocol::{CameraFacing, CaptureCommand, CaptureDevice, CaptureFailure, CaptureKind, CaptureProp, Permission};
use gstreamer as gst;
use gstreamer::prelude::{
    DeviceExt, DeviceMonitorExt, DeviceMonitorExtManual, ElementExt, GObjectExtManualGst, GstBinExtManual,
    PadExtManual,
};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

const PORTAL_NAME: &str = "org.freedesktop.portal.Desktop";
const PORTAL_PATH: &str = "/org/freedesktop/portal/desktop";
const PORTAL_CAMERA: &str = "org.freedesktop.portal.Camera";
const PORTAL_TIMEOUT_MS: i32 = 30_000;

fn under_harness() -> bool {
    std::env::var_os("KAYA_SELFTEST").is_some()
}

/// THE WALL (docs/capture-plan.md §7): under the harness the one
/// device-open function takes only a lane synthetic device, by the core's
/// table; tools/check-verbs.py holds every PipeWire source inside it.
fn wall(device: &str) {
    if let Some(why) = refusal(device, under_harness()) {
        panic!("{why}");
    }
}

fn refusal(device: &str, harness: bool) -> Option<String> {
    (harness && !device.is_empty() && !crate::capture::SYNTHETIC.iter().any(|s| s.id == device)).then(|| {
        format!(
            "kaya: the capture reaches the device {device:?} under the harness (KAYA_SELFTEST is set); a lane \
             opens kaya's synthetic devices only (docs/capture-plan.md §7)"
        )
    })
}

/// One open of a capture's devices.
struct Open {
    pipeline: gst::Pipeline,
    paintable: Option<gdk::Paintable>,
    /// The camera's frame size, (0, 0) with no camera.
    frames: (u32, u32),
    _watch: gst::bus::BusWatchGuard,
    /// The portal's PipeWire remote, alive as long as the pipeline.
    _remote: Option<std::os::fd::OwnedFd>,
}

#[derive(Default)]
struct GtkCapture {
    camera: String,
    microphone: String,
    wish: (f64, f64, f64),
    running: bool,
    generation: u64,
    open: Option<Open>,
}

/// What waits for the one door, queued so no GStreamer or D-Bus callback
/// borrows CORE (gtk_media's rule).
enum Pending {
    Report(u64, u64, Report),
    Permission(CaptureKind, Permission, String),
    Devices(Vec<CaptureDevice>),
    Repaint(u64),
    Occurrence(Occurrence),
}

thread_local! {
    static CAPTURES: RefCell<HashMap<u64, GtkCapture>> = RefCell::new(HashMap::new());
    static PENDING: RefCell<std::collections::VecDeque<Pending>> = RefCell::new(Default::default());
    static FLUSH_SCHEDULED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static WATCH: RefCell<Option<(gst::DeviceMonitor, gst::bus::BusWatchGuard)>> = const { RefCell::new(None) };
    static REOPEN: RefCell<std::collections::HashSet<u64>> = RefCell::new(Default::default());
}

fn queue(item: Pending) {
    PENDING.with_borrow_mut(|q| q.push_back(item));
    if !FLUSH_SCHEDULED.replace(true) {
        glib::idle_add_local_once(flush);
    }
}

/// From a capture thread: onto the main loop, then the queue.
fn post(item: Pending) {
    glib::MainContext::default().invoke(move || queue(item));
}

fn flush() {
    FLUSH_SCHEDULED.set(false);
    if CORE.with(|c| c.try_borrow_mut().is_err()) {
        if !FLUSH_SCHEDULED.replace(true) {
            glib::timeout_add_local_once(std::time::Duration::from_millis(5), flush);
        }
        return;
    }
    while let Some(item) = PENDING.with_borrow_mut(|q| q.pop_front()) {
        CORE.with_borrow_mut(|core| {
            let Some(core) = core.as_mut() else { return };
            crate::fault::guard("a capture report", || match item {
                Pending::Report(id, generation, r) => {
                    if generation_of(id) == Some(generation) {
                        capture_report(core, id, r);
                    }
                }
                Pending::Permission(kind, permission, detail) => {
                    for occ in core.scene.capture_permission(kind, permission, detail) {
                        core.occurrences.send(occ);
                    }
                }
                Pending::Devices(devices) => {
                    core.scene.capture_devices_begin();
                    for d in devices {
                        core.scene.capture_device(d);
                    }
                    for occ in core.scene.capture_devices_end() {
                        core.occurrences.send(occ);
                    }
                }
                Pending::Repaint(id) => repaint(core, id),
                Pending::Occurrence(occ) => core.occurrences.send(occ),
            });
        });
    }
}

fn generation_of(id: u64) -> Option<u64> {
    CAPTURES.with_borrow(|c| c.get(&id).map(|c| c.generation))
}

/// THE ONE DOOR every capture report takes: the core decides what the app
/// hears; a start the core's clock failed `timeout` is torn down.
fn capture_report(core: &mut CoreState, id: u64, r: Report) {
    let overdue = r == Report::Overdue;
    let published = core.scene.capture_report(crate::protocol::CaptureId(id), r);
    let failed = published.iter().any(|o| {
        matches!(o, Occurrence::CaptureChanged { state: crate::protocol::CaptureState::Failed, .. })
    });
    let torn_down = overdue && crate::capture::timed_out(&published);
    for occ in published {
        core.occurrences.send(occ);
    }
    if torn_down || failed {
        close(id);
        repaint(core, id);
    }
}

fn repaint(core: &mut CoreState, id: u64) {
    let (paintable, frames) = CAPTURES.with_borrow(|c| {
        let open = c.get(&id).and_then(|c| c.open.as_ref());
        (open.and_then(|o| o.paintable.clone()), open.map_or((0, 0), |o| o.frames))
    });
    for view in core.videos.iter().filter(|v| v.capture.get() == Some(id)) {
        self_view_size(view, Some(crate::capture::self_view_natural(frames)));
        view.picture.set_paintable(paintable.as_ref());
        view.picture.queue_draw();
    }
    gtk_media::follow_keep_awake(core);
}

/// A self-view takes the core's natural size with no minimum, so it shrinks
/// to its room (docs/capture-plan.md §3); `None` gives the view back to the
/// player's picture sizing.
fn self_view_size(view: &gtk_media::GtkVideoView, natural: Option<(u32, u32)>) {
    match natural {
        Some((w, h)) => {
            let layout = view
                .picture
                .layout_manager()
                .and_then(|l| l.downcast::<natural_layout::NaturalLayout>().ok())
                .unwrap_or_else(|| {
                    let layout = natural_layout::NaturalLayout::default();
                    view.picture.set_layout_manager(Some(layout.clone()));
                    layout
                });
            layout.set_natural(w as i32, h as i32);
            view.picture.set_size_request(-1, -1);
            let grows = grow_weight(view.overlay.upcast_ref()) > 0.0;
            view.picture.set_halign(if grows { gtk4::Align::Fill } else { gtk4::Align::Center });
        }
        None => {
            view.picture.set_layout_manager(None::<gtk4::LayoutManager>);
            view.picture.set_size_request(gtk_media::VIDEO_PLACEHOLDER.0, gtk_media::VIDEO_PLACEHOLDER.1);
            view.picture.set_halign(gtk4::Align::Fill);
        }
    }
}

mod natural_layout {
    use gtk4::glib;
    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;
    use std::cell::Cell;

    #[derive(Default)]
    pub struct NaturalLayoutInner {
        natural: Cell<(i32, i32)>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for NaturalLayoutInner {
        const NAME: &'static str = "KayaNaturalLayout";
        type Type = NaturalLayout;
        type ParentType = gtk4::LayoutManager;
    }

    impl ObjectImpl for NaturalLayoutInner {}

    impl LayoutManagerImpl for NaturalLayoutInner {
        fn measure(
            &self,
            _widget: &gtk4::Widget,
            orientation: gtk4::Orientation,
            _for_size: i32,
        ) -> (i32, i32, i32, i32) {
            let (w, h) = self.natural.get();
            (0, if orientation == gtk4::Orientation::Horizontal { w } else { h }, -1, -1)
        }

        fn allocate(&self, _widget: &gtk4::Widget, _width: i32, _height: i32, _baseline: i32) {}
    }

    glib::wrapper! {
        pub struct NaturalLayout(ObjectSubclass<NaturalLayoutInner>)
            @extends gtk4::LayoutManager;
    }

    impl Default for NaturalLayout {
        fn default() -> Self {
            glib::Object::new()
        }
    }

    impl NaturalLayout {
        pub fn set_natural(&self, width: i32, height: i32) {
            self.imp().natural.set((width, height));
            self.layout_changed();
        }
    }
}

/// Rule 5: a capture keeps the display awake while its camera is open and
/// previewed (gtk_media::follow_keep_awake asks this).
pub(super) fn previews_a_camera(id: u64) -> bool {
    CAPTURES.with_borrow(|c| c.get(&id).is_some_and(|c| c.open.as_ref().is_some_and(|o| o.paintable.is_some())))
}

pub(super) fn create(id: u64) {
    if let Err(why) = gtk_media::gst_ready() {
        panic!("{why}");
    }
    CAPTURES.with_borrow_mut(|c| c.insert(id, GtkCapture::default()));
}

pub(super) fn set_prop(id: u64, prop: CaptureProp, value: &Value) {
    let reopen = CAPTURES.with_borrow_mut(|c| {
        let Some(c) = c.get_mut(&id) else { return false };
        match (prop, value) {
            (CaptureProp::Camera, Value::Str(s)) => c.camera = s.clone(),
            (CaptureProp::Microphone, Value::Str(s)) => c.microphone = s.clone(),
            (CaptureProp::Width, Value::F64(x)) => c.wish.0 = *x,
            (CaptureProp::Height, Value::F64(x)) => c.wish.1 = *x,
            (CaptureProp::FrameRate, Value::F64(x)) => c.wish.2 = *x,
            // The core keeps the microphone open and delivers the silence.
            (CaptureProp::Muted, Value::Bool(_)) => return false,
            (prop, value) => panic!("kaya: capture prop {prop:?} with {value:?} never reaches a backend"),
        }
        c.running
    });
    // A device change while running reopens (docs/capture-plan.md §2),
    // once for every prop one transaction wrote.
    if reopen && REOPEN.with_borrow_mut(|r| r.insert(id)) {
        glib::idle_add_local_once(move || {
            REOPEN.with_borrow_mut(|r| r.remove(&id));
            if CAPTURES.with_borrow(|c| c.get(&id).is_some_and(|c| c.running)) {
                open(id);
            }
        });
    }
}

pub(super) fn command(id: u64, command: CaptureCommand) {
    match command {
        CaptureCommand::Start => {
            let generation = CAPTURES.with_borrow_mut(|c| {
                let c = c.get_mut(&id)?;
                if c.running {
                    return None;
                }
                c.running = true;
                Some(c.generation)
            });
            if generation.is_none() {
                return;
            }
            open(id);
            let Some(generation) = generation_of(id) else { return };
            glib::timeout_add_local_once(std::time::Duration::from_millis(crate::media::TIMEOUT_MS), move || {
                if CAPTURES.with_borrow(|c| c.get(&id).is_some_and(|c| c.running)) {
                    queue(Pending::Report(id, generation, Report::Overdue));
                }
            });
        }
        CaptureCommand::Stop => {
            CAPTURES.with_borrow_mut(|c| {
                if let Some(c) = c.get_mut(&id) {
                    c.running = false;
                }
            });
            close(id);
            queue(Pending::Repaint(id));
        }
    }
}

pub(super) fn release(core: &mut CoreState, id: u64) {
    close(id);
    CAPTURES.with_borrow_mut(|c| c.remove(&id));
    for view in core.videos.iter().filter(|v| v.capture.get() == Some(id)) {
        view.picture.set_paintable(None::<&gdk::Paintable>);
        view.capture.set(None);
        self_view_size(view, None);
    }
    gtk_media::follow_keep_awake(core);
}

pub(super) fn set_video_capture(core: &mut CoreState, widget: WidgetId, capture: Option<u64>) {
    let Some(view) = core.videos.iter().find(|v| v.id == widget).cloned() else { return };
    view.capture.set(capture);
    match capture {
        Some(id) => repaint(core, id),
        None => {
            view.picture.set_paintable(None::<&gdk::Paintable>);
            self_view_size(&view, None);
            gtk_media::follow_keep_awake(core);
        }
    }
}

/// Pipeline down, views blank; a later report of this open is stale.
fn close(id: u64) {
    let open = CAPTURES.with_borrow_mut(|c| {
        let c = c.get_mut(&id)?;
        c.generation += 1;
        c.open.take()
    });
    if let Some(open) = open {
        let _ = open.pipeline.set_state(gst::State::Null);
    }
}

fn kinds(camera: &str, microphone: &str) -> Vec<CaptureKind> {
    let mut out = Vec::new();
    if !camera.is_empty() {
        out.push(CaptureKind::Camera);
    }
    if !microphone.is_empty() {
        out.push(CaptureKind::Microphone);
    }
    out
}

/// The capture's devices opened afresh: each kind's permission first, then
/// the platform's grant for the camera, then the pipeline.
fn open(id: u64) {
    close(id);
    queue(Pending::Repaint(id));
    let Some((camera, microphone, generation)) =
        CAPTURES.with_borrow(|c| c.get(&id).map(|c| (c.camera.clone(), c.microphone.clone(), c.generation)))
    else {
        return;
    };
    let denied = ask(&kinds(&camera, &microphone)).contains(&Permission::Denied);
    if denied {
        queue(Pending::Report(
            id,
            generation,
            Report::Failed(CaptureFailure::Denied, "the user denied this app the camera or the microphone".to_owned()),
        ));
        return;
    }
    if camera.is_empty() {
        finish(id, generation, None);
        return;
    }
    camera_grant(move |grant| {
        if !under_harness() {
            let answer = if matches!(grant, Grant::Denied(_)) { Permission::Denied } else { Permission::Granted };
            queue(Pending::Permission(CaptureKind::Camera, answer, String::new()));
        }
        match grant {
            Grant::Denied(detail) => {
                queue(Pending::Report(id, generation, Report::Failed(CaptureFailure::Denied, detail)));
            }
            Grant::Portal(fd) => finish(id, generation, Some(fd)),
            Grant::Direct => finish(id, generation, None),
        }
    });
}

/// Each kind's permission in turn, the prompt shown for one still at
/// prompt: under the harness the core's synthetic prompt (OPEN C); off it
/// no permission is asked here, the camera's being the portal's.
fn ask(kinds: &[CaptureKind]) -> Vec<Permission> {
    kinds
        .iter()
        .map(|&kind| {
            if !under_harness() {
                return Permission::Granted;
            }
            let before = crate::capture::synthetic_permission(kind);
            let answer = crate::capture::synthetic_ask(kind);
            if before != answer {
                queue(Pending::Permission(kind, answer, String::new()));
            }
            answer
        })
        .collect()
}

/// request_permission: the synthetic prompt under the harness, the portal's
/// AccessCamera for a camera otherwise; a microphone has no prompt here.
pub(super) fn request_permission(kind: CaptureKind) {
    if under_harness() {
        let answer = crate::capture::synthetic_ask(kind);
        queue(Pending::Permission(kind, answer, String::new()));
        return;
    }
    match kind {
        CaptureKind::Microphone => queue(Pending::Permission(kind, Permission::Granted, String::new())),
        CaptureKind::Camera => camera_grant(move |grant| {
            let (permission, detail) = match grant {
                Grant::Denied(detail) => (Permission::Denied, detail),
                Grant::Portal(_) | Grant::Direct => (Permission::Granted, String::new()),
            };
            queue(Pending::Permission(kind, permission, detail));
        }),
    }
}

/// The platform's answer for the camera.
enum Grant {
    Portal(std::os::fd::OwnedFd),
    Direct,
    Denied(String),
}

/// THE CAMERA PORTAL FIRST, PIPEWIRE DIRECTLY WHEN NO PORTAL ANSWERS (§9
/// ruling 5, GNOME Snapshot's rule): AccessCamera's Request, then
/// OpenPipeWireRemote. A portal that answers no is `denied`, never a
/// fallback. Under the harness the route taken is printed, which is what
/// tools/linux/capture-leg.py asserts.
fn camera_grant(done: impl FnOnce(Grant) + 'static) {
    let route = |grant: Grant, why: &str| {
        if under_harness() {
            let name = match &grant {
                Grant::Portal(_) => "portal",
                Grant::Direct => "direct",
                Grant::Denied(_) => "portal-denied",
            };
            kaya_diag!("KAYA_DIAG capture route: {name} ({why})");
        }
        grant
    };
    let Some(conn) = session_bus() else {
        done(route(Grant::Direct, "no session bus"));
        return;
    };
    let conn2 = conn.clone();
    conn.call(
        Some(PORTAL_NAME),
        PORTAL_PATH,
        "org.freedesktop.DBus.Properties",
        "Get",
        Some(&glib::Variant::tuple_from_iter([PORTAL_CAMERA.to_variant(), "version".to_variant()])),
        None,
        gio::DBusCallFlags::NONE,
        PORTAL_TIMEOUT_MS,
        gio::Cancellable::NONE,
        move |answer| {
            if let Err(why) = answer {
                done(route(Grant::Direct, &format!("no camera portal answers: {why}")));
                return;
            }
            access_camera(conn2, move |grant, why| done(route(grant, &why)));
        },
    );
}

fn access_camera(conn: gio::DBusConnection, done: impl FnOnce(Grant, String) + 'static) {
    static TOKENS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let token = format!("kaya_capture_{}", TOKENS.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
    let sender = conn.unique_name().map(|n| n.trim_start_matches(':').replace('.', "_")).unwrap_or_default();
    let request = format!("{PORTAL_PATH}/request/{sender}/{token}");
    let done: Rc<RefCell<Option<Box<dyn FnOnce(Grant, String)>>>> = Rc::new(RefCell::new(Some(Box::new(done))));
    let held: Rc<RefCell<Option<gio::SignalSubscription>>> = Rc::new(RefCell::new(None));
    let (done2, held2, conn2) = (done.clone(), held.clone(), conn.clone());
    let subscription = conn.subscribe_to_signal(
        Some(PORTAL_NAME),
        Some("org.freedesktop.portal.Request"),
        Some("Response"),
        Some(&request),
        None,
        gio::DBusSignalFlags::NONE,
        move |signal| {
            held2.borrow_mut().take();
            let Some(done) = done2.borrow_mut().take() else { return };
            let response = signal.parameters.child_value(0).get::<u32>().unwrap_or(2);
            if response != 0 {
                done(
                    Grant::Denied(format!("the camera portal answered AccessCamera with response {response}")),
                    format!("AccessCamera response {response}"),
                );
                return;
            }
            open_remote(&conn2, done);
        },
    );
    *held.borrow_mut() = Some(subscription);
    let options = glib::VariantDict::new(None);
    options.insert("handle_token", token.as_str());
    conn.call(
        Some(PORTAL_NAME),
        PORTAL_PATH,
        PORTAL_CAMERA,
        "AccessCamera",
        Some(&glib::Variant::tuple_from_iter([options.end()])),
        None,
        gio::DBusCallFlags::NONE,
        PORTAL_TIMEOUT_MS,
        gio::Cancellable::NONE,
        move |answer| {
            if let Err(why) = answer {
                held.borrow_mut().take();
                if let Some(done) = done.borrow_mut().take() {
                    done(Grant::Direct, format!("AccessCamera failed: {why}"));
                }
            }
        },
    );
}

fn open_remote(conn: &gio::DBusConnection, done: Box<dyn FnOnce(Grant, String)>) {
    conn.call_with_unix_fd_list(
        Some(PORTAL_NAME),
        PORTAL_PATH,
        PORTAL_CAMERA,
        "OpenPipeWireRemote",
        Some(&glib::Variant::tuple_from_iter([glib::VariantDict::new(None).end()])),
        Some(glib::VariantTy::new("(h)").expect("a variant type")),
        gio::DBusCallFlags::NONE,
        PORTAL_TIMEOUT_MS,
        None::<&gio::UnixFDList>,
        gio::Cancellable::NONE,
        move |answer| {
            use gio::prelude::UnixFDListExtManual;
            let fd = answer.map_err(|e| e.to_string()).and_then(|(reply, fds)| {
                let index = reply.child_value(0).get::<glib::variant::Handle>().map(|h| h.0).unwrap_or(-1);
                fds.ok_or_else(|| "no fd list".to_owned())?.get(index).map_err(|e| e.to_string())
            });
            match fd {
                Ok(fd) => done(Grant::Portal(fd), "AccessCamera granted, OpenPipeWireRemote answered".to_owned()),
                Err(why) => done(Grant::Direct, format!("OpenPipeWireRemote failed: {why}")),
            }
        },
    );
}

/// A device as PipeWire lists it.
struct Node {
    name: String,
    description: String,
    camera: bool,
    facing: CameraFacing,
    preferred: bool,
    formats: Vec<(u32, u32, u32)>,
    /// A microphone's own rate and channel count, which a consumer that
    /// converts must ask for: unasked, pipewiresrc's caps fixate at 1 Hz
    /// mono (docs/probes/capture-2026-10-01/linux-measured.md).
    native: Option<(i32, i32)>,
}

/// Every camera and microphone node PipeWire lists now.
fn nodes() -> Vec<Node> {
    let monitor = gst::DeviceMonitor::new();
    monitor.add_filter(Some("Video/Source"), None);
    monitor.add_filter(Some("Audio/Source"), None);
    if monitor.start().is_err() {
        return Vec::new();
    }
    let out = monitor.devices().into_iter().filter_map(|d| node_of(&d)).collect();
    monitor.stop();
    out
}

fn node_of(device: &gst::Device) -> Option<Node> {
    let props = device.properties()?;
    let name = props.get::<String>("node.name").ok()?;
    let camera = device.device_class().starts_with("Video/");
    let location = props.get::<String>("api.libcamera.location").unwrap_or_default();
    let facing = match location.as_str() {
        "front" => CameraFacing::Front,
        "back" => CameraFacing::Back,
        _ if camera => CameraFacing::External,
        _ => CameraFacing::Unknown,
    };
    Some(Node {
        name,
        description: device.display_name().to_string(),
        camera,
        facing,
        preferred: props.get::<bool>("is-default").unwrap_or(false),
        formats: device.caps().map(|c| formats_of(&c)).unwrap_or_default(),
        native: device.caps().and_then(|c| native_of(&c)),
    })
}

/// The raw formats a camera's caps offer as (width, height, frame rate).
fn formats_of(caps: &gst::Caps) -> Vec<(u32, u32, u32)> {
    let mut out = Vec::new();
    for s in caps.iter() {
        if s.name() != "video/x-raw" {
            continue;
        }
        let (Ok(w), Ok(h)) = (s.get::<i32>("width"), s.get::<i32>("height")) else { continue };
        let mut rates = Vec::new();
        if let Ok(f) = s.get::<gst::Fraction>("framerate") {
            rates.push(f);
        } else if let Ok(list) = s.get::<gst::List>("framerate") {
            rates.extend(list.iter().filter_map(|v| v.get::<gst::Fraction>().ok()));
        } else if let Ok(range) = s.get::<gst::FractionRange>("framerate") {
            rates.extend([range.min(), range.max()]);
        }
        for f in rates {
            if f.denom() > 0 && f.numer() > 0 {
                out.push((w as u32, h as u32, (f.numer() / f.denom()) as u32));
            }
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

fn native_of(caps: &gst::Caps) -> Option<(i32, i32)> {
    caps.iter()
        .filter(|s| s.name() == "audio/x-raw")
        .find_map(|s| Some((s.get::<i32>("rate").ok()?, s.get::<i32>("channels").ok()?)))
}

/// OPEN A: under the harness the device list is the core's synthetic
/// table, each entry present only while the lane's node carrying it is.
fn devices() -> Vec<CaptureDevice> {
    let found = nodes();
    if under_harness() {
        return crate::capture::SYNTHETIC
            .iter()
            .filter(|s| found.iter().any(|n| n.name == s.id))
            .map(|s| CaptureDevice {
                id: s.id.to_owned(),
                name: s.name.to_owned(),
                kind: s.kind,
                facing: s.facing,
                preferred: s.preferred,
            })
            .collect();
    }
    found
        .into_iter()
        .map(|n| CaptureDevice {
            id: n.name,
            name: n.description,
            kind: if n.camera { CaptureKind::Camera } else { CaptureKind::Microphone },
            facing: n.facing,
            preferred: n.preferred,
        })
        .collect()
}

/// watch_capture_devices: each kind's standing permission and the list,
/// now and whenever a device comes or goes.
pub(super) fn watch(on: bool) {
    WATCH.with_borrow_mut(|w| {
        if let Some((monitor, _)) = w.take() {
            monitor.stop();
        }
    });
    if !on {
        return;
    }
    if let Err(why) = gtk_media::gst_ready() {
        panic!("{why}");
    }
    for kind in [CaptureKind::Camera, CaptureKind::Microphone] {
        let standing = if under_harness() {
            crate::capture::synthetic_permission(kind)
        } else if kind == CaptureKind::Camera {
            Permission::Prompt
        } else {
            Permission::Granted
        };
        queue(Pending::Permission(kind, standing, String::new()));
    }
    queue(Pending::Devices(devices()));
    let monitor = gst::DeviceMonitor::new();
    monitor.add_filter(Some("Video/Source"), None);
    monitor.add_filter(Some("Audio/Source"), None);
    let bus = monitor.bus();
    let Ok(guard) = bus.add_watch_local(|_, msg| {
        if matches!(msg.view(), gst::MessageView::DeviceAdded(_) | gst::MessageView::DeviceRemoved(_)) {
            queue(Pending::Devices(devices()));
        }
        glib::ControlFlow::Continue
    }) else {
        return;
    };
    if monitor.start().is_ok() {
        WATCH.with_borrow_mut(|w| *w = Some((monitor, guard)));
    }
}

/// The devices resolved and opened, back on the main loop.
fn finish(id: u64, generation: u64, remote: Option<std::os::fd::OwnedFd>) {
    let Some((camera, microphone, wish)) = CAPTURES.with_borrow(|c| {
        let c = c.get(&id)?;
        (c.generation == generation && c.running).then(|| (c.camera.clone(), c.microphone.clone(), c.wish))
    }) else {
        return;
    };
    let fail = |reason, detail: String| queue(Pending::Report(id, generation, Report::Failed(reason, detail)));
    let found = nodes();
    let pick = |want: &str, camera: bool| -> Result<Option<&Node>, String> {
        if want.is_empty() {
            return Ok(None);
        }
        let known = !under_harness()
            || crate::capture::SYNTHETIC.iter().any(|s| s.id == want && (s.kind == CaptureKind::Camera) == camera);
        found
            .iter()
            .find(|n| known && n.name == want && n.camera == camera)
            .map(Some)
            .ok_or_else(|| {
                if under_harness() {
                    format!("no device {want:?}: under the harness only kaya's synthetic devices exist, each where the lane's PipeWire node carrying it is")
                } else {
                    format!("no {} {want:?} among PipeWire's nodes", if camera { "camera" } else { "microphone" })
                }
            })
    };
    let (cam, mic) = match (pick(&camera, true), pick(&microphone, false)) {
        (Ok(c), Ok(m)) => (c, m),
        (Err(why), _) | (_, Err(why)) => return fail(CaptureFailure::NotFound, why),
    };
    let format = match cam {
        None => (0, 0, 0),
        Some(n) => match crate::capture::nearest_format(&n.formats, wish) {
            Some(f) => f,
            None => return fail(CaptureFailure::Unsupported, format!("{:?} offers no raw video format", n.name)),
        },
    };
    let mirror = cam.is_some_and(|n| matches!(facing_of(n), CameraFacing::Front | CameraFacing::External));
    match open_devices(
        id,
        generation,
        cam.map(|n| n.name.as_str()),
        mic.map(|n| (n.name.as_str(), n.native.unwrap_or((48_000, 2)))),
        format,
        mirror,
        remote,
    ) {
        Ok(open) => {
            CAPTURES.with_borrow_mut(|c| {
                if let Some(c) = c.get_mut(&id) {
                    c.open = Some(open);
                }
            });
            queue(Pending::Repaint(id));
        }
        Err((reason, detail)) => fail(reason, detail),
    }
}

/// Rule 4's facing: the synthetic table's under the harness, PipeWire's
/// otherwise.
fn facing_of(node: &Node) -> CameraFacing {
    if under_harness() {
        if let Some(s) = crate::capture::SYNTHETIC.iter().find(|s| s.id == node.name) {
            return s.facing;
        }
    }
    node.facing
}

fn make(factory: &str) -> Result<gst::Element, (CaptureFailure, String)> {
    gst::ElementFactory::make(factory).build().map_err(|e| {
        (
            CaptureFailure::HardwareError,
            format!(
                "kaya: the capture arm needs GStreamer's {factory} ({e}) — gstreamer1.0-pipewire, \
                 gstreamer1.0-gtk4 and gstreamer1.0-plugins-base (docs/capture-plan.md §1)"
            ),
        )
    })
}

/// THE ONE DEVICE-OPEN FUNCTION: every PipeWire source a capture reads is
/// made here, after the wall, each naming its node and refusing any other
/// (tools/check-verbs.py's GTK capture clause).
#[allow(clippy::too_many_arguments)]
fn open_devices(
    id: u64,
    generation: u64,
    camera: Option<&str>,
    microphone: Option<(&str, (i32, i32))>,
    format: (u32, u32, u32),
    mirror: bool,
    remote: Option<std::os::fd::OwnedFd>,
) -> Result<Open, (CaptureFailure, String)> {
    wall(camera.unwrap_or(""));
    wall(microphone.map_or("", |(node, _)| node));
    let pipeline = gst::Pipeline::new();
    let started = Arc::new(AtomicBool::new(false));
    let mut paintable = None;
    let source = |node: &str, media: &str, fd: Option<i32>| -> Result<gst::Element, (CaptureFailure, String)> {
        let src = make("pipewiresrc")?;
        src.set_property("target-object", node);
        src.set_property("client-name", "kaya");
        if let Some(fd) = fd {
            src.set_property("fd", fd);
        }
        // A named device that is absent fails rather than linking to the
        // session's default (docs/probes/capture-2026-10-01/linux-measured.md).
        let props = gst::Structure::builder("props")
            .field("media.type", media)
            .field("media.category", "Capture")
            .field("media.role", if media == "Video" { "Camera" } else { "Communication" })
            .field("node.dont-fallback", true)
            .field("node.dont-reconnect", true)
            .build();
        src.set_property("stream-properties", &props);
        Ok(src)
    };
    if let Some(node) = camera {
        use std::os::fd::AsRawFd;
        let src = source(node, "Video", remote.as_ref().map(|fd| fd.as_raw_fd()))?;
        let (w, h, fps) = format;
        let size = make("capsfilter")?;
        size.set_property(
            "caps",
            gst::Caps::builder("video/x-raw")
                .field("width", w as i32)
                .field("height", h as i32)
                .field("framerate", gst::Fraction::new(fps as i32, 1))
                .build(),
        );
        // A source naming no colorimetry is read as video-range BT.601, a
        // webcam's: GStreamer's default by size would read 720p as BT.709
        // (docs/probes/capture-2026-10-01/linux-measured.md).
        if let Some(pad) = src.static_pad("src") {
            pad.add_probe(gst::PadProbeType::EVENT_DOWNSTREAM, |_, info| {
                if let Some(gst::PadProbeData::Event(event)) = &info.data {
                    if let gst::EventView::Caps(c) = event.view() {
                        let caps = c.caps();
                        if caps.structure(0).is_some_and(|s| s.name() == "video/x-raw" && !s.has_field("colorimetry")) {
                            let mut caps = caps.to_owned();
                            if let Some(s) = caps.make_mut().structure_mut(0) {
                                s.set("colorimetry", "bt601");
                            }
                            info.data = Some(gst::PadProbeData::Event(gst::event::Caps::new(&caps)));
                        }
                    }
                }
                gst::PadProbeReturn::Ok
            });
        }
        let tee = make("tee")?;
        let shown = make("queue")?;
        let flip = make("videoflip")?;
        flip.set_property_from_str("video-direction", if mirror { "horiz" } else { "identity" });
        let shown_convert = make("videoconvert")?;
        let sink = make("gtk4paintablesink")?;
        paintable = Some(sink.property::<gdk::Paintable>("paintable"));
        let handed = make("queue")?;
        handed.set_property_from_str("leaky", "downstream");
        handed.set_property("max-size-buffers", 1u32);
        let convert = make("videoconvert")?;
        let frames = gstreamer_app::AppSink::builder()
            .caps(&gst::Caps::builder("video/x-raw").field("format", "NV12").field("colorimetry", "bt601").build())
            .sync(false)
            .max_buffers(1)
            .drop(true)
            .build();
        let first = started.clone();
        frames.set_callbacks(
            gstreamer_app::AppSinkCallbacks::builder()
                .new_sample(move |sink| {
                    let sample = sink.pull_sample().map_err(|_| gst::FlowError::Eos)?;
                    hand_frame(id, &sample);
                    if !first.swap(true, std::sync::atomic::Ordering::AcqRel) {
                        post(Pending::Report(id, generation, Report::Running { width: w, height: h, frame_rate: fps }));
                    }
                    Ok(gst::FlowSuccess::Ok)
                })
                .build(),
        );
        let frames: gst::Element = frames.upcast();
        pipeline
            .add_many([&src, &size, &tee, &shown, &flip, &shown_convert, &sink, &handed, &convert, &frames])
            .map_err(|e| (CaptureFailure::HardwareError, e.to_string()))?;
        let link = |chain: &[&gst::Element]| {
            gst::Element::link_many(chain.iter().copied()).map_err(|e| (CaptureFailure::HardwareError, e.to_string()))
        };
        link(&[&src, &size, &tee])?;
        link(&[&tee, &shown, &flip, &shown_convert, &sink])?;
        link(&[&tee, &handed, &convert, &frames])?;
    }
    if let Some((node, (rate, channels))) = microphone {
        let src = source(node, "Audio", None)?;
        let native = make("capsfilter")?;
        native.set_property(
            "caps",
            gst::Caps::builder("audio/x-raw").field("rate", rate).field("channels", channels).build(),
        );
        let convert = make("audioconvert")?;
        let samples = gstreamer_app::AppSink::builder()
            .caps(&gst::Caps::builder("audio/x-raw").field("format", "F32LE").field("layout", "interleaved").build())
            .sync(false)
            .build();
        let first = started.clone();
        let audio_only = camera.is_none();
        samples.set_callbacks(
            gstreamer_app::AppSinkCallbacks::builder()
                .new_sample(move |sink| {
                    let sample = sink.pull_sample().map_err(|_| gst::FlowError::Eos)?;
                    hand_samples(id, &sample);
                    if audio_only && !first.swap(true, std::sync::atomic::Ordering::AcqRel) {
                        post(Pending::Report(id, generation, Report::Running { width: 0, height: 0, frame_rate: 0 }));
                    }
                    Ok(gst::FlowSuccess::Ok)
                })
                .build(),
        );
        let samples: gst::Element = samples.upcast();
        pipeline
            .add_many([&src, &native, &convert, &samples])
            .map_err(|e| (CaptureFailure::HardwareError, e.to_string()))?;
        gst::Element::link_many([&src, &native, &convert, &samples]).map_err(|e| (CaptureFailure::HardwareError, e.to_string()))?;
    }
    let bus = pipeline.bus().expect("a pipeline has a bus");
    let watch = bus
        .add_watch_local(move |_, msg| {
            let failure = match msg.view() {
                gst::MessageView::Error(e) => Some(failure_of(&e.error(), e.debug().as_deref())),
                gst::MessageView::Eos(_) => {
                    Some((CaptureFailure::Disconnected, "the device's stream ended while it was open".to_owned()))
                }
                _ => None,
            };
            if let Some((reason, detail)) = failure {
                queue(Pending::Report(id, generation, Report::Failed(reason, detail)));
            }
            glib::ControlFlow::Continue
        })
        .expect("kaya: a new pipeline's bus already had a watch");
    if pipeline.set_state(gst::State::Playing).is_err() {
        let _ = pipeline.set_state(gst::State::Null);
        return Err((CaptureFailure::HardwareError, "the capture pipeline refused to start".to_owned()));
    }
    Ok(Open { pipeline, paintable, frames: (format.0, format.1), _watch: watch, _remote: remote })
}

/// GStreamer's error in the closed vocabulary (rule 2), its sentence kept.
fn failure_of(error: &glib::Error, debug: Option<&str>) -> (CaptureFailure, String) {
    let said = format!("{error}{}", debug.map(|d| format!(" ({d})")).unwrap_or_default());
    let text = said.to_ascii_lowercase();
    let reason = if text.contains("target not found") || error.matches(gst::ResourceError::NotFound) {
        CaptureFailure::NotFound
    } else if text.contains("busy") || error.matches(gst::ResourceError::Busy) {
        CaptureFailure::InUse
    } else if error.matches(gst::ResourceError::NotAuthorized) {
        CaptureFailure::Denied
    } else if text.contains("disconnect") || text.contains("removed") {
        CaptureFailure::Disconnected
    } else if error.matches(gst::CoreError::Negotiation) || text.contains("not-negotiated") {
        CaptureFailure::Unsupported
    } else {
        CaptureFailure::HardwareError
    };
    (reason, said)
}

/// One NV12 frame to the core, on the appsink's streaming thread: the
/// default layout GStreamer's NV12 caps describe (no video meta is asked
/// for, so upstream hands that layout).
fn hand_frame(id: u64, sample: &gst::Sample) {
    let (Some(buffer), Some(caps)) = (sample.buffer(), sample.caps()) else { return };
    let Some(s) = caps.structure(0) else { return };
    let (Ok(w), Ok(h)) = (s.get::<i32>("width"), s.get::<i32>("height")) else { return };
    let (w, h) = (w as u32, h as u32);
    let stride = (w + 3) & !3;
    let luma = (stride * ((h + 1) & !1)) as usize;
    let Ok(map) = buffer.map_readable() else { return };
    let data = map.as_slice();
    let chroma = (stride * h.div_ceil(2)) as usize;
    if data.len() < luma + chroma {
        return;
    }
    let frame = crate::capture::CaptureFrame {
        width: w,
        height: h,
        y: &data[..(stride * h) as usize],
        y_stride: stride,
        uv: &data[luma..luma + chroma],
        uv_stride: stride,
        timestamp_ns: buffer.pts().map_or(0, gst::ClockTime::nseconds),
        rotation: 0,
    };
    crate::capture::frame(crate::protocol::CaptureId(id), &frame);
}

/// Samples to the core as the platform delivered them, on the appsink's
/// streaming thread; an overrun the core reports goes to the main loop.
fn hand_samples(id: u64, sample: &gst::Sample) {
    let (Some(buffer), Some(caps)) = (sample.buffer(), sample.caps()) else { return };
    let Some(s) = caps.structure(0) else { return };
    let (Ok(rate), Ok(channels)) = (s.get::<i32>("rate"), s.get::<i32>("channels")) else { return };
    let Ok(map) = buffer.map_readable() else { return };
    let floats: Vec<f32> =
        map.as_slice().chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
    let at = buffer.pts().map_or(0, gst::ClockTime::nseconds);
    for occ in crate::capture::samples(crate::protocol::CaptureId(id), channels as u32, rate as u32, &floats, at) {
        post(Pending::Occurrence(occ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gtk_capture_wall_refuses_every_device_outside_the_synthetic_table() {
        let said = refusal("v4l2_input.platform-uvc", true).expect("a real device refused under the harness");
        assert!(said.contains("\"v4l2_input.platform-uvc\"") && said.contains("KAYA_SELFTEST"), "{said}");
        for s in crate::capture::SYNTHETIC {
            assert_eq!(refusal(s.id, true), None, "{} is the lane's own", s.id);
        }
        assert_eq!(refusal("", true), None, "no device is no open");
        assert_eq!(refusal("v4l2_input.platform-uvc", false), None, "off the harness a real device opens");
        let caught = std::panic::catch_unwind(|| {
            if let Some(why) = refusal("alsa_input.pci", true) {
                panic!("{why}");
            }
        });
        assert!(caught.is_err(), "the wall's refusal is fatal");
    }

    #[test]
    fn gtk_capture_reads_a_devices_formats_and_its_native_audio() {
        gst::init().expect("GStreamer");
        let camera: gst::Caps = "video/x-raw, format=NV12, width=640, height=480, framerate=15/1; \
             video/x-raw, format=NV12, width=640, height=480, framerate=30/1; \
             video/x-raw, format=NV12, width=1280, height=720, framerate=15/1; \
             video/x-raw, format=NV12, width=1280, height=720, framerate=30/1; \
             image/jpeg, width=1920, height=1080, framerate=30/1"
            .parse()
            .expect("caps");
        let formats = formats_of(&camera);
        assert_eq!(formats, vec![(640, 480, 15), (640, 480, 30), (1280, 720, 15), (1280, 720, 30)]);
        assert_eq!(crate::capture::nearest_format(&formats, (600.0, 400.0, 30.0)), Some((640, 480, 30)));
        assert_eq!(crate::capture::nearest_format(&formats, (1280.0, 720.0, 15.0)), Some((1280, 720, 15)));
        let listed: gst::Caps =
            "video/x-raw, format=YUY2, width=1280, height=720, framerate={ 30/1, 10/1 }".parse().expect("caps");
        assert_eq!(formats_of(&listed), vec![(1280, 720, 10), (1280, 720, 30)]);
        let mic: gst::Caps =
            "audio/x-raw, layout=interleaved, format=F32LE, rate=48000, channels=2".parse().expect("caps");
        assert_eq!(native_of(&mic), Some((48_000, 2)));
        assert_eq!(native_of(&camera), None);
    }
}
