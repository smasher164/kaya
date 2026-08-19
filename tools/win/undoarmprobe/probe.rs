//! THROWAWAY probe for the WinUI UNDO ARM — docs/undo-plan.md §3a and
//! the three questions §1.1 could not ask (the type verb and the
//! ledger-quiet bracket did not exist when it ran). Measures; builds
//! nothing.
//!
//! A MODULE OF THE BACKEND, driving the REAL `undo` example guest
//! (guests/rust/undo.rs) for the reason the first probe gives, and
//! needing no Cargo.toml edit because that example is registered.
//!
//! Wiring (temporary, reverted after the run):
//!   crates/kaya/src/winui/mod.rs
//!     #[path = "../../../../tools/win/undoarmprobe/probe.rs"] mod undoarmprobe;
//!     ... and `undoarmprobe::maybe_spawn();` at the end of `setup`.
//!
//! Every line is prefixed PROBE with a millisecond stamp; the last line
//! is PROBEDONE.

#![allow(dead_code)]

use super::bindings::Microsoft::UI::Xaml::FocusState;
use super::{CORE, CoreState, DISPATCHER, DispatcherQueueHandler};
use std::io::Write as _;
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::time::{Duration, Instant};
use windows_core::HSTRING;

static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

fn say(s: impl AsRef<str>) {
    let t = START.get_or_init(Instant::now).elapsed().as_millis();
    println!("PROBE {t:>6}ms {}", s.as_ref());
    let _ = std::io::stdout().flush();
}

fn nap(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

/// Run a closure on the UI thread with CORE borrowed MUTABLY — the same
/// borrow the chord hook's dispatch (menu_user_activate) holds, which is
/// the state the routing will call `Undo()` under.
fn on_ui<T: Send + 'static>(
    f: impl FnOnce(&mut CoreState) -> windows_core::Result<T> + Send + 'static,
) -> Result<T, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    let Some(dispatcher) = DISPATCHER.get() else {
        return Err("no dispatcher yet".to_owned());
    };
    let cell = std::sync::Mutex::new(Some((f, tx)));
    let handler = DispatcherQueueHandler::new(move || {
        if let Some((f, tx)) = cell.lock().unwrap().take() {
            CORE.with_borrow_mut(|core| match core.as_mut() {
                Some(core) => {
                    let _ =
                        tx.send(f(core).map_err(|e| format!("{} ({:?})", e.message(), e.code())));
                }
                None => {
                    let _ = tx.send(Err("core not built yet".to_owned()));
                }
            });
        }
        Ok(())
    });
    dispatcher
        .0
        .TryEnqueue(&handler)
        .map_err(|e| e.message().to_string())?;
    match rx.recv_timeout(Duration::from_secs(20)) {
        Ok(v) => v,
        Err(_) => Err("UI thread did not answer in 20s".to_owned()),
    }
}

// --- the TextChanged witness ---------------------------------------------
//
// The arm's emit rides the control's own TextChanged, so §3a's question
// IS "does the raw control raise TextChanged for an undo". A SECOND
// handler on the same control records every raise with a stamp, plus
// whether the `Undo()` that provoked it had already returned.

static IN_UNDO: AtomicBool = AtomicBool::new(false);
static EVENTS: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

fn events_take() -> Vec<String> {
    std::mem::take(&mut *EVENTS.lock().unwrap())
}

fn attach_witness() {
    let r = on_ui(|core| {
        let field = core.entries[0].clone();
        let f = field.clone();
        let handler = super::TextChangedEventHandler::new(move |_, _| {
            let t = START.get_or_init(Instant::now).elapsed().as_millis();
            let text = f.Text()?.to_string();
            let can = f.CanUndo()?;
            EVENTS.lock().unwrap().push(format!(
                "TextChanged at {t}ms text={text:?} CanUndo={can} inside_undo_call={}",
                IN_UNDO.load(Relaxed)
            ));
            Ok(())
        });
        field.TextChanged(&handler)?;
        Ok(())
    });
    say(format!("witness attached: {r:?}"));
}

