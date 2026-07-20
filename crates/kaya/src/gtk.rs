//! GTK4 backend, milestone 1: an interpreter of resolved apply-ops.
//!
//! Same architecture as the AppKit backend: the core owns the main
//! thread and the GLib main loop; transactions resolve through the scene
//! core into Create/SetProp/AddChild/Mount ops mapped onto gtk4::Box,
//! Button, and Label. The clicked signal pushes an occurrence carrying
//! the widget id and never calls app code; glib::idle_add (g_idle_add)
//! is the doorbell, carrying no data.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::mpsc::Receiver;

use gtk4::glib;
use gtk4::prelude::*;

use crate::protocol::{
    ApplyOp, CommandKind, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind,
};
use crate::scene::Scene;

/// Where a child's grow weight is parked so the layout manager can find
/// it. GTK's own channel for per-child layout data is a `GtkLayoutChild`
/// subclass, which would mean a second GObject type and a factory method
/// on the manager; a keyed data item on the child widget carries the one
/// f64 we need with none of that, and lives and dies with the widget.
const GROW_KEY: &str = "kaya-grow";

fn grow_weight(widget: &gtk4::Widget) -> f64 {
    // SAFETY: the key is private to this module and only ever set to an
    // f64 by set_grow_weight below.
    unsafe {
        widget
            .data::<f64>(GROW_KEY)
            .map(|p| *p.as_ref())
            .unwrap_or(0.0)
    }
}

fn set_grow_weight(widget: &gtk4::Widget, weight: f64) {
    // SAFETY: as above — this is the only writer of the key.
    unsafe { widget.set_data(GROW_KEY, weight) }
}

/// Install the flex layout manager on a container the first time one of
/// its children grows.
///
/// Lazy on purpose. GtkBox lays out perfectly well on its own and does
/// it the way GTK apps do; the only thing it cannot say is "divide the
/// leftover 1:3". So the toolkit keeps the layout until a scene asks
/// for that, and containers that never grow anything never leave GTK's
/// own behaviour. The manager takes the spacing with it, since it owns
/// the gaps once installed.
fn ensure_flex(container: &gtk4::Widget) {
    let Some(container_box) = container.downcast_ref::<gtk4::Box>() else {
        return;
    };
    if container_box
        .layout_manager()
        .and_then(|l| l.downcast::<flex::FlexLayout>().ok())
        .is_some()
    {
        return;
    }
    let orientation = container_box.orientation();
    container_box.set_layout_manager(Some(flex::FlexLayout::new(orientation, 8)));
}

/// Reconcile a child's main-axis alignment with its weight.
///
/// Without this, `grow` on GTK would silently do nothing. GTK applies a
/// widget's own halign/valign *inside* the rect its parent allocated, so
/// a grower still carrying the normalized `Start` alignment would be
/// handed its full share and then shrink itself back to natural size
/// within it — the layout manager's arithmetic correct and completely
/// invisible. `Fill` on the main axis is what makes a child actually
/// occupy what it was given; the cross axis keeps `Start`, which is the
/// normalized default and what makes labels read left-aligned rather
/// than centered in a stretched box.
fn reconcile_grow_align(child: &gtk4::Widget) {
    let Some(parent) = child.parent() else { return };
    // The axis comes from our own manager, never from
    // GtkBox::orientation: once ensure_flex has replaced the box layout,
    // that property belongs to a manager that is no longer there. No
    // flex manager means nothing in this container grows, so there is no
    // alignment to reconcile.
    let Some(layout) = parent.layout_manager() else {
        return;
    };
    let Some(flex) = layout.downcast_ref::<flex::FlexLayout>() else {
        return;
    };
    let fill_or_start = if grow_weight(child) > 0.0 {
        gtk4::Align::Fill
    } else {
        gtk4::Align::Start
    };
    match flex.orientation() {
        gtk4::Orientation::Vertical => child.set_valign(fill_or_start),
        _ => child.set_halign(fill_or_start),
    }
}

