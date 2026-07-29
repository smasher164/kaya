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

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;

use crate::protocol::{
    ApplyOp, CommandKind, MenuItemKind, MenuProp, OccSink, Occurrence, Prop, Transaction, Value,
    WidgetId, WidgetKind, WindowProp, WindowId,
};
use crate::scene::Scene;

/// Where a child's grow weight is parked so the layout manager can find
/// it. GTK's own channel for per-child layout data is a `GtkLayoutChild`
/// subclass, which would mean a second GObject type and a factory method
/// on the manager; a keyed data item on the child widget carries the one
/// f64 we need with none of that, and lives and dies with the widget.
const GROW_KEY: &str = "kaya-grow";

/// Guest-visible text uses LF as its line separator on every platform
/// (strings are compared byte-for-byte across languages). GTK's
/// Entry/TextView store pasted text verbatim — CR or CRLF from a paste
/// would ride into occurrence payloads and harness reads — so text is
/// normalized wherever it escapes toward the guest, the same boundary
/// discipline as WinUI's `lf` (whose TextBox speaks CR natively).
fn lf(s: String) -> String {
    if s.contains('\r') {
        s.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        s
    }
}

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
    Radio(gtk4::Box),
    Grid(gtk4::Grid),
    Textarea(gtk4::TextView),
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
            NativeWidget::Radio(w) => w.clone().upcast(),
            NativeWidget::Grid(w) => w.clone().upcast(),
            NativeWidget::Textarea(w) => w.clone().upcast(),
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

/// One section's materialized state: the stack page's container Box
/// (the mount target), its title, its own mounted root, and the
/// hosting window.
struct GtkSectionPage {
    window: u64,
    page: gtk4::Box,
    title: String,
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
    radios: Vec<gtk4::Box>,
    grids: Vec<gtk4::Grid>,
    textareas: Vec<gtk4::TextView>,
    /// Grid layout state: ordered children + column count. Children
    /// can arrive BEFORE the columns prop (children-first sugars),
    /// so both paths re-flow the attach positions.
    grid_children: HashMap<u64, Vec<gtk4::Widget>>,
    grid_cols: HashMap<u64, i32>,
    /// Radio plumbing, the select_options shape: label id -> (its
    /// radio's id, its row); the row's REAL widget is the grouped
    /// CheckButton in radio_buttons.
    radio_options: HashMap<u64, (u64, u32)>,
    radio_buttons: HashMap<u64, Vec<gtk4::CheckButton>>,
    radio_tags: HashMap<u64, Vec<u8>>,
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
    /// list_detail per window (wprop 6; DESIGN.md, Adaptive
    /// list-detail): does this window ASK for the adaptive
    /// presentation of its stack. Whether it GETS one is the size
    /// class's answer, resolved in refresh_nav.
    list_detail: HashMap<u64, bool>,
    /// The presentation refresh_nav ACTUALLY rendered, per window —
    /// stamped by the arm that ran, never derived from `list_detail`
    /// or the width, so expect_split cannot agree with the lowering by
    /// construction.
    split_presentation: HashMap<u64, &'static str>,
    /// The live AdwNavigationSplitView per window. It answers whether it
    /// collapsed, which is the only honest reading of which presentation
    /// happened once GNOME owns that decision.
    split_views: HashMap<u64, adw::NavigationSplitView>,
    /// Sections (DESIGN.md, Sections): per-window ordered sets, page
    /// containers by section id, the GtkStack that materializes the
    /// switcher, and the selection mirror. A section's page swaps
    /// between its own root and its stack's top entry (stacks are
    /// per-surface; nav_stacks keys sections too).
    sections: HashMap<u64, Vec<u64>>,
    section_pages: HashMap<u64, GtkSectionPage>,
    section_stacks: HashMap<u64, gtk4::Stack>,
    /// The assembled chrome per window: (presentation it was built
    /// for, the container) — rebuilt only when the hint changes.
    section_chrome: HashMap<u64, (i64, gtk4::Box)>,
    selected_sections: HashMap<u64, u64>,
    sections_presentation: HashMap<u64, i64>,
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
    /// The command-catalog registry (DESIGN.md, Menus): items, bars,
    /// anchors. Rc'd so the GSimpleAction handlers reach the mirror
    /// without borrowing CORE (see the menus section comment).
    menus: Rc<RefCell<MenuRegistry>>,
    /// The GMenu model per window — the object the PopoverMenuBar
    /// renders and menu_count reads; rebuilt in place on catalog
    /// mutations.
    menu_models: HashMap<u64, gio::Menu>,
    /// The bar strip per window: (strip, content slot). Present only
    /// once a catalog anchored; set_window_content routes through it.
    menu_strips: HashMap<u64, (gtk4::Box, gtk4::Box)>,
    /// Auxiliary windows' "win"-prefixed action groups (the primary is
    /// a GtkApplicationWindow and exports "win" itself).
    menu_action_groups: HashMap<u64, gio::SimpleActionGroup>,
    /// Context attachments by anchor widget id.
    context_menus: HashMap<u64, GtkContextMenu>,
    /// The OPEN context menu's anchor: taken by the gesture and the
    /// context_open verb, cleared by activation or chrome dismissal.
    /// While set it owns path resolution EXCLUSIVELY (the
    /// interpreters' rule). Rc'd: the popover's closed handler clears
    /// it without borrowing CORE.
    open_context: Rc<RefCell<Option<u64>>>,
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
    // With sections present, back routes to the ACTIVE section's
    // stack — back never switches sections (DESIGN.md, Sections).
    let window = if core.sections.contains_key(&window) {
        core.selected_sections.get(&window).copied().unwrap_or(window)
    } else {
        window
    };
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
    // A section host reconciles its PAGE, not a window (stacks are
    // per-surface; DESIGN.md, Sections).
    if core.section_pages.contains_key(&window) {
        refresh_section_pane(core, window);
        return;
    }
    let target = gtk_window(core, window);
    let top = core.nav_stacks.get(&window).and_then(|s| s.last()).copied();

    // ADAPTIVE LIST-DETAIL (DESIGN.md). Both halves must hold: the app
    // asked (wprop 6) and the window IS regular — the same 600
    // boundary every other backend draws, read off the real window
    // rather than derived from anything the app said.
    //
    // A plain horizontal Box, deliberately NOT GtkPaned: a paned is a
    // DRAGGABLE splitter, which DESIGN separates from list-detail by
    // name (2/4 native, not admitted). libadwaita's
    // AdwNavigationSplitView is the idiomatic wrapper — animations and
    // AdwBreakpoint for free — but this backend does not depend on
    // libadwaita, and the semantic is expressible without it. That
    // dependency is a ledger item, not a blocker.
    let wants_split = core.list_detail.get(&window).copied().unwrap_or(false);
    // No `top.is_some()` requirement: an empty stack on a regular
    // window shows the leading pane and an EMPTY trailing one
    // (DESIGN.md). Requiring an entry here made GTK report `stacked`
    // where mac reported `split` for the same scene — a semantics
    // divergence, which is never a backend's call to make.
    // NO width test here any more. AdwNavigationSplitView collapses on
    // a BREAKPOINT, and the condition is GNOME's documented one rather
    // than a number kaya invented and then graded itself against.
    if wants_split {
        use adw::prelude::*;
        let base = core.window_roots.get(&window).cloned();
        let detail = top.and_then(|id| core.nav_entries.get(&id)).and_then(|e| e.root.clone());
        if let Some(base) = base {
            let split = adw::NavigationSplitView::new();
            unparent(&base);
            // The sidebar pane is sized by libadwaita's OWN rule now:
            // sidebar-width-fraction with min/max, which is where
            // protocol::leading_pane_width's 25%/180..280 came from in
            // the first place. Adopting the widget means adopting the
            // source rather than the copy.
            let list = adw::NavigationPage::builder()
                .child(&base)
                .title(core.window_titles.get(&window).cloned().unwrap_or_default())
                .tag("list")
                .build();
            split.set_sidebar(Some(&list));
            if let Some(detail) = &detail {
                unparent(detail);
                let title = top
                    .and_then(|id| core.nav_entries.get(&id))
                    .map(|e| e.title.clone())
                    .unwrap_or_default();
                let page = adw::NavigationPage::builder()
                    .child(detail)
                    .title(title)
                    .tag("detail")
                    .build();
                split.set_content(Some(&page));
            }
            // show-content is the ONE stack fact the widget is told:
            // whether a detail is open. Everything else about the stack
            // stays in kaya's core, which is what keeps a pop and the
            // widget's pop from being two different truths.
            split.set_show_content(top.is_some());

            // The COLLAPSE decision, handed to GNOME. AdwNavigationSplitView
            // has no default of its own — libadwaita deliberately makes
            // the application declare the breakpoint — so kaya supplies
            // the condition from libadwaita's own documented example
            // rather than choosing a width. A BreakpointBin is what lets
            // a plain GtkApplicationWindow carry one; add_breakpoint
            // otherwise lives on AdwWindow, which this backend is not.
            let bin = adw::BreakpointBin::builder()
                .width_request(1)
                .height_request(1)
                .child(&split)
                .build();
            if let Ok(condition) = adw::BreakpointCondition::parse("max-width: 400sp") {
                let breakpoint = adw::Breakpoint::new(condition);
                breakpoint.add_setter(&split, "collapsed", Some(&true.to_value()));
                bin.add_breakpoint(breakpoint);
            }

            // The user's back, caught where libadwaita reports it.
            // Collapsed, its navigation view draws a back button whose
            // pop sets show-content false; that transition IS the
            // gesture, and it is distinguishable from a resize, which
            // moves `collapsed` and leaves show-content alone (measured
            // on libadwaita 1.7.6 before any of this was written).
            split.connect_show_content_notify(move |view| {
                if view.shows_content() {
                    return;
                }
                glib::idle_add_local_once(move || {
                    CORE.with_borrow_mut(|core| {
                        let Some(core) = core.as_mut() else { return };
                        if core.nav_stacks.get(&window).is_some_and(|s| !s.is_empty()) {
                            user_back(core, window);
                        }
                    });
                });
            });

            // THE BACK AFFORDANCE FOLLOWS THE COLLAPSE, and it has to be
            // driven from here rather than set once below: `collapsed`
            // is the BREAKPOINT's answer, and a breakpoint applies
            // during allocation — at the moment this arm builds the
            // view, nothing has been measured and `is_collapsed` is
            // still false. This is the same shape WinUI needed for
            // ModeChanged, for the same reason.
            //
            // Only the button's visibility, never the whole arm: this
            // fires from inside layout, and re-running the arm here
            // would build a fresh view whose own breakpoint applies and
            // fires it again.
            split.connect_collapsed_notify(move |view| {
                let collapsed = view.is_collapsed();
                // Deferred, like the handler above: this runs from
                // GTK's layout, and CORE may be borrowed by the apply
                // that caused it.
                glib::idle_add_local_once(move || {
                    CORE.with_borrow_mut(|core| {
                        let Some(core) = core.as_mut() else { return };
                        let covers =
                            core.nav_stacks.get(&window).is_some_and(|s| !s.is_empty());
                        if let Some(back) = core.back_buttons.get(&window) {
                            back.set_visible(collapsed && covers);
                        }
                    });
                });
            });

            set_window_content(core, window, Some(bin.upcast_ref::<gtk4::Widget>()));
            // WITH AN EMPTY STACK THE WINDOW KEEPS ITS OWN TITLE. This
            // used to fall back to the empty string, which is a window
            // with no title at all — the serial arm's None branch below
            // has always used window_titles for exactly this case, and
            // the split arm simply did not. Caught on macOS, where the
            // title bar is read for real and AppKit substitutes the
            // PROCESS NAME for an empty one (2026-07-27).
            let title = top
                .and_then(|id| core.nav_entries.get(&id))
                .map(|e| e.title.clone())
                .unwrap_or_else(|| {
                    core.window_titles.get(&window).cloned().unwrap_or_default()
                });
            target.set_title(Some(&title));
            let collapsed = split.is_collapsed();
            core.split_views.insert(window, split);
            // THE SAME RULE THE SERIAL ARM FOLLOWS: a back button
            // exactly where back reveals something. Two panes reveal
            // nothing, so it is absent there — that IS the two-pane
            // rule, and the harness's `back` refuses a hidden button
            // like any other.
            //
            // This used to hide the button for the whole presentation,
            // on the belief that libadwaita draws its own once
            // collapsed. IT DOES NOT: libadwaita draws that button
            // inside a header bar IT owns (an AdwHeaderBar in the page,
            // normally via AdwToolbarView), and these pages carry the
            // raw scene root. So a collapsed window had no back
            // affordance at all while `back` popped anyway — the
            // harness driving something the screen did not have, which
            // is exactly what the two-pane rule forbids in the other
            // direction. Caught by screenshotting the collapsed window;
            // no lane could see it, because no assertion reads whether
            // an affordance is THERE (docs/deferred.md).
            //
            // Best-effort here and authoritative in the notify handler
            // above: nothing is measured yet at build time, so this is
            // false on a first build and the breakpoint corrects it.
            if let Some(back) = core.back_buttons.get(&window) {
                back.set_visible(collapsed && top.is_some());
            }
            return;
        }
    }
    // The serial arm stamps too: an observation only one arm writes is
    // derived-by-default in the other (docs/traps.md).
    core.split_presentation.insert(window, "stacked");

    match top.and_then(|id| core.nav_entries.get(&id)) {
        Some(entry) => {
            if let Some(root) = entry.root.clone() {
                set_window_content(core, window, Some(&root));
            }
            let title = entry.title.clone();
            target.set_title(Some(&title));
        }
        None => {
            set_window_content(core, window, core.window_roots.get(&window).cloned().as_ref());
            let own = core.window_titles.get(&window).cloned().unwrap_or_default();
            target.set_title(Some(&own));
        }
    }
    if let Some(back) = core.back_buttons.get(&window) {
        back.set_visible(top.is_some());
    }
}

