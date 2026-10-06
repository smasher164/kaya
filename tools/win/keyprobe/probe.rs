//! THROWAWAY in-process keystroke probe for the WinUI backend
//! (tools/win/keyprobe/README.md). A MODULE OF THE BACKEND, not a standalone
//! app: the question is whether a keystroke POSTED to this process's own
//! island HWND traverses the XAML keyboard path the system queue's does —
//! into kaya's own TextBox, RichEditBox and NumberBox, through kaya's own
//! doors (submit_on_enter, the number field's commit, the search field's
//! Escape, the thread-scoped chord hook) — while ANOTHER guest holds the
//! foreground.
//!
//! Wiring (temporary, reverted after the run — tools/win/keyprobe/hook.patch):
//!   crates/kaya/src/winui/mod.rs
//!     #[path = "../../../../tools/win/keyprobe/probe.rs"] mod keyprobe;
//!     ... and `keyprobe::maybe_spawn();` at the end of `setup`.
//!
//! Two roles, one exe, one guest (tools/win/keyprobe/guest.rs):
//!   KAYA_KEY_PROBE=witness  takes the foreground, focuses its own entry and
//!                           idles, counting every key event and text change
//!                           that reaches it — the "foreground received
//!                           nothing" half of the verdict.
//!   KAYA_KEY_PROBE=driver   waits for the witness, refuses to measure while
//!                           it is itself the foreground window, then posts
//!                           keystrokes to its own HWNDs and reads what
//!                           landed, which doors fired, and whether the
//!                           native undo stack filled.

// A probe keeps its unused instruments.
#![allow(dead_code)]

use super::bindings::Microsoft::UI::Xaml::Input::KeyEventHandler;
use super::bindings::Microsoft::UI::Xaml::{FocusState, UIElement};
use super::{CoreState, DispatcherQueueHandler, Editable, CORE, DISPATCHER};
use std::io::Write as _;
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};
use std::time::{Duration, Instant};
use windows_core::HSTRING;

static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
static ROLE: std::sync::OnceLock<String> = std::sync::OnceLock::new();

const DIR: &str = r"C:\kaya\keyprobe";
const WITNESS_READY: &str = r"C:\kaya\keyprobe\witness-ready.txt";
const DRIVER_DONE: &str = r"C:\kaya\keyprobe\driver-done.txt";

const WM_KEYDOWN: u32 = 0x0100;
const WM_KEYUP: u32 = 0x0101;
const WM_CHAR: u32 = 0x0102;
const VK_SHIFT: usize = 0x10;
const VK_CONTROL: usize = 0x11;
const VK_RETURN: usize = 0x0D;
const VK_TAB: usize = 0x09;
const VK_ESCAPE: usize = 0x1B;
const INPUT_SITE_CLASS: &str = "InputSiteWindowClass";

// Declared here rather than reached through the backend's own blocks, so the
// probe compiles whatever `cfg` the backend puts on its declarations.
#[link(name = "user32")]
unsafe extern "system" {
    fn GetFocus() -> isize;
    fn GetForegroundWindow() -> isize;
    fn SetForegroundWindow(hwnd: isize) -> i32;
    fn BringWindowToTop(hwnd: isize) -> i32;
    fn SetFocus(hwnd: isize) -> isize;
    fn AttachThreadInput(attach: u32, attach_to: u32, join: i32) -> i32;
    fn GetWindowThreadProcessId(hwnd: isize, pid: *mut u32) -> u32;
    fn GetClassNameW(hwnd: isize, buf: *mut u16, len: i32) -> i32;
    fn GetParent(hwnd: isize) -> isize;
    fn EnumChildWindows(
        parent: isize,
        callback: Option<unsafe extern "system" fn(isize, isize) -> i32>,
        param: isize,
    ) -> i32;
    fn PostMessageW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> i32;
    fn SendMessageW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> isize;
    fn MapVirtualKeyW(code: u32, map: u32) -> u32;
    fn VkKeyScanW(ch: u16) -> i16;
    fn GetKeyboardState(state: *mut u8) -> i32;
    fn SetKeyboardState(state: *const u8) -> i32;
    fn IsWindowVisible(hwnd: isize) -> i32;
    fn keybd_event(vk: u8, scan: u8, flags: u32, extra: usize);
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentThreadId() -> u32;
    fn GetCurrentProcessId() -> u32;
}