/// The flex layout manager: GTK's half of the `grow` contract.
///
/// GtkBox cannot express this. Its only knob is the boolean
/// `hexpand`/`vexpand`, and extra space is split *equally* among the
/// children that set it — there is no per-child weight anywhere in the
/// widget, so a 1:3 request is not merely awkward to spell, it is
/// unrepresentable. Hence a real layout manager, which is also the
/// GTK-blessed way to add a layout policy rather than fighting one.
///
/// The policy is the one on [`Prop::Grow`]: weight-0 children take their
/// natural main-axis size, and the growers divide what is left in
/// proportion to their weights, their own natural sizes not entering the
/// division.
mod flex {
    use gtk4::glib;
    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;

    pub struct FlexLayoutInner {
        pub orientation: std::cell::Cell<gtk4::Orientation>,
        pub spacing: std::cell::Cell<i32>,
    }

    // Hand-written rather than derived: gtk4::Orientation has no Default,
    // and ObjectSubclass requires one because GObject constructs the
    // instance before any of our code runs. FlexLayout::new overwrites
    // both fields immediately.
    impl Default for FlexLayoutInner {
        fn default() -> Self {
            Self {
                orientation: std::cell::Cell::new(gtk4::Orientation::Vertical),
                spacing: std::cell::Cell::new(0),
            }
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for FlexLayoutInner {
        const NAME: &'static str = "KayaFlexLayout";
        type Type = FlexLayout;
        type ParentType = gtk4::LayoutManager;
    }

    impl ObjectImpl for FlexLayoutInner {}

    impl FlexLayoutInner {
        fn is_main(&self, orientation: gtk4::Orientation) -> bool {
            orientation == self.orientation.get()
        }
    }

    impl LayoutManagerImpl for FlexLayoutInner {
        fn measure(
            &self,
            widget: &gtk4::Widget,
            orientation: gtk4::Orientation,
            for_size: i32,
        ) -> (i32, i32, i32, i32) {
            let (mut minimum, mut natural, mut count) = (0, 0, 0);
            let mut child = widget.first_child();
            while let Some(c) = child {
                if c.is_visible() {
                    let (cmin, cnat, _, _) = c.measure(orientation, for_size);
                    if self.is_main(orientation) {
                        // Along the axis the children queue on, extents
                        // add up; across it they overlap, so the widest
                        // child sets the requirement.
                        minimum += cmin;
                        natural += cnat;
                    } else {
                        minimum = minimum.max(cmin);
                        natural = natural.max(cnat);
                    }
                    count += 1;
                }
                child = c.next_sibling();
            }
            if self.is_main(orientation) && count > 1 {
                let gaps = self.spacing.get() * (count - 1);
                minimum += gaps;
                natural += gaps;
            }
            (minimum, natural, -1, -1)
        }

        fn allocate(&self, widget: &gtk4::Widget, width: i32, height: i32, baseline: i32) {
            let vertical = self.orientation.get() == gtk4::Orientation::Vertical;
            let (main_total, cross_total) = if vertical {
                (height, width)
            } else {
                (width, height)
            };

            // Pass 1: what the non-growers need, and the weight pool.
            let mut children = Vec::new();
            let mut child = widget.first_child();
            while let Some(c) = child {
                if c.is_visible() {
                    let weight = super::grow_weight(&c);
                    let natural = if weight > 0.0 {
                        // A grower's own natural size is deliberately not
                        // consulted: the contract is flex-basis 0, so it
                        // starts from nothing and lives on its share.
                        0
                    } else {
                        c.measure(self.orientation.get(), -1).1
                    };
                    children.push((c.clone(), weight, natural));
                }
                child = c.next_sibling();
            }
            if children.is_empty() {
                return;
            }
            let gaps = self.spacing.get() * (children.len() as i32 - 1);
            let fixed: i32 = children.iter().map(|(_, _, nat)| *nat).sum();
            let leftover = (main_total - fixed - gaps).max(0);
            let pool: f64 = children.iter().map(|(_, w, _)| *w).sum();

            // Pass 2: place them. The growers' shares are handed out
            // exactly, without clamping to their minimum sizes — the
            // split is the contract, while what a too-small container
            // should do is the overflow policy DESIGN still defers. A
            // clamp here would silently turn 1:3 into something else in
            // a tight window, which is the one failure this whole verb
            // exists to catch.
            let mut offset = 0;
            let mut spent = 0;
            let growers = children.iter().filter(|(_, w, _)| *w > 0.0).count();
            let mut seen = 0;
            for (c, weight, natural) in &children {
                let extent = if *weight > 0.0 {
                    seen += 1;
                    if seen == growers {
                        // The last grower absorbs the rounding dust, so
                        // the children always fill the container exactly
                        // instead of leaving a stray pixel.
                        leftover - spent
                    } else {
                        let share = (leftover as f64 * weight / pool).round() as i32;
                        spent += share;
                        share
                    }
                } else {
                    *natural
                };
                let (w, h, x, y) = if vertical {
                    (cross_total, extent, 0, offset)
                } else {
                    (extent, cross_total, offset, 0)
                };
                let transform = gtk4::gsk::Transform::new()
                    .translate(&gtk4::graphene::Point::new(x as f32, y as f32));
                c.allocate(w, h, baseline, Some(transform));
                offset += extent + self.spacing.get();
            }
        }
    }

    glib::wrapper! {
        pub struct FlexLayout(ObjectSubclass<FlexLayoutInner>)
            @extends gtk4::LayoutManager;
    }

    impl FlexLayout {
        pub fn new(orientation: gtk4::Orientation, spacing: i32) -> Self {
            let this: Self = glib::Object::new();
            this.imp().orientation.set(orientation);
            this.imp().spacing.set(spacing);
            this
        }

        /// The axis this manager stacks on — the authority now that the
        /// GtkBoxLayout that used to own the property has been replaced.
        pub fn orientation(&self) -> gtk4::Orientation {
            self.imp().orientation.get()
        }
    }

    /// Read a child's main-axis extent as the manager allocated it.
    ///
    /// The allocation, not `width()`/`height()`: those report the CSS
    /// box, which the theme insets inside the allocation — Adwaita takes
    /// 10pt out of a button's height — so they answer "how big is the
    /// widget drawn" when the layout contract asks "how much of the axis
    /// was it given". Reading them turned an exactly correct 25/75 split
    /// into 27/73. Same trap as AppKit's alignment rect versus frame,
    /// and the reason child_shares specifies the layout rect everywhere.
    pub fn child_extent(child: &gtk4::Widget, vertical: bool) -> f64 {
        let allocation = child.allocation();
        if vertical {
            f64::from(allocation.height())
        } else {
            f64::from(allocation.width())
        }
    }
}

enum NativeWidget {
    Column(gtk4::Box),
    Button(gtk4::Button),
    Label(gtk4::Label),
    Entry(gtk4::Entry),
    Row(gtk4::Box),
    Checkbox(gtk4::CheckButton),
    Slider(gtk4::Scale),
    Image(gtk4::Picture),
}

impl NativeWidget {
    fn widget(&self) -> gtk4::Widget {
        match self {
            NativeWidget::Column(w) => w.clone().upcast(),
            NativeWidget::Button(w) => w.clone().upcast(),
            NativeWidget::Label(w) => w.clone().upcast(),
            NativeWidget::Entry(w) => w.clone().upcast(),
            NativeWidget::Row(w) => w.clone().upcast(),
            NativeWidget::Checkbox(w) => w.clone().upcast(),
            NativeWidget::Slider(w) => w.clone().upcast(),
            NativeWidget::Image(w) => w.clone().upcast(),
        }
    }
}

struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    widgets: HashMap<WidgetId, NativeWidget>,
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index. GTK fires the real
    // signals for programmatic set_text/set_active/set_value, so the
    // stage drives each control exactly as a user would.
    buttons: Vec<gtk4::Button>,
    checkboxes: Vec<gtk4::CheckButton>,
    labels: Vec<gtk4::Label>,
    entries: Vec<gtk4::Entry>,
    sliders: Vec<gtk4::Scale>,
    images: Vec<gtk4::Picture>,
    columns: Vec<gtk4::Box>,
    window: gtk4::Window,
    // None when attached... not yet on GTK; the app quits the loop.
    app: Option<gtk4::Application>,
}

impl Drop for CoreState {
    fn drop(&mut self) {
        self.occurrences.send(Occurrence::Shutdown);
    }
}

thread_local! {
    static CORE: RefCell<Option<CoreState>> = const { RefCell::new(None) };
}

static EXIT_CODE: AtomicI32 = AtomicI32::new(0);

/// Wake the main loop so it drains pending transactions. Safe to call
/// from any thread; the idle source carries no data.
pub(crate) fn ring_doorbell() {
    glib::idle_add(|| {
        drain_transactions();
        glib::ControlFlow::Break
    });
}

fn drain_transactions() {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        while let Ok(tx) = core.transactions.try_recv() {
            for op in core.scene.apply(tx) {
                apply(core, op);
            }
        }
    });
}

