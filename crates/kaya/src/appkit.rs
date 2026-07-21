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
use std::collections::{HashMap, HashSet};
use std::sync::mpsc::Receiver;

use dispatch2::DispatchQueue;
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, ProtocolObject};
use objc2::{
    AnyThread, DefinedClass, MainThreadMarker, MainThreadOnly, Message, define_class, msg_send, sel,
};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSApplicationDelegate, NSBackingStoreType,
    NSButton, NSControlTextEditingDelegate, NSImage, NSImageView, NSLayoutAttribute,
    NSLayoutConstraint, NSLayoutConstraintOrientation, NSLayoutRelation, NSSlider, NSStackView,
    NSStackViewDistribution, NSTextField, NSTextFieldDelegate, NSUserInterfaceLayoutOrientation,
    NSWindow, NSWindowStyleMask,
};
use objc2_foundation::{
    NSArray, NSData, NSNotification, NSObject, NSObjectProtocol, NSPoint, NSRect, NSSize, NSString,
};

use crate::protocol::{
    ApplyOp, CommandKind, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind,
};
use crate::scene::Scene;

enum NativeWidget {
    Column(Retained<NSStackView>),
    Row(Retained<NSStackView>),
    Button(Retained<NSButton>),
    Label(Retained<NSTextField>),
    Entry(Retained<NSTextField>),
    Checkbox(Retained<NSButton>),
    Slider(Retained<NSSlider>),
    Image(Retained<NSImageView>),
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
            NativeWidget::Image(v) => v,
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
    images: Vec<Retained<NSImageView>>,
    columns: Vec<Retained<NSStackView>>,
    rows: Vec<Retained<NSStackView>>,
    // Flex bookkeeping. A weight is set on a child but solved on its
    // parent — the split is a property of the whole sibling set — so
    // the enclosing stack has to be findable from the child, and its
    // constraints rebuilt whole whenever any of that set changes.
    parents: HashMap<WidgetId, WidgetId>,
    grow: HashMap<WidgetId, f64>,
    grow_constraints: HashMap<WidgetId, Vec<Retained<NSLayoutConstraint>>>,
    /// One trailing filler per container (see add_filler), plus a
    /// pointer set so the child-reading observations can skip them —
    /// a filler is plumbing, never a child.
    fillers: HashMap<WidgetId, Retained<objc2_app_kit::NSView>>,
    filler_ptrs: HashSet<usize>,
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

/// Re-solve one stack's flex split from scratch.
///
/// The blessed semantics are stated once on [`Prop::Grow`] and in
/// DESIGN's layout-normalization worklist: weight 0 is natural size, and
/// the positive-weight children divide the leftover main-axis space in
/// proportion to their weights, their own natural sizes not entering the
/// division.
///
/// AppKit has no weight of its own, so this expresses the split as
/// pairwise Auto Layout constraints: every grower is pinned to the first
/// grower's main-axis dimension times the ratio of their weights, which
/// is exactly "proportional to weight" once the stack has handed the
/// non-growers their natural sizes. Dropping the growers' hugging
/// priority to the floor is what lets the stack stretch them at all —
/// on its own that would only produce AppKit's ordinal behaviour, which
/// is why the ratio constraints carry the actual contract.
///
/// The whole set is rebuilt on every change rather than patched: one
/// weight moving re-proportions every sibling, so there is no smaller
/// correct unit of work.
/// Under Fill distribution the stack must hand its leftover to
/// someone — that requirement is the whole fix. The filler is that
/// someone: an empty view with no intrinsic size, hugging and
/// compression floored so it always yields first, kept last in the
/// arranged order and hidden (= detached) the moment real growers
/// exist. The child-reading observations skip fillers by pointer —
/// plumbing, never a child.
fn add_filler(
    core: &mut CoreState,
    mtm: MainThreadMarker,
    id: WidgetId,
    stack: &NSStackView,
    orientation: NSLayoutConstraintOrientation,
) {
    let filler = objc2_app_kit::NSView::new(mtm);
    filler.setContentHuggingPriority_forOrientation(1.0, orientation);
    filler.setContentCompressionResistancePriority_forOrientation(1.0, orientation);
    stack.addArrangedSubview(&filler);
    core.filler_ptrs
        .insert(Retained::as_ptr(&filler) as usize);
    core.fillers.insert(id, filler);
}

fn resolve_grow(core: &mut CoreState, parent: WidgetId) {
    // Only the axis is needed: the stack sizes the non-growers itself,
    // and the ratios are expressed between the growers directly.
    let axis = match core.widgets.get(&parent) {
        Some(NativeWidget::Column(_)) => NSLayoutAttribute::Height,
        Some(NativeWidget::Row(_)) => NSLayoutAttribute::Width,
        // Destroyed, or never a container: nothing to solve.
        _ => return,
    };
    if let Some(old) = core.grow_constraints.remove(&parent) {
        NSLayoutConstraint::deactivateConstraints(&NSArray::from_retained_slice(&old));
    }

    // Sorted so the reference grower — and therefore the exact set of
    // constraints emitted — is a function of the scene, not of hash
    // order. Same scene, same constraints, every run.
    let mut children: Vec<WidgetId> = core
        .parents
        .iter()
        .filter(|&(_, &p)| p == parent)
        .map(|(&child, _)| child)
        .collect();
    children.sort_by_key(|id| id.0);

    let orientation = match axis {
        NSLayoutAttribute::Height => NSLayoutConstraintOrientation::Vertical,
        _ => NSLayoutConstraintOrientation::Horizontal,
    };
    let mut growers: Vec<(Retained<objc2_app_kit::NSView>, f64)> = Vec::new();
    for child in children {
        let Some(widget) = core.widgets.get(&child) else {
            continue;
        };
        let view = widget.view().retain();
        let weight = core.grow.get(&child).copied().unwrap_or(0.0);
        // A weight that stopped being positive has to have its hugging
        // restored, or the child would keep stretching after its grow
        // went back to 0.
        view.setContentHuggingPriority_forOrientation(
            if weight > 0.0 { 1.0 } else { 250.0 },
            orientation,
        );
        if weight > 0.0 {
            growers.push((view, weight));
        }
    }

    // One grower needs no ratio — the lowered hugging already hands it
    // the leftover. Ratios only mean anything between two of them.
    // The filler absorbs the leftover only while nothing grows; the
    // moment real growers exist they take it (hidden means detached
    // here — out of layout entirely, not zero-sized-but-counted).
    if let Some(filler) = core.fillers.get(&parent) {
        filler.setHidden(!growers.is_empty());
    }
    if growers.len() < 2 {
        return;
    }
    let (reference, reference_weight) = growers[0].clone();
    let made: Vec<Retained<NSLayoutConstraint>> = growers[1..]
        .iter()
        .map(|(view, weight)| unsafe {
            NSLayoutConstraint::constraintWithItem_attribute_relatedBy_toItem_attribute_multiplier_constant(
                view,
                axis,
                NSLayoutRelation::Equal,
                Some(&reference),
                axis,
                weight / reference_weight,
                0.0,
            )
        })
        .collect();
    NSLayoutConstraint::activateConstraints(&NSArray::from_retained_slice(&made));
    core.grow_constraints.insert(parent, made);
}

fn apply(core: &mut CoreState, mtm: MainThreadMarker, op: ApplyOp) {
    match op {
        ApplyOp::Create { id, kind, tag } => {
            let native = match kind {
                WidgetKind::Column => {
                    let stack = NSStackView::new(mtm);
                    // Normalized layout defaults, uniform across all
                    // backends: 8-DIP spacing, children at natural size
                    // packed to the leading (cross-axis start) edge. The
                    // deliberate baseline that replaces each toolkit's
                    // divergent native default.
                    stack.setOrientation(NSUserInterfaceLayoutOrientation::Vertical);
                    stack.setSpacing(8.0);
                    stack.setAlignment(NSLayoutAttribute::Leading);
                    // Fill, not the gravity-areas default: gravity lets
                    // the leftover pool in slack that no optional pin
                    // can claim back (the bottom pull is 250 and LOSES
                    // to nothing — it simply goes unenforced), so
                    // growers held their ratio at minimum size and the
                    // share observation, total-invariant by design,
                    // could not tell. Fill makes handing the leftover
                    // to SOMEONE a required constraint; the filler
                    // below is that someone until real growers exist.
                    stack.setDistribution(NSStackViewDistribution::Fill);
                    stack.setDetachesHiddenViews(true);
                    core.columns.push(stack.clone());
                    add_filler(
                        core,
                        mtm,
                        id,
                        &stack,
                        NSLayoutConstraintOrientation::Vertical,
                    );
                    NativeWidget::Column(stack)
                }
                WidgetKind::Row => {
                    let stack = NSStackView::new(mtm);
                    stack.setOrientation(NSUserInterfaceLayoutOrientation::Horizontal);
                    stack.setSpacing(8.0);
                    stack.setAlignment(NSLayoutAttribute::Top);
                    stack.setDistribution(NSStackViewDistribution::Fill);
                    stack.setDetachesHiddenViews(true);
                    core.rows.push(stack.clone());
                    add_filler(
                        core,
                        mtm,
                        id,
                        &stack,
                        NSLayoutConstraintOrientation::Horizontal,
                    );
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
                WidgetKind::Image => {
                    // Display-only, like Label: no tag, no target. The
                    // source arrives as a SetProp blob and decodes
                    // there.
                    let view = NSImageView::new(mtm);
                    core.images.push(view.clone());
                    NativeWidget::Image(view)
                }
            };
            core.widgets.insert(id, native);
        }
        ApplyOp::MoveChild {
            parent,
            child,
            before,
        } => {
            let stack = match core.widgets.get(&parent) {
                Some(NativeWidget::Column(s)) | Some(NativeWidget::Row(s)) => s.clone(),
                other => panic!("kaya: move_child parent {parent:?} is not a container ({other:?})", other = other.is_some()),
            };
            let child_view = core.widgets[&child].view().retain();
            stack.removeArrangedSubview(&child_view);
            let index = match before {
                Some(anchor) => {
                    let anchor_view = core.widgets[&anchor].view().retain();
                    let arranged = stack.arrangedSubviews();
                    (0..arranged.count())
                        .position(|i| arranged.objectAtIndex(i) == anchor_view)
                        .expect("kaya: move_child anchor not among siblings")
                        as isize
                }
                // Before the filler, which stays last even across
                // moves.
                None => stack.arrangedSubviews().count().saturating_sub(1) as isize,
            };
            stack.insertArrangedSubview_atIndex(&child_view, index);
            // Order does not enter the ratios, but the parent is recorded
            // again in case the move crossed containers.
            core.parents.insert(child, parent);
            resolve_grow(core, parent);
        }
        ApplyOp::Destroy { id } => {
            let widget = core.widgets.remove(&id).expect("scene validated the id");
            widget.view().removeFromSuperview();
            core.grow.remove(&id);
            // Constraints referencing a destroyed view have to go before
            // the sibling set is re-solved; a stack that is itself being
            // destroyed simply drops its (now empty) entry.
            core.grow_constraints.remove(&id);
            if let Some(filler) = core.fillers.remove(&id) {
                core.filler_ptrs
                    .remove(&(Retained::as_ptr(&filler) as usize));
                filler.removeFromSuperview();
            }
            if let Some(parent) = core.parents.remove(&id) {
                resolve_grow(core, parent);
            }
        }
        ApplyOp::SetProp { id, prop, value } => {
            // Grow is handled ahead of the per-kind table, and not as an
            // arm inside it: it is the one prop that is kind-agnostic and
            // whose effect lands on the parent rather than the widget, so
            // it needs `core` mutably while the table holds a widget
            // borrow.
            if let (Prop::Grow, Value::F64(weight)) = (prop, &value) {
                debug_assert!(
                    core.widgets.contains_key(&id),
                    "scene validated the id"
                );
                core.grow.insert(id, *weight);
                if let Some(&parent) = core.parents.get(&id) {
                    resolve_grow(core, parent);
                }
                return;
            }
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
                (NativeWidget::Image(view), Prop::Source, Value::Blob(blob)) => {
                    // Encoded bytes in, native decode: NSImage(data:).
                    // A failed decode yields nil — the placeholder
                    // class, never a crash — and image_size reads 0x0.
                    let data = NSData::with_bytes(&blob.0);
                    let image = NSImage::initWithData(NSImage::alloc(), &data);
                    view.setImage(image.as_deref());
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
                    // Before the filler, which stays last: appending
                    // after it would put children past the leftover.
                    let count = stack.arrangedSubviews().count();
                    stack.insertArrangedSubview_atIndex(
                        &child_view,
                        count.saturating_sub(1) as isize,
                    );
                }
                _ => panic!("kaya: add_child parent is not a container"),
            }
            core.parents.insert(child, parent);
            // The sibling set changed, so the split changes with it —
            // even when this child has no weight of its own, since the
            // leftover it consumes is what the growers divide.
            resolve_grow(core, parent);
        }
        ApplyOp::Mount { window: _, root } => {
            let root_view = core.widgets.get(&root).expect("scene validated the id");
            // The normalized root inset: 16 units INSIDE the root (the
            // root still fills its window — expect_root_fills holds),
            // on every backend, so content stops kissing the window
            // edge on six of seven platforms while one padded.
            if let NativeWidget::Column(stack) | NativeWidget::Row(stack) = root_view {
                stack.setEdgeInsets(objc2_foundation::NSEdgeInsets {
                    top: 16.0,
                    left: 16.0,
                    bottom: 16.0,
                    right: 16.0,
                });
            }
            core._window.setContentView(Some(root_view.view()));
        }
        ApplyOp::Command { id, command } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match command {
                CommandKind::Clear => {
                    let NativeWidget::Entry(field) = widget else {
                        panic!("kaya: clear on a non-entry (scene validates kinds)")
                    };
                    // The field stays authoritative and answers through
                    // its normal edit path. AppKit fires no
                    // controlTextDidChange for a programmatic set, so
                    // the delegate emits explicitly — the same
                    // compensation the Stage's set_text makes.
                    field.setStringValue(&NSString::from_str(""));
                    let (_, delegate) = core
                        .entries
                        .iter()
                        .find(|(f, _)| std::ptr::eq::<NSTextField>(&**f, &**field))
                        .expect("entries registry covers every entry");
                    delegate.emit("");
                }
                CommandKind::Focus => {
                    // Per-window first responder: key status is not
                    // required, so parallel tiled suite legs cannot
                    // steal each other's focus assertions.
                    core._window.makeFirstResponder(Some(widget.view()));
                }
            }
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
    // The grid adapts to the actual screen: cells sized for the
    // largest selftest window any backend places (SwiftUI's 540x330;
    // this backend's windows are smaller and share the same slots), a
    // partial last cell counting when the window itself still fits.
    let origin = match std::env::var("KAYA_WIN_SLOT")
        .ok()
        .and_then(|s| s.parse::<u32>().ok())
    {
        Some(slot) => {
            let (sw, sh) = objc2_app_kit::NSScreen::mainScreen(mtm)
                .map(|s| {
                    let f = s.visibleFrame();
                    (f.size.width, f.size.height)
                })
                .unwrap_or((1440.0, 900.0));
            let cols = (((sw - 20.0 - 540.0) / 570.0).floor() as u32 + 1).max(1);
            let rows = (((sh - 40.0 - 330.0) / 345.0).floor() as u32 + 1).max(1);
            let capacity = cols * rows;
            let slot = slot % capacity;
            NSPoint::new(
                20.0 + f64::from(slot % cols) * 570.0,
                40.0 + f64::from(slot / cols) * 345.0,
            )
        }
        None => NSPoint::new(200.0, 200.0),
    };
    // 540x330: the one desktop default (SwiftUI already used it; the
    // placement grids were already sized for it).
    let content_rect = NSRect::new(origin, NSSize::new(540.0, 330.0));
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
            images: Vec::new(),
            columns: Vec::new(),
            rows: Vec::new(),
            parents: HashMap::new(),
            grow: HashMap::new(),
            grow_constraints: HashMap::new(),
            fillers: HashMap::new(),
            filler_ptrs: HashSet::new(),
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

    fn read_text(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.entries.len());
            core.entries[i].0.stringValue().to_string()
        })
    }

    fn image_size(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.images.len());
            match core.images[i].image() {
                // NSImage.size is in points; the tiny test PNGs carry
                // no DPI chunk, so points equal pixels here.
                Some(image) => {
                    let size = image.size();
                    format!("{}x{}", size.width as i64, size.height as i64)
                }
                None => "0x0".into(),
            }
        })
    }

    fn is_focused(&self, t: crate::harness::Target) -> bool {
        Self::on_main(move |core| {
            // A focused NSTextField's first responder is its field
            // editor, not the field — currentEditor() is non-nil
            // exactly while the field holds focus, and stays
            // per-window (key status not required).
            match t.kind {
                crate::harness::TargetKind::Entry => {
                    let i = crate::harness::resolve(t.index, core.entries.len());
                    core.entries[i].0.currentEditor().is_some()
                }
                other => panic!("kaya: is_focused not wired for {other:?} on appkit"),
            }
        })
    }

    fn child_texts(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.columns.len());
            let stack = &core.columns[i];
            // Child order as the toolkit holds it — the registries are
            // creation-ordered and cannot observe a move.
            let mut texts = Vec::new();
            for child in stack.arrangedSubviews() {
                if let Some(field) = child.downcast_ref::<NSTextField>() {
                    let is_label = core
                        .labels
                        .iter()
                        .any(|l| std::ptr::eq::<NSTextField>(&**l, field));
                    if is_label {
                        texts.push(field.stringValue().to_string());
                    }
                }
            }
            texts.join("|")
        })
    }

    fn child_shares(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            // Kind picks the registry and the axis: a column's
            // children split its height, a row's its width (the runner
            // rejects any other kind before it gets here).
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let i = crate::harness::resolve(t.index, registry.len());
            let stack = &registry[i];
            // Constraints are solved lazily; without this the first read
            // after mount would see the pre-layout frames.
            stack.layoutSubtreeIfNeeded();
            // The alignment rect, not the frame: AppKit inflates some
            // controls' frames past the rect Auto Layout actually
            // constrains (a slider by 2pt a side), which would report a
            // 1:3 split as 2.90:1.
            let mut extents = Vec::new();
            for child in stack.arrangedSubviews() {
                if core.filler_ptrs.contains(&(Retained::as_ptr(&child) as usize)) {
                    continue;
                }
                let rect = child.alignmentRectForFrame(child.frame());
                extents.push(if vertical { rect.size.height } else { rect.size.width });
            }
            crate::harness::shares(&extents)
        })
    }

    fn container_fills(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let i = crate::harness::resolve(t.index, registry.len());
            let stack = &registry[i];
            stack.layoutSubtreeIfNeeded();
            // The content box: bounds minus the stack's own edge
            // insets (where the normalized root inset lives).
            let insets = stack.edgeInsets();
            let bounds = stack.bounds();
            let inner = if vertical {
                bounds.size.height - insets.top - insets.bottom
            } else {
                bounds.size.width - insets.left - insets.right
            };
            // First alignment-rect start to last end; fillers are
            // plumbing, hidden or not, and never count.
            let mut min_start = f64::MAX;
            let mut max_end = f64::MIN;
            for child in stack.arrangedSubviews() {
                if core.filler_ptrs.contains(&(Retained::as_ptr(&child) as usize)) {
                    continue;
                }
                let rect = child.alignmentRectForFrame(child.frame());
                let (start, extent) = if vertical {
                    (rect.origin.y, rect.size.height)
                } else {
                    (rect.origin.x, rect.size.width)
                };
                min_start = min_start.min(start);
                max_end = max_end.max(start + extent);
            }
            if max_end < min_start {
                return "no children".to_owned();
            }
            let span = max_end - min_start;
            if (span - inner).abs() <= 2.0 {
                String::new()
            } else {
                format!(
                    "children span {}pt of {}pt",
                    span.round() as i64,
                    inner.round() as i64
                )
            }
        })
    }

    fn root_fills(&self) -> String {
        Self::on_main(move |core| {
            // The mounted root IS the contentView (Mount hands it to
            // setContentView), so it fills by construction — this
            // measures rather than trusts, and holds the door shut
            // against a future mount that pins instead of replacing.
            let Some(view) = core._window.contentView() else {
                return "nothing mounted".to_owned();
            };
            view.layoutSubtreeIfNeeded();
            let frame = view.frame();
            let area = core._window.contentLayoutRect();
            // Within one point: rounding is not a hug.
            if (frame.size.width - area.size.width).abs() <= 1.0
                && (frame.size.height - area.size.height).abs() <= 1.0
            {
                String::new()
            } else {
                format!(
                    "{}x{}pt inside {}x{}pt",
                    frame.size.width as i64,
                    frame.size.height as i64,
                    area.size.width as i64,
                    area.size.height as i64,
                )
            }
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
