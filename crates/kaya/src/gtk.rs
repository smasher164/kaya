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
    ApplyOp, CommandKind, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind, WindowProp, WindowId,
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

/// A container's align mode (the align spec enum's wire values), same
/// object-data pattern as the grow weight: AddChild reads it to stamp
/// children that arrive after the prop did.
const ALIGN_KEY: &str = "kaya-align";

fn container_align(widget: &gtk4::Widget) -> i64 {
    // SAFETY: the key is private to this module and only ever set to
    // an i64 by set_container_align below.
    unsafe {
        widget
            .data::<i64>(ALIGN_KEY)
            .map(|p| *p.as_ref())
            .unwrap_or(0)
    }
}

fn set_container_align(widget: &gtk4::Widget, mode: i64) {
    // SAFETY: as above — this is the only writer of the key.
    unsafe { widget.set_data(ALIGN_KEY, mode) }
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
/// Stamp one child's CROSS-axis alignment from its container's align
/// mode. Grow reconciliation owns the MAIN axis (Fill for growers);
/// this owns the other one, so the two never fight. Baseline maps to
/// GTK's native baseline valign (rows only; the scene rejects it on
/// columns at the root).
fn apply_cross_align(child: &gtk4::Widget, vertical_container: bool, mode: i64) {
    use gtk4::prelude::WidgetExt;
    let align = match mode {
        1 => gtk4::Align::Center,
        2 => gtk4::Align::End,
        3 => gtk4::Align::Fill,
        4 => gtk4::Align::Baseline,
        _ => gtk4::Align::Start,
    };
    if vertical_container {
        // A column's cross axis is horizontal.
        child.set_halign(align);
    } else {
        child.set_valign(align);
    }
}

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
    Scroll(gtk4::ScrolledWindow),
    Progress(gtk4::ProgressBar),
    Select(gtk4::DropDown),
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
            NativeWidget::Scroll(w) => w.clone().upcast(),
            NativeWidget::Progress(w) => w.clone().upcast(),
            NativeWidget::Select(w) => w.clone().upcast(),
        }
    }
}