fn snap(label: &str) -> String {
    let out = on_ui(|core| {
        let f = core.entries[0].clone();
        Ok(format!(
            "text={:?} CanUndo={} CanRedo={} sel=({},{}) focus={:?}",
            f.Text()?.to_string(),
            f.CanUndo()?,
            f.CanRedo()?,
            f.SelectionStart()?,
            f.SelectionLength()?,
            f.FocusState()?.0
        ))
    })
    .unwrap_or_else(|e| format!("<unreadable: {e}>"));
    say(format!("{label}: {out}"));
    for e in events_take() {
        say(format!("    event {e}"));
    }
    out
}

// --- real input -----------------------------------------------------------

fn hwnd() -> isize {
    on_ui(|core| {
        let native: super::IWindowNative = windows_core::Interface::cast(&core.window)?;
        native.window_handle()
    })
    .unwrap_or(0)
}

fn foreground() -> bool {
    let h = hwnd();
    if h == 0 {
        say("foreground: no hwnd");
        return false;
    }
    for attempt in 0..150 {
        if unsafe { super::GetForegroundWindow() } == h {
            return true;
        }
        unsafe { super::SetForegroundWindow(h) };
        if attempt == 10 {
            unsafe {
                super::keybd_event(0x1B, 0, 0, 0);
                super::keybd_event(0x1B, 0, 2, 0);
            }
        }
        if attempt == 50 {
            unsafe {
                super::keybd_event(0x12, 0, 0, 0);
                super::keybd_event(0x12, 0, 2, 0);
            }
        }
        nap(20);
    }
    say("foreground: FAILED to take the foreground in 3s");
    false
}

const KEYUP: u32 = 0x2;

/// Real keystrokes on the system input queue, one event pair per
/// character — the shape the `type` verb will take.
fn type_text(s: &str, gap_ms: u64) {
    if !foreground() {
        return;
    }
    let at = START.get_or_init(Instant::now).elapsed().as_millis();
    for ch in s.chars() {
        let vk = match ch {
            'a'..='z' => (ch as u8) - b'a' + 0x41,
            '0'..='9' => (ch as u8) - b'0' + 0x30,
            ' ' => 0x20,
            _ => continue,
        };
        unsafe {
            super::keybd_event(vk, 0, 0, 0);
            super::keybd_event(vk, 0, KEYUP, 0);
        }
        nap(gap_ms);
    }
    let done = START.get_or_init(Instant::now).elapsed().as_millis();
    say(format!(
        "typed {s:?} as real keystrokes ({gap_ms}ms apart, injection {at}ms..{done}ms)"
    ));
}

/// How long after the last keystroke does the CONTROL show the text?
/// (Contract point 4: the verb blocks until the text has landed.)
fn settle(expect: &str) {
    let want = expect.to_owned();
    for turn in 0..400 {
        let now = on_ui(|core| Ok(core.entries[0].Text()?.to_string())).unwrap_or_default();
        if now == want {
            say(format!("settled on {want:?} after {turn} polls (1ms apart)"));
            return;
        }
        nap(1);
    }
    say(format!("NEVER settled on {want:?}"));
}

