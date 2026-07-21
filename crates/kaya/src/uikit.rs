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
use std::collections::{HashMap, HashSet};
use std::ffi::{CString, c_char};
use std::sync::Mutex;
use std::sync::mpsc::Receiver;

use dispatch2::DispatchQueue;
use objc2::rc::Retained;
use objc2::{
    AnyThread, DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, sel,
};
use objc2_foundation::{NSArray, NSData, NSObject, NSObjectProtocol, NSString};
use objc2_ui_kit::{
    NSLayoutAttribute, NSLayoutConstraint, NSLayoutRelation, UIApplication, UIApplicationDelegate,
    UIApplicationMain, UIButton, UIButtonType, UIControlEvents, UIControlState, UIImage,
    UIImageView, UILabel, UILayoutConstraintAxis, UIScreen, UIStackView, UISlider, UISwitch,
    UITextField, UIView, UIViewController, UIWindow,
};

use crate::protocol::{
    ApplyOp, CommandKind, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind,
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
    Image(Retained<UIImageView>),
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
    // the harness names targets as kind#index and drives each control
    // with sendActionsForControlEvents — the real action path.
    buttons: Vec<Retained<UIButton>>,
    checkboxes: Vec<Retained<UISwitch>>,
    labels: Vec<Retained<UILabel>>,
    entries: Vec<Retained<UITextField>>,
    sliders: Vec<Retained<UISlider>>,
    images: Vec<Retained<UIImageView>>,
    columns: Vec<Retained<UIStackView>>,
    rows: Vec<Retained<UIStackView>>,
    // Flex bookkeeping, as on AppKit: a weight is set on a child but
    // solved across the whole sibling set, so the enclosing stack has to
    // be reachable from the child and its constraints rebuilt whole.
    parents: HashMap<WidgetId, WidgetId>,
    grow: HashMap<WidgetId, f64>,
    grow_constraints: HashMap<WidgetId, Vec<Retained<NSLayoutConstraint>>>,
    /// The mounted root, for the root-fills observation.
    root: Option<WidgetId>,
    /// Each container's trailing leftover-absorber by container id (see
    /// make_filler), plus a pointer set so the child-reading
    /// observations can skip them — a filler is plumbing, never a
    /// child.
    fillers: HashMap<WidgetId, Retained<UIView>>,
    filler_ptrs: HashSet<usize>,
    /// A nested container's breadth constraint (the child spans its
    /// parent's cross axis — see pin_breadth), by CHILD id: rebuilt on
    /// move, dropped on destroy.
    breadth: HashMap<WidgetId, Retained<NSLayoutConstraint>>,
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

/// Re-solve one stack's flex split from scratch — UIKit's half of the
/// `grow` contract, and the same shape as the AppKit one.
///
/// UIStackView has no per-child weight either: its `distribution` knob
/// offers equal-size/equal-spacing modes and `fill`, none of which is
/// "divide the leftover in proportion to these numbers". So the ratios
/// are expressed as pairwise Auto Layout constraints between the
/// growers, exactly as on AppKit, and the growers' hugging priority is
/// dropped so the stack will stretch them at all.
///
/// See [`Prop::Grow`] for the contract itself.
fn resolve_grow(core: &mut CoreState, mtm: MainThreadMarker, parent: WidgetId) {
    let axis = match core.widgets.get(&parent) {
        Some(NativeWidget::Column(_)) => NSLayoutAttribute::Height,
        Some(NativeWidget::Row(_)) => NSLayoutAttribute::Width,
        _ => return,
    };
    if let Some(old) = core.grow_constraints.remove(&parent) {
        NSLayoutConstraint::deactivateConstraints(&NSArray::from_retained_slice(&old), mtm);
    }

    // Sorted so the reference grower is a function of the scene, not of
    // hash order: same scene, same constraints, every run.
    let mut children: Vec<WidgetId> = core
        .parents
        .iter()
        .filter(|&(_, &p)| p == parent)
        .map(|(&child, _)| child)
        .collect();
    children.sort_by_key(|id| id.0);

    let hug_axis = match axis {
        NSLayoutAttribute::Height => UILayoutConstraintAxis::Vertical,
        _ => UILayoutConstraintAxis::Horizontal,
    };
    let mut growers: Vec<(Retained<UIView>, f64)> = Vec::new();
    for child in children {
        let Some(widget) = core.widgets.get(&child) else {
            continue;
        };
        use objc2::Message;
        let view = widget.view().retain();
        let weight = core.grow.get(&child).copied().unwrap_or(0.0);
        // Restore hugging when a weight goes back to 0, or the child
        // would keep stretching after it stopped growing.
        unsafe {
            view.setContentHuggingPriority_forAxis(
                if weight > 0.0 { 1.0 } else { 250.0 },
                hug_axis,
            );
        }
        if weight > 0.0 {
            growers.push((view, weight));
        }
    }

    // The filler absorbs the leftover only while nothing grows; the
    // moment a weight appears the growers own it (the stack skips
    // hidden arranged subviews entirely).
    if let Some(filler) = core.fillers.get(&parent) {
        filler.setHidden(!growers.is_empty());
    }

    // One grower needs no ratio: the lowered hugging already hands it
    // the leftover. Ratios only mean anything between two of them.
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
                mtm,
            )
        })
        .collect();
    NSLayoutConstraint::activateConstraints(&NSArray::from_retained_slice(&made), mtm);
    core.grow_constraints.insert(parent, made);
}

