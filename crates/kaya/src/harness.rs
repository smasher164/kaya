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
//!   expect entry#<index> "<text>"     (reads the field's displayed text)
//!   expect image#<index> "<WxH>"      (reads the decoded image's size)
//!   expect_focused <kind>#<index>
//!
//! Targets are (kind, creation index) — stamped copies enter the count
//! in creation order, so `button#last` is "the most recently stamped
//! button", today's milestone-2 idiom. Every step is logged with its
//! offset from the run's start (`KAYA_HARNESS: +<ms> <step>`): the
//! transcript is the timeline a recording mode will extract frames by,
//! relative offsets only, no wall clock.
//!
//! `kind#index` is HARNESS grammar and nothing else. App code never
//! addresses positionally — an app holds the WidgetId its constructor
//! returned, or names collection rows by their domain keys — and no
//! binding exposes an index lookup. The harness gets indices because
//! it drives scenes from OUTSIDE the process, across eight language
//! guests sharing one byte-identical script, where a handle cannot
//! exist; even here the indexability policy bites — leaf kinds index
//! stably because body order is screen order in every language, while
//! container creation order is not, so tools/check-steps.sh rejects
//! every container target except the unique-by-convention
//! `column#0`/`row#0`.

use std::time::{Duration, Instant};

/// The scene scripts, embedded from tools/scenes at build time.
pub fn script(scene: &str) -> Option<&'static str> {
    match scene {
        "entry" => Some(include_str!("../../../tools/scenes/entry.steps")),
        "gallery" => Some(include_str!("../../../tools/scenes/gallery.steps")),
        "todos" => Some(include_str!("../../../tools/scenes/todos.steps")),
        "reorder" => Some(include_str!("../../../tools/scenes/reorder.steps")),
        "feed" => Some(include_str!("../../../tools/scenes/feed.steps")),
        "layout" => Some(include_str!("../../../tools/scenes/layout.steps")),
        "grow" => Some(include_str!("../../../tools/scenes/grow.steps")),
        "align" => Some(include_str!("../../../tools/scenes/align.steps")),
        "window" => Some(include_str!("../../../tools/scenes/window.steps")),
        "panels" => Some(include_str!("../../../tools/scenes/panels.steps")),
        "confirm" => Some(include_str!("../../../tools/scenes/confirm.steps")),
        "nav" => Some(include_str!("../../../tools/scenes/nav.steps")),
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
    /// Rows are targetable under the same convention as columns: only
    /// index 0, only in a scene that keeps exactly one row, because
    /// container creation order legitimately differs per language
    /// (tools/check-steps.sh holds the line). Landed for the
    /// horizontal grow assertion — before this, a backend that grew
    /// only columns would have passed the whole matrix.
    Row,
    Image,
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
    /// Expect the widget to hold keyboard focus — the observation the
    /// focus command is verified by (there is no other way to see
    /// focus land).
    ExpectFocused(Target),
    /// Expect the container's children to occupy the given `,`-joined
    /// percentages of the main axis — the observation layout weights
    /// are verified by.
    ///
    /// Shares, never sizes: absolute geometry is a *metric*, which
    /// DESIGN leaves platform-flavored, so a size assertion could not
    /// be shared byte-for-byte the way every other expect is. A share
    /// is *semantics*, and identical everywhere by construction — give
    /// a container none but growing children and the split is exactly
    /// weight/Σweight whatever the platform's control metrics are.
    ExpectShares(Target, String),
    /// Expect the mounted root to fill the window's content area — the
    /// observation "the root fills its window" (a DESIGN normalization)
    /// is verified by, and the one thing shares can NEVER see: a share
    /// is a percentage of the children's sum, which is total-invariant,
    /// so a root that hugs its content at a fraction of the window
    /// still splits 25/75 and passes every share assertion. That blind
    /// spot shipped twice (GTK's root hugged top-left; UIKit's root was
    /// pinned top+leading only) and both times only a recording caught
    /// it — this step is the gate that does instead.
    ExpectRootFills,
    /// Expect the container's children to span its content box along
    /// the main axis — the leftover-consumption half of the grow
    /// contract, and the second blind spot shares can never see:
    /// growers that hold their weight RATIO at natural size pass every
    /// share assertion (shares are percentages of the children's sum,
    /// which is total-invariant) while consuming none of the leftover.
    /// root_fills cannot see it either — it stops at the root, and the
    /// root can be forced full-size by its window while its children
    /// pool the leftover in container slack. That exact combination
    /// shipped: AppKit's gravity-areas distribution left the bottom
    /// pull unenforced, growers sat at ratio'd minimums, every gate
    /// stayed green, and only a 540x330 window made it visible where
    /// 320x160 had hidden it. This step is the gate that sees it.
    ExpectFills(Target),
    /// Expect the container's children to sit at the given cross-axis
    /// placement — the observation the `align` prop is verified by.
    /// The stage CLASSIFIES from geometry (which edges or centers
    /// coincide, whether breadths fill, whether text baselines agree)
    /// rather than reading the prop back: a backend that ignored the
    /// write while the model still carried it must fail here.
    ExpectAligned(Target, String),
    /// None = the implicit primary (window 0), keeping the
    /// single-window spelling; Some(n) prefixes the observation with
    /// `window#n `.
    ExpectTitle(Option<u64>, String),
    ExpectWindowSize(Option<u64>, f64, f64),
    /// Drive the window's REAL chrome close (performClose, WM_CLOSE,
    /// gtk close) — the veto grammar's trigger.
    CloseWindow(u64),
    /// The number of live surfaces (primary included).
    ExpectWindows(usize),
    /// Expect a live modal alert (over the target window; None = the
    /// primary) whose REAL presented title matches — read from the
    /// platform dialog, never the request's copy.
    ExpectAlert(Option<u64>, String),
    /// Drive the live alert's REAL answer path: press the action
    /// button (0 or 1) or fire the platform's dismissal (the cancel
    /// slot). An action, silent like click and close_window.
    AlertChoose(u32),
    /// The number of live alerts (0 or 1 — one per process).
    ExpectAlerts(usize),
    /// The window's navigation-stack depth (None = the implicit
    /// primary; Some(n) prefixes the observation with `window#n `).
    ExpectEntries(Option<u64>, usize),
    /// Drive the window's REAL back affordance (the toolbar back
    /// button's path, the predictive gesture's path): an armed
    /// intercept_back entry emits back_requested and nothing pops; an
    /// unarmed top pops and reports entry_popped. An action, silent
    /// like click and close_window. None = the implicit primary.
    Back(Option<u64>),
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
    /// The displayed text of an entry — what the user sees in the
    /// field, read from the toolkit (the observation the clear command
    /// is pinned by: the occurrence fold alone cannot prove the screen
    /// emptied). No default, like child_texts: a backend that forgets
    /// it fails to compile.
    fn read_text(&self, target: Target) -> String;
    /// Whether the widget holds keyboard focus, read from the toolkit
    /// (per-window focus, never global key status — parallel tiled
    /// legs must not steal each other's assertion). No default.
    fn is_focused(&self, target: Target) -> bool;
    /// The decoded size of an image, as "WxH" — the observation that
    /// pins "the bytes actually decoded and display" (a failed decode
    /// reads "0x0", the placeholder class). No default, like
    /// child_texts: a backend that forgets it fails to compile.
    fn image_size(&self, target: Target) -> String;
    /// The texts of the container's label children, in child order,
    /// joined with `|` — the observation expect_order verifies. No
    /// default: a backend that forgets it must fail to compile, not
    /// panic on the first reorder leg (which is how the GTK gap
    /// reached the Linux suite).
    fn child_texts(&self, target: Target) -> String;
    /// Whether the mounted root fills the window's content area, read
    /// from the toolkit after forcing pending layout: the empty string
    /// when it does (within one device unit — rounding is not a hug),
    /// otherwise a short platform-flavored description of the two
    /// rects, which only ever appears in failure text and is never
    /// compared across platforms. "Content area" is the platform's own
    /// notion — the safe area on iOS, the contentView on macOS, the
    /// window's child area on GTK and WinUI, the content parent on
    /// Android. No default, like child_shares: a backend that forgets
    /// it must fail to compile rather than pass the fill leg vacuously.
    fn root_fills(&self) -> String;
    /// The main-axis extents of the container's children, in child
    /// order, each as a whole percentage of their sum, joined with `,`
    /// — the observation expect_shares verifies, and the only way a
    /// layout weight is observable at all.
    ///
    /// Their sum, not the container's extent: spacing and padding are
    /// platform metrics, so dividing by the container would leak them
    /// into the number and break the byte-for-byte comparison. Read the
    /// alignment/layout rect where the toolkit distinguishes it from
    /// the drawing frame (AppKit inflates a slider's frame past its
    /// alignment rect, which would read 1:3 as 2.90:1).
    ///
    /// No default, like child_texts: a backend that forgets it must
    /// fail to compile rather than pass a layout leg vacuously.
    fn child_shares(&self, target: Target) -> String;
    /// Whether the container's children (plumbing like leftover
    /// fillers excluded) span its content box along the main axis,
    /// read from the toolkit after forcing pending layout: the empty
    /// string when they do (within two device units), otherwise a
    /// short platform-flavored description of the span and the box,
    /// which only ever appears in failure text and is never compared
    /// across platforms. The observation expect_fills verifies. No
    /// default, like child_shares: a backend that forgets it must
    /// fail to compile rather than pass the consumption leg vacuously.
    fn container_fills(&self, target: Target) -> String;
    /// The container's cross-axis placement, CLASSIFIED from geometry
    /// after forcing pending layout: one of "start", "center", "end",
    /// "stretch", or "baseline" when the corresponding coincidence
    /// holds for every child (within two device units), otherwise a
    /// short platform-flavored description of what was seen (failure
    /// text only, never compared across platforms). Baseline is
    /// meaningful on rows alone and classifies via each toolkit's own
    /// baseline query. The observation expect_aligned verifies. No
    /// default: a backend that forgets it must fail to compile.
    fn cross_mode(&self, target: Target) -> String;
    /// A surface's REAL materialized title (the title bar on the
    /// desktops, the task label on Android) — never the scene
    /// model's copy, so a backend that ignored the write fails. No
    /// default: a backend that forgets it must fail to compile.
    fn window_title(&self, window: u64) -> String;
    /// A surface's REAL content extent in device-independent units —
    /// what expect_window_size compares against the advisory
    /// request. No default, like window_title.
    fn window_content_size(&self, window: u64) -> (f64, f64);
    /// Drive the surface's REAL chrome close (performClose, WM_CLOSE,
    /// gtk close) — a veto_close window emits close_requested and
    /// stays; a non-veto auxiliary closes and reports window_closed.
    fn close_window(&self, window: u64);
    /// The number of live surfaces, primary included.
    fn window_count(&self) -> usize;
    /// The REAL presented title of the live alert over the window, or
    /// None when no alert is live there — read from the platform
    /// dialog (NSAlert's messageText, ContentDialog's Title, ...),
    /// never the request's copy. No default: a backend that forgets
    /// it must fail to compile.
    fn alert_title(&self, window: u64) -> Option<String>;
    /// Drive the live alert's REAL answer path: activate the action
    /// button (choice 0 or 1) or the cancel slot (the sentinel) the
    /// way the platform's own dismissal would. No default.
    fn choose_alert(&self, choice: u32);
    /// The number of live alerts (0 or 1). No default.
    fn alert_count(&self) -> usize;
    /// The window's navigation-stack depth — the observation
    /// expect_entries verifies. No default: a backend that forgets it
    /// must fail to compile rather than pass a navigation leg
    /// vacuously.
    fn entry_count(&self, window: u64) -> usize;
    /// Drive the window's REAL back affordance. No default.
    fn back(&self, window: u64);
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
            "expect_focused" => Step::ExpectFocused(parse_target(rest)?),
            "expect_order" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_order wants a target and a string: {line:?}")
                })?;
                Step::ExpectOrder(parse_target(target)?, parse_string(text)?)
            }
            "expect_shares" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_shares wants a target and a string: {line:?}")
                })?;
                Step::ExpectShares(parse_target(target)?, parse_string(text)?)
            }
            "expect_fills" => Step::ExpectFills(parse_target(rest)?),
            "expect_aligned" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_aligned wants a target and a mode string: {line:?}")
                })?;
                Step::ExpectAligned(parse_target(target)?, parse_string(text)?)
            }
            "expect_root_fills" => {
                if !rest.is_empty() {
                    return Err(format!(
                        "expect_root_fills takes no arguments — the mounted root is the target: {line:?}"
                    ));
                }
                Step::ExpectRootFills
            }
            "expect_title" => {
                let (window, rest) = parse_window_target(rest);
                Step::ExpectTitle(window, parse_string(rest)?)
            }
            "expect_window_size" => {
                let (window, rest) = parse_window_target(rest);
                let (w, h) = rest.split_once('x').ok_or_else(|| {
                    format!("expect_window_size wants WxH: {line:?}")
                })?;
                let w = w.trim().parse::<f64>().map_err(|_| {
                    format!("expect_window_size wants numeric WxH: {line:?}")
                })?;
                let h = h.trim().parse::<f64>().map_err(|_| {
                    format!("expect_window_size wants numeric WxH: {line:?}")
                })?;
                Step::ExpectWindowSize(window, w, h)
            }
            "close_window" => {
                let (window, rest) = parse_window_target(rest);
                if !rest.is_empty() {
                    return Err(format!(
                        "close_window takes one window#N target: {line:?}"
                    ));
                }
                let window = window.ok_or_else(|| {
                    format!("close_window wants an explicit window#N: {line:?}")
                })?;
                Step::CloseWindow(window)
            }
            "expect_windows" => {
                let n = rest.trim().parse::<usize>().map_err(|_| {
                    format!("expect_windows wants a count: {line:?}")
                })?;
                Step::ExpectWindows(n)
            }
            "expect_alert" => {
                let (window, rest) = parse_window_target(rest);
                Step::ExpectAlert(window, parse_string(rest)?)
            }
            "alert_choose" => {
                let choice = match rest.trim() {
                    "0" => 0,
                    "1" => 1,
                    "cancel" => u32::MAX,
                    other => {
                        return Err(format!(
                            "alert_choose wants 0, 1, or cancel, got {other:?}: {line:?}"
                        ))
                    }
                };
                Step::AlertChoose(choice)
            }
            "expect_alerts" => {
                let n = rest.trim().parse::<usize>().map_err(|_| {
                    format!("expect_alerts wants a count: {line:?}")
                })?;
                Step::ExpectAlerts(n)
            }
            "expect_entries" => {
                let (window, rest) = parse_window_target(rest);
                let n = rest.trim().parse::<usize>().map_err(|_| {
                    format!("expect_entries wants a count: {line:?}")
                })?;
                Step::ExpectEntries(window, n)
            }
            "back" => {
                let (window, rest) = parse_window_target(rest);
                if !rest.trim().is_empty() {
                    return Err(format!(
                        "back takes at most one window#N target: {line:?}"
                    ));
                }
                Step::Back(window)
            }
            other => return Err(format!("unknown step {other:?}")),
        };
        steps.push(step);
        }
    }
    Ok(steps)
}