fn say(s: impl AsRef<str>) {
    let t = START.get_or_init(Instant::now).elapsed().as_millis();
    let role = ROLE.get().map(String::as_str).unwrap_or("?");
    println!("PROBE {role} {t:>6}ms {}", s.as_ref());
    let _ = std::io::stdout().flush();
}

fn nap(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

/// Run a closure on the UI thread with CORE borrowed — the harness stage's
/// on_ui_mut, never panicking: a probe that dies takes its measurement
/// with it.
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
    dispatcher.0.TryEnqueue(&handler).map_err(|e| e.message().to_string())?;
    match rx.recv_timeout(Duration::from_secs(20)) {
        Ok(v) => v,
        Err(_) => Err("UI thread did not answer in 20s".to_owned()),
    }
}

/// The same without CORE, blocking until it ran — for the key-state table,
/// which is PER THREAD and must be written on the thread that will read it
/// (GetKeyState in submit_on_enter and key_hook runs on the UI thread).
fn on_ui_raw<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Result<T, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    let Some(dispatcher) = DISPATCHER.get() else {
        return Err("no dispatcher yet".to_owned());
    };
    let cell = std::sync::Mutex::new(Some((f, tx)));
    let handler = DispatcherQueueHandler::new(move || {
        if let Some((f, tx)) = cell.lock().unwrap().take() {
            let _ = tx.send(f());
        }
        Ok(())
    });
    dispatcher.0.TryEnqueue(&handler).map_err(|e| e.message().to_string())?;
    rx.recv_timeout(Duration::from_secs(20))
        .map_err(|_| "UI thread did not answer in 20s".to_owned())
}

// --- the window census ----------------------------------------------------

fn class_of(h: isize) -> String {
    let mut buf = [0u16; 256];
    let n = unsafe { GetClassNameW(h, buf.as_mut_ptr(), 256) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn pid_of(h: isize) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(h, &mut pid) };
    pid
}

static KIDS: std::sync::Mutex<Vec<isize>> = std::sync::Mutex::new(Vec::new());

unsafe extern "system" fn collect(h: isize, _l: isize) -> i32 {
    KIDS.lock().unwrap().push(h);
    1
}

/// Every descendant of the top-level window (EnumChildWindows recurses).
fn descendants(top: isize) -> Vec<isize> {
    KIDS.lock().unwrap().clear();
    unsafe { EnumChildWindows(top, Some(collect), 0) };
    KIDS.lock().unwrap().clone()
}

fn hwnd() -> isize {
    on_ui(|core| {
        let native: super::IWindowNative = windows_core::Interface::cast(&core.window)?;
        native.window_handle()
    })
    .unwrap_or(0)
}

fn find_class(top: isize, class: &str) -> isize {
    descendants(top).into_iter().find(|&h| class_of(h) == class).unwrap_or(0)
}

fn census(top: isize) {
    say(format!("top-level {top:#x} class {:?} visible={}", class_of(top), unsafe {
        IsWindowVisible(top)
    }));
    for h in descendants(top) {
        say(format!(
            "  child {h:#x} class {:?} parent {:#x}",
            class_of(h),
            unsafe { GetParent(h) }
        ));
    }
}

/// What the system says is the foreground, as the driver's own evidence that
/// it was NOT it: class, and whether the pid is this process's.
fn foreground_report(me: isize) -> String {
    let fg = unsafe { GetForegroundWindow() };
    let mine = pid_of(fg) == unsafe { GetCurrentProcessId() };
    format!(
        "foreground={fg:#x} class={:?} {}",
        class_of(fg),
        if fg == me { "SELF" } else if mine { "this process (not the top-level)" } else { "another process" }
    )
}