/// One navigation entry: a pushed scene root, retained while covered
/// (the widget refs here keep it alive), destroyed at pop.
struct GtkNavEntry {
    window: u64,
    title: String,
    /// The close-veto class transplanted to POP.
    intercept_back: bool,
    root: Option<gtk4::Widget>,
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
    scrolls: Vec<gtk4::ScrolledWindow>,
    progresses: Vec<gtk4::ProgressBar>,
    selects: Vec<gtk4::DropDown>,
    /// Option-label plumbing: label widget id -> (its select's id,
    /// its option row). A select's label children are its OPTIONS —
    /// rows of the DropDown's StringList, not standalone widgets —
    /// so their text lands in the model, and they leave the
    /// harness's label registry.
    select_options: HashMap<u64, (u64, u32)>,
    /// The DropDown's string model per select id (rows appended at
    /// AddChild; text arrives via the label's SetProp).
    select_models: HashMap<u64, gtk4::StringList>,
    /// Echo guard for EVERY interactive kind: GTK's change signals
    /// (changed, toggled, value-changed, notify::selected) cannot
    /// tell a user act from a programmatic write, and only the USER
    /// path may emit an occurrence — a property write is state
    /// configuration, never an event (without this, a handler that
    /// writes back a different value than it received ping-pongs
    /// through the native signal forever). Armed around every
    /// SetProp write to an interactive widget and the select's
    /// model appends (GTK auto-selects row 0 when the first item
    /// lands). Commands (clear) and the harness stage's direct
    /// writes stay unguarded ON PURPOSE: a command acts like the
    /// user, and both must reach the app through the widget's own
    /// path.
    apply_quiet: std::rc::Rc<std::cell::Cell<bool>>,
    /// Indeterminate bars pulse on a shared ticker (GTK's activity
    /// mode is pulse-driven, not a property); membership here IS the
    /// indeterminate flag the observation reads.
    indeterminate: std::rc::Rc<RefCell<std::collections::HashSet<u64>>>,
    columns: Vec<gtk4::Box>,
    rows: Vec<gtk4::Box>,
    window: gtk4::Window,
    /// Auxiliary surfaces by kaya window id (the primary is
    /// `window`); created hidden, presented at mount.
    aux_windows: HashMap<u64, gtk4::Window>,
    /// veto_close per window id (primary included; default false).
    window_veto: std::rc::Rc<RefCell<HashMap<u64, bool>>>,
    /// Live navigation entries by surface id, and per-window stacks
    /// bottom to top (DESIGN.md, Navigation): the top entry is the
    /// window's visible child; the window's own root and title come
    /// back when its stack empties.
    nav_entries: HashMap<u64, GtkNavEntry>,
    nav_stacks: HashMap<u64, Vec<u64>>,
    /// The window's OWN mounted root and title, restored on pop.
    window_roots: HashMap<u64, gtk4::Widget>,
    window_titles: HashMap<u64, String>,
    /// The header-bar back button per window — GTK's back affordance
    /// (the ViewSwitcher-era header pattern); visible only while the
    /// window's stack has entries.
    back_buttons: HashMap<u64, gtk4::Button>,
    /// The live modal alert (one per process): the request's identity
    /// plus the REAL dialog object for the runner's reads. Shared with
    /// the choose callback, which clears it when the one result fires.
    live_alert: std::rc::Rc<RefCell<Option<GtkLiveAlert>>>,
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

/// The chrome-close grammar: a veto_close window emits
/// close_requested and stays; a non-veto auxiliary closes and
/// reports window_closed; the non-veto primary exits with the app
/// (GTK quits when the application window closes).
/// The live alert's identity and its REAL dialog: title reads come
/// from the AlertDialog object, and choose_alert finds the presented
/// dialog window's actual button to activate.
struct GtkLiveAlert {
    id: u64,
    window: u64,
    actions: usize,
    /// Button labels in presentation order (actions first, cancel
    /// last) — how choose_alert names the button to press.
    labels: Vec<String>,
    dialog: gtk4::AlertDialog,
}

/// Depth-first search for a button with the given label under a
/// widget — how the runner presses the REAL button inside the
/// presented alert window (gtk::AlertDialog exposes no press API).
fn find_button(widget: &gtk4::Widget, label: &str) -> Option<gtk4::Button> {
    use gtk4::prelude::{ButtonExt, Cast, WidgetExt};
    if let Ok(button) = widget.clone().downcast::<gtk4::Button>() {
        if button.label().as_deref() == Some(label) {
            return Some(button);
        }
    }
    let mut child = widget.first_child();
    while let Some(c) = child {
        if let Some(found) = find_button(&c, label) {
            return Some(found);
        }
        child = c.next_sibling();
    }
    None
}

fn wire_close(
    window: &gtk4::Window,
    id: u64,
    veto: std::rc::Rc<RefCell<HashMap<u64, bool>>>,
    sink: OccSink,
) {
    use gtk4::glib;
    use gtk4::prelude::GtkWindowExt;
    window.connect_close_request(move |_| {
        if veto.borrow().get(&id).copied().unwrap_or(false) {
            sink.send(Occurrence::CloseRequested {
                window: WindowId(id),
            });
            return glib::Propagation::Stop;
        }
        if id != 0 {
            sink.send(Occurrence::WindowClosed {
                window: WindowId(id),
            });
        }
        glib::Propagation::Proceed
    });
}

fn gtk_window(core: &CoreState, id: u64) -> gtk4::Window {
    if id == 0 {
        core.window.clone()
    } else {
        core.aux_windows
            .get(&id)
            .expect("harness targeted an unknown window")
            .clone()
    }
}

/// Install the window's navigation chrome: a HeaderBar whose back
/// button is GTK's back affordance (the ViewSwitcher-era header
/// pattern). Hidden until the window's stack has entries; the click
/// runs the SAME user-pop path a real press does, so the harness's
/// `back` verb can drive the actual button.
fn install_nav_chrome(window: &gtk4::Window, id: u64) -> gtk4::Button {
    use gtk4::prelude::{ButtonExt, GtkWindowExt, WidgetExt};
    let header = gtk4::HeaderBar::new();
    let back = gtk4::Button::from_icon_name("go-previous-symbolic");
    back.set_visible(false);
    back.connect_clicked(move |_| {
        CORE.with_borrow_mut(|core| {
            let Some(core) = core.as_mut() else { return };
            user_back(core, id);
        });
    });
    header.pack_start(&back);
    window.set_titlebar(Some(&header));
    back
}

/// A user-driven back on the window's top entry: an
/// intercept_back-armed top emits back_requested and nothing pops
/// (the veto class); an unarmed top pops here, reconciles the
/// core-owned stack post-fact, and reports entry_popped.
fn user_back(core: &mut CoreState, window: u64) {
    let Some(&top) = core.nav_stacks.get(&window).and_then(|s| s.last()) else {
        return;
    };
    if core.nav_entries[&top].intercept_back {
        core.occurrences.send(Occurrence::BackRequested {
            entry: WindowId(top),
        });
        return;
    }
    core.nav_stacks.get_mut(&window).unwrap().pop();
    core.nav_entries.remove(&top);
    core.scene.user_popped(WindowId(top));
    refresh_nav(core, window);
    core.occurrences.send(Occurrence::EntryPopped {
        entry: WindowId(top),
    });
}

/// Reconcile the window's visible state with its stack: the top
/// entry's root and title (the entry title IS the window title while
/// covered, the NavigationStack semantic), or the window's own root
/// and title when the stack is empty; the back button shows only
/// over entries.
fn refresh_nav(core: &mut CoreState, window: u64) {
    use gtk4::prelude::{GtkWindowExt, WidgetExt};
    let target = gtk_window(core, window);
    let top = core.nav_stacks.get(&window).and_then(|s| s.last()).copied();
    match top.and_then(|id| core.nav_entries.get(&id)) {
        Some(entry) => {
            if let Some(root) = &entry.root {
                target.set_child(Some(root));
            }
            target.set_title(Some(&entry.title));
        }
        None => {
            target.set_child(core.window_roots.get(&window));
            let own = core.window_titles.get(&window).cloned().unwrap_or_default();
            target.set_title(Some(&own));
        }
    }
    if let Some(back) = core.back_buttons.get(&window) {
        back.set_visible(top.is_some());
    }
}

fn apply(core: &mut CoreState, op: ApplyOp) {
    match op {
        ApplyOp::Create { id, kind, tag } => {
            let native = match kind {
                WidgetKind::Entry => {
                    // Uncontrolled: the widget owns its text; each edit
                    // goes up with the entry's identity tag, and the
                    // app folds it into its own model. GTK fires
                    // `changed` for programmatic set_text too, so the
                    // USER/programmatic split rides apply_quiet: the
                    // stage's direct writes and the clear command
                    // emit like a user; SetProp stays silent.
                    let entry = gtk4::Entry::new();
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("entries carry a tag");
                    let quiet = core.apply_quiet.clone();
                    entry.connect_changed(move |e| {
                        if !quiet.get() {
                            sink.send_text_tag(&tag, e.text().as_str());
                        }
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
                    core.rows.push(row.clone());
                    NativeWidget::Row(row)
                }
                WidgetKind::Checkbox => {
                    // The box owns its checked bit; each flip goes up
                    // with the box's identity tag. GTK fires `toggled`
                    // for programmatic set_active too — the
                    // USER/programmatic split rides apply_quiet (see
                    // that field).
                    let check = gtk4::CheckButton::new();
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("checkboxes carry a tag");
                    let quiet = core.apply_quiet.clone();
                    check.connect_toggled(move |c| {
                        if !quiet.get() {
                            sink.send_toggle_tag(&tag, c.is_active());
                        }
                    });
                    core.checkboxes.push(check.clone());
                    NativeWidget::Checkbox(check)
                }
                WidgetKind::Slider => {
                    // Uncontrolled, like the entry: the slider owns its
                    // position; each change goes up with its identity
                    // tag. GTK fires `value-changed` for programmatic
                    // set_value too — the USER/programmatic split
                    // rides apply_quiet (see that field).
                    let scale =
                        gtk4::Scale::with_range(gtk4::Orientation::Horizontal, 0.0, 1.0, 0.01);
                    scale.set_size_request(160, -1);
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("sliders carry a tag");
                    let quiet = core.apply_quiet.clone();
                    scale.connect_value_changed(move |sc| {
                        if !quiet.get() {
                            sink.send_value_tag(&tag, sc.value());
                        }
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
                WidgetKind::Scroll => {
                    // The vertical scroll viewport over its ONE child
                    // (the scene enforces the count):
                    // GtkScrolledWindow, the platform's own machinery
                    // — its vadjustment is both the observation
                    // source and the API scroll_end drives.
                    let scrolled = gtk4::ScrolledWindow::new();
                    // Vertical-only v1: no horizontal bar, ever.
                    scrolled.set_policy(gtk4::PolicyType::Never, gtk4::PolicyType::Automatic);
                    core.scrolls.push(scrolled.clone());
                    NativeWidget::Scroll(scrolled)
                }
                WidgetKind::Progress => {
                    // Display-only, like Label: no tag, no signal.
                    // Determinate = set_fraction; indeterminate =
                    // GTK's pulse mode, driven by a ticker while the
                    // prop is on (see the SetProp arm).
                    let bar = gtk4::ProgressBar::new();
                    core.progresses.push(bar.clone());
                    NativeWidget::Progress(bar)
                }
                WidgetKind::Select => {
                    // The dressed floor: GtkDropDown over a
                    // StringList — the select's label children are
                    // its OPTIONS, rows of this model (see AddChild).
                    // Uncontrolled like the slider: each USER pick
                    // goes up with the identity tag; programmatic
                    // writes ride the quiet guard because
                    // notify::selected cannot tell the two apart.
                    let model = gtk4::StringList::new(&[]);
                    let dropdown =
                        gtk4::DropDown::new(Some(model.clone()), gtk4::Expression::NONE);
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("selects carry a tag");
                    let quiet = core.apply_quiet.clone();
                    dropdown.connect_selected_notify(move |dd| {
                        if !quiet.get() && dd.selected() != gtk4::INVALID_LIST_POSITION {
                            sink.send_value_tag(&tag, f64::from(dd.selected()));
                        }
                    });
                    core.select_models.insert(id.0, model);
                    core.selects.push(dropdown.clone());
                    NativeWidget::Select(dropdown)
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
        ApplyOp::SetWindowProp { window, prop, value } => {
            use gtk4::prelude::GtkWindowExt;
            let target = if window.0 == 0 {
                core.window.clone()
            } else {
                core.aux_windows
                    .get(&window.0)
                    .expect("scene validated the window id")
                    .clone()
            };
            match (prop, &value) {
                (WindowProp::Title, Value::Str(title)) => {
                    // The window's OWN title; while a navigation
                    // entry covers it the entry's title shows (the
                    // NavigationStack semantic), and this one comes
                    // back at pop.
                    core.window_titles.insert(window.0, title.clone());
                    let covered = core
                        .nav_stacks
                        .get(&window.0)
                        .is_some_and(|s| !s.is_empty());
                    if !covered {
                        target.set_title(Some(title));
                    }
                }
                // The advisory size request. GTK4's one public size
                // verb is set_default_size; under the suites' X11 WM
                // it resizes a mapped window too, and the WM (or a
                // Wayland compositor) keeps the last word — exactly
                // the request semantics (DESIGN.md, Presentation
                // contexts).
                (WindowProp::Width, Value::F64(w)) => {
                    let (_, h) = target.default_size();
                    target.set_default_size(*w as i32, h);
                }
                (WindowProp::Height, Value::F64(h)) => {
                    let (w, _) = target.default_size();
                    target.set_default_size(w, *h as i32);
                }
                (WindowProp::VetoClose, Value::Bool(on)) => {
                    core.window_veto.borrow_mut().insert(window.0, *on);
                }
                (p, v) => unreachable!("scene validated window prop {p:?}/{v:?}"),
            }
        }
        ApplyOp::CreateWindow { window } => {
            // Materializes hidden; mounting a root presents it. The
            // normalized 540x330 default and the root inset ride the
            // same paths the primary uses.
            use gtk4::prelude::GtkWindowExt;
            let aux = gtk4::Window::builder()
                .default_width(540)
                .default_height(330)
                .build();
            let back = install_nav_chrome(&aux, window.0);
            core.back_buttons.insert(window.0, back);
            wire_close(
                &aux,
                window.0,
                core.window_veto.clone(),
                core.occurrences.clone(),
            );
            core.aux_windows.insert(window.0, aux);
        }
        ApplyOp::DestroyWindow { window } => {
            use gtk4::prelude::GtkWindowExt;
            if let Some(aux) = core.aux_windows.remove(&window.0) {
                // destroy() skips close_request: no spurious
                // window_closed for an app-initiated close.
                aux.destroy();
            }
            core.window_veto.borrow_mut().remove(&window.0);
            // A destroyed window takes its navigation stack with it.
            for entry in core.nav_stacks.remove(&window.0).unwrap_or_default() {
                core.nav_entries.remove(&entry);
            }
            core.window_roots.remove(&window.0);
            core.window_titles.remove(&window.0);
            core.back_buttons.remove(&window.0);
        }
        ApplyOp::PushEntry { window, entry } => {
            // Materializes covered/incoming: on the stack now, the
            // mount fills and presents it.
            core.nav_entries.insert(
                entry.0,
                GtkNavEntry {
                    window: window.0,
                    title: String::new(),
                    intercept_back: false,
                    root: None,
                },
            );
            core.nav_stacks.entry(window.0).or_default().push(entry.0);
        }
        ApplyOp::PopEntry { window } => {
            // Programmatic pop: the core already reconciled its
            // stack; drop the top and reconcile the visible state
            // (the batch's NET change shows once drained).
            let top = core
                .nav_stacks
                .get_mut(&window.0)
                .and_then(|s| s.pop())
                .expect("scene validated the pop");
            core.nav_entries.remove(&top);
            refresh_nav(core, window.0);
        }
        ApplyOp::SetEntryProp { entry, prop, value } => {
            use crate::protocol::EntryProp;
            let record = core
                .nav_entries
                .get_mut(&entry.0)
                .expect("scene validated the entry id");
            match (prop, &value) {
                (EntryProp::Title, Value::Str(title)) => {
                    record.title = title.clone();
                }
                (EntryProp::InterceptBack, Value::Bool(on)) => {
                    record.intercept_back = *on;
                }
                (p, v) => unreachable!("scene validated entry prop {p:?}/{v:?}"),
            }
            let window = record.window;
            if core.nav_stacks.get(&window).and_then(|s| s.last()) == Some(&entry.0) {
                refresh_nav(core, window);
            }
        }
        ApplyOp::PresentAlert(spec) => {
            // The platform's REAL modal dialog: gtk::AlertDialog maps
            // the vocabulary 1:1 (buttons in order, cancel-button
            // index, async choose -> index). Answered exactly once
            // through capi::alert_resolved — the shared retire path.
            let parent = gtk_window(core, spec.window.0);
            let mut labels: Vec<String> = spec.actions.clone();
            labels.push(spec.cancel.clone());
            let actions_n = spec.actions.len();
            let dialog = gtk4::AlertDialog::builder()
                .message(&spec.title)
                .detail(&spec.message)
                .buttons(labels.iter().map(String::as_str).collect::<Vec<_>>())
                .cancel_button(actions_n as i32)
                .default_button(0)
                .modal(true)
                .build();
            let alert_id = spec.alert.0;
            *core.live_alert.borrow_mut() = Some(GtkLiveAlert {
                id: alert_id,
                window: spec.window.0,
                actions: actions_n,
                labels,
                dialog: dialog.clone(),
            });
            let live = core.live_alert.clone();
            // The result must ride THIS backend's sink (the guest
            // listens there — Mpsc for a Rust guest, the ring for a
            // C one); capi::alert_retire is only the liveness gate.
            let sink = core.occurrences.clone();
            dialog.choose(
                Some(&parent),
                None::<&gtk4::gio::Cancellable>,
                move |result| {
                    // Esc/close resolve to the cancel index; any
                    // index at or past the action count IS the
                    // cancel slot.
                    let index = result.unwrap_or(actions_n as i32);
                    let choice = if (index as usize) < actions_n {
                        crate::protocol::AlertChoice::Action(index as u32)
                    } else {
                        crate::protocol::AlertChoice::Cancel
                    };
                    *live.borrow_mut() = None;
                    crate::capi::alert_retire(alert_id);
                    sink.send(Occurrence::AlertResult {
                        alert: crate::protocol::AlertId(alert_id),
                        choice,
                    });
                },
            );
        }
        ApplyOp::SetProp { id, prop, value } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match (widget, prop, value) {
                (NativeWidget::Button(button), Prop::Text, Value::Str(s)) => {
                    button.set_label(&s);
                }
                (NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {
                    label.set_text(&s);
                    // An option label's text lands in its DropDown
                    // row (the model is what the popup and the
                    // collapsed button both render).
                    if let Some((select, row)) = core.select_options.get(&id.0) {
                        core.apply_quiet.set(true);
                        core.select_models[select].splice(*row, 1, &[&s]);
                        core.apply_quiet.set(false);
                    }
                }
                (NativeWidget::Entry(entry), Prop::Text, Value::Str(s)) => {
                    // Quiet: a property write is configuration, not a
                    // user edit (see apply_quiet).
                    core.apply_quiet.set(true);
                    entry.set_text(&s);
                    core.apply_quiet.set(false);
                }
                (NativeWidget::Checkbox(check), Prop::Text, Value::Str(s)) => {
                    check.set_label(Some(&s));
                }
                (NativeWidget::Checkbox(check), Prop::Checked, Value::Bool(b)) => {
                    core.apply_quiet.set(true);
                    check.set_active(b);
                    core.apply_quiet.set(false);
                }
                (NativeWidget::Slider(scale), Prop::Value, Value::F64(v)) => {
                    core.apply_quiet.set(true);
                    scale.set_value(v);
                    core.apply_quiet.set(false);
                }
                (NativeWidget::Select(dropdown), Prop::Value, Value::F64(v)) => {
                    // A programmatic write is quiet (uniform
                    // semantics: only the user path emits).
                    core.apply_quiet.set(true);
                    dropdown.set_selected(v as u32);
                    core.apply_quiet.set(false);
                }
                (NativeWidget::Progress(bar), Prop::Value, Value::F64(v)) => {
                    bar.set_fraction(v);
                }
                (NativeWidget::Progress(bar), Prop::Indeterminate, Value::Bool(on)) => {
                    // GTK's activity mode is pulse-driven, not a
                    // property: a ticker pulses every armed bar; the
                    // membership set is also what the observation
                    // reads. Turning it off restores the fraction
                    // display (set_fraction repaints the bar).
                    let key = id.0;
                    let mut armed = core.indeterminate.borrow_mut();
                    if on {
                        if armed.insert(key) {
                            let bar = bar.clone();
                            let set = core.indeterminate.clone();
                            glib::timeout_add_local(
                                std::time::Duration::from_millis(100),
                                move || {
                                    if set.borrow().contains(&key) {
                                        bar.pulse();
                                        glib::ControlFlow::Continue
                                    } else {
                                        glib::ControlFlow::Break
                                    }
                                },
                            );
                        }
                    } else {
                        armed.remove(&key);
                        bar.set_fraction(bar.fraction());
                    }
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
                (NativeWidget::Column(container), Prop::Spacing, Value::F64(gap))
                | (NativeWidget::Row(container), Prop::Spacing, Value::F64(gap)) => {
                    // The container's own inter-child gap; the flex
                    // manager reads the Box spacing at allocate time,
                    // so both layout paths follow it.
                    container.set_spacing(gap.round() as i32);
                }
                (NativeWidget::Column(container), Prop::Align, Value::I64(mode)) => {
                    use gtk4::prelude::WidgetExt;
                    let container = container.clone().upcast::<gtk4::Widget>();
                    set_container_align(&container, mode);
                    let mut child = container.first_child();
                    while let Some(widget) = child {
                        apply_cross_align(&widget, true, mode);
                        child = widget.next_sibling();
                    }
                }
                (NativeWidget::Row(container), Prop::Align, Value::I64(mode)) => {
                    use gtk4::prelude::WidgetExt;
                    let container = container.clone().upcast::<gtk4::Widget>();
                    set_container_align(&container, mode);
                    let mut child = container.first_child();
                    while let Some(widget) = child {
                        apply_cross_align(&widget, false, mode);
                        child = widget.next_sibling();
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
            // A select's label children are its OPTIONS: rows of the
            // DropDown's model, never widgets in a container. The
            // native label stays unparented (its SetProp text lands
            // in the model row) and leaves the harness's label
            // registry — options are the select's data, so they must
            // not shift every later label's index. The append rides
            // the quiet guard: GTK auto-selects row 0 when the first
            // item lands, and that notify is not a user pick.
            if let NativeWidget::Select(_) = core.widgets.get(&parent).expect("scene validated the id")
            {
                // The row initializes from the label's CURRENT text:
                // children-first sugars (OCaml, Haskell) set the text
                // BEFORE this AddChild, so an empty-row default would
                // miss it (caught live on linux, 2026-07-22 — every
                // ocaml/haskell row read ""). The splice in SetProp
                // covers writes that arrive after.
                let text = match core.widgets.get(&child).expect("scene validated the id") {
                    NativeWidget::Label(l) => {
                        let l = l.clone();
                        core.labels.retain(|x| x != &l);
                        l.text().to_string()
                    }
                    _ => String::new(),
                };
                let model = &core.select_models[&parent.0];
                let row = model.n_items();
                core.apply_quiet.set(true);
                model.append(&text);
                core.apply_quiet.set(false);
                core.select_options.insert(child.0, (parent.0, row));
                return;
            }
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
            // ... then the container's align mode overrides the cross
            // axis for children arriving after the prop did.
            match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(c) => apply_cross_align(
                    &child_widget,
                    true,
                    container_align(c.clone().upcast_ref::<gtk4::Widget>()),
                ),
                NativeWidget::Row(c) => apply_cross_align(
                    &child_widget,
                    false,
                    container_align(c.clone().upcast_ref::<gtk4::Widget>()),
                ),
                _ => {}
            }
            match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(column) => column.append(&child_widget),
                NativeWidget::Row(row) => row.append(&child_widget),
                // The viewport's one child (the scene rejects a
                // second): the content fills the viewport's width and
                // scrolls on its own height.
                NativeWidget::Scroll(scrolled) => {
                    child_widget.set_halign(gtk4::Align::Fill);
                    scrolled.set_child(Some(&child_widget));
                }
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
        ApplyOp::Mount { window, root } => {
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
            root_widget.add_css_class("kaya-root");
            // The target is a SURFACE: a navigation entry presents
            // in-window (the push already stacked it; the mount fills
            // it), the primary is the window's own root, an auxiliary
            // presents its window.
            if let Some(entry) = core.nav_entries.get_mut(&window.0) {
                entry.root = Some(root_widget);
                let host = entry.window;
                if core.nav_stacks.get(&host).and_then(|s| s.last()) == Some(&window.0) {
                    refresh_nav(core, host);
                }
            } else if window.0 == 0 {
                core.window.set_child(Some(&root_widget));
                core.window_roots.insert(0, root_widget);
            } else {
                use gtk4::prelude::GtkWindowExt;
                let aux = core
                    .aux_windows
                    .get(&window.0)
                    .expect("scene validated the window id");
                aux.set_child(Some(&root_widget));
                // Mounting presents.
                aux.present();
                core.window_roots.insert(window.0, root_widget);
            }
        }
        ApplyOp::Command { id, command } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match command {
                CommandKind::Clear => {
                    let NativeWidget::Entry(entry) = widget else {
                        panic!("kaya: clear on a non-entry (scene validates kinds)")
                    };
                    // A command ACTS LIKE THE USER (unlike a property
                    // write): apply_quiet stays off here on purpose, so
                    // GTK's `changed` carries the empty edit to the app
                    // through the entry's own path — the entry scene's
                    // second-add round depends on exactly this echo.
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
            .default_width(540)
            .default_height(330)
            .build();
        // The normalized root inset: 16 units INSIDE the root, via the
        // CSS box (padding sits inside the allocation, so the root
        // still fills its window and expect_root_fills holds — margins
        // would shrink the allocation instead and break it). The class
        // is stamped on the mounted root in the Mount arm.
        let css = gtk4::CssProvider::new();
        css.load_from_data(".kaya-root { padding: 16px; }");
        if let Some(display) = gtk4::gdk::Display::default() {
            gtk4::style_context_add_provider_for_display(
                &display,
                &css,
                gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }
        let primary_back = {
            use gtk4::prelude::Cast;
            install_nav_chrome(window.upcast_ref::<gtk4::Window>(), 0)
        };
        window.present();

        if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
            crate::harness::spawn(&scene, GtkStage, |line| println!("{line}"));
        }

        CORE.with_borrow_mut(|core| {
            *core = Some(CoreState {
                transactions: tx_rx,
                scene: Scene::new(),
                occurrences: occ_tx.clone(),
                aux_windows: HashMap::new(),
                nav_entries: HashMap::new(),
                nav_stacks: HashMap::new(),
                window_roots: HashMap::new(),
                window_titles: {
                    use gtk4::prelude::GtkWindowExt;
                    let mut titles = HashMap::new();
                    titles.insert(
                        0,
                        window.title().map(String::from).unwrap_or_default(),
                    );
                    titles
                },
                back_buttons: {
                    let mut buttons = HashMap::new();
                    buttons.insert(0, primary_back);
                    buttons
                },
                live_alert: std::rc::Rc::new(RefCell::new(None)),
                window_veto: {
                    let veto = std::rc::Rc::new(RefCell::new(HashMap::new()));
                    {
                        use gtk4::prelude::Cast;
                        wire_close(
                            window.upcast_ref::<gtk4::Window>(),
                            0,
                            veto.clone(),
                            occ_tx.clone(),
                        );
                    }
                    veto
                },
                widgets: HashMap::new(),
                buttons: Vec::new(),
                checkboxes: Vec::new(),
                labels: Vec::new(),
                entries: Vec::new(),
                sliders: Vec::new(),
                images: Vec::new(),
                scrolls: Vec::new(),
                progresses: Vec::new(),
                selects: Vec::new(),
                select_options: HashMap::new(),
                select_models: HashMap::new(),
                apply_quiet: std::rc::Rc::new(std::cell::Cell::new(false)),
                indeterminate: std::rc::Rc::new(RefCell::new(std::collections::HashSet::new())),
                columns: Vec::new(),
                rows: Vec::new(),
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
            let Some(i) = crate::harness::try_resolve(t.index, core.labels.len()) else {
                return "<no such target>".to_string();
            };
            core.labels[i].text().to_string()
        })
    }

    fn read_text(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.entries.len()) else {
                return "<no such target>".to_string();
            };
            core.entries[i].text().to_string()
        })
    }

    fn image_size(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.images.len()) else {
                return "<no such target>".to_string();
            };
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
                    let Some(i) = crate::harness::try_resolve(t.index, core.entries.len()) else {
                        return false;
                    };
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
            let registry = if matches!(t.kind, crate::harness::TargetKind::Column) {
                &core.columns
            } else {
                &core.rows
            };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return "<no such target>".to_string();
            };
            // Child order as the toolkit holds it — the registries are
            // creation-ordered and cannot observe a move.
            let mut texts = Vec::new();
            let mut child = registry[i].first_child();
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
            // Kind picks the registry and the axis: a column's
            // children split its height, a row's its width (the runner
            // rejects any other kind before it gets here).
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return "<no such target>".to_string();
            };
            let container = &registry[i];
            // Pending resizes must land before the sizes mean anything;
            // otherwise the first read after mount sees zeros.
            while glib::MainContext::default().iteration(false) {}
            let mut extents = Vec::new();
            let mut child = container.first_child();
            while let Some(widget) = child {
                extents.push(flex::child_extent(&widget, vertical));
                child = widget.next_sibling();
            }
            crate::harness::shares(&extents)
        })
    }

    fn container_fills(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::WidgetExt;
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return "<no such target>".to_string();
            };
            let container = &registry[i];
            while glib::MainContext::default().iteration(false) {}
            // width()/height() are ALREADY the content box on GTK4 —
            // CSS padding lives outside the widget's own coordinate
            // space, unlike every other backend here, and child
            // allocations are content-relative. Subtracting the
            // .kaya-root padding on top of that read a filling root as
            // 259px spanning 227px on the first Wayland run.
            let inner = if vertical {
                container.height()
            } else {
                container.width()
            };
            let mut min_start = i32::MAX;
            let mut max_end = i32::MIN;
            let mut child = container.first_child();
            while let Some(widget) = child {
                let alloc = widget.allocation();
                let (start, extent) = if vertical {
                    (alloc.y(), alloc.height())
                } else {
                    (alloc.x(), alloc.width())
                };
                min_start = min_start.min(start);
                max_end = max_end.max(start + extent);
                child = widget.next_sibling();
            }
            if max_end < min_start {
                return "no children".to_owned();
            }
            let span = max_end - min_start;
            if (span - inner).abs() <= 2 {
                String::new()
            } else {
                format!("children span {span}px of {inner}px")
            }
        })
    }

    fn cross_mode(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::WidgetExt;
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return "<no such target>".to_string();
            };
            let container = &registry[i];
            while glib::MainContext::default().iteration(false) {}
            // Cross axis: horizontal for a column, vertical for a row.
            // width()/height() are the content box and child
            // allocations are content-relative (the fills lesson), so
            // the cross box is 0..inner.
            let inner = if vertical { container.width() } else { container.height() };
            let mut rects: Vec<(i32, i32)> = Vec::new();
            let mut baselines: Vec<i32> = Vec::new();
            let mut child = container.first_child();
            while let Some(widget) = child {
                let alloc = widget.allocation();
                let (start, extent) = if vertical {
                    (alloc.x(), alloc.width())
                } else {
                    (alloc.y(), alloc.height())
                };
                rects.push((start, extent));
                if !vertical {
                    let b = widget.allocated_baseline();
                    if b >= 0 {
                        baselines.push(alloc.y() + b);
                    }
                }
                child = widget.next_sibling();
            }
            if rects.is_empty() {
                return "no children".to_owned();
            }
            let all = |f: &dyn Fn(&(i32, i32)) -> bool| rects.iter().all(f);
            // Baseline first: GTK 4.12 spells it BASELINE_FILL, so the
            // boxes legitimately fill the row too — but the box hands
            // children an allocated baseline ONLY under baseline
            // alignment (plain fill reads -1), which is the honest
            // discriminator stretch geometry cannot fake. PARTICIPATION
            // is the whole check: the reported values are not
            // comparable across widget kinds (a label reports the
            // box-allocated line, a button its content-relative one —
            // 37 vs 27 for a visually ALIGNED pair, screenshot-
            // verified), so the agreement itself is GTK's to keep,
            // the way root_fills leaves "content area" to each
            // platform's own notion.
            if !vertical && baselines.len() >= 2 {
                return "baseline".to_owned();
            }
            // Every geometric mode is tested; more than one match
            // means the scene's geometry cannot distinguish them, and
            // a first-match answer would let such a scene pass while
            // proving nothing — ambiguity fails loudly instead (the
            // separability lesson, made structural).
            let mut matches = Vec::new();
            if all(&|r| (r.1 - inner).abs() <= 2) {
                matches.push("stretch");
            }
            if all(&|r| r.0.abs() <= 2) {
                matches.push("start");
            }
            if all(&|r| ((2 * r.0 + r.1) - inner).abs() <= 4) {
                matches.push("center");
            }
            if all(&|r| ((r.0 + r.1) - inner).abs() <= 2) {
                matches.push("end");
            }
            match matches.as_slice() {
                [one] => (*one).to_owned(),
                // A baseline-looking row reading mixed is usually the
                // observation, not the geometry — name the allocated
                // count in the verdict (participation is GTK's
                // baseline signal).
                [] => {
                    let allocated = if vertical {
                        String::new()
                    } else {
                        format!("; {} baselines allocated", baselines.len())
                    };
                    format!("mixed (cross rects {rects:?} in {inner}px{allocated})")
                }
                many => format!("ambiguous ({})", many.join("|")),
            }
        })
    }

    fn window_title(&self, window: u64) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::GtkWindowExt;
            gtk_window(core, window)
                .title()
                .map(String::from)
                .unwrap_or_default()
        })
    }