/// An optional leading `window#N` token; the remainder is returned
/// for the verb's own parsing. None keeps the implicit primary.
fn parse_window_target(rest: &str) -> (Option<u64>, &str) {
    let trimmed = rest.trim_start();
    if let Some(tail) = trimmed.strip_prefix("window#") {
        let digits: &str = tail.split_whitespace().next().unwrap_or("");
        if let Ok(n) = digits.parse::<u64>() {
            let after = &tail[digits.len()..];
            return (Some(n), after.trim_start());
        }
    }
    (None, rest)
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
        "row" => TargetKind::Row,
        "image" => TargetKind::Image,
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

/// A recorded leg must outlive its last sample time. The extractor
/// takes the final expect's still at that step's own transcript moment,
/// and the window closes within ONE capture-frame period of that moment
/// — the verdict and exit follow the last step by milliseconds. Any
/// anchor drift then hands the covering-frame rule a teardown frame:
/// the GTK stills were the bare Xvfb root, because the arithmetic
/// anchor (kill-time minus duration) drifts ~150ms and at 15fps that is
/// two black frames. Holding the window briefly after the steps makes
/// every sampled moment a live one whatever the anchor error, on every
/// backend alike. Without a recorder this is a no-op; the pre-flight
/// failures (bad script, no expects) skip it — they ran no steps worth
/// sampling.
fn record_linger() {
    if std::env::var_os("KAYA_RECORD").is_some()
        || std::env::var_os("KAYA_HARNESS_GATE").is_some()
    {
        std::thread::sleep(Duration::from_millis(750));
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
        .any(|s| {
            matches!(
                s,
                Step::Expect(..)
                    | Step::ExpectOrder(..)
                    | Step::ExpectFocused(..)
                    | Step::ExpectShares(..)
                    | Step::ExpectRootFills
                    | Step::ExpectFills(..)
                    | Step::ExpectAligned(..)
            )
        })
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
                // The target kind picks the observation: an entry
                // reads its own displayed text, an image its decoded
                // size, a label its text — and nothing else reads at
                // all: routing any other kind to read_label would
                // index the LABELS registry with a foreign target and
                // silently read a different widget (the interpreters
                // already reject these loudly).
                let got = match t.kind {
                    TargetKind::Entry => stage.read_text(*t),
                    TargetKind::Image => stage.image_size(*t),
                    TargetKind::Label => stage.read_label(*t),
                    other => {
                        failures.push(format!(
                            "expect reads labels, entries and images — not {other:?}"
                        ));
                        continue;
                    }
                };
                if got == *want {
                    observed.push(got);
                } else {
                    failures.push(format!("{t:?} reads {got:?}, wanted {want:?}"));
                }
            }
            Step::ExpectOrder(t, want) => {
                // Container verbs take container targets and nothing
                // else — resolving a label target against a container
                // registry (or vice versa) would silently read a
                // DIFFERENT widget, the false-verdict class the
                // interpreters already reject loudly.
                if !matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    failures.push(format!("{t:?} is not a container target"));
                    continue;
                }
                let got = stage.child_texts(*t);
                if got == *want {
                    observed.push(got);
                } else {
                    failures.push(format!("{t:?} ordered {got:?}, wanted {want:?}"));
                }
            }
            Step::ExpectShares(t, want) => {
                if !matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    failures.push(format!("{t:?} is not a container target"));
                    continue;
                }
                let got = stage.child_shares(*t);
                if got == *want {
                    observed.push(got);
                } else {
                    failures.push(format!("{t:?} splits {got:?}, wanted {want:?}"));
                }
            }
            Step::ExpectRootFills => {
                // Empty means fills; anything else is the platform's
                // own description of the hug, for the failure text
                // alone — the pass observation is the byte-identical
                // "root fills" on every backend.
                let hug = stage.root_fills();
                if hug.is_empty() {
                    observed.push("root fills".to_owned());
                } else {
                    failures.push(format!("root hugs ({hug})"));
                }
            }
            Step::ExpectTitle(window, want) => {
                // The REAL materialized title (the title bar / task
                // label), never the scene model's copy — a backend
                // that ignored the write must fail. The pass
                // observation is byte-identical on every backend; an
                // explicit window target prefixes it.
                let id = window.unwrap_or(0);
                let prefix = match window {
                    Some(n) => format!("window#{n} "),
                    None => String::new(),
                };
                let got = stage.window_title(id);
                if got == *want {
                    observed.push(format!("{prefix}title {want:?}"));
                } else {
                    failures.push(format!("{prefix}title {got:?}, wanted {want:?}"));
                }
            }
            Step::ExpectWindowSize(window, w, h) => {
                // The surface's REAL content extent against the
                // advisory request, within 2 device units.
                let id = window.unwrap_or(0);
                let prefix = match window {
                    Some(n) => format!("window#{n} "),
                    None => String::new(),
                };
                let (gw, gh) = stage.window_content_size(id);
                if (gw - w).abs() <= 2.0 && (gh - h).abs() <= 2.0 {
                    observed.push(format!("{prefix}window {}x{}", *w as i64, *h as i64));
                } else {
                    failures.push(format!(
                        "{prefix}window {}x{}, wanted {}x{}",
                        gw as i64, gh as i64, *w as i64, *h as i64
                    ));
                }
            }
            Step::CloseWindow(window) => {
                // An action, silent like click: the veto grammar's
                // observable is what the scene does next.
                stage.close_window(*window);
            }
            Step::ExpectWindows(n) => {
                let got = stage.window_count();
                if got == *n {
                    observed.push(format!("windows {n}"));
                } else {
                    failures.push(format!("windows {got}, wanted {n}"));
                }
            }
            Step::ExpectAlert(window, want) => {
                // The REAL presented title, never the request's copy —
                // a backend that materialized nothing must fail here.
                let id = window.unwrap_or(0);
                let prefix = match window {
                    Some(n) => format!("window#{n} "),
                    None => String::new(),
                };
                match stage.alert_title(id) {
                    Some(got) if got == *want => {
                        observed.push(format!("{prefix}alert {want:?}"));
                    }
                    Some(got) => {
                        failures.push(format!("{prefix}alert {got:?}, wanted {want:?}"));
                    }
                    None => {
                        failures.push(format!("{prefix}no alert live, wanted {want:?}"));
                    }
                }
            }
            Step::AlertChoose(choice) => {
                // An action, silent like click: the observable is the
                // guest's reaction to the result.
                stage.choose_alert(*choice);
            }
            Step::ExpectAlerts(n) => {
                let got = stage.alert_count();
                if got == *n {
                    observed.push(format!("alerts {n}"));
                } else {
                    failures.push(format!("alerts {got}, wanted {n}"));
                }
            }
            Step::ExpectEntries(window, n) => {
                let id = window.unwrap_or(0);
                let prefix = match window {
                    Some(w) => format!("window#{w} "),
                    None => String::new(),
                };
                let got = stage.entry_count(id);
                if got == *n {
                    observed.push(format!("{prefix}entries {n}"));
                } else {
                    failures.push(format!("{prefix}entries {got}, wanted {n}"));
                }
            }
            Step::Back(window) => {
                // An action, silent like click: the observable is
                // whether the stack popped (expect_entries) or the
                // guest's back_requested reaction.
                stage.back(window.unwrap_or(0));
            }
            Step::ExpectFills(t) => {
                if !matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    failures.push(format!("{t:?} is not a container target"));
                    continue;
                }
                // Empty means the children span the content box; the
                // pass observation is the byte-identical
                // "column#0 fills" every backend and interpreter emits.
                let slack = stage.container_fills(*t);
                if slack.is_empty() {
                    observed.push(format!("{} fills", target_spec(t)));
                } else {
                    failures.push(format!("{} leaves leftover ({slack})", target_spec(t)));
                }
            }
            Step::ExpectAligned(t, want) => {
                if !matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    failures.push(format!("{t:?} is not a container target"));
                    continue;
                }
                let got = stage.cross_mode(*t);
                if got == *want {
                    observed.push(format!("{} aligns {got}", target_spec(t)));
                } else {
                    failures.push(format!(
                        "{} aligns {got:?}, wanted {want:?}",
                        target_spec(t)
                    ));
                }
            }
            Step::ExpectFocused(t) => {
                if stage.is_focused(*t) {
                    observed.push(format!("{t:?} focused"));
                } else {
                    failures.push(format!("{t:?} does not hold focus"));
                }
            }
        }
    }
    record_linger();
    if failures.is_empty() {
        stage.finish(0, &format!("KAYA_SELFTEST: OK ({})", observed.join(", ")));
    } else {
        stage.finish(1, &format!("KAYA_SELFTEST: FAILED ({})", failures.join("; ")));
    }
}

