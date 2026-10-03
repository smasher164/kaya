//! The Rust binding's capture surface (docs/capture-plan.md): a capture
//! object the app holds, the video view previewing one, the permission and
//! device readings, and the frame and sample callbacks that run on kaya's
//! capture thread.

use super::{Messages, Tx, Widget};
use crate::capture::CaptureFrame;
use crate::protocol::{
    CaptureCommand, CaptureDevice, CaptureFailure, CaptureId, CaptureInterruption, CaptureKind, CaptureProp,
    CaptureState, Occurrence, Permission, Prop, TxOp, Value, WidgetId, WidgetKind,
};

/// A capture's readings, as the core last published them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CaptureReading {
    pub state: CaptureState,
    pub failure: Option<CaptureFailure>,
    pub interruption: Option<CaptureInterruption>,
    /// The format the platform chose; 0x0 at 0 with no camera running.
    pub width: u32,
    pub height: u32,
    pub frame_rate: u32,
}

impl Default for CaptureReading {
    fn default() -> Self {
        CaptureReading {
            state: CaptureState::Idle,
            failure: None,
            interruption: None,
            width: 0,
            height: 0,
            frame_rate: 0,
        }
    }
}

impl super::AppCtx {
    pub(super) fn alloc_capture(&self) -> CaptureId {
        let id = self.next_capture.get();
        self.next_capture.set(id + 1);
        CaptureId(id)
    }

    /// A capture's readings as of the last occurrence this loop took.
    pub fn capture(&self, capture: CaptureId) -> CaptureReading {
        self.captures.borrow().get(&capture.0).copied().unwrap_or_default()
    }

    /// A kind's permission as last heard: `prompt` until the platform says.
    pub fn permission(&self, kind: CaptureKind) -> Permission {
        self.capture_permissions.borrow().get(&kind).copied().unwrap_or(Permission::Prompt)
    }

    /// The cameras and microphones as last listed (watch them with
    /// [`Tx::watch_capture_devices`]).
    pub fn capture_devices(&self) -> Vec<CaptureDevice> {
        self.capture_devices.borrow().clone()
    }

    /// Run `f` on KAYA'S CAPTURE THREAD for each frame of `capture`, the
    /// frame borrowed for the call and the next one dropped while `f` still
    /// runs (docs/capture-plan.md §4). It holds no transaction: to touch the
    /// scene, post through a [`super::Poster`]. A callback holding what
    /// only the app thread may touch does not compile:
    ///
    /// ```compile_fail
    /// fn f(ctx: &kaya::AppCtx, id: kaya::CaptureId) {
    ///     let app_only = std::rc::Rc::new(0u32);
    ///     ctx.on_capture_frame(id, move |_| {
    ///         let _ = &app_only;
    ///     });
    /// }
    /// ```
    ///
    /// ```
    /// fn f(ctx: &kaya::AppCtx, id: kaya::CaptureId) {
    ///     let shared = std::sync::Arc::new(0u32);
    ///     ctx.on_capture_frame(id, move |_| {
    ///         let _ = &shared;
    ///     });
    /// }
    /// ```
    pub fn on_capture_frame(&self, capture: CaptureId, f: impl Fn(&CaptureFrame<'_>) + Send + Sync + 'static) {
        crate::capture::set_frame_sink(capture, Some(std::sync::Arc::new(f)));
    }

    /// Run `f` on kaya's capture thread for every 10 ms of `capture`'s
    /// microphone: 480 samples of 48 kHz mono s16 and the first one's time on
    /// the capture's clock. None is dropped; a callback slower than the
    /// microphone is told through [`Messages::on_capture_overrun`].
    pub fn on_capture_samples(&self, capture: CaptureId, f: impl Fn(&[i16], u64) + Send + Sync + 'static) {
        crate::capture::set_sample_sink(capture, Some(std::sync::Arc::new(f)));
    }

    pub(super) fn absorb_capture(&self, occ: &Occurrence) {
        match occ {
            Occurrence::CaptureChanged { capture, state, failure, interruption, width, height, frame_rate, .. } => {
                self.captures.borrow_mut().insert(
                    capture.0,
                    CaptureReading {
                        state: *state,
                        failure: *failure,
                        interruption: *interruption,
                        width: *width,
                        height: *height,
                        frame_rate: *frame_rate,
                    },
                );
            }
            Occurrence::CapturePermission { kind, permission, .. } => {
                self.capture_permissions.borrow_mut().insert(*kind, *permission);
            }
            Occurrence::CaptureDevices { devices } => *self.capture_devices.borrow_mut() = devices.clone(),
            _ => {}
        }
    }
}

impl<'a> Tx<'a> {
    /// A capture (docs/capture-plan.md §2): at most one camera and one
    /// microphone, with no place in the layout. Preview it with
    /// [`Tx::video_capture`]; `.start()` it once its devices are set.
    pub fn capture(&mut self) -> CaptureRef<'_, 'a> {
        let capture = self.ctx.alloc_capture();
        self.ops.push(TxOp::CreateCapture { capture });
        CaptureRef { tx: self, capture }
    }