/// Give a container its trailing leftover-absorber.
///
/// UIStackView has no gravity distribution: under distribution=.fill —
/// the only mode that keeps kaya's 8pt spacing — SOMETHING must take
/// the leftover once the stack is larger than its content, or the
/// stack stretches the least-hugging real child (the "balloon"
/// pathology this backend once dodged by hugging the whole root, which
/// in turn silently left every grow weight nothing to divide). The
/// filler is that something: an empty view with no intrinsic size and
/// rock-bottom priorities, absorbing the leftover while nothing grows
/// and hiding the moment a sibling carries a weight (resolve_grow owns
/// that bit; the stack skips hidden arranged subviews entirely). The
/// child-reading observations skip fillers by pointer — plumbing is
/// not a child.
fn add_filler(
    core: &mut CoreState,
    mtm: MainThreadMarker,
    id: WidgetId,
    stack: &UIStackView,
    axis: UILayoutConstraintAxis,
) {
    use objc2::Message;
    let filler = UIView::new(mtm);
    unsafe {
        filler.setContentHuggingPriority_forAxis(1.0, axis);
        filler.setContentCompressionResistancePriority_forAxis(1.0, axis);
        stack.addArrangedSubview(&filler);
    }
    core.filler_ptrs
        .insert(Retained::as_ptr(&filler.retain()) as usize);
    core.fillers.insert(id, filler);
}

