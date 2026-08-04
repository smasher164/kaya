//! The stall watchdog: is the app thread still coming back for its
//! occurrences?
//!
//! WHAT IT IS FOR. An app thread stuck inside a handler is the worst
//! failure kaya can have, because it LOOKS ALIVE: the backend keeps
//! drawing, the window keeps resizing, and input silently stops meaning
//! anything. Nothing in the framework noticed. DESIGN's threading
//! section promised this diagnostic and said it needs no protocol —
//! "the core reads the app's consumer cursor directly, so stall
//! detection (log undrained for N seconds) requires no protocol" — and
//! that is exactly what this does.
//!
//! WHY IT IS WORTH A THREAD. The class is real and already bit once: a
//! Haskell release used `putMVar`, which blocks when the MVar is full,
//! so a second click would have blocked the app thread forever. No gate
//! saw it; it was found by asking whether Go's `close` blocks. The file
//! dialog design then made the class REACHABLE ON PURPOSE — a guest may
//! call the blocking open on the app thread, and all eight guests carry
//! a comment explaining why they do not. Until now nothing would have
//! reported it if one did.
//!
//! WHAT COUNTS AS A STALL, and the definition is narrower than it first
//! looks. A consumer advances its cursor BEFORE handing the record over,
//! so a handler that blocks while nothing is queued is
//! indistinguishable from an idle app — and rightly so, since nothing is
//! waiting on it. A stall is therefore PENDING WORK NOBODY HAS PICKED
//! UP: records sitting in the transport while the consumer stands still.
//! That is also the shape a person reports, which is the point — they
//! click, and click again, and nothing happens.
//!
//! BOTH TRANSPORTS, EACH IN ITS OWN TERMS, and getting this wrong cost
//! this project a matrix debugging round. There are two, and only one
//! consumer at a time:
//!
//! - the occurrence RING, whose consumer advances `head` — every foreign
//!   guest, whether it goes through the C function floor (`wait_pop`) or
//!   maps the ring and peeks at it directly (go, csharp, ocaml, haskell,
//!   java);
//! - an mpsc CHANNEL, which has no cursor at all — the Rust binding's
//!   own in-process path (lib.rs sets an `OccSink::Mpsc`).
//!
//! The first cut read cursors alone and reported "keeping up" for a Rust
//! app that was provably asleep, because nothing an mpsc app does moves
//! a ring cursor. The second cut answered that with two COUNTERS —
//! enqueued and taken — and claimed they "say the same thing about
//! either transport". THEY DO NOT: `taken` is bumped only where the core
//! itself hands a record over, and the five direct-ring languages never
//! pass through there. Their `taken` sat at 0 for the life of the
//! process while `enqueued` climbed, so the difference was permanently
//! positive and the cursor that WAS moving was not being read — every
//! healthy leg in those languages reported a stall as soon as the
//! threshold elapsed (measured 2026-08-04: go, csharp, ocaml, haskell
//! and java all report on a PASSING clipboard leg; rust, python and
//! swift do not). It reads as a diagnostic about the app thread, so it
//! sends the next session hunting a blocked main thread that does not
//! exist — which is exactly what it did.
//!
//! So each transport is asked in the terms it actually has: the ring
//! through its cursors, the channel through its counters. Pending work
//! on either, with the consumer of neither moving, is the stall.
//!
//! ONE THREAD, POLLING. It reads a few atomics every 100ms and sleeps.
//! The alternative was a per-backend timer, which is four
//! implementations of the same loop and none of them shared with the
//! harness. This is not gated on the harness feature: a shipped app is
//! precisely where an unreported stall costs the most.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

/// How long pending work may sit before it is called a stall. One
/// second is far past any handler that is doing its job — a handler
/// runs inside a frame — and far short of a person's patience.
const DEFAULT_STALL_MS: u64 = 1000;

/// Milliseconds the app thread has been ignoring pending work, or 0
/// when it is keeping up. Written by the watchdog, read by anyone;
/// a plain atomic because that is the whole state.
static STALLED_FOR_MS: AtomicU64 = AtomicU64::new(0);

