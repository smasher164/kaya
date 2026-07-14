//! AppKit backend, milestone 0: one window, one button, one label.
//!
//! The core owns the main thread and the run loop. Nothing calls into app
//! code: the button's action pushes an occurrence onto the ring and wakes
//! the app thread. Commands come back on their own ring; GCD's main queue
//! is used purely as a doorbell to wake the run loop, never to carry data.

use std::cell::RefCell;
use std::sync::mpsc::Receiver;

use dispatch2::DispatchQueue;
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, ProtocolObject};
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, sel};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSApplicationDelegate, NSBackingStoreType,
    NSButton, NSTextField, NSWindow, NSWindowStyleMask,
};
use objc2_foundation::{NSObject, NSObjectProtocol, NSPoint, NSRect, NSSize, NSString};

use crate::protocol::{Command, OccSink, Occurrence, skeleton};

struct CoreState {
    commands: Receiver<Command>,
    occurrences: OccSink,
    label: Retained<NSTextField>,
    // Held so the target and delegate outlive the objects that reference
    // them weakly.
    _button: Retained<NSButton>,
    _window: Retained<NSWindow>,
    _target: Retained<ButtonTarget>,
    _delegate: Retained<AppDelegate>,
}

impl Drop for CoreState {
    fn drop(&mut self) {
        // The core is going away; tell whoever is draining occurrences.
        self.occurrences.send(Occurrence::Shutdown);
    }
}

thread_local! {
    static CORE: RefCell<Option<CoreState>> = const { RefCell::new(None) };
}

/// Wake the main loop so it drains the command ring. Safe to call from any
/// thread. The dispatched closure carries no data; the ring does.
pub(crate) fn ring_doorbell() {
    DispatchQueue::main().exec_async(|| {
        drain_commands();
    });
}

fn drain_commands() {
    CORE.with_borrow(|core| {
        let Some(core) = core.as_ref() else { return };
        while let Ok(command) = core.commands.try_recv() {
            match command {
                Command::SetText { id, text } => {
                    if id == skeleton::LABEL {
                        core.label.setStringValue(&NSString::from_str(&text));
                    }
                }
            }
        }
    });
}

struct TargetIvars {
    occurrences: OccSink,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "KayaButtonTarget"]
    #[ivars = TargetIvars]
    struct ButtonTarget;

    impl ButtonTarget {
        #[unsafe(method(clicked:))]
        fn clicked(&self, _sender: Option<&AnyObject>) {
            self.ivars().occurrences.send(Occurrence::ButtonClicked {
                id: skeleton::BUTTON,
            });
        }
    }
);

impl ButtonTarget {
    fn new(mtm: MainThreadMarker, occurrences: OccSink) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(TargetIvars { occurrences });
        unsafe { msg_send![super(this), init] }
    }
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "KayaAppDelegate"]
    struct AppDelegate;

    unsafe impl NSObjectProtocol for AppDelegate {}

    unsafe impl NSApplicationDelegate for AppDelegate {
        #[unsafe(method(applicationShouldTerminateAfterLastWindowClosed:))]
        fn should_terminate_after_last_window_closed(&self, _app: &NSApplication) -> bool {
            true
        }
    }
);

impl AppDelegate {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let this = Self::alloc(mtm);
        unsafe { msg_send![this, init] }
    }
}

/// The main-thread half, independent of who owns the app thread: the Rust
/// API spawns one, the C ABI leaves it to the calling language. Returns
/// the exit code; the host process decides how to exit.
pub(crate) fn run_core(occ_tx: OccSink, cmd_rx: Receiver<Command>) -> i32 {
    let mtm = MainThreadMarker::new()
        .expect("kaya must be run on the main thread; the core owns it");

    let app = NSApplication::sharedApplication(mtm);
    app.setActivationPolicy(NSApplicationActivationPolicy::Regular);

    let delegate = AppDelegate::new(mtm);
    app.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));

    let content_rect = NSRect::new(NSPoint::new(200.0, 200.0), NSSize::new(320.0, 160.0));
    let style = NSWindowStyleMask::Titled
        | NSWindowStyleMask::Closable
        | NSWindowStyleMask::Miniaturizable;
    let window = unsafe {
        NSWindow::initWithContentRect_styleMask_backing_defer(
            NSWindow::alloc(mtm),
            content_rect,
            style,
            NSBackingStoreType::Buffered,
            false,
        )
    };
    // Retained<NSWindow> manages the lifetime; the AppKit default of
    // releasing on close would double-free.
    unsafe { window.setReleasedWhenClosed(false) };
    window.setTitle(&NSString::from_str("kaya milestone 0"));

    let target = ButtonTarget::new(mtm, occ_tx.clone());
    let button = unsafe {
        NSButton::buttonWithTitle_target_action(
            &NSString::from_str("Click me"),
            Some(&target),
            Some(sel!(clicked:)),
            mtm,
        )
    };
    button.setFrame(NSRect::new(NSPoint::new(20.0, 90.0), NSSize::new(280.0, 32.0)));

    let label = NSTextField::labelWithString(&NSString::from_str("Clicked 0 times"), mtm);
    label.setFrame(NSRect::new(NSPoint::new(20.0, 40.0), NSSize::new(280.0, 24.0)));

    let content = window.contentView().expect("window has a content view");
    content.addSubview(&button);
    content.addSubview(&label);

    window.makeKeyAndOrderFront(None);
    app.activate();

    if std::env::var_os("KAYA_SELFTEST").is_some() {
        spawn_selftest();
    }

    CORE.with_borrow_mut(|core| {
        *core = Some(CoreState {
            commands: cmd_rx,
            occurrences: occ_tx,
            label,
            _button: button,
            _window: window,
            _target: target,
            _delegate: delegate,
        });
    });

    app.run();
    0
}

/// Drives the full round trip without a human: performClick on the main
/// thread emits a real occurrence, the app thread answers with a command,
/// and the label text proves both rings worked.
fn spawn_selftest() {
    fn on_main(f: impl FnOnce() + Send + 'static) {
        DispatchQueue::main().exec_async(f);
    }

    std::thread::spawn(|| {
        let click = || {
            on_main(|| {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    unsafe { core._button.performClick(None) };
                });
            });
        };

        std::thread::sleep(std::time::Duration::from_millis(500));
        click();
        std::thread::sleep(std::time::Duration::from_millis(200));
        click();
        std::thread::sleep(std::time::Duration::from_millis(500));

        on_main(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let text = core.label.stringValue().to_string();
                if text == "Clicked 2 times" {
                    println!("KAYA_SELFTEST: OK ({text})");
                    std::process::exit(0);
                } else {
                    eprintln!("KAYA_SELFTEST: FAILED (label reads {text:?})");
                    std::process::exit(1);
                }
            });
        });
    });
}
