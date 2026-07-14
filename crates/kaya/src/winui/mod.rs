//! WinUI 3 backend, milestone 0: one window, one button, one label.
//!
//! Same architecture as the AppKit backend: the core owns the UI thread
//! and the XAML dispatcher; the button's Click handler pushes an
//! occurrence and never calls app code; commands come back on their own
//! channel; DispatcherQueue::TryEnqueue is the doorbell (the GCD
//! equivalent), carrying no data.
//!
//! This backend is the de-risking experiment for "WinUI 3 from Rust via
//! COM, no XAML files, no C#". Known uncertainty, to be settled in the
//! VM: whether creating the window from a plain `Application` (no
//! subclass, UI built from a dispatcher callback after `Start`) is
//! sufficient, or whether `IApplicationOverrides` composition is needed
//! for `OnLaunched`.

#[allow(
    non_snake_case,
    non_camel_case_types,
    non_upper_case_globals,
    dead_code,
    clippy::all
)]
mod bindings;

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::mpsc::Receiver;
use std::sync::OnceLock;

use windows_core::HSTRING;

use bindings::Microsoft::UI::Dispatching::{DispatcherQueue, DispatcherQueueHandler};
use bindings::Microsoft::UI::Xaml::Controls::{Button, StackPanel, TextBlock};
use bindings::Microsoft::UI::Xaml::{
    Application, ApplicationInitializationCallback, RoutedEventHandler, Window,
};

use crate::protocol::{Command, OccSink, Occurrence, skeleton};

struct CoreState {
    commands: Receiver<Command>,
    occurrences: OccSink,
    label: TextBlock,
    button: Button,
    _window: Window,
}

impl Drop for CoreState {
    fn drop(&mut self) {
        self.occurrences.send(Occurrence::Shutdown);
    }
}

thread_local! {
    static CORE: RefCell<Option<CoreState>> = const { RefCell::new(None) };
}

/// The UI thread's dispatcher, for waking it from other threads.
/// DispatcherQueue is agile (TryEnqueue is documented thread-safe); the
/// wrapper asserts that to the type system.
struct SharedDispatcher(DispatcherQueue);
unsafe impl Send for SharedDispatcher {}
unsafe impl Sync for SharedDispatcher {}

static DISPATCHER: OnceLock<SharedDispatcher> = OnceLock::new();

/// Exit code for when Application::Start returns. Clean shutdown goes
/// through Application::Exit on the UI thread; calling process::exit from
/// inside XAML dispatch tears down under the framework's feet (observed as
/// an access violation in XAML rundown).
static EXIT_CODE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);

fn request_exit(code: i32) {
    EXIT_CODE.store(code, std::sync::atomic::Ordering::Relaxed);
    if let Ok(app) = Application::Current() {
        let _ = app.Exit();
    }
}

