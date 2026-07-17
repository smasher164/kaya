//! The interaction test harness: scene scripts as data, one
//! interpreter for every Rust backend.
//!
//! A scene's selftest used to be a hand-written driver per backend per
//! scene — sleep, poke a control through its own event path, sleep,
//! read a label, compare. That knowledge now lives once, in
//! tools/scenes/<scene>.steps (embedded here at build time, so a Rust
//! backend can never run a stale script), and each backend supplies
//! only its native calls through [`Stage`]: how to click its button,
//! flip its checkbox, read its label — code it already had, minus the
//! choreography. The SwiftUI and Compose halves interpret the same
//! grammar in Swift and Kotlin (they own their node trees on the far
//! side of the C ABI); the suites hand them the script text through
//! the environment.
//!
//! The grammar is line-oriented; `;` is accepted as a line separator
//! for transports that cannot carry newlines:
//!
//!   settle <ms>
//!   click <kind>#<index|last>
//!   toggle <kind>#<index> on|off
//!   set_value <kind>#<index> <f64>
//!   set_text <kind>#<index> "<text>"
//!   expect label#<index> "<text>"
//!
//! Targets are (kind, creation index) — stamped copies enter the count
//! in creation order, so `button#last` is "the most recently stamped
//! button", today's milestone-2 idiom. Every step is logged with its
//! offset from the run's start (`KAYA_HARNESS: +<ms> <step>`): the
//! transcript is the timeline a recording mode will extract frames by,
//! relative offsets only, no wall clock.

use std::time::{Duration, Instant};

/// The scene scripts, embedded from tools/scenes at build time.
pub fn script(scene: &str) -> Option<&'static str> {
    match scene {
        "entry" => Some(include_str!("../../../tools/scenes/entry.steps")),
        "gallery" => Some(include_str!("../../../tools/scenes/gallery.steps")),
        "todos" => Some(include_str!("../../../tools/scenes/todos.steps")),
        "reorder" => Some(include_str!("../../../tools/scenes/reorder.steps")),
        // "1" is the plain selftest flag: the milestone-2 scene.
        _ => Some(include_str!("../../../tools/scenes/milestone2.steps")),
    }
}

/// One widget, named by kind and creation order. `index` of -1 is
/// `#last`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Target {
    pub kind: TargetKind,
    pub index: isize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetKind {
    Button,
    Checkbox,
    Slider,
    Entry,
    Label,
    Column,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    Settle(u64),
    Click(Target),
    Toggle(Target, bool),
    SetValue(Target, f64),
    SetText(Target, String),
    Expect(Target, String),
    /// Expect the container's label children to read, in child order,
    /// the given `|`-joined texts — the observation reorder ops are
    /// verified by (creation-order registries cannot see a move).
    ExpectOrder(Target, String),
}

/// What a backend supplies: its native calls, each hopping to its UI
/// thread internally and blocking until applied (reads return the
/// value). The harness thread stays dumb.
pub trait Stage: Send + 'static {
    fn click(&self, target: Target);
    fn toggle(&self, target: Target, on: bool);
    fn set_value(&self, target: Target, value: f64);
    fn set_text(&self, target: Target, text: &str);
    fn read_label(&self, target: Target) -> String;
    /// The texts of the container's label children, in child order,
    /// joined with `|` — the observation expect_order verifies. No
    /// default: a backend that forgets it must fail to compile, not
    /// panic on the first reorder leg (which is how the GTK gap
    /// reached the Linux suite).
    fn child_texts(&self, target: Target) -> String;
    /// Report the verdict and end the process (backends own their exit
    /// discipline: process::exit, request_exit, _exit after finishing
    /// the Activity, ...).
    fn finish(&self, code: i32, verdict: &str);
}