/// The thread's own focus window, read ON THE UI THREAD (GetFocus is per
/// queue, so a read from the probe thread would answer for the wrong queue).
fn ui_focus() -> String {
    match on_ui_raw(|| unsafe { GetFocus() }) {
        Ok(0) => "GetFocus()=NULL".to_owned(),
        Ok(h) => format!("GetFocus()={h:#x} class {:?}", class_of(h)),
        Err(e) => format!("GetFocus() unreadable: {e}"),
    }
}

// --- the counters ---------------------------------------------------------

static PREVIEW: AtomicUsize = AtomicUsize::new(0);
static KEYUP: AtomicUsize = AtomicUsize::new(0);
static LAST_KEY: AtomicUsize = AtomicUsize::new(0);

/// PreviewKeyDown and KeyUp on the window's content: the tunnelling
/// preview reaches the root BEFORE the TextBox, so a key the TextBox then
/// consumes is still counted. (CharacterReceived is not counted: a TextBox
/// eats it before any app handler, microsoft-ui-xaml #4256.)
fn install_counters() {
    let r = on_ui(|core| {
        let root: UIElement = core.window.Content()?;
        root.PreviewKeyDown(&KeyEventHandler::new(|_, args| {
            if let Some(args) = args.as_ref() {
                LAST_KEY.store(args.Key()?.0 as usize, Relaxed);
            }
            PREVIEW.fetch_add(1, Relaxed);
            Ok(())
        }))?;
        root.KeyUp(&KeyEventHandler::new(|_, _| {
            KEYUP.fetch_add(1, Relaxed);
            Ok(())
        }))?;
        Ok(())
    });
    say(format!("counters on the window content: {r:?}"));
}

fn counters() -> String {
    format!(
        "preview={} keyup={} last_key={:#x}",
        PREVIEW.load(Relaxed),
        KEYUP.load(Relaxed),
        LAST_KEY.load(Relaxed)
    )
}

// --- reads ----------------------------------------------------------------

fn label(i: usize) -> String {
    on_ui(move |core| Ok(core.labels[i].Text()?.to_string())).unwrap_or_else(|e| format!("<unreadable: {e}>"))
}

fn entry_text(i: usize) -> String {
    on_ui(move |core| Ok(core.entries[i].Text()?.to_string())).unwrap_or_else(|e| format!("<unreadable: {e}>"))
}

fn search_text() -> String {
    on_ui(|core| Ok(core.searches[0].Text()?.to_string())).unwrap_or_else(|e| format!("<unreadable: {e}>"))
}

fn area_text() -> String {
    on_ui(|core| Ok(super::lf(Editable::Textarea(core.textareas[0].clone()).text()?)))
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
}

fn number_text() -> String {
    on_ui(|core| {
        Ok(match super::number_input(&core.number_fields[0])? {
            Ok(input) => format!("text={:?} value={}", input.Text()?.to_string(), core.number_fields[0].Value()?),
            Err(why) => why,
        })
    })
    .unwrap_or_else(|e| format!("<unreadable: {e}>"))
}

fn entry_focus(i: usize) -> String {
    on_ui(move |core| Ok(format!("{:?}", core.entries[i].FocusState()?.0))).unwrap_or_else(|e| e)
}

fn snap(what: &str) {
    say(format!(
        "{what}: entry={:?} CanUndo={} area={:?} search={:?} number[{}] labels[{:?} {:?} {:?} {:?}] {}",
        entry_text(0),
        on_ui(|core| core.entries[0].CanUndo()).map(|b| b.to_string()).unwrap_or_else(|e| e),
        area_text(),
        search_text(),
        number_text(),
        label(0),
        label(1),
        label(2),
        label(3),
        counters(),
    ));
}

fn wait_until(ms: u64, mut pred: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_millis(ms);
    loop {
        if pred() {
            return true;
        }
        if Instant::now() > deadline {
            return false;
        }
        nap(25);
    }
}

// --- focus and resets -----------------------------------------------------

fn focus_entry(i: usize) {
    let r = on_ui(move |core| {
        let f = core.entries[i].clone();
        let took = f.Focus(FocusState::Programmatic)?;
        let n = f.Text()?.to_string().encode_utf16().count() as i32;
        Editable::Entry(f).set_caret(n)?;
        Ok(took)
    });
    say(format!("focus entries[{i}]: {r:?}; {}", ui_focus()));
    nap(150);
}