/// The mpsc transport's two counters: occurrences handed to the channel,
/// and occurrences the app has taken off it. The ring transport is not
/// counted here — it has a cursor, which is a better answer to the same
/// question and one no binding can forget to update (a consumer that
/// does not advance `head` wedges itself immediately).
static ENQUEUED: AtomicU64 = AtomicU64::new(0);
static TAKEN: AtomicU64 = AtomicU64::new(0);

/// The process's occurrence ring, registered when it is created so the
/// watchdog can read the consumer cursor DESIGN promised it would.
static RING: OnceLock<Arc<crate::ring::OccRing>> = OnceLock::new();

/// Hand the watchdog the ring to read. Called once, where the ring is
/// born (`capi::state`), never by a binding.
pub(crate) fn watch_ring(ring: Arc<crate::ring::OccRing>) {
    let _ = RING.set(ring);
}

/// One occurrence has entered the mpsc transport, bound for the app
/// thread.
///
/// STARTS THE WATCHDOG, and that is deliberate rather than tidy. It was
/// started from `kaya_run` first, which is one of THREE entry points —
/// `kaya::run` reaches `swiftui_host::run` and `backend::run_core`
/// directly and never passes through the C one, so every Rust guest on
/// every platform ran with no watchdog at all and the scene reported
/// "the app thread is keeping up" about an app that was asleep. An
/// entry point somebody has to remember is not a place to start
/// something. The first occurrence to reach any transport starts it,
/// which no path can avoid and no new entry point can forget.
pub(crate) fn enqueued() {
    watch();
    ENQUEUED.fetch_add(1, Ordering::Release);
}

/// The app thread has taken one off the mpsc transport. Called where the
/// app RECEIVES, never where it finishes handling — a handler that runs
/// long is not a stall, it is work; a handler that never returns shows
/// up as the NEXT occurrence going unclaimed.
pub(crate) fn taken() {
    TAKEN.fetch_add(1, Ordering::Release);
}

/// One occurrence has entered the RING, bound for the app thread. No
/// counter: the ring's own cursors say both what is pending and whether
/// the consumer is moving. This exists to start the watchdog on the
/// first record, for the same reason `enqueued` does.
pub(crate) fn ring_pushed() {
    watch();
}

/// How long the app thread has been ignoring pending occurrences, or
/// `None` if it is keeping up.
///
/// This is what the harness's `expect_stall` and `expect_no_stall` read,
/// and what an app can poll if it wants to report its own health.
pub fn stalled_for() -> Option<Duration> {
    match STALLED_FOR_MS.load(Ordering::Acquire) {
        0 => None,
        ms => Some(Duration::from_millis(ms)),
    }
}

