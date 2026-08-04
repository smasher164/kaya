//! THROWAWAY undo probe for the WinUI backend — docs/undo-plan.md §0,
//! probe plan cells P3-win, P4, P5. Measures; builds nothing.
//!
//! It is a MODULE OF THE BACKEND rather than a standalone app on
//! purpose: the questions are about the TextBox kaya itself creates,
//! with kaya's minimal template, written through kaya's own SetProp
//! path, under kaya's own thread-scoped chord hook. A standalone WinUI
//! app would have to re-create the composed Application (KayaOuter),
//! the MRT resources.pri and the minimal style, and would then be
//! measuring a different widget.
//!
//! Wiring (temporary, reverted after the run — see hook.patch):
//!   crates/kaya/src/winui/mod.rs
//!     #[path = "../../../../tools/win/undoprobe/probe.rs"] mod undoprobe;
//!     ... and `undoprobe::maybe_spawn();` at the end of `setup`.
//!
//! Everything it prints is prefixed PROBE with a millisecond stamp;
//! the guest's own observations print PROBEGUEST. The last line is
//! PROBEDONE.

// A probe keeps its unused instruments (right_click_area, call_redo):
// the next question asked of this file is not the last one answered.
#![allow(dead_code)]

use super::bindings::Microsoft::UI::Xaml::FocusState;
use super::{CORE, CoreState, DISPATCHER, DispatcherQueueHandler};
use std::io::Write as _;
use std::sync::atomic::Ordering::Relaxed;
use std::time::{Duration, Instant};
use windows_core::HSTRING;

static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