fn apply(core: &mut CoreState, op: ApplyOp) {
    match op {
        ApplyOp::Create { id, kind, tag } => {
            let native = match kind {
                WidgetKind::Entry => {
                    // Uncontrolled: the widget owns its text; each edit
                    // goes up with the entry's identity tag, and the
                    // app folds it into its own model. (GTK fires
                    // `changed` for programmatic set_text too, which is
                    // what lets the selftest type like a user.)
                    let entry = gtk4::Entry::new();
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("entries carry a tag");
                    entry.connect_changed(move |e| {
                        sink.send_text_tag(&tag, e.text().as_str());
                    });
                    core.entries.push(entry.clone());
                    NativeWidget::Entry(entry)
                }
                WidgetKind::Column => {
                    // Normalized layout default (uniform across backends):
                    // 8-unit spacing between children; the box hugs the
                    // top-left of its parent (Start/Start) rather than
                    // centering/filling. Children are pinned to the
                    // leading edge at natural size on add (see AddChild).
                    let column = gtk4::Box::new(gtk4::Orientation::Vertical, 8);
                    column.set_halign(gtk4::Align::Start);
                    column.set_valign(gtk4::Align::Start);
                    // No flex manager yet, deliberately: GtkBox's own
                    // layout stays until a child actually carries a
                    // weight (see ensure_flex). Replacing it eagerly
                    // would put every scene through our arithmetic and
                    // throw away GTK's own behaviour, when the point is
                    // that each platform flows like itself.
                    core.columns.push(column.clone());
                    NativeWidget::Column(column)
                }
                WidgetKind::Row => {
                    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
                    row.set_halign(gtk4::Align::Start);
                    row.set_valign(gtk4::Align::Start);
                    NativeWidget::Row(row)
                }
                WidgetKind::Checkbox => {
                    // The box owns its checked bit; each flip goes up
                    // with the box's identity tag. (GTK fires `toggled`
                    // for programmatic set_active too, which is what
                    // lets the selftest click like a user.)
                    let check = gtk4::CheckButton::new();
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("checkboxes carry a tag");
                    check.connect_toggled(move |c| {
                        sink.send_toggle_tag(&tag, c.is_active());
                    });
                    core.checkboxes.push(check.clone());
                    NativeWidget::Checkbox(check)
                }
                WidgetKind::Slider => {
                    // Uncontrolled, like the entry: the slider owns its
                    // position; each change goes up with its identity
                    // tag. (GTK fires `value-changed` for programmatic
                    // set_value too, which is what lets the selftest
                    // drag like a user.)
                    let scale =
                        gtk4::Scale::with_range(gtk4::Orientation::Horizontal, 0.0, 1.0, 0.01);
                    scale.set_size_request(160, -1);
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("sliders carry a tag");
                    scale.connect_value_changed(move |sc| {
                        sink.send_value_tag(&tag, sc.value());
                    });
                    core.sliders.push(scale.clone());
                    NativeWidget::Slider(scale)
                }
                WidgetKind::Button => {
                    let button = gtk4::Button::new();
                    let sink = core.occurrences.clone();
                    // The tag is the click's identity, emitted verbatim;
                    // this backend never learns what it means.
                    let tag = tag.expect("buttons carry a click tag");
                    button.connect_clicked(move |_| {
                        sink.send_click_tag(&tag);
                    });
                    core.buttons.push(button.clone());
                    NativeWidget::Button(button)
                }
                WidgetKind::Label => {
                    let label = gtk4::Label::new(None);
                    core.labels.push(label.clone());
                    NativeWidget::Label(label)
                }
                WidgetKind::Image => {
                    // Display-only, like Label: no tag, no signal. The
                    // source arrives as a SetProp blob and decodes
                    // there.
                    let picture = gtk4::Picture::new();
                    core.images.push(picture.clone());
                    NativeWidget::Image(picture)
                }
            };
            core.widgets.insert(id, native);
        }
        ApplyOp::MoveChild {
            parent,
            child,
            before,
        } => {
            use gtk4::prelude::WidgetExt;
            let parent_box = match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(b) | NativeWidget::Row(b) => b.clone(),
                _ => panic!("kaya: move_child parent is not a container"),
            };
            let child_widget = core
                .widgets
                .get(&child)
                .expect("scene validated the id")
                .widget();
            // gtk speaks after-semantics; before(anchor) = after(anchor's
            // previous sibling), and None (end) = after the last child.
            let after = match before {
                Some(anchor) => core
                    .widgets
                    .get(&anchor)
                    .expect("scene validated the id")
                    .widget()
                    .prev_sibling(),
                None => parent_box.last_child(),
            };
            if after.as_ref() != Some(&child_widget) {
                parent_box.reorder_child_after(&child_widget, after.as_ref());
            }
        }
        ApplyOp::Destroy { id } => {
            let widget = core
                .widgets
                .remove(&id)
                .expect("scene validated the id")
                .widget();
            if let Some(parent) = widget.parent() {
                if let Ok(column) = parent.downcast::<gtk4::Box>() {
                    column.remove(&widget);
                }
            }
        }
        ApplyOp::SetProp { id, prop, value } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match (widget, prop, value) {
                (NativeWidget::Button(button), Prop::Text, Value::Str(s)) => {
                    button.set_label(&s);
                }
                (NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {
                    label.set_text(&s);
                }
                (NativeWidget::Entry(entry), Prop::Text, Value::Str(s)) => {
                    entry.set_text(&s);
                }
                (NativeWidget::Checkbox(check), Prop::Text, Value::Str(s)) => {
                    check.set_label(Some(&s));
                }
                (NativeWidget::Checkbox(check), Prop::Checked, Value::Bool(b)) => {
                    check.set_active(b);
                }
                (NativeWidget::Slider(scale), Prop::Value, Value::F64(v)) => {
                    scale.set_value(v);
                }
                (NativeWidget::Slider(scale), Prop::Min, Value::F64(v)) => {
                    scale.adjustment().set_lower(v);
                }
                (NativeWidget::Slider(scale), Prop::Max, Value::F64(v)) => {
                    scale.adjustment().set_upper(v);
                }
                // Kind-agnostic, like the prop itself: the weight rides
                // on the widget and the parent's flex manager reads it
                // at allocate time.
                (w, Prop::Grow, Value::F64(weight)) => {
                    let widget = w.widget();
                    set_grow_weight(&widget, weight);
                    // The first positive weight in this container is what
                    // takes the layout away from GtkBox.
                    if weight > 0.0 {
                        if let Some(parent) = widget.parent() {
                            ensure_flex(&parent);
                        }
                    }
                    reconcile_grow_align(&widget);
                    // The split belongs to the whole sibling set, so the
                    // parent re-runs, not just this child.
                    if let Some(parent) = widget.parent() {
                        parent.queue_resize();
                    }
                }
                (NativeWidget::Image(picture), Prop::Source, Value::Blob(blob)) => {
                    // Encoded bytes in, native decode:
                    // gdk::Texture::from_bytes reads encoded PNG/JPEG.
                    // A failed decode yields the placeholder class (no
                    // paintable, image_size reads 0x0), never a panic.
                    let bytes = gtk4::glib::Bytes::from(&blob.0[..]);
                    match gtk4::gdk::Texture::from_bytes(&bytes) {
                        Ok(texture) => picture.set_paintable(Some(&texture)),
                        Err(_) => picture.set_paintable(gtk4::gdk::Paintable::NONE),
                    }
                }
                (_, prop, value) => {
                    panic!("kaya: gtk cannot apply {prop:?} = {value:?} here")
                }
            }
        }
        ApplyOp::AddChild { parent, child } => {
            let child_widget = core
                .widgets
                .get(&child)
                .expect("scene validated the id")
                .widget();
            // Normalized layout default: children sit at natural size on
            // the leading edge. GtkWidget's default halign is Fill, which
            // stretches a child to the full cross-axis extent (and makes
            // labels read as centered-in-fill); Start pins it left/top at
            // its intrinsic size instead.
            child_widget.set_halign(gtk4::Align::Start);
            child_widget.set_valign(gtk4::Align::Start);
            match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(column) => column.append(&child_widget),
                NativeWidget::Row(row) => row.append(&child_widget),
                _ => panic!("kaya: add_child parent is not a container"),
            }
            // Only now is the parent — and so the main axis — known, so
            // a weight that arrived before the child was attached gets
            // its manager and alignment here rather than being dropped.
            if grow_weight(&child_widget) > 0.0 {
                match core.widgets.get(&parent).expect("scene validated the id") {
                    NativeWidget::Column(c) => ensure_flex(c.upcast_ref()),
                    NativeWidget::Row(r) => ensure_flex(r.upcast_ref()),
                    _ => {}
                }
            }
            reconcile_grow_align(&child_widget);
        }
        ApplyOp::Mount { window: _, root } => {
            let root_widget = core
                .widgets
                .get(&root)
                .expect("scene validated the id")
                .widget();
            // The root fills its window, as it does on every other
            // backend — AppKit's contentView and UIKit's root view fill
            // by construction, while a GTK child obeys its own align and
            // would otherwise hug its content in the top-left corner.
            // Without this there is no leftover space anywhere in the
            // tree, so every grow weight in the scene divides nothing.
            root_widget.set_halign(gtk4::Align::Fill);
            root_widget.set_valign(gtk4::Align::Fill);
            core.window.set_child(Some(&root_widget));
        }
        ApplyOp::Command { id, command } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match command {
                CommandKind::Clear => {
                    let NativeWidget::Entry(entry) = widget else {
                        panic!("kaya: clear on a non-entry (scene validates kinds)")
                    };
                    // GTK fires `changed` for programmatic set_text (the
                    // Create arm's comment), so the empty edit reaches
                    // the app through the entry's own path — no manual
                    // emit, unlike AppKit's compensation.
                    entry.set_text("");
                }
                CommandKind::Focus => {
                    // grab_focus is per-window (the toplevel's focus
                    // widget), so parallel tiled suite legs cannot
                    // steal each other's focus assertions.
                    widget.widget().grab_focus();
                }
            }
        }
    }
}

