//! AppKit backend, milestone 1: an interpreter of resolved apply-ops.
//!
//! The core owns the main thread and the run loop. The scene arrives as
//! transactions; the scene core (scene.rs) resolves them — signals and
//! all — into Create/SetProp/AddChild/Mount ops, and this backend maps
//! those onto NSStackView, NSButton, and NSTextField. Nothing calls into
//! app code: a button's action pushes an occurrence carrying its widget
//! id and wakes the app thread. GCD's main queue is the doorbell,
//! carrying no data.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::mpsc::Receiver;

use dispatch2::DispatchQueue;
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, ProtocolObject};
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, Message, define_class, msg_send, sel};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSApplicationDelegate, NSBackingStoreType,
    NSButton, NSLayoutAttribute, NSStackView, NSTextField, NSUserInterfaceLayoutOrientation,
    NSWindow, NSWindowStyleMask,
};
use objc2_foundation::{NSObject, NSObjectProtocol, NSPoint, NSRect, NSSize, NSString};

use crate::protocol::{ApplyOp, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind};
use crate::scene::Scene;

enum NativeWidget {
    Column(Retained<NSStackView>),
    Button(Retained<NSButton>),
    Label(Retained<NSTextField>),
}

impl NativeWidget {
    fn view(&self) -> &objc2_app_kit::NSView {
        match self {
            NativeWidget::Column(v) => v,
            NativeWidget::Button(v) => v,
            NativeWidget::Label(v) => v,
        }
    }
}

struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    widgets: HashMap<WidgetId, NativeWidget>,
    // The first button (the scene's driver), the most recently created
    // button (a stamped one, in the milestone-2 scene), and the first
    // label (the status line), for the selftest's round trip.
    selftest_button: Option<Retained<NSButton>>,
    selftest_last_button: Option<Retained<NSButton>>,
    selftest_label: Option<Retained<NSTextField>>,
    // Held so targets and the delegate outlive the objects that
    // reference them weakly.
    _targets: Vec<Retained<ButtonTarget>>,
    _window: Retained<NSWindow>,
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

/// Wake the main loop so it drains pending transactions. Safe to call
/// from any thread. The dispatched closure carries no data.
pub(crate) fn ring_doorbell() {
    DispatchQueue::main().exec_async(|| {
        drain_transactions();
    });
}

fn drain_transactions() {
    let mtm = MainThreadMarker::new().expect("the doorbell rings on the main thread");
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        while let Ok(tx) = core.transactions.try_recv() {
            for op in core.scene.apply(tx) {
                apply(core, mtm, op);
            }
        }
    });
}