/// Pin a nested container across its parent's breadth.
///
/// The normalized cross-axis default is leading/natural — a label in a
/// column keeps its own width — but a nested CONTAINER whose main axis
/// runs across the parent spans that breadth: a row in a column is as
/// wide as the column, a column in a row as tall as the row. Every
/// other backend has this natively (KayaFlex spells it "offer the
/// container's full cross extent; the child decides"); without it a
/// row hugs the sum of its children's intrinsic widths, growers divide
/// a leftover of zero, and the layout scene's sliders collapsed to
/// their thumbs. Same-axis nesting takes no constraint — the parent's
/// own distribution governs its main axis.
fn pin_breadth(core: &mut CoreState, parent: WidgetId, child: WidgetId) {
    if let Some(old) = core.breadth.remove(&child) {
        old.setActive(false);
    }
    let (Some(parent_widget), Some(child_widget)) =
        (core.widgets.get(&parent), core.widgets.get(&child))
    else {
        return;
    };
    let constraint = match (parent_widget, child_widget) {
        (NativeWidget::Column(p), NativeWidget::Row(c)) => unsafe {
            c.widthAnchor().constraintEqualToAnchor(&p.widthAnchor())
        },
        (NativeWidget::Row(p), NativeWidget::Column(c)) => unsafe {
            c.heightAnchor().constraintEqualToAnchor(&p.heightAnchor())
        },
        _ => return,
    };
    constraint.setActive(true);
    core.breadth.insert(child, constraint);
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
                    // The uniform layout default (matches AppKit/SwiftUI):
                    // 8pt between children; children at natural size packed
                    // to the start of the main axis (top) and aligned to the
                    // leading (left) cross edge. Distribution defaults to
                    // .fill along the axis; the trailing filler is what
                    // keeps that from stretching a real child when the
                    // stack is larger than its content (see add_filler).
                    unsafe {
                        stack.setAxis(UILayoutConstraintAxis::Vertical);
                        stack.setSpacing(8.0);
                        stack.setAlignment(objc2_ui_kit::UIStackViewAlignment::Leading);
                    }
                    add_filler(core, mtm, id, &stack, UILayoutConstraintAxis::Vertical);
                    core.columns.push(stack.clone());
                    NativeWidget::Column(stack)
                }
                WidgetKind::Row => {
                    let stack = UIStackView::new(mtm);
                    // Same uniform default on the horizontal axis: 8pt
                    // between children, aligned to the top cross edge, at
                    // natural size.
                    unsafe {
                        stack.setAxis(UILayoutConstraintAxis::Horizontal);
                        stack.setSpacing(8.0);
                        stack.setAlignment(objc2_ui_kit::UIStackViewAlignment::Top);
                    }
                    add_filler(core, mtm, id, &stack, UILayoutConstraintAxis::Horizontal);
                    core.rows.push(stack.clone());
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
                WidgetKind::Image => {
                    // Display-only, like Label: no tag, no target. The
                    // source arrives as a SetProp blob and decodes
                    // there.
                    let view = UIImageView::new(mtm);
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
                // Before the filler, which stays last even across moves.
                None => unsafe { stack.arrangedSubviews() }.count().saturating_sub(1),
            };
            unsafe { stack.insertArrangedSubview_atIndex(&child_view, index) };
            // Order does not enter the ratios, but the parent is
            // recorded again in case the move crossed containers — and
            // the breadth pin follows the child to its new parent.
            core.parents.insert(child, parent);
            pin_breadth(core, parent, child);
            resolve_grow(core, mtm, parent);
        }
        ApplyOp::Destroy { id } => {
            let widget = core.widgets.remove(&id).expect("scene validated the id");
            widget.view().removeFromSuperview();
            core.grow.remove(&id);
            // Constraints referencing a destroyed view go before the
            // sibling set is re-solved.
            core.grow_constraints.remove(&id);
            if let Some(constraint) = core.breadth.remove(&id) {
                constraint.setActive(false);
            }
            if let Some(filler) = core.fillers.remove(&id) {
                use objc2::Message;
                core.filler_ptrs
                    .remove(&(Retained::as_ptr(&filler.retain()) as usize));
                filler.removeFromSuperview();
            }
            if let Some(parent) = core.parents.remove(&id) {
                resolve_grow(core, mtm, parent);
            }
        }
        ApplyOp::SetProp { id, prop, value } => {
            // Grow ahead of the per-kind table: the one kind-agnostic
            // prop, and the one whose effect lands on the parent.
            if let (Prop::Grow, Value::F64(weight)) = (prop, &value) {
                debug_assert!(core.widgets.contains_key(&id), "scene validated the id");
                core.grow.insert(id, *weight);
                if let Some(&parent) = core.parents.get(&id) {
                    resolve_grow(core, mtm, parent);
                }
                return;
            }
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
                (NativeWidget::Image(view), Prop::Source, Value::Blob(blob)) => {
                    // Encoded bytes in, native decode: UIImage(data:).
                    // A failed decode yields nil — the placeholder
                    // class, never a crash — and image_size reads 0x0.
                    let data = NSData::with_bytes(&blob.0);
                    let image = UIImage::initWithData(UIImage::alloc(), &data);
                    unsafe { view.setImage(image.as_deref()) };
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
                    // Before the filler, which stays last: appending
                    // after it would put children past the leftover.
                    let count = stack.arrangedSubviews().count();
                    stack.insertArrangedSubview_atIndex(&child_view, count.saturating_sub(1));
                },
                _ => panic!("kaya: add_child parent is not a container"),
            }
            core.parents.insert(child, parent);
            pin_breadth(core, parent, child);
            // The sibling set changed, so the split changes with it.
            resolve_grow(core, mtm, parent);
        }
        ApplyOp::Mount { window: _, root } => {
            core.root = Some(root);
            let root_view = core.widgets.get(&root).expect("scene validated the id");
            let view = root_view.view();
            // The root fills the safe area — the DESIGN normalization
            // ("the mounted root fills its window"), the one AppKit gets
            // by making the root the contentView and GTK by forcing Fill
            // on mount. This backend once hugged instead, to dodge
            // distribution=.fill's balloon pathology — which silently
            // left grow nothing to divide: the ratio held over a total
            // of a few dozen points, and share-based assertion
            // (total-invariant by construction) could not see it; the
            // first iOS recording could. The balloon is the fillers'
            // problem now (see add_filler), so the root can finally
            // take its window.
            core.content.addSubview(&view);
            // The normalized root inset: 16 units INSIDE the root (the
            // root still fills the safe area — expect_root_fills
            // holds), matching every other backend.
            if let NativeWidget::Column(stack) | NativeWidget::Row(stack) =
                core.widgets.get(&root).expect("scene validated the id")
            {
                unsafe {
                    stack.setLayoutMarginsRelativeArrangement(true);
                    stack.setLayoutMargins(objc2_ui_kit::UIEdgeInsets {
                        top: 16.0,
                        left: 16.0,
                        bottom: 16.0,
                        right: 16.0,
                    });
                }
            }
            let guide = core.content.safeAreaLayoutGuide();
            unsafe {
                view.setTranslatesAutoresizingMaskIntoConstraints(false);
                view.topAnchor()
                    .constraintEqualToAnchor(&guide.topAnchor())
                    .setActive(true);
                view.leadingAnchor()
                    .constraintEqualToAnchor(&guide.leadingAnchor())
                    .setActive(true);
                view.trailingAnchor()
                    .constraintEqualToAnchor(&guide.trailingAnchor())
                    .setActive(true);
                view.bottomAnchor()
                    .constraintEqualToAnchor(&guide.bottomAnchor())
                    .setActive(true);
            }
        }
        ApplyOp::Command { id, command } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match command {
                CommandKind::Clear => {
                    let NativeWidget::Entry(field) = widget else {
                        panic!("kaya: clear on a non-entry (scene validates kinds)")
                    };
                    // The field stays authoritative and answers through
                    // its normal edit path. UIKit fires no
                    // EditingChanged for a programmatic set, so the
                    // action is re-fired explicitly — the same
                    // compensation the Stage's set_text makes.
                    unsafe { field.setText(Some(&NSString::from_str(""))) };
                    field.sendActionsForControlEvents(UIControlEvents::EditingChanged);
                }
                CommandKind::Focus => {
                    widget.view().becomeFirstResponder();
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
            images: Vec::new(),
            columns: Vec::new(),
            rows: Vec::new(),
            parents: HashMap::new(),
            grow: HashMap::new(),
            grow_constraints: HashMap::new(),
            root: None,
            fillers: HashMap::new(),
            filler_ptrs: HashSet::new(),
            breadth: HashMap::new(),
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

    fn read_text(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.entries.len());
            unsafe { core.entries[i].text() }
                .map(|t| t.to_string())
                .unwrap_or_default()
        })
    }

    fn image_size(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.images.len());
            match core.images[i].image() {
                // UIImage.size is in points; the tiny test PNGs carry
                // no DPI, so points equal pixels here.
                Some(image) => {
                    let size = unsafe { image.size() };
                    format!("{}x{}", size.width as i64, size.height as i64)
                }
                None => "0x0".into(),
            }
        })
    }

    fn is_focused(&self, t: crate::harness::Target) -> bool {
        Self::on_main(move |core| {
            // First-responder status is per-window on iOS (there is
            // one key window per scene), so parallel legs cannot steal
            // each other's focus assertions.
            match t.kind {
                crate::harness::TargetKind::Entry => {
                    let i = crate::harness::resolve(t.index, core.entries.len());
                    core.entries[i].isFirstResponder()
                }
                other => panic!("kaya: is_focused not wired for {other:?} on uikit"),
            }
        })
    }

    fn child_texts(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let registry = if matches!(t.kind, crate::harness::TargetKind::Column) {
                &core.columns
            } else {
                &core.rows
            };
            let i = crate::harness::resolve(t.index, registry.len());
            let stack = &registry[i];
            // Child order as the toolkit holds it — the registries are
            // creation-ordered and cannot observe a move.
            let mut texts = Vec::new();
            for child in unsafe { stack.arrangedSubviews() } {
                if let Some(label) = child.downcast_ref::<UILabel>() {
                    let is_label = core
                        .labels
                        .iter()
                        .any(|l| std::ptr::eq::<UILabel>(&**l, label));
                    if is_label {
                        texts.push(label.text().map(|t| t.to_string()).unwrap_or_default());
                    }
                }
            }
            texts.join("|")
        })
    }

    fn child_shares(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            // Kind picks the registry and the axis: a column's children
            // split its height, a row's its width (the runner rejects
            // any other kind before it gets here).
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let i = crate::harness::resolve(t.index, registry.len());
            let stack = &registry[i];
            // Constraints solve lazily; without this the first read
            // after mount sees the pre-layout frames.
            stack.layoutIfNeeded();
            let mut extents = Vec::new();
            for child in unsafe { stack.arrangedSubviews() } {
                // The trailing filler is plumbing, not a child: counted,
                // it would append a phantom extent (0 beside growers,
                // the whole leftover beside natural-size children) and
                // break the byte-for-byte share comparison.
                use objc2::Message;
                if core
                    .filler_ptrs
                    .contains(&(Retained::as_ptr(&child.retain()) as usize))
                {
                    continue;
                }
                extents.push(if vertical {
                    child.frame().size.height
                } else {
                    child.frame().size.width
                });
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
            stack.layoutIfNeeded();
            // The content box: bounds minus layout margins when the
            // stack arranges relative to them (the root inset), the
            // raw bounds otherwise (margins exist on every UIView but
            // only bind arranged layout under the flag).
            let bounds = stack.bounds();
            let margins = if unsafe { stack.isLayoutMarginsRelativeArrangement() } {
                stack.layoutMargins()
            } else {
                objc2_ui_kit::UIEdgeInsets {
                    top: 0.0,
                    left: 0.0,
                    bottom: 0.0,
                    right: 0.0,
                }
            };
            let inner = if vertical {
                bounds.size.height - margins.top - margins.bottom
            } else {
                bounds.size.width - margins.left - margins.right
            };
            let mut min_start = f64::MAX;
            let mut max_end = f64::MIN;
            for child in unsafe { stack.arrangedSubviews() } {
                use objc2::Message;
                if core
                    .filler_ptrs
                    .contains(&(Retained::as_ptr(&child.retain()) as usize))
                {
                    continue;
                }
                let frame = child.frame();
                let (start, extent) = if vertical {
                    (frame.origin.y, frame.size.height)
                } else {
                    (frame.origin.x, frame.size.width)
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
            let Some(root) = core.root else {
                return "nothing mounted".to_owned();
            };
            let view = core.widgets.get(&root).expect("root outlives the scene").view();
            core.content.layoutIfNeeded();
            let frame = view.frame();
            let area = core.content.safeAreaLayoutGuide().layoutFrame();
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