    fn window_content_size(&self, window: u64) -> (f64, f64) {
        Self::on_main(move |core| {
            use gtk4::prelude::GtkWindowExt;
            // On a mapped toplevel default_size tracks the current
            // content size (X11; a Wayland compositor keeps its own
            // last word, the request semantics).
            let (w, h) = gtk_window(core, window).default_size();
            (f64::from(w), f64::from(h))
        })
    }

    fn close_window(&self, window: u64) {
        Self::on_main(move |core| {
            use gtk4::prelude::GtkWindowExt;
            // The REAL chrome path: close() runs close_request, so
            // the veto grammar fires exactly as a user click would.
            gtk_window(core, window).close();
        })
    }

    fn window_count(&self) -> usize {
        Self::on_main(move |core| 1 + core.aux_windows.len())
    }

    fn alert_title(&self, window: u64) -> Option<String> {
        Self::on_main(move |core| {
            let live = core.live_alert.borrow();
            live.as_ref()
                .filter(|a| a.window == window)
                // The REAL dialog object's message, never the
                // request's copy.
                .map(|a| a.dialog.message().to_string())
        })
    }

    fn choose_alert(&self, choice: u32) {
        Self::on_main(move |core| {
            use gtk4::prelude::{Cast, GtkWindowExt, WidgetExt};
            let live = core.live_alert.borrow();
            let Some(alert) = live.as_ref() else { return };
            let label = if choice == crate::wire::ALERT_CHOICE_CANCEL {
                alert.labels.last().cloned()
            } else {
                alert
                    .labels
                    .get(choice as usize)
                    .filter(|_| (choice as usize) < alert.actions)
                    .cloned()
            };
            let Some(label) = label else { return };
            // The REAL button inside the presented dialog window:
            // find the alert's own toplevel (transient-for our
            // window, not one of ours) and activate its button —
            // the same signal path a user's click runs.
            let parent = gtk_window(core, alert.window);
            for toplevel in gtk4::Window::list_toplevels() {
                let Ok(window) = toplevel.downcast::<gtk4::Window>() else {
                    continue;
                };
                if window.transient_for().as_ref() != Some(&parent) {
                    continue;
                }
                if let Some(button) = find_button(window.upcast_ref(), &label) {
                    use gtk4::prelude::WidgetExt as _;
                    let _ = button.activate();
                    return;
                }
            }
        })
    }