fn apply(core: &mut CoreState, mtm: MainThreadMarker, op: ApplyOp) {
    match op {
        ApplyOp::Create { id, kind, tag } => {
            let native = match kind {
                WidgetKind::Column => {
                    let stack = NSStackView::new(mtm);
                    stack.setOrientation(NSUserInterfaceLayoutOrientation::Vertical);
                    stack.setAlignment(NSLayoutAttribute::CenterX);
                    stack.setSpacing(8.0);
                    NativeWidget::Column(stack)
                }
                WidgetKind::Button => {
                    // The tag is the click's identity, emitted verbatim;
                    // this backend never learns what it means.
                    let tag = tag.expect("buttons carry a click tag");
                    let target = ButtonTarget::new(mtm, core.occurrences.clone(), tag);
                    let button = unsafe {
                        NSButton::buttonWithTitle_target_action(
                            &NSString::from_str(""),
                            Some(&target),
                            Some(sel!(clicked:)),
                            mtm,
                        )
                    };
                    core._targets.push(target);
                    if core.selftest_button.is_none() {
                        core.selftest_button = Some(button.clone());
                    }
                    core.selftest_last_button = Some(button.clone());
                    NativeWidget::Button(button)
                }
                WidgetKind::Label => {
                    let label = NSTextField::labelWithString(&NSString::from_str(""), mtm);
                    if core.selftest_label.is_none() {
                        core.selftest_label = Some(label.clone());
                    }
                    NativeWidget::Label(label)
                }
            };
            core.widgets.insert(id, native);
        }
        ApplyOp::Destroy { id } => {
            let widget = core.widgets.remove(&id).expect("scene validated the id");
            widget.view().removeFromSuperview();
        }
        ApplyOp::SetProp { id, prop, value } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match (widget, prop, value) {
                (NativeWidget::Button(button), Prop::Text, Value::Str(s)) => {
                    button.setTitle(&NSString::from_str(&s));
                }
                (NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {
                    label.setStringValue(&NSString::from_str(&s));
                }
                (_, prop, value) => {
                    panic!("kaya: appkit cannot apply {prop:?} = {value:?} here")
                }
            }
        }
        ApplyOp::AddChild { parent, child } => {
            // Two lookups because split borrows are not expressible
            // through the map; the retain makes it alias-safe.
            let child_view = core
                .widgets
                .get(&child)
                .expect("scene validated the id")
                .view()
                .retain();
            match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(stack) => stack.addArrangedSubview(&child_view),
                _ => panic!("kaya: add_child parent is not a container"),
            }
        }
        ApplyOp::Mount { window: _, root } => {
            let root_view = core.widgets.get(&root).expect("scene validated the id");
            core._window.setContentView(Some(root_view.view()));
        }
    }
}

struct TargetIvars {
    occurrences: OccSink,
    tag: Vec<u8>,
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
            self.ivars()
                .occurrences
                .send_click_tag(&self.ivars().tag);
        }
    }
);

impl ButtonTarget {
    fn new(mtm: MainThreadMarker, occurrences: OccSink, tag: Vec<u8>) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(TargetIvars { occurrences, tag });
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
pub(crate) fn run_core(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> i32 {
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
    window.makeKeyAndOrderFront(None);

    if std::env::var_os("KAYA_SELFTEST").is_some() {
        spawn_selftest();
    }

    CORE.with_borrow_mut(|core| {
        *core = Some(CoreState {
            transactions: tx_rx,
            scene: Scene::new(),
            occurrences: occ_tx,
            widgets: HashMap::new(),
            selftest_button: None,
            selftest_last_button: None,
            selftest_label: None,
            _targets: Vec::new(),
            _window: window,
            _delegate: delegate,
        });
    });

    // The first transaction may already be queued; drain before running.
    drain_transactions();

    app.activate();
    app.run();
    0
}

/// Drives the full round trip without a human: performClick on the main
/// thread emits real occurrences — twice on the scene's driver button
/// (stamping groups, items, and the When), once on the most recently
/// stamped button (whose click travels as a template-node id plus key
/// path) — and the status label proves the whole loop: stamping, tags,
/// data-addressed removal, and the answering signal write.
fn spawn_selftest() {
    fn on_main(f: impl FnOnce() + Send + 'static) {
        DispatchQueue::main().exec_async(f);
    }

    std::thread::spawn(|| {
        let click_first = || {
            on_main(|| {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    let button = core
                        .selftest_button
                        .as_ref()
                        .expect("the scene has a button");
                    unsafe { button.performClick(None) };
                });
            });
        };
        let click_last = || {
            on_main(|| {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    let button = core
                        .selftest_last_button
                        .as_ref()
                        .expect("the scene has stamped a button");
                    unsafe { button.performClick(None) };
                });
            });
        };

        std::thread::sleep(std::time::Duration::from_millis(500));
        click_first();
        std::thread::sleep(std::time::Duration::from_millis(200));
        click_first();
        std::thread::sleep(std::time::Duration::from_millis(300));
        click_last();
        std::thread::sleep(std::time::Duration::from_millis(500));

        on_main(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let label = core.selftest_label.as_ref().expect("the scene has a label");
                let text = label.stringValue().to_string();
                if text == "removed g2/a" {
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