unsafe extern "system" {
    fn GetWindowThreadProcessId(hwnd: isize, pid: *mut u32) -> u32;
    fn GetCurrentProcessId() -> u32;
    fn ClientToScreen(hwnd: isize, pt: *mut ProbePoint) -> i32;
    fn SetCursorPos(x: i32, y: i32) -> i32;
    fn mouse_event(flags: u32, dx: i32, dy: i32, data: u32, extra: usize);
    fn GetWindowTextW(hwnd: isize, buf: *mut u16, len: i32) -> i32;
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct ProbePoint {
    x: i32,
    y: i32,
}

fn say(s: impl AsRef<str>) {
    let t = START.get_or_init(Instant::now).elapsed().as_millis();
    println!("PROBE {t:>6}ms {}", s.as_ref());
    let _ = std::io::stdout().flush();
}

fn nap(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

/// Run a closure on the UI thread with CORE borrowed, like the harness
/// stage's on_ui_mut — but never panicking: a probe that dies takes its
/// own measurement with it.
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
                    let _ = tx.send(f(core).map_err(|e| format!("{} ({:?})", e.message(), e.code())));
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

/// The same, without touching CORE (for calls that re-enter it).
fn on_ui_raw(f: impl FnOnce() + Send + 'static) {
    let Some(dispatcher) = DISPATCHER.get() else { return };
    let cell = std::sync::Mutex::new(Some(f));
    let handler = DispatcherQueueHandler::new(move || {
        if let Some(f) = cell.lock().unwrap().take() {
            f();
        }
        Ok(())
    });
    let _ = dispatcher.0.TryEnqueue(&handler);
}

// --- the reads -----------------------------------------------------------

fn snap(label: &str) -> String {
    let out = on_ui(|core| {
        let f = core.entries[0].clone();
        Ok(format!(
            "text={:?} CanUndo={} CanRedo={} focus={:?}",
            f.Text()?.to_string(),
            f.CanUndo()?,
            f.CanRedo()?,
            f.FocusState()?.0
        ))
    })
    .unwrap_or_else(|e| format!("<unreadable: {e}>"));
    say(format!("{label}: {out}"));
    out
}

/// The same read against the multi-line sibling.
fn snap_area(label: &str) {
    let out = on_ui(|core| {
        let f = core.textareas[0].clone();
        Ok(format!(
            "text={:?} CanUndo={} CanRedo={} focus={:?}",
            f.Text()?.to_string(),
            f.CanUndo()?,
            f.CanRedo()?,
            f.FocusState()?.0
        ))
    })
    .unwrap_or_else(|e| format!("<unreadable: {e}>"));
    say(format!("{label}: {out}"));
}

/// kaya's programmatic write against the TEXTAREA (the same SetProp arm).
fn kaya_write_area(text: &str) {
    let t = text.to_owned();
    let r = on_ui(move |core| {
        let id = core.textarea_ids[0];
        let f = core.textareas[0].clone();
        if super::lf(f.Text()?.to_string()) != t {
            if let Some(swallow) = core.entry_swallow.get(&id) {
                swallow.fetch_add(1, Relaxed);
            }
            f.SetText(&HSTRING::from(&t))?;
        }
        Ok(())
    });
    match r {
        Ok(()) => say(format!("kaya SetProp text write {text:?} on the TEXTAREA")),
        Err(e) => say(format!("kaya SetProp text write {text:?} on the TEXTAREA FAILED: {e}")),
    }
    nap(150);
}

fn focus_area() {
    let r = on_ui(|core| core.textareas[0].Focus(FocusState::Programmatic));
    say(format!("focus the textarea: {r:?}"));
    nap(150);
}

/// Move the focus to the scene's Button — a focusable widget that is
/// NOT a text control.
fn focus_button() {
    let r = on_ui(|core| {
        let mut took = None;
        for w in core.widgets.values() {
            if let super::NativeWidget::Button { button, .. } = w {
                took = Some(button.Focus(FocusState::Programmatic)?);
                break;
            }
        }
        let field = core.entries[0].FocusState()?.0;
        Ok(format!("button focus taken={took:?}, entry FocusState now {field:?}"))
    });
    say(format!("focus the button: {r:?}"));
    nap(200);
}

/// kaya's own programmatic write, byte for byte the SetProp arm
/// (winui/mod.rs: the swallow bump, then SetText).
fn kaya_write(text: &str) {
    let t = text.to_owned();
    let r = on_ui(move |core| {
        let id = core.entry_ids[0];
        let f = core.entries[0].clone();
        if super::lf(f.Text()?.to_string()) != t {
            if let Some(swallow) = core.entry_swallow.get(&id) {
                swallow.fetch_add(1, Relaxed);
            }
            f.SetText(&HSTRING::from(&t))?;
        }
        Ok(())
    });
    match r {
        Ok(()) => say(format!("kaya SetProp text write {text:?} (the SetProp arm's path)")),
        Err(e) => say(format!("kaya SetProp text write {text:?} FAILED: {e}")),
    }
    nap(150);
}

fn call_undo() {
    match on_ui(|core| core.entries[0].Undo()) {
        Ok(()) => say("TextBox.Undo() returned Ok"),
        Err(e) => say(format!("TextBox.Undo() FAILED: {e}")),
    }
    nap(150);
}

fn call_redo() {
    match on_ui(|core| core.entries[0].Redo()) {
        Ok(()) => say("TextBox.Redo() returned Ok"),
        Err(e) => say(format!("TextBox.Redo() FAILED: {e}")),
    }
    nap(150);
}

fn call_clear_history() {
    match on_ui(|core| core.entries[0].ClearUndoRedoHistory()) {
        Ok(()) => say("TextBox.ClearUndoRedoHistory() returned Ok"),
        Err(e) => say(format!("TextBox.ClearUndoRedoHistory() FAILED: {e}")),
    }
    nap(120);
}

fn focus_field() {
    let r = on_ui(|core| {
        let f = core.entries[0].clone();
        let took = f.Focus(FocusState::Programmatic)?;
        // Put the caret at the end, where typing appends.
        let n = f.Text()?.to_string().chars().count() as i32;
        f.SetSelectionStart(n)?;
        Ok(took)
    });
    say(format!("focus the entry: {r:?}"));
    nap(150);
}

// --- the real input ------------------------------------------------------

fn hwnd() -> isize {
    on_ui(|core| {
        let native: super::IWindowNative = windows_core::Interface::cast(&core.window)?;
        native.window_handle()
    })
    .unwrap_or(0)
}

/// The shortcut verb's own foregrounding routine, print-on-failure.
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

/// Real keystrokes on the system input queue — the only way to seed a
/// genuine user undo stack (the harness's `type` verb is a
/// programmatic SetText, which is the very thing under test).
fn type_text(s: &str) {
    if !foreground() {
        return;
    }
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
        nap(60);
    }
    nap(300);
    say(format!("typed {s:?} as real keystrokes"));
}

fn press(mods: &[u8], key: u8, what: &str) {
    if !foreground() {
        return;
    }
    unsafe {
        for &m in mods {
            super::keybd_event(m, 0, 0, 0);
        }
        super::keybd_event(key, 0, 0, 0);
        super::keybd_event(key, 0, KEYUP, 0);
        for &m in mods.iter().rev() {
            super::keybd_event(m, 0, KEYUP, 0);
        }
    }
    say(format!("pressed {what} (real keystroke)"));
    nap(600);
}

// --- popup inventory (P4) ------------------------------------------------

static POPUPS: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

unsafe extern "system" fn collect(h: isize, _l: isize) -> i32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(h, &mut pid) };
    if pid != unsafe { GetCurrentProcessId() } {
        return 1;
    }
    let mut cls = [0u16; 256];
    let n = unsafe { super::GetClassNameW(h, cls.as_mut_ptr(), 256) };
    let class = String::from_utf16_lossy(&cls[..n.max(0) as usize]);
    let mut title = [0u16; 256];
    let tn = unsafe { GetWindowTextW(h, title.as_mut_ptr(), 256) };
    let title = String::from_utf16_lossy(&title[..tn.max(0) as usize]);
    let visible = unsafe { super::IsWindowVisible(h) } != 0;
    let mut r = super::Rect::default();
    unsafe { super::GetWindowRect(h, &mut r) };
    POPUPS.lock().unwrap().push(format!(
        "hwnd={h:#x} class={class:?} title={title:?} visible={visible} rect=({},{})-({},{})",
        r.left, r.top, r.right, r.bottom
    ));
    1
}