fn focus_search() {
    let r = on_ui(|core| {
        let f = core.searches[0].clone();
        let took = f.Focus(FocusState::Programmatic)?;
        let n = f.Text()?.to_string().encode_utf16().count() as i32;
        Editable::Entry(f).set_caret(n)?;
        Ok(took)
    });
    say(format!("focus searches[0]: {r:?}; {}", ui_focus()));
    nap(150);
}

fn focus_area() {
    let r = on_ui(|core| {
        let f = core.textareas[0].clone();
        let took = f.Focus(FocusState::Programmatic)?;
        let n = Editable::Textarea(f.clone()).text()?.encode_utf16().count() as i32;
        Editable::Textarea(f).set_caret(n)?;
        Ok(took)
    });
    say(format!("focus textareas[0]: {r:?}; {}", ui_focus()));
    nap(150);
}

fn focus_number() {
    let r = on_ui(|core| {
        let input = match super::number_input(&core.number_fields[0])? {
            Ok(input) => input,
            Err(why) => return Ok(format!("no input box: {why}")),
        };
        let took = input.Focus(FocusState::Programmatic)?;
        let n = input.Text()?.to_string().encode_utf16().count() as i32;
        Editable::Entry(input).set_caret(n)?;
        Ok(format!("{took}"))
    });
    say(format!("focus number_fields[0]'s input: {r:?}; {}", ui_focus()));
    nap(150);
}

/// Empty the entry THROUGH the app's own path (SetText, the SetProp arm) and
/// drop its history, so every route starts from the same nothing.
fn reset_entry() {
    let r = on_ui(|core| {
        let f = core.entries[0].clone();
        f.SetText(&HSTRING::new())?;
        f.ClearUndoRedoHistory()?;
        Ok(())
    });
    if let Err(e) = r {
        say(format!("reset entry FAILED: {e}"));
    }
    nap(100);
    focus_entry(0);
}

// --- the key-state table --------------------------------------------------

/// Hold a modifier down in the UI THREAD's key-state table — the table
/// GetKeyState reads on that thread — the way ArkDeck's UI tests do it from
/// outside (GetKeyboardState, set the high bit, SetKeyboardState). A posted
/// message carries no modifier state of its own.
fn modifier(vk: usize, down: bool) {
    let r = on_ui_raw(move || unsafe {
        let mut state = [0u8; 256];
        GetKeyboardState(state.as_mut_ptr());
        state[vk] = if down { 0x80 } else { 0 };
        SetKeyboardState(state.as_ptr())
    });
    say(format!("key table vk {vk:#x} {}: {r:?}", if down { "DOWN" } else { "up" }));
}

// --- the deliveries -------------------------------------------------------

#[derive(Clone, Copy, Debug)]
enum Shape {
    /// WM_KEYDOWN + WM_KEYUP; the character, if any, is the island's own
    /// TranslateMessage's to make.
    KeysOnly,
    /// WM_KEYDOWN + WM_CHAR + WM_KEYUP, the shape a real keystroke leaves
    /// in the queue after translation.
    KeysAndChar,
    /// WM_CHAR alone.
    CharOnly,
}

#[derive(Clone, Copy, Debug)]
enum Dest {
    /// `InputSiteWindowClass`, the grandchild four other projects post to.
    Site,
    /// `GetFocus()` on the UI thread, arrow_step's own target; skipped when NULL.
    Focus,
    /// `Microsoft.UI.Content.DesktopChildSiteBridge`, the island's child.
    Bridge,
    /// The top-level `WinUIDesktopWin32WindowClass`.
    Top,
}

fn dest_hwnd(top: isize, dest: Dest) -> isize {
    match dest {
        Dest::Site => find_class(top, INPUT_SITE_CLASS),
        Dest::Focus => on_ui_raw(|| unsafe { GetFocus() }).unwrap_or(0),
        Dest::Bridge => find_class(top, super::ISLAND_CLASS),
        Dest::Top => top,
    }
}