fn request_exit(code: i32) {
    EXIT_CODE.store(code, Ordering::Relaxed);
    CORE.with_borrow(|core| {
        let Some(core) = core.as_ref() else { return };
        match &core.app {
            Some(app) => app.quit(),
            None => std::process::exit(code),
        }
    });
}

/// The main-thread half, independent of who owns the app thread. Returns
/// the exit code; the host process decides how to exit.
pub(crate) fn run_core(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> i32 {
    let app = gtk4::Application::builder()
        .application_id("dev.kaya.Milestone2")
        .build();

    // activate can fire more than once; the core is set up once.
    let ends = Rc::new(RefCell::new(Some((occ_tx, tx_rx))));
    app.connect_activate(move |app| {
        let Some((occ_tx, tx_rx)) = ends.borrow_mut().take() else {
            return;
        };
        let window = gtk4::ApplicationWindow::builder()
            .application(app)
            .title("kaya milestone 2")
            .default_width(320)
            .default_height(160)
            .build();
        window.present();

        if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
            crate::harness::spawn(&scene, GtkStage, |line| println!("{line}"));
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
                window: window.upcast(),
                app: Some(app.clone()),
            });
        });

        // The first transaction may already be queued; drain now.
        drain_transactions();
    });

    let _ = app.run_with_args::<&str>(&[]);

    // GTK teardown is orderly; dropping CoreState here announces shutdown
    // through its Drop impl.
    CORE.with_borrow_mut(|core| {
        core.take();
    });
    EXIT_CODE.load(Ordering::Relaxed)
}