fn windows_of_this_process(label: &str) {
    POPUPS.lock().unwrap().clear();
    unsafe { super::EnumWindows(Some(collect), 0) };
    let list = POPUPS.lock().unwrap().clone();
    say(format!("{label}: {} top-level window(s) in this process", list.len()));
    for l in list {
        say(format!("    {l}"));
    }
}

/// Screen capture through stock PowerShell, from this (non-UI) thread —
/// the same shape run_powershell uses for the clipboard's foreign half.
fn shot(name: &str) {
    let out = format!("C:\\kaya\\undoprobe\\shot-{name}.png");
    let script = format!(
        "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; \
         $b=[System.Windows.Forms.SystemInformation]::VirtualScreen; \
         $bmp=New-Object Drawing.Bitmap $b.Width,$b.Height; \
         $g=[Drawing.Graphics]::FromImage($bmp); \
         $g.CopyFromScreen($b.Left,$b.Top,0,0,$bmp.Size); \
         $bmp.Save('{out}',[Drawing.Imaging.ImageFormat]::Png); \
         Write-Output 'shot {name} ok'"
    );
    let r = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", &script])
        .output();
    match r {
        Ok(o) => say(format!(
            "screenshot {name}: {}",
            String::from_utf8_lossy(&o.stdout).trim()
        )),
        Err(e) => say(format!("screenshot {name} FAILED: {e}")),
    }
}

