//! Traffic types between the core (main thread) and app logic (its own
//! thread).
//!
//! Transport policy: while the crate is in-process-only, the logs ride
//! `std::sync::mpsc`, which already has the semantics the design asks of a
//! log (unbounded, ordered, lossless, single consumer, and it grows by
//! linked blocks internally). The byte-level record ring in shared memory
//! arrives with the C ABI, where nothing off the shelf fits; it will be
//! written once and tested with loom and miri. The real-time audio ring is
//! a separate case and should use `rtrb`.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WidgetId(pub u64);

/// Core -> app. Ordered, lossless, consumed exactly once.
#[derive(Debug)]
pub enum Occurrence {
    ButtonClicked { id: WidgetId },
    /// The core is gone and no further occurrences will arrive; the app
    /// loop should end. First member of the lifecycle vocabulary.
    Shutdown,
}

/// App -> core. One-shot imperatives and property writes.
#[derive(Debug)]
pub enum Command {
    SetText { id: WidgetId, text: String },
}

/// Fixed ids for the milestone-0 scene, identical on every backend.
pub mod skeleton {
    use super::WidgetId;
    pub const BUTTON: WidgetId = WidgetId(1);
    pub const LABEL: WidgetId = WidgetId(2);
}

/// Where occurrences go: the Rust API consumes over mpsc, the C ABI over
/// the byte-record ring. One consumer either way.
#[derive(Clone)]
pub(crate) enum OccSink {
    Mpsc(std::sync::mpsc::Sender<Occurrence>),
    Ring(std::sync::Arc<crate::ring::OccRing>),
}

impl OccSink {
    pub(crate) fn send(&self, occurrence: Occurrence) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(occurrence);
            }
            OccSink::Ring(ring) => match occurrence {
                Occurrence::ButtonClicked { id } => {
                    ring.push(crate::ring::REC_BUTTON_CLICKED, id.0);
                }
                Occurrence::Shutdown => ring.set_shutdown(),
            },
        }
    }
}