    fn capture_prop(&mut self, capture: CaptureId, prop: CaptureProp, value: Value) {
        self.ops.push(TxOp::SetCaptureProp { capture, prop, value });
    }

    /// The camera, by a device's id from [`super::AppCtx::capture_devices`];
    /// None closes it and puts its indicator out.
    pub fn capture_camera(&mut self, capture: CaptureId, device: Option<&str>) {
        self.capture_prop(capture, CaptureProp::Camera, Value::Str(device.unwrap_or("").to_owned()));
    }

    /// The microphone, as [`Tx::capture_camera`].
    pub fn capture_microphone(&mut self, capture: CaptureId, device: Option<&str>) {
        self.capture_prop(capture, CaptureProp::Microphone, Value::Str(device.unwrap_or("").to_owned()));
    }

    /// The picture size wished for, met by the platform's nearest format.
    pub fn capture_size(&mut self, capture: CaptureId, width: f64, height: f64) {
        self.capture_prop(capture, CaptureProp::Width, Value::F64(width));
        self.capture_prop(capture, CaptureProp::Height, Value::F64(height));
    }

    pub fn capture_frame_rate(&mut self, capture: CaptureId, rate: f64) {
        self.capture_prop(capture, CaptureProp::FrameRate, Value::F64(rate));
    }

    /// The microphone stays open and delivers silence, as a call's mute.
    pub fn capture_muted(&mut self, capture: CaptureId, on: bool) {
        self.capture_prop(capture, CaptureProp::Muted, Value::Bool(on));
    }

    /// Open the devices, asking for each kind's permission still at
    /// `prompt`; the answer is the capture's own state.
    pub fn start_capture(&mut self, capture: CaptureId) {
        self.ops.push(TxOp::CaptureCommand { capture, command: CaptureCommand::Start });
    }

    pub fn stop_capture(&mut self, capture: CaptureId) {
        self.ops.push(TxOp::CaptureCommand { capture, command: CaptureCommand::Stop });
    }

    /// Stop and forget a capture; its callbacks are dropped with it.
    pub fn release_capture(&mut self, capture: CaptureId) {
        self.ops.push(TxOp::ReleaseCapture { capture });
    }

    /// Ask for a kind's permission before any capture starts; the answer
    /// arrives through [`Messages::on_permission`].
    pub fn request_permission(&mut self, kind: CaptureKind) {
        self.ops.push(TxOp::RequestPermission { kind });
    }

    /// List the cameras and microphones now and whenever one comes or goes
    /// ([`Messages::on_capture_devices`]); false stops.
    pub fn watch_capture_devices(&mut self, on: bool) {
        self.ops.push(TxOp::WatchCaptureDevices { on });
    }

    /// A video view previewing `capture` (docs/capture-plan.md §3): the
    /// player's view one source over, mirrored for a front camera.
    pub fn video_capture(&mut self, capture: CaptureId) -> Widget<'_, 'a> {
        let w = self.widget(WidgetKind::Video);
        self.set(w, Prop::Capture, Value::I64(capture.0 as i64));
        Widget { id: w, out: (), tx: self }
    }

    /// Preview another capture in a video view, or none.
    pub fn show_capture(&mut self, video: WidgetId, capture: Option<CaptureId>) {
        self.set(video, Prop::Capture, Value::I64(capture.map_or(0, |c| c.0 as i64)));
    }
}

#[must_use = "a capture's settings apply as they are chained; .id() hands the capture back"]
pub struct CaptureRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    capture: CaptureId,
}

