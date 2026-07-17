//! UIKit backend, milestone 1: an interpreter of resolved apply-ops.
//!
//! Same architecture as the other backends. iOS is strict about the main
//! thread: UIApplicationMain must run on the actual process main thread
//! and never returns, so the exit code path differs — the self-test exits
//! the process directly, and there is no window-close path (iOS apps do
//! not close windows). GCD's main queue is the doorbell, exactly as on
//! macOS. The delegate is instantiated by UIKit itself, so the channel
//! ends reach it through a slot rather than closure capture.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{CString, c_char};
use std::sync::Mutex;
use std::sync::mpsc::Receiver;

use dispatch2::DispatchQueue;
use objc2::rc::Retained;
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, sel};
use objc2_core_foundation::CGRect;
use objc2_foundation::{NSObject, NSObjectProtocol, NSString};
use objc2_ui_kit::{
    UIApplication, UIApplicationDelegate, UIApplicationMain, UIButton, UIButtonType,
    UIControlEvents, UIControlState, UILabel, UILayoutConstraintAxis, UIScreen, UIStackView,
    UISlider, UISwitch, UITextField, UIView, UIViewAutoresizing, UIViewController, UIWindow,
};

use crate::protocol::{
    ApplyOp, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind,
};
use crate::scene::Scene;

enum NativeWidget {
    Column(Retained<UIStackView>),
    Row(Retained<UIStackView>),
    Button(Retained<UIButton>),
    Label(Retained<UILabel>),
    Entry(Retained<UITextField>),
    // iOS has no checkbox control; the native presentation is a labeled
    // UISwitch. The stack is the widget's view; the caption label and
    // the switch are its fixed children.
    Slider(Retained<UISlider>),
    Checkbox {
        stack: Retained<UIStackView>,
        toggle: Retained<UISwitch>,
        caption: Retained<UILabel>,
    },
}