/// The harness stage: GTK's native calls, each hopping to the main
/// context. Programmatic set_text/set_active/set_value fire the real
/// signals, so every step travels the path a user's gesture would.
struct GtkStage;

impl GtkStage {
    fn on_main<T: Send + 'static>(
        f: impl FnOnce(&CoreState) -> T + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        let cell = std::cell::Cell::new(Some((f, tx)));
        glib::idle_add(move || {
            if let Some((f, tx)) = cell.take() {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            glib::ControlFlow::Break
        });
        rx.recv().expect("the main context applied the step")
    }
}

impl crate::harness::Stage for GtkStage {
    fn click(&self, t: crate::harness::Target) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.buttons.len());
            core.buttons[i].emit_clicked();
        });
    }

    fn toggle(&self, t: crate::harness::Target, on: bool) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.checkboxes.len());
            core.checkboxes[i].set_active(on);
        });
    }

    fn set_value(&self, t: crate::harness::Target, value: f64) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.sliders.len());
            core.sliders[i].set_value(value);
        });
    }

    fn set_text(&self, t: crate::harness::Target, text: &str) {
        let text = text.to_owned();
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.entries.len());
            core.entries[i].set_text(&text);
        });
    }

    fn read_label(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.labels.len());
            core.labels[i].text().to_string()
        })
    }

    fn read_text(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.entries.len());
            core.entries[i].text().to_string()
        })
    }

    fn image_size(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.images.len());
            // The paintable's intrinsic size, in pixels for a texture;
            // no paintable is the placeholder class, "0x0".
            match core.images[i].paintable() {
                Some(paintable) => format!(
                    "{}x{}",
                    paintable.intrinsic_width(),
                    paintable.intrinsic_height()
                ),
                None => "0x0".into(),
            }
        })
    }

    fn is_focused(&self, t: crate::harness::Target) -> bool {
        Self::on_main(move |core| {
            // A focused GtkEntry delegates to its internal GtkText, so
            // the entry itself is never the toplevel's focus widget
            // (is_focus() stays false) — FOCUS_WITHIN is the flag GTK
            // sets on the ancestors of the focus widget, and it stays
            // per-window (key status not required).
            match t.kind {
                crate::harness::TargetKind::Entry => {
                    let i = crate::harness::resolve(t.index, core.entries.len());
                    core.entries[i]
                        .state_flags()
                        .intersects(gtk4::StateFlags::FOCUSED | gtk4::StateFlags::FOCUS_WITHIN)
                }
                other => panic!("kaya: is_focused not wired for {other:?} on gtk"),
            }
        })
    }

    fn child_texts(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::{Cast, WidgetExt};
            let i = crate::harness::resolve(t.index, core.columns.len());
            // Child order as the toolkit holds it — the registries are
            // creation-ordered and cannot observe a move.
            let mut texts = Vec::new();
            let mut child = core.columns[i].first_child();
            while let Some(widget) = child {
                if let Some(label) = widget.downcast_ref::<gtk4::Label>() {
                    if core.labels.iter().any(|l| l == label) {
                        texts.push(label.text().to_string());
                    }
                }
                child = widget.next_sibling();
            }
            texts.join("|")
        })
    }

    fn child_shares(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::WidgetExt;
            let i = crate::harness::resolve(t.index, core.columns.len());
            let column = &core.columns[i];
            // Pending resizes must land before the sizes mean anything;
            // otherwise the first read after mount sees zeros.
            while glib::MainContext::default().iteration(false) {}
            // Vertical because the target kind is Column, matching the
            // other backends: only columns are registered.
            let mut extents = Vec::new();
            let mut child = column.first_child();
            while let Some(widget) = child {
                extents.push(flex::child_extent(&widget, true));
                child = widget.next_sibling();
            }
            crate::harness::shares(&extents)
        })
    }

    fn finish(&self, code: i32, verdict: &str) {
        if code == 0 {
            println!("{verdict}");
        } else {
            eprintln!("{verdict}");
        }
        // request_exit reads the main thread's CORE; hop before asking.
        Self::on_main(move |_| request_exit(code));
    }
}