/// The AX dump: an OUT-OF-PROCESS UI Automation client walking every
/// top-level window of this process, so the context menu's items are
/// named rather than only pictured. Out of process deliberately —
/// crates/kaya/Cargo.toml records why an in-process UIA client is a
/// wall here.
fn uia_dump(label: &str) {
    let pid = unsafe { GetCurrentProcessId() };
    let r = std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "C:\\kaya\\undoprobe\\uia.ps1",
            &pid.to_string(),
        ])
        .output();
    match r {
        Ok(o) => {
            for line in String::from_utf8_lossy(&o.stdout).lines() {
                say(format!("uia[{label}] {line}"));
            }
            let err = String::from_utf8_lossy(&o.stderr);
            if !err.trim().is_empty() {
                say(format!("uia[{label}] STDERR {}", err.trim()));
            }
        }
        Err(e) => say(format!("uia[{label}] FAILED: {e}")),
    }
}

/// Right-click the TEXTAREA, which in this scene carries an
/// APP-declared kaya context menu (SetContextFlyout). If kaya's flyout
/// displaces the platform's TextCommandBarFlyout, the entry's
/// Paste/Undo/Select All is not what this field offers.
fn right_click_area() {
    let geom = on_ui(|core| {
        use windows_core::Interface as _;
        let f = core.textareas[0].clone();
        let w = f.ActualWidth()?;
        let h = f.ActualHeight()?;
        let el: super::UIElement = f.cast()?;
        let t = el.TransformToVisual(None::<&super::UIElement>)?;
        let p = t.TransformPoint(super::bindings::Windows::Foundation::Point {
            X: (w / 2.0) as f32,
            Y: (h / 2.0) as f32,
        })?;
        let scale = f.XamlRoot()?.RasterizationScale()?;
        Ok((p.X as f64, p.Y as f64, scale))
    });
    let Ok((x, y, scale)) = geom else {
        say(format!("right click (textarea): geometry unavailable: {geom:?}"));
        return;
    };
    let h_wnd = hwnd();
    let mut origin = ProbePoint::default();
    unsafe { ClientToScreen(h_wnd, &mut origin) };
    let sx = origin.x + (x * scale) as i32;
    let sy = origin.y + (y * scale) as i32;
    if !foreground() {
        return;
    }
    unsafe {
        SetCursorPos(sx, sy);
        nap(120);
        mouse_event(0x0002, 0, 0, 0, 0);
        mouse_event(0x0004, 0, 0, 0, 0);
        nap(250);
        mouse_event(0x0008, 0, 0, 0, 0);
        mouse_event(0x0010, 0, 0, 0, 0);
    }
    say(format!("right-clicked the TEXTAREA at screen ({sx},{sy})"));
    nap(900);
}

fn right_click_field() {
    // The field's centre in screen pixels: XAML DIPs through the
    // element's own transform, scaled by the XamlRoot, offset by the
    // window's client origin.
    let geom = on_ui(|core| {
        use windows_core::Interface as _;
        let f = core.entries[0].clone();
        let w = f.ActualWidth()?;
        let h = f.ActualHeight()?;
        let el: super::UIElement = f.cast()?;
        let t = el.TransformToVisual(None::<&super::UIElement>)?;
        let p = t.TransformPoint(super::bindings::Windows::Foundation::Point {
            X: (w / 2.0) as f32,
            Y: (h / 2.0) as f32,
        })?;
        let scale = f.XamlRoot()?.RasterizationScale()?;
        Ok((p.X as f64, p.Y as f64, scale, w, h))
    });
    let Ok((x, y, scale, w, h)) = geom else {
        say(format!("right click: geometry unavailable: {geom:?}"));
        return;
    };
    let h_wnd = hwnd();
    let mut origin = ProbePoint::default();
    unsafe { ClientToScreen(h_wnd, &mut origin) };
    let sx = origin.x + (x * scale) as i32;
    let sy = origin.y + (y * scale) as i32;
    say(format!(
        "entry is {w:.0}x{h:.0} DIP, centre at ({x:.0},{y:.0}) DIP, scale {scale}, \
         client origin ({},{}) -> screen ({sx},{sy})",
        origin.x, origin.y
    ));
    if !foreground() {
        return;
    }
    unsafe {
        SetCursorPos(sx, sy);
        nap(120);
        // left click first: focus the field the way a user would
        mouse_event(0x0002, 0, 0, 0, 0);
        mouse_event(0x0004, 0, 0, 0, 0);
        nap(250);
        mouse_event(0x0008, 0, 0, 0, 0);
        mouse_event(0x0010, 0, 0, 0, 0);
    }
    say("right-clicked the entry");
    nap(900);
}