fn maybe_spawn_body() {
    // Let the guest mount and take focus.
    nap(1500);
    say("== the WinUI undo arm probe ==");
    attach_witness();
    snap("A0 start (the guest focuses entry#0 at mount)");

    // --- Q1: real keystrokes fill the native stack, one TextChanged each
    type_text("abc", 40);
    settle("abc");
    snap("A1 after typing abc");

    // --- Q2: the caret move the type verb owes (contract point 3) is not
    // an edit: it must not spend an undo step and must raise nothing.
    let r = on_ui(|core| {
        let f = core.entries[0].clone();
        let n = f.Text()?.to_string().chars().count() as i32;
        f.SetSelectionStart(n)?;
        f.SetSelectionLength(0)?;
        Ok(())
    });
    say(format!("caret to the end (SetSelectionStart/Length): {r:?}"));
    nap(150);
    snap("A2 after the caret move");

    // --- Q3: typing APPENDS after that caret move
    type_text("de", 40);
    settle("abcde");
    snap("A3 after typing de");

    // --- Q4 (§3a): does a NATIVE undo reach kaya's model here? The
    // routing's own call: Undo() with CORE borrowed, then the sample the
    // arm would take, then whatever the control raises afterwards.
    let sample = on_ui(|core| {
        let f = core.entries[0].clone();
        IN_UNDO.store(true, Relaxed);
        let called = f.Undo();
        let text = f.Text()?.to_string();
        let can = f.CanUndo()?;
        IN_UNDO.store(false, Relaxed);
        Ok(format!("Undo()={called:?} sample_text={text:?} sample_CanUndo={can}"))
    });
    say(format!("NATIVE UNDO, routed: {sample:?}"));
    nap(400);
    snap("A4 after the native undo (400ms later)");

    // A second walk backwards, to see the granularity of the coalescing.
    let sample = on_ui(|core| {
        let f = core.entries[0].clone();
        IN_UNDO.store(true, Relaxed);
        let called = f.Undo();
        let text = f.Text()?.to_string();
        let can = f.CanUndo()?;
        IN_UNDO.store(false, Relaxed);
        Ok(format!("Undo()={called:?} sample_text={text:?} sample_CanUndo={can}"))
    });
    say(format!("NATIVE UNDO #2: {sample:?}"));
    nap(400);
    snap("A5 after the second native undo");

    let sample = on_ui(|core| {
        let f = core.entries[0].clone();
        IN_UNDO.store(true, Relaxed);
        let called = f.Redo();
        let text = f.Text()?.to_string();
        let can = f.CanRedo()?;
        IN_UNDO.store(false, Relaxed);
        Ok(format!("Redo()={called:?} sample_text={text:?} sample_CanRedo={can}"))
    });
    say(format!("NATIVE REDO: {sample:?}"));
    nap(400);
    snap("A6 after the native redo");

    // --- Q5: what a PROGRAMMATIC Focus() does to the selection (macOS
    // selects the whole contents; the type verb's contract point 3 is
    // written for that divergence, so this lane's answer must be on the
    // record rather than assumed).
    let r = on_ui(|core| {
        // Move focus away first, so the Focus() below is a real change.
        let mut moved = false;
        for w in core.widgets.values() {
            if let super::NativeWidget::Button { button, .. } = w {
                moved = button.Focus(FocusState::Programmatic)?;
                break;
            }
        }
        Ok(moved)
    });
    say(format!("focus moved to a button: {r:?}"));
    nap(200);
    let r = on_ui(|core| {
        let f = core.entries[0].clone();
        let took = f.Focus(FocusState::Programmatic)?;
        Ok(format!(
            "took={took} sel=({},{}) text={:?}",
            f.SelectionStart()?,
            f.SelectionLength()?,
            f.Text()?.to_string()
        ))
    });
    say(format!("A7 refocus the entry programmatically: {r:?}"));
    nap(200);
    snap("A7 after the programmatic refocus");

    // --- Q6: D7 re-verified on this build — the arm's own SetProp path,
    // then the explicit ClearUndoRedoHistory that §1.1 measured a no-op.
    type_text("zz", 40);
    settle("abczz");
    snap("A8 after typing zz (a live user stack)");
    let r = on_ui(|core| {
        let id = core.entry_ids[0];
        let f = core.entries[0].clone();
        let before = f.CanUndo()?;
        if super::lf(f.Text()?.to_string()) != "PROG" {
            if let Some(swallow) = core.entry_swallow.get(&id) {
                swallow.fetch_add(1, Relaxed);
            }
            f.SetText(&HSTRING::from("PROG"))?;
        }
        let after_write = f.CanUndo()?;
        f.ClearUndoRedoHistory()?;
        let after_clear = f.CanUndo()?;
        Ok(format!(
            "CanUndo before={before} after_write={after_write} after_explicit_clear={after_clear}"
        ))
    });
    say(format!("A9 D7 (SetProp write + explicit clear): {r:?}"));
    nap(300);
    snap("A9 after the programmatic write");

    say("PROBEDONE");
    nap(500);
    std::process::exit(0);
}

pub(super) fn maybe_spawn() {
    if std::env::var_os("KAYA_UNDO_ARM_PROBE").is_none() {
        return;
    }
    START.get_or_init(Instant::now);
    std::thread::spawn(maybe_spawn_body);
}