/// The steps-file spelling of a target — "column#0" — for observation
/// strings that echo their target. One implementation so the pass
/// observations stay byte-identical; the interpreters emit the same
/// spelling from their own runners.
fn target_spec(t: &Target) -> String {
    let kind = match t.kind {
        TargetKind::Button => "button",
        TargetKind::Checkbox => "checkbox",
        TargetKind::Slider => "slider",
        TargetKind::Entry => "entry",
        TargetKind::Label => "label",
        TargetKind::Column => "column",
        TargetKind::Row => "row",
        TargetKind::Image => "image",
    };
    if t.index < 0 {
        format!("{kind}#last")
    } else {
        format!("{kind}#{}", t.index)
    }
}

/// Format child main-axis extents as whole-percentage shares of their
/// sum, joined with `,` — the one implementation every backend's
/// `child_shares` formats through.
///
/// Shared because the *rounding* has to be identical everywhere, not
/// just the arithmetic: expect_shares compares byte-for-byte, so a
/// backend that rounded 24.6 to 24 while another rounded to 25 would
/// fail a leg over a formatting difference and read as a layout bug.
/// An empty container, or one whose children are all zero-extent,
/// reports the empty string rather than dividing by zero.
pub fn shares(extents: &[f64]) -> String {
    let total: f64 = extents.iter().sum();
    if total <= 0.0 {
        return String::new();
    }
    extents
        .iter()
        .map(|e| format!("{}", (e / total * 100.0).round() as i64))
        .collect::<Vec<_>>()
        .join(",")
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
        for scene in ["entry", "gallery", "todos", "reorder", "feed", "align", "1"] {
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
        assert_eq!(
            parse("expect_shares column#1 \"25,75\"").unwrap()[0],
            Step::ExpectShares(
                Target { kind: TargetKind::Column, index: 1 },
                "25,75".into()
            )
        );
    }

    /// Shares are percentages of the children's *sum*, so container
    /// spacing and padding — platform metrics both — stay out of the
    /// number, and every backend rounds identically.
    #[test]
    fn shares_are_percentages_of_the_child_sum() {
        assert_eq!(shares(&[78.0, 234.0]), "25,75");
        // Same split, different absolute metrics: the whole point.
        assert_eq!(shares(&[7.8, 23.4]), "25,75");
        // Spacing is not subtracted here because it was never added:
        // a container 8pt wider does not move the shares.
        assert_eq!(shares(&[1.0, 1.0, 2.0]), "25,25,50");
        // Degenerate containers report nothing rather than dividing by
        // zero, so a backend cannot pass a leg with a collapsed tree.
        assert_eq!(shares(&[]), "");
        assert_eq!(shares(&[0.0, 0.0]), "");
    }

    /// A `;` inside a comment is prose, not a statement separator —
    /// the regression that once turned "…; both labels…" into steps.
    #[test]
    fn comments_swallow_their_semicolons() {
        let steps = parse("# wait; settle 999; chaos\nexpect label#0 \"x\"").unwrap();
        assert_eq!(steps.len(), 1);
    }

    /// expect routes by target kind (entry reads the field, labels
    /// read label text) and expect_focused both parses and counts as
    /// an expect for the zero-expect guard.
    #[test]
    fn entry_expect_and_focus_route_and_count() {
        let steps =
            parse("expect entry#0 \"entry-text\"\nexpect_focused entry#0").unwrap();
        assert_eq!(steps[1], Step::ExpectFocused(Target { kind: TargetKind::Entry, index: 0 }));
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert!(verdict.contains("entry-text"), "{verdict}");
        assert!(verdict.contains("focused"), "{verdict}");
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
        fn read_text(&self, _: Target) -> String {
            "entry-text".into()
        }
        fn is_focused(&self, _: Target) -> bool {
            true
        }
        fn image_size(&self, _: Target) -> String {
            "2x2".into()
        }
        fn child_texts(&self, _: Target) -> String {
            "a|b".into()
        }
        fn child_shares(&self, _: Target) -> String {
            "25,75".into()
        }
        fn window_title(&self, _: u64) -> String {
            "mock".to_owned()
        }
        fn window_content_size(&self, _: u64) -> (f64, f64) {
            (540.0, 330.0)
        }
        fn close_window(&self, _: u64) {}
        fn entry_count(&self, _: u64) -> usize {
            0
        }
        fn back(&self, _: u64) {}
        fn window_count(&self) -> usize {
            1
        }
        fn alert_title(&self, _window: u64) -> Option<String> {
            None
        }
        fn choose_alert(&self, _choice: u32) {}
        fn alert_count(&self) -> usize {
            0
        }
        fn root_fills(&self) -> String {
            String::new()
        }
        fn container_fills(&self, _: Target) -> String {
            String::new()
        }
        fn cross_mode(&self, _: Target) -> String {
            "center".into()
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

    /// expect_shares counts as an expect for the zero-expect guard, and
    /// compares against the stage's child_shares.
    ///
    /// The zero-expect half is the load-bearing half: a scene whose only
    /// assertion is a layout one — which is exactly what a conformance
    /// scene is — would otherwise be rejected as asserting nothing, and
    /// the natural "fix" is to weaken the scene rather than the guard.
    #[test]
    fn expect_shares_is_an_expect() {
        let steps = parse("expect_shares column#0 \"25,75\"").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (25,75)");
        // A wrong split fails loudly rather than being tolerated: the
        // whole point of the verb is that an ordinal or equal-split
        // implementation cannot pass.
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_shares column#0 \"50,50\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("splits"), "{verdict}");
    }

    /// expect_root_fills parses bare (a target would be a lie — the
    /// mounted root is the only thing it can mean), counts as an expect
    /// for the zero-expect guard, and reads the stage's root_fills:
    /// empty is the fill, anything else is the hug's description.
    #[test]
    fn expect_root_fills_is_an_expect() {
        let steps = parse("expect_root_fills").unwrap();
        assert_eq!(steps[0], Step::ExpectRootFills);
        assert!(parse("expect_root_fills column#0").is_err());
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (root fills)");
        struct Hugger(Sender<(i32, String)>);
        impl Stage for Hugger {
            fn click(&self, _: Target) {}
            fn toggle(&self, _: Target, _: bool) {}
            fn set_value(&self, _: Target, _: f64) {}
            fn set_text(&self, _: Target, _: &str) {}
            fn read_label(&self, _: Target) -> String {
                String::new()
            }
            fn read_text(&self, _: Target) -> String {
                String::new()
            }
            fn is_focused(&self, _: Target) -> bool {
                false
            }
            fn image_size(&self, _: Target) -> String {
                String::new()
            }
            fn child_texts(&self, _: Target) -> String {
                String::new()
            }
            fn child_shares(&self, _: Target) -> String {
                String::new()
            }
            fn window_title(&self, _: u64) -> String {
            "mock".to_owned()
        }
        fn window_content_size(&self, _: u64) -> (f64, f64) {
            (540.0, 330.0)
        }
        fn close_window(&self, _: u64) {}
        fn entry_count(&self, _: u64) -> usize {
            0
        }
        fn back(&self, _: u64) {}
        fn window_count(&self) -> usize {
            1
        }
        fn root_fills(&self) -> String {
                "34x27pt inside 390x844pt".into()
            }
            fn container_fills(&self, _: Target) -> String {
                "children span 92pt of 298pt".into()
            }
            fn cross_mode(&self, _: Target) -> String {
                "start".into()
            }
            fn alert_title(&self, _window: u64) -> Option<String> {
            None
        }
        fn choose_alert(&self, _choice: u32) {}
        fn alert_count(&self) -> usize {
            0
        }
        fn finish(&self, code: i32, verdict: &str) {
                let _ = self.0.send((code, verdict.to_owned()));
            }
        }
        let (tx, rx) = std::sync::mpsc::channel();
        run(parse("expect_root_fills").unwrap(), Hugger(tx));
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("root hugs"), "{verdict}");
    }

    /// expect_fills takes a container target, counts as an expect for
    /// the zero-expect guard, emits the byte-identical "column#0
    /// fills" observation on pass, and fails with the platform's slack
    /// description otherwise. The pass half is the load-bearing half:
    /// growers that hold their ratio at natural size pass every share
    /// assertion while consuming nothing — this is the verb that sees
    /// the leftover (the AppKit gravity-areas miss, found only because
    /// a 540x330 window made 200pt of slack impossible to overlook).
    #[test]
    fn expect_fills_is_an_expect() {
        let steps = parse("expect_fills column#0").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectFills(Target { kind: TargetKind::Column, index: 0 })
        );
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (column#0 fills)");
        // A non-container target is the false-verdict class: resolving
        // label#0 against a container registry would read a different
        // widget. Rejected loudly, exactly like the other container
        // verbs.
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_fills label#0").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("not a container target"), "{verdict}");
        // Slack fails loudly: the whole point of the verb is that
        // ratio-at-minimum cannot pass it.
        struct Pooler(Sender<(i32, String)>);
        impl Stage for Pooler {
            fn click(&self, _: Target) {}
            fn toggle(&self, _: Target, _: bool) {}
            fn set_value(&self, _: Target, _: f64) {}
            fn set_text(&self, _: Target, _: &str) {}
            fn read_label(&self, _: Target) -> String {
                String::new()
            }
            fn read_text(&self, _: Target) -> String {
                String::new()
            }
            fn is_focused(&self, _: Target) -> bool {
                false
            }
            fn image_size(&self, _: Target) -> String {
                String::new()
            }
            fn child_texts(&self, _: Target) -> String {
                String::new()
            }
            fn child_shares(&self, _: Target) -> String {
                String::new()
            }
            fn window_title(&self, _: u64) -> String {
            "mock".to_owned()
        }
        fn window_content_size(&self, _: u64) -> (f64, f64) {
            (540.0, 330.0)
        }
        fn close_window(&self, _: u64) {}
        fn entry_count(&self, _: u64) -> usize {
            0
        }
        fn back(&self, _: u64) {}
        fn window_count(&self) -> usize {
            1
        }
        fn root_fills(&self) -> String {
                String::new()
            }
            fn container_fills(&self, _: Target) -> String {
                "children span 92pt of 298pt".into()
            }
            fn cross_mode(&self, _: Target) -> String {
                "start".into()
            }
            fn alert_title(&self, _window: u64) -> Option<String> {
            None
        }
        fn choose_alert(&self, _choice: u32) {}
        fn alert_count(&self) -> usize {
            0
        }
        fn finish(&self, code: i32, verdict: &str) {
                let _ = self.0.send((code, verdict.to_owned()));
            }
        }
        let (tx, rx) = std::sync::mpsc::channel();
        run(parse("expect_fills row#0").unwrap(), Pooler(tx));
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("row#0 leaves leftover"), "{verdict}");
        assert!(verdict.contains("92pt of 298pt"), "{verdict}");
    }

    /// expect_aligned takes a container target and a mode, counts as
    /// an expect, emits the byte-identical "column#0 aligns center"
    /// observation on match, and fails with the stage's classification
    /// otherwise — the classification coming from geometry, so a
    /// backend that ignores the prop cannot pass by echoing the model.
    #[test]
    fn expect_aligned_is_an_expect() {
        let steps = parse("expect_aligned column#0 \"center\"").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectAligned(
                Target { kind: TargetKind::Column, index: 0 },
                "center".into()
            )
        );
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (column#0 aligns center)");
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_aligned label#0 \"center\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("not a container target"), "{verdict}");
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_aligned column#0 \"end\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("aligns \"center\", wanted \"end\""), "{verdict}");
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