/// Wake the UI thread so it drains the command ring. Safe to call from
/// any thread. The enqueued closure carries no data; the ring does.
pub(crate) fn ring_doorbell() {
    if let Some(dispatcher) = DISPATCHER.get() {
        let handler = DispatcherQueueHandler::new(|| {
            drain_commands();
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
    }
}

fn drain_commands() {
    CORE.with_borrow(|core| {
        let Some(core) = core.as_ref() else { return };
        while let Ok(command) = core.commands.try_recv() {
            match command {
                Command::SetText { id, text } => {
                    if id == skeleton::LABEL {
                        let _ = core.label.SetText(&HSTRING::from(&text));
                    }
                }
            }
        }
    });
}

// --- Windows App Runtime bootstrap (unpackaged apps) ---------------------
//
// The bootstrap DLL ships next to the executable; it locates the installed
// Windows App Runtime and wires it into the process. Loaded dynamically so
// kaya needs no import lib from the NuGet package.

const WASDK_MAJOR_MINOR: u32 = 0x0002_0002; // 2.2
const MDD_ON_NO_MATCH_SHOW_UI: i32 = 0x8;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn LoadLibraryW(name: *const u16) -> *mut c_void;
    fn GetProcAddress(module: *mut c_void, name: *const u8) -> *mut c_void;
}

#[link(name = "ole32")]
unsafe extern "system" {
    fn CoInitializeEx(reserved: *const c_void, coinit: u32) -> i32;
}

type MddBootstrapInitialize2 =
    unsafe extern "system" fn(u32, *const u16, u64, i32) -> i32;
type MddBootstrapShutdown = unsafe extern "system" fn();

static BOOTSTRAP_SHUTDOWN: OnceLock<usize> = OnceLock::new();

fn bootstrap_shutdown() {
    if let Some(&addr) = BOOTSTRAP_SHUTDOWN.get() {
        let shutdown: MddBootstrapShutdown = unsafe { std::mem::transmute(addr) };
        unsafe { shutdown() };
    }
}

fn bootstrap_windows_app_runtime() {
    // TODO: resolve the bootstrap DLL relative to kaya's own module path
    // (GetModuleHandleExW with FROM_ADDRESS) instead of the default search
    // order, so foreign hosts (python.exe) need not have kaya's directory
    // on PATH.
    let dll: Vec<u16> = "Microsoft.WindowsAppRuntime.Bootstrap.dll\0"
        .encode_utf16()
        .collect();
    let module = unsafe { LoadLibraryW(dll.as_ptr()) };
    assert!(
        !module.is_null(),
        "Microsoft.WindowsAppRuntime.Bootstrap.dll not found next to the executable"
    );
    let proc = unsafe { GetProcAddress(module, c"MddBootstrapInitialize2".as_ptr().cast()) };
    assert!(!proc.is_null(), "MddBootstrapInitialize2 not exported");
    let init: MddBootstrapInitialize2 = unsafe { std::mem::transmute(proc) };
    let version_tag: Vec<u16> = "\0".encode_utf16().collect();
    let hr = unsafe { init(WASDK_MAJOR_MINOR, version_tag.as_ptr(), 0, MDD_ON_NO_MATCH_SHOW_UI) };
    assert!(
        hr >= 0,
        "MddBootstrapInitialize2 failed: 0x{hr:08x} (is the Windows App Runtime installed?)"
    );

    let shutdown = unsafe { GetProcAddress(module, c"MddBootstrapShutdown".as_ptr().cast()) };
    if !shutdown.is_null() {
        let _ = BOOTSTRAP_SHUTDOWN.set(shutdown as usize);
    }
}

// --- Core ----------------------------------------------------------------

/// The UI-thread half, independent of who owns the app thread. Returns
/// the exit code; the host process decides how to exit (a library must
/// not tear down someone else's process).
pub(crate) fn run_core(occ_tx: OccSink, cmd_rx: Receiver<Command>) -> i32 {
    bootstrap_windows_app_runtime();

    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    unsafe { CoInitializeEx(std::ptr::null(), COINIT_APARTMENTTHREADED) };

    // Application::Start creates the XAML UI thread machinery and calls
    // back once it is ready; the callback runs on the UI thread. Building
    // the scene is deferred through the dispatcher so it runs after the
    // launch sequence completes.
    let callback = ApplicationInitializationCallback::new(move |_params| {
        let _app = Application::new()?;
        let dispatcher = DispatcherQueue::GetForCurrentThread()?;
        let occ_tx = occ_tx.clone();
        let cmd_rx_cell = RefCell::new(Some(cmd_rx_take()));
        let build = DispatcherQueueHandler::new(move || {
            let cmd_rx = cmd_rx_cell
                .borrow_mut()
                .take()
                .expect("scene built once");
            build_scene(occ_tx.clone(), cmd_rx)
        });
        dispatcher.TryEnqueue(&build)?;
        DISPATCHER
            .set(SharedDispatcher(dispatcher))
            .map_err(|_| ())
            .expect("run_core called once");
        Ok(())
    });

    // Application::Start's callback cannot capture cmd_rx directly because
    // the callback type requires Fn semantics; park it in a static slot.
    cmd_rx_put(cmd_rx);

    Application::Start(&callback).expect("Application::Start failed");

    // Start has returned; XAML has torn down its apartment. Rust TLS
    // destructors still run during process::exit on Windows (TLS
    // callbacks), and releasing XAML COM objects into the dead apartment
    // is an access violation. Announce shutdown, then leak the COM
    // references; the process reclaims everything anyway.
    CORE.with_borrow_mut(|core| {
        if let Some(core) = core.take() {
            core.occurrences.send(Occurrence::Shutdown);
            std::mem::forget(core);
        }
    });
    // Unwind the App Runtime while the process is still healthy; leaving
    // it for DLL_PROCESS_DETACH crashes inside Microsoft.UI.Xaml.dll in
    // hosted processes (observed with python.exe).
    bootstrap_shutdown();
    EXIT_CODE.load(std::sync::atomic::Ordering::Relaxed)
}

// Receiver<Command> is !Sync, and the WinRT callback signature forces the
// closure to be Fn + Send. The receiver crosses into the UI thread through
// this slot instead of the closure environment.
static CMD_RX_SLOT: std::sync::Mutex<Option<Receiver<Command>>> = std::sync::Mutex::new(None);

fn cmd_rx_put(rx: Receiver<Command>) {
    *CMD_RX_SLOT.lock().unwrap() = Some(rx);
}

fn cmd_rx_take() -> Receiver<Command> {
    CMD_RX_SLOT
        .lock()
        .unwrap()
        .take()
        .expect("command receiver already taken")
}

fn build_scene(occ_tx: OccSink, cmd_rx: Receiver<Command>) -> windows_core::Result<()> {
    let window = Window::new()?;
    window.SetTitle(&HSTRING::from("kaya milestone 0"))?;

    let panel = StackPanel::new()?;
    let button = Button::new()?;
    let caption = TextBlock::new()?;
    caption.SetText(&HSTRING::from("Click me"))?;
    button.SetContent(&caption)?;

    let label = TextBlock::new()?;
    label.SetText(&HSTRING::from("Clicked 0 times"))?;

    let children = panel.Children()?;
    children.Append(&button)?;
    children.Append(&label)?;
    window.SetContent(&panel)?;

    let click_sink = occ_tx.clone();
    let handler = RoutedEventHandler::new(move |_, _| {
        click_sink.send(Occurrence::ButtonClicked {
            id: skeleton::BUTTON,
        });
        Ok(())
    });
    button.Click(&handler)?;

    // Closing the window exits the app, matching the AppKit backend's
    // terminate-after-last-window-closed behavior.
    let closed = bindings::Windows::Foundation::TypedEventHandler::new(|_, _| {
        request_exit(0);
        Ok(())
    });
    window.Closed(&closed)?;

    window.Activate()?;

    if std::env::var_os("KAYA_SELFTEST").is_some() {
        spawn_selftest();
    }

    CORE.with_borrow_mut(|core| {
        *core = Some(CoreState {
            commands: cmd_rx,
            occurrences: occ_tx,
            label,
            button,
            _window: window,
        });
    });
    Ok(())
}

/// Drives the round trip without a human. Uses the button's automation
/// invoke path once peers are bound; for the skeleton it performs the
/// click on the UI thread by raising the same handler path the pointer
/// would take.
fn spawn_selftest() {
    fn on_ui(f: impl Fn() -> windows_core::Result<()> + Send + 'static) {
        if let Some(dispatcher) = DISPATCHER.get() {
            let handler = DispatcherQueueHandler::new(move || f());
            let _ = dispatcher.0.TryEnqueue(&handler);
        }
    }

    std::thread::spawn(|| {
        let click = || {
            on_ui(|| {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    // TODO(selftest): use ButtonAutomationPeer::Invoke once
                    // automation bindings are generated, to exercise the
                    // real input path instead of the handler directly.
                    core.occurrences.send(Occurrence::ButtonClicked {
                        id: skeleton::BUTTON,
                    });
                });
                Ok(())
            });
        };

        std::thread::sleep(std::time::Duration::from_millis(800));
        click();
        std::thread::sleep(std::time::Duration::from_millis(300));
        click();
        std::thread::sleep(std::time::Duration::from_millis(700));

        on_ui(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let text = core.label.Text()?.to_string();
                let _ = &core.button;
                if text == "Clicked 2 times" {
                    println!("KAYA_SELFTEST: OK ({text})");
                    request_exit(0);
                } else {
                    eprintln!("KAYA_SELFTEST: FAILED (label reads {text:?})");
                    request_exit(1);
                }
                Ok(())
            })
        });
    });
}