impl CaptureRef<'_, '_> {
    pub fn camera(self, device: &str) -> Self {
        self.tx.capture_camera(self.capture, Some(device));
        self
    }

    pub fn microphone(self, device: &str) -> Self {
        self.tx.capture_microphone(self.capture, Some(device));
        self
    }

    pub fn size(self, width: f64, height: f64) -> Self {
        self.tx.capture_size(self.capture, width, height);
        self
    }

    pub fn frame_rate(self, rate: f64) -> Self {
        self.tx.capture_frame_rate(self.capture, rate);
        self
    }

    pub fn muted(self, on: bool) -> Self {
        self.tx.capture_muted(self.capture, on);
        self
    }

    pub fn id(self) -> CaptureId {
        self.capture
    }
}

impl<M> Messages<M> {
    fn on_capture_occ(&self, capture: CaptureId, f: impl Fn(&Occurrence) -> Option<M> + 'static) {
        self.captures.borrow_mut().entry(capture.0).or_default().push(Box::new(f));
    }

    /// Every state the capture moves to, `failed` included.
    pub fn on_capture_state(&self, capture: CaptureId, f: impl Fn(&CaptureReading) -> M + 'static) {
        self.on_capture_occ(capture, move |occ| match occ {
            Occurrence::CaptureChanged { state, failure, interruption, width, height, frame_rate, .. } => {
                Some(f(&CaptureReading {
                    state: *state,
                    failure: *failure,
                    interruption: *interruption,
                    width: *width,
                    height: *height,
                    frame_rate: *frame_rate,
                }))
            }
            _ => None,
        });
    }

    /// The capture cannot run: the closed reason and the platform's
    /// sentence, which no two platforms word alike.
    pub fn on_capture_failed(&self, capture: CaptureId, f: impl Fn(CaptureFailure, &str) -> M + 'static) {
        self.on_capture_occ(capture, move |occ| match occ {
            Occurrence::CaptureChanged { state: CaptureState::Failed, failure: Some(why), detail, .. } => {
                Some(f(*why, detail))
            }
            _ => None,
        });
    }

    /// The app's sample callback fell this many ms behind the microphone.
    pub fn on_capture_overrun(&self, capture: CaptureId, f: impl Fn(u64) -> M + 'static) {
        self.on_capture_occ(capture, move |occ| match occ {
            Occurrence::CaptureOverrun { behind_ms, .. } => Some(f(*behind_ms)),
            _ => None,
        });
    }

    /// A kind's permission moved or was asked about.
    pub fn on_permission(&self, f: impl Fn(CaptureKind, Permission) -> M + 'static) {
        *self.permission.borrow_mut() = Some(Box::new(f));
    }

    /// The device list, as watching starts and whenever it changes.
    pub fn on_capture_devices(&self, f: impl Fn(&[CaptureDevice]) -> M + 'static) {
        *self.capture_devices.borrow_mut() = Some(Box::new(f));
    }