/// Assemble (or reassemble on a hint change) the window's sections
/// chrome: a GtkStack of section pages under the presentation's
/// switcher — the header StackSwitcher for auto/bar, GtkStackSidebar
/// for sidebar (the ADVISORY hint, resolved to this platform's
/// spellings). The stack's notify::visible-child is the USER route:
/// a switcher click lands there unguarded, reconciles the core, and
/// emits; programmatic selection rides the echo guard.
fn refresh_sections(core: &mut CoreState, window: u64) {
    use gtk4::prelude::{BoxExt, Cast, ObjectExt, WidgetExt};
    let ids = core.sections.get(&window).cloned().unwrap_or_default();
    if ids.is_empty() {
        return;
    }
    if !core.section_stacks.contains_key(&window) {
        let stack = gtk4::Stack::new();
        let quiet = core.apply_quiet.clone();
        let occurrences = core.occurrences.clone();
        stack.connect_notify_local(Some("visible-child"), move |st, _| {
            if quiet.get() {
                return;
            }
            let Some(name) = st.visible_child_name() else { return };
            let Ok(sid) = name.as_str().parse::<u64>() else { return };
            let mut changed = false;
            CORE.with_borrow_mut(|core| {
                let Some(core) = core.as_mut() else { return };
                if core.selected_sections.get(&window) == Some(&sid) {
                    return;
                }
                core.selected_sections.insert(window, sid);
                core.scene
                    .user_selected_section(WindowId(window), WindowId(sid));
                changed = true;
            });
            if changed {
                occurrences.send(Occurrence::SectionSelected {
                    window: WindowId(window),
                    section: WindowId(sid),
                });
            }
        });
        core.section_stacks.insert(window, stack);
    }
    let stack = core.section_stacks[&window].clone();
    for sid in &ids {
        let record = &core.section_pages[sid];
        if record.page.parent().is_none() {
            core.apply_quiet.set(true);
            stack.add_titled(&record.page, Some(&sid.to_string()), &record.title);
            core.apply_quiet.set(false);
        }
    }
    let hint = core
        .sections_presentation
        .get(&window)
        .copied()
        .unwrap_or(0);
    let rebuild = !matches!(core.section_chrome.get(&window), Some((h, _)) if *h == hint);
    if rebuild {
        if let Some(parent) = stack.parent() {
            if let Some(container) = parent.downcast_ref::<gtk4::Box>() {
                container.remove(&stack);
            }
        }
        stack.set_hexpand(true);
        stack.set_vexpand(true);
        let chrome = if hint == 2 {
            // sidebar: the leading-edge list spelling.
            let container = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
            let sidebar = gtk4::StackSidebar::new();
            sidebar.set_stack(&stack);
            container.append(&sidebar);
            container.append(&stack);
            container
        } else {
            // auto/bar: the header switcher, GTK's dominant idiom.
            let container = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
            let switcher = gtk4::StackSwitcher::new();
            switcher.set_stack(Some(&stack));
            switcher.set_halign(gtk4::Align::Center);
            container.append(&switcher);
            container.append(&stack);
            container
        };
        core.section_chrome.insert(window, (hint, chrome));
    }
    let chrome = core.section_chrome[&window].1.clone();
    set_window_content(core, window, Some(chrome.upcast_ref()));
    if let Some(sel) = core.selected_sections.get(&window).copied() {
        core.apply_quiet.set(true);
        stack.set_visible_child_name(&sel.to_string());
        core.apply_quiet.set(false);
    }
}

/// Reconcile a section page's visible child: its stack's top entry
/// root while covered (stacks are per-surface), its own mounted root
/// otherwise.
fn refresh_section_pane(core: &mut CoreState, sid: u64) {
    use gtk4::prelude::{BoxExt, WidgetExt};
    let Some(record) = core.section_pages.get(&sid) else { return };
    let top = core.nav_stacks.get(&sid).and_then(|s| s.last()).copied();
    let desired = top
        .and_then(|id| core.nav_entries.get(&id))
        .and_then(|e| e.root.clone())
        .or_else(|| record.root.clone());
    let page = record.page.clone();
    while let Some(child) = page.first_child() {
        page.remove(&child);
    }
    if let Some(widget) = desired {
        widget.set_hexpand(true);
        widget.set_vexpand(true);
        page.append(&widget);
    }
}

/// Re-attach a grid's children row-major per its current column
/// count — called when children or the columns prop arrive, in
/// either order (children-first sugars emit adds before the prop).
fn reflow_grid(core: &mut CoreState, grid_id: u64) {
    let Some(NativeWidget::Grid(grid)) = core.widgets.get(&crate::protocol::WidgetId(grid_id))
    else {
        return;
    };
    let cols = core.grid_cols.get(&grid_id).copied().unwrap_or(1).max(1);
    let children = core.grid_children.get(&grid_id).cloned().unwrap_or_default();
    for child in &children {
        if child.parent().is_some() {
            grid.remove(child);
        }
    }
    for (i, child) in children.iter().enumerate() {
        let i = i as i32;
        grid.attach(child, i % cols, i / cols, 1, 1);
    }
}

// --- Menus: the command vocabulary (DESIGN.md, Menus) -----------------
//
// The ratified GTK lowering: one GMenu model per window, rendered by a
// PopoverMenuBar in a strip ABOVE the mounted root (the header bar
// already carries nav chrome; the bar is its own row, the traditional
// Linux shape). Every actionable item is a real window-scoped
// GSimpleAction (`win.kmi-<id>`): enablement is set_enabled, a toggle
// is a stateful bool action, a radio group is ONE stateful action
// whose options are int targets — checkmarks and radio rendering come
// free from GMenu — and shortcuts ride set_accels_for_action, so
// accel display and key dispatch are both native. A context catalog is
// GtkPopoverMenu::from_model on a right-click GestureClick, its
// actions in a per-anchor group ("kayactx" on the anchor widget) so a
// stamped copy's occurrence carries THAT copy's key path — the noun is
// baked into the action's tag at attach time, exactly as stamped
// click tags are (the on_click_node encoding).
//
// One dispatch path: bar chrome, the context popover, accelerators,
// and the harness verbs all activate the same GSimpleAction, whose
// handler mirrors user state FIRST and then emits (docs/traps.md's
// post-user-mirror rule). Programmatic checked/value writes go through
// set_state, which never fires `activate` — the echo doctrine holds
// with no quiet guard. The handlers capture the Rc'd registry and the
// sink, never CORE, so a stage verb may activate them while it holds
// the CORE borrow (the same discipline as every widget signal here).

/// One menu item's retained state: the props mirror (the post-user
/// mirror toggles/radios update BEFORE emitting), the semantic tree,
/// and every live GSimpleAction instance materialized for the item —
/// the bar's window-scoped one, plus one per context attachment — so
/// enabled/checked/value writes reach all of them.
struct MenuItemState {
    kind: MenuItemKind,
    label: String,
    /// The item's OWN flag; what chrome and dispatch honor is the AND
    /// of this and every grouping ancestor's (docs/traps.md).
    enabled: bool,
    checked: bool,
    value: f64,
    /// The phone-promotion hint, mirrored for the record: INERT on
    /// desktop by design (DESIGN.md, Menus), so nothing here reads it.
    #[allow(dead_code)]
    primary: bool,
    shortcut: String,
    parent: Option<u64>,
    children: Vec<u64>,
    actions: Vec<gio::SimpleAction>,
}

/// The command-catalog registry. Rc'd so action handlers can reach the
/// mirror without touching CORE (see the section comment).
#[derive(Default)]
struct MenuRegistry {
    items: HashMap<u64, MenuItemState>,
    /// Top-level grouping nodes per window, in menubar-append order.
    bars: HashMap<u64, Vec<u64>>,
    /// Root item id -> the window whose bar holds it.
    bar_of: HashMap<u64, u64>,
    /// Root item id -> every widget carrying a context attachment
    /// rooted at it (a template catalog attaches to every stamped
    /// copy; a live-widget catalog to exactly one).
    context_of: HashMap<u64, Vec<u64>>,
}

/// One widget's context attachment: its own GMenu + popover + action
/// group, and the anchor copy's key path (empty on a live widget).
struct GtkContextMenu {
    roots: Vec<u64>,
    noun: Vec<Value>,
    model: gio::Menu,
    popover: gtk4::PopoverMenu,
    group: gio::SimpleActionGroup,
    /// This attachment's action instances by item id — the ones whose
    /// tags carry this anchor's noun.
    actions: HashMap<u64, gio::SimpleAction>,
}

/// Enablement is the AND of the item's own flag and every grouping
/// ancestor's — the inherited rule every read, render, accel, and
/// activation route shares (docs/traps.md).
fn menu_effective_enabled(reg: &MenuRegistry, id: u64) -> bool {
    let mut enabled = true;
    let mut current = Some(id);
    while let Some(item) = current {
        let state = &reg.items[&item];
        enabled = enabled && state.enabled;
        current = state.parent;
    }
    enabled
}

fn menu_root_of(reg: &MenuRegistry, id: u64) -> u64 {
    let mut current = id;
    while let Some(parent) = reg.items[&current].parent {
        current = parent;
    }
    current
}

fn menu_preorder(reg: &MenuRegistry, root: u64) -> Vec<u64> {
    let mut out = Vec::new();
    let mut stack = vec![root];
    while let Some(id) = stack.pop() {
        out.push(id);
        for &child in reg.items[&id].children.iter().rev() {
            stack.push(child);
        }
    }
    out
}

/// Resolve a `>`-joined label path SEMANTICALLY against root items,
/// labels compared byte-for-byte (the shared-scene contract). A
/// grouping root's label is a path segment whether or not the
/// materialization mints a titled row — an inline nested radio group
/// has none, yet "View>Sort>Date" still lands on Date. `"Sort>Date"`
/// is option Date inside group Sort; `"Sort"` is the group itself.
fn menu_resolve_path(reg: &MenuRegistry, roots: &[u64], path: &str) -> Option<u64> {
    let mut current: Vec<u64> = roots.to_vec();
    let mut found = None;
    for seg in path.split('>') {
        let id = current
            .iter()
            .copied()
            .find(|id| reg.items[id].label == seg)?;
        found = Some(id);
        current = reg.items[&id].children.clone();
    }
    found
}

/// Push inherited enablement into the REAL actions: every instance of
/// every item under `id` carries the AND of its own flag and its
/// ancestors', so native rendering (grayed rows), native dispatch (a
/// disabled GSimpleAction refuses activation), accelerators, and the
/// harness verbs all gate on one state. Grouping nodes have no GAction
/// of their own — GtkPopoverMenuBarItem binds only `label` from the
/// model, so a bar-level header has no sensitivity to bind (nested
/// submenu rows do, but graying only there would make GTK's own two
/// levels disagree). Their reads come from the registry, and the AND
/// below still reaches every command underneath.
fn menu_sync_enabled(reg: &MenuRegistry, id: u64) {
    fn walk(reg: &MenuRegistry, id: u64, inherited: bool) {
        let item = &reg.items[&id];
        let effective = inherited && item.enabled;
        for action in &item.actions {
            action.set_enabled(effective);
        }
        for &child in &item.children {
            walk(reg, child, effective);
        }
    }
    let inherited = reg.items[&id]
        .parent
        .map_or(true, |parent| menu_effective_enabled(reg, parent));
    walk(reg, id, inherited);
}

/// Mirror a radio group's selected index onto every option's action
/// state, in every instance (the bar's and each context attachment's).
/// A radio row is checked exactly when its action's state equals its
/// target, and every option targets its own index, so one shared value
/// drives the whole group's checkmarks.
fn menu_sync_radio_state(reg: &MenuRegistry, group: u64) {
    use gtk4::glib::prelude::ToVariant;
    let state = (reg.items[&group].value as i32).to_variant();
    for &option in &reg.items[&group].children {
        for action in &reg.items[&option].actions {
            action.set_state(&state);
        }
    }
}