fn lparam_down(vk: usize) -> isize {
    let scan = unsafe { MapVirtualKeyW(vk as u32, 0) } as isize;
    1 | (scan << 16)
}

fn lparam_up(vk: usize) -> isize {
    lparam_down(vk) | (3 << 30)
}

fn post(h: isize, msg: u32, w: usize, l: isize, send: bool) {
    unsafe {
        if send {
            SendMessageW(h, msg, w, l);
        } else {
            PostMessageW(h, msg, w, l);
        }
    }
}

/// One virtual key down and up. `send` chooses SendMessage over PostMessage.
fn key(h: isize, vk: usize, shape: Shape, ch: Option<char>, send: bool) {
    match shape {
        Shape::KeysOnly => {
            post(h, WM_KEYDOWN, vk, lparam_down(vk), send);
            post(h, WM_KEYUP, vk, lparam_up(vk), send);
        }
        Shape::KeysAndChar => {
            post(h, WM_KEYDOWN, vk, lparam_down(vk), send);
            if let Some(ch) = ch {
                post(h, WM_CHAR, ch as usize, lparam_down(vk), send);
            }
            post(h, WM_KEYUP, vk, lparam_up(vk), send);
        }
        Shape::CharOnly => {
            if let Some(ch) = ch {
                post(h, WM_CHAR, ch as usize, lparam_down(vk), send);
            }
        }
    }
}

/// Printable ASCII through the active layout (VkKeyScanW), as type_text
/// does; a character the layout needs Shift for holds Shift in the UI
/// thread's table around its keys (KeysOnly is the shape that needs it —
/// WM_CHAR carries the final character).
fn type_text(h: isize, text: &str, shape: Shape, send: bool) {
    for ch in text.chars() {
        let scan = unsafe { VkKeyScanW(ch as u16) };
        let (vk, shift) = if scan == -1 { (0usize, false) } else { ((scan & 0xff) as usize, (scan >> 8) & 1 != 0) };
        let hold = shift && matches!(shape, Shape::KeysOnly);
        if hold {
            modifier(VK_SHIFT, true);
        }
        key(h, vk, shape, Some(ch), send);
        if hold {
            nap(150);
            modifier(VK_SHIFT, false);
        }
        nap(20);
    }
}

fn press_return(h: isize, with_char: bool) {
    key(h, VK_RETURN, if with_char { Shape::KeysAndChar } else { Shape::KeysOnly }, Some('\r'), false);
}

// --- the foreground (the witness's half) ----------------------------------

/// The harness's own dance, print-on-failure: SetForegroundWindow, then the
/// AttachThreadInput bypass, ESC at 10, the ALT tap at 50.
fn take_foreground(h: isize) -> bool {
    for attempt in 0..150 {
        if unsafe { GetForegroundWindow() } == h {
            return true;
        }
        unsafe { SetForegroundWindow(h) };
        if unsafe { GetForegroundWindow() } == h {
            return true;
        }
        let fg = unsafe { GetForegroundWindow() };
        if fg != 0 {
            let holder = unsafe { GetWindowThreadProcessId(fg, std::ptr::null_mut()) };
            let mine = unsafe { GetCurrentThreadId() };
            if holder != 0 && holder != mine {
                unsafe {
                    if AttachThreadInput(mine, holder, 1) != 0 {
                        SetForegroundWindow(h);
                        BringWindowToTop(h);
                        SetFocus(h);
                        AttachThreadInput(mine, holder, 0);
                    }
                }
            }
        }
        if attempt == 10 {
            unsafe {
                keybd_event(0x1B, 0, 0, 0);
                keybd_event(0x1B, 0, 2, 0);
            }
        }
        if attempt == 50 {
            unsafe {
                keybd_event(0x12, 0, 0, 0);
                keybd_event(0x12, 0, 2, 0);
            }
        }
        nap(20);
    }
    false
}

// --- the entry ------------------------------------------------------------

