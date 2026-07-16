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
    NSButton, NSControlTextEditingDelegate, NSLayoutAttribute, NSStackView, NSTextField,
    NSTextFieldDelegate, NSUserInterfaceLayoutOrientation, NSWindow, NSWindowStyleMask,
};
use objc2_foundation::{NSNotification, NSObject, NSObjectProtocol, NSPoint, NSRect, NSSize, NSString};

use crate::protocol::{ApplyOp, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind};
use crate::scene::Scene;

enum NativeWidget {
    Column(Retained<NSStackView>),
    Row(Retained<NSStackView>),
    Button(Retained<NSButton>),
    Label(Retained<NSTextField>),
    Entry(Retained<NSTextField>),
    Checkbox(Retained<NSButton>),
}

impl NativeWidget {
    fn view(&self) -> &objc2_app_kit::NSView {
        match self {
            NativeWidget::Column(v) => v,
            NativeWidget::Row(v) => v,
            NativeWidget::Button(v) => v,
            NativeWidget::Label(v) => v,
            NativeWidget::Entry(v) => v,
            NativeWidget::Checkbox(v) => v,
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
    // The first entry plus its delegate, for the entry selftest: the
    // script sets the field's text and emits the change through the
    // same path a keystroke would.
    selftest_entry: Option<(Retained<NSTextField>, Retained<EntryDelegate>)>,
    selftest_checkbox: Option<Retained<NSButton>>,
    // Held so targets and the delegates outlive the objects that
    // reference them weakly.
    _targets: Vec<Retained<ButtonTarget>>,
    _entry_delegates: Vec<Retained<EntryDelegate>>,
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
                WidgetKind::Row => {
                    let stack = NSStackView::new(mtm);
                    stack.setOrientation(NSUserInterfaceLayoutOrientation::Horizontal);
                    stack.setAlignment(NSLayoutAttribute::CenterY);
                    stack.setSpacing(8.0);
                    NativeWidget::Row(stack)
                }
                WidgetKind::Button => {
                    // The tag is the click's identity, emitted verbatim;
                    // this backend never learns what it means.
                    let tag = tag.expect("buttons carry a click tag");
                    let target = ButtonTarget::new(mtm, core.occurrences.clone(), tag);
                    // Selector/method pairs are stringly; a missing
                    // method is otherwise an unrecognized-selector
                    // crash at first click, not at build.
                    debug_assert!(target.respondsToSelector(sel!(clicked:)));
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
                WidgetKind::Checkbox => {
                    // The tag is the toggle's identity, emitted with the
                    // new state; the box owns its checked bit the way an
                    // entry owns its text.
                    let tag = tag.expect("checkboxes carry a tag");
                    let target = ButtonTarget::new(mtm, core.occurrences.clone(), tag);
                    debug_assert!(target.respondsToSelector(sel!(toggled:)));
                    let target_obj: &objc2::runtime::AnyObject = (*target).as_ref();
                    let boxed = unsafe {
                        NSButton::checkboxWithTitle_target_action(
                            &NSString::from_str(""),
                            Some(target_obj),
                            Some(sel!(toggled:)),
                            mtm,
                        )
                    };
                    core._targets.push(target);
                    if core.selftest_checkbox.is_none() {
                        core.selftest_checkbox = Some(boxed.clone());
                    }
                    NativeWidget::Checkbox(boxed)
                }
                WidgetKind::Entry => {
                    // Uncontrolled: the field owns its text; the
                    // delegate reports each edit with the entry's tag,
                    // and the app folds the occurrences into its own
                    // model. The tag is identity, emitted verbatim.
                    let tag = tag.expect("entries carry a tag");
                    let field = NSTextField::textFieldWithString(&NSString::from_str(""), mtm);
                    let delegate = EntryDelegate::new(mtm, core.occurrences.clone(), tag);
                    unsafe { field.setDelegate(Some(ProtocolObject::from_ref(&*delegate))) };
                    if core.selftest_entry.is_none() {
                        core.selftest_entry = Some((field.clone(), delegate.clone()));
                    }
                    core._entry_delegates.push(delegate);
                    NativeWidget::Entry(field)
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
                (NativeWidget::Entry(field), Prop::Text, Value::Str(s)) => {
                    field.setStringValue(&NSString::from_str(&s));
                }
                (NativeWidget::Checkbox(boxed), Prop::Text, Value::Str(s)) => {
                    boxed.setTitle(&NSString::from_str(&s));
                }
                (NativeWidget::Checkbox(boxed), Prop::Checked, Value::Bool(on)) => {
                    boxed.setState(if on {
                        objc2_app_kit::NSControlStateValueOn
                    } else {
                        objc2_app_kit::NSControlStateValueOff
                    });
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
                NativeWidget::Column(stack) | NativeWidget::Row(stack) => {
                    stack.addArrangedSubview(&child_view)
                }
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

        #[unsafe(method(toggled:))]
        fn toggled(&self, sender: Option<&AnyObject>) {
            let checked = sender
                .and_then(|s| s.downcast_ref::<NSButton>())
                .map(|b| b.state() == objc2_app_kit::NSControlStateValueOn)
                .unwrap_or(false);
            self.ivars()
                .occurrences
                .send_toggle_tag(&self.ivars().tag, checked);
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
    #[name = "KayaEntryDelegate"]
    #[ivars = TargetIvars]
    struct EntryDelegate;

    unsafe impl NSObjectProtocol for EntryDelegate {}

    unsafe impl NSControlTextEditingDelegate for EntryDelegate {
        #[unsafe(method(controlTextDidChange:))]
        fn control_text_did_change(&self, notification: &NSNotification) {
            let Some(object) = notification.object() else { return };
            let Ok(field) = object.downcast::<NSTextField>() else { return };
            self.emit(&field.stringValue().to_string());
        }
    }

    unsafe impl NSTextFieldDelegate for EntryDelegate {}
);

impl EntryDelegate {
    fn new(mtm: MainThreadMarker, occurrences: OccSink, tag: Vec<u8>) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(TargetIvars { occurrences, tag });
        unsafe { msg_send![super(this), init] }
    }

    fn emit(&self, text: &str) {
        self.ivars().occurrences.send_text_tag(&self.ivars().tag, text);
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
    window.setTitle(&NSString::from_str("kaya milestone 2"));
    window.makeKeyAndOrderFront(None);

    match std::env::var("KAYA_SELFTEST") {
        Ok(script) if script == "entry" => spawn_entry_selftest(),
        Ok(script) if script == "gallery" => spawn_gallery_selftest(),
        Ok(script) if script == "todos" => spawn_todos_selftest(),
        Ok(_) => spawn_selftest(),
        Err(_) => {}
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
            selftest_entry: None,
            selftest_checkbox: None,
            _targets: Vec::new(),
            _entry_delegates: Vec::new(),
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
                if text == "removed g2/a, 0 left" {
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

/// The gallery scene's round trip (KAYA_SELFTEST=gallery): performClick
/// on the checkbox — the real user path, flipping state and firing the
/// action — then read the status label.
fn spawn_gallery_selftest() {
    fn on_main(f: impl FnOnce() + Send + 'static) {
        DispatchQueue::main().exec_async(f);
    }

    std::thread::spawn(|| {
        std::thread::sleep(std::time::Duration::from_millis(500));
        on_main(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let boxed = core
                    .selftest_checkbox
                    .as_ref()
                    .expect("the scene has a checkbox");
                unsafe { boxed.performClick(None) };
            });
        });
        std::thread::sleep(std::time::Duration::from_millis(500));
        on_main(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let label = core.selftest_label.as_ref().expect("the scene has a label");
                let text = label.stringValue().to_string();
                if text == "urgent: true" {
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

/// The todos scene's round trip (KAYA_SELFTEST=todos): type through
/// the entry's delegate path, click Add, toggle the stamped row's
/// checkbox — a field-level update — and read the items-left label.
fn spawn_todos_selftest() {
    fn on_main(f: impl FnOnce() + Send + 'static) {
        DispatchQueue::main().exec_async(f);
    }

    std::thread::spawn(|| {
        std::thread::sleep(std::time::Duration::from_millis(500));
        on_main(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let (field, delegate) = core
                    .selftest_entry
                    .as_ref()
                    .expect("the scene has an entry");
                field.setStringValue(&NSString::from_str("buy milk"));
                delegate.emit("buy milk");
            });
        });
        std::thread::sleep(std::time::Duration::from_millis(300));
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
        std::thread::sleep(std::time::Duration::from_millis(400));
        on_main(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let boxed = core
                    .selftest_checkbox
                    .as_ref()
                    .expect("the scene has stamped a checkbox");
                unsafe { boxed.performClick(None) };
            });
        });
        std::thread::sleep(std::time::Duration::from_millis(500));
        on_main(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let label = core.selftest_label.as_ref().expect("the scene has a label");
                let text = label.stringValue().to_string();
                if text == "0 items left" {
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

/// The entry scene's round trip (KAYA_SELFTEST=entry): set the field's
/// text and emit the change through the delegate's own path — exactly
/// what a keystroke produces — then click the add button and read the
/// status label. Proves the uncontrolled-entry contract: text travels
/// up as occurrences, the app folds it into its model, and nothing is
/// ever read back from the widget.
fn spawn_entry_selftest() {
    fn on_main(f: impl FnOnce() + Send + 'static) {
        DispatchQueue::main().exec_async(f);
    }

    std::thread::spawn(|| {
        std::thread::sleep(std::time::Duration::from_millis(500));
        on_main(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let (field, delegate) =
                    core.selftest_entry.as_ref().expect("the scene has an entry");
                field.setStringValue(&NSString::from_str("milk"));
                delegate.emit("milk");
            });
        });
        std::thread::sleep(std::time::Duration::from_millis(300));
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
        std::thread::sleep(std::time::Duration::from_millis(500));
        on_main(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let label = core.selftest_label.as_ref().expect("the scene has a label");
                let text = label.stringValue().to_string();
                if text == "added milk, 1 total" {
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