/// Create the GSimpleAction for one item — the shared dispatch path's
/// one entry: chrome clicks, accelerators, and harness verbs all
/// activate THIS object, and only its handler emits. `noun` is the
/// anchor's key path (empty for the bar and live-widget anchors).
fn make_menu_action(core: &CoreState, id: u64, noun: &[Value]) -> Option<gio::SimpleAction> {
    use gtk4::glib::prelude::ToVariant;
    let reg = core.menus.borrow();
    let item = &reg.items[&id];
    // GAction names reject underscores; kmi-<id> stays inside the
    // [a-zA-Z0-9.-] floor for every id.
    let name = format!("kmi-{id}");
    debug_assert!(gio::Action::name_is_valid(&name));
    let menus = core.menus.clone();
    let sink = core.occurrences.clone();
    let tag = crate::wire::click_tag(id, noun);
    match item.kind {
        MenuItemKind::Action => {
            let action = gio::SimpleAction::new(&name, None);
            action.connect_activate(move |_, _| {
                sink.send_menu_activated_tag(&tag);
            });
            Some(action)
        }
        MenuItemKind::Toggle => {
            let action = gio::SimpleAction::new_stateful(&name, None, &item.checked.to_variant());
            action.connect_activate(move |_, _| {
                // Post-user mirror FIRST (docs/traps.md): the registry
                // and every sibling instance move, then the occurrence
                // goes up — a later rebuild starts from the user's
                // state.
                let checked = {
                    let mut reg = menus.borrow_mut();
                    let item = reg.items.get_mut(&id).expect("menu items are never removed");
                    item.checked = !item.checked;
                    let checked = item.checked;
                    for action in &item.actions {
                        action.set_state(&checked.to_variant());
                    }
                    checked
                };
                sink.send_menu_toggled_tag(&tag, checked);
            });
            Some(action)
        }
        MenuItemKind::RadioOption => {
            // One stateful action PER OPTION, not one per group. GTK
            // gives an item the radio role when the item carries a
            // target and its action carries state (gtkmenutrackeritem),
            // and it takes the row's sensitivity from that action's
            // enabled flag — which has no per-target form. So options
            // that shared one group action could never gray
            // individually. Per-option actions keep the radio idiom
            // (checked is state == target, and every option's state is
            // the GROUP's selected index) while giving each option the
            // enabled flag the inherited AND already walks onto it.
            let group = item.parent.expect("scene validated option parentage");
            let index = reg.items[&group]
                .children
                .iter()
                .position(|option| *option == id)
                .expect("options list under their group") as i32;
            let action = gio::SimpleAction::new_stateful(
                &name,
                Some(gtk4::glib::VariantTy::INT32),
                &(reg.items[&group].value as i32).to_variant(),
            );
            // The occurrence names the GROUP — the choice contract's
            // subject — even though the activated action is the
            // option's.
            let tag = crate::wire::click_tag(group, noun);
            action.connect_activate(move |_, _| {
                // The choice contract: re-selecting the selected option
                // is NOT a change and emits nothing.
                let changed = {
                    let mut reg = menus.borrow_mut();
                    let selectable =
                        reg.items[&group].value as i32 != index && menu_effective_enabled(&reg, id);
                    if selectable {
                        reg.items
                            .get_mut(&group)
                            .expect("menu items are never removed")
                            .value = f64::from(index);
                        menu_sync_radio_state(&reg, group);
                    }
                    selectable
                };
                if changed {
                    sink.send_menu_value_tag(&tag, f64::from(index));
                }
            });
            Some(action)
        }
        MenuItemKind::Menu | MenuItemKind::RadioGroup | MenuItemKind::Separator => None,
    }
}

/// The window-scoped action home: the primary IS a
/// GtkApplicationWindow, whose own ActionMap exports the "win" prefix;
/// an auxiliary window is plain, so CreateWindow inserted a group
/// under the same prefix (only GtkApplicationWindow reserves it).
/// Where a window's own actions live — the read side of
/// [`add_window_action`]: the primary IS a GtkApplicationWindow (its
/// own ActionMap exports "win"), an auxiliary carries the group
/// CreateWindow inserted under the same prefix.
#[cfg(debug_assertions)]
fn action_group_for(core: &CoreState, window: u64) -> Option<gio::SimpleActionGroup> {
    if window == 0 {
        None // the primary's map is the window itself; checked below
    } else {
        core.menu_action_groups.get(&window).cloned()
    }
}

fn add_window_action(core: &CoreState, window: u64, action: &gio::SimpleAction) {
    use gtk4::gio::prelude::ActionMapExt;
    if window == 0 {
        core.window
            .clone()
            .downcast::<gtk4::ApplicationWindow>()
            .expect("the primary window is the ApplicationWindow")
            .add_action(action);
    } else {
        core.menu_action_groups
            .get(&window)
            .expect("scene validated the window id")
            .add_action(action);
    }
}

/// Give every actionable item under `root` its window-scoped
/// GSimpleAction. Items keep exactly one bar instance (single-anchor
/// rule); re-walks after later appends skip the registered ones.
fn register_bar_actions(core: &CoreState, window: u64, root: u64) {
    let ids = {
        let reg = core.menus.borrow();
        menu_preorder(&reg, root)
    };
    for id in ids {
        let registered = !core.menus.borrow().items[&id].actions.is_empty();
        if registered {
            continue;
        }
        let Some(action) = make_menu_action(core, id, &[]) else {
            continue;
        };
        add_window_action(core, window, &action);
        core.menus
            .borrow_mut()
            .items
            .get_mut(&id)
            .expect("menu items are never removed")
            .actions
            .push(action);
    }
    let reg = core.menus.borrow();
    menu_sync_enabled(&reg, root);
}

/// Give every actionable item under `root` an instance in the
/// attachment's own group — the one whose tags carry this anchor's
/// noun (stamped copies each get their own, so the keys ARE the noun).
fn register_context_actions(core: &mut CoreState, widget: u64, root: u64) {
    use gtk4::gio::prelude::ActionMapExt;
    let ids = {
        let reg = core.menus.borrow();
        menu_preorder(&reg, root)
    };
    let noun = core.context_menus[&widget].noun.clone();
    for id in ids {
        if core.context_menus[&widget].actions.contains_key(&id) {
            continue;
        }
        let Some(action) = make_menu_action(core, id, &noun) else {
            continue;
        };
        core.context_menus[&widget].group.add_action(&action);
        core.context_menus
            .get_mut(&widget)
            .expect("attachment exists")
            .actions
            .insert(id, action.clone());
        core.menus
            .borrow_mut()
            .items
            .get_mut(&id)
            .expect("menu items are never removed")
            .actions
            .push(action);
    }
    let reg = core.menus.borrow();
    menu_sync_enabled(&reg, root);
}

fn flush_menu_section(into: &gio::Menu, section: &mut gio::Menu) {
    use gtk4::gio::prelude::MenuModelExt;
    if section.n_items() > 0 {
        into.append_section(None, &*section);
        *section = gio::Menu::new();
    }
}

/// A radio group's option rows: each option carries its OWN stateful
/// action plus its index as target — GMenu renders the radio idiom
/// from exactly that shape (target + state), and the per-option action
/// is what lets ONE option gray while its siblings stay live.
fn append_radio_options(reg: &MenuRegistry, group: u64, prefix: &str, into: &gio::Menu) {
    use gtk4::glib::prelude::ToVariant;
    for (index, &option) in reg.items[&group].children.iter().enumerate() {
        let row = gio::MenuItem::new(Some(&reg.items[&option].label), None);
        row.set_action_and_target_value(
            Some(&format!("{prefix}.kmi-{option}")),
            Some(&(index as i32).to_variant()),
        );
        into.append_item(&row);
    }
}

/// Materialize a child list into a GMenu: plain leaves accumulate in
/// an anonymous section, a separator starts the next one, a nested
/// menu cascades as a real submenu, and a nested radio group lands
/// INLINE as its own labeled section (the ratified compact-grouping
/// shape; its checkmarks ride the group action's targets).
fn build_menu_items(reg: &MenuRegistry, children: &[u64], prefix: &str, into: &gio::Menu) {
    let mut section = gio::Menu::new();
    for &child in children {
        let item = &reg.items[&child];
        match item.kind {
            MenuItemKind::Separator => flush_menu_section(into, &mut section),
            MenuItemKind::Action | MenuItemKind::Toggle => {
                section.append(Some(&item.label), Some(&format!("{prefix}.kmi-{child}")));
            }
            MenuItemKind::Menu => {
                let submenu = gio::Menu::new();
                build_menu_items(reg, &item.children, prefix, &submenu);
                section.append_submenu(Some(&item.label), &submenu);
            }
            MenuItemKind::RadioGroup => {
                flush_menu_section(into, &mut section);
                let options = gio::Menu::new();
                append_radio_options(reg, child, prefix, &options);
                into.append_section(Some(&item.label), &options);
            }
            MenuItemKind::RadioOption => {
                unreachable!("scene validated: options live under radio groups")
            }
        }
    }
    flush_menu_section(into, &mut section);
}

/// Rebuild a window's GMenu from the registry: catalogs are small and
/// GMenu items are immutable snapshots, so a full rebuild is the
/// live-label/topology path (the PopoverMenuBar tracks the model
/// OBJECT, which stays). Action state never lives in the model, so a
/// rebuild cannot revert a toggle or radio pick — the post-user-mirror
/// rule holds by construction.
fn rebuild_menubar(core: &CoreState, window: u64) {
    let Some(model) = core.menu_models.get(&window) else {
        return;
    };
    {
        let reg = core.menus.borrow();
        model.remove_all();
        for &root in reg.bars.get(&window).map(Vec::as_slice).unwrap_or(&[]) {
            let item = &reg.items[&root];
            let submenu = gio::Menu::new();
            if item.kind == MenuItemKind::RadioGroup {
                // A bar-level radio group IS a top-level menu whose
                // options wear the checkmark idiom.
                append_radio_options(&reg, root, "win", &submenu);
            } else {
                build_menu_items(&reg, &item.children, "win", &submenu);
            }
            model.append_submenu(Some(&item.label), &submenu);
        }
    }
    assert_model_actions_resolve(core, window, model);
    refresh_menu_accels(core, window);
}


/// Every action a rendered ROW names must exist in the window's action
/// group. GTK draws a row whose action is missing as insensitive — a
/// user sees a permanently gray command — while a registry-side read
/// happily reports it enabled, so a typo or a stale name in the model
/// is invisible to a state assertion. Walking the model the chrome
/// actually renders closes that gap end to end: model row -> action
/// name -> the group the accel controller and the click path resolve
/// against. Debug-only: the lanes build debug, and this is a BACKEND
/// invariant, never a guest error.
#[cfg(debug_assertions)]
fn assert_model_actions_resolve(core: &CoreState, window: u64, model: &gio::Menu) {
    use gtk4::gio::prelude::ActionGroupExt;
    use gtk4::prelude::Cast;
    fn walk(core: &CoreState, window: u64, model: &gio::MenuModel) {
        use gtk4::gio::prelude::MenuModelExt;
        for i in 0..model.n_items() {
            if let Some(name) = model
                .item_attribute_value(i, gio::MENU_ATTRIBUTE_ACTION, None)
                .and_then(|v| v.get::<String>())
            {
                let bare = name.strip_prefix("win.").unwrap_or(&name);
                let known = if window == 0 {
                    core.window
                        .clone()
                        .downcast::<gtk4::ApplicationWindow>()
                        .is_ok_and(|w| w.has_action(bare))
                } else {
                    action_group_for(core, window)
                        .is_some_and(|group| group.has_action(bare))
                };
                assert!(
                    known,
                    "kaya: menu row names action {name:?}, which the window's \
                     action group does not hold — GTK would render it \
                     permanently insensitive"
                );
            }
            for link in [gio::MENU_LINK_SUBMENU, gio::MENU_LINK_SECTION] {
                if let Some(child) = model.item_link(i, link) {
                    walk(core, window, &child);
                }
            }
        }
    }
    walk(core, window, model.upcast_ref());
}

#[cfg(not(debug_assertions))]
fn assert_model_actions_resolve(_core: &CoreState, _window: u64, _model: &gio::Menu) {}

/// Rebuild one context attachment's model from its root list.
fn rebuild_context(core: &CoreState, widget: u64) {
    let Some(attachment) = core.context_menus.get(&widget) else {
        return;
    };
    let reg = core.menus.borrow();
    attachment.model.remove_all();
    build_menu_items(&reg, &attachment.roots, "kayactx", &attachment.model);
}

/// Rebuild whatever anchors present the tree `id` lives in — the bar
/// and/or every stamped attachment (live labels, live topology).
fn rebuild_menu_anchors(core: &CoreState, id: u64) {
    let (bar, contexts) = {
        let reg = core.menus.borrow();
        let root = menu_root_of(&reg, id);
        (
            reg.bar_of.get(&root).copied(),
            reg.context_of.get(&root).cloned().unwrap_or_default(),
        )
    };
    if let Some(window) = bar {
        rebuild_menubar(core, window);
    }
    for widget in contexts {
        rebuild_context(core, widget);
    }
}

/// The canonical shortcut spelling onto GTK's accelerator syntax:
/// `primary` IS GTK's <Primary> (kaya adopted the name from GTK), and
/// named keys map onto their keysym names. Total — the root already
/// rejected everything outside the floor, and accelerator_parse
/// validates whatever else a steps script could carry.
fn menu_accel(spelling: &str) -> Option<String> {
    let mut accel = String::new();
    let mut key = None;
    for part in spelling.split('+') {
        match part {
            "primary" => accel.push_str("<Primary>"),
            "shift" => accel.push_str("<Shift>"),
            "alt" => accel.push_str("<Alt>"),
            other => key = Some(other),
        }
    }
    let keysym = match key? {
        "enter" => "Return".to_owned(),
        "escape" => "Escape".to_owned(),
        "delete" => "Delete".to_owned(),
        "left" => "Left".to_owned(),
        "right" => "Right".to_owned(),
        "up" => "Up".to_owned(),
        "down" => "Down".to_owned(),
        // The punctuation set onto X keysym names (the canonical
        // spellings name UNSHIFTED US positions, which is exactly what
        // these keysyms are).
        "comma" => "comma".to_owned(),
        "period" => "period".to_owned(),
        "slash" => "slash".to_owned(),
        "backslash" => "backslash".to_owned(),
        "minus" => "minus".to_owned(),
        "equal" => "equal".to_owned(),
        "leftbracket" => "bracketleft".to_owned(),
        "rightbracket" => "bracketright".to_owned(),
        f if f.len() > 1 && f.starts_with('f') && f[1..].chars().all(|c| c.is_ascii_digit()) => {
            f.to_uppercase()
        }
        k => k.to_owned(),
    };
    accel.push_str(&keysym);
    Some(accel)
}