fn threshold() -> Duration {
    let ms = std::env::var("KAYA_STALL_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_STALL_MS);
    Duration::from_millis(ms)
}

/// Start the watchdog. Idempotent, and called on every occurrence —
/// `Once` makes all but the first a relaxed atomic load.
fn watch() {
    use std::sync::Once;
    static STARTED: Once = Once::new();
    STARTED.call_once(move || {
        let limit = threshold();
        std::thread::Builder::new()
            .name("kaya-stall-watchdog".into())
            .spawn(move || run(limit))
            .expect("kaya: could not start the stall watchdog");
    });
}

/// What both transports say at one instant. The ring is `None` in a
/// process that never made one.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
struct Reading {
    enqueued: u64,
    taken: u64,
    /// The ring's cursors, `(head, tail)`.
    ring: Option<(u32, u32)>,
}

impl Reading {
    /// Records sitting on either transport that nobody has picked up.
    fn pending(self) -> bool {
        self.enqueued != self.taken || matches!(self.ring, Some((h, t)) if h != t)
    }

    /// What moves when the app takes something — the consumer's position
    /// on each transport. Unchanged between polls while work is pending
    /// is the stall, and it is the ONE thing this file must read from
    /// both transports.
    fn claimed(self) -> (u64, u32) {
        (self.taken, self.ring.map_or(0, |(head, _)| head))
    }
}

fn read() -> Reading {
    Reading {
        enqueued: ENQUEUED.load(Ordering::Acquire),
        taken: TAKEN.load(Ordering::Acquire),
        ring: RING.get().map(|ring| ring.cursors()),
    }
}

/// The watchdog's decision, as a state machine over readings so it can
/// be tested without a thread or a clock.
#[derive(Default)]
struct Watch {
    last_claimed: Option<(u64, u32)>,
    waiting_since: Option<Instant>,
}

#[derive(Debug, PartialEq, Eq)]
enum Verdict {
    /// Nothing pending, or the consumer moved: the app owes nobody
    /// anything.
    KeepingUp,
    /// Work is pending and the consumer has not moved, but not for long
    /// enough to call it.
    Waiting,
    /// Pending work, untouched for at least the limit.
    Stalled(Duration),
}

impl Watch {
    fn poll(&mut self, now: Instant, reading: Reading, limit: Duration) -> Verdict {
        if !reading.pending() {
            // Nothing pending: the app owes nobody anything, whatever it
            // is doing.
            self.last_claimed = None;
            self.waiting_since = None;
            return Verdict::KeepingUp;
        }
        let claimed = reading.claimed();
        if self.last_claimed != Some(claimed) {
            // The consumer moved (or this is the first look at pending
            // work): the clock starts here.
            self.last_claimed = Some(claimed);
            self.waiting_since = Some(now);
            return Verdict::KeepingUp;
        }
        let waited = self
            .waiting_since
            .map(|since| now.duration_since(since))
            .unwrap_or_default();
        if waited < limit {
            Verdict::Waiting
        } else {
            Verdict::Stalled(waited)
        }
    }
}

/// How many occurrences are waiting, for the report. Both transports can
/// hold some; only one of them ever does.
fn depth(reading: Reading) -> u64 {
    reading.enqueued.saturating_sub(reading.taken)
        + RING.get().map_or(0, |ring| ring.pending_records())
}

fn run(limit: Duration) {
    let mut watch = Watch::default();
    let mut reported = false;
    loop {
        std::thread::sleep(Duration::from_millis(100));
        let reading = read();
        match watch.poll(Instant::now(), reading, limit) {
            Verdict::KeepingUp => {
                reported = false;
                STALLED_FOR_MS.store(0, Ordering::Release);
            }
            Verdict::Waiting => {}
            Verdict::Stalled(waited) => {
                STALLED_FOR_MS.store(waited.as_millis() as u64, Ordering::Release);
                // ONCE PER EPISODE. A stall that lasts a minute is one
                // event, not six hundred; a watchdog that floods the log
                // is a watchdog people turn off.
                if !reported {
                    reported = true;
                    let pending = depth(reading);
                    eprintln!(
                        "kaya: THE APP THREAD IS STALLED — {pending} occurrences have been \
                         waiting {}ms and nothing has taken them. The window will keep drawing and \
                         input will keep doing nothing, which is why this is reported rather than \
                         left to look like an idle app. The cause is a handler that has not returned: \
                         something blocking ran on the app thread instead of on a thread of its own. \
                         Do that work elsewhere and post the result back.",
                        waited.as_millis()
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIMIT: Duration = Duration::from_millis(1000);

    fn ring(head: u32, tail: u32) -> Reading {
        Reading {
            enqueued: 0,
            taken: 0,
            ring: Some((head, tail)),
        }
    }

    fn mpsc(enqueued: u64, taken: u64) -> Reading {
        Reading {
            enqueued,
            taken,
            ring: Some((0, 0)),
        }
    }

    /// THE DEFECT THIS FILE WAS REWRITTEN FOR. A direct-ring guest never
    /// moves a counter; its consumer moves the ring's head. A watchdog
    /// that reads only the counters calls that healthy app stalled.
    ///
    /// A BACKLOG THE WHOLE TIME, deliberately: an app that drains to
    /// empty between polls resets the clock on emptiness alone, and the
    /// test would then pass with the cursor unread — which is exactly
    /// how the first draft of it passed against the defect. Here two
    /// records are always waiting and the consumer is always moving,
    /// which is the ONE shape that separates the two readings.
    #[test]
    fn a_consumer_that_only_moves_the_ring_cursor_is_keeping_up() {
        let mut watch = Watch::default();
        let t0 = Instant::now();
        for step in 0..40u32 {
            let now = t0 + Duration::from_millis(100 * u64::from(step));
            let verdict = watch.poll(now, ring(step * 16, step * 16 + 32), LIMIT);
            assert!(
                !matches!(verdict, Verdict::Stalled(_)),
                "a consumer moving the ring cursor must never be called stalled, \
                 got {verdict:?} at step {step}"
            );
        }
    }

    #[test]
    fn a_ring_consumer_that_stops_is_a_stall() {
        let mut watch = Watch::default();
        let t0 = Instant::now();
        // 16 bytes sit in the ring and the head never moves again.
        assert_eq!(watch.poll(t0, ring(0, 16), LIMIT), Verdict::KeepingUp);
        assert_eq!(
            watch.poll(t0 + Duration::from_millis(500), ring(0, 16), LIMIT),
            Verdict::Waiting
        );
        assert_eq!(
            watch.poll(t0 + Duration::from_millis(1100), ring(0, 16), LIMIT),
            Verdict::Stalled(Duration::from_millis(1100))
        );
    }

    #[test]
    fn an_mpsc_consumer_that_stops_is_a_stall() {
        let mut watch = Watch::default();
        let t0 = Instant::now();
        assert_eq!(watch.poll(t0, mpsc(1, 0), LIMIT), Verdict::KeepingUp);
        assert_eq!(
            watch.poll(t0 + Duration::from_millis(1100), mpsc(1, 0), LIMIT),
            Verdict::Stalled(Duration::from_millis(1100))
        );
    }

    #[test]
    fn an_mpsc_consumer_that_keeps_up_is_never_stalled() {
        let mut watch = Watch::default();
        let t0 = Instant::now();
        for step in 0..40u64 {
            let now = t0 + Duration::from_millis(100 * step);
            watch.poll(now, mpsc(step + 1, step), LIMIT);
            assert_eq!(watch.poll(now, mpsc(step + 1, step + 1), LIMIT), Verdict::KeepingUp);
        }
    }

    /// An empty transport is not a stall however long the app is gone:
    /// nothing is waiting on it.
    #[test]
    fn an_idle_app_with_nothing_queued_is_not_a_stall() {
        let mut watch = Watch::default();
        let t0 = Instant::now();
        assert_eq!(watch.poll(t0, ring(64, 64), LIMIT), Verdict::KeepingUp);
        assert_eq!(
            watch.poll(t0 + Duration::from_secs(60), ring(64, 64), LIMIT),
            Verdict::KeepingUp
        );
    }

    /// A stall that ends is over: the reading clears the moment the
    /// consumer moves again, which is what lets a scene assert recovery.
    #[test]
    fn a_stall_that_recovers_clears() {
        let mut watch = Watch::default();
        let t0 = Instant::now();
        watch.poll(t0, ring(0, 16), LIMIT);
        assert!(matches!(
            watch.poll(t0 + Duration::from_millis(1100), ring(0, 16), LIMIT),
            Verdict::Stalled(_)
        ));
        assert_eq!(
            watch.poll(t0 + Duration::from_millis(1200), ring(16, 16), LIMIT),
            Verdict::KeepingUp
        );
    }

    /// The ring's record count is what the message quotes, and it counts
    /// RECORDS rather than bytes — including across a wrap, and never
    /// counting the pad the wrap leaves behind.
    #[test]
    fn the_report_counts_records_not_bytes() {
        let ring = crate::ring::OccRing::new(64);
        assert_eq!(ring.pending_records(), 0);
        ring.push_record(crate::ring::REC_BUTTON_CLICKED, &[0u8; 8]);
        assert_eq!(ring.pending_records(), 1);
        ring.push_record(crate::ring::REC_BUTTON_CLICKED, &[0u8; 8]);
        assert_eq!(ring.pending_records(), 2);
        assert!(matches!(ring.wait_pop(), crate::ring::Waited::Record(..)));
        assert_eq!(ring.pending_records(), 1);
    }
}