impl NativeWidget {
    fn view(&self) -> &UIView {
        match self {
            NativeWidget::Column(v) => v,
            NativeWidget::Row(v) => v,
            NativeWidget::Button(v) => v,
            NativeWidget::Label(v) => v,
            NativeWidget::Entry(v) => v,
            NativeWidget::Checkbox { stack, .. } => stack,
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
    // the harness names targets as kind#index and drives each control
    // with sendActionsForControlEvents — the real action path.
    buttons: Vec<Retained<UIButton>>,
    checkboxes: Vec<Retained<UISwitch>>,
    labels: Vec<Retained<UILabel>>,
    entries: Vec<Retained<UITextField>>,
    sliders: Vec<Retained<UISlider>>,
    content: Retained<UIView>,
    _targets: Vec<Retained<ButtonTarget>>,
    _window: Retained<UIWindow>,
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
static CHANNEL_SLOT: Mutex<Option<(OccSink, Receiver<Transaction>)>> = Mutex::new(None);

/// Wake the main loop so it drains pending transactions. Safe to call
/// from any thread. The dispatched closure carries no data.
pub(crate) fn ring_doorbell() {
    DispatchQueue::main().exec_async(|| {
        drain_transactions();
    });
}

fn drain_transactions() {
    let Some(mtm) = MainThreadMarker::new() else { return };
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
                WidgetKind::Entry => {
                    // Uncontrolled: the field owns its text; the target
                    // reports each edit (EditingChanged) with the
                    // entry's identity tag, and the app folds it into
                    // its own model.
                    let tag = tag.expect("entries carry a tag");
                    let target = ButtonTarget::new(mtm, core.occurrences.clone(), tag);
                    let field = UITextField::new(mtm);
                    debug_assert!(target.respondsToSelector(sel!(textChanged:)));
                    let target_obj: &objc2::runtime::AnyObject = (*target).as_ref();
                    unsafe {
                        field.addTarget_action_forControlEvents(
                            Some(target_obj),
                            sel!(textChanged:),
                            UIControlEvents::EditingChanged,
                        );
                    }
                    core._targets.push(target);
                    core.entries.push(field.clone());
                    NativeWidget::Entry(field)
                }
                WidgetKind::Column => {
                    let stack = UIStackView::new(mtm);
                    unsafe {
                        stack.setAxis(UILayoutConstraintAxis::Vertical);
                        stack.setAlignment(objc2_ui_kit::UIStackViewAlignment::Center);
                        stack.setSpacing(8.0);
                    }
                    NativeWidget::Column(stack)
                }
                WidgetKind::Row => {
                    let stack = UIStackView::new(mtm);
                    unsafe {
                        stack.setAxis(UILayoutConstraintAxis::Horizontal);
                        stack.setAlignment(objc2_ui_kit::UIStackViewAlignment::Center);
                        stack.setSpacing(8.0);
                    }
                    NativeWidget::Row(stack)
                }
                WidgetKind::Checkbox => {
                    // The switch owns its checked bit; ValueChanged
                    // reports each flip with the box's identity tag.
                    let tag = tag.expect("checkboxes carry a tag");
                    let target = ButtonTarget::new(mtm, core.occurrences.clone(), tag);
                    debug_assert!(target.respondsToSelector(sel!(toggled:)));
                    let toggle = UISwitch::new(mtm);
                    let target_obj: &objc2::runtime::AnyObject = (*target).as_ref();
                    unsafe {
                        toggle.addTarget_action_forControlEvents(
                            Some(target_obj),
                            sel!(toggled:),
                            UIControlEvents::ValueChanged,
                        );
                    }
                    core._targets.push(target);
                    let caption = UILabel::new(mtm);
                    unsafe { caption.setTextColor(Some(&objc2_ui_kit::UIColor::labelColor())) };
                    let stack = UIStackView::new(mtm);
                    unsafe {
                        stack.setAxis(UILayoutConstraintAxis::Horizontal);
                        stack.setAlignment(objc2_ui_kit::UIStackViewAlignment::Center);
                        stack.setSpacing(8.0);
                        stack.addArrangedSubview(&toggle);
                        stack.addArrangedSubview(&caption);
                    }
                    core.checkboxes.push(toggle.clone());
                    NativeWidget::Checkbox { stack, toggle, caption }
                }
                WidgetKind::Slider => {
                    // Uncontrolled, like the entry: the slider owns its
                    // position; ValueChanged reports each move with its
                    // identity tag. UISlider is f32-valued; the wire is
                    // f64 — the cast is the platform flavor.
                    let tag = tag.expect("sliders carry a tag");
                    let target = ButtonTarget::new(mtm, core.occurrences.clone(), tag);
                    debug_assert!(target.respondsToSelector(sel!(valueChanged:)));
                    let slider = UISlider::new(mtm);
                    unsafe {
                        slider.setMinimumValue(0.0);
                        slider.setMaximumValue(1.0);
                    }
                    let target_obj: &objc2::runtime::AnyObject = (*target).as_ref();
                    unsafe {
                        slider.addTarget_action_forControlEvents(
                            Some(target_obj),
                            sel!(valueChanged:),
                            UIControlEvents::ValueChanged,
                        );
                    }
                    core._targets.push(target);
                    core.sliders.push(slider.clone());
                    NativeWidget::Slider(slider)
                }
                WidgetKind::Button => {
                    // The tag is the click's identity, emitted verbatim;
                    // this backend never learns what it means.
                    let tag = tag.expect("buttons carry a click tag");
                    let target = ButtonTarget::new(mtm, core.occurrences.clone(), tag);
                    debug_assert!(target.respondsToSelector(sel!(clicked:)));
                    let button = UIButton::buttonWithType(UIButtonType::System, mtm);
                    let target_obj: &objc2::runtime::AnyObject = (*target).as_ref();
                    unsafe {
                        button.addTarget_action_forControlEvents(
                            Some(target_obj),
                            sel!(clicked:),
                            UIControlEvents::TouchUpInside,
                        );
                    }
                    core._targets.push(target);
                    core.buttons.push(button.clone());
                    NativeWidget::Button(button)
                }
                WidgetKind::Label => {
                    let label = UILabel::new(mtm);
                    unsafe { label.setTextColor(Some(&objc2_ui_kit::UIColor::labelColor())) };
                    core.labels.push(label.clone());
                    NativeWidget::Label(label)
                }
            };
            core.widgets.insert(id, native);
        }
        ApplyOp::MoveChild {
            parent,
            child,
            before,
        } => {
            use objc2::Message;
            let stack = match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(s) | NativeWidget::Row(s) => s.retain(),
                _ => panic!("kaya: move_child parent is not a container"),
            };
            let child_view = core
                .widgets
                .get(&child)
                .expect("scene validated the id")
                .view()
                .retain();
            unsafe { stack.removeArrangedSubview(&child_view) };
            let index = match before {
                Some(anchor) => {
                    let anchor_view = core
                        .widgets
                        .get(&anchor)
                        .expect("scene validated the id")
                        .view()
                        .retain();
                    let arranged = unsafe { stack.arrangedSubviews() };
                    (0..arranged.count())
                        .position(|i| unsafe { arranged.objectAtIndex(i) } == anchor_view)
                        .expect("kaya: move_child anchor not among siblings")
                }
                None => unsafe { stack.arrangedSubviews() }.count(),
            };
            unsafe { stack.insertArrangedSubview_atIndex(&child_view, index) };
        }
        ApplyOp::Destroy { id } => {
            let widget = core.widgets.remove(&id).expect("scene validated the id");
            widget.view().removeFromSuperview();
        }
        ApplyOp::SetProp { id, prop, value } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match (widget, prop, value) {
                (NativeWidget::Button(button), Prop::Text, Value::Str(s)) => {
                    button.setTitle_forState(
                        Some(&NSString::from_str(&s)),
                        UIControlState::Normal,
                    );
                }
                (NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {
                    label.setText(Some(&NSString::from_str(&s)));
                }
                (NativeWidget::Entry(field), Prop::Text, Value::Str(s)) => {
                    unsafe { field.setText(Some(&NSString::from_str(&s))) };
                }
                (NativeWidget::Checkbox { caption, .. }, Prop::Text, Value::Str(s)) => {
                    caption.setText(Some(&NSString::from_str(&s)));
                }
                (NativeWidget::Checkbox { toggle, .. }, Prop::Checked, Value::Bool(b)) => {
                    unsafe { toggle.setOn(b) };
                }
                (NativeWidget::Slider(slider), Prop::Value, Value::F64(v)) => {
                    unsafe { slider.setValue(v as f32) };
                }
                (NativeWidget::Slider(slider), Prop::Min, Value::F64(v)) => {
                    unsafe { slider.setMinimumValue(v as f32) };
                }
                (NativeWidget::Slider(slider), Prop::Max, Value::F64(v)) => {
                    unsafe { slider.setMaximumValue(v as f32) };
                }
                (_, prop, value) => {
                    panic!("kaya: uikit cannot apply {prop:?} = {value:?} here")
                }
            }
        }
        ApplyOp::AddChild { parent, child } => {
            let child_view = {
                use objc2::Message;
                core.widgets
                    .get(&child)
                    .expect("scene validated the id")
                    .view()
                    .retain()
            };
            match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(stack) | NativeWidget::Row(stack) => unsafe {
                    stack.addArrangedSubview(&child_view);
                },
                _ => panic!("kaya: add_child parent is not a container"),
            }
        }
        ApplyOp::Mount { window: _, root } => {
            let root_view = core.widgets.get(&root).expect("scene validated the id");
            let bounds: CGRect = core.content.bounds();
            root_view.view().setFrame(bounds);
            unsafe {
                root_view.view().setAutoresizingMask(
                    UIViewAutoresizing::FlexibleWidth | UIViewAutoresizing::FlexibleHeight,
                );
            }
            core.content.addSubview(root_view.view());
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
        fn clicked(&self, _sender: Option<&objc2::runtime::AnyObject>) {
            self.ivars()
                .occurrences
                .send_click_tag(&self.ivars().tag);
        }

        #[unsafe(method(toggled:))]
        fn toggled(&self, sender: Option<&objc2::runtime::AnyObject>) {
            let checked = sender
                .and_then(|s| s.downcast_ref::<UISwitch>())
                .map(|t| unsafe { t.isOn() })
                .unwrap_or(false);
            self.ivars()
                .occurrences
                .send_toggle_tag(&self.ivars().tag, checked);
        }

        #[unsafe(method(valueChanged:))]
        fn value_changed(&self, sender: Option<&objc2::runtime::AnyObject>) {
            let value = sender
                .and_then(|s| s.downcast_ref::<UISlider>())
                .map(|s| unsafe { s.value() } as f64)
                .unwrap_or(0.0);
            self.ivars()
                .occurrences
                .send_value_tag(&self.ivars().tag, value);
        }

        #[unsafe(method(textChanged:))]
        fn text_changed(&self, sender: Option<&objc2::runtime::AnyObject>) {
            let text = sender
                .and_then(|s| s.downcast_ref::<UITextField>())
                .and_then(|f| unsafe { f.text() })
                .map(|t| t.to_string())
                .unwrap_or_default();
            self.ivars()
                .occurrences
                .send_text_tag(&self.ivars().tag, &text);
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

    unsafe impl UIApplicationDelegate for AppDelegate {
        #[unsafe(method(application:didFinishLaunchingWithOptions:))]
        fn did_finish_launching(
            &self,
            _application: &UIApplication,
            _options: Option<&objc2_foundation::NSDictionary>,
        ) -> bool {
            let mtm = MainThreadMarker::new().expect("UIKit callbacks run on the main thread");
            let (occ_tx, tx_rx) = CHANNEL_SLOT
                .lock()
                .unwrap()
                .take()
                .expect("run_core stocked the channel slot");
            setup(mtm, occ_tx, tx_rx);
            true
        }
    }
);

fn setup(mtm: MainThreadMarker, occ_tx: OccSink, tx_rx: Receiver<Transaction>) {
    let screen_bounds = UIScreen::mainScreen(mtm).bounds();
    let window = unsafe { UIWindow::initWithFrame(UIWindow::alloc(mtm), screen_bounds) };

    let controller = UIViewController::new(mtm);
    let view = controller.view().expect("controller has a view");
    view.setBackgroundColor(Some(&objc2_ui_kit::UIColor::systemBackgroundColor()));

    window.setRootViewController(Some(&controller));
    window.makeKeyAndVisible();

    if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
        crate::harness::spawn(&scene, UiKitStage, |line| println!("{line}"));
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
            content: view,
            _targets: Vec::new(),
            _window: window,
        });
    });

    // The first transaction may already be queued; drain now.
    drain_transactions();
}