pub(super) fn maybe_spawn() {
    let Ok(role) = std::env::var("KAYA_KEY_PROBE") else {
        return;
    };
    START.get_or_init(Instant::now);
    let _ = ROLE.set(role.clone());
    match role.as_str() {
        "driver" => {
            std::thread::spawn(driver);
        }
        "witness" => {
            std::thread::spawn(witness);
        }
        other => {
            say(format!("KAYA_KEY_PROBE={other:?} names no role (driver|witness)"));
            println!("PROBEDONE");
        }
    }
}

/// The scene is built through the ring; wait for the guest's widgets.
fn wait_scene() -> bool {
    for _ in 0..100 {
        if let Ok(ready) = on_ui(|core| {
            Ok(core.entries.len() >= 2
                && core.labels.len() >= 4
                && !core.searches.is_empty()
                && !core.textareas.is_empty()
                && !core.number_fields.is_empty())
        }) {
            if ready {
                return true;
            }
        }
        nap(100);
    }
    false
}

fn witness() {
    say("witness armed");
    if !wait_scene() {
        say("the scene never came up in 10s — nothing to witness");
        println!("PROBEDONE");
        return;
    }
    let me = hwnd();
    census(me);
    install_counters();
    let _ = wait_until(20_000, || unsafe { IsWindowVisible(me) } != 0);
    let took = take_foreground(me);
    say(format!("took the foreground: {took}; {}", foreground_report(me)));
    focus_entry(0);
    say(format!("idle with entries[0] focused; {}", ui_focus()));
    snap("W0");
    if let Err(e) = std::fs::write(WITNESS_READY, "ready\r\n") {
        say(format!("could not write {WITNESS_READY}: {e}"));
    }
    let mut lost_foreground = 0usize;
    let mut last = String::new();
    let deadline = Instant::now() + Duration::from_secs(240);
    while Instant::now() < deadline {
        if unsafe { GetForegroundWindow() } != me {
            lost_foreground += 1;
        }
        let now = format!(
            "fg_self={} {} entry={:?} {} {}",
            unsafe { GetForegroundWindow() } == me,
            counters(),
            entry_text(0),
            label(2),
            label(0)
        );
        if now != last {
            say(format!("W {now}"));
            last = now;
        }
        if std::path::Path::new(DRIVER_DONE).exists() {
            break;
        }
        nap(250);
    }
    snap("W1 final");
    say(format!(
        "WITNESS VERDICT strays: {} entry={:?} {} {} ; samples_without_foreground={lost_foreground} \
         (a PreviewKeyDown above 0, a non-empty entry or a `changed` above 0 means a key \
         posted by the driver reached the FOREGROUND window)",
        counters(),
        entry_text(0),
        label(2),
        label(0)
    ));
    println!("PROBEDONE");
}