fn dismiss_popup() {
    unsafe {
        super::keybd_event(0x1B, 0, 0, 0);
        super::keybd_event(0x1B, 0, 2, 0);
    }
    nap(400);
}

// --- the menu catalog (P5) ----------------------------------------------

fn take_shortcut(spelling: &str) -> Option<u64> {
    let s = spelling.to_owned();
    on_ui(move |core| Ok(core.menu_shortcuts.remove(&s))).unwrap_or(None)
}

fn put_shortcut(spelling: &str, id: u64) {
    let s = spelling.to_owned();
    let _ = on_ui(move |core| {
        core.menu_shortcuts.insert(s, id);
        Ok(())
    });
}

// --- the run -------------------------------------------------------------

pub(super) fn maybe_spawn() {
    if std::env::var("KAYA_UNDO_PROBE").is_err() {
        return;
    }
    START.get_or_init(Instant::now);
    std::thread::spawn(run);
}

fn run() {
    say("undo probe armed (P3-win / P4 / P5)");
    // Wait for the scene: the guest builds it through the ring.
    let mut ready = false;
    for _ in 0..100 {
        if let Ok(n) = on_ui(|core| Ok(core.entries.len())) {
            if n > 0 {
                ready = true;
                break;
            }
        }
        nap(100);
    }
    if !ready {
        say("no entry appeared in 10s — nothing to measure");
        println!("PROBEDONE");
        return;
    }
    let chord = on_ui(|core| Ok(core.menu_shortcuts.clone()));
    say(format!("catalog chords: {chord:?}"));

    // ---------------- P4a: the affordance, before any input -------------
    say("== P4: what undo affordance does the minimal TextBox template carry ==");
    let flyouts = on_ui(|core| {
        let f = core.entries[0].clone();
        let ctx = match f.ContextFlyout() {
            Ok(fb) => match windows_core::Interface::cast::<windows_core::IInspectable>(&fb) {
                Ok(i) => format!("{:?}", i.GetRuntimeClassName().map(|h| h.to_string())),
                Err(e) => format!("<uncastable: {}>", e.message()),
            },
            Err(e) => format!("<none: {} {:?}>", e.message(), e.code()),
        };
        let sel = match f.SelectionFlyout() {
            Ok(fb) => match windows_core::Interface::cast::<windows_core::IInspectable>(&fb) {
                Ok(i) => format!("{:?}", i.GetRuntimeClassName().map(|h| h.to_string())),
                Err(e) => format!("<uncastable: {}>", e.message()),
            },
            Err(e) => format!("<none: {} {:?}>", e.message(), e.code()),
        };
        Ok(format!("ContextFlyout={ctx} SelectionFlyout={sel}"))
    });
    say(format!("entry flyout properties: {flyouts:?}"));

    // ---------------- P3 phase A: the write on a pristine field ---------
    say("== P3 phase A: does kaya's programmatic write enter the native stack ==");
    snap("A0 pristine");
    kaya_write("alpha");
    snap("A1 after the app's write");
    call_undo();
    snap("A2 after Undo()");
    call_redo();
    snap("A3 after Redo()");

    // ---------------- P3 phase B: a real user edit under it -------------
    say("== P3 phase B: a REAL user edit, then an app write over it ==");
    kaya_write("");
    call_clear_history();
    snap("B0 cleared");
    focus_field();
    type_text("user");
    snap("B1 after the user typed");
    kaya_write("APPWRITE");
    snap("B2 after the app's write (NO clear yet)");
    call_undo();
    snap("B3 after one Undo()");
    call_undo();
    snap("B4 after a second Undo()");

    // ---------------- P3 phase C: D7's spelling -------------------------
    say("== P3 phase C: D7 — ClearUndoRedoHistory() after the app's write ==");
    kaya_write("");
    call_clear_history();
    focus_field();
    type_text("mine");
    snap("C0 user text");
    kaya_write("APPTWO");
    call_clear_history();
    snap("C1 app write + ClearUndoRedoHistory");
    call_undo();
    snap("C2 Undo() after the clear — D7 wants this UNCHANGED");
    focus_field();
    type_text("zz");
    snap("C3 new user text after the clear");
    call_undo();
    snap("C4 Undo() — D7 wants the new edit undone, and no further");
    call_undo();
    snap("C5 a second Undo() — must not reach the pre-write history");

    // ---------------- P4b: the affordance, driven ------------------------
    say("== P4: drive the context menu ==");
    windows_of_this_process("P4 before");
    right_click_field();
    windows_of_this_process("P4 after right-click");
    shot("rightclick");
    dismiss_popup();
    focus_field();
    press(&[0x10], 0x79, "shift+F10 (the keyboard context-menu route)");
    windows_of_this_process("P4 after shift+F10");
    shot("shiftf10");
    dismiss_popup();
    press(&[], 0x5D, "VK_APPS (the menu key)");
    windows_of_this_process("P4 after VK_APPS");
    shot("vkapps");
    dismiss_popup();

    // ---------------- P3 phase D: the multi-line sibling ----------------
    say("== P3 phase D: the TEXTAREA (same TextBox class, AcceptsReturn) ==");
    focus_area();
    type_text("note");
    snap_area("D0 user text in the textarea");
    kaya_write_area("APPAREA");
    snap_area("D1 after the app's write to the textarea");

    // ---------------- P3 phase E: kaya's OWN clipboard commands ---------
    // Edit>Cut and Edit>Paste reach the field through the platform's own
    // edit commands (perform_clipboard_role: CutSelectionToClipboard,
    // PasteFromClipboard). Whether THOSE land in the native undo stack
    // decides whether the two tiers stay coherent for a user who cuts
    // and then presses Undo.
    say("== P3 phase E: do kaya's clipboard commands enter the native stack ==");
    kaya_write("");
    call_clear_history();
    focus_field();
    type_text("wxyz");
    snap("E0 typed");
    let cut = on_ui(|core| {
        let f = core.entries[0].clone();
        f.SetSelectionStart(0)?;
        f.SetSelectionLength(4)?;
        f.CutSelectionToClipboard()?;
        Ok(())
    });
    say(format!("Edit>Cut's call, CutSelectionToClipboard: {cut:?}"));
    nap(200);
    snap("E1 after cut");
    call_undo();
    snap("E2 Undo() after cut");
    // The paste half needs the insertion to be VISIBLE: start from a
    // different, freshly cleared text with the caret at the end, so
    // "wxyz" arriving from the clipboard cannot be confused with what
    // was already there.
    kaya_write("ab");
    call_clear_history();
    focus_field();
    let caret = on_ui(|core| {
        let f = core.entries[0].clone();
        f.SetSelectionStart(2)?;
        f.SetSelectionLength(0)?;
        Ok(())
    });
    say(format!("caret to the end of \"ab\": {caret:?}"));
    let paste = on_ui(|core| core.entries[0].PasteFromClipboard());
    say(format!("Edit>Paste's call, PasteFromClipboard: {paste:?}"));
    nap(400);
    snap("E3 after paste (expect \"abwxyz\")");
    call_undo();
    snap("E4 Undo() after paste (expect \"ab\" if the paste is one native step)");

    // ---------------- P5: the Ctrl+Z collision ---------------------------
    say("== P5: Ctrl+Z with a kaya Edit>Undo chord registered ==");
    kaya_write("");
    call_clear_history();
    focus_field();
    type_text("abc");
    snap("P5a seed");
    // P5a: the chord is NOT in kaya's table, so the WH_KEYBOARD hook
    // passes it through — the platform's own routing decides between
    // the TextBox and the KeyboardAccelerator XAML still carries.
    let owner = take_shortcut("primary+z");
    say(format!(
        "removed primary+z from core.menu_shortcuts (was {owner:?}) — the hook \
         will pass the chord to XAML"
    ));
    press(&[0x11], 0x5A, "ctrl+z with the hook NOT owning the chord");
    snap("P5a after ctrl+z (hook passes through)");
    press(&[0x11], 0x59, "ctrl+y — does the TextBox own redo too");
    snap("P5a after ctrl+y");

    // P5d: the CONTROL for P5a. Same chord, same pass-through, but the
    // focus is on a Button — if the accelerator fires here and not
    // there, the TextBox is what suppresses it.
    focus_button();
    press(&[0x11], 0x5A, "ctrl+z with focus on the BUTTON, hook not owning it");
    snap("P5d after ctrl+z with the button focused");

    // P5b: the chord back in the table — kaya as it would actually ship.
    if let Some(id) = owner {
        put_shortcut("primary+z", id);
        say("restored primary+z in core.menu_shortcuts — the hook owns the chord again");
    }
    focus_field();
    type_text("def");
    snap("P5b seed");
    press(&[0x11], 0x5A, "ctrl+z with the hook OWNING the chord");
    snap("P5b after ctrl+z (hook owns it)");

    focus_button();
    press(&[0x11], 0x5A, "ctrl+z with the button focused and the hook owning it");
    snap("P5e after ctrl+z with the button focused");

    // P5f: the DISABLED item. The hook eats a chord its catalog owns
    // whether or not the item is enabled ("a disabled item is INERT ...
    // the chord is still this catalog's, so it is eaten"). If that
    // holds, disabling Edit>Undo is NOT a way to hand Ctrl+Z back to
    // the focused TextBox.
    let disabled = on_ui(|core| {
        let id = *core.menu_shortcuts.get("primary+z").expect("the probe's chord");
        if let Some(m) = core.menu_models.get_mut(&id) {
            m.enabled = false;
        }
        if let Some(super::MenuNative::Action(item)) =
            core.menu_natives.get(&(super::MenuAttachment::Window(0), id))
        {
            item.SetIsEnabled(false)?;
        }
        Ok(id)
    });
    say(format!("disabled Edit>Undo in the model and the chrome: {disabled:?}"));
    focus_field();
    type_text("gh");
    snap("P5f seed with Edit>Undo DISABLED");
    press(&[0x11], 0x5A, "ctrl+z with the chord owned by a DISABLED item");
    snap("P5f after ctrl+z (a disabled owner still eats the chord?)");

    // ------------- P4 again, with something to undo ---------------------
    // The first pass caught the flyout in a CanUndo=false state. Ask the
    // question the cell actually asks: with undoable content in the
    // field, does the menu offer Undo?
    say("== P4 (second pass): the flyout with undoable content ==");
    kaya_write("");
    call_clear_history();
    focus_field();
    type_text("hello");
    snap("P4b seed (CanUndo must be true for the menu to offer Undo)");
    right_click_field();
    shot("undo-available");
    uia_dump("context menu with undoable content");
    dismiss_popup();

    // (No third pass for an APP-declared context menu on a text
    // widget: the root REFUSES the attachment outright —
    // scene.rs:1435, measured here as a guest panic — so a kaya
    // context menu can never displace the flyout above.)
    say("== P4: an app context menu on a text widget is refused at the root (scene.rs:1435) ==");

    say("probe complete");
    println!("PROBEDONE");
    let _ = std::io::stdout().flush();
    nap(500);
    on_ui_raw(|| super::request_exit(0));
}