/// (Re)register the window catalog's accelerators with the
/// application: accel display beside the items and key dispatch are
/// both native. Item ids are globally unique, so registrations never
/// collide across windows; shortcuts are const-only and items never
/// removed, so nothing needs unregistering.
fn refresh_menu_accels(core: &CoreState, window: u64) {
    let Some(app) = core.app.as_ref() else { return };
    let reg = core.menus.borrow();
    for &root in reg.bars.get(&window).map(Vec::as_slice).unwrap_or(&[]) {
        for id in menu_preorder(&reg, root) {
            let item = &reg.items[&id];
            if item.shortcut.is_empty() {
                continue;
            }
            // Every LEAF command may carry a chord. An option's action
            // is its own and takes the option index as target, so its
            // accelerator names the DETAILED action — GTK's
            // `win.kmi-7(1)` spelling — which is also what the rendered
            // row activates.
            debug_assert!(item.kind.takes_shortcut(), "the root rejects chords elsewhere");
            let action = match item.kind {
                MenuItemKind::Action | MenuItemKind::Toggle => format!("win.kmi-{id}"),
                MenuItemKind::RadioOption => {
                    let group = item.parent.expect("scene validated option parentage");
                    let index = reg.items[&group]
                        .children
                        .iter()
                        .position(|option| *option == id)
                        .expect("options list under their group");
                    format!("win.kmi-{id}({index})")
                }
                MenuItemKind::Menu | MenuItemKind::RadioGroup | MenuItemKind::Separator => continue,
            };
            if let Some(accel) = menu_accel(&item.shortcut) {
                app.set_accels_for_action(&action, &[&accel]);
            }
        }
    }
}

/// Materialize the window's menu chrome on first use: the
/// PopoverMenuBar over the window's GMenu model in a strip above the
/// content. The window's current child moves into the strip's content
/// slot, and every later content change routes through
/// set_window_content.
fn ensure_menu_strip(core: &mut CoreState, window: u64) {
    if core.menu_strips.contains_key(&window) {
        return;
    }
    let model = core
        .menu_models
        .entry(window)
        .or_insert_with(gio::Menu::new)
        .clone();
    let bar = gtk4::PopoverMenuBar::from_model(Some(&model));
    let strip = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    let content = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    content.set_hexpand(true);
    content.set_vexpand(true);
    strip.append(&bar);
    strip.append(&content);
    let target = gtk_window(core, window);
    if let Some(existing) = target.child() {
        target.set_child(gtk4::Widget::NONE);
        existing.set_hexpand(true);
        existing.set_vexpand(true);
        content.append(&existing);
    }
    target.set_child(Some(&strip));
    core.menu_strips.insert(window, (strip, content));
}

/// Route a window's content through the menu strip when one exists:
/// the bar is chrome above the content, so everything that used to be
/// the window's child — the mounted root, a nav entry's root, the
/// sections chrome — fills the strip's content slot instead. No strip
/// means no menus were declared, and the window keeps GTK's own child
/// slot.
/// The window's live content width in pixels, read from its ALLOCATION
/// rather than from `default_size()`.
///
/// default_size is the size REQUESTED, not the one in effect: under a
/// bare Xvfb with no window manager the two drift apart, and the arm
/// and the assertion then disagree about the same instant — the arm
/// rendered `split` while the read said `compact`, which looks like a
/// lowering bug and is not one. Same lesson the WinUI backend learned:
/// measure the window, and measure it once for both readers.
/// Falls back to the request before the window is mapped, when the
/// allocation is legitimately 0.
fn window_width(core: &CoreState, window: u64) -> i32 {
    use gtk4::prelude::{GtkWindowExt, WidgetExt};
    let target = gtk_window(core, window);
    let allocated = target.width();
    if allocated > 0 { allocated } else { target.default_size().0 }
}

/// Detach a widget from whatever currently holds it. GTK gives a
/// widget EXACTLY ONE parent and asserts loudly on a second
/// (`gtk_window_set_child: assertion ... failed`), and these roots move
/// between the window, the menu-strip content box, and the list-detail
/// split box as the size class changes. Every reparenting path goes
/// through here.
fn unparent(child: &gtk4::Widget) {
    use gtk4::prelude::{BoxExt, Cast, GtkWindowExt, WidgetExt};
    let Some(parent) = child.parent() else { return };
    if let Some(bx) = parent.downcast_ref::<gtk4::Box>() {
        bx.remove(child);
    } else if let Some(win) = parent.downcast_ref::<gtk4::Window>() {
        win.set_child(None::<&gtk4::Widget>);
    } else if let Some(page) = parent.downcast_ref::<adw::NavigationPage>() {
        // A page owns its child through a PROPERTY, so a bare unparent
        // detaches the widget while leaving the page still pointing at
        // it. The pane then lives in no tree the accessibility walk can
        // reach, and `expect_ax` reports it absent while kaya's own
        // model still has it — which is exactly how this presented.
        adw::prelude::NavigationPageExt::set_child(page, None::<&gtk4::Widget>);
    } else {
        child.unparent();
    }
}

fn set_window_content(core: &CoreState, window: u64, child: Option<&gtk4::Widget>) {
    if let Some((_, content)) = core.menu_strips.get(&window) {
        while let Some(old) = content.first_child() {
            content.remove(&old);
        }
        if let Some(widget) = child {
            unparent(widget);
            // Expansion is opt-in inside a Box (a bare window child
            // fills by construction): without it the mounted root
            // hugs and every grow weight divides nothing.
            widget.set_hexpand(true);
            widget.set_vexpand(true);
            content.append(widget);
        }
    } else {
        if let Some(widget) = child {
            unparent(widget);
        }
        gtk_window(core, window).set_child(child);
    }
}

/// Attach a context catalog root to a live or stamped widget: a
/// GtkPopoverMenu over the attachment's own model, opened by the
/// platform's own gesture (right-click, button 3), its actions in a
/// per-anchor group so each stamped copy's occurrences carry that
/// copy's key path.
fn context_attach(core: &mut CoreState, widget: u64, item: u64, noun: Vec<Value>) {
    if !core.context_menus.contains_key(&widget) {
        let anchor = core
            .widgets
            .get(&WidgetId(widget))
            .expect("scene validated the anchor id")
            .widget();
        let model = gio::Menu::new();
        let popover = gtk4::PopoverMenu::from_model(Some(&model));
        popover.set_parent(&anchor);
        let group = gio::SimpleActionGroup::new();
        anchor.insert_action_group("kayactx", Some(&group));
        // The platform's own gesture: right-click pops the catalog at
        // the pointer and takes the open-context claim.
        let gesture = gtk4::GestureClick::new();
        gesture.set_button(gtk4::gdk::BUTTON_SECONDARY);
        let open = core.open_context.clone();
        let popover_for_press = popover.clone();
        gesture.connect_pressed(move |_, _, x, y| {
            popover_for_press.set_pointing_to(Some(&gtk4::gdk::Rectangle::new(
                x as i32, y as i32, 1, 1,
            )));
            *open.borrow_mut() = Some(widget);
            popover_for_press.popup();
        });
        anchor.add_controller(gesture);
        // Chrome dismissal (Esc, outside click) releases the claim;
        // menu_activate clears it BEFORE its popdown, so this no-ops
        // on the harness path. The Rc keeps this closure off CORE —
        // popdown can run while a stage closure holds that borrow.
        let open = core.open_context.clone();
        popover.connect_closed(move |_| {
            let mut open = open.borrow_mut();
            if *open == Some(widget) {
                *open = None;
            }
        });
        core.context_menus.insert(
            widget,
            GtkContextMenu {
                roots: Vec::new(),
                noun,
                model,
                popover,
                group,
                actions: HashMap::new(),
            },
        );
    }
    core.context_menus
        .get_mut(&widget)
        .expect("attachment exists")
        .roots
        .push(item);
    core.menus
        .borrow_mut()
        .context_of
        .entry(item)
        .or_default()
        .push(widget);
    register_context_actions(core, widget, item);
    rebuild_context(core, widget);
}

/// The widget id behind a harness target — the reverse of the
/// kind#index registries, by object identity (the registries hold the
/// same native objects the widget map does).
// Harness-only: its sole caller is the Stage impl below, and it speaks
// harness types, so it goes with the harness rather than shipping in a
// user's binary.
#[cfg(feature = "harness")]
fn context_anchor_id(core: &CoreState, t: crate::harness::Target) -> u64 {
    use crate::harness::{resolve, TargetKind as K};
    let widget: gtk4::Widget = match t.kind {
        K::Button => core.buttons[resolve(t.index, core.buttons.len())].clone().upcast(),
        K::Checkbox => core.checkboxes[resolve(t.index, core.checkboxes.len())].clone().upcast(),
        K::Slider => core.sliders[resolve(t.index, core.sliders.len())].clone().upcast(),
        K::Label => core.labels[resolve(t.index, core.labels.len())].clone().upcast(),
        K::Column => core.columns[resolve(t.index, core.columns.len())].clone().upcast(),
        K::Row => core.rows[resolve(t.index, core.rows.len())].clone().upcast(),
        K::Image => core.images[resolve(t.index, core.images.len())].clone().upcast(),
        K::Progress => core.progresses[resolve(t.index, core.progresses.len())].clone().upcast(),
        K::Scroll => core.scrolls[resolve(t.index, core.scrolls.len())].clone().upcast(),
        K::Select => core.selects[resolve(t.index, core.selects.len())].clone().upcast(),
        K::Radio => core.radios[resolve(t.index, core.radios.len())].clone().upcast(),
        K::Grid => core.grids[resolve(t.index, core.grids.len())].clone().upcast(),
        // The harness rejects editable text before the stage sees it
        // (their native context menus are dress).
        K::Entry | K::Textarea => {
            panic!("kaya: editable text is not a context anchor (v1)")
        }
    };
    core.widgets
        .iter()
        .find_map(|(id, native)| (native.widget() == widget).then_some(id.0))
        .expect("kaya: context target is not a live widget")
}