fn driver() {
    say("driver armed");
    if !wait_scene() {
        say("the scene never came up in 10s — nothing to measure");
        println!("PROBEDONE");
        return;
    }
    let me = hwnd();
    census(me);
    install_counters();
    let _ = wait_until(20_000, || unsafe { IsWindowVisible(me) } != 0);

    say("waiting for the witness to hold the foreground");
    let witness_up = wait_until(60_000, || std::path::Path::new(WITNESS_READY).exists());
    say(format!("witness ready: {witness_up}; {}", foreground_report(me)));
    nap(500);
    let fg_self = unsafe { GetForegroundWindow() } == me;
    if fg_self {
        say("REFUSING: this window IS the foreground, so nothing below would measure a background post");
    }
    say(format!("before any focus call: {}", ui_focus()));

    let site = find_class(me, INPUT_SITE_CLASS);
    let bridge = find_class(me, super::ISLAND_CLASS);
    say(format!("InputSite={site:#x} bridge={bridge:#x} top={me:#x}"));
    if site == 0 {
        say("NO InputSiteWindowClass under this window — the census above is the finding");
    }

    // ---------------- Q1: which HWND and which message shape lands text --
    say("== Q1: text into the entry (TextBox) from the background ==");
    let routes: [(&str, Dest, Shape, bool); 8] = [
        ("R1 KeysOnly -> InputSite (posted)", Dest::Site, Shape::KeysOnly, false),
        ("R2 KeysAndChar -> InputSite (posted)", Dest::Site, Shape::KeysAndChar, false),
        ("R3 CharOnly -> InputSite (posted)", Dest::Site, Shape::CharOnly, false),
        ("R4 KeysAndChar -> GetFocus() (posted; arrow_step's target)", Dest::Focus, Shape::KeysAndChar, false),
        ("R5 KeysAndChar -> bridge (posted; expected NOT to land)", Dest::Bridge, Shape::KeysAndChar, false),
        ("R6 KeysAndChar -> top-level (posted; expected NOT to land)", Dest::Top, Shape::KeysAndChar, false),
        ("R7 KeysAndChar -> InputSite (SENT)", Dest::Site, Shape::KeysAndChar, true),
        ("R8 KeysOnly 'Milk' with Shift in the UI thread's table -> InputSite", Dest::Site, Shape::KeysOnly, false),
    ];
    let mut landed: Vec<(&str, Shape, bool)> = Vec::new();
    for (name, dest, shape, send) in routes {
        if fg_self {
            break;
        }
        reset_entry();
        let h = dest_hwnd(me, dest);
        if h == 0 {
            say(format!("{name}: SKIPPED, no such window ({dest:?})"));
            continue;
        }
        let before = PREVIEW.load(Relaxed);
        let text = if name.starts_with("R8") { "Milk" } else { "milk" };
        say(format!("{name}: {} chars to {h:#x} class {:?}; {}", text.len(), class_of(h), foreground_report(me)));
        type_text(h, text, shape, send);
        let got = wait_until(2000, || entry_text(0) == text);
        let now = entry_text(0);
        say(format!(
            "{name}: landed={got} entry={now:?} preview_delta={} app={:?} CanUndo={:?}",
            PREVIEW.load(Relaxed) - before,
            label(2),
            on_ui(|core| core.entries[0].CanUndo())
        ));
        if got {
            landed.push((name, shape, send));
        }
    }
    say(format!("Q1 VERDICT: routes that landed the text: {landed:?}"));

    // The door measurements ride the first posted InputSite shape that
    // landed, KeysAndChar preferred (the real keystroke's shape), else
    // KeysOnly, else CharOnly.
    let chosen = landed
        .iter()
        .find(|(n, _, s)| n.starts_with("R2") && !s)
        .or_else(|| landed.iter().find(|(n, _, s)| n.starts_with("R1") && !s))
        .or_else(|| landed.iter().find(|(n, _, s)| n.starts_with("R3") && !s))
        .map(|(_, shape, _)| *shape);
    let Some(shape) = chosen else {
        say("NO POSTED ROUTE LANDED TEXT — the doors below are not measured");
        let _ = std::fs::write(DRIVER_DONE, "done\r\n");
        say(format!("DRIVER VERDICT foreground_was_self={fg_self} text=NONE"));
        println!("PROBEDONE");
        return;
    };
    say(format!("doors measured with {shape:?} posted to the InputSite"));

    // ---------------- (c) native undo ------------------------------------
    say("== (c) the native undo stack after posted typing ==");
    reset_entry();
    type_text(site, "milk", shape, false);
    let _ = wait_until(2000, || entry_text(0) == "milk");
    snap("U0 typed");
    let r = on_ui(|core| core.entries[0].Undo());
    nap(300);
    say(format!("TextBox.Undo() -> {r:?}"));
    snap("U1 after one Undo (the lane's arm merges the whole run into one step)");
    let r = on_ui(|core| core.entries[0].Redo());
    nap(300);
    say(format!("TextBox.Redo() -> {r:?}"));
    snap("U2 after Redo");

    // ---------------- (b) the Return door --------------------------------
    say("== (b) Return into the entry: submit_on_enter (PreviewKeyDown VirtualKey::Enter) ==");
    reset_entry();
    type_text(site, "milk", shape, false);
    let _ = wait_until(2000, || entry_text(0) == "milk");
    press_return(site, false);
    let fired = wait_until(2000, || label(0) == "sent: milk");
    say(format!("Return KeysOnly: submitted={fired} entry={:?} label={:?}", entry_text(0), label(0)));
    reset_entry();
    type_text(site, "soup", shape, false);
    let _ = wait_until(2000, || entry_text(0) == "soup");
    press_return(site, true);
    let fired = wait_until(2000, || label(0) == "sent: soup");
    say(format!(
        "Return KeysAndChar: submitted={fired} entry={:?} label={:?} (a stray CR in the entry would say the posted WM_CHAR bypassed the handled preview)",
        entry_text(0),
        label(0)
    ));

    // ---------------- Shift+Return in the submits textarea ---------------
    say("== the `submits` textarea: Return submits, Shift+Return (GetKeyState) is the newline ==");
    let _ = on_ui(|core| core.textareas[0].TextDocument()?.SetText(super::bindings::Microsoft::UI::Text::TextSetOptions::None, &HSTRING::new()));
    focus_area();
    type_text(site, "ab", shape, false);
    let _ = wait_until(2000, || area_text() == "ab");
    let sent_before = label(0);
    modifier(VK_SHIFT, true);
    press_return(site, false);
    let newline = wait_until(2000, || area_text().len() > 2);
    modifier(VK_SHIFT, false);
    say(format!(
        "Shift+Return: newline_inserted={newline} area={:?} label={:?} (was {sent_before:?})",
        area_text(),
        label(0)
    ));
    press_return(site, false);
    let fired = wait_until(2000, || label(0) != sent_before);
    say(format!("plain Return: submitted={fired} area={:?} label={:?}", area_text(), label(0)));

    // ---------------- the number field: Return and focus loss ------------
    say("== the number field: Return commits; a posted Tab's focus loss commits ==");
    focus_number();
    type_text(site, "12.5", shape, false);
    let _ = wait_until(2000, || number_text().contains("12.5"));
    say(format!("typed: {}", number_text()));
    press_return(site, false);
    let fired = wait_until(2000, || label(1) == "commits: 1");
    say(format!("Return: committed={fired} {} label={:?}", number_text(), label(1)));
    focus_number();
    let _ = on_ui(|core| {
        if let Ok(input) = super::number_input(&core.number_fields[0])? {
            input.SetText(&HSTRING::new())?;
        }
        Ok(())
    });
    type_text(site, "7", shape, false);
    let _ = wait_until(2000, || number_text().contains("text=\"7\""));
    key(site, VK_TAB, Shape::KeysOnly, None, false);
    let moved = wait_until(2000, || entry_focus(1) != "0");
    let fired = wait_until(2000, || label(1) == "commits: 2");
    say(format!(
        "Tab: focus_moved_to_note={moved} (entries[1] {}) committed={fired} {} label={:?}",
        entry_focus(1),
        number_text(),
        label(1)
    ));

    // ---------------- the search field's Escape --------------------------
    say("== the search field: Escape on KeyDown clears ==");
    focus_search();
    type_text(site, "abc", shape, false);
    let _ = wait_until(2000, || search_text() == "abc");
    say(format!("typed: {:?}", search_text()));
    key(site, VK_ESCAPE, Shape::KeysOnly, None, false);
    let cleared = wait_until(2000, || search_text().is_empty());
    say(format!("Escape: cleared={cleared} search={:?} app={:?}", search_text(), label(2)));

    // ---------------- the chord through the thread-scoped WH_KEYBOARD hook
    say("== primary+z with Control in the UI thread's table: key_hook -> Edit>Undo ==");
    reset_entry();
    type_text(site, "zz", shape, false);
    let _ = wait_until(2000, || entry_text(0) == "zz");
    modifier(VK_CONTROL, true);
    key(site, 0x5A, Shape::KeysOnly, None, false);
    let fired = wait_until(2000, || label(3) == "menu: undo");
    modifier(VK_CONTROL, false);
    say(format!("Ctrl+Z: menu_activated={fired} label={:?} entry={:?}", label(3), entry_text(0)));

    snap("final");
    say(format!(
        "DRIVER VERDICT foreground_was_self={fg_self} landed_routes={landed:?} ; {}",
        foreground_report(me)
    ));
    let _ = std::fs::write(DRIVER_DONE, "done\r\n");
    println!("PROBEDONE");
}