/// The main-thread half. On iOS, UIApplicationMain never returns, so the
/// declared return type is for signature parity with the other backends;
/// the self-test terminates the process directly.
pub(crate) fn run_core(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> i32 {
    *CHANNEL_SLOT.lock().unwrap() = Some((occ_tx, tx_rx));

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

/// The harness stage: UIKit's native calls, each hopping to the main
/// thread. sendActionsForControlEvents raises the real action paths —
/// touch-up-inside, value-changed, editing-changed — exactly what a
/// user's gesture produces.
struct UiKitStage;

impl UiKitStage {
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

impl crate::harness::Stage for UiKitStage {
    fn click(&self, t: crate::harness::Target) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.buttons.len());
            core.buttons[i].sendActionsForControlEvents(UIControlEvents::TouchUpInside);
        });
    }

    fn toggle(&self, t: crate::harness::Target, on: bool) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.checkboxes.len());
            let toggle = &core.checkboxes[i];
            unsafe { toggle.setOn(on) };
            toggle.sendActionsForControlEvents(UIControlEvents::ValueChanged);
        });
    }

    fn set_value(&self, t: crate::harness::Target, value: f64) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.sliders.len());
            let slider = &core.sliders[i];
            unsafe { slider.setValue(value as f32) };
            slider.sendActionsForControlEvents(UIControlEvents::ValueChanged);
        });
    }

    fn set_text(&self, t: crate::harness::Target, text: &str) {
        let text = text.to_owned();
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.entries.len());
            let field = &core.entries[i];
            unsafe { field.setText(Some(&NSString::from_str(&text))) };
            field.sendActionsForControlEvents(UIControlEvents::EditingChanged);
        });
    }

    fn read_label(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.labels.len());
            core.labels[i]
                .text()
                .map(|t| t.to_string())
                .unwrap_or_default()
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
