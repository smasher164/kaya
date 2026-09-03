//! THE VERB TRACE: what each harness verb did, attempt by attempt, kept in
//! a ring and written ONLY WHEN THE RUN FAILS (docs/deferred.md's
//! flight-recorder entry; docs/HACKING.md for the hand run).
//!
//! A STATIC, not a local: the step watchdog fires from its own thread and
//! leaves through `std::process::exit`, so it can reach nothing the run
//! owns, and backends answer partly on the UI thread. The idiom is fault.rs's
//! `FAULT`. (Not crate::ring, which is the wire's occurrence ring.)
//!
//! One line adds a verb — `vtrace::note(verb, format_args!(...))`, or
//! `poll_named` for a retried observation's per-attempt records. THE `what`
//! CONVENTION: `->` opens a call to the platform and `<-` is what came back,
//! so a `->` with no `<-` after it is a call that never returned.
//!
//! `KAYA_VERB_TRACE` names the file; unset means no instrument at all.

use std::fmt::Arguments;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

const ENV_VAR: &str = "KAYA_VERB_TRACE";

/// Records kept before the oldest goes. A ring that silently forgets is a
/// diagnostic that lies, so the drop count is in the dump's first line.
pub(crate) const CAP: usize = 2048;

struct Rec {
    at_ms: u64,
    step: usize,
    verb: &'static str,
    /// 0 when the verb is not a retry.
    attempt: u32,
    what: String,
}

struct Trace {
    start: Option<Instant>,
    step: usize,
    /// The script's own text, by step ordinal — the records carry the
    /// ordinal, so a dropped record still knows which step it was in.
    steps: Vec<String>,
    recs: Vec<Rec>,
    head: usize,
    dropped: u64,
}

impl Trace {
    const fn new() -> Self {
        Trace {
            start: None,
            step: 0,
            steps: Vec::new(),
            recs: Vec::new(),
            head: 0,
            dropped: 0,
        }
    }

    fn push(&mut self, rec: Rec) {
        if self.recs.len() < CAP {
            self.recs.push(rec);
        } else {
            self.recs[self.head] = rec;
            self.head = (self.head + 1) % CAP;
            self.dropped += 1;
        }
    }

    fn at_ms(&self) -> u64 {
        self.start.map_or(0, |s| s.elapsed().as_millis() as u64)
    }
}

static TRACE: Mutex<Trace> = Mutex::new(Trace::new());

/// Read once per run, so a note off the instrument costs one atomic
/// load: every call site sits on the harness's step path.
static ON: AtomicBool = AtomicBool::new(false);

/// A poisoned lock is still a trace — no path out of a diagnostic may
/// panic (fault.rs's rule).
fn locked() -> std::sync::MutexGuard<'static, Trace> {
    TRACE.lock().unwrap_or_else(|e| e.into_inner())
}

/// Whether anything is recording. Call sites that would cost the
/// PLATFORM something to trace (an extra UI hop) ask this first.
pub(crate) fn on() -> bool {
    ON.load(Ordering::Relaxed)
}

/// The start of a run. `start` is the zero every record's `t=` counts
/// from — the step log's own zero, so the two transcripts line up.
pub(crate) fn begin(start: Instant) {
    let on = std::env::var_os(ENV_VAR).is_some_and(|p| !p.is_empty());
    ON.store(on, Ordering::Relaxed);
    let mut t = locked();
    *t = Trace::new();
    t.start = Some(start);
}

/// The step boundary. Sits beside `watch.enter` in the step loop.
pub(crate) fn step(ordinal: usize, text: Arguments<'_>) {
    if !on() {
        return;
    }
    let mut t = locked();
    t.step = ordinal;
    if t.steps.len() <= ordinal {
        t.steps.resize(ordinal + 1, String::new());
    }
    t.steps[ordinal] = text.to_string();
}

pub(crate) fn note(verb: &'static str, what: Arguments<'_>) {
    record(verb, 0, what);
}

/// One attempt of a retried verb, numbered from 1; harness.rs's
/// `poll_named` feeds it.
pub(crate) fn attempt(verb: &'static str, n: u32, what: Arguments<'_>) {
    record(verb, n, what);
}

fn record(verb: &'static str, attempt: u32, what: Arguments<'_>) {
    if !on() {
        return;
    }
    let mut t = locked();
    let at_ms = t.at_ms();
    let step = t.step;
    t.push(Rec { at_ms, step, verb, attempt, what: what.to_string() });
}

/// One field a `key=value` reader can take, whatever the verb put in it
/// (simdrive's `quoted`).
fn quoted(s: &str) -> String {
    format!("\"{}\"", s.replace('"', "'").replace(['\n', '\r'], " "))
}

/// Append the whole ring under `reason`. FAILURE ONLY — the two callers
/// (harness.rs's failed verdict and the step watchdog's fire path) decide
/// that; a green run leaves no file.
pub(crate) fn dump(reason: &str) {
    if !on() {
        return;
    }
    let Some(path) = std::env::var_os(ENV_VAR) else {
        return;
    };
    let mut out = String::new();
    let (kept, dropped);
    {
        let t = locked();
        kept = t.recs.len();
        dropped = t.dropped;
        out.push_str(&format!(
            "KAYA_VERB_TRACE: dump reason={} t={} records={kept} dropped={dropped} steps={}\n",
            quoted(reason),
            t.at_ms(),
            t.steps.len()
        ));
        for (i, text) in t.steps.iter().enumerate() {
            out.push_str(&format!("KAYA_VERB_TRACE: step={i} text={}\n", quoted(text)));
        }
        for r in t.recs[t.head..].iter().chain(t.recs[..t.head].iter()) {
            out.push_str(&format!(
                "KAYA_VERB_TRACE: t={} step={} verb={} try={} what={}\n",
                r.at_ms,
                r.step,
                r.verb,
                r.attempt,
                quoted(&r.what)
            ));
        }
    }
    // O_APPEND and ONE write: the block stays whole against any other
    // writer of the same file (a runner's watcher writes lines to it too).
    use std::io::Write;
    let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) else {
        return;
    };
    let _ = f.write_all(out.as_bytes());
    let _ = f.flush();
    // NOT IN THE VERDICT: that text is byte-compared across the three
    // harnesses and this instrument exists in one (tools/check-verbs.py).
    eprintln!(
        "KAYA_HARNESS: verb trace ({kept} records, {dropped} dropped) appended to {}",
        path.to_string_lossy()
    );
}
