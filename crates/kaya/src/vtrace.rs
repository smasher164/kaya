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

/// Records kept per step: its first STEP_HEAD and its last STEP_TAIL, the
/// middle counted — so a step retried hundreds of times cannot push an
/// earlier failing step out of the dump (docs/traps.md, "The sockets a stale
/// freeze destroyed": 2266 records dropped took the first failing step's
/// whole history). CAP bounds the run; past it the oldest step goes whole.
pub(crate) const STEP_HEAD: usize = 64;
pub(crate) const STEP_TAIL: usize = 64;
pub(crate) const CAP: usize = 16384;

struct Rec {
    at_ms: u64,
    step: usize,
    verb: &'static str,
    /// 0 when the verb is not a retry.
    attempt: u32,
    what: String,
}

struct Segment {
    step: usize,
    head: Vec<Rec>,
    tail: Vec<Rec>,
    tail_at: usize,
    dropped: u64,
}

impl Segment {
    fn len(&self) -> usize {
        self.head.len() + self.tail.len()
    }
}

struct Trace {
    start: Option<Instant>,
    step: usize,
    /// The script's own text, by step ordinal — the records carry the
    /// ordinal, so a dropped record still knows which step it was in.
    steps: Vec<String>,
    segments: Vec<Segment>,
    kept: usize,
    dropped: u64,
    /// Steps evicted whole past CAP, with their record counts.
    evicted: Vec<(usize, u64)>,
}

impl Trace {
    const fn new() -> Self {
        Trace {
            start: None,
            step: 0,
            steps: Vec::new(),
            segments: Vec::new(),
            kept: 0,
            dropped: 0,
            evicted: Vec::new(),
        }
    }

    fn push(&mut self, rec: Rec) {
        let at = match self.segments.iter().rposition(|s| s.step == rec.step) {
            Some(at) => at,
            None => {
                self.segments.push(Segment { step: rec.step, head: Vec::new(), tail: Vec::new(), tail_at: 0, dropped: 0 });
                self.segments.len() - 1
            }
        };
        let seg = &mut self.segments[at];
        if seg.head.len() < STEP_HEAD {
            seg.head.push(rec);
            self.kept += 1;
        } else if seg.tail.len() < STEP_TAIL {
            seg.tail.push(rec);
            self.kept += 1;
        } else {
            seg.tail[seg.tail_at] = rec;
            seg.tail_at = (seg.tail_at + 1) % STEP_TAIL;
            seg.dropped += 1;
            self.dropped += 1;
        }
        while self.kept > CAP && self.segments.len() > 1 {
            let gone = self.segments.remove(0);
            let n = gone.len() as u64 + gone.dropped;
            self.kept -= gone.len();
            self.dropped += gone.len() as u64;
            self.evicted.push((gone.step, n));
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

/// A file BESIDE the trace, for this leg: `KAYA_VERB_TRACE` names
/// `…\<leg>-vtrace.txt` on windows and `…/<leg>.vtrace` on linux, so a
/// capture written as `…\<leg>-<suffix>` is pulled into that leg's bundle
/// (tools/lib/flightrec_lane.py's windows sections, tools/linux/run-suites.sh).
/// None when nothing is recording — a hand-launched guest writes no captures.
#[cfg(any(target_os = "windows", target_os = "linux"))]
pub(crate) fn sibling(suffix: &str) -> Option<std::path::PathBuf> {
    let path = std::path::PathBuf::from(std::env::var_os(ENV_VAR)?);
    let name = path.file_name()?.to_str()?;
    let stem = name.strip_suffix("-vtrace.txt").or_else(|| name.strip_suffix(".vtrace"))?;
    Some(path.with_file_name(format!("{stem}-{suffix}")))
}

/// ONE LINE, WRITTEN NOW, past the ring: the ring reaches the file only
/// through `dump`, which a PANIC never runs — and the toast capture's own
/// sentence is written on the path that then panics (winui/mod.rs,
/// `capture_toast_moment`).
#[cfg(target_os = "windows")]
pub(crate) fn line(text: &str) {
    let Some(path) = std::env::var_os(ENV_VAR) else {
        return;
    };
    use std::io::Write;
    let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) else {
        return;
    };
    let _ = writeln!(f, "KAYA_VERB_TRACE: {text}");
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
        kept = t.kept;
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
        let line = |out: &mut String, r: &Rec| {
            out.push_str(&format!(
                "KAYA_VERB_TRACE: t={} step={} verb={} try={} what={}\n",
                r.at_ms,
                r.step,
                r.verb,
                r.attempt,
                quoted(&r.what)
            ));
        };
        for (step, n) in &t.evicted {
            out.push_str(&format!("KAYA_VERB_TRACE: step={step} dropped={n}\n"));
        }
        for seg in &t.segments {
            for r in &seg.head {
                line(&mut out, r);
            }
            if seg.dropped > 0 {
                out.push_str(&format!("KAYA_VERB_TRACE: step={} dropped={}\n", seg.step, seg.dropped));
            }
            for r in seg.tail[seg.tail_at..].iter().chain(seg.tail[..seg.tail_at].iter()) {
                line(&mut out, r);
            }
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
