//! UIKit backend, milestone 0: one window, one button, one label.
//!
//! Same architecture as the other backends. iOS is strict about the main
//! thread: UIApplicationMain must run on the actual process main thread
//! and never returns, so the exit code path differs — the self-test exits
//! the process directly, and there is no window-close path (iOS apps do
//! not close windows). GCD's main queue is the doorbell, exactly as on
//! macOS. The delegate is instantiated by UIKit itself, so the channel
//! ends reach it through a slot rather than closure capture.

use std::cell::RefCell;
use std::ffi::{CString, c_char};
use std::sync::Mutex;
use std::sync::mpsc::Receiver;

use dispatch2::DispatchQueue;
use objc2::rc::Retained;
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, sel};
use objc2_core_foundation::{CGPoint, CGRect, CGSize};
use objc2_foundation::{NSObject, NSObjectProtocol, NSString};
use objc2_ui_kit::{
    UIApplication, UIApplicationDelegate, UIApplicationMain, UIButton, UIButtonType,
    UIControlEvents, UIControlState, UILabel, UIScreen, UIViewController, UIWindow,
};

use crate::protocol::{Command, OccSink, Occurrence, skeleton};

struct CoreState {
    commands: Receiver<Command>,
    occurrences: OccSink,
    label: Retained<UILabel>,
    button: Retained<UIButton>,
    _window: Retained<UIWindow>,
    _target: Retained<ButtonTarget>,
}

impl Drop for CoreState {
    fn drop(&mut self) {
        self.occurrences.send(Occurrence::Shutdown);
    }
}

thread_local! {
    static CORE: RefCell<Option<CoreState>> = const { RefCell::new(None) };
}

// UIKit constructs the delegate; the channel ends travel through this
// slot instead of a closure environment.
static CHANNEL_SLOT: Mutex<Option<(OccSink, Receiver<Command>)>> = Mutex::new(None);

/// Wake the main loop so it drains the command ring. Safe to call from
/// any thread. The dispatched closure carries no data; the ring does.
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
                        core.label.setText(Some(&NSString::from_str(&text)));
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
        fn clicked(&self, _sender: Option<&objc2::runtime::AnyObject>) {
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

    unsafe impl UIApplicationDelegate for AppDelegate {
        #[unsafe(method(application:didFinishLaunchingWithOptions:))]
        fn did_finish_launching(
            &self,
            _application: &UIApplication,
            _options: Option<&objc2_foundation::NSDictionary>,
        ) -> bool {
            let mtm = MainThreadMarker::new().expect("UIKit callbacks run on the main thread");
            let (occ_tx, cmd_rx) = CHANNEL_SLOT
                .lock()
                .unwrap()
                .take()
                .expect("run_core stocked the channel slot");
            build_scene(mtm, occ_tx, cmd_rx);
            true
        }
    }
);

fn build_scene(mtm: MainThreadMarker, occ_tx: OccSink, cmd_rx: Receiver<Command>) {
    let screen_bounds = UIScreen::mainScreen(mtm).bounds();
    let window = unsafe { UIWindow::initWithFrame(UIWindow::alloc(mtm), screen_bounds) };

    let controller = UIViewController::new(mtm);
    let view = controller.view().expect("controller has a view");
    view.setBackgroundColor(Some(&objc2_ui_kit::UIColor::systemBackgroundColor()));

    let target = ButtonTarget::new(mtm, occ_tx.clone());
    let button = UIButton::buttonWithType(UIButtonType::System, mtm);
    button.setTitle_forState(Some(&NSString::from_str("Click me")), UIControlState::Normal);
    button.setFrame(CGRect::new(CGPoint::new(20.0, 120.0), CGSize::new(280.0, 44.0)));
    let target_obj: &objc2::runtime::AnyObject = (*target).as_ref();
    unsafe {
        button.addTarget_action_forControlEvents(
            Some(target_obj),
            sel!(clicked:),
            UIControlEvents::TouchUpInside,
        );
    }

    let label = UILabel::new(mtm);
    unsafe { label.setTextColor(Some(&objc2_ui_kit::UIColor::labelColor())) };
    label.setText(Some(&NSString::from_str("Clicked 0 times")));
    label.setFrame(CGRect::new(CGPoint::new(20.0, 180.0), CGSize::new(280.0, 32.0)));

    view.addSubview(&button);
    view.addSubview(&label);

    window.setRootViewController(Some(&controller));
    window.makeKeyAndVisible();

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
            _target: target,
        });
    });
}

/// The main-thread half. On iOS, UIApplicationMain never returns, so the
/// declared return type is for signature parity with the other backends;
/// the self-test terminates the process directly.
pub(crate) fn run_core(occ_tx: OccSink, cmd_rx: Receiver<Command>) -> i32 {
    *CHANNEL_SLOT.lock().unwrap() = Some((occ_tx, cmd_rx));

    let mtm = MainThreadMarker::new()
        .expect("kaya must be run on the main thread; the core owns it");
    let _ = mtm;

    // Ensure the delegate class is registered with the runtime before
    // UIKit looks it up by name.
    let _ = <AppDelegate as objc2::ClassType>::class();

    let delegate_name = NSString::from_str("KayaAppDelegate");
    let arg0 = CString::new("kaya").unwrap();
    let mut argv: [*mut c_char; 1] = [arg0.as_ptr() as *mut c_char];
    unsafe {
        UIApplicationMain(
            1,
            std::ptr::NonNull::new(argv.as_mut_ptr()).unwrap(),
            None,
            Some(&delegate_name),
        );
    }
    unreachable!("UIApplicationMain never returns");
}

/// Drives the round trip without a human: sendActionsForControlEvents
/// raises the real touch-up-inside action path.
fn spawn_selftest() {
    fn on_main(f: impl Fn() + Send + 'static) {
        DispatchQueue::main().exec_async(f);
    }

    std::thread::spawn(|| {
        let click = || {
            on_main(|| {
                CORE.with_borrow(|core| {
                    if let Some(core) = core.as_ref() {
                        core.button
                            .sendActionsForControlEvents(UIControlEvents::TouchUpInside);
                    }
                });
            });
        };

        std::thread::sleep(std::time::Duration::from_millis(800));
        click();
        std::thread::sleep(std::time::Duration::from_millis(300));
        click();
        std::thread::sleep(std::time::Duration::from_millis(700));

        on_main(|| {
            CORE.with_borrow(|core| {
                let Some(core) = core.as_ref() else { return };
                let text = core
                    .label
                    .text()
                    .map(|t| t.to_string())
                    .unwrap_or_default();
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