pub fn parse(script: &str) -> Result<Vec<Step>, String> {
    let mut steps = Vec::new();
    // Comments are whole newline-delimited lines; only the statements
    // that remain also split on `;` (the newline stand-in for
    // transports that cannot carry one).
    for raw_line in script.split('\n') {
        let raw_line = raw_line.trim();
        if raw_line.is_empty() || raw_line.starts_with('#') {
            continue;
        }
        for raw in raw_line.split(';') {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (op, rest) = line.split_once(char::is_whitespace).unwrap_or((line, ""));
        let rest = rest.trim();
        let step = match op {
            "settle" => Step::Settle(
                rest.parse()
                    .map_err(|_| format!("settle wants milliseconds: {line:?}"))?,
            ),
            "click" => Step::Click(parse_target(rest)?),
            "toggle" => {
                let (target, state) = rest
                    .split_once(char::is_whitespace)
                    .ok_or_else(|| format!("toggle wants a target and on|off: {line:?}"))?;
                Step::Toggle(
                    parse_target(target)?,
                    match state.trim() {
                        "on" => true,
                        "off" => false,
                        other => return Err(format!("toggle wants on|off, got {other:?}")),
                    },
                )
            }
            "set_value" => {
                let (target, value) = rest
                    .split_once(char::is_whitespace)
                    .ok_or_else(|| format!("set_value wants a target and a number: {line:?}"))?;
                Step::SetValue(
                    parse_target(target)?,
                    value
                        .trim()
                        .parse()
                        .map_err(|_| format!("set_value wants a number: {line:?}"))?,
                )
            }
            "set_text" => {
                let (target, text) = rest
                    .split_once(char::is_whitespace)
                    .ok_or_else(|| format!("set_text wants a target and a string: {line:?}"))?;
                Step::SetText(parse_target(target)?, parse_string(text)?)
            }
            "expect" => {
                let (target, text) = rest
                    .split_once(char::is_whitespace)
                    .ok_or_else(|| format!("expect wants a target and a string: {line:?}"))?;
                Step::Expect(parse_target(target)?, parse_string(text)?)
            }
            "expect_order" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_order wants a target and a string: {line:?}")
                })?;
                Step::ExpectOrder(parse_target(target)?, parse_string(text)?)
            }
            other => return Err(format!("unknown step {other:?}")),
        };
        steps.push(step);
        }
    }
    Ok(steps)
}

fn parse_target(spec: &str) -> Result<Target, String> {
    let (kind, index) = spec
        .split_once('#')
        .ok_or_else(|| format!("target wants kind#index: {spec:?}"))?;
    let kind = match kind {
        "button" => TargetKind::Button,
        "checkbox" => TargetKind::Checkbox,
        "slider" => TargetKind::Slider,
        "entry" => TargetKind::Entry,
        "label" => TargetKind::Label,
        "column" => TargetKind::Column,
        other => return Err(format!("unknown target kind {other:?}")),
    };
    let index = if index == "last" {
        -1
    } else {
        index
            .parse()
            .map_err(|_| format!("target index wants a number or `last`: {spec:?}"))?
    };
    Ok(Target { kind, index })
}

fn parse_string(spec: &str) -> Result<String, String> {
    let spec = spec.trim();
    let inner = spec
        .strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .ok_or_else(|| format!("wanted a quoted string, got {spec:?}"))?;
    Ok(inner.to_owned())
}

/// Run the scene's script on its own thread against a backend's stage.
/// Every step logs its offset from the run's start; expects accumulate,
/// and the verdict joins their observed values — "urgent: true,
/// volume: 75%" — exactly the strings the suites have always printed.
pub fn spawn(scene: &str, stage: impl Stage, log: fn(&str)) {
    let Some(text) = script(scene) else { return };
    let steps = match parse(text) {
        Ok(steps) => steps,
        Err(e) => {
            stage.finish(1, &format!("KAYA_SELFTEST: FAILED (bad script: {e})"));
            return;
        }
    };
    std::thread::spawn(move || run_with_log(steps, stage, Some(log)));
}

/// The synchronous run loop, factored out of spawn so tests can drive
/// it with a mock stage.
pub fn run(steps: Vec<Step>, stage: impl Stage) {
    run_with_log(steps, stage, None);
}