    fn entry_count(&self, window: u64) -> usize {
        Self::on_main(move |core| {
            core.nav_stacks.get(&window).map_or(0, Vec::len)
        })
    }

    fn back(&self, window: u64) {
        Self::on_main(move |core| {
            // The REAL affordance: activate the header bar's back
            // button — its click handler runs the same user-pop path
            // a pointer press does. Deferred one idle tick: the
            // handler re-borrows CORE, which this closure holds.
            if let Some(back) = core.back_buttons.get(&window).cloned() {
                glib::idle_add_local_once(move || {
                    use gtk4::prelude::ButtonExt;
                    back.emit_clicked();
                });
            }
        })
    }

    fn scroll_overflow(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.scrolls.len()) else {
                return "<no such target>".to_string();
            };
            // The toolkit's own adjustment: upper is the content
            // extent, page_size the viewport.
            let adj = core.scrolls[i].vadjustment();
            if adj.upper() > adj.page_size() + 2.0 {
                String::new()
            } else {
                format!("content {} in viewport {}", adj.upper(), adj.page_size())
            }
        })
    }

    fn scroll_end(&self, t: crate::harness::Target) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.scrolls.len());
            // The REAL scrolling API: setting the adjustment's value
            // IS how GTK scrolls (scrollbars and kinetic panning both
            // write it).
            let adj = core.scrolls[i].vadjustment();
            adj.set_value(adj.upper() - adj.page_size());
        })
    }

    fn progress_state(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.progresses.len()) else {
                return "<no such target>".to_string();
            };
            let bar = &core.progresses[i];
            // The REAL control's state: membership in the pulse set is
            // the indeterminate flag; the fraction is the bar's own.
            let armed = core
                .progresses
                .get(i)
                .map(|b| {
                    // Recover the widget id by identity against the
                    // registry order is unnecessary: the pulse set is
                    // keyed by widget id, so read it via the bar's
                    // kaya id stored at creation.
                    b.clone()
                })
                .is_some()
                && core
                    .indeterminate
                    .borrow()
                    .iter()
                    .any(|key| core.widgets.get(&WidgetId(*key)).is_some_and(|w| {
                        matches!(w, NativeWidget::Progress(p) if p == bar)
                    }));
            if armed {
                "indeterminate".to_string()
            } else {
                format!("{}%", (bar.fraction() * 100.0).round() as i64)
            }
        })
    }

    fn choose(&self, t: crate::harness::Target, index: usize) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.selects.len());
            // The REAL selection route: set_selected IS how GTK picks
            // (row activation in the popup writes it). The quiet
            // guard is off here, so notify::selected emits exactly as
            // a user pick does.
            core.selects[i].set_selected(index as u32);
        });
    }

    fn selected_label(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.selects.len()) else {
                return "<no such target>".to_string();
            };
            // The REAL control's state: the selected item out of the
            // DropDown's own model — what the collapsed button shows.
            core.selects[i]
                .selected_item()
                .and_then(|item| item.downcast::<gtk4::StringObject>().ok())
                .map(|s| s.string().to_string())
                .unwrap_or_default()
        })
    }

    fn scroll_at_end(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.scrolls.len()) else {
                return "<no such target>".to_string();
            };
            let adj = core.scrolls[i].vadjustment();
            let short = adj.upper() - (adj.value() + adj.page_size());
            if short.abs() <= 2.0 {
                String::new()
            } else {
                format!(
                    "content bottom {} vs viewport {}",
                    adj.value() + adj.page_size(),
                    adj.upper()
                )
            }
        })
    }

    fn alert_count(&self) -> usize {
        Self::on_main(move |core| usize::from(core.live_alert.borrow().is_some()))
    }

    fn root_fills(&self) -> String {
        Self::on_main(move |core| {
            use gtk4::prelude::{GtkWindowExt, WidgetExt};
            let Some(root) = core.window.child() else {
                return "nothing mounted".to_owned();
            };
            while glib::MainContext::default().iteration(false) {}
            let alloc = root.allocation();
            // The child's slot excludes whatever the window draws for
            // itself, and how much that is depends on the compositor:
            // Wayland CSD puts a ~39px headerbar above the child, bare
            // Xvfb draws nothing (the first cut compared against the
            // whole window widget and read a perfectly filling Wayland
            // root as a hug). So "fills" is edge-flush: from wherever
            // the slot starts, the allocation reaches the window's
            // left, right and bottom edges. A hugging child leaves the
            // bottom or right edge unreached and fails either way;
            // only the top edge is unknowable, since it is exactly
            // where the decoration lives.
            let (width, height) = (core.window.width(), core.window.height());
            // Within two pixels: rounding is not a hug.
            if alloc.x() <= 2
                && (alloc.x() + alloc.width() - width).abs() <= 2
                && (alloc.y() + alloc.height() - height).abs() <= 2
            {
                String::new()
            } else {
                format!(
                    "{}x{}px at ({},{}) inside {}x{}px",
                    alloc.width(),
                    alloc.height(),
                    alloc.x(),
                    alloc.y(),
                    width,
                    height,
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
        // request_exit reads the main thread's CORE; hop before asking.
        Self::on_main(move |_| request_exit(code));
    }
}