    pub(super) fn dispatch_capture(&self, occ: &Occurrence) -> Option<M> {
        match occ {
            Occurrence::CaptureChanged { capture, .. } | Occurrence::CaptureOverrun { capture, .. } => self
                .captures
                .borrow()
                .get(&capture.0)
                .and_then(|fs| fs.iter().rev().find_map(|f| f(occ))),
            Occurrence::CapturePermission { kind, permission, .. } => {
                self.permission.borrow().as_ref().map(|f| f(*kind, *permission))
            }
            Occurrence::CaptureDevices { devices } => self.capture_devices.borrow().as_ref().map(|f| f(devices)),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Inbox, Transaction};
    use std::sync::mpsc::{self, Receiver, Sender};

    fn context() -> (super::super::AppCtx, Receiver<Transaction>, Sender<Inbox>) {
        let (send, receive) = mpsc::channel();
        let (transactions, batches) = mpsc::channel();
        (super::super::AppCtx::new(receive, transactions, send.clone()), batches, send)
    }

    #[derive(Debug, PartialEq)]
    enum Msg {
        State(CaptureState, u32),
        Failed(CaptureFailure, String),
        Permission(CaptureKind, Permission),
        Devices(usize),
        Overrun(u64),
    }

    fn changed(capture: CaptureId, state: CaptureState, failure: Option<CaptureFailure>, width: u32) -> Occurrence {
        Occurrence::CaptureChanged {
            capture,
            state,
            failure,
            interruption: None,
            width,
            height: width * 3 / 4,
            frame_rate: 30,
            detail: "the platform's words".into(),
        }
    }

    /// The handle's ops are the spec's records, and every occurrence reaches
    /// the readings and the handler registered for it.
    #[test]
    fn a_capture_is_declared_and_heard() {
        let (ctx, batches, send) = context();
        let msgs = Messages::<Msg>::new();
        let (call, video) = ctx.apply(|tx| {
            let call = tx.capture().camera("cam").microphone("mic").size(640.0, 480.0).id();
            let video = tx.video_capture(call).id();
            tx.start_capture(call);
            tx.watch_capture_devices(true);
            (call, video)
        });
        let batch = batches.recv().unwrap();
        let ops: Vec<String> = batch.iter().map(|op| format!("{op:?}")).collect();
        for want in [
            TxOp::CreateCapture { capture: call },
            TxOp::SetCaptureProp { capture: call, prop: CaptureProp::Camera, value: Value::from("cam") },
            TxOp::SetCaptureProp { capture: call, prop: CaptureProp::Width, value: Value::F64(640.0) },
            TxOp::CaptureCommand { capture: call, command: CaptureCommand::Start },
            TxOp::WatchCaptureDevices { on: true },
        ] {
            assert!(ops.contains(&format!("{want:?}")), "{want:?} not in {ops:?}");
        }
        assert!(batch.iter().any(|op| matches!(
            op,
            TxOp::SetProperty { widget, prop: Prop::Capture, value: crate::protocol::PropValue::Const(Value::I64(c)) }
                if *widget == video && *c == call.0 as i64
        )));
        msgs.on_capture_state(call, |r| Msg::State(r.state, r.width));
        msgs.on_capture_failed(call, |why, detail| Msg::Failed(why, detail.to_owned()));
        msgs.on_capture_overrun(call, Msg::Overrun);
        msgs.on_permission(Msg::Permission);
        msgs.on_capture_devices(|d| Msg::Devices(d.len()));
        send.send(Inbox::Occ(Occurrence::CapturePermission {
            kind: CaptureKind::Camera,
            permission: Permission::Granted,
            detail: String::new(),
        }))
        .unwrap();
        assert_eq!(msgs.next(&ctx), Some(Msg::Permission(CaptureKind::Camera, Permission::Granted)));
        assert_eq!(ctx.permission(CaptureKind::Camera), Permission::Granted);
        assert_eq!(ctx.permission(CaptureKind::Microphone), Permission::Prompt);
        send.send(Inbox::Occ(changed(call, CaptureState::Running, None, 640))).unwrap();
        assert_eq!(msgs.next(&ctx), Some(Msg::State(CaptureState::Running, 640)));
        assert_eq!(ctx.capture(call).height, 480);
        send.send(Inbox::Occ(Occurrence::CaptureOverrun { capture: call, behind_ms: 250 })).unwrap();
        assert_eq!(msgs.next(&ctx), Some(Msg::Overrun(250)));
        send.send(Inbox::Occ(Occurrence::CaptureDevices {
            devices: vec![crate::protocol::CaptureDevice {
                id: "cam".into(),
                name: "Camera".into(),
                kind: CaptureKind::Camera,
                facing: crate::protocol::CameraFacing::Front,
                preferred: true,
            }],
        }))
        .unwrap();
        assert_eq!(msgs.next(&ctx), Some(Msg::Devices(1)));
        assert_eq!(ctx.capture_devices()[0].id, "cam");
        send.send(Inbox::Occ(changed(call, CaptureState::Failed, Some(CaptureFailure::InUse), 0))).unwrap();
        assert_eq!(msgs.next(&ctx), Some(Msg::Failed(CaptureFailure::InUse, "the platform's words".into())));
        assert_eq!(ctx.capture(call).failure, Some(CaptureFailure::InUse));
    }
}