/// The REAL activation route for a resolved item: the GSimpleAction
/// (and the option index for a radio pick). Grouping nodes and
/// separators have none — chrome opens or ignores them, and so does
/// the verb.
fn menu_activation_route(
    reg: &MenuRegistry,
    item: u64,
    attachment: Option<&GtkContextMenu>,
) -> Option<(gio::SimpleAction, Option<i32>)> {
    let instance = |id: u64| match attachment {
        Some(cm) => cm.actions.get(&id).cloned(),
        None => reg.items[&id].actions.first().cloned(),
    };
    match reg.items[&item].kind {
        MenuItemKind::Action | MenuItemKind::Toggle => instance(item).map(|a| (a, None)),
        MenuItemKind::RadioOption => {
            let group = reg.items[&item]
                .parent
                .expect("scene validated option parentage");
            let index = reg.items[&group]
                .children
                .iter()
                .position(|c| *c == item)
                .expect("options list under their group") as i32;
            // The option's own action, the same object its rendered row
            // activates — a disabled option refuses the verb exactly as
            // it refuses a click.
            instance(item).map(|a| (a, Some(index)))
        }
        MenuItemKind::Menu | MenuItemKind::RadioGroup | MenuItemKind::Separator => None,
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
                            sink.send_text_tag(&tag, &lf(e.text().to_string()));
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
                WidgetKind::Textarea => {
                    // The multi-line editor: GtkTextView, the entry's
                    // exact contract — the buffer's `changed` fires
                    // for programmatic set_text too, so the
                    // USER/programmatic split rides apply_quiet.
                    let view = gtk4::TextView::new();
                    view.set_size_request(240, 96);
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("textareas carry a tag");
                    let quiet = core.apply_quiet.clone();
                    let buffer = view.buffer();
                    buffer.connect_changed(move |b| {
                        if !quiet.get() {
                            let text =
                                lf(b.text(&b.start_iter(), &b.end_iter(), false).to_string());
                            sink.send_text_tag(&tag, &text);
                        }
                    });
                    core.textareas.push(view.clone());
                    NativeWidget::Textarea(view)
                }
                WidgetKind::Grid => {
                    // The 2D layout contract on GTK's own Grid:
                    // columns take their natural width (homogeneous
                    // off is the default), aligned across rows by the
                    // toolkit itself. Attach positions re-flow when
                    // children or the columns prop arrive.
                    let grid = gtk4::Grid::new();
                    core.grid_children.insert(id.0, Vec::new());
                    core.grid_cols.insert(id.0, 1);
                    core.grids.push(grid.clone());
                    NativeWidget::Grid(grid)
                }
                WidgetKind::Radio => {
                    // The choice contract inline: GTK's radio idiom
                    // is grouped CheckButtons (set_group renders the
                    // circle); the group's Box is the widget. Rows
                    // materialize at AddChild; each USER pick emits
                    // with the group's identity tag (toggled fires
                    // for programmatic set_active too, so the picks
                    // ride apply_quiet like every interactive kind).
                    let group = gtk4::Box::new(gtk4::Orientation::Vertical, 4);
                    core.radio_tags
                        .insert(id.0, tag.clone().expect("radio groups carry a tag"));
                    core.radio_buttons.insert(id.0, Vec::new());
                    core.radios.push(group.clone());
                    NativeWidget::Radio(group)
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
            // A destroyed anchor takes its context attachment with it
            // (menu ITEMS are never destroyed): the popover unparents
            // BEFORE the widget leaves its container, this
            // attachment's action instances leave the registry's sync
            // lists, and a dangling open-context claim is released —
            // a Remove activation destroys its own anchor (the WinUI
            // lifecycle precedent, docs/traps.md).
            if let Some(attachment) = core.context_menus.remove(&id.0) {
                {
                    let mut open = core.open_context.borrow_mut();
                    if *open == Some(id.0) {
                        *open = None;
                    }
                }
                let mut reg = core.menus.borrow_mut();
                for (item, action) in &attachment.actions {
                    if let Some(state) = reg.items.get_mut(item) {
                        state.actions.retain(|a| a != action);
                    }
                }
                for widgets in reg.context_of.values_mut() {
                    widgets.retain(|w| *w != id.0);
                }
                attachment.popover.unparent();
            }
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
                (WindowProp::ListDetail, Value::Bool(on)) => {
                    core.list_detail.insert(window.0, *on);
                    refresh_nav(core, window.0);
                }
                (WindowProp::SectionsPresentation, Value::I64(hint)) => {
                    // ADVISORY: bar/auto = the header StackSwitcher,
                    // sidebar = GtkStackSidebar; the chrome rebuilds
                    // if it already exists.
                    core.sections_presentation.insert(window.0, *hint);
                    if core.sections.contains_key(&window.0) {
                        refresh_sections(core, window.0);
                    }
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
            // Window-scoped menu actions for a PLAIN window: the
            // primary is a GtkApplicationWindow whose own ActionMap
            // exports "win"; an auxiliary needs the group inserted by
            // hand under the same prefix (safe here — only
            // GtkApplicationWindow reserves it).
            let actions = gio::SimpleActionGroup::new();
            aux.insert_action_group("win", Some(&actions));
            core.menu_action_groups.insert(window.0, actions);
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
            // ... and its sections, each with ITS stack (the one way
            // a section dies).
            for sid in core.sections.remove(&window.0).unwrap_or_default() {
                core.section_pages.remove(&sid);
                for entry in core.nav_stacks.remove(&sid).unwrap_or_default() {
                    core.nav_entries.remove(&entry);
                }
            }
            core.section_stacks.remove(&window.0);
            core.section_chrome.remove(&window.0);
            core.selected_sections.remove(&window.0);
            core.sections_presentation.remove(&window.0);
            // ... and its menu chrome. The registry keeps the items
            // (they are never destroyed); only this window's bar list
            // and materialization go.
            core.menu_models.remove(&window.0);
            core.menu_strips.remove(&window.0);
            core.menu_action_groups.remove(&window.0);
            {
                let mut reg = core.menus.borrow_mut();
                reg.bars.remove(&window.0);
                reg.bar_of.retain(|_, w| *w != window.0);
            }
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
        ApplyOp::AddSection { window, section } => {
            // Append-only: a page container joins the window's stack;
            // the mount fills it. First added is selected (mirrored
            // from the core).
            let page = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
            core.section_pages.insert(
                section.0,
                GtkSectionPage {
                    window: window.0,
                    page,
                    title: String::new(),
                    root: None,
                },
            );
            core.sections.entry(window.0).or_default().push(section.0);
            core.selected_sections.entry(window.0).or_insert(section.0);
            refresh_sections(core, window.0);
        }
        ApplyOp::SelectSection { window, section } => {
            // Programmatic and QUIET: the stack moves under the echo
            // guard, so notify::visible-child stays silent (the echo
            // doctrine — only the user's switch emits).
            core.selected_sections.insert(window.0, section.0);
            if let Some(stack) = core.section_stacks.get(&window.0) {
                use gtk4::prelude::WidgetExt;
                core.apply_quiet.set(true);
                stack.set_visible_child_name(&section.0.to_string());
                core.apply_quiet.set(false);
                let _ = stack; // chrome stays as-is
            }
        }
        ApplyOp::SetSectionProp { section, prop, value } => {
            use crate::protocol::SectionProp;
            let record = core
                .section_pages
                .get_mut(&section.0)
                .expect("scene validated the section id");
            match (prop, &value) {
                (SectionProp::Title, Value::Str(title)) => {
                    record.title = title.clone();
                    let window = record.window;
                    if let Some(stack) = core.section_stacks.get(&window) {
                        let page = &core.section_pages[&section.0].page;
                        use gtk4::prelude::Cast;
                        let stack_page = stack.page(page.upcast_ref::<gtk4::Widget>());
                        stack_page.set_title(&core.section_pages[&section.0].title);
                    }
                }
                // Day-one slot: accepted; the switcher TITLE is the
                // harness observable (GTK's switcher shows titles).
                (SectionProp::Icon, Value::Blob(_)) => {}
                (p, v) => unreachable!("scene validated section prop {p:?}/{v:?}"),
            }
        }
        ApplyOp::MenuItemCreate { item, kind } => {
            // Registry only: actions and chrome materialize at anchor
            // time, when the item's window (or anchor widget) is
            // known.
            core.menus.borrow_mut().items.insert(
                item.0,
                MenuItemState {
                    kind,
                    label: String::new(),
                    enabled: true,
                    checked: false,
                    value: 0.0,
                    primary: false,
                    shortcut: String::new(),
                    parent: None,
                    children: Vec::new(),
                    actions: Vec::new(),
                },
            );
        }
        ApplyOp::MenuItemAppend { parent, child } => {
            {
                let mut reg = core.menus.borrow_mut();
                reg.items
                    .get_mut(&child.0)
                    .expect("scene validated the child id")
                    .parent = Some(parent.0);
                reg.items
                    .get_mut(&parent.0)
                    .expect("scene validated the parent id")
                    .children
                    .push(child.0);
            }
            // Append-at-any-time: a subtree landing under an anchored
            // root materializes NOW (the rework path appends Publish
            // under the retained Document and the steps activate it
            // with no further nudge).
            let (bar, contexts) = {
                let reg = core.menus.borrow();
                let root = menu_root_of(&reg, child.0);
                (
                    reg.bar_of.get(&root).copied(),
                    reg.context_of.get(&root).cloned().unwrap_or_default(),
                )
            };
            if let Some(window) = bar {
                register_bar_actions(core, window, child.0);
            }
            for widget in &contexts {
                register_context_actions(core, *widget, child.0);
            }
            rebuild_menu_anchors(core, child.0);
        }
        ApplyOp::MenubarAppend { window, item } => {
            {
                let mut reg = core.menus.borrow_mut();
                reg.bars.entry(window.0).or_default().push(item.0);
                reg.bar_of.insert(item.0, window.0);
            }
            ensure_menu_strip(core, window.0);
            register_bar_actions(core, window.0, item.0);
            rebuild_menubar(core, window.0);
        }
        ApplyOp::ContextAttach { widget, item } => {
            context_attach(core, widget.0, item.0, Vec::new());
        }
        ApplyOp::ContextAttachNode { widget, item, path } => {
            // The stamped copy's key path IS the noun: baked into the
            // attachment's action tags (the on_click_node encoding).
            context_attach(core, widget.0, item.0, path);
        }
        ApplyOp::SetMenuProp { item, prop, value } => {
            use gtk4::glib::prelude::ToVariant;
            // EXHAUSTIVE over the prop: a new MENU_PROPS row fails to
            // compile here rather than reaching a catch-all at runtime.
            match prop {
                MenuProp::Label => {
                    let label = crate::protocol::prop_str(&value);
                    core.menus
                        .borrow_mut()
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .label = label.to_owned();
                    // Labels are live: whatever chrome presents the
                    // tree re-renders (GMenu snapshots are immutable).
                    rebuild_menu_anchors(core, item.0);
                }
                MenuProp::Enabled => {
                    {
                        let mut reg = core.menus.borrow_mut();
                        reg.items
                            .get_mut(&item.0)
                            .expect("scene validated the item id")
                            .enabled = crate::protocol::prop_bool(&value);
                    }
                    // The inherited AND lands on every descendant's
                    // REAL action; no model rebuild — enablement is
                    // live action state. Enablement writes never emit.
                    let reg = core.menus.borrow();
                    menu_sync_enabled(&reg, item.0);
                }
                MenuProp::Checked => {
                    // QUIET (the echo doctrine): set_state never fires
                    // activate, so the write configures the native
                    // checkmark without an occurrence.
                    let on = crate::protocol::prop_bool(&value);
                    let mut reg = core.menus.borrow_mut();
                    let state = reg
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id");
                    state.checked = on;
                    for action in &state.actions {
                        action.set_state(&on.to_variant());
                    }
                }
                MenuProp::Value => {
                    // QUIET, same as checked (the choice contract's
                    // programmatic side). The state lives on the
                    // OPTIONS' actions, one per option, so the group's
                    // write fans out to all of them.
                    let mut reg = core.menus.borrow_mut();
                    reg.items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .value = crate::protocol::prop_f64(&value);
                    menu_sync_radio_state(&reg, item.0);
                }
                MenuProp::Primary => {
                    // The phone-promotion hint: INERT on desktop by
                    // design (DESIGN.md, Menus) — recorded, never
                    // materialized.
                    core.menus
                        .borrow_mut()
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .primary = crate::protocol::prop_bool(&value);
                }
                MenuProp::Shortcut => {
                    core.menus
                        .borrow_mut()
                        .items
                        .get_mut(&item.0)
                        .expect("scene validated the item id")
                        .shortcut = crate::protocol::prop_str(&value).to_owned();
                    let window = {
                        let reg = core.menus.borrow();
                        reg.bar_of.get(&menu_root_of(&reg, item.0)).copied()
                    };
                    if let Some(window) = window {
                        refresh_menu_accels(core, window);
                    }
                }
                MenuProp::Icon => {
                    // Day-one slot: accepted; GTK's menu dress carries
                    // no item icons and phone promotion is not this
                    // platform (DESIGN.md, Menus — ignored where the
                    // dress has none).
                }
                MenuProp::Role => {
                    // A standard-command role is a placement REQUEST
                    // this host has nowhere to honor: there is no
                    // dress-owned application menu here, so the item
                    // stays exactly where the app declared it.
                }
            }
        }

        ApplyOp::PresentFileDialog(_) => {
            // DEPTH SLICE: the mac SwiftUI arm lands first (CLAUDE.md's
            // sequencing). This backend compiles the vocabulary and
            // refuses it loudly rather than silently doing nothing. The
            // call is what check-stubs and check-steps read — it names
            // the scene, so neither gate has to recognise a sentence.
            crate::depth_stub("filedialog");
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
                    // collapsed button both render) — or its radio
                    // row's CheckButton label.
                    if let Some((select, row)) = core.select_options.get(&id.0) {
                        core.apply_quiet.set(true);
                        core.select_models[select].splice(*row, 1, &[&s]);
                        core.apply_quiet.set(false);
                    }
                    if let Some((radio, row)) = core.radio_options.get(&id.0) {
                        core.radio_buttons[radio][*row as usize].set_label(Some(&s));
                    }
                }
                (NativeWidget::Entry(entry), Prop::Text, Value::Str(s)) => {
                    // Quiet: a property write is configuration, not a
                    // user edit (see apply_quiet).
                    core.apply_quiet.set(true);
                    entry.set_text(&s);
                    core.apply_quiet.set(false);
                }
                (NativeWidget::Textarea(view), Prop::Text, Value::Str(s)) => {
                    core.apply_quiet.set(true);
                    view.buffer().set_text(&s);
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
                // THE UNIVERSAL PROPS. Every other arm keys on a
                // (kind, prop) pair because every other prop names
                // something only some controls have; these name
                // something every element has, so they match the prop
                // alone and reach the widget through NativeWidget::widget.
                //
                // The LABEL is a real accessible property — it is what
                // an assistive client speaks, and setting it OVERRIDES
                // whatever the control derived from its own content, so
                // an unset label must never be written as "".
                (w, Prop::A11yLabel, Value::Str(label)) => {
                    use gtk4::prelude::{AccessibleExt, AccessibleExtManual};
                    if !label.is_empty() {
                        let widget = w.widget();
                        // Promote a CONTAINER to a semantic group. GTK
                        // made GtkBox's role GENERIC in 4.12 (it was
                        // GROUP before), and GENERIC is documented as "a
                        // nameless container with no semantic meaning" —
                        // so a label set on one simply does not surface
                        // as an AT-SPI name. Naming a container IS the
                        // app declaring it a group, which is the same
                        // rule WinUI enforces (an unnamed Grid has no
                        // automation peer) and what the ARIA guidance
                        // says: unnamed containers are flattened, named
                        // ones are groups.
                        //
                        // EVERY container kind, not just row and column:
                        // measured 2026-07-25 over AT-SPI, a named grid
                        // and a named radio group both stayed role
                        // `panel` with an EMPTY name, and a named scroll
                        // stayed `scroll pane`, also nameless. The radio
                        // group is here because its accessibility shape
                        // IS a container — a group of radio buttons,
                        // which is what every other platform publishes
                        // for it too.
                        if matches!(
                            w,
                            NativeWidget::Column(_)
                                | NativeWidget::Row(_)
                                | NativeWidget::Grid(_)
                                | NativeWidget::Scroll(_)
                                | NativeWidget::Radio(_)
                        ) {
                            widget.set_accessible_role(gtk4::AccessibleRole::Group);
                        }
                        // AN AUTHORED NAME MUST WIN. GTK's name
                        // computation reads the LABELLED_BY relation
                        // FIRST and the label property second
                        // (gtkatcontext.c), and a control that points a
                        // relation at its own content therefore
                        // outranks anything an app sets: a named select
                        // read back as `combo box name='Red'`, its
                        // selected option, with the authored "Color"
                        // ignored (measured 2026-07-25 over AT-SPI,
                        // through a re-apply on notify, on map and on a
                        // later timeout — none of them could win a
                        // precedence fight). Dropping the relation is
                        // what makes the property the answer.
                        widget.reset_relation(gtk4::AccessibleRelation::LabelledBy);
                        widget.update_property(&[gtk4::accessible::Property::Label(
                            label.as_str(),
                        )]);
                    }
                }
                // The IDENTIFIER has no GTK setter and no reader below
                // 4.22 (gtk_accessible_get_accessible_id landed there;
                // this build pins v4_10 and Debian trixie ships 4.18).
                // The widget NAME is what GTK's AT-SPI backend publishes
                // for a widget's identity, so that is where it goes —
                // and it is what the AT-SPI reader will match on.
                // The HINT: GTK's DESCRIPTION property, which AT-SPI
                // publishes as the description — the slot for what
                // acting on the control does. Same empty-means-unset
                // rule as the label.
                (w, Prop::A11yHint, Value::Str(hint)) => {
                    use gtk4::prelude::AccessibleExtManual;
                    if !hint.is_empty() {
                        w.widget().update_property(&[
                            gtk4::accessible::Property::Description(hint.as_str()),
                        ]);
                    }
                }
                (w, Prop::A11yId, Value::Str(id)) => {
                    use gtk4::prelude::WidgetExt;
                    w.widget().set_widget_name(id.as_str());
                }
                (NativeWidget::Grid(grid), Prop::Columns, Value::F64(cols)) => {
                    core.grid_cols.insert(id.0, cols as i32);
                    let grid = grid.clone();
                    let _ = grid;
                    reflow_grid(core, id.0);
                }
                (NativeWidget::Grid(grid), Prop::Spacing, Value::F64(gap)) => {
                    grid.set_row_spacing(gap as u32);
                    grid.set_column_spacing(gap as u32);
                }
                (NativeWidget::Radio(_), Prop::Value, Value::F64(v)) => {
                    core.apply_quiet.set(true);
                    if let Some(check) = core
                        .radio_buttons
                        .get(&id.0)
                        .and_then(|b| b.get(v as usize))
                    {
                        check.set_active(true);
                    }
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
            if let NativeWidget::Grid(_) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let child_widget = core
                    .widgets
                    .get(&child)
                    .expect("scene validated the id")
                    .widget();
                child_widget.set_halign(gtk4::Align::Start);
                child_widget.set_valign(gtk4::Align::Start);
                core.grid_children
                    .get_mut(&parent.0)
                    .expect("grid created")
                    .push(child_widget);
                reflow_grid(core, parent.0);
                return;
            }
            if let NativeWidget::Radio(group) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                // A radio's label children are its OPTIONS: grouped
                // CheckButton rows, never standalone widgets. The row
                // initializes from the label's CURRENT text
                // (children-first sugars set it before this AddChild)
                // and the label leaves the harness's label registry.
                let group = group.clone();
                let text = match core.widgets.get(&child).expect("scene validated the id") {
                    NativeWidget::Label(l) => {
                        let l = l.clone();
                        core.labels.retain(|x| x != &l);
                        l.text().to_string()
                    }
                    _ => String::new(),
                };
                let check = gtk4::CheckButton::with_label(&text);
                let buttons = core.radio_buttons.get_mut(&parent.0).expect("radio created");
                if let Some(first) = buttons.first() {
                    check.set_group(Some(first));
                }
                let row = buttons.len() as u32;
                let sink = core.occurrences.clone();
                let tag = core.radio_tags[&parent.0].clone();
                let quiet = core.apply_quiet.clone();
                check.connect_toggled(move |c| {
                    if c.is_active() && !quiet.get() {
                        sink.send_value_tag(&tag, f64::from(row));
                    }
                });
                group.append(&check);
                buttons.push(check);
                core.radio_options.insert(child.0, (parent.0, row));
                return;
            }
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
            if core.section_pages.contains_key(&window.0) {
                // A section presents in-window: added to the set
                // already; the mount fills its page.
                core.section_pages.get_mut(&window.0).unwrap().root =
                    Some(root_widget);
                refresh_section_pane(core, window.0);
            } else if let Some(entry) = core.nav_entries.get_mut(&window.0) {
                entry.root = Some(root_widget);
                let host = entry.window;
                if core.nav_stacks.get(&host).and_then(|s| s.last()) == Some(&window.0) {
                    refresh_nav(core, host);
                }
            } else if window.0 == 0 {
                set_window_content(core, 0, Some(&root_widget));
                core.window_roots.insert(0, root_widget);
            } else {
                use gtk4::prelude::GtkWindowExt;
                set_window_content(core, window.0, Some(&root_widget));
                // Mounting presents.
                core.aux_windows
                    .get(&window.0)
                    .expect("scene validated the window id")
                    .present();
                core.window_roots.insert(window.0, root_widget);
            }
        }
        ApplyOp::Command { id, command } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match command {
                CommandKind::Clear => {
                    // A command ACTS LIKE THE USER (unlike a property
                    // write): apply_quiet stays off here on purpose, so
                    // GTK's `changed` carries the empty edit to the app
                    // through the widget's own path — the entry
                    // scene's second-add round depends on exactly
                    // this echo.
                    match widget {
                        NativeWidget::Entry(entry) => entry.set_text(""),
                        NativeWidget::Textarea(view) => view.buffer().set_text(""),
                        _ => panic!("kaya: clear on a non-text widget (scene validates kinds)"),
                    }
                }
                CommandKind::Focus => {
                    // grab_focus is per-window (the toplevel's focus
                    // widget), so parallel tiled suite legs cannot
                    // steal each other's focus assertions. The
                    // materialization class (see traps.md): an
                    // unmapped widget cannot take focus and the bool
                    // is discarded — a mount-tx focus would silently
                    // drop. Not mapped yet: one-shot re-grab from the
                    // widget's own map signal.
                    let w = widget.widget();
                    if w.is_mapped() {
                        w.grab_focus();
                    } else {
                        // One-shot: map re-fires on every re-map, and
                        // a stale handler must not steal focus later.
                        let armed = Rc::new(RefCell::new(None));
                        let armed2 = armed.clone();
                        let handler = w.connect_map(move |w| {
                            w.grab_focus();
                            if let Some(id) = armed2.borrow_mut().take() {
                                w.disconnect(id);
                            }
                        });
                        *armed.borrow_mut() = Some(handler);
                    }
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
        // libadwaita has to be initialised before any Adw widget is
        // constructed, and the list-detail arm constructs one. Safe to
        // call more than once, and it must come after GTK is up, which
        // inside activate it already is.
        adw::init().expect("libadwaita init");
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

        #[cfg(feature = "harness")]
        if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
            crate::harness::spawn(&scene, GtkStage, |line| println!("{line}"));
        }
        // A build WITHOUT the harness feature must not silently ignore
        // KAYA_SELFTEST. The feature is off by default so users do not
        // ship the scene interpreter, which means a runner that forgets
        // `--features harness` would otherwise start the app, run no
        // steps, print no verdict, and hang until its timeout — the
        // silent-no-op shape this repo keeps paying for. Fail loudly
        // instead, naming the fix.
        #[cfg(not(feature = "harness"))]
        if std::env::var("KAYA_SELFTEST").is_ok() {
            panic!(
                "kaya: KAYA_SELFTEST is set but this build has no harness \
                 — rebuild with `--features harness` (it is off by default \
                 so shipped apps do not carry the scene interpreter)"
            );
        }


        CORE.with_borrow_mut(|core| {
            *core = Some(CoreState {
                transactions: tx_rx,
                scene: Scene::new(),
                occurrences: occ_tx.clone(),
                aux_windows: HashMap::new(),
                nav_entries: HashMap::new(),
                nav_stacks: HashMap::new(),
                list_detail: HashMap::new(),
                split_presentation: HashMap::new(),
                split_views: HashMap::new(),
                sections: HashMap::new(),
                section_pages: HashMap::new(),
                section_stacks: HashMap::new(),
                section_chrome: HashMap::new(),
                selected_sections: HashMap::new(),
                sections_presentation: HashMap::new(),
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
                menus: Rc::new(RefCell::new(MenuRegistry::default())),
                menu_models: HashMap::new(),
                menu_strips: HashMap::new(),
                menu_action_groups: HashMap::new(),
                context_menus: HashMap::new(),
                open_context: Rc::new(RefCell::new(None)),
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
                radios: Vec::new(),
                grids: Vec::new(),
                textareas: Vec::new(),
                grid_children: HashMap::new(),
                grid_cols: HashMap::new(),
                radio_options: HashMap::new(),
                radio_buttons: HashMap::new(),
                radio_tags: HashMap::new(),
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
#[cfg(feature = "harness")]
struct GtkStage;

#[cfg(feature = "harness")]
impl GtkStage {
    /// The mutable twin of on_main, for stage actions that reconcile
    /// core-owned state (select_section's user route).
    fn on_main_mut<T: Send + 'static>(
        f: impl FnOnce(&mut CoreState) -> T + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        let cell = std::cell::Cell::new(Some((f, tx)));
        glib::idle_add(move || {
            if let Some((f, tx)) = cell.take() {
                CORE.with_borrow_mut(|core| {
                    let core = core.as_mut().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            glib::ControlFlow::Break
        });
        rx.recv().expect("the main context applied the step")
    }

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

#[cfg(feature = "harness")]
impl crate::harness::Stage for GtkStage {
    fn menu_activate(&self, path: &str) {
        let path = path.to_owned();
        Self::on_main(move |core| {
            use gtk4::gio::prelude::ActionExt;
            use gtk4::glib::prelude::ToVariant;
            // An OPEN context menu owns resolution EXCLUSIVELY while
            // presented — no bar fallback (the interpreters' rule).
            let open = *core.open_context.borrow();
            if let Some(anchor) = open {
                let attachment = core
                    .context_menus
                    .get(&anchor)
                    .expect("kaya: the open context menu lost its attachment");
                let route = {
                    let reg = core.menus.borrow();
                    let item = menu_resolve_path(&reg, &attachment.roots, &path)
                        .unwrap_or_else(|| panic!("kaya: no such context item {path:?}"));
                    menu_activation_route(&reg, item, Some(attachment))
                };
                // A leaf fires exactly once and the menu closes: the
                // claim clears BEFORE popdown (the closed handler's
                // equality check no-ops), and the REAL per-anchor
                // action carries the noun.
                *core.open_context.borrow_mut() = None;
                attachment.popover.popdown();
                match route {
                    Some((action, None)) => action.activate(None),
                    Some((action, Some(index))) => action.activate(Some(&index.to_variant())),
                    None => {}
                }
                return;
            }
            // The bar route: resolve SEMANTICALLY over the model tree
            // (a grouping root's label is a path segment whether or
            // not materialization mints a titled row), then drive the
            // REAL window-scoped GAction — the same object bar chrome
            // and the accelerator hit. A disabled action refuses the
            // activation natively, exactly as its grayed row would.
            let route = {
                let reg = core.menus.borrow();
                let roots = reg.bars.get(&0).cloned().unwrap_or_default();
                let item = menu_resolve_path(&reg, &roots, &path)
                    .unwrap_or_else(|| panic!("kaya: no such menu item {path:?}"));
                menu_activation_route(&reg, item, None)
            };
            match route {
                Some((action, None)) => action.activate(None),
                Some((action, Some(index))) => action.activate(Some(&index.to_variant())),
                None => {}
            }
        });
    }

    fn context_open(&self, t: crate::harness::Target) {
        Self::on_main(move |core| {
            let anchor = context_anchor_id(core, t);
            let attachment = core
                .context_menus
                .get(&anchor)
                .unwrap_or_else(|| panic!("kaya: no context menu attached to {t:?}"));
            // The claim, then the REAL chrome: the same popover the
            // right-click gesture presents.
            *core.open_context.borrow_mut() = Some(anchor);
            attachment.popover.popup();
        });
    }

    fn menu_count(&self) -> usize {
        Self::on_main(|core| {
            use gtk4::gio::prelude::MenuModelExt;
            // The REAL materialized bar: the GMenu model the
            // PopoverMenuBar renders — its top-level submenus ARE the
            // catalog's grouping roots.
            core.menu_models
                .get(&0)
                .map(|model| model.n_items() as usize)
                .unwrap_or(0)
        })
    }

    fn ax(&self, target: crate::harness::Target) -> String {
        // Correspondence is ORDINAL: the Nth element of the matching
        // role in the app's AT-SPI tree, which is what `kind#index`
        // already means. GTK <= 4.21 publishes no settable accessible
        // id (verified: set_widget_name does NOT surface as one), so
        // identity matching is unavailable here — unlike macOS, where
        // the identifier works and is used instead. Strongest
        // correspondence each platform offers.
        #[cfg(feature = "harness")]
        {
            use crate::harness::TargetKind as K;
            let want = match target.kind {
                K::Button => atspi::Role::Button,
                K::Checkbox => atspi::Role::CheckBox,
                // GTK exposes an entry as AT-SPI role TEXT, not Entry —
                // read off the live bus with the probe, not guessed.
                K::Entry | K::Textarea => atspi::Role::Text,
                K::Label => atspi::Role::Label,
                K::Slider => atspi::Role::Slider,
                K::Image => atspi::Role::Image,
                K::Progress => atspi::Role::ProgressBar,
                K::Select => atspi::Role::ComboBox,
                // A scroll viewport keeps GTK's own role: the Group
                // promotion the other containers take does not apply to
                // a GtkScrolledWindow (measured — it stays `scroll
                // pane`, with the authored name attached), and the
                // closed set normalizes it to `group` below, exactly as
                // macOS normalizes AXScrollArea.
                K::Scroll => atspi::Role::ScrollPane,
                // A container kaya has NAMED carries role Grouping
                // (the lowering promotes it); an unnamed one stays
                // GENERIC/Panel and is not a semantic group at all.
                // Matching Grouping also sidesteps the panel-ordinal
                // problem: the tree is full of GTK-internal panels (a
                // check box contains one), so "Nth panel" never lined
                // up with "Nth container kaya created". The radio group
                // rides here too: its accessibility shape is a group of
                // radio buttons, and the lowering promotes it with the
                // rest.
                K::Row | K::Column | K::Grid | K::Radio => atspi::Role::Grouping,
            };
            let role = match want {
                atspi::Role::Button => "button",
                atspi::Role::CheckBox => "checkbox",
                atspi::Role::Text => "field",
                atspi::Role::Label => "label",
                atspi::Role::Slider => "slider",
                atspi::Role::Image => "image",
                atspi::Role::ProgressBar => "progress",
                atspi::Role::ComboBox => "combobox",
                atspi::Role::Grouping | atspi::Role::ScrollPane => "group",
                _ => "unknown",
            };
            // THE ORDINAL IS NOT kaya's INDEX. `label#0` means the
            // first label kaya created, but the bus's Nth Label counts
            // the captions inside buttons and check boxes too — so
            // `label#0` read `label/Save`, the caption inside the first
            // button (measured 2026-07-25). The same collision hits
            // every role the bus shares between kinds: an entry and a
            // textarea are both `text`, so `textarea#0` read the
            // entry's name; every named container is `grouping`, so
            // `row#0` read the enclosing column's.
            //
            // So kaya's index resolves a WIDGET (creation order, what
            // `kind#index` means), and the widget's rank among the
            // widgets publishing the SAME bus role — walked
            // depth-first, the order the bus publishes — is the ordinal
            // to ask for. Widget-tree order rather than creation order
            // on purpose: creation is parent-first in statement-shaped
            // languages and child-first in expression-shaped ones,
            // while the tree is identical in both.
            //
            // Exact identity is still unavailable here (GTK publishes
            // no settable accessible id below 4.22, and the AT-SPI
            // probe confirms the widget name does not surface as one);
            // this is the strongest correspondence the platform offers.
            //
            // The rank is read on the MAIN thread (the widget tree
            // lives there), the bus walk on this one — the same split
            // every other GTK verb makes.
            let index = match Self::on_main(move |core| {
                target_widget(core, target)
                    .and_then(|widget| atspi_rank(&core.window, &widget))
            }) {
                Some(rank) => rank as isize,
                None => return "<not in the accessibility tree>".to_owned(),
            };
            return match atspi_collect(want, index as usize, false) {
                Some(name) => format!("{role}/{name}"),
                None => "<not in the accessibility tree>".to_owned(),
            };
        }
        #[allow(unreachable_code)]
        {
            let _ = target;
        // FAN-OUT PENDING (the depth slice is SwiftUI on mac). Declared
        // so the trait is satisfied and the remaining work stays
        // VISIBLE — a sentinel that can never equal a valid
        // `<role>/<label>` spelling, so any scene asserting on this
        // backend fails loudly instead of quietly passing. Reads GtkAccessible / AT-SPI when it lands.
            "<the GTK accessibility read is not implemented yet>".to_owned()
        }
    }

    fn ax_hint(&self, target: crate::harness::Target) -> String {
        // The HINT rides AT-SPI's DESCRIPTION — GTK's
        // `Property::Description`, which is the accessible surface's
        // slot for "what does acting on this do", and the same node
        // `ax` resolves. Same correspondence rules apply (see `ax`):
        // kaya's index picks a widget, the widget's rank among
        // same-role nodes picks the bus ordinal.
        #[cfg(feature = "harness")]
        {
            use crate::harness::TargetKind as K;
            let want = match target.kind {
                K::Button => atspi::Role::Button,
                K::Checkbox => atspi::Role::CheckBox,
                K::Select => atspi::Role::ComboBox,
                K::Radio => atspi::Role::Grouping,
                // The root admits a11y_hint on activation kinds only
                // (scene.rs), so anything else asking for one is a
                // scene bug, said out loud rather than answered.
                _ => return "<the hint prop applies to activation kinds only>".to_owned(),
            };
            let index = match Self::on_main(move |core| {
                target_widget(core, target)
                    .and_then(|widget| atspi_rank(&core.window, &widget))
            }) {
                Some(rank) => rank,
                None => return "<not in the accessibility tree>".to_owned(),
            };
            return match atspi_collect(want, index, true) {
                Some(description) => description,
                None => "<not in the accessibility tree>".to_owned(),
            };
        }
        #[allow(unreachable_code)]
        {
            let _ = target;
            "<the GTK accessibility read is not implemented yet>".to_owned()
        }
    }

    fn resize_window(&self, window: u64, width: f64, height: f64) {
        // The REAL resize path: the size a user's drag would set.
        Self::on_main_mut(move |core| {
            use gtk4::prelude::GtkWindowExt;
            gtk_window(core, window).set_default_size(width as i32, height as i32);
        });
        // WAIT FOR THE ALLOCATION, then re-run the arm. set_default_size
        // returns before GTK has laid out, so an arm that re-ran
        // immediately measured the OLD width and stamped the OLD
        // presentation — while the assertion, polling a beat later, saw
        // the new one. The two disagreeing about one instant is the
        // signature of reading a tree mid-update (docs/traps.md).
        //
        // Polled from the HARNESS thread, never by pumping the main
        // loop from inside a CoreState borrow: re-entering CORE there
        // aborts.
        // Wait until the allocation lands on the SAME SIDE OF THE
        // BOUNDARY as the request — not until it equals it. A window
        // manager (or, under Xvfb, its absence) is free to grant a
        // different size, so exact equality never held and every resize
        // paid the full timeout instead of ~a frame. The size class is
        // the only thing the arm reads, so it is the only thing worth
        // waiting for.
        let want_regular = width >= 600.0;
        for _ in 0..100 {
            let now = f64::from(Self::on_main(move |core| window_width(core, window)));
            if (now >= 600.0) == want_regular {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        Self::on_main_mut(move |core| {
            refresh_nav(core, window);
        });
    }

    fn split_presentation(&self) -> String {
        Self::on_main(|core| {
            use gtk4::prelude::GtkWindowExt;
            // The class from the window's real width, the same 600
            // boundary menu_presentation draws; the presentation from
            // the arm that actually ran.
            // The SAME source the arm used.
            let width = window_width(core, 0);
            let class = if width >= 600 { "regular" } else { "compact" };
            // THE WIDGET'S OWN ANSWER, not a value the arm stamped
            // about itself: GNOME decides where this collapses, so
            // asking anything else would be asking kaya what kaya did.
            // A window that never requested list-detail has no widget,
            // and falls back to the serial arm's stamp.
            let presentation = match core.split_views.get(&0) {
                Some(view) => {
                    if view.is_collapsed() {
                        "stacked"
                    } else {
                        "split"
                    }
                }
                None => core.split_presentation.get(&0).copied().unwrap_or("stacked"),
            };
            format!("{class}/{presentation}")
        })
    }

    fn menu_presentation(&self) -> String {
        Self::on_main(|core| {
            use gtk4::prelude::GtkWindowExt;
            // GTK4 has no size-class API of its own (libadwaita's
            // AdwBreakpoint is the nearest, and this backend does not
            // depend on it), so the class comes from the window's real
            // content width against the same 600 boundary the other
            // platforms draw — default_size on a mapped toplevel, the
            // notion window_content_size already reads.
            let width = gtk_window(core, 0).default_size().0;
            let class = if width >= 600 { "regular" } else { "compact" };
            // The presentation is read off the REAL chrome — a
            // PopoverMenuBar exists or it does not. GTK has only the
            // bar lowering, so there is no arm to disagree with the
            // class; that is a fact about this backend, recorded, not
            // an inference.
            let bar = core
                .menu_models
                .get(&0)
                .map(|model| {
                    use gtk4::gio::prelude::MenuModelExt;
                    model.n_items() > 0
                })
                .unwrap_or(false);
            format!("{class}/{}", if bar { "bar" } else { "none" })
        })
    }

    fn menu_state(&self, path: &str, aspect: crate::harness::MenuAspect) -> String {
        let path = path.to_owned();
        Self::on_main(move |core| {
            use crate::harness::MenuAspect;
            use gtk4::gio::prelude::ActionExt;
            // TOTAL, the try_resolve style: a missing item is a
            // retryable miss — expect_menu doubles as the wait for a
            // catalog rebuild — never a panic. The OPEN context menu
            // owns resolution exclusively while presented.
            let reg = core.menus.borrow();
            let open = *core.open_context.borrow();
            let roots = match open {
                Some(anchor) => match core.context_menus.get(&anchor) {
                    Some(attachment) => attachment.roots.clone(),
                    None => return "no such item".to_owned(),
                },
                None => reg.bars.get(&0).cloned().unwrap_or_default(),
            };
            let Some(id) = menu_resolve_path(&reg, &roots, &path) else {
                return "no such item".to_owned();
            };
            let item = &reg.items[&id];
            match aspect {
                MenuAspect::Enablement => {
                    // The REAL action's flag where one exists (it
                    // carries the inherited AND) — including a radio
                    // option's own action, which is what grays that one
                    // row. Grouping nodes have no GAction, so the
                    // registry's same AND answers for them.
                    let enabled = match item.actions.first() {
                        Some(action) => action.is_enabled(),
                        None => menu_effective_enabled(&reg, id),
                    };
                    if enabled { "enabled" } else { "disabled" }.to_owned()
                }
                MenuAspect::Checkedness => {
                    // The stateful action's own bool — what GMenu
                    // renders as the checkmark.
                    match item
                        .actions
                        .first()
                        .and_then(|action| action.state())
                        .and_then(|state| state.get::<bool>())
                    {
                        Some(true) => "checked".to_owned(),
                        Some(false) => "unchecked".to_owned(),
                        None => "not a toggle".to_owned(),
                    }
                }
                MenuAspect::Value => {
                    // The state lives on the OPTIONS' actions, one per
                    // option and all carrying the group's selected
                    // index (that index is what each row compares its
                    // target against to draw the radio mark). Reading
                    // the first option's action therefore reads what
                    // GMenu renders — and a group with no options yet
                    // has no such state to read.
                    match item
                        .children
                        .first()
                        .and_then(|option| reg.items[option].actions.first())
                        .and_then(|action| action.state())
                        .and_then(|state| state.get::<i32>())
                    {
                        Some(index) => format!("value {index}"),
                        None => "not a radio group".to_owned(),
                    }
                }
            }
        })
    }

    fn shortcut(&self, spelling: &str) {
        let spelling = spelling.to_owned();
        Self::on_main(move |core| {
            // The platform's own table: the application accelerator
            // map that set_accels_for_action filled — the exact table
            // GtkApplicationWindow's accel controller walks for a
            // real key press. A chord no catalog action owns is a
            // SILENT no-op (the dress must never swallow it — the
            // interpreters' rule), which the map gates structurally:
            // only catalog actions are ever registered in it.
            let Some(app) = core.app.as_ref() else { return };
            let accel = menu_accel(&spelling)
                .unwrap_or_else(|| panic!("kaya: shortcut {spelling:?}: unmappable spelling"));
            let want = gtk4::accelerator_parse(&accel).unwrap_or_else(|| {
                panic!("kaya: shortcut {spelling:?}: GTK rejected accelerator {accel:?}")
            });
            for description in app.list_action_descriptions() {
                let owns = app
                    .accels_for_action(&description)
                    .iter()
                    .any(|a| gtk4::accelerator_parse(a) == Some(want));
                if !owns {
                    continue;
                }
                // The action machinery end to end: resolve the
                // detailed name through the owning window's muxer —
                // where the accel controller lands a key event — so
                // the SAME GSimpleAction handler emits the SAME
                // menu_activated a direct activation would.
                // A DETAILED name carries an option's target —
                // `win.kmi-7(1)` — and activate_action takes a plain
                // name plus the parameter, never the detailed
                // spelling. Splitting it is what lets one option of a
                // group answer its own chord.
                let Ok((name, param)) = gio::Action::parse_detailed_name(&description) else {
                    continue;
                };
                let target = name
                    .strip_prefix("win.kmi-")
                    .and_then(|id| id.parse::<u64>().ok())
                    .and_then(|id| {
                        let reg = core.menus.borrow();
                        reg.bar_of.get(&menu_root_of(&reg, id)).copied()
                    })
                    .map(|window| gtk_window(core, window))
                    .unwrap_or_else(|| core.window.clone());
                let _ = target.activate_action(&name, param.as_ref());
                return;
            }
            // Nothing in the catalog owns this chord — a script error,
            // said out loud rather than passing as a no-op (the WinUI
            // lesson, docs/traps.md).
            panic!(
                "kaya: shortcut {spelling:?}: no catalog item owns this chord \
                 (the leaf kinds that may carry one are action, toggle, and \
                 radio option)"
            );
        });
    }

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
            // The user path per kind: the buffer/entry change signal
            // fires and emits (the quiet guard is off).
            if t.kind == crate::harness::TargetKind::Textarea {
                let i = crate::harness::resolve(t.index, core.textareas.len());
                core.textareas[i].buffer().set_text(&text);
                return;
            }
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
            if t.kind == crate::harness::TargetKind::Textarea {
                let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len()) else {
                    return "<no such target>".to_string();
                };
                let b = core.textareas[i].buffer();
                return lf(b.text(&b.start_iter(), &b.end_iter(), false).to_string());
            }
            let Some(i) = crate::harness::try_resolve(t.index, core.entries.len()) else {
                return "<no such target>".to_string();
            };
            lf(core.entries[i].text().to_string())
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
                crate::harness::TargetKind::Textarea => {
                    let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len())
                    else {
                        return false;
                    };
                    core.textareas[i]
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
            //
            // ONE PATH, list-detail included. This used to special-case
            // a split window by activating `navigation.pop` on the view
            // directly, on the belief that libadwaita's own back button
            // was the affordance being driven. There was no such button
            // (see refresh_nav), so the harness popped a collapsed
            // window that showed nothing to press — the verb inventing
            // an affordance, which is the failure the check below
            // exists to prevent. The split arm now shows kaya's button
            // when collapsed, so this path covers both arms and the
            // two-pane rule falls out of the SAME visibility test:
            // two panes, no button, nothing to drive.
            //
            // A HIDDEN button is not an affordance. emit_clicked runs
            // the handler regardless of visibility, so without this the
            // harness could pop where a user has no button to press,
            // and the two-pane back rule would pass its own test while
            // being false on screen.
            if let Some(back) = core.back_buttons.get(&window).cloned() {
                if !gtk4::prelude::WidgetExt::get_visible(&back) {
                    return;
                }
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

    fn grid_columns(&self, t: crate::harness::Target, want: usize) -> String {
        Self::on_main(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.grids.len()) else {
                return "<no such target>".to_string();
            };
            let grid = &core.grids[i];
            // Geometry, never the model's columns copy: cluster the
            // cells' leading edges (allocations are parent-relative
            // in GTK4); the distinct clusters ARE the columns.
            let mut edges: Vec<i32> = Vec::new();
            let mut child = grid.first_child();
            while let Some(c) = child {
                edges.push(c.allocation().x());
                child = c.next_sibling();
            }
            if edges.is_empty() {
                return "no cells".to_string();
            }
            edges.sort_unstable();
            let mut clusters = 0;
            let mut last = i32::MIN;
            for x in edges {
                if clusters == 0 || x - last > 2 {
                    clusters += 1;
                    last = x;
                }
            }
            if clusters == want {
                String::new()
            } else {
                format!("{clusters} column edges, wanted {want}")
            }
        })
    }

    fn choose(&self, t: crate::harness::Target, index: usize) {
        Self::on_main(move |core| {
            // The REAL selection route per kind, quiet guard off so
            // the native signal emits exactly as a user pick does.
            if t.kind == crate::harness::TargetKind::Radio {
                let i = crate::harness::resolve(t.index, core.radios.len());
                let group = &core.radios[i];
                for (id, buttons) in &core.radio_buttons {
                    if matches!(core.widgets.get(&WidgetId(*id)),
                                Some(NativeWidget::Radio(b)) if b == group)
                    {
                        if let Some(check) = buttons.get(index) {
                            check.set_active(true);
                        }
                        return;
                    }
                }
                return;
            }
            let i = crate::harness::resolve(t.index, core.selects.len());
            core.selects[i].set_selected(index as u32);
        });
    }

    fn selected_label(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            if t.kind == crate::harness::TargetKind::Radio {
                // The REAL control's state: the ACTIVE grouped
                // CheckButton's own label.
                let Some(i) = crate::harness::try_resolve(t.index, core.radios.len()) else {
                    return "<no such target>".to_string();
                };
                let group = &core.radios[i];
                for (id, buttons) in &core.radio_buttons {
                    if matches!(core.widgets.get(&WidgetId(*id)),
                                Some(NativeWidget::Radio(b)) if b == group)
                    {
                        return buttons
                            .iter()
                            .find(|c| c.is_active())
                            .and_then(|c| c.label())
                            .map(|l| l.to_string())
                            .unwrap_or_default();
                    }
                }
                return String::new();
            }
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

    fn file_dialog_state(&self) -> Option<(String, Vec<String>)> {
        // DEPTH SLICE: the SwiftUI arm lands first, and this backend's
        // apply arm refuses the record outright — so no picker can be
        // live here and None is the honest answer, not a stub hiding a
        // gap. check-stubs is what keeps a runner from wiring the
        // scene's legs against this.
        None
    }

    fn choose_file(&self, _: Option<&str>) {}

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

    fn section_count(&self) -> usize {
        // The REAL switcher's page model, never the section map.
        Self::on_main(|core| {
            use gtk4::prelude::Cast;
            use gtk4::gio::prelude::ListModelExt;
            core.section_stacks
                .get(&0)
                .map(|stack| stack.pages().upcast_ref::<gtk4::gio::ListModel>().n_items() as usize)
                .unwrap_or(0)
        })
    }

    fn active_section_title(&self) -> String {
        // The visible page's OWN title from the stack — the
        // platform's selection state, not the model mirror.
        Self::on_main(|core| {
            use gtk4::prelude::WidgetExt;
            let Some(stack) = core.section_stacks.get(&0) else {
                return String::new();
            };
            let Some(child) = stack.visible_child() else {
                return String::new();
            };
            stack
                .page(&child)
                .title()
                .map(|t| t.to_string())
                .unwrap_or_default()
        })
    }

    fn select_section(&self, index: usize) {
        // The user's route: reconcile, move the stack under the echo
        // guard (the notify handler cannot re-borrow CORE from inside
        // this closure), and emit exactly once — the WinUI
        // synchronous-emit pattern.
        Self::on_main_mut(move |core| {
            let ids = core.sections.get(&0).cloned().unwrap_or_default();
            let Some(&sid) = ids.get(index) else { return };
            if core.selected_sections.get(&0) == Some(&sid) {
                return;
            }
            core.selected_sections.insert(0, sid);
            core.scene
                .user_selected_section(WindowId(0), WindowId(sid));
            core.apply_quiet.set(true);
            if let Some(stack) = core.section_stacks.get(&0) {
                stack.set_visible_child_name(&sid.to_string());
            }
            core.apply_quiet.set(false);
            core.occurrences.send(Occurrence::SectionSelected {
                window: WindowId(0),
                section: WindowId(sid),
            });
        });
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

/// The widget a `kind#index` target names, from the per-kind registry
/// every other verb resolves through — creation order, which is what
/// `kind#index` means.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn target_widget(core: &CoreState, target: crate::harness::Target) -> Option<gtk4::Widget> {
    use crate::harness::{try_resolve, TargetKind as K};
    use gtk4::prelude::Cast;
    macro_rules! nth {
        ($reg:expr) => {
            try_resolve(target.index, $reg.len()).map(|i| $reg[i].clone().upcast())
        };
    }
    match target.kind {
        K::Button => nth!(core.buttons),
        K::Checkbox => nth!(core.checkboxes),
        K::Label => nth!(core.labels),
        K::Entry => nth!(core.entries),
        K::Textarea => nth!(core.textareas),
        K::Slider => nth!(core.sliders),
        K::Image => nth!(core.images),
        K::Progress => nth!(core.progresses),
        K::Select => nth!(core.selects),
        K::Radio => nth!(core.radios),
        K::Grid => nth!(core.grids),
        K::Scroll => nth!(core.scrolls),
        K::Row => nth!(core.rows),
        K::Column => nth!(core.columns),
    }
}

/// The AT-SPI role GTK publishes for this widget — MEASURED off the bus
/// (tools/linux/atspi_probe.py), not assumed, and deliberately narrow:
/// it answers only for the roles a scene can assert.
///
/// It exists because the bus tree is NOT kaya's tree. GTK publishes
/// widgets kaya never created (every button and check box contains a
/// GtkLabel, and those labels are real Label nodes on the bus) and
/// hides some it did (an entry's internal GtkText does not appear at
/// all). Ranking a target among the widgets that publish the SAME role
/// is what turns kaya's per-kind index into the bus's ordinal, and
/// getting the set wrong is silent: it reads the wrong element's name.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_role_of(w: &gtk4::Widget) -> Option<atspi::Role> {
    use gtk4::prelude::{AccessibleExt, Cast};
    // A ScrolledWindow FIRST, before the promotion check below: the
    // lowering names it like any other container, and GTK takes the
    // name but NOT the role — the bus still publishes `scroll pane`
    // (measured). Reading the promotion here instead would rank it
    // among groupings and shift every named container after it.
    if w.is::<gtk4::ScrolledWindow>() {
        return Some(atspi::Role::ScrollPane);
    }
    // A container kaya NAMED was promoted to Group by the lowering, and
    // Group is exactly what the bus then publishes for it.
    if w.accessible_role() == gtk4::AccessibleRole::Group {
        return Some(atspi::Role::Grouping);
    }
    if w.is::<gtk4::Label>() {
        // Kaya's labels AND the captions inside buttons and check
        // boxes: all of them are Label nodes on the bus.
        return Some(atspi::Role::Label);
    }
    if w.is::<gtk4::CheckButton>() {
        // A grouped check button IS a radio button, and GTK says so
        // through the accessible role it assigns.
        return Some(if w.accessible_role() == gtk4::AccessibleRole::Radio {
            atspi::Role::RadioButton
        } else {
            atspi::Role::CheckBox
        });
    }
    // ToggleButton is a Button subclass and must not count as one: the
    // drop-down's internal button is a toggle, and the bus agrees.
    if w.is::<gtk4::ToggleButton>() {
        return Some(atspi::Role::ToggleButton);
    }
    if w.is::<gtk4::Button>() {
        return Some(atspi::Role::Button);
    }
    // Both editable kinds are role Text on the bus — the very collision
    // that made `textarea#0` read the entry's name.
    if w.is::<gtk4::Entry>() || w.is::<gtk4::TextView>() {
        return Some(atspi::Role::Text);
    }
    if w.is::<gtk4::Scale>() {
        return Some(atspi::Role::Slider);
    }
    if w.is::<gtk4::Picture>() {
        return Some(atspi::Role::Image);
    }
    if w.is::<gtk4::ProgressBar>() {
        return Some(atspi::Role::ProgressBar);
    }
    if w.is::<gtk4::DropDown>() {
        return Some(atspi::Role::ComboBox);
    }
    None
}

/// This widget's rank among the widgets of the SAME AT-SPI role in the
/// window, walked depth-first — which is the order the bus publishes,
/// so the rank IS the ordinal of its node there.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_rank(window: &gtk4::Window, target: &gtk4::Widget) -> Option<usize> {
    use gtk4::prelude::Cast;
    let want = atspi_role_of(target)?;
    fn walk(
        node: &gtk4::Widget,
        target: &gtk4::Widget,
        want: atspi::Role,
        rank: &mut usize,
    ) -> bool {
        use gtk4::prelude::WidgetExt;
        if node == target {
            return true;
        }
        // THE BUS PUBLISHES WHAT IS ON SCREEN. An unmapped subtree has
        // no accessible nodes, so counting it shifts every ordinal
        // after it: a drop-down's popover carries its own
        // GtkScrolledWindow, and counting that one made the scene's
        // real scroll viewport ScrollPane#1 on a bus that published
        // exactly one (measured 2026-07-25).
        if !node.is_mapped() {
            return false;
        }
        if atspi_role_of(node) == Some(want) {
            *rank += 1;
        }
        let mut child = node.first_child();
        while let Some(c) = child {
            if walk(&c, target, want, rank) {
                return true;
            }
            child = c.next_sibling();
        }
        false
    }
    let mut rank = 0;
    let root: gtk4::Widget = window.clone().upcast();
    // A target that is not in this window's tree has no ordinal at all,
    // which is a finding rather than a zero.
    if !walk(&root, target, want, &mut rank) {
        return None;
    }
    Some(rank)
}

/// Read this app's accessibility tree over AT-SPI, as a real assistive
/// client does.
///
/// GTK exposes NO getter for accessible properties — the accessible
/// surface IS AT-SPI — so an in-process read would only return kaya's
/// own writes. Going over the bus is the only honest route, and it is
/// why the harness (and this dependency) is feature-gated: a shipped
/// app must never link a dbus client to serve a test verb.
#[cfg(all(feature = "harness", target_os = "linux"))]
fn atspi_collect(want: atspi::Role, index: usize, want_description: bool) -> Option<String> {
    use atspi::proxy::accessible::AccessibleProxy;
    atspi::zbus::block_on(async move {
        let conn = atspi::connection::AccessibilityConnection::new()
            .await
            .ok()?;
        let root = AccessibleProxy::builder(conn.connection())
            .destination("org.a11y.atspi.Registry")
            .ok()?
            .path("/org/a11y/atspi/accessible/root")
            .ok()?
            .build()
            .await
            .ok()?;
        let me = std::process::id();
        let mut found: Vec<(atspi::Role, String, String)> = Vec::new();
        // Depth-first over OUR application only. Roles are matched on
        // the enum, not a localized name string.
        async fn walk(
            node: AccessibleProxy<'_>,
            out: &mut Vec<(atspi::Role, String, String)>,
            depth: usize,
        ) {
            if depth > 24 {
                return;
            }
            if let (Ok(role), Ok(name), Ok(description)) =
                (node.get_role().await, node.name().await, node.description().await)
            {
                out.push((role, name, description));
            }
            let Ok(children) = node.get_children().await else {
                return;
            };
            for child in children {
                let Some(dest) = child.name() else { continue };
                let Ok(proxy) = AccessibleProxy::builder(node.inner().connection())
                    .destination(dest.to_owned())
                    .and_then(|b| b.path(child.path().to_owned()))
                else {
                    continue;
                };
                if let Ok(proxy) = proxy.build().await {
                    Box::pin(walk(proxy, out, depth + 1)).await;
                }
            }
        }
        for app in root.get_children().await.ok()? {
            let Some(dest) = app.name() else { continue };
            let Ok(builder) = AccessibleProxy::builder(conn.connection())
                .destination(dest.to_owned())
                .and_then(|b| b.path(app.path().to_owned()))
            else {
                continue;
            };
            let Ok(proxy) = builder.build().await else { continue };
            // Only our own process's application node.
            if proxy.get_application().await.is_err() {
                continue;
            }
            let _ = me;
            Box::pin(walk(proxy, &mut found, 0)).await;
        }
        let nth = found.iter().filter(|(r, _, _)| *r == want).nth(index);
        if nth.is_none() {
            // A miss is never self-explaining: the question is always
            // what the bus DID publish, and one container round-trip
            // per answer is the expensive way to learn it.
            eprintln!(
                "KAYA_AX_TRACE: no {want:?}#{index} on the bus; it published {:?}",
                found
                    .iter()
                    .map(|(r, n, _)| format!("{r:?}/{n}"))
                    .collect::<Vec<_>>()
            );
        }
        nth.map(|(_, name, description)| {
            if want_description { description.clone() } else { name.clone() }
        })
    })
}
