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
    NSButton, NSControlTextEditingDelegate, NSLayoutAttribute, NSSlider, NSStackView,
    NSTextField, NSTextFieldDelegate, NSUserInterfaceLayoutOrientation, NSWindow,
    NSWindowStyleMask,
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
    Slider(Retained<NSSlider>),
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
            NativeWidget::Slider(v) => v,
        }
    }
}

struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    widgets: HashMap<WidgetId, NativeWidget>,
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index, and drives each control
    // through its own event path — performClick, the entry delegate's
    // emit, the slider target's emit.
    buttons: Vec<Retained<NSButton>>,
    checkboxes: Vec<Retained<NSButton>>,
    labels: Vec<Retained<NSTextField>>,
    entries: Vec<(Retained<NSTextField>, Retained<EntryDelegate>)>,
    sliders: Vec<(Retained<NSSlider>, Retained<ButtonTarget>)>,
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
                    core.buttons.push(button.clone());
                    NativeWidget::Button(button)
                }
                WidgetKind::Label => {
                    let label = NSTextField::labelWithString(&NSString::from_str(""), mtm);
                    core.labels.push(label.clone());
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
                    core.checkboxes.push(boxed.clone());
                    NativeWidget::Checkbox(boxed)
                }
                WidgetKind::Slider => {
                    // Uncontrolled, like the entry: the slider owns its
                    // position and reports each change with its tag.
                    let tag = tag.expect("sliders carry a tag");
                    let target = ButtonTarget::new(mtm, core.occurrences.clone(), tag);
                    debug_assert!(target.respondsToSelector(sel!(valueChanged:)));
                    let target_obj: &objc2::runtime::AnyObject = (*target).as_ref();
                    let slider = unsafe {
                        NSSlider::sliderWithTarget_action(
                            Some(target_obj),
                            Some(sel!(valueChanged:)),
                            mtm,
                        )
                    };
                    slider.setMinValue(0.0);
                    slider.setMaxValue(1.0);
                    core.sliders.push((slider.clone(), target.clone()));
                    core._targets.push(target);
                    NativeWidget::Slider(slider)
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
                    core.entries.push((field.clone(), delegate.clone()));
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
                (NativeWidget::Slider(slider), Prop::Value, Value::F64(v)) => {
                    slider.setDoubleValue(v);
                }
                (NativeWidget::Slider(slider), Prop::Min, Value::F64(v)) => {
                    slider.setMinValue(v);
                }
                (NativeWidget::Slider(slider), Prop::Max, Value::F64(v)) => {
                    slider.setMaxValue(v);
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

        #[unsafe(method(valueChanged:))]
        fn value_changed(&self, sender: Option<&AnyObject>) {
            let value = sender
                .and_then(|s| s.downcast_ref::<NSSlider>())
                .map(|s| s.doubleValue())
                .unwrap_or(0.0);
            self.ivars()
                .occurrences
                .send_value_tag(&self.ivars().tag, value);
        }
    }
);

impl ButtonTarget {
    fn new(mtm: MainThreadMarker, occurrences: OccSink, tag: Vec<u8>) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(TargetIvars { occurrences, tag });
        unsafe { msg_send![super(this), init] }
    }

    fn emit_value(&self, value: f64) {
        self.ivars().occurrences.send_value_tag(&self.ivars().tag, value);
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
    // Selftest runs drive widgets by direct calls, never real input:
    // staying an accessory (no Dock icon, no activation) keeps a
    // 48-leg suite from stealing the human's keyboard 48 times.
    if std::env::var("KAYA_SELFTEST").is_ok() {
        app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);
    } else {
        app.setActivationPolicy(NSApplicationActivationPolicy::Regular);
    }

    let delegate = AppDelegate::new(mtm);
    app.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));

    // Recording mode tiles parallel legs so one display-scoped capture
    // sees every window unoccluded: the runner assigns a slot, the
    // window places itself (its own window — no permissions involved).
    let origin = match std::env::var("KAYA_WIN_SLOT")
        .ok()
        .and_then(|s| s.parse::<u32>().ok())
    {
        Some(slot) => NSPoint::new(
            20.0 + f64::from(slot % 2) * 700.0,
            80.0 + f64::from(slot / 2) * 450.0,
        ),
        None => NSPoint::new(200.0, 200.0),
    };
    let content_rect = NSRect::new(origin, NSSize::new(320.0, 160.0));
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
    if std::env::var("KAYA_SELFTEST").is_ok() {
        window.orderFront(None);
    } else {
        window.makeKeyAndOrderFront(None);
    }

    if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
        crate::harness::spawn(&scene, AppKitStage, |line| println!("{line}"));
    }

    CORE.with_borrow_mut(|core| {
        *core = Some(CoreState {
            transactions: tx_rx,
            scene: Scene::new(),
            occurrences: occ_tx,
            widgets: HashMap::new(),
            buttons: Vec::new(),
            checkboxes: Vec::new(),
            labels: Vec::new(),
            entries: Vec::new(),
            sliders: Vec::new(),
            _targets: Vec::new(),
            _entry_delegates: Vec::new(),
            _window: window,
            _delegate: delegate,
        });
    });

    // The first transaction may already be queued; drain before running.
    drain_transactions();

    if std::env::var("KAYA_SELFTEST").is_err() {
        app.activate();
    }
    app.run();
    0
}

/// The harness stage: AppKit's native calls, each hopping to the main
/// thread. Interactions travel each control's own event path —
/// performClick, the entry delegate's emit, the slider target's emit —
/// exactly what a user's gesture produces.
struct AppKitStage;

impl AppKitStage {
    fn on_main<T: Send + 'static>(
        f: impl FnOnce(&CoreState) -> T + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        DispatchQueue::main().exec_async(move || {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let _ = tx.send(f(core));
            });
        });
        rx.recv().expect("the main thread applied the step")
    }
}

impl crate::harness::Stage for AppKitStage {
    fn click(&self, t: crate::harness::Target) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.buttons.len());
            unsafe { core.buttons[i].performClick(None) };
        });
    }

    fn toggle(&self, t: crate::harness::Target, on: bool) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.checkboxes.len());
            let boxed = &core.checkboxes[i];
            let is_on = boxed.state() == objc2_app_kit::NSControlStateValueOn;
            if is_on != on {
                unsafe { boxed.performClick(None) };
            }
        });
    }

    fn set_value(&self, t: crate::harness::Target, value: f64) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.sliders.len());
            let (slider, target) = &core.sliders[i];
            slider.setDoubleValue(value);
            target.emit_value(value);
        });
    }

    fn set_text(&self, t: crate::harness::Target, text: &str) {
        let text = text.to_owned();
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.entries.len());
            let (field, delegate) = &core.entries[i];
            field.setStringValue(&NSString::from_str(&text));
            delegate.emit(&text);
        });
    }

    fn read_label(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.labels.len());
            core.labels[i].stringValue().to_string()
        })
    }

    fn finish(&self, code: i32, verdict: &str) {
        if code == 0 {
            println!("{verdict}");
        } else {
            eprintln!("{verdict}");
        }
        std::process::exit(code);
    }
}
