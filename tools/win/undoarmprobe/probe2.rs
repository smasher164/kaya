//! THROWAWAY probe #2 for the WinUI undo arm — the two claims the
//! byte-frozen scene CANNOT reach: the CHORD (no scene presses one) and
//! A1's CLEAR (the scene passes with or without it on this lane).
//! docs/undo-plan.md §1.1.
//!
//! Wiring (temporary, reverted after the run):
//!   crates/kaya/src/winui/mod.rs
//!     #[path = "../../../../tools/win/undoarmprobe/probe2.rs"] mod undoarmprobe;
//!     ... and `undoarmprobe::maybe_spawn();` at the end of `setup`.

#![allow(dead_code)]

use super::{CORE, CoreState, DISPATCHER, DispatcherQueueHandler};
use std::io::Write as _;
use std::time::{Duration, Instant};

static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

fn say(s: impl AsRef<str>) {
    let t = START.get_or_init(Instant::now).elapsed().as_millis();
    println!("PROBE {t:>6}ms {}", s.as_ref());
    let _ = std::io::stdout().flush();
}

fn nap(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

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

fn snap(label: &str) -> String {
    let out = on_ui(|core| {
        let f = core.entries[0].clone();
        Ok(format!(
            "text={:?} CanUndo={} CanRedo={} status={:?} history={:?}",
            f.Text()?.to_string(),
            f.CanUndo()?,
            f.CanRedo()?,
            core.labels[0].Text()?.to_string(),
            core.labels[1].Text()?.to_string(),
        ))
    })
    .unwrap_or_else(|e| format!("<unreadable: {e}>"));
    say(format!("{label}: {out}"));
    out
}

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
    say("foreground: FAILED in 3s");
    false
}

const KEYUP: u32 = 0x2;

fn type_text(s: &str) {
    if !foreground() {
        return;
    }
    for ch in s.chars() {
        let vk = match ch {
            'a'..='z' => (ch as u8) - b'a' + 0x41,
            _ => continue,
        };
        unsafe {
            super::keybd_event(vk, 0, 0, 0);
            super::keybd_event(vk, 0, KEYUP, 0);
        }
        nap(40);
    }
    nap(250);
    say(format!("typed {s:?} as real keystrokes"));
}

/// A REAL Ctrl+Z on the system input queue — the key kaya's hook watches.
fn press_undo_chord(shift: bool) {
    if !foreground() {
        return;
    }
    unsafe {
        super::keybd_event(0x11, 0, 0, 0); // VK_CONTROL
        if shift {
            super::keybd_event(0x10, 0, 0, 0);
        }
        super::keybd_event(0x5A, 0, 0, 0); // Z
        super::keybd_event(0x5A, 0, KEYUP, 0);
        if shift {
            super::keybd_event(0x10, 0, KEYUP, 0);
        }
        super::keybd_event(0x11, 0, KEYUP, 0);
    }
    say(format!(
        "pressed REAL {}Ctrl+Z",
        if shift { "Shift+" } else { "" }
    ));
    nap(500);
}

fn body() {
    nap(1500);
    say("== the WinUI undo arm probe #2: the chord, and A1's clear ==");
    snap("B0 start");

    // --- A1: a core group commits with the field focused -> the field's
    // native history goes with it.
    type_text("tea");
    snap("B1 after typing tea (a live native stack)");
    let r = on_ui(|core| {
        // The star button is button#1 in the undo guest; clicking it is
        // what the scene does, and it commits an undoable GROUP.
        let tag = core.buttons[1].clone();
        core.occurrences.send_click_tag(&tag);
        Ok(())
    });
    say(format!("clicked the star button (an undoable group): {r:?}"));
    nap(600);
    snap("B2 after the group committed — CanUndo IS A1's VERDICT");

    // --- the chord: install primary+z into the live catalog table the
    // hook consults, exactly as an app declaring `.shortcut("primary+z")`
    // would have done at build time.
    type_text("s");
    snap("B3 after typing s (a new episode, empty native stack under it)");
    let r = on_ui(|core| {
        let item = core
            .menu_models
            .iter()
            .find(|(_, m)| m.role == "undo")
            .map(|(&id, _)| id);
        let redo = core
            .menu_models
            .iter()
            .find(|(_, m)| m.role == "redo")
            .map(|(&id, _)| id);
        if let Some(item) = item {
            core.menu_shortcuts.insert("primary+z".to_owned(), item);
        }
        if let Some(redo) = redo {
            core.menu_shortcuts.insert("primary+shift+z".to_owned(), redo);
        }
        Ok(format!("undo item={item:?} redo item={redo:?}"))
    });
    say(format!("installed primary+z in the catalog: {r:?}"));

    // 1. The NATIVE tier through the chord. The hook owns the key now,
    //    so the TextBox never sees it (§1.1 P5b) — anything that happens
    //    to the text is kaya's routing, not the control's.
    press_undo_chord(false);
    snap("B4 after the FIRST real Ctrl+Z (expect the typing walked back)");

    // 2. The CORE tier through the same chord — the decisive one: no
    //    TextBox undo can move a status label.
    press_undo_chord(false);
    snap("B5 after the SECOND real Ctrl+Z (expect the star group undone)");

    // 3. And forward again.
    press_undo_chord(true);
    snap("B6 after a real Shift+Ctrl+Z (expect the star group redone)");

    say("PROBEDONE");
    nap(500);
    std::process::exit(0);
}

pub(super) fn maybe_spawn() {
    if std::env::var_os("KAYA_UNDO_ARM_PROBE").is_none() {
        return;
    }
    START.get_or_init(Instant::now);
    std::thread::spawn(body);
}
