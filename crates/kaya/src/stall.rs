//! The stall watchdog: is the app thread still coming back for its
//! occurrences? An app thread stuck inside a handler LOOKS ALIVE — the
//! backend keeps drawing and input silently stops meaning anything.
//!
//! WHAT COUNTS AS A STALL is narrower than it looks: a consumer
//! advances its cursor BEFORE handing the record over, so a handler
//! that blocks while nothing is queued is indistinguishable from an
//! idle app. A stall is PENDING WORK NOBODY HAS PICKED UP.
//!
//! BOTH TRANSPORTS, EACH IN ITS OWN TERMS. The occurrence RING is asked
//! through its cursors (every foreign guest, whether it goes through
//! `wait_pop` or maps the ring and advances `head` itself); the mpsc
//! CHANNEL, which has no cursor, through its counters (the Rust
//! binding's in-process path). Asking either in the other's terms
//! reports a stall on a healthy app — docs/traps.md, "A watchdog that
//! reports a stall on a HEALTHY app, in five of eight languages".
//!
//! Not gated on the harness feature: a shipped app is precisely where
//! an unreported stall costs the most.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

/// How long pending work may sit before it is called a stall. Far past
/// any handler doing its job, far short of a person's patience.
const DEFAULT_STALL_MS: u64 = 1000;

/// Milliseconds the app thread has been ignoring pending work, or 0
/// when it is keeping up.
static STALLED_FOR_MS: AtomicU64 = AtomicU64::new(0);

/// The mpsc transport's two counters. The RING transport is not counted
/// here — it has a cursor, which no binding can forget to update.
static ENQUEUED: AtomicU64 = AtomicU64::new(0);
static TAKEN: AtomicU64 = AtomicU64::new(0);

static RING: OnceLock<Arc<crate::ring::OccRing>> = OnceLock::new();

/// Hand the watchdog the ring to read. Called once, where the ring is
/// born (`capi::state`), never by a binding.
pub(crate) fn watch_ring(ring: Arc<crate::ring::OccRing>) {
    let _ = RING.set(ring);
}

/// One occurrence has entered the mpsc transport, bound for the app
/// thread.
///
/// STARTS THE WATCHDOG. The first occurrence to reach any transport
/// starts it, which no path can avoid and no new entry point can
/// forget — an entry point is not a place to start it from, there
/// being three of them (docs/deferred.md).
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

/// One occurrence has entered the RING. No counter: the ring's cursors
/// say both what is pending and whether the consumer is moving. This
/// exists only to start the watchdog on the first record.
pub(crate) fn ring_pushed() {
    watch();
}

/// How long the app thread has been ignoring pending occurrences, or
/// `None` if it is keeping up. What the harness's `expect_stall` and
/// `expect_no_stall` read.
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

    /// The consumer's position on each transport. Unchanged between
    /// polls while work is pending IS the stall.
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
                // Once per episode: a watchdog that floods the log is a
                // watchdog people turn off.
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

    /// A direct-ring guest never moves a counter; its consumer moves
    /// the ring's head (docs/traps.md).
    ///
    /// A BACKLOG THE WHOLE TIME, deliberately: an app that drains to
    /// empty between polls resets the clock on emptiness alone, and the
    /// test would then pass with the cursor unread. Two records always
    /// waiting with the consumer always moving is the ONE shape that
    /// separates the two readings.
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

    /// The reading clears the moment the consumer moves again, which is
    /// what lets a scene assert recovery.
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

    /// The message quotes RECORDS rather than bytes — including across
    /// a wrap, and never counting the pad the wrap leaves behind.
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