/// Recording handshake: when the runner exports KAYA_HARNESS_GATE, it
/// is recording this window, and the recorder needs time to deliver
/// its first frame (seconds, when several streams start under load).
/// Waiting for the runner's go-file means a leg cannot outrun its
/// recorder; without the variable this is a no-op. Bounded — a
/// recorder that never starts must not hang the scene.
fn gate_wait() {
    let Ok(gate) = std::env::var("KAYA_HARNESS_GATE") else {
        return;
    };
    let deadline = Instant::now() + Duration::from_secs(20);
    while !std::path::Path::new(&gate).exists() {
        if Instant::now() > deadline {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn run_with_log(steps: Vec<Step>, stage: impl Stage, log: Option<fn(&str)>) {
    if log.is_some() {
        gate_wait();
    }
    // Offsets are relative to here — after the gate, so the recording
    // contains every step from its own t=0 onward.
    let start = Instant::now();
    let log = log.map(|log| (log, start));
    if let Some((log, _)) = log {
        // The wall-clock anchor recording mode pairs with the
        // recorder's own start stamp; step offsets stay relative.
        let epoch = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        log(&format!("KAYA_HARNESS: epoch {epoch}"));
    }
    // A script with no expects proves nothing; a transport that
    // mangled the text into a comment must fail, not pass.
    if !steps
        .iter()
        .any(|s| matches!(s, Step::Expect(..) | Step::ExpectOrder(..)))
    {
        stage.finish(1, "KAYA_SELFTEST: FAILED (script has no expects)");
        return;
    }
    let mut observed = Vec::new();
    let mut failures = Vec::new();
    for step in &steps {
        if let Some((log, start)) = log {
            log(&format!(
                "KAYA_HARNESS: +{}ms {:?}",
                start.elapsed().as_millis(),
                step
            ));
        }
        match step {
            Step::Settle(ms) => std::thread::sleep(Duration::from_millis(*ms)),
            Step::Click(t) => stage.click(*t),
            Step::Toggle(t, on) => stage.toggle(*t, *on),
            Step::SetValue(t, v) => stage.set_value(*t, *v),
            Step::SetText(t, s) => stage.set_text(*t, s),
            Step::Expect(t, want) => {
                let got = stage.read_label(*t);
                if got == *want {
                    observed.push(got);
                } else {
                    failures.push(format!("{t:?} reads {got:?}, wanted {want:?}"));
                }
            }
            Step::ExpectOrder(t, want) => {
                let got = stage.child_texts(*t);
                if got == *want {
                    observed.push(got);
                } else {
                    failures.push(format!("{t:?} ordered {got:?}, wanted {want:?}"));
                }
            }
        }
    }
    if failures.is_empty() {
        stage.finish(0, &format!("KAYA_SELFTEST: OK ({})", observed.join(", ")));
    } else {
        stage.finish(1, &format!("KAYA_SELFTEST: FAILED ({})", failures.join("; ")));
    }
}

/// Resolve `#last` against a registry length; panics on out-of-range,
/// which is a script bug worth dying loudly for.
pub fn resolve(index: isize, len: usize) -> usize {
    if index < 0 {
        len.checked_sub(index.unsigned_abs())
            .unwrap_or_else(|| panic!("kaya: harness target #last of an empty registry"))
    } else {
        let i = index as usize;
        assert!(i < len, "kaya: harness target #{index} of {len}");
        i
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::mpsc::Sender;

    #[test]
    fn scripts_parse_and_grammar_round_trips() {
        for scene in ["entry", "gallery", "todos", "reorder", "1"] {
            parse(script(scene).unwrap()).unwrap();
        }
        let steps = parse(
            "# c\nsettle 5; click button#last\ntoggle checkbox#0 on\n\
             set_value slider#0 0.75;set_text entry#0 \"a b\"\nexpect label#1 \"x\"",
        )
        .unwrap();
        assert_eq!(steps.len(), 6);
        assert_eq!(steps[1], Step::Click(Target { kind: TargetKind::Button, index: -1 }));
        assert_eq!(
            steps[4],
            Step::SetText(Target { kind: TargetKind::Entry, index: 0 }, "a b".into())
        );
        assert!(parse("warp reality#0").is_err());
        assert_eq!(resolve(-1, 3), 2);
        assert_eq!(resolve(1, 3), 1);
    }

    /// A `;` inside a comment is prose, not a statement separator —
    /// the regression that once turned "…; both labels…" into steps.
    #[test]
    fn comments_swallow_their_semicolons() {
        let steps = parse("# wait; settle 999; chaos\nexpect label#0 \"x\"").unwrap();
        assert_eq!(steps.len(), 1);
    }

    /// A stage that records interactions and reports the verdict back
    /// through a channel, so tests can watch a whole run.
    struct MockStage {
        seen: &'static Mutex<Vec<String>>,
        verdict: Sender<(i32, String)>,
    }

    impl Stage for MockStage {
        fn click(&self, t: Target) {
            self.seen.lock().unwrap().push(format!("click {t:?}"));
        }
        fn toggle(&self, _: Target, _: bool) {}
        fn set_value(&self, _: Target, _: f64) {}
        fn set_text(&self, _: Target, _: &str) {}
        fn read_label(&self, _: Target) -> String {
            "ok-text".into()
        }
        fn child_texts(&self, _: Target) -> String {
            "a|b".into()
        }
        fn finish(&self, code: i32, verdict: &str) {
            let _ = self.verdict.send((code, verdict.to_owned()));
        }
    }

    static SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());

    /// The zero-expect guard fires: a script a transport mangled into
    /// nothing (or someone forgot to assert in) must fail, not pass.
    #[test]
    fn a_script_with_no_expects_fails() {
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("click button#0").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("no expects"), "{verdict}");
    }

    /// expect_order parses like expect, counts as an expect for the
    /// zero-expect guard, and compares against the stage's child_texts.
    #[test]
    fn expect_order_is_an_expect() {
        let steps = parse("expect_order column#0 \"a|b\"").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectOrder(Target { kind: TargetKind::Column, index: 0 }, "a|b".into())
        );
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (a|b)");
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_order column#0 \"b|a\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("ordered"), "{verdict}");
    }

    /// The verdict format is load-bearing: the suites grep
    /// "KAYA_SELFTEST: OK" and the parenthesized text is the observed
    /// expects joined with ", ".
    #[test]
    fn verdict_joins_observed_expects() {
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect label#0 \"ok-text\";expect label#1 \"ok-text\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0);
        assert_eq!(verdict, "KAYA_SELFTEST: OK (ok-text, ok-text)");
    }
}
