//! The Rust binding's far end (docs/capture-plan.md §5): the surface that
//! shows the peer's frames and the voice output that plays the peer's
//! samples, both fed from any thread through a handle that is Send + Sync.

use super::{Messages, Tx};
use crate::capture::CaptureFrame;
use crate::protocol::{Occurrence, TxOp, VoiceId, VoiceRoute, WidgetId, WidgetKind};

/// Where a surface's frames go: cloned onto the app's transport thread,
/// it submits there with no transaction.
///
/// ```
/// fn f(ctx: &kaya::AppCtx, surface: kaya::WidgetId) {
///     let frames = ctx.surface_frames(surface);
///     std::thread::spawn(move || {
///         let (y, uv) = (vec![0u8; 4], vec![128u8; 2]);
///         let frame = kaya::CaptureFrame { width: 2, height: 2, y: &y, y_stride: 2, uv: &uv, uv_stride: 2, timestamp_ns: 0, rotation: 0 };
///         frames.submit(&frame);
///     });
/// }
/// ```
#[derive(Debug, Clone, Copy)]
pub struct SurfaceFrames {
    surface: WidgetId,
}

impl SurfaceFrames {
    /// Show `frame` (NV12, as a capture hands one) once the surface's
    /// display clock next ticks, replacing any frame not yet shown. False
    /// when the surface is gone, and the frame is dropped.
    pub fn submit(&self, frame: &CaptureFrame<'_>) -> bool {
        crate::farend::submit(self.surface, frame)
    }
}

/// Where a voice output's samples go, from any thread.
#[derive(Debug, Clone, Copy)]
pub struct VoiceWriter {
    voice: VoiceId,
}

impl VoiceWriter {
    /// Queue 48 kHz mono s16 samples for the platform's voice path; past
    /// 200 ms ahead of it the oldest are dropped. False once the voice
    /// output is released.
    pub fn write(&self, samples: &[i16]) -> bool {
        crate::farend::write(self.voice, samples)
    }
}

impl super::AppCtx {
    pub(super) fn alloc_voice(&self) -> VoiceId {
        let id = self.next_voice.get();
        self.next_voice.set(id + 1);
        VoiceId(id)
    }

    /// A surface's frame handle, for the thread the frames arrive on.
    pub fn surface_frames(&self, surface: WidgetId) -> SurfaceFrames {
        SurfaceFrames { surface }
    }

    /// A voice output's sample handle, for the thread the samples arrive on.
    pub fn voice_writer(&self, voice: VoiceId) -> VoiceWriter {
        VoiceWriter { voice }
    }

    /// A voice output's route as last heard: `none` until the platform opens it.
    pub fn voice_route(&self, voice: VoiceId) -> VoiceRoute {
        self.voices.borrow().get(&voice.0).copied().unwrap_or(VoiceRoute::None)
    }

    pub(super) fn absorb_voice(&self, occ: &Occurrence) {
        if let Occurrence::VoiceChanged { voice, route, .. } = occ {
            self.voices.borrow_mut().insert(voice.0, *route);
        }
    }
}

impl<'a> Tx<'a> {
    /// A voice output (docs/capture-plan.md §5): plays what
    /// [`super::AppCtx::voice_writer`] writes on the platform's voice path,
    /// where its echo canceller hears it.
    pub fn voice(&mut self) -> VoiceId {
        let voice = self.ctx.alloc_voice();
        self.ops.push(TxOp::CreateVoice { voice });
        voice
    }

    /// Stop and forget a voice output; what it still holds is dropped.
    pub fn release_voice(&mut self, voice: VoiceId) {
        self.ops.push(TxOp::ReleaseVoice { voice });
    }
}

impl<M> Messages<M> {
    /// The voice output's route as the platform opened it, and what the
    /// backend measured.
    pub fn on_voice_route(&self, voice: VoiceId, f: impl Fn(VoiceRoute, &str) -> M + 'static) {
        self.voices.borrow_mut().entry(voice.0).or_default().push(Box::new(move |occ| match occ {
            Occurrence::VoiceChanged { route, detail, .. } => Some(f(*route, detail)),
            _ => None,
        }));
    }

    pub(super) fn dispatch_voice(&self, occ: &Occurrence) -> Option<M> {
        match occ {
            Occurrence::VoiceChanged { voice, .. } => {
                self.voices.borrow().get(&voice.0).and_then(|fs| fs.iter().rev().find_map(|f| f(occ)))
            }
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

    #[test]
    fn a_surface_and_a_voice_are_declared_and_heard() {
        let (ctx, batches, send) = context();
        let msgs = Messages::<(VoiceRoute, String)>::new();
        let (surface, voice) = ctx.apply(|tx| {
            let surface = tx.surface().id();
            let voice = tx.voice();
            tx.release_voice(voice);
            (surface, voice)
        });
        let batch = batches.recv().unwrap();
        let ops: Vec<String> = batch.iter().map(|op| format!("{op:?}")).collect();
        for want in [
            TxOp::CreateWidget { id: surface, kind: WidgetKind::Surface },
            TxOp::CreateVoice { voice },
            TxOp::ReleaseVoice { voice },
        ] {
            assert!(ops.contains(&format!("{want:?}")), "{want:?} not in {ops:?}");
        }
        assert_eq!(ctx.voice_route(voice), VoiceRoute::None);
        msgs.on_voice_route(voice, |route, detail| (route, detail.to_owned()));
        send.send(Inbox::Occ(Occurrence::VoiceChanged { voice, route: VoiceRoute::Voice, detail: "measured".into() }))
            .unwrap();
        assert_eq!(msgs.next(&ctx), Some((VoiceRoute::Voice, "measured".to_owned())));
        assert_eq!(ctx.voice_route(voice), VoiceRoute::Voice);
        fn send_sync<T: Send + Sync>(_: &T) {}
        send_sync(&ctx.surface_frames(surface));
        send_sync(&ctx.voice_writer(voice));
    }
}
