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
//! looks. `OccRing::wait_pop` advances the consumer cursor BEFORE
//! handing the record over, so a handler that blocks while the ring is
//! empty is indistinguishable from an idle app — and rightly so, since
//! nothing is waiting on it. A stall is therefore PENDING WORK NOBODY
//! HAS PICKED UP: records sitting in the ring while the cursor stands
//! still. That is also the shape a person reports, which is the point —
//! they click, and click again, and nothing happens.
//!
//! COUNTERS AND NOT RING CURSORS, which is not what the first version
//! did and is the whole reason this file has a note about it. DESIGN
//! says the core "reads the app's consumer cursor directly", and the
//! occurrence ring has exactly such a cursor — but the ring is only ONE
//! of two transports. The Rust binding's own in-process path uses an
//! mpsc channel instead (lib.rs sets an `OccSink::Mpsc`), so on macOS
//! and iOS nothing an app does ever moves a ring cursor, and a
//! cursor-reading watchdog reported "keeping up" for an app thread that
//! was provably asleep. Two counters — enqueued, taken — say the same
//! thing about either transport.
//!
//! ONE THREAD, POLLING. It reads two atomics every 100ms and sleeps.
//! The alternative was a per-backend timer, which is four
//! implementations of the same loop and none of them shared with the
//! harness. This is not gated on the harness feature: a shipped app is
//! precisely where an unreported stall costs the most.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// How long pending work may sit before it is called a stall. One
/// second is far past any handler that is doing its job — a handler
/// runs inside a frame — and far short of a person's patience.
const DEFAULT_STALL_MS: u64 = 1000;

/// Milliseconds the app thread has been ignoring pending work, or 0
/// when it is keeping up. Written by the watchdog, read by anyone;
/// a plain atomic because that is the whole state.
static STALLED_FOR_MS: AtomicU64 = AtomicU64::new(0);

/// Occurrences handed to a transport, and occurrences the app has taken
/// off one. Their difference is the queue depth, whichever transport is
/// live; `TAKEN` standing still while the difference is positive is the
/// stall.
static ENQUEUED: AtomicU64 = AtomicU64::new(0);
static TAKEN: AtomicU64 = AtomicU64::new(0);

/// One occurrence has entered a transport, bound for the app thread.
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

/// The app thread has taken one off. Called where the app RECEIVES,
/// never where it finishes handling — a handler that runs long is not
/// a stall, it is work; a handler that never returns shows up as the
/// NEXT occurrence going unclaimed.
pub(crate) fn taken() {
    TAKEN.fetch_add(1, Ordering::Release);
}

/// How long the app thread has been ignoring pending occurrences, or
/// `None` if it is keeping up.
///
/// This is what the harness's `expect_stall` reads, and what an app can
/// poll if it wants to report its own health.
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

/// Start the watchdog. Idempotent, and called from `enqueued` on every
/// occurrence — `Once` makes all but the first a relaxed atomic load.
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

fn run(limit: Duration) {
    let mut last_taken = None::<u64>;
    let mut waiting_since = None::<Instant>;
    let mut reported = false;
    loop {
        std::thread::sleep(Duration::from_millis(100));
        let enqueued = ENQUEUED.load(Ordering::Acquire);
        let taken = TAKEN.load(Ordering::Acquire);

        if enqueued == taken {
            // Nothing pending: the app owes nobody anything, whatever
            // it is doing.
            last_taken = None;
            waiting_since = None;
            reported = false;
            STALLED_FOR_MS.store(0, Ordering::Release);
            continue;
        }

        // Work is pending. Did the app take anything since last look?
        if last_taken != Some(taken) {
            last_taken = Some(taken);
            waiting_since = Some(Instant::now());
            reported = false;
            STALLED_FOR_MS.store(0, Ordering::Release);
            continue;
        }

        let waited = waiting_since.map(|t| t.elapsed()).unwrap_or_default();
        if waited < limit {
            continue;
        }
        STALLED_FOR_MS.store(waited.as_millis() as u64, Ordering::Release);

        // ONCE PER EPISODE. A stall that lasts a minute is one event,
        // not six hundred; a watchdog that floods the log is a watchdog
        // people turn off.
        if !reported {
            reported = true;
            let pending = enqueued - taken;
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
