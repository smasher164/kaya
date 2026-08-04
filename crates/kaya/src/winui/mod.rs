//! WinUI 3 backend: an interpreter of resolved apply-ops.
//!
//! Same architecture as the AppKit backend: the core owns the UI thread
//! and the XAML dispatcher; the button's Click handler pushes an
//! occurrence and never calls app code; commands come back on their own
//! channel; DispatcherQueue::TryEnqueue is the doorbell (the GCD
//! equivalent), carrying no data.
//!
//! This backend is the de-risking experiment for "WinUI 3 from Rust via
//! COM, no XAML files, no C#". Known uncertainty, to be settled in the
//! VM: whether creating the window from a plain `Application` (no
//! subclass, UI built from a dispatcher callback after `Start`) is
//! sufficient, or whether `IApplicationOverrides` composition is needed
//! for `OnLaunched`.

#[allow(
    non_snake_case,
    non_camel_case_types,
    non_upper_case_globals,
    dead_code,
    clippy::all
)]
mod bindings;

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::mpsc::Receiver;
use std::sync::OnceLock;

use windows_core::{HSTRING, Interface as _};

use bindings::Microsoft::UI::Dispatching::{DispatcherQueue, DispatcherQueueHandler};
use bindings::Microsoft::UI::Xaml::Controls::{
    Button, CheckBox, ColumnDefinition, ComboBox, ComboBoxItem, ContentDialog,
    ContentDialogButton, ContentDialogResult, Grid, Image, MenuBar, MenuBarItem, MenuFlyout,
    MenuFlyoutItem, MenuFlyoutItemBase, MenuFlyoutSeparator, MenuFlyoutSubItem, NavigationView,
    NavigationViewItem, NavigationViewPaneDisplayMode, ProgressBar, RadioMenuFlyoutItem,
    RowDefinition,
    RadioButtons, ScrollBarVisibility, ScrollMode, ScrollViewer, SelectionChangedEventHandler,
    Slider, TextBlock, TextBox, TextChangedEventHandler, ToggleMenuFlyoutItem, TwoPaneView,
    TwoPaneViewMode, TwoPaneViewPriority, TwoPaneViewWideModeConfiguration,
};
use bindings::Windows::Foundation::TypedEventHandler;
use bindings::Microsoft::UI::Xaml::Input::KeyboardAccelerator;
use bindings::Windows::System::{VirtualKey, VirtualKeyModifiers};
use bindings::Microsoft::UI::Xaml::{GridLength, GridUnitType, Thickness, Visibility};
use bindings::Microsoft::UI::Xaml::Media::Imaging::BitmapImage;
use bindings::Windows::Foundation::{IReference, PropertyValue};
use bindings::Windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};
use bindings::Microsoft::UI::Xaml::{
    Application, ApplicationInitializationCallback, FocusState, FrameworkElement,
    RoutedEventHandler, UIElement, UnhandledExceptionEventHandler, Window,
};

use crate::protocol::{
    ApplyOp, CommandKind, MenuAttachment, MenuItemId, MenuItemKind, MenuProp, OccSink, Occurrence,
    Path, Prop, Transaction, Value, WidgetId, WidgetKind, WindowId, WindowProp,
    purge_context_natives,
};
use crate::scene::Scene;

enum NativeWidget {
    Column(Grid),
    Row(Grid),
    Checkbox { check: CheckBox, caption: TextBlock },
    Slider(Slider),
    // The caption TextBlock is the button's text surface.
    Button { button: Button, caption: TextBlock },
    Label(TextBlock),
    Entry(TextBox),
    Image(Image),
    Scroll(ScrollViewer),
    Progress(ProgressBar),
    Select(ComboBox),
    Radio(RadioButtons),
    /// The 2D grid widget (KIND_GRID) — a WinUI Grid with Auto
    /// tracks, distinct from Column/Row's star-sized Grids.
    Grid2D(Grid),
    Textarea(TextBox),
}

impl NativeWidget {
    fn element(&self) -> windows_core::Result<UIElement> {
        use windows_core::Interface;
        match self {
            NativeWidget::Column(panel) => panel.cast(),
            NativeWidget::Row(panel) => panel.cast(),
            NativeWidget::Checkbox { check, .. } => check.cast(),
            NativeWidget::Slider(slider) => slider.cast(),
            NativeWidget::Button { button, .. } => button.cast(),
            NativeWidget::Label(label) => label.cast(),
            NativeWidget::Entry(field) => field.cast(),
            NativeWidget::Image(image) => image.cast(),
            NativeWidget::Scroll(viewer) => viewer.cast(),
            NativeWidget::Progress(bar) => bar.cast(),
            NativeWidget::Select(combo) => combo.cast(),
            NativeWidget::Radio(group) => group.cast(),
            NativeWidget::Grid2D(grid) => grid.cast(),
            NativeWidget::Textarea(field) => field.cast(),
        }
    }
}

struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    /// The directory the next picker opens on.
    ///
    /// ARMED, NOT SET: a dialog reads its folder when it is shown, so
    /// the harness's file_dialog_goto stores it here and the apply arm
    /// applies it. Same shape as GTK and the SwiftUI interpreter, for
    /// the same reason — pointing one already on screen is ignored.
    pending_dialog_dir: RefCell<Option<String>>,
    widgets: HashMap<WidgetId, NativeWidget>,
    // Which grid each widget sits in, for Destroy's detach.
    parents: HashMap<WidgetId, Grid>,
    // Grid places by attached Row/Column index, not by child order, so
    // the logical order has to be tracked here and stamped back onto the
    // children after every structural change. This is also the order the
    // definitions are rebuilt in — one definition per child, carrying
    // that child's grow weight.
    child_order: HashMap<WidgetId, Vec<WidgetId>>,
    grow: HashMap<WidgetId, f64>,
    /// Container align modes (the align spec enum's wire values):
    /// reindex stamps the cross alignment onto every child after any
    /// structural change, so late arrivals are covered by the same
    /// path that keeps Grid indices honest.
    aligns: HashMap<WidgetId, i64>,
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index. Clicks emit the stored
    // tag directly; the other controls fire their real events for the
    // stage's direct writes (SetIsChecked raises Checked, SetText
    // raises TextChanged, SetValue raises ValueChanged) — that is the
    // stage's user path. The APPLY path arms apply_quiet so property
    // writes stay silent (see that field).
    buttons: Vec<Vec<u8>>,
    checkboxes: Vec<CheckBox>,
    labels: Vec<TextBlock>,
    entries: Vec<TextBox>,
    /// Aligned with `entries`: the widget id per registry slot (the
    /// stage indexes by creation order; the maps below key by id).
    entry_ids: Vec<u64>,
    /// TextChanged is raised ASYNCHRONOUSLY, so programmatic text
    /// paths cannot ride it in order: SetProp, the clear command,
    /// and the stage's set_text all bump this counter, write the
    /// text, and (for the emitting paths) send the occurrence
    /// SYNCHRONOUSLY themselves — the late native raise is swallowed
    /// 1:1. User typing bumps nothing and emits through the real
    /// raise. Caught live 2026-07-22: without this, a click's
    /// occurrence OVERTAKES the edit and the guest's add handler
    /// runs on an empty draft.
    entry_swallow: HashMap<u64, std::sync::Arc<std::sync::atomic::AtomicUsize>>,
    entry_tags: HashMap<u64, Vec<u8>>,
    sliders: Vec<Slider>,
    images: Vec<Image>,
    scrolls: Vec<ScrollViewer>,
    progresses: Vec<ProgressBar>,
    selects: Vec<ComboBox>,
    radios: Vec<RadioButtons>,
    grids: Vec<Grid>,
    textareas: Vec<TextBox>,
    textarea_ids: Vec<u64>,
    /// Grid layout state: ordered children + column count; both the
    /// adds and the columns prop re-flow the attach positions
    /// (children-first sugars emit adds before the prop).
    grid_children: HashMap<u64, Vec<UIElement>>,
    grid_cols: HashMap<u64, i32>,
    /// Radio plumbing, the select_options shape: label id -> (its
    /// group, its row in the group's Items vector) — option text
    /// updates land with SetAt.
    radio_options: HashMap<u64, (RadioButtons, u32)>,
    /// Option-label plumbing: label widget id -> (its select's
    /// ComboBox, its option row's own TextBlock). A select's label
    /// children are its OPTIONS — ComboBoxItems in the popup, not
    /// standalone widgets — so their SetProp text lands on the row
    /// as STRING content and they leave the harness's label
    /// registry. Strings, never a TextBlock: a UIElement content is
    /// STOLEN into the collapsed box's SelectionBoxItem while its
    /// row is selected (one visual tree), and the row's Content()
    /// reads back null — caught live 2026-07-22 as a null-interface
    /// panic that wedged the dispatcher.
    select_options: HashMap<u64, (ComboBox, ComboBoxItem)>,
    /// Echo guard for EVERY interactive kind: WinUI's change events
    /// (TextChanged, Checked/Unchecked, ValueChanged,
    /// SelectionChanged) cannot tell a user act from a programmatic
    /// write, and only the USER path may emit an occurrence — a
    /// property write is state configuration, never an event
    /// (without this, a handler that writes back a different value
    /// than it received ping-pongs through the native event
    /// forever). Armed around every SetProp write to an interactive
    /// widget. Commands (clear) and the harness stage's direct
    /// writes stay unguarded ON PURPOSE: a command acts like the
    /// user, and both must reach the app through the widget's own
    /// path. Atomic because WinRT event handlers are Send-bound
    /// (they still fire on this thread).
    apply_quiet: std::sync::Arc<std::sync::atomic::AtomicBool>,
    columns: Vec<Grid>,
    rows: Vec<Grid>,
    window: Window,
    /// Auxiliary surfaces by kaya window id (the primary is
    /// `window`); created hidden, presented (Activated) at mount.
    aux_windows: HashMap<u64, Window>,
    /// veto_close per window id (primary included; default false).
    window_veto: HashMap<u64, bool>,
    /// App-initiated teardown bypasses the chrome-close grammar:
    /// Window.Close() rides WM_CLOSE, and without this a veto window
    /// would swallow its own confirmed destruction (and a non-veto
    /// one would report a spurious window_closed).
    tearing_down: std::collections::HashSet<u64>,
    /// The live modal alert (one per process): the request's identity
    /// plus the REAL ContentDialog for the runner's reads and press.
    /// Cleared by the ShowAsync completion — the one emit site.
    live_alert: Option<WinLiveAlert>,
    /// Live navigation entries by surface id, and per-window stacks
    /// bottom to top (DESIGN.md, Navigation); the window's own root
    /// and title come back when its stack empties.
    nav_entries: HashMap<u64, WinNavEntry>,
    nav_stacks: HashMap<u64, Vec<u64>>,
    /// list_detail per window (wprop 6) and the presentation
    /// refresh_nav ACTUALLY rendered — stamped by the arm that ran,
    /// never derived (docs/traps.md).
    list_detail: HashMap<u64, bool>,
    split_presentation: HashMap<u64, &'static str>,
    /// The live list-detail Grid per window, kept so the next render
    /// can release the roots it holds (see release_split).
    split_views: HashMap<u64, TwoPaneView>,
    window_roots: HashMap<u64, UIElement>,
    window_titles: HashMap<u64, String>,
    /// Sections (DESIGN.md, Sections): per-window ordered sets, pane
    /// containers by section id, the NavigationView that materializes
    /// the switcher (the platform's own idiom — viable now that the
    /// aggregation outer delegates QI; docs/traps.md), and the
    /// selection mirror. A section's pane swaps between its own root
    /// and its stack's top entry (stacks are per-surface; nav_stacks
    /// keys sections too).
    sections: HashMap<u64, Vec<u64>>,
    section_panes: HashMap<u64, WinSection>,
    section_navs: HashMap<u64, NavigationView>,
    section_items: HashMap<u64, NavigationViewItem>,
    /// The TextChanged lesson applied to the switcher: WinRT raises
    /// SelectionChanged ASYNCHRONOUSLY, so programmatic moves swallow
    /// the late raise via a counter (a flag's guard window closes too
    /// early), and only real user switches reach the handler body.
    section_swallow: HashMap<u64, std::sync::Arc<std::sync::atomic::AtomicUsize>>,
    /// What the CONTROL last showed — a no-op SetSelectedItem raises
    /// nothing, so the swallow only increments on a real move.
    ui_selected_sections: HashMap<u64, u64>,
    selected_sections: HashMap<u64, u64>,
    sections_presentation: HashMap<u64, i64>,
    /// Menus (DESIGN.md, Menus and the command vocabulary): the
    /// retained item model — kind fixed at create, every applicable
    /// prop live. This map is the POST-USER MIRROR (docs/traps.md):
    /// toggle/radio chrome owns the immediate user change, its Click
    /// handler updates checked/value here BEFORE emitting, and every
    /// rebuild starts from it. Items are never destroyed.
    menu_models: HashMap<u64, MenuModel>,
    /// Per-window top-level catalog items, in menubar-append order.
    menu_windows: HashMap<u64, Vec<u64>>,
    /// Context catalogs: attached root items per anchor widget, the
    /// stamped copy's key path (empty for a live widget — the noun
    /// every activation from that anchor stamps), and the one real
    /// MenuFlyout set as the element's ContextFlyout.
    context_roots: HashMap<u64, Vec<u64>>,
    context_nouns: HashMap<u64, Path>,
    context_flyouts: HashMap<u64, MenuFlyout>,
    /// (attachment, item id) -> its materialized native chrome,
    /// rebuilt with the catalog. Keyed PER ATTACHMENT: a template
    /// context catalog attaches the SAME item ids to every stamped
    /// copy, and the copy's keys ARE the noun (DESIGN.md, Menus) — a
    /// flat per-item map would keep only the last-built copy, in
    /// context_roots' arbitrary iteration order, and the harness
    /// would invoke that anchor's chrome (and emit ITS noun) from
    /// every other row (docs/traps.md). Separators and NESTED radio
    /// groups mint none (the group's options materialize inline —
    /// the checkmark idiom).
    menu_natives: HashMap<(MenuAttachment, u64), MenuNative>,
    /// The window shell (the ratified lowering): MenuBar in its own
    /// Auto row of a shell Grid, the window's real content in the
    /// Star-row slot beneath it. Built once per window at the first
    /// menubar_append; every content swap goes through the slot.
    menubars: HashMap<u64, MenuBar>,
    menu_slots: HashMap<u64, Grid>,
    /// Canonical shortcut spelling -> action item id for the PRIMARY
    /// window's catalog (the harness's target, the sections-precedent
    /// scoping). Gates the shortcut verb: a chord no catalog action
    /// owns is a silent no-op — checked before any OS-global
    /// injection (docs/traps.md). It also DISPATCHES every chord: the
    /// key hook resolves the pressed spelling here (The chord route),
    /// so what the verb gates on and what the app answers cannot
    /// disagree.
    menu_shortcuts: HashMap<String, u64>,
    /// The harness's OPEN context menu: anchor widget id plus the
    /// flyout handle, kept until Closed is awaited (the staged
    /// ShowAt ruling — the anchor row may be destroyed by the very
    /// occurrence the activation emits).
    open_context: Option<(u64, MenuFlyout)>,
    /// Coalesced per drain: any op touching the command surface sets
    /// it; one rebuild follows the batch.
    menus_touched: bool,
    /// Accept lists by widget id (the accepts prop; empty = unset =
    /// absent here). The paste split and Paste's enablement both read
    /// it. The root admits the prop on entries and textareas
    /// (scene.rs), whose identity tags entry_tags already carries.
    accepts: HashMap<u64, String>,
    /// A clipboard surface appeared (accepts / copy / read): the
    /// refresh sites consult it, so the scenes that never touch the
    /// clipboard pay nothing for the role recomputation.
    clipboard_armed: bool,
}

/// One section's materialized state: the pane Grid (the mount
/// target), its title, its own mounted root, and the hosting window.
struct WinSection {
    window: u64,
    pane: Grid,
    title: String,
    root: Option<UIElement>,
}

/// One navigation entry: a pushed scene root, retained while covered
/// (the wrapper Grid holds it), destroyed at pop. The wrapper's top
/// row is the backend-owned back bar — WinUI's back affordance here;
/// visible only while the entry is on screen by construction.
struct WinNavEntry {
    window: u64,
    title: String,
    /// The close-veto class transplanted to POP.
    intercept_back: bool,
    wrapper: Option<Grid>,
    back_button: Option<Button>,
}

/// The live alert's identity and its REAL dialog object.
struct WinLiveAlert {
    window: u64,
    actions: usize,
    dialog: ContentDialog,
}

/// One menu item's retained state (the post-user mirror; see
/// CoreState::menu_models). `primary` is stored but INERT on desktop
/// (the phone-promotion hint; DESIGN.md, Menus).
struct MenuModel {
    kind: MenuItemKind,
    label: String,
    enabled: bool,
    checked: bool,
    value: f64,
    primary: bool,
    /// A standard-command role from the closed vocabulary ("" =
    /// none). PLACEMENT is inert here (no dress-owned application
    /// menu), but the clipboard roles change BEHAVIOR: activation
    /// performs the command on the focused widget, and enablement
    /// folds in role_enabled (refresh_clipboard_roles).
    role: String,
    shortcut: String,
    children: Vec<u64>,
    parent: Option<u64>,
}

/// An item's materialized WinUI chrome, per the ratified 1:1 lowering:
/// MenuBarItem for a top-level grouping node (a bar-level radio_group
/// included — its options inline under the group's own title),
/// MenuFlyoutSubItem for a nested menu, and the three leaf item kinds.
#[derive(Clone)]
enum MenuNative {
    Bar(MenuBarItem),
    Sub(MenuFlyoutSubItem),
    Action(MenuFlyoutItem),
    Toggle(ToggleMenuFlyoutItem),
    Option(RadioMenuFlyoutItem),
}

impl MenuNative {
    /// The REAL chrome's enablement — what expect_menu reads. The
    /// rebuild stamps the inherited AND onto every native, so this is
    /// the effective value (docs/traps.md, inherited enablement).
    fn is_enabled(&self) -> windows_core::Result<bool> {
        match self {
            MenuNative::Bar(i) => i.IsEnabled(),
            MenuNative::Sub(i) => i.IsEnabled(),
            MenuNative::Action(i) => i.IsEnabled(),
            MenuNative::Toggle(i) => i.IsEnabled(),
            MenuNative::Option(i) => i.IsEnabled(),
        }
    }

    /// The write side of the same flag — what refresh_clipboard_roles
    /// stamps the intersection enablement through. The rebuild writes
    /// structural enablement alone, so every rebuild is followed by a
    /// role refresh.
    fn set_enabled(&self, on: bool) -> windows_core::Result<()> {
        match self {
            MenuNative::Bar(i) => i.SetIsEnabled(on),
            MenuNative::Sub(i) => i.SetIsEnabled(on),
            MenuNative::Action(i) => i.SetIsEnabled(on),
            MenuNative::Toggle(i) => i.SetIsEnabled(on),
            MenuNative::Option(i) => i.SetIsEnabled(on),
        }
    }
}

impl Drop for CoreState {
    fn drop(&mut self) {
        self.occurrences.send(Occurrence::Shutdown);
    }
}

thread_local! {
    static CORE: RefCell<Option<CoreState>> = const { RefCell::new(None) };
}

/// The UI thread's dispatcher, for waking it from other threads.
/// DispatcherQueue is agile (TryEnqueue is documented thread-safe); the
/// wrapper asserts that to the type system.
struct SharedDispatcher(DispatcherQueue);
unsafe impl Send for SharedDispatcher {}
unsafe impl Sync for SharedDispatcher {}

static DISPATCHER: OnceLock<SharedDispatcher> = OnceLock::new();

/// Exit code for when Application::Start returns. Clean shutdown goes
/// through Application::Exit on the UI thread; calling process::exit from
/// inside XAML dispatch tears down under the framework's feet (observed as
/// an access violation in XAML rundown).
static EXIT_CODE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);
/// Whether EXIT_CODE has been claimed — see request_exit.
static EXIT_DECIDED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

// The composed Application, kept from CreateInstance: the composition
// outer (KayaOuter) answers its own interfaces and forwards the rest
// delegate QI to the inner, so Application::Current() — whose identity
// is the outer — cannot be cast back to Application. Everything the
// backend needs goes through this handle instead. UI thread only.
thread_local! {
    static APP: RefCell<Option<Application>> = const { RefCell::new(None) };
}

fn request_exit(code: i32) {
    // First writer wins, and it is not a nicety: Application.Exit()
    // closes the window, which fires Closed, which calls back in here
    // with 0. A plain store therefore overwrote a failing verdict's 1
    // with the close handler's 0 microseconds later, and every failing
    // Windows leg exited 0 — the suite greps EXIT=0, so a FAILED scene
    // reported PASS. Whoever decides the outcome first owns it; a
    // window closing afterwards is a consequence of that decision, not
    // a new one.
    if !EXIT_DECIDED.swap(true, std::sync::atomic::Ordering::Relaxed) {
        EXIT_CODE.store(code, std::sync::atomic::Ordering::Relaxed);
    }
    APP.with_borrow(|app| match app.as_ref() {
        Some(app) => {
            if let Err(e) = app.Exit() {
                eprintln!("kaya: winui Application.Exit failed: {}", e.message());
            }
        }
        None => eprintln!("kaya: winui request_exit before the app existed"),
    });
}

/// Wake the UI thread so it drains pending transactions. Safe to call
/// from any thread. The enqueued closure carries no data.
pub(crate) fn ring_doorbell() {
    if let Some(dispatcher) = DISPATCHER.get() {
        let handler = DispatcherQueueHandler::new(|| {
            drain_transactions();
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
    }
}

/// Recompute the clipboard roles' enablement ONE TICK LATER. The
/// callers are event handlers that can fire while CORE is borrowed —
/// a Focus() inside apply raises GotFocus, and the WNDPROC re-enters
/// CORE by construction — so neither may borrow here and now (the
/// close_window precedent). The tick defers past whatever borrow is
/// live.
fn defer_role_refresh() {
    if let Some(dispatcher) = DISPATCHER.get() {
        let handler = DispatcherQueueHandler::new(|| {
            CORE.with_borrow(|core| {
                if let Some(core) = core.as_ref() {
                    if core.clipboard_armed {
                        refresh_clipboard_roles(core);
                    }
                }
            });
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
    }
}

fn drain_transactions() {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        while let Ok(tx) = core.transactions.try_recv() {
            for op in core.scene.apply(tx) {
                apply(core, op).expect("kaya: applying an op failed");
            }
        }
        // ONE coalesced menu-chrome rebuild per drain, from the
        // post-user mirror. Quiet-armed as a belt: constructing and
        // stamping native items must never read as user activation
        // (the echo doctrine).
        if core.menus_touched {
            core.menus_touched = false;
            core.apply_quiet
                .store(true, std::sync::atomic::Ordering::Relaxed);
            let rebuilt = rebuild_menus(core);
            core.apply_quiet
                .store(false, std::sync::atomic::Ordering::Relaxed);
            rebuilt.expect("kaya: rebuilding the menu chrome failed");
        }
    });
}

/// The minimal TextBox template: text editing needs only the
/// ScrollViewer named ContentElement; everything else of the default
/// chrome is styling this unpackaged app cannot resource-resolve.
const ENTRY_STYLE_XAML: &str = r#"<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="TextBox">
  <Setter Property="MinWidth" Value="160"/>
  <Setter Property="Padding" Value="6,4,6,4"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TextBox">
        <Border Background="{TemplateBinding Background}" BorderBrush="Gray" BorderThickness="1" CornerRadius="4">
          <ScrollViewer x:Name="ContentElement" Padding="{TemplateBinding Padding}" VerticalAlignment="Center"/>
        </Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>"#;

/// The load-bearing piece of code-only WinUI: the XAML parser resolves
/// non-core types (TextCommandBarFlyout inside TextBox's built-in
/// style, everything in XamlControlsResources) through an
/// IXamlMetadataProvider it obtains by QIing the Application object —
/// normally the subclass the XAML compiler generates. Without one,
/// deferred theme XAML fail-fasts the process
/// (STOWED_EXCEPTION_80004005 ... XamlSchemaContext::
/// GetTypeInfoProvider — microsoft-ui-xaml discussions #7357/#8151).
///
/// HAND-ROLLED, not #[implement]: the Application is composed via COM
/// aggregation with this object as the outer, and the AGGREGATION
/// CONTRACT requires the outer's QueryInterface to forward every IID
/// it does not implement to the inner's non-delegating IUnknown.
/// windows-core's #[implement] answers unknown IIDs with
/// E_NOINTERFACE instead, which made Application.Current() — an
/// identity QI for IApplication — fail 0x80004002, and every control
/// that consults it at runtime stow-crashed the process
/// (NavigationView's ResourceAccessor was the first; docs/traps.md).
///
/// Layout is three vtable slots at fixed offsets (identity /
/// IApplicationOverrides / IXamlMetadataProvider); the thunks recover
/// the object by subtracting the slot index. Lifetime is the process
/// (the framework holds the Application forever), so AddRef/Release
/// are counters in name only.
#[repr(C)]
struct KayaOuter {
    identity: *const windows_core::IInspectable_Vtbl,
    overrides: *const bindings::Microsoft::UI::Xaml::IApplicationOverrides_Vtbl,
    metadata: *const bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl,
    /// The inner's non-delegating IUnknown/IInspectable, set once
    /// after CreateInstance; QIs the outer cannot answer forward
    /// here. Null only during CreateInstance itself.
    inner: std::cell::Cell<*mut core::ffi::c_void>,
    // Lazily created: the provider activates WinUI machinery that is
    // not ready until the application object exists.
    provider: RefCell<
        Option<bindings::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider>,
    >,
}

static KAYA_OUTER_IDENTITY_VTBL: windows_core::IInspectable_Vtbl =
    windows_core::IInspectable_Vtbl {
        base: windows_core::IUnknown_Vtbl {
            QueryInterface: outer_qi::<0>,
            AddRef: outer_addref,
            Release: outer_release,
        },
        GetIids: outer_get_iids,
        GetRuntimeClassName: outer_get_class_name,
        GetTrustLevel: outer_get_trust_level,
    };

static KAYA_OUTER_OVERRIDES_VTBL: bindings::Microsoft::UI::Xaml::IApplicationOverrides_Vtbl =
    bindings::Microsoft::UI::Xaml::IApplicationOverrides_Vtbl {
        base__: windows_core::IInspectable_Vtbl {
            base: windows_core::IUnknown_Vtbl {
                QueryInterface: outer_qi::<1>,
                AddRef: outer_addref,
                Release: outer_release,
            },
            GetIids: outer_get_iids,
            GetRuntimeClassName: outer_get_class_name,
            GetTrustLevel: outer_get_trust_level,
        },
        OnLaunched: outer_on_launched,
    };

static KAYA_OUTER_METADATA_VTBL:
    bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl =
    bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl {
        base__: windows_core::IInspectable_Vtbl {
            base: windows_core::IUnknown_Vtbl {
                QueryInterface: outer_qi::<2>,
                AddRef: outer_addref,
                Release: outer_release,
            },
            GetIids: outer_get_iids,
            GetRuntimeClassName: outer_get_class_name,
            GetTrustLevel: outer_get_trust_level,
        },
        GetXamlType: outer_get_xaml_type,
        GetXamlTypeByFullName: outer_get_xaml_type_by_full_name,
        GetXmlnsDefinitions: outer_get_xmlns_definitions,
    };

/// Recover the object from a slot's `this` pointer.
unsafe fn outer_from_slot<const SLOT: isize>(this: *mut core::ffi::c_void) -> *const KayaOuter {
    unsafe { (this as *mut *const core::ffi::c_void).offset(-SLOT) as *const KayaOuter }
}

unsafe extern "system" fn outer_qi<const SLOT: isize>(
    this: *mut core::ffi::c_void,
    iid: *const windows_core::GUID,
    out: *mut *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    use windows_core::Interface;
    unsafe {
        if out.is_null() {
            return windows_core::imp::E_POINTER;
        }
        let outer = outer_from_slot::<SLOT>(this);
        let iid = &*iid;
        let slot: isize = if *iid == windows_core::IUnknown::IID
            || *iid == windows_core::IInspectable::IID
        {
            0
        } else if *iid
            == <bindings::Microsoft::UI::Xaml::IApplicationOverrides as Interface>::IID
        {
            1
        } else if *iid
            == <bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider as Interface>::IID
        {
            2
        } else {
            -1
        };
        if slot >= 0 {
            *out = (outer as *mut *const core::ffi::c_void).offset(slot)
                as *mut core::ffi::c_void;
            return windows_core::HRESULT(0);
        }
        // The aggregation contract: everything else is the inner's
        // business, through its NON-delegating IUnknown.
        let inner = (*outer).inner.get();
        if !inner.is_null() {
            let vtbl = *(inner as *mut *const windows_core::IUnknown_Vtbl);
            return ((*vtbl).QueryInterface)(inner, iid, out);
        }
        *out = core::ptr::null_mut();
        windows_core::imp::E_NOINTERFACE
    }
}

unsafe extern "system" fn outer_addref(_this: *mut core::ffi::c_void) -> u32 {
    // Process-lifetime object; the count is nominal.
    2
}

unsafe extern "system" fn outer_release(_this: *mut core::ffi::c_void) -> u32 {
    1
}

unsafe extern "system" fn outer_get_iids(
    _this: *mut core::ffi::c_void,
    count: *mut u32,
    values: *mut *mut windows_core::GUID,
) -> windows_core::HRESULT {
    unsafe {
        *count = 0;
        *values = core::ptr::null_mut();
    }
    windows_core::HRESULT(0)
}

unsafe extern "system" fn outer_get_class_name(
    _this: *mut core::ffi::c_void,
    value: *mut *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    let name = windows_core::HSTRING::from("Microsoft.UI.Xaml.Application");
    unsafe {
        *value = core::mem::transmute::<windows_core::HSTRING, *mut core::ffi::c_void>(name);
    }
    windows_core::HRESULT(0)
}

unsafe extern "system" fn outer_get_trust_level(
    _this: *mut core::ffi::c_void,
    value: *mut i32,
) -> windows_core::HRESULT {
    unsafe { *value = 0 };
    windows_core::HRESULT(0)
}

impl KayaOuter {
    fn provider(
        &self,
    ) -> windows_core::Result<
        bindings::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider,
    > {
        let mut slot = self.provider.borrow_mut();
        if slot.is_none() {
            *slot = Some(
                bindings::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider::new()?,
            );
        }
        Ok(slot.as_ref().expect("just filled").clone())
    }

    fn raw_provider(
        &self,
    ) -> windows_core::Result<bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider> {
        use windows_core::Interface;
        self.provider()?.cast()
    }
}

unsafe extern "system" fn outer_on_launched(
    this: *mut core::ffi::c_void,
    _args: *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    let _ = unsafe { outer_from_slot::<1>(this) };
    // Merge the framework's control resources once, at launch: a
    // code-only app has no App.xaml to do it, and while most control
    // templates happen to resolve without the merge, ProgressBar's
    // was the first to hit a missing theme key. The merge is TIERED
    // because it cannot always load: XamlControlsResources resolves
    // through ms-appx, which needs the exe-adjacent resources.pri —
    // present for the scene executables, structurally absent for
    // dll-hosted guests without the pri-adjacency runners. Where the
    // real merge fails, kaya logs and continues.
    let launched: windows_core::Result<()> = APP.with_borrow(|app| {
        let Some(app) = app.as_ref() else {
            return Ok(());
        };
        let merged: windows_core::Result<()> = (|| {
            let resources =
                bindings::Microsoft::UI::Xaml::Controls::XamlControlsResources::new()?;
            app.Resources()?.MergedDictionaries()?.Append(&resources)?;
            Ok(())
        })();
        if let Err(e) = merged {
            eprintln!(
                "kaya: winui XamlControlsResources unavailable ({})",
                e.message()
            );
        }
        Ok(())
    });
    launched.into()
}

unsafe extern "system" fn outer_get_xaml_type(
    this: *mut core::ffi::c_void,
    type_name: core::mem::MaybeUninit<bindings::Windows::UI::Xaml::Interop::TypeName>,
    out: *mut *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    use windows_core::Interface;
    unsafe {
        let outer = outer_from_slot::<2>(this);
        match (*outer).raw_provider() {
            Ok(provider) => {
                let vtbl = *(provider.as_raw()
                    as *mut *const bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl);
                ((*vtbl).GetXamlType)(provider.as_raw(), type_name, out)
            }
            Err(e) => e.into(),
        }
    }
}

unsafe extern "system" fn outer_get_xaml_type_by_full_name(
    this: *mut core::ffi::c_void,
    full_name: *mut core::ffi::c_void,
    out: *mut *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    use windows_core::Interface;
    unsafe {
        let outer = outer_from_slot::<2>(this);
        match (*outer).raw_provider() {
            Ok(provider) => {
                let vtbl = *(provider.as_raw()
                    as *mut *const bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl);
                ((*vtbl).GetXamlTypeByFullName)(provider.as_raw(), full_name, out)
            }
            Err(e) => e.into(),
        }
    }
}

unsafe extern "system" fn outer_get_xmlns_definitions(
    this: *mut core::ffi::c_void,
    count: *mut u32,
    values: *mut *mut core::mem::MaybeUninit<
        bindings::Microsoft::UI::Xaml::Markup::XmlnsDefinition,
    >,
) -> windows_core::HRESULT {
    use windows_core::Interface;
    unsafe {
        let outer = outer_from_slot::<2>(this);
        match (*outer).raw_provider() {
            Ok(provider) => {
                let vtbl = *(provider.as_raw()
                    as *mut *const bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl);
                ((*vtbl).GetXmlnsDefinitions)(provider.as_raw(), count, values)
            }
            Err(e) => e.into(),
        }
    }
}

/// Construct the Application composed with KayaOuter as the COM
/// aggregation outer: the returned instance is the framework object,
/// identity QIs route to the outer (which answers
/// IXamlMetadataProvider and forwards the rest to the inner — see
/// KayaOuter). The outer and the inner reference live for the process
/// lifetime, matching the Application itself.
fn compose_application() -> windows_core::Result<Application> {
    use windows_core::Interface;
    let outer: &'static KayaOuter = Box::leak(Box::new(KayaOuter {
        identity: &KAYA_OUTER_IDENTITY_VTBL,
        overrides: &KAYA_OUTER_OVERRIDES_VTBL,
        metadata: &KAYA_OUTER_METADATA_VTBL,
        inner: std::cell::Cell::new(core::ptr::null_mut()),
        provider: RefCell::new(None),
    }));
    let factory = windows_core::factory::<
        Application,
        bindings::Microsoft::UI::Xaml::IApplicationFactory,
    >()?;
    unsafe {
        let mut inner: *mut core::ffi::c_void = core::ptr::null_mut();
        let mut result: *mut core::ffi::c_void = core::ptr::null_mut();
        (Interface::vtable(&factory).CreateInstance)(
            Interface::as_raw(&factory),
            outer as *const KayaOuter as *mut core::ffi::c_void,
            &mut inner,
            &mut result,
        )
        .ok()?;
        // The non-delegating inner: the QI fallback target. Owned by
        // the composition for the process lifetime; never released.
        outer.inner.set(inner);
        windows_core::Type::from_abi(result)
    }
}

fn trace_enabled() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("KAYA_WINUI_TRACE").is_some())
}

/// Rebuild one grid's track definitions and restamp its children's
/// attached indices.
///
/// A Grid does not lay out by child order the way a StackPanel does: a
/// child sits wherever its attached Grid.Row/Grid.Column says, and two
/// children with the same index overlap silently rather than erroring.
/// So the logical order kaya maintains has to be written back after
/// every structural change — add, move, or destroy — and the whole set
/// is rebuilt rather than patched, because inserting in the middle
/// shifts every later child's index anyway.
///
/// The track sizes carry the layout contract directly: `Auto` for a
/// weight-0 child (natural size) and `Star(w)` for a grower. WinUI's
/// star sizing already means "divide what is left after the Auto tracks
/// in proportion to the star values", which is exactly [`Prop::Grow`],
/// so unlike AppKit and GTK there is no arithmetic to do here — only the
/// weights to hand over.
/// Re-attach a 2D grid's children row-major per its current column
/// count, with one Auto track per row/column — called when children
/// or the columns prop arrive, in either order.
fn reflow_grid(core: &CoreState, grid_id: u64) -> windows_core::Result<()> {
    let Some(NativeWidget::Grid2D(grid)) = core.widgets.get(&WidgetId(grid_id)) else {
        return Ok(());
    };
    let cols = core.grid_cols.get(&grid_id).copied().unwrap_or(1).max(1);
    let children = match core.grid_children.get(&grid_id) {
        Some(c) => c.clone(),
        None => return Ok(()),
    };
    let rows = (children.len() as i32 + cols - 1) / cols;
    let coldefs = grid.ColumnDefinitions()?;
    coldefs.Clear()?;
    for _ in 0..cols {
        let def = ColumnDefinition::new()?;
        def.SetWidth(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
        coldefs.Append(&def)?;
    }
    let rowdefs = grid.RowDefinitions()?;
    rowdefs.Clear()?;
    for _ in 0..rows {
        let def = RowDefinition::new()?;
        def.SetHeight(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
        rowdefs.Append(&def)?;
    }
    let slots = grid.Children()?;
    slots.Clear()?;
    for (i, child) in children.iter().enumerate() {
        let i = i as i32;
        Grid::SetColumn(&child.cast::<FrameworkElement>()?, i % cols)?;
        Grid::SetRow(&child.cast::<FrameworkElement>()?, i / cols)?;
        slots.Append(child)?;
    }
    Ok(())
}

fn reindex(core: &CoreState, parent: WidgetId) -> windows_core::Result<()> {
    let (grid, vertical) = match core.widgets.get(&parent) {
        Some(NativeWidget::Column(g)) => (g.clone(), true),
        Some(NativeWidget::Row(g)) => (g.clone(), false),
        // Destroyed, or never a container: nothing to place.
        _ => return Ok(()),
    };
    let empty = Vec::new();
    let order = core.child_order.get(&parent).unwrap_or(&empty);

    if vertical {
        let defs = grid.RowDefinitions()?;
        defs.Clear()?;
        for child in order {
            let def = RowDefinition::new()?;
            def.SetHeight(track(core.grow.get(child).copied().unwrap_or(0.0)))?;
            defs.Append(&def)?;
        }
    } else {
        let defs = grid.ColumnDefinitions()?;
        defs.Clear()?;
        for child in order {
            let def = ColumnDefinition::new()?;
            def.SetWidth(track(core.grow.get(child).copied().unwrap_or(0.0)))?;
            defs.Append(&def)?;
        }
    }

    let mode = core.aligns.get(&parent).copied().unwrap_or(0);
    for (index, child) in order.iter().enumerate() {
        let Some(widget) = core.widgets.get(child) else {
            continue;
        };
        // The attached setters take a FrameworkElement, one step down
        // from the UIElement the widget table hands out; every widget
        // kaya creates is one.
        let element: FrameworkElement = widget.element()?.cast()?;
        let index = index as i32;
        if vertical {
            Grid::SetRow(&element, index)?;
        } else {
            Grid::SetColumn(&element, index)?;
        }
        // Cross placement from the container's align mode. WinUI's
        // own default is Stretch; kaya's normalized default is start,
        // stamped explicitly so the two never drift. Baseline (rows
        // only) stamps Top here and gets its margin compensation
        // after the pass below — WinUI has no native baseline
        // alignment. One carve-out, the BREADTH rule: a nested
        // container whose main axis crosses its parent spans the
        // parent's breadth (a row in a column is as wide as the
        // column — the rule WinUI's Stretch default used to satisfy
        // for free, and the first stamped run broke: the grow row
        // hugged and split 31/69 of its own natural width).
        let crossing = matches!(
            (widget, vertical),
            (NativeWidget::Row(_), true) | (NativeWidget::Column(_), false)
        );
        if vertical {
            element.SetHorizontalAlignment(if crossing {
                bindings::Microsoft::UI::Xaml::HorizontalAlignment::Stretch
            } else {
                match mode {
                    1 => bindings::Microsoft::UI::Xaml::HorizontalAlignment::Center,
                    2 => bindings::Microsoft::UI::Xaml::HorizontalAlignment::Right,
                    3 => bindings::Microsoft::UI::Xaml::HorizontalAlignment::Stretch,
                    _ => bindings::Microsoft::UI::Xaml::HorizontalAlignment::Left,
                }
            })?;
        } else {
            element.SetVerticalAlignment(if crossing {
                bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch
            } else {
                match mode {
                    1 => bindings::Microsoft::UI::Xaml::VerticalAlignment::Center,
                    2 => bindings::Microsoft::UI::Xaml::VerticalAlignment::Bottom,
                    3 => bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch,
                    _ => bindings::Microsoft::UI::Xaml::VerticalAlignment::Top,
                }
            })?;
        }
    }
    if mode == 4 && !vertical {
        baseline_compensate(core, &grid, order)?;
    }
    Ok(())
}

/// WinUI's baseline row: no native primitive exists, so children with
/// a text baseline get a top margin lifting them to the deepest one.
/// BaselineOffset is only meaningful after a measure pass; UpdateLayout
/// forces it synchronously, the child_shares precedent.
fn baseline_compensate(
    core: &CoreState,
    grid: &Grid,
    order: &[WidgetId],
) -> windows_core::Result<()> {
    grid.UpdateLayout()?;
    let mut offsets: Vec<(FrameworkElement, f64)> = Vec::new();
    for child in order {
        let Some(widget) = core.widgets.get(child) else {
            continue;
        };
        let element: FrameworkElement = widget.element()?.cast()?;
        let baseline = match widget {
            NativeWidget::Label(text) => Some(text.BaselineOffset()?),
            NativeWidget::Button { caption, .. } | NativeWidget::Checkbox { caption, .. } => {
                // The caption sits inside the control; its baseline in
                // the CONTROL's space is its offset there plus its own
                // BaselineOffset.
                let at = caption
                    .TransformToVisual(&element)?
                    .TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
                Some(f64::from(at.Y) + caption.BaselineOffset()?)
            }
            // No text baseline: the bottom-edge rule — the child's
            // baseline IS its bottom (the CSS replaced-element rule),
            // so a tall image drags the common baseline down and the
            // text children lift to meet it. Text-only compensation
            // aligned label to checkbox at ~14dip and left the image
            // at the top — geometrically indistinguishable from
            // start, which is exactly how the first Windows run
            // failed.
            _ => Some(element.ActualHeight()?),
        };
        if let Some(b) = baseline {
            offsets.push((element, b));
        }
    }
    let Some(deepest) = offsets
        .iter()
        .map(|(_, b)| *b)
        .max_by(|a, b| a.partial_cmp(b).unwrap())
    else {
        return Ok(());
    };
    for (element, baseline) in offsets {
        element.SetMargin(Thickness {
            Left: 0.0,
            Top: deepest - baseline,
            Right: 0.0,
            Bottom: 0.0,
        })?;
    }
    Ok(())
}

/// One child's track: natural size, or a share of the leftover.
fn track(weight: f64) -> GridLength {
    if weight > 0.0 {
        GridLength {
            Value: weight,
            GridUnitType: GridUnitType::Star,
        }
    } else {
        // Auto and not `*`: a weight-0 child takes its natural size and
        // takes no part in the division, which is what makes the growers'
        // shares come out of the leftover rather than the whole.
        GridLength {
            Value: 0.0,
            GridUnitType: GridUnitType::Auto,
        }
    }
}

/// A user-driven back on the window's top entry: an
/// intercept_back-armed top emits back_requested and nothing pops
/// (the veto class); an unarmed top pops here, reconciles the
/// core-owned stack post-fact, and reports entry_popped.
fn user_back(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    // With sections present, back routes to the ACTIVE section's
    // stack — back never switches sections (DESIGN.md, Sections).
    let window = if core.sections.contains_key(&window) {
        core.selected_sections.get(&window).copied().unwrap_or(window)
    } else {
        window
    };
    let Some(&top) = core.nav_stacks.get(&window).and_then(|s| s.last()) else {
        return Ok(());
    };
    if core.nav_entries[&top].intercept_back {
        core.occurrences.send(Occurrence::BackRequested {
            entry: WindowId(top),
        });
        return Ok(());
    }
    core.nav_stacks.get_mut(&window).unwrap().pop();
    core.nav_entries.remove(&top);
    core.scene.user_popped(WindowId(top));
    refresh_nav(core, window)?;
    core.occurrences.send(Occurrence::EntryPopped {
        entry: WindowId(top),
    });
    Ok(())
}

/// Reconcile the window's visible state with its stack: the top
/// entry's wrapper and title (the entry title IS the window title
/// while covered), or the window's own root and title when the stack
/// empties.
fn refresh_nav(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    // A section host reconciles its PANE, not a window (stacks are
    // per-surface; DESIGN.md, Sections).
    if core.section_panes.contains_key(&window) {
        return refresh_section_pane(core, window);
    }
    let target = winui_window(core, window)?;
    let top = core.nav_stacks.get(&window).and_then(|s| s.last()).copied();

    // ADAPTIVE LIST-DETAIL (DESIGN.md). Both halves: the app asked
    // (wprop 6) and the window IS regular — the same 600 boundary the
    // other backends draw, read from XamlRoot's real size the way
    // menu_presentation already does.
    //
    // A two-column Grid rather than TwoPaneView: the semantic is
    // side-by-side panes, and WinUI's adaptive triggers ARE width
    // thresholds anyway. Same call GTK and Compose made — the
    // idiomatic wrapper is a ledger item, not a blocker.
    // Whichever arm is about to run, the previous split render must let
    // go of the roots first.
    release_split(core, window)?;
    let wants_split = core.list_detail.get(&window).copied().unwrap_or(false);
    //
    // SHORT-CIRCUITED on wants_split, and that matters: propagating the
    // read unconditionally made every nav scene fail, because a window
    // reconciling before its first mount legitimately has no content to
    // measure. The one remaining fallback is that case and says so —
    // no content is not a failed reading, it is nothing to lay out.
    let measured = window_client_width(core, window);
    if std::env::var("KAYA_SPLIT_TRACE").is_ok() {
        eprintln!(
            "KAYA_SPLIT_TRACE: window={window} wants_split={wants_split} \
             measured={measured:?} entries={}",
            core.nav_stacks.get(&window).map(|s| s.len()).unwrap_or(0)
        );
    }
    // NO width test here any more. TwoPaneView decides where one pane
    // becomes two, off its own MinWideModeWidth, and kaya no longer
    // draws that line: the app declares list-detail and the platform
    // says how it presents. The old `>= 600` was a number kaya invented
    // and then graded itself against.
    //
    // No `top.is_some()` either: an empty stack on a wide window shows
    // the leading pane and an EMPTY trailing one, the same as every
    // other backend. Semantics are never a backend's call.
    if wants_split {
        let base = core.window_roots.get(&window).cloned();
        let detail = top
            .and_then(|id| core.nav_entries.get(&id))
            .and_then(|e| e.wrapper.clone());
        if let Some(base) = base {
            let view = TwoPaneView::new()?;
            view.SetWideModeConfiguration(TwoPaneViewWideModeConfiguration::LeftRight)?;
            // Leading pane sized, trailing pane takes the rest — see
            // protocol::leading_pane_width. TwoPaneView's OWN default is
            // two equal panes, because it was built for dual-SCREEN
            // devices where each pane is a display; for list-detail on
            // one screen that is the down-the-middle split no platform
            // actually ships, so the proportion stays ours.
            let lead = crate::protocol::leading_pane_width(
                window_client_width(core, window).unwrap_or(0.0),
            );
            view.SetPane1Length(GridLength {
                Value: lead,
                GridUnitType: GridUnitType::Pixel,
            })?;
            view.SetPane2Length(GridLength {
                Value: 1.0,
                GridUnitType: GridUnitType::Star,
            })?;
            // Which pane survives the collapse: the detail once the
            // stack has one, else the list. This is TwoPaneView's
            // spelling of libadwaita's show-content, and it is the only
            // stack fact the control is told.
            view.SetPanePriority(if top.is_some() {
                TwoPaneViewPriority::Pane2
            } else {
                TwoPaneViewPriority::Pane1
            })?;
            let detail: UIElement = match &detail {
                Some(d) => windows_core::Interface::cast(d)?,
                None => windows_core::Interface::cast(&Grid::new()?)?,
            };
            // The window is still holding the base root at this point.
            detach_window_content(core, window)?;
            view.SetPane1(&base)?;
            view.SetPane2(&detail)?;
            core.split_views.insert(window, view.clone());
            let el: UIElement = windows_core::Interface::cast(&view)?;
            set_window_content(core, window, &el)?;
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
            target.SetTitle(&HSTRING::from(&*title))?;
            // The back bar follows the CONTROL's mode, now and every
            // time Windows changes it. Mode is decided during layout, so
            // reading it here alone would read the value from before
            // this pane arrangement existed — the measuring-what-you-are-
            // about-to-replace trap that cost this backend a day.
            apply_split_back_bar(core, window)?;
            let handler = TypedEventHandler::new(move |_, _| {
                CORE.with_borrow_mut(|core| {
                    let Some(core) = core.as_mut() else { return Ok(()) };
                    apply_split_back_bar(core, window)
                })
            });
            view.ModeChanged(&handler)?;
            return Ok(());
        }
    }
    // The serial arm stamps too.
    core.split_presentation.insert(window, "stacked");

    match top.and_then(|id| core.nav_entries.get(&id)) {
        Some(entry) => {
            // Collapsed: the entry COVERS the leading pane, so back
            // means something again and its bar comes back. The split
            // arm above hid it; this is the other half, and both arms
            // must write it or the state is derived-by-default in one.
            if let Some(back) = &entry.back_button {
                let back: UIElement = back.cast()?;
                back.SetVisibility(Visibility::Visible)?;
            }
            if let Some(wrapper) = &entry.wrapper {
                let wrapper: UIElement = windows_core::Interface::cast(wrapper)?;
                set_window_content(core, window, &wrapper)?;
            }
            target.SetTitle(&HSTRING::from(&*entry.title))?;
        }
        None => {
            if let Some(root) = core.window_roots.get(&window) {
                let root = root.clone();
                set_window_content(core, window, &root)?;
            }
            let own = core.window_titles.get(&window).cloned().unwrap_or_default();
            target.SetTitle(&HSTRING::from(&*own))?;
        }
    }
    Ok(())
}

/// Fill a navigation entry at mount: the wrapper Grid is the
/// backend's chrome — an auto-height back bar (the back affordance;
/// its click runs the SAME user-pop path a pointer press does) over
/// a star-height row holding the entry's root.
fn mount_entry(
    core: &mut CoreState,
    entry_id: u64,
    element: UIElement,
) -> windows_core::Result<()> {
    let wrapper = Grid::new()?;
    let defs = wrapper.RowDefinitions()?;
    let bar = RowDefinition::new()?;
    bar.SetHeight(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Auto,
    })?;
    defs.Append(&bar)?;
    let fill = RowDefinition::new()?;
    fill.SetHeight(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Star,
    })?;
    defs.Append(&fill)?;
    let back = Button::new()?;
    let caption = TextBlock::new()?;
    caption.SetText(&HSTRING::from("\u{2190}"))?;
    back.SetContent(&caption)?;
    let host = core.nav_entries[&entry_id].window;
    let handler = RoutedEventHandler::new(move |_, _| {
        // Fires from the message loop, never under an apply borrow.
        CORE.with_borrow_mut(|core| {
            let Some(core) = core.as_mut() else { return Ok(()) };
            user_back(core, host)
        })
    });
    back.Click(&handler)?;
    let back_el: FrameworkElement = back.cast()?;
    Grid::SetRow(&back_el, 0)?;
    wrapper.Children()?.Append(&back_el)?;
    let content_el: FrameworkElement = element.cast()?;
    Grid::SetRow(&content_el, 1)?;
    wrapper.Children()?.Append(&element)?;
    let entry = core.nav_entries.get_mut(&entry_id).unwrap();
    entry.wrapper = Some(wrapper);
    entry.back_button = Some(back);
    if core.nav_stacks.get(&host).and_then(|s| s.last()) == Some(&entry_id) {
        refresh_nav(core, host)?;
    }
    Ok(())
}

/// Assemble the window's sections chrome: a NavigationView — the
/// platform's own idiom, viable now that the aggregation outer
/// delegates QI (docs/traps.md) — whose items are the sections
/// (string content, the ComboBox content-stealing trap) and whose
/// Content is the active pane. Built ONCE and grown incrementally
/// (XAML refuses re-parenting); a hint change is just
/// SetPaneDisplayMode — Left for auto/`sidebar` (the ratified
/// Windows default), Top for `bar`. SelectionChanged is the USER
/// route, guarded by the swallow COUNTER (it raises async; the
/// entry_swallow pattern): unguarded raises reconcile the core and
/// emit.
fn refresh_sections(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    let ids = core.sections.get(&window).cloned().unwrap_or_default();
    if ids.is_empty() {
        return Ok(());
    }
    if !core.section_navs.contains_key(&window) {
        let nav = NavigationView::new()?;
        nav.SetIsSettingsVisible(false)?;
        nav.SetIsBackButtonVisible(
            bindings::Microsoft::UI::Xaml::Controls::NavigationViewBackButtonVisible::Collapsed,
        )?;
        let swallow =
            std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        core.section_swallow.insert(window, swallow.clone());
        let handler = bindings::Windows::Foundation::TypedEventHandler::new(
            move |nav: windows_core::Ref<NavigationView>, _| {
                use windows_core::Interface;
                // A programmatic move's late raise: swallow it — the
                // model and emit were handled synchronously at the
                // set (the entry_swallow pattern).
                if swallow
                    .fetch_update(
                        std::sync::atomic::Ordering::Relaxed,
                        std::sync::atomic::Ordering::Relaxed,
                        |n| n.checked_sub(1),
                    )
                    .is_ok()
                {
                    return Ok(());
                }
                let Some(nav) = nav.as_ref() else { return Ok(()) };
                let Ok(selected) = nav.SelectedItem() else { return Ok(()) };
                let Ok(item) = selected.cast::<NavigationViewItem>() else {
                    return Ok(());
                };
                let Ok(tag) = item.Tag() else { return Ok(()) };
                let Ok(sid_ref) = tag.cast::<IReference<u64>>() else {
                    return Ok(());
                };
                let sid = sid_ref.Value()?;
                // Fires from the message loop, never under an apply
                // borrow (the back-button precedent).
                let mut emit = false;
                CORE.with_borrow_mut(|core| {
                    let Some(core) = core.as_mut() else { return };
                    if core.selected_sections.get(&window) == Some(&sid) {
                        return;
                    }
                    core.selected_sections.insert(window, sid);
                    core.ui_selected_sections.insert(window, sid);
                    core.scene
                        .user_selected_section(WindowId(window), WindowId(sid));
                    let _ = show_section_pane(core, window, sid);
                    emit = true;
                });
                if emit {
                    CORE.with_borrow(|core| {
                        if let Some(core) = core.as_ref() {
                            core.occurrences.send(Occurrence::SectionSelected {
                                window: WindowId(window),
                                section: WindowId(sid),
                            });
                        }
                    });
                }
                Ok(())
            },
        );
        nav.SelectionChanged(&handler)?;
        core.section_navs.insert(window, nav.clone());
        let nav_el: UIElement = windows_core::Interface::cast(&nav)?;
        set_window_content(core, window, &nav_el)?;
    }
    let nav = core.section_navs[&window].clone();
    // Grow incrementally: an item per section not yet appended (add
    // order; the set is append-only by grammar).
    for sid in &ids {
        if core.section_items.contains_key(sid) {
            continue;
        }
        let item = NavigationViewItem::new()?;
        let title = &core.section_panes[sid].title;
        // String content, never a UIElement child — the ComboBox
        // content-stealing trap (docs/traps.md).
        item.SetContent(&PropertyValue::CreateString(&HSTRING::from(&**title))?)?;
        item.SetTag(&PropertyValue::CreateUInt64(*sid)?)?;
        nav.MenuItems()?.Append(&item)?;
        core.section_items.insert(*sid, item);
    }
    let hint = core
        .sections_presentation
        .get(&window)
        .copied()
        .unwrap_or(0);
    nav.SetPaneDisplayMode(if hint == 1 {
        NavigationViewPaneDisplayMode::Top
    } else {
        NavigationViewPaneDisplayMode::Left
    })?;
    if let Some(sel) = core.selected_sections.get(&window).copied() {
        nav_set_selected(core, window, sel)?;
        show_section_pane(core, window, sel)?;
    }
    Ok(())
}

/// Move the switcher's selection programmatically: swallow the async
/// SelectionChanged raise (counter, not flag) and skip no-op moves,
/// which raise nothing and would leave the counter armed against a
/// future real switch.
fn nav_set_selected(
    core: &mut CoreState,
    window: u64,
    sid: u64,
) -> windows_core::Result<()> {
    if core.ui_selected_sections.get(&window) == Some(&sid) {
        return Ok(());
    }
    let (Some(nav), Some(item)) = (
        core.section_navs.get(&window).cloned(),
        core.section_items.get(&sid).cloned(),
    ) else {
        return Ok(());
    };
    if let Some(swallow) = core.section_swallow.get(&window) {
        swallow.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }
    core.ui_selected_sections.insert(window, sid);
    nav.SetSelectedItem(&item)?;
    Ok(())
}

/// Put the section's pane into the NavigationView's content slot.
fn show_section_pane(
    core: &CoreState,
    window: u64,
    section: u64,
) -> windows_core::Result<()> {
    let (Some(nav), Some(record)) = (
        core.section_navs.get(&window),
        core.section_panes.get(&section),
    ) else {
        return Ok(());
    };
    nav.SetContent(&record.pane)?;
    Ok(())
}

/// Reconcile a section pane's visible child: its stack's top entry
/// wrapper while covered (stacks are per-surface), its own mounted
/// root otherwise.
fn refresh_section_pane(core: &mut CoreState, sid: u64) -> windows_core::Result<()> {
    let Some(record) = core.section_panes.get(&sid) else {
        return Ok(());
    };
    let top = core.nav_stacks.get(&sid).and_then(|s| s.last()).copied();
    let desired: Option<UIElement> = top
        .and_then(|id| core.nav_entries.get(&id))
        .and_then(|e| e.wrapper.clone())
        .map(|w| w.cast().expect("a Grid is a UIElement"))
        .or_else(|| record.root.clone());
    let children = record.pane.Children()?;
    children.Clear()?;
    if let Some(widget) = desired {
        children.Append(&widget)?;
    }
    Ok(())
}

/// WinUI's TextBox stores every line break as a bare CR (its Rich Edit
/// heritage): text SET with LF reads back with CR. The wire and every
/// other backend speak LF, and guest-visible strings are compared
/// byte-for-byte across languages, so CR is normalized to LF at every
/// point where TextBox text escapes toward the guest (occurrence
/// payloads, harness reads) or is compared against guest text (the
/// quiet-set and set_text guards — an unnormalized compare never
/// matches multi-line text and re-sets on every write).
fn lf(s: String) -> String {
    if s.contains('\r') {
        s.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        s
    }
}

/// KAYA_WINUI_NAV_PROBE: wrap the primary mount in a NavigationView
/// ("bare" = no items; anything else adds two string items). The
/// stowed-E_NOINTERFACE bisection instrument (docs/traps.md): it
/// answers whether the control is viable in THIS hosting shape at
/// all, independent of kaya's sections machinery.
fn nav_probe_wrap(element: &UIElement) -> windows_core::Result<UIElement> {
    use bindings::Microsoft::UI::Xaml::Controls::{NavigationView, NavigationViewItem};
    let level = std::env::var("KAYA_WINUI_NAV_PROBE").unwrap_or_default();
    if level.is_empty() {
        return Ok(element.clone());
    }
    eprintln!("kaya: NAV PROBE armed ({level})");
    // The aggregation hypothesis: NavigationView's ResourceAccessor
    // consults Application.Current at runtime; with the outer
    // discarding the inner, identity QIs for IApplication die
    // E_NOINTERFACE. Reproduce the exact lookup it would make.
    match bindings::Microsoft::UI::Xaml::Application::Current() {
        Ok(app) => match app.Resources() {
            Ok(_) => eprintln!("kaya: PROBE Current().Resources() OK"),
            Err(e) => eprintln!(
                "kaya: PROBE Current().Resources() FAILED: {:?} {}",
                e.code(),
                e.message()
            ),
        },
        Err(e) => eprintln!(
            "kaya: PROBE Application::Current() FAILED: {:?} {}",
            e.code(),
            e.message()
        ),
    }
    let nav = NavigationView::new()?;
    nav.SetIsSettingsVisible(false)?;
    if level != "bare" {
        for title in ["Feed", "Archive"] {
            let item = NavigationViewItem::new()?;
            item.SetContent(&PropertyValue::CreateString(&HSTRING::from(title))?)?;
            nav.MenuItems()?.Append(&item)?;
        }
    }
    nav.SetContent(element)?;
    nav.cast()
}

// --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------
//
// One item vocabulary, two anchors. The WINDOW anchor is a real
// in-window MenuBar in its own Auto row of the window shell Grid; the
// WIDGET/NODE anchor is a MenuFlyout set as the element's
// ContextFlyout. Echo doctrine: ONE dispatch path — chrome clicks,
// the KeyboardAccelerator route, and harness verbs all land in
// menu_user_activate and emit; programmatic set_menu_prop writes
// mutate the model silently in the apply arm and the rebuild restamps
// the chrome from that mirror.

/// Enablement is the AND of the item's own flag and every grouping
/// ancestor's — the inherited rule every read, render, shortcut, and
/// activation route shares (docs/traps.md).
fn menu_effective_enabled(core: &CoreState, item: u64) -> bool {
    let mut enabled = match core.menu_models.get(&item) {
        Some(m) => m.enabled,
        None => return false,
    };
    let mut current = item;
    while let Some(parent) = core.menu_models.get(&current).and_then(|m| m.parent) {
        enabled = enabled && core.menu_models.get(&parent).is_some_and(|m| m.enabled);
        current = parent;
    }
    enabled
}

/// Catalog preorder: top-level grouping nodes in menubar-append order,
/// then each node's children in append order, depth-first (the
/// promotion/shortcut-table order; creation time is irrelevant).
fn menu_preorder(core: &CoreState, roots: &[u64], out: &mut Vec<u64>) {
    for &id in roots {
        out.push(id);
        if let Some(children) = core.menu_models.get(&id).map(|m| m.children.clone()) {
            menu_preorder(core, &children, out);
        }
    }
}

/// Resolve a `>`-joined label path against root items, labels compared
/// byte-for-byte (the shared-scene contract). The path walks the
/// SEMANTIC tree: a grouping root's label is a path segment whether or
/// not materialization mints a titled row — an inline nested
/// radio_group has none, yet "View>Sort>Date" must still land on Date.
fn resolve_menu_path(core: &CoreState, path: &str, roots: &[u64]) -> Option<u64> {
    let mut current: Vec<u64> = roots.to_vec();
    let mut found = None;
    for seg in path.split('>') {
        let item = *current
            .iter()
            .find(|id| core.menu_models.get(id).is_some_and(|m| m.label == seg))?;
        found = Some(item);
        current = core.menu_models[&item].children.clone();
    }
    found
}

/// Build the window shell at the first menubar_append (the ratified
/// lowering): a Grid whose Auto row holds the MenuBar and whose Star
/// row is the content slot every later mount/nav/sections swap fills.
/// Built ONCE and grown through rebuilds; any content the window
/// already presents moves into the slot (detached by the SetContent
/// swap first — XAML refuses re-parenting; docs/traps.md).
fn ensure_menu_shell(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    use windows_core::Interface as _;
    if core.menubars.contains_key(&window) {
        return Ok(());
    }
    let target = winui_window(core, window)?;
    let shell = Grid::new()?;
    let defs = shell.RowDefinitions()?;
    let bar_row = RowDefinition::new()?;
    bar_row.SetHeight(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Auto,
    })?;
    defs.Append(&bar_row)?;
    let fill = RowDefinition::new()?;
    fill.SetHeight(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Star,
    })?;
    defs.Append(&fill)?;
    let bar = MenuBar::new()?;
    let bar_el: FrameworkElement = bar.cast()?;
    Grid::SetRow(&bar_el, 0)?;
    shell.Children()?.Append(&bar_el)?;
    let slot = Grid::new()?;
    let slot_el: FrameworkElement = slot.cast()?;
    Grid::SetRow(&slot_el, 1)?;
    shell.Children()?.Append(&slot_el)?;
    let old = target.Content().ok();
    target.SetContent(&shell.cast::<UIElement>()?)?;
    if let Some(old) = old {
        slot.Children()?.Append(&old)?;
    }
    core.menubars.insert(window, bar);
    core.menu_slots.insert(window, slot);
    Ok(())
}

/// Every content swap for a window goes through here: into the menu
/// shell's slot when the window carries a bar, straight onto the
/// Window otherwise. Keeps the mount/nav/sections paths one mechanism.
/// The window's client width in DIP, read from the WINDOW rather than
/// from whatever element currently occupies it.
///
/// This started out reading `Content().XamlRoot().Size()`, which is
/// what menu_presentation does — and that is safe there because the
/// menu arm never REPLACES the content. The list-detail arm does
/// exactly that, so measuring the content to decide what the content
/// should be is circular: the trace showed `measured` alternating
/// between Some(900.0) and None as the tree was swapped underneath the
/// reading.
///
/// The mechanism is DOCUMENTED, not a quirk: a UIElement's XamlRoot is
/// null until it is parented into a live tree, and returns its
/// parent's once it is. So an element mid-reparent legitimately has no
/// XamlRoot, and anything measuring through it reads null exactly when
/// the arm needs an answer. GetClientRect answers about the WINDOW —
/// what a size class is a property of — and is available before XAML
/// has laid anything out.
/// What to do with the live file dialog: read it back, or drive it.
#[cfg(feature = "harness")]
/// Is the Shell's file dialog on screen? Plain Win32, no COM.
///
/// THE GONE-CHECK MUST NOT WALK THE DIALOG. `choose_file` presses Open
/// and then asks whether the dialog left, and asking that through UI
/// Automation means enumerating a tree that is being torn down at that
/// exact moment: uiautomationcore raises RPC_E_DISCONNECTED, COM
/// surfaces it as a STRUCTURED EXCEPTION rather than a failed HRESULT,
/// and the JVM's process-wide handler turns that into a FATAL error
/// report. The java leg died there while the other four merely raced
/// unseen — the same event, escalated by one runtime and swallowed by
/// the rest.
///
/// Existence is a window question, so it is asked of the window
/// manager. EnumWindows cannot fault on a dead provider because it
/// never speaks to one.
#[cfg(feature = "harness")]
fn file_dialog_is_up() -> bool {
    unsafe extern "system" fn visit(hwnd: isize, found: isize) -> i32 {
        let mut class = [0u16; 64];
        let n = unsafe { GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32) };
        if n > 0 && unsafe { IsWindowVisible(hwnd) } != 0 {
            let name = String::from_utf16_lossy(&class[..n as usize]);
            if name == "#32770" {
                unsafe { *(found as *mut bool) = true };
                return 0; // stop: one is enough
            }
        }
        1
    }

    let mut found = false;
    unsafe { EnumWindows(Some(visit), &mut found as *mut bool as isize) };
    found
}

/// The live dialog's window, or nothing. Plain Win32: no COM, no
/// automation, no messages sent.
#[cfg(feature = "harness")]
fn live_dialog() -> Option<isize> {
    unsafe extern "system" fn visit(hwnd: isize, found: isize) -> i32 {
        let mut class = [0u16; 64];
        let n = unsafe { GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32) };
        if n > 0 && unsafe { IsWindowVisible(hwnd) } != 0 {
            let name = String::from_utf16_lossy(&class[..n as usize]);
            if name == "#32770" {
                unsafe { *(found as *mut isize) = hwnd };
                return 0;
            }
        }
        1
    }
    let mut found: isize = 0;
    unsafe { EnumWindows(Some(visit), &mut found as *mut isize as isize) };
    (found != 0).then_some(found)
}

/// What the live dialog is SHOWING, sampled through the shell's own
/// interfaces rather than through UI Automation.
///
/// UIA IS THE THING THAT MUST NOT HAPPEN, and moving the client out of
/// process could never have fixed it, because the fault is on the
/// PROVIDER side — inside this process. Measured stack, bottom up:
/// USER32 dispatches a message, DirectUI (DUI70) handles it, and while
/// handling it uiautomationcore raises an automation event to whatever
/// client has attached, which needs an outgoing COM call. Windows
/// refuses one from a thread dispatching an input-synchronous call and
/// raises RPC_E_CANTCALLOUT_ININPUTSYNCCALL (0x8001010d) — flagged
/// NONCONTINUABLE, so no handler may dismiss it. COM catches it and
/// carries on; four runtimes never notice; HotSpot's vectored exception
/// handler on windows-aarch64 sees the same first-chance event and
/// reports a fatal error. So MERELY ATTACHING A UIA CLIENT makes this
/// dialog fatal to a JVM, and nothing on the client side can help —
/// which is why a helper process was built, measured, and thrown away.
///
/// The dialog is ours, created in this process, so the shell will
/// simply say what its view holds: IServiceProvider ->
/// SID_STopLevelBrowser -> IShellBrowser -> the active IShellView ->
/// IFolderView -> its items. No automation client, no WM_GETOBJECT, no
/// event notifications, no exception.
///
/// SAMPLED ON THE DIALOG'S OWN THREAD, because the dialog is an STA
/// object and belongs to the thread that created it. The harness thread
/// posts a request to a message-only window living on that thread and
/// reads the answer out of a mutex; nothing crosses an apartment.
#[cfg(feature = "harness")]
mod sampler {
    use std::sync::Mutex;

    /// The message-only window on the dialog's thread, 0 when no dialog
    /// is up.
    pub(crate) static WINDOW: std::sync::atomic::AtomicIsize =
        std::sync::atomic::AtomicIsize::new(0);
    /// The last sample. Cleared when a dialog opens, so a stale answer
    /// can never satisfy an assertion about a new one.
    pub(crate) static VIEW: Mutex<Option<(String, Vec<String>)>> = Mutex::new(None);
    /// WM_APP: "sample now". pub(crate) and not pub: cbindgen scrapes
    /// public constants into the C header regardless of the privacy of
    /// the module holding them, and this is an internal detail of one
    /// backend rather than part of the ABI.
    pub(crate) const SAMPLE: u32 = 0x8000;
}

#[cfg(feature = "harness")]
fn sample_folder_view(dialog: &windows::Win32::UI::Shell::IFileOpenDialog) {
    use windows::Win32::System::Com::IServiceProvider;
    use windows::Win32::UI::Shell::{
        IFolderView, IShellBrowser, IShellItemArray, SVGIO_ALLVIEW, SIGDN_FILESYSPATH,
        SIGDN_PARENTRELATIVEFORUI,
    };
    // {4C96BE40-915C-11CF-99D3-00AA004AE837}, the top-level browser the
    // dialog hosts its view in. Not exported by the metadata, so it is
    // spelled out.
    const SID_S_TOP_LEVEL_BROWSER: windows_core::GUID =
        windows_core::GUID::from_u128(0x4C96BE40_915C_11CF_99D3_00AA004AE837);
    // SVGIO_ALLVIEW is everything the view is displaying, which is the
    // question the scene asks — not the selection, not the background.

    let sampled = (|| -> windows_core::Result<(String, Vec<String>)> {
        let directory = unsafe { dialog.GetFolder()?.GetDisplayName(SIGDN_FILESYSPATH)? };
        let directory = unsafe { directory.to_string()? };

        let provider: IServiceProvider = dialog.cast()?;
        let browser: IShellBrowser =
            unsafe { provider.QueryService(&SID_S_TOP_LEVEL_BROWSER)? };
        let view = unsafe { browser.QueryActiveShellView()? };
        let folder: IFolderView = view.cast()?;
        let items: IShellItemArray = unsafe { folder.Items(SVGIO_ALLVIEW)? };

        let mut rows = Vec::new();
        for i in 0..unsafe { items.GetCount()? } {
            let item = unsafe { items.GetItemAt(i)? };
            // PARENTRELATIVEFORUI is WHAT THE USER SEES, which is what
            // every other backend reports and what the shared scene
            // compares byte for byte. It honours Explorer's HideFileExt,
            // so the deploy still has to set that to 0 — the same guard
            // as before, for the same reason.
            let name = unsafe { item.GetDisplayName(SIGDN_PARENTRELATIVEFORUI)? };
            rows.push(unsafe { name.to_string()? });
        }
        Ok((directory, rows))
    })();

    if let Ok(state) = sampled {
        if let Ok(mut slot) = sampler::VIEW.lock() {
            *slot = Some(state);
        }
    }
}

/// A control of the dialog by its classic id and class. The ids were
/// confirmed against the real dialog by tools/win/dialogprobe rather
/// than taken from documentation: 1 is Open, 2 is Cancel, and 1148 is
/// the file-name box, which is an Edit inside a ComboBoxEx32 that
/// shares its id.
#[cfg(feature = "harness")]
fn dialog_control(dialog: isize, id: i32, class: &str) -> Option<isize> {
    struct Hunt<'a> {
        id: i32,
        class: &'a str,
        found: isize,
    }
    unsafe extern "system" fn visit(hwnd: isize, param: isize) -> i32 {
        let hunt = unsafe { &mut *(param as *mut Hunt) };
        let mut buf = [0u16; 64];
        let n = unsafe { GetClassNameW(hwnd, buf.as_mut_ptr(), buf.len() as i32) };
        let class = String::from_utf16_lossy(&buf[..n.max(0) as usize]);
        if unsafe { GetDlgCtrlID(hwnd) } == hunt.id && class == hunt.class {
            hunt.found = hwnd;
            return 0;
        }
        unsafe { EnumChildWindows(hwnd, Some(visit), param) };
        1
    }
    let mut hunt = Hunt { id, class, found: 0 };
    unsafe { EnumChildWindows(dialog, Some(visit), &mut hunt as *mut Hunt as isize) };
    (hunt.found != 0).then_some(hunt.found)
}

#[cfg(feature = "harness")]
const ID_OK: i32 = 1;
#[cfg(feature = "harness")]
const ID_CANCEL: i32 = 2;
#[cfg(feature = "harness")]
const ID_FILENAME: i32 = 1148;
#[cfg(feature = "harness")]
const WM_CHAR: u32 = 0x0102;
#[cfg(feature = "harness")]
const EM_SETSEL: u32 = 0x00B1;
#[cfg(feature = "harness")]
const BM_CLICK: u32 = 0x00F5;

/// The WNDCLASSW the sampler window registers. Hand-declared beside
/// the user32 calls this file already names, rather than by enabling
/// Win32_UI_WindowsAndMessaging for one struct.
#[cfg(feature = "harness")]
#[repr(C)]
struct WndClassW {
    style: u32,
    proc_: Option<unsafe extern "system" fn(isize, u32, usize, isize) -> isize>,
    cls_extra: i32,
    wnd_extra: i32,
    instance: isize,
    icon: isize,
    cursor: isize,
    background: isize,
    menu_name: *const u16,
    class_name: *const u16,
}

/// The message-only window the harness posts its sample request to.
///
/// It lives on the DIALOG'S thread, because that is the only thread
/// allowed to touch an STA object, and it is a window rather than a
/// channel because that thread is inside a modal Show() loop — a loop
/// that pumps the thread's queue and so dispatches to this window
/// without knowing anything about it. Nothing here crosses an
/// apartment, which is the entire point.
#[cfg(feature = "harness")]
unsafe extern "system" fn sampler_proc(
    hwnd: isize,
    msg: u32,
    wparam: usize,
    lparam: isize,
) -> isize {
    if msg == sampler::SAMPLE {
        SAMPLED_DIALOG.with(|held| {
            if let Some(dialog) = held.borrow().as_ref() {
                sample_folder_view(dialog);
            }
        });
        return 0;
    }
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

#[cfg(feature = "harness")]
thread_local! {
    /// The live dialog, reachable from the window proc above. A
    /// thread-local and not a global: an STA interface pointer is only
    /// valid on the thread that created it, and this is that thread.
    static SAMPLED_DIALOG: std::cell::RefCell<Option<windows::Win32::UI::Shell::IFileOpenDialog>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(feature = "harness")]
fn utf16(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Stand the sampler up for the life of one dialog.
#[cfg(feature = "harness")]
fn open_sampler(dialog: &windows::Win32::UI::Shell::IFileOpenDialog) {
    let class = utf16("KayaFileDialogSampler");
    let instance = unsafe { GetModuleHandleW(core::ptr::null()) };
    let mut wc: WndClassW = unsafe { core::mem::zeroed() };
    wc.proc_ = Some(sampler_proc);
    wc.instance = instance;
    wc.class_name = class.as_ptr();
    // Registering the same class twice simply fails; the class outlives
    // any one dialog and that is fine.
    unsafe { RegisterClassW(&wc) };
    // HWND_MESSAGE is -3: no screen presence, no z-order, nothing but a
    // queue endpoint.
    let hwnd = unsafe {
        CreateWindowExW(
            0,
            class.as_ptr(),
            core::ptr::null(),
            0,
            0,
            0,
            0,
            0,
            -3,
            0,
            instance,
            core::ptr::null_mut(),
        )
    };
    SAMPLED_DIALOG.with(|held| *held.borrow_mut() = Some(dialog.clone()));
    // A NEW DIALOG STARTS WITH NO ANSWER, so a sample of the previous
    // one can never satisfy an assertion about this one.
    if let Ok(mut slot) = sampler::VIEW.lock() {
        *slot = None;
    }
    sampler::WINDOW.store(hwnd, std::sync::atomic::Ordering::SeqCst);
}

/// Take it down when the dialog goes. A published handle to a window
/// nobody pumps would leave the harness posting into nothing.
#[cfg(feature = "harness")]
fn close_sampler() {
    let hwnd = sampler::WINDOW.swap(0, std::sync::atomic::Ordering::SeqCst);
    if hwnd != 0 {
        unsafe { DestroyWindow(hwnd) };
    }
    SAMPLED_DIALOG.with(|held| *held.borrow_mut() = None);
}

/// Show the Shell's common item dialog and return (name, path) per
/// file. Runs on its own STA thread; see the apply arm.
///
/// The empty vector IS cancel: Show() answers ERROR_CANCELLED, which is
/// not an error condition to report but the platform's way of saying the
/// selection was empty.
fn file_dialog_show(
    hwnd: isize,
    multiple: bool,
    filters: &[(String, String)],
    folder: Option<&str>,
) -> Vec<(String, String)> {
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
        COINIT_APARTMENTTHREADED,
    };
    use windows::Win32::UI::Shell::Common::COMDLG_FILTERSPEC;
    use windows::Win32::UI::Shell::{
        FileOpenDialog, IFileOpenDialog, IShellItem, SHCreateItemFromParsingName,
        SIGDN_FILESYSPATH, FOS_ALLOWMULTISELECT, FOS_FORCEFILESYSTEM,
    };

    let mut out = Vec::new();
    unsafe {
        // STA, because the shell dialog demands it. The result is not
        // checked for S_FALSE: already-initialized is fine, and the
        // matching uninit still runs.
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        // WHICH CALL FAILED, not merely that one did: a bare
        // "The parameter is incorrect" from a chain of six COM calls
        // names nothing, and the first run cost a deploy cycle to learn
        // that much.
        let mut stage = "CoCreateInstance";
        let result = (|| -> windows_core::Result<()> {
            let dialog: IFileOpenDialog =
                CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;

            stage = "GetOptions";
            let mut options = dialog.GetOptions()?;
            // FORCEFILESYSTEM keeps the answer to things that HAVE a
            // path: the design hands back a capability the guest opens
            // with its own file API, and a virtual shell item has
            // nothing to open.
            options |= FOS_FORCEFILESYSTEM;
            if multiple {
                options |= FOS_ALLOWMULTISELECT;
            }
            stage = "SetOptions";
            dialog.SetOptions(options)?;

            // ADVISORY on every platform (DESIGN.md): a default view,
            // never a guarantee. The HSTRINGs must outlive SetFileTypes,
            // which borrows their pointers.
            let specs: Vec<(HSTRING, HSTRING)> = filters
                .iter()
                .map(|(label, suffix)| {
                    (HSTRING::from(label.as_str()), HSTRING::from(format!("*.{suffix}")))
                })
                .collect();
            if !specs.is_empty() {
                let raw: Vec<COMDLG_FILTERSPEC> = specs
                    .iter()
                    .map(|(label, pattern)| COMDLG_FILTERSPEC {
                        pszName: windows_core::PCWSTR(label.as_ptr()),
                        pszSpec: windows_core::PCWSTR(pattern.as_ptr()),
                    })
                    .collect();
                stage = "SetFileTypes";
            dialog.SetFileTypes(&raw)?;
            }

            // The armed directory, applied HERE because that is the only
            // moment it is read.
            if let Some(dir) = folder {
                let wide = HSTRING::from(dir);
                stage = "SHCreateItemFromParsingName";
                let item: IShellItem =
                    SHCreateItemFromParsingName(windows_core::PCWSTR(wide.as_ptr()), None)?;
                stage = "SetFolder";
            dialog.SetFolder(&item)?;
            }

            // The sampler lives exactly as long as the modal loop:
            // stood up immediately before Show, taken down the instant
            // it returns (below, outside this closure, because cancel
            // leaves through the `?`).
            #[cfg(feature = "harness")]
            open_sampler(&dialog);

            stage = "Show";
            // NO OWNER, and that is not laziness. Show() disables its
            // owner and waits on the owner's input queue, and this runs
            // on a thread that is not the UI thread — so passing the
            // app window blocks inside Show() before the dialog is ever
            // created. Measured: the thread entered Show and never
            // returned, and UI Automation reported no #32770 anywhere on
            // the desktop.
            //
            // Modality is not lost by this. kaya already allows exactly
            // one live file dialog per process (capi::file_dialog_shown
            // panics on a second), which is the guarantee the vocabulary
            // actually makes.
            let _ = hwnd;
            dialog.Show(None)?;

            stage = "GetResults";
            let items = dialog.GetResults()?;
            for i in 0..items.GetCount()? {
                let item = items.GetItemAt(i)?;
                let path = item.GetDisplayName(SIGDN_FILESYSPATH)?;
                let path = path.to_string()?;
                let name = std::path::Path::new(&path)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                out.push((name, path));
            }
            Ok(())
        })();
        // OUTSIDE THE CLOSURE, because Show() answers cancel with an
        // Err that leaves it early — a teardown inside would run on the
        // happy path only, and the harness would go on posting into a
        // queue nobody pumps.
        #[cfg(feature = "harness")]
        close_sampler();
        // A cancelled dialog returns ERROR_CANCELLED from Show(); the
        // empty vector already says that, so nothing is logged for it.
        if let Err(err) = result {
            const CANCELLED: windows_core::HRESULT = windows_core::HRESULT(0x8007_04C7u32 as i32);
            if err.code() != CANCELLED {
                eprintln!(
                    "kaya: file dialog failed at {stage} (hwnd={hwnd:#x}, \
                     folder={folder:?}, filters={filters:?}): {err}"
                );
            }
        }
        CoUninitialize();
    }
    out
}

fn window_client_width(core: &CoreState, window: u64) -> Option<f64> {
    let target = winui_window(core, window).ok()?;
    let native: IWindowNative = windows_core::Interface::cast(&target).ok()?;
    let hwnd = native.window_handle().ok()?;
    let mut client = Rect::default();
    let scale;
    unsafe {
        if GetClientRect(hwnd, &mut client) == 0 {
            return None;
        }
        // DIP, not physical pixels — the same conversion resize_request
        // uses, so the 600 boundary means what it means elsewhere.
        scale = f64::from(GetDpiForWindow(hwnd)) / 96.0;
    }
    Some(f64::from(client.right - client.left) / scale)
}

/// Show or hide the covered entry's back bar according to the CONTROL's
/// mode.
///
/// The back affordance belongs to an entry that is covering something.
/// TwoPaneView is what decides whether the detail covers the list or
/// sits beside it, so the affordance follows its Mode rather than a
/// width kaya measured for itself. Called once when the arm builds the
/// view and again from ModeChanged, because Mode is settled during
/// layout and not before.
fn apply_split_back_bar(core: &CoreState, window: u64) -> windows_core::Result<()> {
    let Some(view) = core.split_views.get(&window) else {
        return Ok(());
    };
    let covering = view.Mode()? == TwoPaneViewMode::SinglePane;
    let Some(top) = core.nav_stacks.get(&window).and_then(|s| s.last()).copied() else {
        return Ok(());
    };
    if let Some(back) = core.nav_entries.get(&top).and_then(|e| e.back_button.clone()) {
        let back: UIElement = back.cast()?;
        back.SetVisibility(if covering {
            Visibility::Visible
        } else {
            Visibility::Collapsed
        })?;
    }
    Ok(())
}

/// Release the roots a previous list-detail render is still holding.
/// A UIElement lives in exactly ONE Children collection, and appending
/// a parented one does not warn the way GTK does — it takes a
/// non-unwinding panic through the XAML layer and ABORTS the process.
/// The split Grid is the only container that keeps a root outside the
/// window's own content path, so emptying it is the whole job.
fn release_split(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    if let Some(view) = core.split_views.remove(&window) {
        // TwoPaneView holds its panes as PROPERTIES, not in a Children
        // collection, so emptying it means nulling both. Same reason as
        // before: a UIElement lives in exactly one parent, and handing a
        // still-parented one to the next view aborts the process.
        view.SetPane1(None::<&UIElement>)?;
        view.SetPane2(None::<&UIElement>)?;
    }
    Ok(())
}

/// Let go of whatever the WINDOW itself is currently showing. The
/// split Grid is not the only holder: on the FIRST split render the
/// base root is still the window's own content, and appending it to
/// the Grid then fails with "Element is already the child of another
/// element" — which arrives as a non-unwinding panic and takes the
/// process with it.
fn detach_window_content(core: &CoreState, window: u64) -> windows_core::Result<()> {
    if let Some(slot) = core.menu_slots.get(&window) {
        slot.Children()?.Clear()
    } else {
        winui_window(core, window)?.SetContent(None)
    }
}

fn set_window_content(
    core: &CoreState,
    window: u64,
    element: &UIElement,
) -> windows_core::Result<()> {
    if let Some(slot) = core.menu_slots.get(&window) {
        let children = slot.Children()?;
        children.Clear()?;
        children.Append(element)?;
        Ok(())
    } else {
        winui_window(core, window)?.SetContent(element)
    }
}

/// One real MenuFlyout per context anchor, set as the element's
/// ContextFlyout (the platform's own right-click route); its items
/// rebuild from the attached roots with the catalog.
fn ensure_context_flyout(core: &mut CoreState, widget: u64) -> windows_core::Result<()> {
    if core.context_flyouts.contains_key(&widget) {
        return Ok(());
    }
    let flyout = MenuFlyout::new()?;
    let element = core
        .widgets
        .get(&WidgetId(widget))
        .expect("scene validated the context anchor")
        .element()?;
    element.SetContextFlyout(&flyout)?;
    core.context_flyouts.insert(widget, flyout);
    Ok(())
}

/// The canonical shortcut spelling (root-validated: lowercase,
/// `primary`/`shift`/`alt` order, one key) onto the accelerator
/// enums. `primary` = Control on Windows. The same key table feeds
/// the verb's keybd_event injection, so matching is by construction.
fn accelerator_chord(spelling: &str) -> Option<(VirtualKey, VirtualKeyModifiers)> {
    let mut mods = VirtualKeyModifiers::None;
    let mut key = None;
    for part in spelling.split('+') {
        match part {
            "primary" => mods = VirtualKeyModifiers(mods.0 | VirtualKeyModifiers::Control.0),
            "shift" => mods = VirtualKeyModifiers(mods.0 | VirtualKeyModifiers::Shift.0),
            "alt" => mods = VirtualKeyModifiers(mods.0 | VirtualKeyModifiers::Menu.0),
            k => key = virtual_key(k),
        }
    }
    Some((key?, mods))
}

/// One closed key floor (DESIGN.md, Menus) onto Windows.System
/// VirtualKey values. `escape` never arrives — the root rejects every
/// spelling of it.
fn virtual_key(name: &str) -> Option<VirtualKey> {
    match name {
        "enter" => return Some(VirtualKey(0x0D)),
        "delete" => return Some(VirtualKey(0x2E)),
        "left" => return Some(VirtualKey(0x25)),
        "up" => return Some(VirtualKey(0x26)),
        "right" => return Some(VirtualKey(0x27)),
        "down" => return Some(VirtualKey(0x28)),
        // The punctuation set onto the OEM keys. VK_OEM_* are defined
        // by POSITION on the US layout, which is exactly what the
        // canonical names denote.
        "minus" => return Some(VirtualKey(0xBD)),        // VK_OEM_MINUS
        "equal" => return Some(VirtualKey(0xBB)),        // VK_OEM_PLUS (the = key)
        "comma" => return Some(VirtualKey(0xBC)),        // VK_OEM_COMMA
        "period" => return Some(VirtualKey(0xBE)),       // VK_OEM_PERIOD
        "slash" => return Some(VirtualKey(0xBF)),        // VK_OEM_2
        "backslash" => return Some(VirtualKey(0xDC)),    // VK_OEM_5
        "leftbracket" => return Some(VirtualKey(0xDB)),  // VK_OEM_4
        "rightbracket" => return Some(VirtualKey(0xDD)), // VK_OEM_6
        _ => {}
    }
    if let Some(n) = name.strip_prefix('f').and_then(|s| s.parse::<u32>().ok()) {
        if (1..=12).contains(&n) {
            return Some(VirtualKey(0x70 + n as i32 - 1));
        }
    }
    let bytes = name.as_bytes();
    if bytes.len() == 1 && bytes[0].is_ascii_lowercase() {
        return Some(VirtualKey(i32::from(bytes[0]) - 32)); // 'a'..'z' -> A..Z
    }
    if bytes.len() == 1 && bytes[0].is_ascii_digit() {
        return Some(VirtualKey(i32::from(bytes[0]))); // '0'..'9' -> Number0..9
    }
    None
}

/// Rebuild every window bar and context flyout from the model — which
/// IS the post-user mirror, so a rebuild forced by an unrelated prop
/// write preserves the user's toggle/radio state (docs/traps.md). Also
/// re-derives the shortcut table. Coalesced per drain (menus_touched).
fn rebuild_menus(core: &mut CoreState) -> windows_core::Result<()> {
    assert_chord_premise();
    if std::env::var_os("KAYA_WINUI_MENU_PROBE").is_some() {
        menu_probe();
    }
    core.menu_natives.clear();
    core.menu_shortcuts.clear();
    let windows: Vec<(u64, Vec<u64>)> = core
        .menu_windows
        .iter()
        .map(|(w, tops)| (*w, tops.clone()))
        .collect();
    for (window, tops) in windows {
        let Some(bar) = core.menubars.get(&window).cloned() else {
            continue;
        };
        let items = bar.Items()?;
        items.Clear()?;
        ensure_key_hook();
        for top in tops {
            let (label, kind) = {
                let m = &core.menu_models[&top];
                (m.label.clone(), m.kind)
            };
            let bar_item = MenuBarItem::new()?;
            bar_item.SetTitle(&HSTRING::from(&*label))?;
            bar_item.SetIsEnabled(menu_effective_enabled(core, top))?;
            // A bar-level radio_group is a top-level menu whose
            // options use the checkmark idiom — the same inline
            // materialization, one level up (the mac segment's shape).
            let children: Vec<u64> = if kind == MenuItemKind::RadioGroup {
                vec![top]
            } else {
                core.menu_models[&top].children.clone()
            };
            build_menu_items(core, &bar_item.Items()?, &children, MenuAttachment::Window(window))?;
            items.Append(&bar_item)?;
            core.menu_natives
                .insert((MenuAttachment::Window(window), top), MenuNative::Bar(bar_item));
        }
    }
    let attaches: Vec<(u64, Vec<u64>)> = core
        .context_roots
        .iter()
        .map(|(w, roots)| (*w, roots.clone()))
        .collect();
    for (widget, roots) in attaches {
        let Some(flyout) = core.context_flyouts.get(&widget).cloned() else {
            continue;
        };
        let items = flyout.Items()?;
        items.Clear()?;
        build_menu_items(core, &items, &roots, MenuAttachment::Context(widget))?;
    }
    let roots = core.menu_windows.get(&0).cloned().unwrap_or_default();
    let mut order = Vec::new();
    menu_preorder(core, &roots, &mut order);
    for id in order {
        let m = &core.menu_models[&id];
        // Every LEAF command may carry a chord — a checkable item and
        // one option of a group as readily as a plain action. This
        // table also GATES the shortcut verb, so a kind missing here is
        // a chord the harness silently never presses.
        if !m.shortcut.is_empty() && m.kind.takes_shortcut() {
            core.menu_shortcuts.insert(m.shortcut.clone(), id);
        }
    }
    // The rebuild stamped STRUCTURAL enablement alone onto the fresh
    // natives, which would un-gray a role item whose clipboard half
    // says no — the role factor goes back on top.
    if core.clipboard_armed {
        refresh_clipboard_roles(core);
    }
    Ok(())
}

/// Materialize one child list into a flyout item vector, 1:1 per the
/// ratified lowering. Every leaf's Click routes to the shared
/// dispatch carrying ITS OWN attachment — the noun resolves from
/// that anchor at dispatch time (the SwiftUI parity rule), so no
/// rebuild order can cross the stamped copies' nouns. Every native
/// is stamped with the inherited AND of enablement and keyed under
/// its attachment.
/// Attach a chord to a native item — every LEAF command may carry one
/// (a checkable item and one option of a group as readily as a plain
/// action). The accelerator is DRESS, not dispatch: WinUI draws the
/// chord text beside the item from it, and the key hook above eats the
/// keystroke before any default action of it can run (see The chord
/// route for the measurement that moved dispatch there).
fn attach_accelerator(
    accels: &windows_collections::IVector<KeyboardAccelerator>,
    shortcut: &str,
) -> windows_core::Result<()> {
    if shortcut.is_empty() {
        return Ok(());
    }
    let Some((key, mods)) = accelerator_chord(shortcut) else {
        return Ok(());
    };
    let accel = KeyboardAccelerator::new()?;
    accel.SetKey(key)?;
    accel.SetModifiers(mods)?;
    // The default action is a UI Automation pattern lookup — Invoke,
    // else Toggle, else Selection — and it is dead code from this
    // backend's side now: the hook consumes the key first, so the
    // lookup never runs. It is recorded because it is what the split
    // route rested on, and what a future reader tempted to hand chords
    // back to XAML would have to re-establish.
    accels.Append(&accel)?;
    Ok(())
}

fn build_menu_items(
    core: &mut CoreState,
    dest: &windows_collections::IVector<MenuFlyoutItemBase>,
    ids: &[u64],
    attachment: MenuAttachment,
) -> windows_core::Result<()> {
    use windows_core::Interface as _;
    for &id in ids {
        let (kind, label, checked, value, shortcut, children) = {
            let m = &core.menu_models[&id];
            (
                m.kind,
                m.label.clone(),
                m.checked,
                m.value,
                m.shortcut.clone(),
                m.children.clone(),
            )
        };
        let enabled = menu_effective_enabled(core, id);
        match kind {
            MenuItemKind::Separator => {
                dest.Append(&MenuFlyoutSeparator::new()?.cast::<MenuFlyoutItemBase>()?)?;
            }
            MenuItemKind::Action => {
                let item = MenuFlyoutItem::new()?;
                item.SetText(&HSTRING::from(&*label))?;
                item.SetIsEnabled(enabled)?;
                attach_accelerator(&item.KeyboardAccelerators()?, &shortcut)?;
                let handler = RoutedEventHandler::new(move |_, _| {
                    menu_user_activate(id, attachment);
                    Ok(())
                });
                item.Click(&handler)?;
                dest.Append(&item.cast::<MenuFlyoutItemBase>()?)?;
                core.menu_natives.insert((attachment, id), MenuNative::Action(item));
            }
            MenuItemKind::Toggle => {
                let item = ToggleMenuFlyoutItem::new()?;
                item.SetText(&HSTRING::from(&*label))?;
                item.SetIsChecked(checked)?;
                item.SetIsEnabled(enabled)?;
                attach_accelerator(&item.KeyboardAccelerators()?, &shortcut)?;
                let handler = RoutedEventHandler::new(move |_, _| {
                    menu_user_activate(id, attachment);
                    Ok(())
                });
                item.Click(&handler)?;
                dest.Append(&item.cast::<MenuFlyoutItemBase>()?)?;
                core.menu_natives.insert((attachment, id), MenuNative::Toggle(item));
            }
            MenuItemKind::Menu => {
                let sub = MenuFlyoutSubItem::new()?;
                sub.SetText(&HSTRING::from(&*label))?;
                sub.SetIsEnabled(enabled)?;
                build_menu_items(core, &sub.Items()?, &children, attachment)?;
                dest.Append(&sub.cast::<MenuFlyoutItemBase>()?)?;
                core.menu_natives.insert((attachment, id), MenuNative::Sub(sub));
            }
            MenuItemKind::RadioGroup => {
                // Inline with the platform's checkmark idiom: the
                // options join the enclosing vector directly
                // (RadioMenuFlyoutItem.GroupName per radio group);
                // the GROUP mints no chrome of its own here.
                for (index, &option) in children.iter().enumerate() {
                    let (option_label, option_shortcut) = {
                        let m = &core.menu_models[&option];
                        (m.label.clone(), m.shortcut.clone())
                    };
                    let option_enabled = menu_effective_enabled(core, option);
                    let radio = RadioMenuFlyoutItem::new()?;
                    radio.SetText(&HSTRING::from(&*option_label))?;
                    radio.SetGroupName(&HSTRING::from(format!("kmg{id}")))?;
                    radio.SetIsChecked(value == index as f64)?;
                    radio.SetIsEnabled(option_enabled)?;
                    attach_accelerator(&radio.KeyboardAccelerators()?, &option_shortcut)?;
                    let handler = RoutedEventHandler::new(move |_, _| {
                        menu_user_activate(option, attachment);
                        Ok(())
                    });
                    radio.Click(&handler)?;
                    dest.Append(&radio.cast::<MenuFlyoutItemBase>()?)?;
                    core.menu_natives
                        .insert((attachment, option), MenuNative::Option(radio));
                }
            }
            // The closed grammar: options build through their group.
            MenuItemKind::RadioOption => {}
        }
    }
    Ok(())
}




// --- The chord route (Win32) -------------------------------------------
//
// EVERY chord this catalog owns dispatches from here. The hook is
// THREAD-scoped (never global): it watches this UI thread's key-downs,
// matches the canonical spelling against the same catalog table the
// verb gates on, performs the state change the platform would have
// performed, and consumes only a chord this catalog owns — so the
// accelerator route cannot double-fire behind it.
//
// It used to serve ONE kind. ToggleMenuFlyoutItem is the one leaf kind
// whose KeyboardAccelerator WinUI never matches: measured on the VM,
// with the chord genuinely injected, a plain command's accelerator
// fires (Invoke pattern), one option of a group fires (SelectionItem
// pattern), and a checkable command's does nothing — not the pattern,
// not an explicit Invoked handler, not a copy on the MenuBar or on the
// content Grid, and not a collapsed companion item. So the checkable
// kind came here and the other two rode the platform.
//
// THAT SPLIT WAS A RACE, and what it raced was how far behind the UI
// thread had fallen — which is exactly what the chord BEFORE it put
// there. Measured 2026-08-03, commands scene, one leg 16 times: the
// group-option chord (primary+2, the accelerator route) landed 67ms
// and 81ms after the preceding chord's activation in the two runs that
// passed, and within 42ms in all fourteen that failed. Failed means
// LOST, not late: no Click, no occurrence, and nothing for the
// harness's five seconds of polling to find, while the same chord
// fires normally seconds later. The hook saw every one of those
// keystrokes and resolved every one against menu_shortcuts — right
// item, right kind, modifiers correct at message-retrieval time — so
// the chord was always in the window and only the platform's dispatch
// of it went missing. A scene that presses one chord, waits for its
// occurrence and presses the next walks into that window by
// construction, which is why it read as an intermittent WinUI-only
// failure of the step AFTER a menu mutation.
//
// The whole point of this route is that it does not depend on XAML's
// input pipeline having caught up: the message-time key state is read
// as the message is retrieved, and the answer comes from kaya's own
// table. The accelerators stay attached for the chord TEXT WinUI draws
// beside each item, which is all they are now for.
unsafe extern "system" {
    fn SetWindowsHookExW(id: i32, proc_: HookProc, module: isize, thread: u32) -> isize;
    fn CallNextHookEx(hook: isize, code: i32, wparam: usize, lparam: isize) -> isize;
    fn GetCurrentThreadId() -> u32;
    fn GetKeyState(vkey: i32) -> i16;
}
type HookProc = unsafe extern "system" fn(i32, usize, isize) -> isize;

thread_local! {
    static KEY_HOOK: std::cell::Cell<isize> = const { std::cell::Cell::new(0) };
}

fn modifier_down(vkey: i32) -> bool {
    (unsafe { GetKeyState(vkey) }) < 0
}

/// The canonical key name for a virtual-key code — the reverse of
/// [`virtual_key`], over the same closed floor.
fn key_name(code: u32) -> Option<String> {
    Some(match code {
        0x0D => "enter".to_owned(),
        0x2E => "delete".to_owned(),
        0x25 => "left".to_owned(),
        0x26 => "up".to_owned(),
        0x27 => "right".to_owned(),
        0x28 => "down".to_owned(),
        0xBD => "minus".to_owned(),
        0xBB => "equal".to_owned(),
        0xBC => "comma".to_owned(),
        0xBE => "period".to_owned(),
        0xBF => "slash".to_owned(),
        0xDC => "backslash".to_owned(),
        0xDB => "leftbracket".to_owned(),
        0xDD => "rightbracket".to_owned(),
        0x30..=0x39 => char::from(b'0' + (code - 0x30) as u8).to_string(),
        0x41..=0x5A => char::from(b'a' + (code - 0x41) as u8).to_string(),
        0x70..=0x7B => format!("f{}", code - 0x70 + 1),
        _ => return None,
    })
}

unsafe extern "system" fn key_hook(code: i32, wparam: usize, lparam: isize) -> isize {
    const HC_ACTION: i32 = 0;
    // Bit 31 set = the key is coming up; bit 30 set = it was already
    // down (auto-repeat), which a menu chord ignores.
    if code == HC_ACTION && (lparam & (1 << 31)) == 0 && (lparam & (1 << 30)) == 0 {
        if let Some(key) = key_name(wparam as u32) {
            let mut spelling = String::new();
            if modifier_down(0x11) {
                spelling.push_str("primary+");
            }
            if modifier_down(0x10) {
                spelling.push_str("shift+");
            }
            if modifier_down(0x12) {
                spelling.push_str("alt+");
            }
            spelling.push_str(&key);
            let hit = CORE.with_borrow(|core| {
                let core = core.as_ref()?;
                let item = *core.menu_shortcuts.get(&spelling)?;
                let kind = core.menu_models.get(&item)?.kind;
                Some((item, kind, menu_effective_enabled(core, item)))
            });
            if let Some((item, kind, enabled)) = hit {
                // A disabled item is INERT, exactly as native chrome
                // leaves it — the chord is still this catalog's, so it
                // is eaten rather than sprayed at whatever is behind.
                if enabled {
                    // The native owns the immediate user change, exactly
                    // as it does for a click; menu_user_activate mirrors
                    // from it and emits. EXHAUSTIVE over the kind: a new
                    // leaf kind that may carry a chord fails to COMPILE
                    // here rather than reaching a catch-all that leaves
                    // its chord dispatching nothing.
                    let _ = CORE.with_borrow(|core| -> windows_core::Result<()> {
                        let Some(core) = core.as_ref() else { return Ok(()) };
                        let native = core.menu_natives.get(&(MenuAttachment::Window(0), item));
                        match kind {
                            MenuItemKind::Toggle => {
                                if let Some(MenuNative::Toggle(native)) = native {
                                    let now = native.IsChecked()?;
                                    native.SetIsChecked(!now)?;
                                }
                            }
                            // One option of a group: checking it is what
                            // the platform's own Select() does, and the
                            // shared GroupName clears the sibling.
                            MenuItemKind::RadioOption => {
                                if let Some(MenuNative::Option(native)) = native {
                                    native.SetIsChecked(true)?;
                                }
                            }
                            // A plain command owns no state of its own.
                            MenuItemKind::Action => {}
                            // Not leaf kinds: menu_shortcuts holds only
                            // what takes_shortcut admits, and the rebuild
                            // is the one writer.
                            MenuItemKind::Menu
                            | MenuItemKind::RadioGroup
                            | MenuItemKind::Separator => {}
                        }
                        Ok(())
                    });
                    menu_user_activate(item, MenuAttachment::Window(0));
                }
                return 1; // consumed: this catalog owns the chord
            }
        }
    }
    let hook = KEY_HOOK.with(|h| h.get());
    unsafe { CallNextHookEx(hook, code, wparam, lparam) }
}

/// Install the thread-scoped key hook once, on the UI thread.
fn ensure_key_hook() {
    const WH_KEYBOARD: i32 = 2;
    KEY_HOOK.with(|slot| {
        if slot.get() == 0 {
            slot.set(unsafe { SetWindowsHookExW(WH_KEYBOARD, key_hook, 0, GetCurrentThreadId()) });
        }
    });
}

/// THE user dispatch path: chrome clicks, the KeyboardAccelerator
/// route, and harness verbs all land here. Fires from the message
/// loop, never under an apply borrow. Mirrors FIRST (the
/// post-user-mirror rule), then emits with the item's identity and
/// the noun of the attachment whose copy fired — resolved HERE, at
/// dispatch, from that anchor (the SwiftUI parity rule: the keys ARE
/// the noun, so the noun can only come from the copy's own anchor).
/// Disabled items — the inherited AND — stay inert, exactly as
/// native chrome leaves them.
fn menu_user_activate(item: u64, attachment: MenuAttachment) {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        // Echo doctrine belt: no programmatic write path raises Click
        // on these controls (the MENU PROBE verifies), but if one
        // ever did, the apply guard keeps it quiet.
        if core.apply_quiet.load(std::sync::atomic::Ordering::Relaxed) {
            return;
        }
        let Some(model) = core.menu_models.get(&item) else {
            return;
        };
        let kind = model.kind;
        let was_checked = model.checked;
        let role = model.role.clone();
        if !menu_effective_enabled(core, item) {
            return;
        }
        // A DISABLED ROLE ITEM IS INERT beyond the structural AND: the
        // intersection half lives on the native's IsEnabled, which
        // this route does not consult — so it is recomputed here, the
        // same freshness rule the harness activation applies (the mac
        // finding, docs/clipboard-plan.md §3).
        if matches!(role.as_str(), "cut" | "copy" | "paste") && !role_enabled(core, &role) {
            return;
        }
        let noun = match attachment {
            MenuAttachment::Window(_) => Path::new(),
            MenuAttachment::Context(widget) => {
                core.context_nouns.get(&widget).cloned().unwrap_or_default()
            }
        };
        match kind {
            MenuItemKind::Action => {
                // A clipboard role PERFORMS rather than reports: the
                // item is the platform's own command acting on the
                // focused widget, so no menu occurrence goes up (the
                // rule every arm shares; DESIGN.md — gestures are
                // commands).
                if perform_clipboard_role(core, &role) {
                    return;
                }
                core.occurrences.send(if noun.is_empty() {
                    Occurrence::MenuActivated { item: MenuItemId(item) }
                } else {
                    Occurrence::InstanceMenuActivated {
                        item: MenuItemId(item),
                        path: noun.clone(),
                    }
                });
            }
            MenuItemKind::Toggle => {
                // The native control owns the immediate user change
                // (it flipped IsChecked before raising Click): mirror
                // from the REAL control first — the firing copy's own
                // native, by its attachment key — then emit; a later
                // rebuild starts from this mirror (docs/traps.md).
                let checked = match core.menu_natives.get(&(attachment, item)) {
                    Some(MenuNative::Toggle(native)) => {
                        native.IsChecked().unwrap_or(!was_checked)
                    }
                    _ => !was_checked,
                };
                core.menu_models.get_mut(&item).expect("checked above").checked = checked;
                core.occurrences.send(if noun.is_empty() {
                    Occurrence::MenuToggled { item: MenuItemId(item), checked }
                } else {
                    Occurrence::InstanceMenuToggled {
                        item: MenuItemId(item),
                        path: noun.clone(),
                        checked,
                    }
                });
            }
            MenuItemKind::RadioOption => {
                let Some(group) = core.menu_models.get(&item).and_then(|m| m.parent) else {
                    return;
                };
                let Some(index) = core
                    .menu_models
                    .get(&group)
                    .and_then(|g| g.children.iter().position(|&c| c == item))
                else {
                    return;
                };
                // Re-selecting the selected option is not a change and
                // emits nothing, exactly as the platform's own change
                // route behaves (the choice contract).
                if core.menu_models[&group].value == index as f64 {
                    return;
                }
                core.menu_models.get_mut(&group).expect("resolved above").value =
                    index as f64; // the retained mirror, BEFORE the emit
                core.occurrences.send(if noun.is_empty() {
                    Occurrence::MenuValueChanged {
                        group: MenuItemId(group),
                        index: index as f64,
                    }
                } else {
                    Occurrence::InstanceMenuValueChanged {
                        group: MenuItemId(group),
                        path: noun.clone(),
                        index: index as f64,
                    }
                });
            }
            // Grouping nodes and separators have no activation; native
            // chrome opens or ignores them.
            _ => {}
        }
    });
}

/// The harness's REAL invoke route (the ContentDialog precedent): the
/// item's automation peer, cast to the provider pattern it exposes —
/// Invoke for plain/radio items, Toggle for toggle items. The peer
/// pipeline runs the control's own OnInvoke, which raises the same
/// Click a pointer press does. Grouping chrome has no activation.
fn invoke_menu_native(native: &MenuNative) -> windows_core::Result<()> {
    use bindings::Microsoft::UI::Xaml::Automation::Peers::FrameworkElementAutomationPeer;
    use bindings::Microsoft::UI::Xaml::Automation::Provider::{IInvokeProvider, IToggleProvider};
    use windows_core::Interface as _;
    let element: UIElement = match native {
        MenuNative::Action(i) => i.cast()?,
        MenuNative::Toggle(i) => i.cast()?,
        MenuNative::Option(i) => i.cast()?,
        MenuNative::Bar(_) | MenuNative::Sub(_) => return Ok(()),
    };
    let peer = FrameworkElementAutomationPeer::CreatePeerForElement(&element)?;
    if let Ok(invoke) = peer.cast::<IInvokeProvider>() {
        return invoke.Invoke();
    }
    peer.cast::<IToggleProvider>()?.Toggle()
}


/// The PREMISE the peer-invoke route rests on, checked once per process
/// — not flag-gated, because a silent change here is a dead harness
/// activation or a checkmark that never moves.
///
/// [`invoke_menu_native`] asks an item's automation peer for Invoke
/// FIRST and falls back to Toggle, which is the platform's own
/// priority. `MenuFlyoutItem` has Invoke, so a plain command activates
/// through it; `ToggleMenuFlyoutItem` does NOT, so a checkable command
/// reaches Toggle and its checkmark moves. A future WinUI that changed
/// either answer would silently reroute the harness's activation — an
/// item that cannot be invoked at all, or a toggle invoked instead of
/// toggled — so the premise fails loudly here rather than as a scene
/// that stopped observing anything.
///
/// The CHORD route no longer rests on any of this: every chord this
/// catalog owns dispatches from the thread key hook and is consumed
/// there, so no accelerator's default action runs (see The chord
/// route).
fn assert_chord_premise() {
    static CHECKED: OnceLock<()> = OnceLock::new();
    if CHECKED.set(()).is_err() {
        return;
    }
    let probe: windows_core::Result<()> = (|| {
        use bindings::Microsoft::UI::Xaml::Automation::Peers::FrameworkElementAutomationPeer;
        use bindings::Microsoft::UI::Xaml::Automation::Provider::IInvokeProvider;
        use windows_core::Interface as _;
        let action: UIElement = MenuFlyoutItem::new()?.cast()?;
        let action_invokes = FrameworkElementAutomationPeer::CreatePeerForElement(&action)?
            .cast::<IInvokeProvider>()
            .is_ok();
        let toggle: UIElement = ToggleMenuFlyoutItem::new()?.cast()?;
        let toggle_invokes = FrameworkElementAutomationPeer::CreatePeerForElement(&toggle)?
            .cast::<IInvokeProvider>()
            .is_ok();
        assert!(
            action_invokes,
            "kaya: MenuFlyoutItem lost its Invoke automation pattern — the \
             harness's menu_activate has no pattern left to drive, so a plain \
             command can no longer be activated at all (docs/traps.md)"
        );
        assert!(
            !toggle_invokes,
            "kaya: ToggleMenuFlyoutItem GAINED an Invoke automation pattern — \
             invoke_menu_native prefers Invoke, so a checkable command would be \
             INVOKED instead of toggled and its checkmark would never move \
             (docs/traps.md)"
        );
        Ok(())
    })();
    if let Err(e) = probe {
        eprintln!("kaya: chord-premise check failed: {:?} {}", e.code(), e.message());
    }
}

/// KAYA_WINUI_MENU_PROBE: the flag-gated instrument (the
/// KAYA_WINUI_NAV_PROBE pattern) answering this backend's two menu
/// behavior questions in-band, on detached canary items:
/// (1) echo doctrine — programmatic IsChecked writes must not raise
/// Click; (2) the peer-invoke route must raise Click on an item whose
/// flyout has never opened (the bar-activation mechanism). Runs once,
/// at the first rebuild.
fn menu_probe() {
    static RAN: OnceLock<()> = OnceLock::new();
    if RAN.set(()).is_err() {
        return;
    }
    let probe: windows_core::Result<()> = (|| {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;
        // (1) Echo canary: programmatic set on toggle and radio items.
        let toggled = Arc::new(AtomicBool::new(false));
        let toggle = ToggleMenuFlyoutItem::new()?;
        let seen = toggled.clone();
        toggle.Click(&RoutedEventHandler::new(move |_, _| {
            seen.store(true, Ordering::Relaxed);
            Ok(())
        }))?;
        toggle.SetIsChecked(true)?;
        toggle.SetIsChecked(false)?;
        let radio_fired = Arc::new(AtomicBool::new(false));
        let radio = RadioMenuFlyoutItem::new()?;
        let seen = radio_fired.clone();
        radio.Click(&RoutedEventHandler::new(move |_, _| {
            seen.store(true, Ordering::Relaxed);
            Ok(())
        }))?;
        radio.SetGroupName(&HSTRING::from("kmg-probe"))?;
        radio.SetIsChecked(true)?;
        eprintln!(
            "kaya: MENU PROBE programmatic-set clicks: toggle={} radio={} (must both be false)",
            toggled.load(Ordering::Relaxed),
            radio_fired.load(Ordering::Relaxed),
        );
        // (2) Peer-invoke canary on a never-opened item.
        let clicked = Arc::new(AtomicBool::new(false));
        let item = MenuFlyoutItem::new()?;
        let seen = clicked.clone();
        item.Click(&RoutedEventHandler::new(move |_, _| {
            seen.store(true, Ordering::Relaxed);
            Ok(())
        }))?;
        invoke_menu_native(&MenuNative::Action(item))?;
        eprintln!(
            "kaya: MENU PROBE peer invoke on closed item: click fired={} (must be true)",
            clicked.load(Ordering::Relaxed),
        );
        Ok(())
    })();
    if let Err(e) = probe {
        eprintln!("kaya: MENU PROBE failed: {:?} {}", e.code(), e.message());
    }
}

// ---------------------------------------------------------------------
// Clipboard (DESIGN.md, Clipboard; docs/clipboard-plan.md §6 for what
// this platform was measured to charge — tools/win/clipprobe).
//
// CLASSIC WIN32, DELIBERATELY. WinRT DataTransfer's SetContent is
// documented to work "only when the application is in the foreground",
// which a matrix leg cannot promise; its custom-format bridge to Win32
// atoms is documented only in the read direction; and its content dies
// with the process unless flushed. Classic SetClipboardData has none
// of those charges — measured: five formats set in one open outlive
// the setter's exit and read back byte-exact through stock PowerShell,
// and RegisterClipboardFormatW carries the ratified slashed custom id
// VERBATIM (atom name reads back "dev.kaya/note").
//
// Reads are synchronous pulls here, so "answered exactly once" needs
// no async bridge on this backend: the arm chooses the richest
// offered∩accepted format off the ENUMERATED offer and reads it in
// one open.
// ---------------------------------------------------------------------

const CF_UNICODETEXT: u32 = 13;
const CF_HDROP: u32 = 15;

fn clip_register(name: &str) -> u32 {
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        windows::Win32::System::DataExchange::RegisterClipboardFormatW(
            windows_core::PCWSTR(wide.as_ptr()),
        )
    }
}

/// Open with a bounded retry: the clipboard is a global lock, and
/// another process holding it answers with an error, not a wait.
fn clip_open_retry() -> windows_core::Result<()> {
    let mut last = Ok(());
    for attempt in 0..10 {
        last = unsafe { windows::Win32::System::DataExchange::OpenClipboard(None) };
        if last.is_ok() {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(20 * (attempt + 1)));
    }
    last
}

fn clip_set_bytes(format: u32, bytes: &[u8]) -> windows_core::Result<()> {
    unsafe {
        let hglobal = windows::Win32::System::Memory::GlobalAlloc(
            windows::Win32::System::Memory::GMEM_MOVEABLE,
            bytes.len().max(1),
        )?;
        let p = windows::Win32::System::Memory::GlobalLock(hglobal);
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
        let _ = windows::Win32::System::Memory::GlobalUnlock(hglobal);
        windows::Win32::System::DataExchange::SetClipboardData(
            format,
            Some(windows::Win32::Foundation::HANDLE(hglobal.0)),
        )?;
        Ok(())
    }
}

fn clip_available(format: u32) -> bool {
    unsafe { windows::Win32::System::DataExchange::IsClipboardFormatAvailable(format).is_ok() }
}

/// One format's bytes, inside an already-open clipboard. GlobalSize
/// may exceed the written length (the allocator rounds up), so
/// self-delimiting formats must trust their own delimiters; a custom
/// format's bytes are whatever the allocation says, which is the
/// platform's own grammar for them.
fn clip_get_bytes(format: u32) -> Option<Vec<u8>> {
    unsafe {
        let handle = windows::Win32::System::DataExchange::GetClipboardData(format).ok()?;
        let hglobal = windows::Win32::Foundation::HGLOBAL(handle.0);
        let size = windows::Win32::System::Memory::GlobalSize(hglobal);
        let p = windows::Win32::System::Memory::GlobalLock(hglobal);
        if p.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(p as *const u8, size).to_vec();
        let _ = windows::Win32::System::Memory::GlobalUnlock(hglobal);
        Some(bytes)
    }
}

fn clip_utf16z(s: &str) -> Vec<u8> {
    s.encode_utf16()
        .chain(std::iter::once(0))
        .flat_map(|u| u.to_le_bytes())
        .collect()
}

/// CF_HTML with 10-digit fixed-width offsets. Fixed width is what
/// makes the header length a CONSTANT rather than a fixpoint; pad
/// while computing but print unpadded and every offset is silently
/// short. Microsoft's own doc example is arithmetically wrong (its
/// fragment offsets mix two relative bases) — this construction is
/// verified byte-exact against a worked example and round-trips
/// through PresentationCore's own reader (tools/win/clipprobe).
fn build_cf_html(fragment: &str) -> Vec<u8> {
    const HEADER_LEN: usize = 105;
    const PREFIX: &str = "<html>\r\n<body>\r\n<!--StartFragment-->";
    const SUFFIX: &str = "<!--EndFragment-->\r\n</body>\r\n</html>";
    let start_fragment = HEADER_LEN + PREFIX.len();
    let end_fragment = start_fragment + fragment.len();
    let end_html = end_fragment + SUFFIX.len();
    let header = format!(
        "Version:0.9\r\nStartHTML:{HEADER_LEN:010}\r\nEndHTML:{end_html:010}\r\nStartFragment:{start_fragment:010}\r\nEndFragment:{end_fragment:010}\r\n"
    );
    debug_assert!(header.len() == HEADER_LEN, "the CF_HTML header stopped being a constant");
    let mut out = header.into_bytes();
    out.extend_from_slice(PREFIX.as_bytes());
    out.extend_from_slice(fragment.as_bytes());
    out.extend_from_slice(SUFFIX.as_bytes());
    out
}

/// The read side's equal and opposite parser: kaya's html
/// representation is the raw fragment, so a CF_HTML payload — whose
/// header kaya may not have written — is sliced by its own
/// StartFragment/EndFragment BYTE offsets. Proven against a foreign
/// header with different padding than ours (PowerShell 5.1's -AsHtml
/// pads to 9 digits with trailing spaces; digits-then-stop parses
/// both).
fn parse_cf_html(payload: &[u8]) -> Option<String> {
    let head = String::from_utf8_lossy(&payload[..payload.len().min(400)]).into_owned();
    let grab = |key: &str| -> Option<usize> {
        let at = head.find(key)? + key.len();
        head[at..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .parse()
            .ok()
    };
    let start = grab("StartFragment:")?;
    let end = grab("EndFragment:")?;
    if start >= end || end > payload.len() {
        return None;
    }
    Some(String::from_utf8_lossy(&payload[start..end]).into_owned())
}

/// DROPFILES: the 20-byte struct (pFiles=20, pt={0,0}, fNC=0,
/// fWide=1), then UTF-16 paths each NUL-terminated, then one extra
/// NUL — measured round-tripping through Explorer's own
/// FileDropList reader.
fn build_dropfiles(paths: &[String]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&20u32.to_le_bytes());
    out.extend_from_slice(&0i32.to_le_bytes());
    out.extend_from_slice(&0i32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&1u32.to_le_bytes());
    for path in paths {
        out.extend_from_slice(&clip_utf16z(path));
    }
    out.extend_from_slice(&[0, 0]);
    out
}

fn parse_dropfiles(bytes: &[u8]) -> Vec<String> {
    if bytes.len() < 20 {
        return Vec::new();
    }
    let p_files = u32::from_le_bytes(bytes[0..4].try_into().unwrap()) as usize;
    let f_wide = u32::from_le_bytes(bytes[16..20].try_into().unwrap());
    if f_wide == 0 {
        // An ANSI list is legal but nothing modern writes one; a
        // foreign ANSI writer would surface here as an empty answer
        // rather than mojibake.
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut at = p_files;
    loop {
        let mut units = Vec::new();
        while at + 1 < bytes.len() {
            let u = u16::from_le_bytes([bytes[at], bytes[at + 1]]);
            at += 2;
            if u == 0 {
                break;
            }
            units.push(u);
        }
        if units.is_empty() {
            break;
        }
        out.push(String::from_utf16_lossy(&units));
    }
    out
}

/// Choose the RICHEST representation the clipboard offers that the
/// accept list takes, read exactly that one, and answer — None for no
/// intersection, the universal no. Shared by the privileged read and
/// the declared-paste delivery, because the two differ in their
/// trigger and never in what they can materialize. Descending clip
/// value — custom (accept-list order), files, image, html, text — the
/// canonical order (§1).
fn materialize_clipboard(accepting: &str) -> windows_core::Result<Option<crate::protocol::Representation>> {
    use crate::protocol::Representation as R;
    let (kinds, custom) = crate::wire::parse_accept_list(accepting);
    let chosen_custom = custom
        .iter()
        .map(|id| (id.to_string(), clip_register(id)))
        .find(|(_, format)| clip_available(*format));
    let png = clip_register("PNG");
    let html = clip_register("HTML Format");

    clip_open_retry()?;
    let answer = (|| {
        if let Some((id, format)) = chosen_custom {
            return clip_get_bytes(format).map(|bytes| R::Custom {
                id,
                bytes: crate::protocol::Blob(std::sync::Arc::from(&bytes[..])),
            });
        }
        if kinds & crate::wire::CLIP_FILES != 0 && clip_available(CF_HDROP) {
            let paths = clip_get_bytes(CF_HDROP).map(|b| parse_dropfiles(&b)).unwrap_or_default();
            let files: Vec<_> = paths
                .into_iter()
                .map(|path| {
                    let name = std::path::Path::new(&path)
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    // The picker's capability arriving through the
                    // second door: the same registration the file
                    // dialog result makes, so kaya_open_picked
                    // redeems a pasted file identically.
                    let handle = crate::capi::picked_register(std::sync::Arc::new(
                        crate::protocol::PathSource { name: name.clone(), path: path.clone() },
                    ));
                    crate::protocol::PickedFile { handle, name, local_path: path }
                })
                .collect();
            return (!files.is_empty()).then_some(R::Files(files));
        }
        if kinds & crate::wire::CLIP_IMAGE != 0 && clip_available(png) {
            return clip_get_bytes(png)
                .map(|b| R::Image(crate::protocol::Blob(std::sync::Arc::from(&b[..]))));
        }
        if kinds & crate::wire::CLIP_HTML != 0 && clip_available(html) {
            return clip_get_bytes(html).and_then(|b| parse_cf_html(&b)).map(R::Html);
        }
        if kinds & crate::wire::CLIP_TEXT != 0 && clip_available(CF_UNICODETEXT) {
            return clip_get_bytes(CF_UNICODETEXT).map(|bytes| {
                let units: Vec<u16> = bytes
                    .chunks_exact(2)
                    .map(|c| u16::from_le_bytes([c[0], c[1]]))
                    .take_while(|&u| u != 0)
                    .collect();
                // The lf boundary: clipboard text is CRLF by Windows
                // convention, guest strings are LF everywhere.
                R::Text(lf(String::from_utf16_lossy(&units)))
            });
        }
        None
    })();
    unsafe { windows::Win32::System::DataExchange::CloseClipboard()? };
    Ok(answer)
}

/// The focused editable widget, if any: the root admits `accepts` on
/// entries and textareas alone (scene.rs), and a TextBox IS its own
/// focus target here — no GtkText delegation to walk.
fn focused_editable_id(core: &CoreState) -> Option<u64> {
    let focused = |field: &TextBox| {
        field
            .FocusState()
            .map(|s| s != FocusState::Unfocused)
            .unwrap_or(false)
    };
    for (i, field) in core.entries.iter().enumerate() {
        if focused(field) {
            return Some(core.entry_ids[i]);
        }
    }
    for (i, field) in core.textareas.iter().enumerate() {
        if focused(field) {
            return Some(core.textarea_ids[i]);
        }
    }
    None
}

fn editable_by_id(core: &CoreState, id: u64) -> Option<TextBox> {
    if let Some(i) = core.entry_ids.iter().position(|&e| e == id) {
        return Some(core.entries[i].clone());
    }
    core.textarea_ids
        .iter()
        .position(|&t| t == id)
        .map(|i| core.textareas[i].clone())
}

/// Whether a clipboard role's command can act right now; a non-role
/// item answers true and pays nothing. THE SAME RULE AS THE OTHER
/// ARMS (kayaRoleEnabled, gtk's role_enabled): paste is the
/// INTERSECTION of what the clipboard offers and what the focused
/// widget accepts — a widget that declared NOTHING still pastes (the
/// platform inserts), so an undeclared target enables on the text
/// offer alone. Cut and copy need a focused editable.
/// IsClipboardFormatAvailable needs no open, so this is cheap enough
/// for every refresh site.
fn role_enabled(core: &CoreState, role: &str) -> bool {
    match role {
        "cut" | "copy" => focused_editable_id(core).is_some(),
        "paste" => {
            let Some(id) = focused_editable_id(core) else {
                return false;
            };
            let accepts = core.accepts.get(&id).cloned().unwrap_or_default();
            if accepts.is_empty() {
                return clip_available(CF_UNICODETEXT);
            }
            let (kinds, custom) = crate::wire::parse_accept_list(&accepts);
            custom.iter().any(|id| clip_available(clip_register(id)))
                || (kinds & crate::wire::CLIP_FILES != 0 && clip_available(CF_HDROP))
                || (kinds & crate::wire::CLIP_IMAGE != 0 && clip_available(clip_register("PNG")))
                || (kinds & crate::wire::CLIP_HTML != 0
                    && clip_available(clip_register("HTML Format")))
                || (kinds & crate::wire::CLIP_TEXT != 0 && clip_available(CF_UNICODETEXT))
        }
        _ => true,
    }
}

/// Recompute the clipboard roles' enablement onto the REAL chrome.
/// THE MAC FINDING, spelled WinUI (docs/clipboard-plan.md §3):
/// enablement is the intersection of what the clipboard offers and
/// what the focused widget accepts, and both move long after the bar
/// was built. menu_user_activate refuses a disabled item natively, so
/// this runs wherever enablement can change hands: a role or accepts
/// list lands, a copy goes out, the clipboard or the focus changes,
/// the coalesced rebuild restamps structural enablement — and before
/// a harness activation.
fn refresh_clipboard_roles(core: &CoreState) {
    for (&id, model) in &core.menu_models {
        if !matches!(model.role.as_str(), "cut" | "copy" | "paste") {
            continue;
        }
        let on = menu_effective_enabled(core, id) && role_enabled(core, model.role.as_str());
        for ((_, native_id), native) in &core.menu_natives {
            if *native_id == id {
                let _ = native.set_enabled(on);
            }
        }
    }
}

/// Perform a clipboard role on the focused widget. Answers whether it
/// WAS one, so a plain action falls through to its own dispatch.
///
/// THE PASTE SPLIT (DESIGN.md): a widget that DECLARED what it
/// accepts takes the content itself — the same materialization walk
/// as the privileged read, delivered to the paste hook — while one
/// that declared nothing gets the platform's own insertion
/// (TextBox::PasteFromClipboard, the method its own context menu
/// calls) and its ordinary change path reports the result. The
/// swallow counter is NOT bumped for that insertion: a paste acts
/// like the user, and the field's TextChanged is the report.
fn perform_clipboard_role(core: &mut CoreState, role: &str) -> bool {
    match role {
        "cut" | "copy" => {
            if let Some(field) = focused_editable_id(core).and_then(|id| editable_by_id(core, id))
            {
                let _ = if role == "cut" {
                    field.CutSelectionToClipboard()
                } else {
                    field.CopySelectionToClipboard()
                };
            }
            true
        }
        "paste" => {
            let Some(id) = focused_editable_id(core) else {
                return true;
            };
            let accepts = core.accepts.get(&id).cloned().unwrap_or_default();
            if accepts.is_empty() {
                if let Some(field) = editable_by_id(core, id) {
                    let _ = field.PasteFromClipboard();
                }
                return true;
            }
            let clip = match materialize_clipboard(&accepts) {
                Ok(Some(clip)) => clip,
                // A paste that delivered nothing is not an occurrence
                // (the read owns the empty answer).
                _ => return true,
            };
            let tag = core
                .entry_tags
                .get(&id)
                .cloned()
                .unwrap_or_else(|| crate::wire::click_tag(id, &[]));
            let occurrence = match crate::wire::decode_click_tag(&tag) {
                Occurrence::ButtonClicked { id } => Occurrence::Pasted { id, clip },
                Occurrence::InstanceButtonClicked { node, path } => {
                    Occurrence::InstancePasted { node, path, clip }
                }
                other => panic!(
                    "kaya: a paste tag decoded to {other:?}, which is not a widget identity"
                ),
            };
            core.occurrences.send(occurrence);
            true
        }
        _ => false,
    }
}

fn apply(core: &mut CoreState, op: ApplyOp) -> windows_core::Result<()> {
    // KAYA_WINUI_TRACE=1: print every op before applying it, so a
    // stowed-exception crash names its last op. The probe sets it.
    if trace_enabled() {
        eprintln!("kaya: winui apply {op:?}");
    }
    match op {
        ApplyOp::Create { id, kind, tag } => {
            let native = match kind {
                WidgetKind::Entry => {
                    // Uncontrolled: the field owns its text; TextChanged
                    // reports each edit (programmatic SetText included,
                    // which is what lets the selftest type like a user)
                    // with the entry's identity tag, and the app folds
                    // it into its own model.
                    //
                    // Two prerequisites, both VM-proven (2026-07-15):
                    // MRT init needs an exe-adjacent resources.pri (the
                    // deploy ships tools/guest/minimal-resources.pri),
                    // and the built-in template's deferred theme XAML
                    // needs the composed Application's metadata provider
                    // (see KayaOuter below) — without it the XAML
                    // parser fail-fasts (0xC000027B) resolving
                    // TextCommandBarFlyout. The minimal template keeps
                    // the widget free of chrome resources kaya doesn't
                    // ship.
                    let field = TextBox::new()?;
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("entries carry a tag");
                    let handler_tag = tag.clone();
                    let field_for_handler = field.clone();
                    let swallow =
                        std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
                    let handler_swallow = swallow.clone();
                    let handler = TextChangedEventHandler::new(move |_, _| {
                        // A programmatic write already emitted its
                        // occurrence synchronously (or, for SetProp,
                        // deliberately not at all) — this late raise
                        // is its shadow. See entry_swallow.
                        if handler_swallow
                            .fetch_update(
                                std::sync::atomic::Ordering::Relaxed,
                                std::sync::atomic::Ordering::Relaxed,
                                |n| n.checked_sub(1),
                            )
                            .is_ok()
                        {
                            return Ok(());
                        }
                        let text = lf(field_for_handler.Text()?.to_string());
                        sink.send_text_tag(&handler_tag, &text);
                        Ok(())
                    });
                    field.TextChanged(&handler)?;
                    // Paste's enablement is the offer/accepts
                    // intersection AT THE FOCUSED WIDGET, so focus
                    // moving hands it over — deferred a tick, because
                    // a programmatic Focus() inside apply raises this
                    // while CORE is borrowed.
                    let focus_handler = RoutedEventHandler::new(move |_, _| {
                        defer_role_refresh();
                        Ok(())
                    });
                    field.GotFocus(&focus_handler)?;
                    let blur_handler = RoutedEventHandler::new(move |_, _| {
                        defer_role_refresh();
                        Ok(())
                    });
                    field.LostFocus(&blur_handler)?;
                    core.entries.push(field.clone());
                    core.entry_ids.push(id.0);
                    core.entry_swallow.insert(id.0, swallow);
                    core.entry_tags.insert(id.0, tag);
                    NativeWidget::Entry(field)
                }
                WidgetKind::Column => {
                    // Grid and not StackPanel: a StackPanel sizes every
                    // child to its natural extent along the stacking axis
                    // and has no per-child weight of any kind, so
                    // proportional grow is not merely awkward there but
                    // unrepresentable. Grid's star sizing *is* the
                    // contract — a definition of Star(w) takes w/Σw of
                    // what is left after the Auto definitions — so the
                    // weights map across with no arithmetic of our own.
                    //
                    // The cost is that Grid places by attached Row/Column
                    // index rather than by child order, so every
                    // structural change has to restamp them (see
                    // reindex).
                    let grid = Grid::new()?;
                    // Uniform layout default: 8-unit gap between adjacent
                    // children, matching every other backend. Grid spells
                    // it per axis; only the stacking one applies, since
                    // the cross axis holds a single track.
                    grid.SetRowSpacing(8.0)?;
                    core.columns.push(grid.clone());
                    NativeWidget::Column(grid)
                }
                WidgetKind::Row => {
                    let grid = Grid::new()?;
                    grid.SetColumnSpacing(8.0)?;
                    core.rows.push(grid.clone());
                    NativeWidget::Row(grid)
                }
                WidgetKind::Checkbox => {
                    // The box owns its checked bit; Checked/Unchecked
                    // report each flip with the box's identity tag.
                    // WinUI raises them for programmatic SetIsChecked
                    // too — the USER/programmatic split rides
                    // apply_quiet (see that field). The caption is the
                    // CheckBox's content, the same shape as Button.
                    let check = CheckBox::new()?;
                    let caption = TextBlock::new()?;
                    check.SetContent(&caption)?;
                    let tag = tag.expect("checkboxes carry a tag");
                    let on_sink = core.occurrences.clone();
                    let on_tag = tag.clone();
                    let on_quiet = core.apply_quiet.clone();
                    let checked = RoutedEventHandler::new(move |_, _| {
                        if !on_quiet.load(std::sync::atomic::Ordering::Relaxed) {
                            on_sink.send_toggle_tag(&on_tag, true);
                        }
                        Ok(())
                    });
                    check.Checked(&checked)?;
                    let off_sink = core.occurrences.clone();
                    let off_tag = tag.clone();
                    let off_quiet = core.apply_quiet.clone();
                    let unchecked = RoutedEventHandler::new(move |_, _| {
                        if !off_quiet.load(std::sync::atomic::Ordering::Relaxed) {
                            off_sink.send_toggle_tag(&off_tag, false);
                        }
                        Ok(())
                    });
                    check.Unchecked(&unchecked)?;
                    core.checkboxes.push(check.clone());
                    NativeWidget::Checkbox { check, caption }
                }
                WidgetKind::Slider => {
                    // Uncontrolled, like the entry: the slider owns its
                    // position; ValueChanged reports each move with its
                    // identity tag. (WinUI raises it for programmatic
                    // SetValue too, which is what lets the selftest
                    // drag like a user.)
                    let slider = Slider::new()?;
                    slider.SetMinimum(0.0)?;
                    slider.SetMaximum(1.0)?;
                    slider.SetStepFrequency(0.01)?;
                    slider.SetMinWidth(160.0)?;
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("sliders carry a tag");
                    let quiet = core.apply_quiet.clone();
                    let handler = bindings::Microsoft::UI::Xaml::Controls::Primitives::RangeBaseValueChangedEventHandler::new(
                        move |_, args: windows_core::Ref<'_, bindings::Microsoft::UI::Xaml::Controls::Primitives::RangeBaseValueChangedEventArgs>| {
                            if quiet.load(std::sync::atomic::Ordering::Relaxed) {
                                return Ok(());
                            }
                            if let Some(args) = args.as_ref() {
                                sink.send_value_tag(&tag, args.NewValue()?);
                            }
                            Ok(())
                        },
                    );
                    slider.ValueChanged(&handler)?;
                    core.sliders.push(slider.clone());
                    NativeWidget::Slider(slider)
                }
                WidgetKind::Button => {
                    let button = Button::new()?;
                    let caption = TextBlock::new()?;
                    button.SetContent(&caption)?;
                    let click_sink = core.occurrences.clone();
                    // The tag is the click's identity, emitted verbatim;
                    // this backend never learns what it means.
                    let tag = tag.expect("buttons carry a click tag");
                    core.buttons.push(tag.clone());
                    let handler = RoutedEventHandler::new(move |_, _| {
                        click_sink.send_click_tag(&tag);
                        Ok(())
                    });
                    button.Click(&handler)?;
                    NativeWidget::Button { button, caption }
                }
                WidgetKind::Label => {
                    let label = TextBlock::new()?;
                    core.labels.push(label.clone());
                    NativeWidget::Label(label)
                }
                WidgetKind::Scroll => {
                    // The vertical scroll viewport over its ONE child
                    // (the scene enforces the count): ScrollViewer,
                    // the platform's own machinery — ScrollableHeight
                    // and VerticalOffset are the observation sources
                    // and ChangeView the API scroll_end drives.
                    let viewer = ScrollViewer::new()?;
                    // Vertical-only v1: no horizontal scrolling, ever.
                    viewer.SetHorizontalScrollMode(ScrollMode::Disabled)?;
                    viewer.SetHorizontalScrollBarVisibility(ScrollBarVisibility::Disabled)?;
                    viewer.SetVerticalScrollMode(ScrollMode::Enabled)?;
                    core.scrolls.push(viewer.clone());
                    NativeWidget::Scroll(viewer)
                }
                WidgetKind::Progress => {
                    // Display-only, like Label: no tag, no handler.
                    // RangeBase's default span is 0..100; kaya's
                    // fraction contract is 0..=1, set explicitly.
                    let bar = ProgressBar::new()?;
                    bar.SetMinimum(0.0)?;
                    bar.SetMaximum(1.0)?;
                    core.progresses.push(bar.clone());
                    NativeWidget::Progress(bar)
                }
                WidgetKind::Textarea => {
                    // The multi-line editor: a TextBox with
                    // AcceptsReturn — the entry's exact contract,
                    // including the swallow counters (TextChanged is
                    // raised async; entry_swallow/entry_tags are
                    // id-keyed and kind-agnostic, so the plumbing is
                    // shared).
                    let field = TextBox::new()?;
                    field.SetAcceptsReturn(true)?;
                    field.SetMinWidth(240.0)?;
                    field.SetMinHeight(96.0)?;
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("textareas carry a tag");
                    let handler_tag = tag.clone();
                    let field_for_handler = field.clone();
                    let swallow =
                        std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
                    let handler_swallow = swallow.clone();
                    let handler = TextChangedEventHandler::new(move |_, _| {
                        if handler_swallow
                            .fetch_update(
                                std::sync::atomic::Ordering::Relaxed,
                                std::sync::atomic::Ordering::Relaxed,
                                |n| n.checked_sub(1),
                            )
                            .is_ok()
                        {
                            return Ok(());
                        }
                        let text = lf(field_for_handler.Text()?.to_string());
                        sink.send_text_tag(&handler_tag, &text);
                        Ok(())
                    });
                    field.TextChanged(&handler)?;
                    // Same focus-handoff refresh as the entry (paste
                    // enablement follows the focused editable).
                    let focus_handler = RoutedEventHandler::new(move |_, _| {
                        defer_role_refresh();
                        Ok(())
                    });
                    field.GotFocus(&focus_handler)?;
                    let blur_handler = RoutedEventHandler::new(move |_, _| {
                        defer_role_refresh();
                        Ok(())
                    });
                    field.LostFocus(&blur_handler)?;
                    core.textareas.push(field.clone());
                    core.textarea_ids.push(id.0);
                    core.entry_swallow.insert(id.0, swallow);
                    core.entry_tags.insert(id.0, tag);
                    NativeWidget::Textarea(field)
                }
                WidgetKind::Grid => {
                    // The 2D layout contract on WinUI's own Grid with
                    // Auto tracks: columns take their natural width,
                    // aligned across rows by the toolkit itself.
                    let grid = Grid::new()?;
                    core.grid_children.insert(id.0, Vec::new());
                    core.grid_cols.insert(id.0, 1);
                    core.grids.push(grid.clone());
                    NativeWidget::Grid2D(grid)
                }
                WidgetKind::Radio => {
                    // The choice contract inline: RadioButtons — the
                    // platform's own group control (string items
                    // render as radio rows). Same quiet-guard stance
                    // as the ComboBox: SelectionChanged cannot tell a
                    // user pick from SetSelectedIndex.
                    let group = RadioButtons::new()?;
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("radio groups carry a tag");
                    let quiet = core.apply_quiet.clone();
                    let handler = SelectionChangedEventHandler::new(
                        move |sender: windows_core::Ref<'_, windows_core::IInspectable>, _| {
                            if quiet.load(std::sync::atomic::Ordering::Relaxed) {
                                return Ok(());
                            }
                            if let Some(sender) = sender.as_ref() {
                                let group: RadioButtons =
                                    windows_core::Interface::cast(sender)?;
                                let index = group.SelectedIndex()?;
                                if index >= 0 {
                                    sink.send_value_tag(&tag, f64::from(index));
                                }
                            }
                            Ok(())
                        },
                    );
                    group.SelectionChanged(&handler)?;
                    core.radios.push(group.clone());
                    NativeWidget::Radio(group)
                }
                WidgetKind::Select => {
                    // The dressed floor: ComboBox — the select's
                    // label children are its OPTIONS, ComboBoxItems
                    // in the popup (see AddChild). Uncontrolled like
                    // the slider for USER picks; programmatic writes
                    // ride the quiet guard because SelectionChanged
                    // cannot tell the two apart.
                    let combo = ComboBox::new()?;
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("selects carry a tag");
                    let quiet = core.apply_quiet.clone();
                    let handler = SelectionChangedEventHandler::new(
                        move |sender: windows_core::Ref<'_, windows_core::IInspectable>, _| {
                            if quiet.load(std::sync::atomic::Ordering::Relaxed) {
                                return Ok(());
                            }
                            if let Some(sender) = sender.as_ref() {
                                let combo: ComboBox = windows_core::Interface::cast(sender)?;
                                let index = combo.SelectedIndex()?;
                                if index >= 0 {
                                    sink.send_value_tag(&tag, f64::from(index));
                                }
                            }
                            Ok(())
                        },
                    );
                    combo.SelectionChanged(&handler)?;
                    core.selects.push(combo.clone());
                    NativeWidget::Select(combo)
                }
                WidgetKind::Image => {
                    // Display-only, like Label: no tag, no handler. The
                    // source arrives as a SetProp blob and decodes
                    // there. Code-only construction, no XAML.
                    let image = Image::new()?;
                    core.images.push(image.clone());
                    NativeWidget::Image(image)
                }
            };
            core.widgets.insert(id, native);
        }
        ApplyOp::MoveChild {
            parent,
            child,
            before,
        } => {
            use bindings::Microsoft::UI::Xaml::UIElement;
            let panel = match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(panel) | NativeWidget::Row(panel) => panel.clone(),
                _ => panic!("kaya: move_child parent is not a container"),
            };
            let as_element = |core: &CoreState, id: WidgetId| -> UIElement {
                match core.widgets.get(&id).expect("scene validated the id") {
                    NativeWidget::Column(p) | NativeWidget::Row(p) => {
                        windows_core::Interface::cast(p).expect("panel is a UIElement")
                    }
                    NativeWidget::Button { button, .. } => {
                        windows_core::Interface::cast(button).expect("button is a UIElement")
                    }
                    NativeWidget::Label(label) => {
                        windows_core::Interface::cast(label).expect("label is a UIElement")
                    }
                    NativeWidget::Entry(field) => {
                        windows_core::Interface::cast(field).expect("entry is a UIElement")
                    }
                    NativeWidget::Checkbox { check, .. } => {
                        windows_core::Interface::cast(check).expect("checkbox is a UIElement")
                    }
                    NativeWidget::Slider(slider) => {
                        windows_core::Interface::cast(slider).expect("slider is a UIElement")
                    }
                    NativeWidget::Image(image) => {
                        windows_core::Interface::cast(image).expect("image is a UIElement")
                    }
                    NativeWidget::Scroll(viewer) => {
                        windows_core::Interface::cast(viewer).expect("scroll is a UIElement")
                    }
                    NativeWidget::Progress(bar) => {
                        windows_core::Interface::cast(bar).expect("progress is a UIElement")
                    }
                    NativeWidget::Select(combo) => {
                        windows_core::Interface::cast(combo).expect("select is a UIElement")
                    }
                    NativeWidget::Radio(group) => {
                        windows_core::Interface::cast(group).expect("radio is a UIElement")
                    }
                    NativeWidget::Grid2D(grid) => {
                        windows_core::Interface::cast(grid).expect("grid is a UIElement")
                    }
                    NativeWidget::Textarea(field) => {
                        windows_core::Interface::cast(field).expect("textarea is a UIElement")
                    }
                }
            };
            let children = panel.Children()?;
            let child_elem = as_element(core, child);
            let mut at = 0u32;
            if children.IndexOf(&child_elem, &mut at)?.into() {
                children.RemoveAt(at)?;
            }
            match before {
                Some(anchor) => {
                    let anchor_elem = as_element(core, anchor);
                    let mut idx = 0u32;
                    let found: bool = children.IndexOf(&anchor_elem, &mut idx)?.into();
                    assert!(found, "kaya: move_child anchor not among siblings");
                    children.InsertAt(idx, &child_elem)?;
                }
                None => children.Append(&child_elem)?,
            }
            // The Children collection is now in the new order, but on a
            // Grid that collection does not place anything — without the
            // restamp below the move would be invisible, which is
            // precisely what expect_order exists to catch.
            let order = core.child_order.entry(parent).or_default();
            order.retain(|&id| id != child);
            match before {
                Some(anchor) => {
                    let at = order
                        .iter()
                        .position(|&id| id == anchor)
                        .expect("kaya: move_child anchor not among siblings");
                    order.insert(at, child);
                }
                None => order.push(child),
            }
            reindex(core, parent)?;
        }
        ApplyOp::Destroy { id } => {
            // A destroyed anchor takes its context attachment with it
            // (menu ITEMS are never destroyed; the anchor map entries
            // are): a For-row removal must not leave the harness's
            // open-menu pointer dangling. The Stage's activation keeps
            // its own flyout handle through Closed (the staged
            // ruling), so dropping these is safe mid-activation.
            if core.context_roots.remove(&id.0).is_some() {
                core.context_nouns.remove(&id.0);
                core.context_flyouts.remove(&id.0);
                // The dead copy's native instances leave the map too
                // (GTK's Destroy arm parity: it retains item actions
                // against the removed attachment's instances). A
                // For-row removal forces no rebuild, and a detached
                // item still raises Click through its automation peer
                // — the menu probe proves it — so a surviving entry
                // would stay invoke-capable with the dead row's noun
                // until some unrelated menu mutation rebuilt the map.
                purge_context_natives(&mut core.menu_natives, id.0);
                if core.open_context.as_ref().is_some_and(|(w, _)| *w == id.0) {
                    core.open_context = None;
                }
            }
            let widget = core.widgets.remove(&id).expect("scene validated the id");
            core.grow.remove(&id);
            core.child_order.remove(&id);
            if let Some(panel) = core.parents.remove(&id) {
                let children = panel.Children()?;
                let mut index = 0u32;
                if children.IndexOf(&widget.element()?, &mut index)? {
                    children.RemoveAt(index)?;
                }
                // Find the parent by its grid, since only the grid was
                // stored; the surviving siblings all shift up a track.
                let parent = core
                    .child_order
                    .iter()
                    .find(|(_, order)| order.contains(&id))
                    .map(|(&parent, _)| parent);
                if let Some(parent) = parent {
                    core.child_order
                        .entry(parent)
                        .or_default()
                        .retain(|&child| child != id);
                    reindex(core, parent)?;
                }
            }
        }
        ApplyOp::SetWindowProp { window, prop, value } => {
            let target = winui_window(core, window.0)?;
            match (prop, &value) {
                (WindowProp::Title, Value::Str(title)) => {
                    // The window's OWN title; while a navigation entry
                    // covers it the entry's title shows, and this one
                    // comes back at pop.
                    core.window_titles.insert(window.0, title.clone());
                    let covered = core
                        .nav_stacks
                        .get(&window.0)
                        .is_some_and(|s| !s.is_empty());
                    if !covered {
                        target.SetTitle(&HSTRING::from(&**title))?;
                    }
                }
                (WindowProp::Width, Value::F64(v)) => {
                    resize_request(&target, Some(*v), None)?
                }
                (WindowProp::Height, Value::F64(v)) => {
                    resize_request(&target, None, Some(*v))?
                }
                (WindowProp::VetoClose, Value::Bool(on)) => {
                    core.window_veto.insert(window.0, *on);
                }
                (WindowProp::ListDetail, Value::Bool(on)) => {
                    core.list_detail.insert(window.0, *on);
                    refresh_nav(core, window.0)?;
                }
                (WindowProp::SectionsPresentation, Value::I64(hint)) => {
                    // ADVISORY: Left pane for auto/sidebar, Top for
                    // bar; rebuilt if the chrome already exists.
                    core.sections_presentation.insert(window.0, *hint);
                    if core.sections.contains_key(&window.0) {
                        refresh_sections(core, window.0)?;
                    }
                }
                (p, v) => unreachable!("scene validated window prop {p:?}/{v:?}"),
            }
        }
        ApplyOp::CreateWindow { window } => {
            // Materializes hidden (never Activated until a mount
            // presents it); the close grammar is installed at birth.
            let aux = Window::new()?;
            subclass(&aux, window.0)?;
            core.aux_windows.insert(window.0, aux);
        }
        ApplyOp::DestroyWindow { window } => {
            core.window_veto.remove(&window.0);
            core.tearing_down.insert(window.0);
            if let Some(aux) = core.aux_windows.remove(&window.0) {
                // Close() on an already-chrome-closed window errors;
                // the grammar makes destroy the reconciliation, so
                // tolerate it.
                let _ = aux.Close();
            }
            core.tearing_down.remove(&window.0);
            // A destroyed window takes its navigation stack with it.
            for entry in core.nav_stacks.remove(&window.0).unwrap_or_default() {
                core.nav_entries.remove(&entry);
            }
            // ... and its sections, each with ITS stack (the one way
            // a section dies).
            for sid in core.sections.remove(&window.0).unwrap_or_default() {
                core.section_panes.remove(&sid);
                core.section_items.remove(&sid);
                for entry in core.nav_stacks.remove(&sid).unwrap_or_default() {
                    core.nav_entries.remove(&entry);
                }
            }
            core.section_navs.remove(&window.0);
            core.section_swallow.remove(&window.0);
            core.ui_selected_sections.remove(&window.0);
            core.selected_sections.remove(&window.0);
            core.sections_presentation.remove(&window.0);
            core.window_roots.remove(&window.0);
            core.window_titles.remove(&window.0);
            // ... and its menu shell/catalog registration (the item
            // MODELS stay — items are never destroyed).
            core.menu_windows.remove(&window.0);
            core.menubars.remove(&window.0);
            core.menu_slots.remove(&window.0);
        }
        ApplyOp::PushEntry { window, entry } => {
            // Materializes covered/incoming: on the stack now, the
            // mount fills and presents it.
            core.nav_entries.insert(
                entry.0,
                WinNavEntry {
                    window: window.0,
                    title: String::new(),
                    intercept_back: false,
                    wrapper: None,
                    back_button: None,
                },
            );
            core.nav_stacks.entry(window.0).or_default().push(entry.0);
        }
        ApplyOp::PopEntry { window } => {
            let top = core
                .nav_stacks
                .get_mut(&window.0)
                .and_then(|s| s.pop())
                .expect("scene validated the pop");
            core.nav_entries.remove(&top);
            refresh_nav(core, window.0)?;
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
                refresh_nav(core, window)?;
            }
        }
        ApplyOp::AddSection { window, section } => {
            // Append-only: a pane joins the window's NavigationView;
            // the mount fills it. First added is selected (mirrored
            // from the core).
            let pane = Grid::new()?;
            core.section_panes.insert(
                section.0,
                WinSection {
                    window: window.0,
                    pane,
                    title: String::new(),
                    root: None,
                },
            );
            core.sections.entry(window.0).or_default().push(section.0);
            core.selected_sections.entry(window.0).or_insert(section.0);
            refresh_sections(core, window.0)?;
        }
        ApplyOp::SelectSection { window, section } => {
            // Programmatic and QUIET: the switcher moves under the
            // swallow counter (SelectionChanged raises ASYNC — the
            // echo doctrine, the entry_swallow spelling).
            core.selected_sections.insert(window.0, section.0);
            nav_set_selected(core, window.0, section.0)?;
            show_section_pane(core, window.0, section.0)?;
        }
        ApplyOp::SetSectionProp { section, prop, value } => {
            use crate::protocol::SectionProp;
            let record = core
                .section_panes
                .get_mut(&section.0)
                .expect("scene validated the section id");
            match (prop, &value) {
                (SectionProp::Title, Value::Str(title)) => {
                    record.title = title.clone();
                    if let Some(item) = core.section_items.get(&section.0) {
                        // String content, never a UIElement child —
                        // the ComboBox content-stealing trap.
                        item.SetContent(&PropertyValue::CreateString(&HSTRING::from(
                            &*record.title,
                        ))?)?;
                    }
                }
                // Day-one slot: accepted; the switcher TITLE is the
                // harness observable.
                (SectionProp::Icon, Value::Blob(_)) => {}
                (p, v) => unreachable!("scene validated section prop {p:?}/{v:?}"),
            }
        }
        // Menus: every arm mutates the retained model and defers the
        // chrome to ONE coalesced rebuild per drain (menus_touched) —
        // the rebuild starts from the post-user mirror by
        // construction (docs/traps.md).
        ApplyOp::MenuItemCreate { item, kind } => {
            core.menu_models.insert(
                item.0,
                MenuModel {
                    kind,
                    label: String::new(),
                    enabled: true,
                    checked: false,
                    value: 0.0,
                    primary: false,
                    role: String::new(),
                    shortcut: String::new(),
                    children: Vec::new(),
                    parent: None,
                },
            );
            core.menus_touched = true;
        }
        ApplyOp::MenuItemAppend { parent, child } => {
            core.menu_models
                .get_mut(&child.0)
                .expect("scene validated the child item")
                .parent = Some(parent.0);
            core.menu_models
                .get_mut(&parent.0)
                .expect("scene validated the parent item")
                .children
                .push(child.0);
            core.menus_touched = true;
        }
        ApplyOp::MenubarAppend { window, item } => {
            core.menu_windows.entry(window.0).or_default().push(item.0);
            ensure_menu_shell(core, window.0)?;
            core.menus_touched = true;
        }
        ApplyOp::ContextAttach { widget, item } => {
            core.context_roots.entry(widget.0).or_default().push(item.0);
            ensure_context_flyout(core, widget.0)?;
            core.menus_touched = true;
        }
        ApplyOp::ContextAttachNode { widget, item, path } => {
            core.context_roots.entry(widget.0).or_default().push(item.0);
            // The stamped copy's key path — the noun every activation
            // from this anchor carries (the on_click_node encoding).
            core.context_nouns.insert(widget.0, path);
            ensure_context_flyout(core, widget.0)?;
            core.menus_touched = true;
        }
        ApplyOp::SetMenuProp { item, prop, value } => {
            let model = core
                .menu_models
                .get_mut(&item.0)
                .expect("scene validated the item id");
            // EXHAUSTIVE over the prop: a new MENU_PROPS row fails to
            // compile here rather than reaching a catch-all at runtime
            // — which `role` did, panicking this backend (docs/traps.md).
            match prop {
                MenuProp::Label => model.label = crate::protocol::prop_str(&value).to_owned(),
                MenuProp::Enabled => model.enabled = crate::protocol::prop_bool(&value),
                // Programmatic checked/value writes are configuration
                // and stay QUIET (the echo doctrine): the rebuild
                // restamps the native state and no Click fires on a
                // programmatic set (the MENU PROBE's first canary).
                MenuProp::Checked => model.checked = crate::protocol::prop_bool(&value),
                MenuProp::Value => model.value = crate::protocol::prop_f64(&value),
                // The phone-promotion hint, INERT on desktop by the
                // ratified design — stored, never materialized here.
                MenuProp::Primary => model.primary = crate::protocol::prop_bool(&value),
                MenuProp::Shortcut => {
                    model.shortcut = crate::protocol::prop_str(&value).to_owned();
                }
                // Icons dress phone promotion; native Windows menu
                // rows carry no icon in this lowering (the section
                // Icon precedent: accepted, day-one slot).
                MenuProp::Icon => {}
                // PLACEMENT is a request this host has nowhere to
                // honor — no dress-owned application menu — so the
                // item stays exactly where the app declared it
                // (DESIGN.md, Menus). BEHAVIOR is not: a clipboard
                // role's activation performs the standard command on
                // the focused widget, and its enablement is the
                // offer/accepts intersection, so the role is recorded
                // and the role items resync now.
                MenuProp::Role => {
                    model.role = crate::protocol::prop_str(&value).to_owned();
                    refresh_clipboard_roles(core);
                }
            }
            core.menus_touched = true;
        }

        ApplyOp::Copy(clip) => {
            core.clipboard_armed = true;
            // Five formats in ONE open, descending clip value —
            // custom, files, image, html, text — the canonical order
            // (§1), which is preference (first-set) order on this
            // host. EmptyClipboard makes this process the owner;
            // classic SetClipboardData is immediate rendering, so the
            // content outlives the process with no Flush of any kind
            // (measured, tools/win/clipprobe).
            clip_open_retry()?;
            unsafe { windows::Win32::System::DataExchange::EmptyClipboard()? };
            let result: windows_core::Result<()> = (|| {
                for (id, bytes) in &clip.custom {
                    clip_set_bytes(clip_register(id), &bytes.0)?;
                }
                if !clip.files.is_empty() {
                    clip_set_bytes(CF_HDROP, &build_dropfiles(&clip.files))?;
                }
                if let Some(png) = &clip.image {
                    // Raw bytes under the "PNG" registered format —
                    // the Firefox/clip convention, byte-exact both
                    // ways (measured). CF_DIB is a deliberate cut: it
                    // would mean decoding the PNG here, and the
                    // closed set's image is ENCODED BYTES everywhere.
                    clip_set_bytes(clip_register("PNG"), &png.0)?;
                }
                if let Some(html) = &clip.html {
                    clip_set_bytes(clip_register("HTML Format"), &build_cf_html(html))?;
                }
                if let Some(text) = &clip.text {
                    clip_set_bytes(CF_UNICODETEXT, &clip_utf16z(text))?;
                }
                Ok(())
            })();
            unsafe { windows::Win32::System::DataExchange::CloseClipboard()? };
            result?;
            refresh_clipboard_roles(core);
        }
        ApplyOp::ReadClipboard { request, accepting } => {
            core.clipboard_armed = true;
            // Answered exactly once; None IS an answer — the
            // universal no (denied, absent, unfocused and
            // nothing-accepted alike). Win32 reads are synchronous
            // pulls, so no async bridge lives here.
            let clip = materialize_clipboard(&accepting)?;
            core.occurrences.send(Occurrence::ClipboardResult { request, clip });
        }
        ApplyOp::PresentFileDialog(spec) => {
            // The Shell's common item dialog, which is what Windows
            // means by a file picker.
            //
            // NOT FileOpenPicker, and the reason is the scene: its
            // SuggestedStartLocation is a PickerLocationId ENUM of
            // well-known folders, so it cannot be pointed at
            // <temp>/kaya-picked-<pid> at all. IFileOpenDialog::SetFolder
            // takes any shell item. DESIGN.md anticipated this shape —
            // "honorable on four platforms and not the fifth" — and it
            // decides the API rather than being worked around.
            //
            // ON ITS OWN STA THREAD, because Show() is modal and runs a
            // nested message loop. Blocking the UI thread inside apply
            // would stall the dispatcher for as long as the picker is
            // up, and this scene exists to prove the app stays alive
            // while a pick is outstanding. The owner HWND still makes it
            // modal to the user; only kaya's thread is spared.
            let target = winui_window(core, spec.window.0);
            let hwnd = target
                .ok()
                .and_then(|t| windows_core::Interface::cast::<IWindowNative>(&t).ok())
                .and_then(|n| n.window_handle().ok())
                .unwrap_or(0);
            let dir = core.pending_dialog_dir.borrow_mut().take();
            let multiple = spec.multiple;
            let filters = spec.filters.clone();
            let dialog_id = spec.dialog.0;
            let sink = core.occurrences.clone();
            std::thread::Builder::new()
                .name("kaya-file-dialog".into())
                .spawn(move || {
                    let files = file_dialog_show(hwnd, multiple, &filters, dir.as_deref());
                    let picked = files
                        .into_iter()
                        .map(|(name, path)| {
                            let handle = crate::capi::picked_register(std::sync::Arc::new(
                                crate::protocol::PathSource {
                                    name: name.clone(),
                                    path: path.clone(),
                                },
                            ));
                            crate::protocol::PickedFile {
                                handle,
                                name,
                                local_path: path,
                            }
                        })
                        .collect::<Vec<_>>();
                    // Cancel is the EMPTY LIST, faithfully: Show()
                    // returns ERROR_CANCELLED and no platform can
                    // confirm an empty selection, so there is no
                    // sentinel to invent (DESIGN.md, File dialogs).
                    crate::capi::file_dialog_retire(dialog_id);
                    sink.send(Occurrence::FileDialogResult {
                        dialog: crate::protocol::FileDialogId(dialog_id),
                        files: picked,
                    });
                })
                .expect("failed to spawn the file dialog thread");
        }
        ApplyOp::PresentAlert(spec) => {
            // The platform's REAL modal dialog: ContentDialog's three
            // slots ARE the vocabulary (two actions + close). The
            // ShowAsync completion is the ONE emit site — Primary/
            // Secondary map to action indices, everything else
            // (Esc, the close button, Hide) completes as None = the
            // cancel slot — routed through capi::alert_resolved, the
            // shared retire path.
            let host = if spec.window.0 == 0 {
                core.window.clone()
            } else {
                core.aux_windows
                    .get(&spec.window.0)
                    .expect("scene validated the alert's window")
                    .clone()
            };
            // A dialog needs the host's LIVE XamlRoot, and a guest
            // can request one within milliseconds of launch — before
            // the content island exists (caught live 2026-07-22 the
            // moment the settles stopped hiding it: the expect
            // aborted the UI thread). Not ready yet: re-enqueue this
            // whole present on the dispatcher and let the queue load
            // the content first; the harness's expect_alert retries
            // until the dialog is really up.
            let root_live = host
                .Content()
                .and_then(|c| {
                    let root: FrameworkElement = windows_core::Interface::cast(&c)?;
                    root.XamlRoot()
                })
                .is_ok();
            if !root_live {
                // Re-present when the root actually loads — its
                // Loaded event is the platform's own "the island is
                // up" signal. (A dispatcher self-re-enqueue loop
                // STARVES the queue that would do the loading; a
                // timer is a guess. This is backend-internal — the
                // harness's uniform mechanism stays bounded polling.)
                let root: FrameworkElement = windows_core::Interface::cast(&host.Content()?)?;
                let cell = std::sync::Mutex::new(Some(spec));
                let handler = RoutedEventHandler::new(move |_, _| {
                    if let Some(spec) = cell.lock().unwrap().take() {
                        CORE.with_borrow_mut(|core| {
                            let core = core.as_mut().expect("core state initialized");
                            let _ = apply(core, ApplyOp::PresentAlert(spec));
                        });
                    }
                    Ok(())
                });
                root.Loaded(&handler)?;
                return Ok(());
            }
            let dialog = ContentDialog::new().expect("ContentDialog::new");
            let title = PropertyValue::CreateString(&HSTRING::from(spec.title.as_str()))
                .expect("title box");
            dialog.SetTitle(&title).expect("SetTitle");
            let message = PropertyValue::CreateString(&HSTRING::from(spec.message.as_str()))
                .expect("message box");
            dialog.SetContent(&message).expect("SetContent");
            if let Some(a0) = spec.actions.first() {
                dialog
                    .SetPrimaryButtonText(&HSTRING::from(a0.as_str()))
                    .expect("SetPrimaryButtonText");
            }
            if let Some(a1) = spec.actions.get(1) {
                dialog
                    .SetSecondaryButtonText(&HSTRING::from(a1.as_str()))
                    .expect("SetSecondaryButtonText");
            }
            dialog
                .SetCloseButtonText(&HSTRING::from(spec.cancel.as_str()))
                .expect("SetCloseButtonText");
            dialog
                .SetDefaultButton(if spec.actions.is_empty() {
                    ContentDialogButton::Close
                } else {
                    ContentDialogButton::Primary
                })
                .expect("SetDefaultButton");
            let xaml_root = host
                .Content()
                .expect("host content")
                .XamlRoot()
                .expect("host XamlRoot");
            dialog.SetXamlRoot(&xaml_root).expect("SetXamlRoot");
            let alert_id = spec.alert.0;
            core.live_alert = Some(WinLiveAlert {
                window: spec.window.0,
                actions: spec.actions.len(),
                dialog: dialog.clone(),
            });
            let op = dialog.ShowAsync().expect("ShowAsync");
            op.SetCompleted(&windows_future::AsyncOperationCompletedHandler::new(
                move |op: windows_core::Ref<'_, windows_future::IAsyncOperation<ContentDialogResult>>,
                      _status| {
                    let result = op.ok()?.GetResults()?;
                    let choice = match result {
                        ContentDialogResult::Primary => crate::protocol::AlertChoice::Action(0),
                        ContentDialogResult::Secondary => crate::protocol::AlertChoice::Action(1),
                        _ => crate::protocol::AlertChoice::Cancel,
                    };
                    // The result must ride THIS backend's sink (the
                    // guest listens there); capi::alert_retire is
                    // only the liveness gate.
                    let sink = CORE.with(|core| {
                        let mut core = core.borrow_mut();
                        let core = core.as_mut().expect("core lives while a dialog shows");
                        core.live_alert = None;
                        core.occurrences.clone()
                    });
                    crate::capi::alert_retire(alert_id);
                    sink.send(Occurrence::AlertResult {
                        alert: crate::protocol::AlertId(alert_id),
                        choice,
                    });
                    Ok(())
                },
            ))
            .expect("SetCompleted");
        }
        ApplyOp::SetProp { id, prop, value } => {
            // Grow is handled ahead of the per-kind table: it is the one
            // kind-agnostic prop, and its effect lands on the parent's
            // track definitions rather than on the widget itself.
            if let (Prop::Grow, Value::F64(weight)) = (prop, &value) {
                debug_assert!(core.widgets.contains_key(&id), "scene validated the id");
                core.grow.insert(id, *weight);
                let parent = core
                    .child_order
                    .iter()
                    .find(|(_, order)| order.contains(&id))
                    .map(|(&parent, _)| parent);
                if let Some(parent) = parent {
                    reindex(core, parent)?;
                }
                return Ok(());
            }
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match (widget, prop, value) {
                (NativeWidget::Button { caption, .. }, Prop::Text, Value::Str(s)) => {
                    caption.SetText(&HSTRING::from(&s))?;
                }
                (NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {
                    label.SetText(&HSTRING::from(&s))?;
                    // An option label's text lands on its ComboBox
                    // row too, as string content (see select_options
                    // for why never a TextBlock) — or its radio row.
                    if let Some((_, item)) = core.select_options.get(&id.0) {
                        item.SetContent(&PropertyValue::CreateString(&HSTRING::from(&s))?)?;
                    }
                    if let Some((group, row)) = core.radio_options.get(&id.0) {
                        group
                            .Items()?
                            .SetAt(*row, &PropertyValue::CreateString(&HSTRING::from(&s))?)?;
                    }
                }
                (NativeWidget::Entry(field), Prop::Text, Value::Str(s))
                | (NativeWidget::Textarea(field), Prop::Text, Value::Str(s)) => {
                    // Quiet: a property write is configuration, not a
                    // user edit — and TextChanged is raised async, so
                    // the flag is a counter (see entry_swallow).
                    if lf(field.Text()?.to_string()) != s {
                        if let Some(swallow) = core.entry_swallow.get(&id.0) {
                            swallow.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        }
                        field.SetText(&HSTRING::from(&s))?;
                    }
                }
                (NativeWidget::Checkbox { caption, .. }, Prop::Text, Value::Str(s)) => {
                    caption.SetText(&HSTRING::from(&s))?;
                }
                (NativeWidget::Checkbox { check, .. }, Prop::Checked, Value::Bool(b)) => {
                    let boxed: IReference<bool> = PropertyValue::CreateBoolean(b)?.cast()?;
                    core.apply_quiet
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                    let write = check.SetIsChecked(&boxed);
                    core.apply_quiet
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    write?;
                }
                (NativeWidget::Slider(slider), Prop::Value, Value::F64(v)) => {
                    core.apply_quiet
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                    let write = slider.SetValue(v);
                    core.apply_quiet
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    write?;
                }
                (NativeWidget::Select(combo), Prop::Value, Value::F64(v)) => {
                    // A programmatic write is quiet (uniform
                    // semantics: only the user path emits).
                    core.apply_quiet
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                    let write = combo.SetSelectedIndex(v as i32);
                    core.apply_quiet
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    write?;
                }
                // THE UNIVERSAL PROPS. Every other arm keys on a
                // (kind, prop) pair; these name something every element
                // has, so they match the prop alone.
                //
                // AutomationProperties is UIA's setter side: AutomationId
                // is the automation identifier (never spoken) and Name is
                // what a screen reader says. Unlike GTK, WinUI publishes a
                // settable identifier, so the harness read below matches
                // by identity rather than by ordinal.
                (w, Prop::A11yId, Value::Str(id)) => {
                    let element = w.element()?;
                    bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(
                        &element,
                        &windows_core::HSTRING::from(id.as_str()),
                    )?;
                }
                // Empty means unset, and unset stays untouched: UIA
                // derives a control's name from its content, and writing
                // "" would SILENCE it.
                (w, Prop::A11yLabel, Value::Str(label)) if !label.is_empty() => {
                    let element = w.element()?;
                    bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(
                        &element,
                        &windows_core::HSTRING::from(label.as_str()),
                    )?;
                }
                // The HINT: UIA's HelpText, the slot for what acting on
                // the control does. Empty means unset, like the name.
                (w, Prop::A11yHint, Value::Str(hint)) if !hint.is_empty() => {
                    let element = w.element()?;
                    bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetHelpText(
                        &element,
                        &windows_core::HSTRING::from(hint.as_str()),
                    )?;
                }
                // ACCEPTANCE IS PER-WIDGET (DESIGN.md, Clipboard):
                // the list drives the paste split and Paste's
                // enablement. Kind-agnostic like the universal props
                // — the root already restricted it to editables and
                // validated the string. Empty means unset, the
                // universal prop rule.
                (_, Prop::Accepts, Value::Str(list)) => {
                    if list.is_empty() {
                        core.accepts.remove(&id.0);
                    } else {
                        core.accepts.insert(id.0, list);
                    }
                    core.clipboard_armed = true;
                    refresh_clipboard_roles(core);
                }
                (NativeWidget::Grid2D(_), Prop::Columns, Value::F64(cols)) => {
                    core.grid_cols.insert(id.0, cols as i32);
                    reflow_grid(core, id.0)?;
                }
                (NativeWidget::Grid2D(grid), Prop::Spacing, Value::F64(gap)) => {
                    grid.SetRowSpacing(gap)?;
                    grid.SetColumnSpacing(gap)?;
                }
                (NativeWidget::Radio(group), Prop::Value, Value::F64(v)) => {
                    core.apply_quiet
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                    let write = group.SetSelectedIndex(v as i32);
                    core.apply_quiet
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    write?;
                }
                (NativeWidget::Progress(bar), Prop::Value, Value::F64(v)) => {
                    bar.SetValue(v)?;
                }
                (NativeWidget::Progress(bar), Prop::Indeterminate, Value::Bool(on)) => {
                    bar.SetIsIndeterminate(on)?;
                }
                (NativeWidget::Column(grid), Prop::Spacing, Value::F64(gap)) => {
                    // A column's children stack as rows; the gap is the
                    // row spacing (expect_fills reads it back live).
                    grid.SetRowSpacing(gap)?;
                }
                (NativeWidget::Column(_), Prop::Align, Value::I64(mode))
                | (NativeWidget::Row(_), Prop::Align, Value::I64(mode)) => {
                    core.aligns.insert(id, mode);
                    reindex(core, id)?;
                }
                (NativeWidget::Row(grid), Prop::Spacing, Value::F64(gap)) => {
                    grid.SetColumnSpacing(gap)?;
                }
                (NativeWidget::Slider(slider), Prop::Min, Value::F64(v)) => {
                    slider.SetMinimum(v)?;
                }
                (NativeWidget::Slider(slider), Prop::Max, Value::F64(v)) => {
                    slider.SetMaximum(v)?;
                }
                (NativeWidget::Image(image), Prop::Source, Value::Blob(blob)) => {
                    // Encoded bytes in, native decode: the bytes go
                    // through an InMemoryRandomAccessStream (via
                    // DataWriter) into a BitmapImage. SetSource is the
                    // synchronously-callable path on the UI thread;
                    // the one async hop is DataWriter.StoreAsync,
                    // blocked on .join() — an in-memory store completes
                    // promptly, but this friction is why runtime
                    // verification happens on the VM. Any failure
                    // (decode included) leaves the placeholder — no
                    // Source, image_size reads 0x0 — never a panic.
                    let result: windows_core::Result<()> = (|| {
                        let stream = InMemoryRandomAccessStream::new()?;
                        let writer = DataWriter::CreateDataWriter(&stream)?;
                        writer.WriteBytes(&blob.0)?;
                        writer.StoreAsync()?.join()?;
                        writer.DetachStream()?;
                        stream.Seek(0)?;
                        let source = BitmapImage::new()?;
                        source.SetSource(&stream)?;
                        image.SetSource(&source)?;
                        Ok(())
                    })();
                    if let Err(e) = result {
                        eprintln!(
                            "kaya: winui image source rejected (placeholder): {}",
                            e.message()
                        );
                    }
                }
                (_, prop, value) => {
                    panic!("kaya: winui cannot apply {prop:?} = {value:?} here")
                }
            }
        }
        ApplyOp::AddChild { parent, child } => {
            // The viewport's one child (the scene rejects a second):
            // ScrollViewer is a ContentControl, not a panel.
            if let NativeWidget::Scroll(viewer) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let viewer = viewer.clone();
                let element = core
                    .widgets
                    .get(&child)
                    .expect("scene validated the id")
                    .element()?;
                viewer.SetContent(&element)?;
                return Ok(());
            }
            if let NativeWidget::Grid2D(_) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let element = core
                    .widgets
                    .get(&child)
                    .expect("scene validated the id")
                    .element()?;
                core.grid_children
                    .get_mut(&parent.0)
                    .expect("grid created")
                    .push(element);
                reflow_grid(core, parent.0)?;
                return Ok(());
            }
            // A radio's label children are its OPTIONS: string rows
            // of the group's Items vector (strings render as radio
            // rows; the label's SetProp text lands with SetAt), and
            // the label leaves the harness's label registry.
            if let NativeWidget::Radio(group) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let group = group.clone();
                let items = group.Items()?;
                let row = items.Size()?;
                if let NativeWidget::Label(label) =
                    core.widgets.get(&child).expect("scene validated the id")
                {
                    items.Append(&PropertyValue::CreateString(&label.Text()?)?)?;
                    let label = label.clone();
                    core.labels.retain(|x| x != &label);
                } else {
                    items.Append(&PropertyValue::CreateString(&HSTRING::new())?)?;
                }
                core.radio_options.insert(child.0, (group, row));
                return Ok(());
            }
            // A select's label children are its OPTIONS: ComboBoxItems
            // in the popup, never children of a panel. The row gets
            // its own TextBlock (the label's SetProp text lands on
            // both), the label's native TextBlock stays unparented,
            // and the label leaves the harness's label registry —
            // options are the select's data, so they must not shift
            // every later label's index.
            if let NativeWidget::Select(combo) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let combo = combo.clone();
                let item = ComboBoxItem::new()?;
                if let NativeWidget::Label(label) =
                    core.widgets.get(&child).expect("scene validated the id")
                {
                    // The row initializes from the label's CURRENT
                    // text: children-first sugars (OCaml, Haskell)
                    // set the text BEFORE this AddChild (the GTK
                    // empty-row lesson); SetProp covers later writes.
                    item.SetContent(&PropertyValue::CreateString(&label.Text()?)?)?;
                    let label = label.clone();
                    core.labels.retain(|x| x != &label);
                }
                combo.Items()?.Append(&item)?;
                core.select_options.insert(child.0, (combo, item));
                return Ok(());
            }
            let panel = match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(panel) | NativeWidget::Row(panel) => panel.clone(),
                _ => panic!("kaya: add_child parent is not a container"),
            };
            let children = panel.Children()?;
            match core.widgets.get(&child).expect("scene validated the id") {
                NativeWidget::Column(p) | NativeWidget::Row(p) => children.Append(p)?,
                NativeWidget::Button { button, .. } => children.Append(button)?,
                NativeWidget::Label(label) => children.Append(label)?,
                NativeWidget::Entry(field) => children.Append(field)?,
                NativeWidget::Checkbox { check, .. } => children.Append(check)?,
                NativeWidget::Slider(slider) => children.Append(slider)?,
                NativeWidget::Image(image) => children.Append(image)?,
                NativeWidget::Scroll(viewer) => children.Append(viewer)?,
                NativeWidget::Progress(bar) => children.Append(bar)?,
                NativeWidget::Select(combo) => children.Append(combo)?,
                NativeWidget::Radio(group) => children.Append(group)?,
                NativeWidget::Grid2D(grid) => children.Append(grid)?,
                NativeWidget::Textarea(field) => children.Append(field)?,
            }
            core.parents.insert(child, panel);
            core.child_order.entry(parent).or_default().push(child);
            // A new child means a new track and a shifted set of indices.
            reindex(core, parent)?;
        }
        ApplyOp::Mount { window, root } => {
            let widget = core.widgets.get(&root).expect("scene validated the id");
            if let NativeWidget::Column(panel) | NativeWidget::Row(panel) = widget {
                // The normalized root inset: 16 units INSIDE the
                // root (Grid.Padding is inside ActualSize, so the
                // root still fills its island and
                // expect_root_fills holds).
                panel.SetPadding(Thickness {
                    Left: 16.0,
                    Top: 16.0,
                    Right: 16.0,
                    Bottom: 16.0,
                })?;
                // Baseline compensation needs REAL text metrics,
                // and at apply time the grid has never had a true
                // layout pass (a detached or just-attached measure
                // reads zeros — margins came out ~0 and the row
                // classified start on the first two Windows runs).
                // Loaded fires after the first real layout; the
                // one-shot re-runs reindex for every
                // baseline-aligned container with live metrics.
                let loaded = RoutedEventHandler::new(move |_, _| {
                    CORE.with_borrow(|core| {
                        let Some(core) = core.as_ref() else {
                            return Ok(());
                        };
                        let ids: Vec<WidgetId> = core
                            .aligns
                            .iter()
                            .filter(|&(_, &m)| m == 4)
                            .map(|(&id, _)| id)
                            .collect();
                        for id in ids {
                            reindex(core, id)?;
                        }
                        Ok(())
                    })
                });
                panel.Loaded(&loaded)?;
            }
            // The target is a SURFACE: a navigation entry presents
            // in-window (the push already stacked it; the mount fills
            // it), the primary is the window's own root, an auxiliary
            // presents its window.
            let element = widget.element()?;
            if core.section_panes.contains_key(&window.0) {
                // A section presents in-window: added to the set
                // already; the mount fills its pane.
                core.section_panes.get_mut(&window.0).unwrap().root =
                    Some(element);
                refresh_section_pane(core, window.0)?;
            } else if core.nav_entries.contains_key(&window.0) {
                mount_entry(core, window.0, element)?;
            } else if window.0 == 0 {
                let element = nav_probe_wrap(&element)?;
                set_window_content(core, 0, &element)?;
                core.window_roots.insert(0, element);
            } else {
                set_window_content(core, window.0, &element)?;
                // Mounting presents.
                winui_window(core, window.0)?.Activate()?;
                core.window_roots.insert(window.0, element);
            }
        }
        ApplyOp::Command { id, command } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match command {
                CommandKind::Clear => {
                    let field = match widget {
                        NativeWidget::Entry(field) | NativeWidget::Textarea(field) => field,
                        _ => panic!("kaya: clear on a non-text widget (scene validates kinds)"),
                    };
                    // A command ACTS LIKE THE USER, and its echo must
                    // stay ORDERED with what follows — TextChanged is
                    // raised async, so the echo is emitted here
                    // synchronously and the late raise is swallowed
                    // (see entry_swallow).
                    if !field.Text()?.to_string().is_empty() {
                        if let Some(swallow) = core.entry_swallow.get(&id.0) {
                            swallow.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        }
                        field.SetText(&HSTRING::new())?;
                        if let Some(tag) = core.entry_tags.get(&id.0) {
                            core.occurrences.send_text_tag(tag, "");
                        }
                    }
                }
                CommandKind::Focus => {
                    // The materialization class (see traps.md): an
                    // element not yet in the live tree cannot take
                    // focus, and the call's bool would be discarded —
                    // a mount-tx focus would silently drop. Not
                    // loaded yet: one-shot re-run from the element's
                    // own Loaded, the alert/baseline pattern.
                    let element = widget.element()?;
                    let fe: FrameworkElement = windows_core::Interface::cast(&element)?;
                    if fe.IsLoaded()? {
                        let _ = element.Focus(FocusState::Programmatic)?;
                    } else {
                        // One-shot (the alert pattern): Loaded
                        // re-fires on every re-attach, and a stale
                        // handler must not steal focus later.
                        let armed = std::sync::Mutex::new(true);
                        let deferred = RoutedEventHandler::new(
                            move |sender: windows_core::Ref<'_, windows_core::IInspectable>, _| {
                                if !std::mem::take(&mut *armed.lock().unwrap()) {
                                    return Ok(());
                                }
                                if let Some(sender) = sender.as_ref() {
                                    let element: UIElement =
                                        windows_core::Interface::cast(sender)?;
                                    let _ = element.Focus(FocusState::Programmatic)?;
                                }
                                Ok(())
                            },
                        );
                        fe.Loaded(&deferred)?;
                    }
                }
            }
        }
    }
    Ok(())
}

// --- Windows App Runtime bootstrap (unpackaged apps) ---------------------
//
// The bootstrap DLL ships next to the executable; it locates the installed
// Windows App Runtime and wires it into the process. Loaded dynamically so
// kaya needs no import lib from the NuGet package.

const WASDK_MAJOR_MINOR: u32 = 0x0002_0002; // 2.2
const MDD_ON_NO_MATCH_SHOW_UI: i32 = 0x8;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn LoadLibraryW(name: *const u16) -> *mut c_void;
    fn GetProcAddress(module: *mut c_void, name: *const u8) -> *mut c_void;
    /// This module's own base, for the sampler window's class.
    #[cfg(feature = "harness")]
    fn GetModuleHandleW(name: *const u16) -> isize;
}

#[link(name = "ole32")]
unsafe extern "system" {
    fn CoInitializeEx(reserved: *const c_void, coinit: u32) -> i32;
}

type MddBootstrapInitialize2 =
    unsafe extern "system" fn(u32, *const u16, u64, i32) -> i32;
type MddBootstrapShutdown = unsafe extern "system" fn();

static BOOTSTRAP_SHUTDOWN: OnceLock<usize> = OnceLock::new();

fn bootstrap_shutdown() {
    if let Some(&addr) = BOOTSTRAP_SHUTDOWN.get() {
        let shutdown: MddBootstrapShutdown = unsafe { std::mem::transmute(addr) };
        unsafe { shutdown() };
    }
}

fn bootstrap_windows_app_runtime() {
    // TODO: resolve the bootstrap DLL relative to kaya's own module path
    // (GetModuleHandleExW with FROM_ADDRESS) instead of the default search
    // order, so foreign hosts (python.exe) need not have kaya's directory
    // on PATH.
    let dll: Vec<u16> = "Microsoft.WindowsAppRuntime.Bootstrap.dll\0"
        .encode_utf16()
        .collect();
    let module = unsafe { LoadLibraryW(dll.as_ptr()) };
    assert!(
        !module.is_null(),
        "Microsoft.WindowsAppRuntime.Bootstrap.dll not found next to the executable"
    );
    let proc = unsafe { GetProcAddress(module, c"MddBootstrapInitialize2".as_ptr().cast()) };
    assert!(!proc.is_null(), "MddBootstrapInitialize2 not exported");
    let init: MddBootstrapInitialize2 = unsafe { std::mem::transmute(proc) };
    let version_tag: Vec<u16> = "\0".encode_utf16().collect();
    let hr = unsafe { init(WASDK_MAJOR_MINOR, version_tag.as_ptr(), 0, MDD_ON_NO_MATCH_SHOW_UI) };
    assert!(
        hr >= 0,
        "MddBootstrapInitialize2 failed: 0x{hr:08x} (is the Windows App Runtime installed?)"
    );

    let shutdown = unsafe { GetProcAddress(module, c"MddBootstrapShutdown".as_ptr().cast()) };
    if !shutdown.is_null() {
        let _ = BOOTSTRAP_SHUTDOWN.set(shutdown as usize);
    }
}

// --- Core ----------------------------------------------------------------

/// The UI-thread half, independent of who owns the app thread. Returns
/// the exit code; the host process decides how to exit (a library must
/// not tear down someone else's process).
pub(crate) fn run_core(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> i32 {
    bootstrap_windows_app_runtime();

    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    unsafe { CoInitializeEx(std::ptr::null(), COINIT_APARTMENTTHREADED) };

    // Application::Start creates the XAML UI thread machinery and calls
    // back once it is ready; the callback runs on the UI thread. Building
    // the core is deferred through the dispatcher so it runs after the
    // launch sequence completes.
    let callback = ApplicationInitializationCallback::new(move |_params| {
        // XAML forwards render-loop errors to CoreApplication; with no
        // handler there, RoReportUnhandledError fail-fasts the process
        // (0xC000027B) — a channel Application.UnhandledException never
        // sees. This app has one known, survivable error on that
        // channel: deferred theme XAML (the built-in TextBox style)
        // cannot instantiate without an IXamlMetadataProvider, which a
        // code-only Application does not have. Propagate() rethrows the
        // stowed HRESULT here, marking it observed; we log it and the
        // control proceeds with its local (minimal) style.
        let on_core_error = bindings::Windows::Foundation::EventHandler::new(
            |_,
             args: windows_core::Ref<
                '_,
                bindings::Windows::ApplicationModel::Core::UnhandledErrorDetectedEventArgs,
            >| {
                if let Some(args) = args.as_ref() {
                    if let Ok(error) = args.UnhandledError() {
                        match error.Propagate() {
                            Ok(()) => {}
                            Err(e) => eprintln!(
                                "kaya: winui unhandled core error (continuing): {}",
                                e.message()
                            ),
                        }
                    }
                }
                Ok(())
            },
        );
        // The statics interface is activated by hand: pulling in the
        // CoreApplication class itself drags members whose types the
        // standalone windows-* crates do not carry.
        struct CoreApplicationMarker;
        impl windows_core::RuntimeName for CoreApplicationMarker {
            const NAME: &'static str = "Windows.ApplicationModel.Core.CoreApplication";
        }
        let unhandled: bindings::Windows::ApplicationModel::Core::ICoreApplicationUnhandledError =
            windows_core::factory::<CoreApplicationMarker, _>()?;
        unhandled.UnhandledErrorDetected(&on_core_error)?;
        let app = compose_application()?;
        APP.with_borrow_mut(|slot| *slot = Some(app));
        // The aggregation contract, asserted where it can fail loudly:
        // Application.Current() is an identity QI for IApplication
        // through the OUTER — if the outer ever stops delegating
        // unknown IIDs to the inner, every control that consults
        // Current at runtime (NavigationView's ResourceAccessor was
        // the first found) stow-crashes minutes later with a bare
        // E_NOINTERFACE instead of failing here, at the source
        // (docs/traps.md, the aggregation trap).
        bindings::Microsoft::UI::Xaml::Application::Current().expect(
            "kaya: Application.Current() failed — the aggregation outer \
             is not delegating QI to the inner (see KayaOuter)",
        );
        // Stowed exceptions (0xC000027B) die silently; print what XAML
        // actually complained about before the process goes down. A
        // permanent diagnostic, not scaffolding.
        let on_unhandled = UnhandledExceptionEventHandler::new(|_, args| {
            if let Some(args) = args.as_ref() {
                eprintln!(
                    "kaya: winui unhandled exception (continuing): {}",
                    args.Message().unwrap_or_default()
                );
                // Keep the process alive: backends are appliers, and
                // the exceptions seen here in practice are resource
                // lookups for control chrome (flyouts) that unpackaged
                // apps resolve imperfectly. Logged, never silent.
                args.SetHandled(true)?;
            }
            Ok(())
        });
        APP.with_borrow(|app| {
            app.as_ref()
                .expect("composed just above")
                .UnhandledException(&on_unhandled)
        })?;
        let dispatcher = DispatcherQueue::GetForCurrentThread()?;
        let occ_tx = occ_tx.clone();
        let tx_rx_cell = RefCell::new(Some(tx_rx_take()));
        let build = DispatcherQueueHandler::new(move || {
            let tx_rx = tx_rx_cell
                .borrow_mut()
                .take()
                .expect("core set up once");
            setup(occ_tx.clone(), tx_rx)
        });
        dispatcher.TryEnqueue(&build)?;
        DISPATCHER
            .set(SharedDispatcher(dispatcher))
            .map_err(|_| ())
            .expect("run_core called once");
        Ok(())
    });

    // Application::Start's callback cannot capture tx_rx directly because
    // the callback type requires Fn semantics; park it in a static slot.
    tx_rx_put(tx_rx);

    Application::Start(&callback).expect("Application::Start failed");

    // Start has returned; XAML has torn down its apartment. Rust TLS
    // destructors still run during process::exit on Windows (TLS
    // callbacks), and releasing XAML COM objects into the dead apartment
    // is an access violation. Announce shutdown, then leak the COM
    // references; the process reclaims everything anyway.
    CORE.with_borrow_mut(|core| {
        if let Some(core) = core.take() {
            core.occurrences.send(Occurrence::Shutdown);
            std::mem::forget(core);
        }
    });
    // Unwind the App Runtime while the process is still healthy; leaving
    // it for DLL_PROCESS_DETACH crashes inside Microsoft.UI.Xaml.dll in
    // hosted processes (observed with python.exe).
    bootstrap_shutdown();
    EXIT_CODE.load(std::sync::atomic::Ordering::Relaxed)
}

// Receiver<Transaction> is !Sync, and the WinRT callback signature forces
// the closure to be Fn + Send. The receiver crosses into the UI thread
// through this slot instead of the closure environment.
static TX_RX_SLOT: std::sync::Mutex<Option<Receiver<Transaction>>> = std::sync::Mutex::new(None);

fn tx_rx_put(rx: Receiver<Transaction>) {
    *TX_RX_SLOT.lock().unwrap() = Some(rx);
}

fn tx_rx_take() -> Receiver<Transaction> {
    TX_RX_SLOT
        .lock()
        .unwrap()
        .take()
        .expect("transaction receiver already taken")
}

// WinUI 3's interop interface for reaching a Window's HWND
// (IWindowNative, one method past IUnknown). The generated bindings
// do not project AppWindow, and Win32 placement via the HWND is all
// recording mode needs.
windows_core::imp::define_interface!(
    IWindowNative,
    IWindowNative_Vtbl,
    0xeecdbf0e_bae9_4cb6_a68e_9598e1cb57bb
);
windows_core::imp::interface_hierarchy!(IWindowNative, windows_core::IUnknown);
#[repr(C)]
#[doc(hidden)]
pub struct IWindowNative_Vtbl {
    pub base__: windows_core::IUnknown_Vtbl,
    pub WindowHandle:
        unsafe extern "system" fn(*mut core::ffi::c_void, *mut isize) -> windows_core::HRESULT,
}
impl IWindowNative {
    fn window_handle(&self) -> windows_core::Result<isize> {
        unsafe {
            let mut hwnd = 0isize;
            (windows_core::Interface::vtable(self).WindowHandle)(
                windows_core::Interface::as_raw(self),
                &mut hwnd,
            )
            .ok()?;
            Ok(hwnd)
        }
    }
}

const WM_CLOSE: u32 = 0x0010;
const WM_CLIPBOARDUPDATE: u32 = 0x031D;
const GWLP_WNDPROC: i32 = -4;

thread_local! {
    /// hwnd -> (kaya window id, the original WNDPROC). UI thread only,
    /// like CORE.
    static KAYA_WNDPROCS: RefCell<HashMap<isize, (u64, isize)>> =
        RefCell::new(HashMap::new());
}

/// The chrome-close grammar, at the Win32 boundary: WM_CLOSE on a
/// veto_close window emits close_requested and is swallowed; on a
/// non-veto auxiliary it reports window_closed and proceeds; the
/// non-veto primary proceeds into the existing Closed handler (app
/// exit). Everything else forwards to the original WNDPROC.
unsafe extern "system" fn kaya_wndproc(
    hwnd: isize,
    msg: u32,
    wparam: usize,
    lparam: isize,
) -> isize {
    let entry = KAYA_WNDPROCS.with_borrow(|m| m.get(&hwnd).copied());
    let Some((id, original)) = entry else {
        return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) };
    };
    if msg == WM_CLIPBOARDUPDATE {
        // Deferred, never a borrow here: the WNDPROC re-enters CORE
        // by construction (the close path's rule).
        defer_role_refresh();
        return unsafe { CallWindowProcW(original, hwnd, msg, wparam, lparam) };
    }
    if msg == WM_CLOSE {
        let tearing = CORE.with_borrow(|core| {
            core.as_ref()
                .map(|c| c.tearing_down.contains(&id))
                .unwrap_or(false)
        });
        if tearing {
            return unsafe { CallWindowProcW(original, hwnd, msg, wparam, lparam) };
        }
        let veto = CORE.with_borrow(|core| {
            core.as_ref()
                .map(|c| c.window_veto.get(&id).copied().unwrap_or(false))
                .unwrap_or(false)
        });
        if veto {
            CORE.with_borrow(|core| {
                if let Some(c) = core.as_ref() {
                    c.occurrences.send(crate::protocol::Occurrence::CloseRequested {
                        window: crate::protocol::WindowId(id),
                    });
                }
            });
            return 0;
        }
        if id != 0 {
            CORE.with_borrow(|core| {
                if let Some(c) = core.as_ref() {
                    c.occurrences.send(crate::protocol::Occurrence::WindowClosed {
                        window: crate::protocol::WindowId(id),
                    });
                }
            });
        }
    }
    unsafe { CallWindowProcW(original, hwnd, msg, wparam, lparam) }
}

/// Install the close grammar on a window's HWND.
fn subclass(window: &Window, id: u64) -> windows_core::Result<()> {
    let native: IWindowNative = windows_core::Interface::cast(window)?;
    let hwnd = native.window_handle()?;
    unsafe {
        let original = SetWindowLongPtrW(hwnd, GWLP_WNDPROC, kaya_wndproc as isize);
        KAYA_WNDPROCS.with_borrow_mut(|m| {
            m.insert(hwnd, (id, original));
        });
        // Paste's enablement moves when the clipboard does, and the
        // system's own change signal is WM_CLIPBOARDUPDATE — a
        // format listener, not the ancient viewer chain. Registered
        // on every kaya window; the deferred refresh no-ops in
        // scenes that never armed the clipboard.
        AddClipboardFormatListener(hwnd);
    }
    Ok(())
}

#[link(name = "user32")]
unsafe extern "system" {
    fn SetWindowPos(
        hwnd: isize,
        insert_after: isize,
        x: i32,
        y: i32,
        cx: i32,
        cy: i32,
        flags: u32,
    ) -> i32;

    fn GetWindowRect(hwnd: isize, rect: *mut Rect) -> i32;
    fn GetClientRect(hwnd: isize, rect: *mut Rect) -> i32;

    /// The gone-check's three entries, declared here beside the rest
    /// rather than by enabling Win32_UI_WindowsAndMessaging: this file
    /// already names the handful of user32 calls it needs, and the
    /// feature would pull a very large surface for three.
    fn EnumWindows(
        callback: Option<unsafe extern "system" fn(isize, isize) -> i32>,
        param: isize,
    ) -> i32;
    fn GetClassNameW(hwnd: isize, buf: *mut u16, len: i32) -> i32;
    fn IsWindowVisible(hwnd: isize) -> i32;
    fn GetDpiForWindow(hwnd: isize) -> u32;
    fn SetWindowLongPtrW(hwnd: isize, index: i32, value: isize) -> isize;
    // The shortcut verb's REAL dispatch: foreground the guest and put
    // the chord on the system input queue, so XAML's own
    // KeyboardAccelerator machinery routes it (docs/traps.md: the
    // injection is OS-global; menu legs run serially for exactly this
    // reason).
    fn SetForegroundWindow(hwnd: isize) -> i32;
    fn GetForegroundWindow() -> isize;
    /// The clipboard-change signal Paste's enablement follows
    /// (WM_CLIPBOARDUPDATE to every registered listener). Raw beside
    /// its WNDPROC consumers, matching this block's convention.
    fn AddClipboardFormatListener(hwnd: isize) -> i32;
    fn keybd_event(vk: u8, scan: u8, flags: u32, extra: usize);
    fn CallWindowProcW(
        prev: isize,
        hwnd: isize,
        msg: u32,
        wparam: usize,
        lparam: isize,
    ) -> isize;
    fn DefWindowProcW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> isize;

    /// The harness's own calls: the sampler window that lets it ask an
    /// STA object a question from another thread, and the posts that
    /// drive the dialog. EVERY ONE IS GATED, because WndClassW is, and
    /// a shipped app carries none of this — check-targets builds both
    /// feature configurations for exactly this reason.
    #[cfg(feature = "harness")]
    fn RegisterClassW(class: *const WndClassW) -> u16;
    #[cfg(feature = "harness")]
    fn EnumChildWindows(
        parent: isize,
        callback: Option<unsafe extern "system" fn(isize, isize) -> i32>,
        param: isize,
    ) -> i32;
    #[cfg(feature = "harness")]
    fn GetDlgCtrlID(hwnd: isize) -> i32;
    #[cfg(feature = "harness")]
    #[allow(clippy::too_many_arguments)]
    fn CreateWindowExW(
        ex_style: u32,
        class: *const u16,
        window: *const u16,
        style: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        parent: isize,
        menu: isize,
        instance: isize,
        param: *mut core::ffi::c_void,
    ) -> isize;
    #[cfg(feature = "harness")]
    fn DestroyWindow(hwnd: isize) -> i32;
    #[cfg(feature = "harness")]
    fn PostMessageW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> i32;
}

/// Win32's RECT, for the client/outer chrome math below.
#[repr(C)]
#[derive(Default)]
struct Rect {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
}

/// The advisory size request's Win32 materialization: DIP -> physical
/// via the window's DPI, applied to the CLIENT area (the request is a
/// content size) by carrying the current chrome delta onto the outer
/// frame. A request, never a guarantee — the shell keeps the last
/// word (DESIGN.md, Presentation contexts).
fn winui_window(core: &CoreState, id: u64) -> windows_core::Result<Window> {
    if id == 0 {
        Ok(core.window.clone())
    } else {
        Ok(core
            .aux_windows
            .get(&id)
            .expect("scene validated the window id")
            .clone())
    }
}

fn resize_request(
    window: &Window,
    width: Option<f64>,
    height: Option<f64>,
) -> windows_core::Result<()> {
    let native: IWindowNative = windows_core::Interface::cast(window)?;
    let hwnd = native.window_handle()?;
    unsafe {
        let mut outer = Rect::default();
        let mut client = Rect::default();
        if GetWindowRect(hwnd, &mut outer) == 0 || GetClientRect(hwnd, &mut client) == 0 {
            return Ok(());
        }
        let scale = f64::from(GetDpiForWindow(hwnd)) / 96.0;
        let client_w = f64::from(client.right - client.left);
        let client_h = f64::from(client.bottom - client.top);
        let chrome_w = (outer.right - outer.left) - (client.right - client.left);
        let chrome_h = (outer.bottom - outer.top) - (client.bottom - client.top);
        let target_w = width.map_or(client_w, |w| w * scale).round() as i32 + chrome_w;
        let target_h = height.map_or(client_h, |h| h * scale).round() as i32 + chrome_h;
        const SWP_NOMOVE: u32 = 0x2;
        const SWP_NOZORDER: u32 = 0x4;
        const SWP_NOACTIVATE: u32 = 0x10;
        SetWindowPos(
            hwnd,
            0,
            0,
            0,
            target_w,
            target_h,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
        );
    }
    Ok(())
}

fn setup(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> windows_core::Result<()> {
    let window = Window::new()?;
    // Recording mode tiles parallel legs so per-window captures never
    // overlap, and the slot rides the TITLE so the recorder can name
    // each window's frames unambiguously.
    let slot = std::env::var("KAYA_WIN_SLOT")
        .ok()
        .and_then(|s| s.parse::<i32>().ok());
    let title = match slot {
        Some(n) => format!("kaya milestone 2 [{n}]"),
        None => "kaya milestone 2".to_owned(),
    };
    window.SetTitle(&HSTRING::from(&*title))?;
    if let Some(n) = slot {
        let native: IWindowNative = windows_core::Interface::cast(&window)?;
        let hwnd = native.window_handle()?;
        const SWP_NOZORDER: u32 = 0x4;
        const SWP_NOACTIVATE: u32 = 0x10;
        unsafe {
            SetWindowPos(
                hwnd,
                0,
                6 + (n % 2) * 568,
                6 + (n / 2) * 390,
                556,
                378,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
    }

    // The close grammar (veto/report) rides a WNDPROC subclass; the
    // non-veto primary falls through into the Closed handler below.
    subclass(&window, 0)?;

    // Closing the window exits the app, matching the AppKit backend's
    // terminate-after-last-window-closed behavior.
    let closed = bindings::Windows::Foundation::TypedEventHandler::new(|_, _| {
        request_exit(0);
        Ok(())
    });
    window.Closed(&closed)?;
    window.Activate()?;

    #[cfg(feature = "harness")]
    if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
        let scene = scene.trim().to_owned();
        eprintln!("kaya: winui selftest armed ({scene})");
        crate::harness::spawn(&scene, WinUiStage, |line| println!("{line}"));
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
            occurrences: occ_tx,
            pending_dialog_dir: RefCell::new(None),
            widgets: HashMap::new(),
            parents: HashMap::new(),
            buttons: Vec::new(),
            checkboxes: Vec::new(),
            labels: Vec::new(),
            entries: Vec::new(),
            entry_ids: Vec::new(),
            entry_swallow: HashMap::new(),
            entry_tags: HashMap::new(),
            sliders: Vec::new(),
            images: Vec::new(),
            scrolls: Vec::new(),
            progresses: Vec::new(),
            selects: Vec::new(),
            radios: Vec::new(),
            grids: Vec::new(),
            textareas: Vec::new(),
            textarea_ids: Vec::new(),
            grid_children: HashMap::new(),
            grid_cols: HashMap::new(),
            radio_options: HashMap::new(),
            select_options: HashMap::new(),
            apply_quiet: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            columns: Vec::new(),
            rows: Vec::new(),
            child_order: HashMap::new(),
            grow: HashMap::new(),
            aligns: HashMap::new(),
            window,
            aux_windows: HashMap::new(),
            nav_entries: HashMap::new(),
            sections: HashMap::new(),
            section_panes: HashMap::new(),
            section_navs: HashMap::new(),
            section_items: HashMap::new(),
            section_swallow: HashMap::new(),
            ui_selected_sections: HashMap::new(),
            selected_sections: HashMap::new(),
            sections_presentation: HashMap::new(),
            nav_stacks: HashMap::new(),
            list_detail: HashMap::new(),
            split_presentation: HashMap::new(),
            split_views: HashMap::new(),
            window_roots: HashMap::new(),
            window_titles: HashMap::new(),
            window_veto: HashMap::new(),
            tearing_down: std::collections::HashSet::new(),
            live_alert: None,
            menu_models: HashMap::new(),
            menu_windows: HashMap::new(),
            context_roots: HashMap::new(),
            context_nouns: HashMap::new(),
            context_flyouts: HashMap::new(),
            menu_natives: HashMap::new(),
            menubars: HashMap::new(),
            menu_slots: HashMap::new(),
            menu_shortcuts: HashMap::new(),
            open_context: None,
            menus_touched: false,
            accepts: HashMap::new(),
            clipboard_armed: false,
        });
    });

    // The first transaction may already be queued; drain now.
    drain_transactions();
    Ok(())
}

/// The harness stage: WinUI's native calls, each hopping to the
/// dispatcher. Programmatic SetIsChecked/SetText/SetValue raise the
/// real event paths; clicks emit the button's stored tag, the same
/// bytes the pointer path would.
/// PowerShell single-quoted literal: the only escape is '' for '.
#[cfg(feature = "harness")]
fn ps_quote(s: &str) -> String {
    s.replace('\'', "''")
}

/// The foreign clipboard tool's one entry: powershell.exe, PINNED —
/// pwsh silently lacks the entire clipboard cmdlet surface this lane
/// uses (-AsHtml, -LiteralPath, -Format, -TextFormatType), so the
/// edition is asserted INSIDE the script; a future shell swap fails
/// loudly here instead of reading empty (the guard, not a memory).
/// Runs on the harness thread — a child process on the app thread
/// would trip the stall watchdog.
#[cfg(feature = "harness")]
fn run_powershell(script: &str) -> String {
    let guarded = format!(
        "$ErrorActionPreference='Stop'; if ($PSVersionTable.PSEdition -ne 'Desktop') {{ Write-Output 'KAYA_WRONG_EDITION'; exit 1 }}; {script}"
    );
    let out = std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            &guarded,
        ])
        .output()
        .unwrap_or_else(|e| panic!("kaya: the foreign clipboard tool needs powershell.exe: {e}"));
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(
        !stdout.contains("KAYA_WRONG_EDITION"),
        "kaya: powershell resolved to a non-Desktop edition — the clipboard \
         cmdlet surface differs there (docs/clipboard-plan.md §6)"
    );
    stdout
}

#[cfg(feature = "harness")]
struct WinUiStage;

#[cfg(feature = "harness")]
impl WinUiStage {
    /// The mutable twin of on_ui, for stage actions that reconcile
    /// core-owned state (select_section's user route).
    fn on_ui_mut<T: Send + 'static>(
        f: impl FnOnce(&mut CoreState) -> windows_core::Result<T> + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        let dispatcher = DISPATCHER.get().expect("the dispatcher is up");
        let cell = std::sync::Mutex::new(Some((f, tx)));
        let handler = DispatcherQueueHandler::new(move || {
            if let Some((f, tx)) = cell.lock().unwrap().take() {
                CORE.with_borrow_mut(|core| {
                    let core = core.as_mut().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
        rx.recv()
            .expect("the dispatcher applied the step")
            .expect("the step's WinRT calls succeeded")
    }

    fn on_ui<T: Send + 'static>(
        f: impl FnOnce(&CoreState) -> windows_core::Result<T> + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        let dispatcher = DISPATCHER.get().expect("the dispatcher is up");
        let cell = std::sync::Mutex::new(Some((f, tx)));
        let handler = DispatcherQueueHandler::new(move || {
            if let Some((f, tx)) = cell.lock().unwrap().take() {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
        rx.recv()
            .expect("the dispatcher applied the step")
            .expect("the step's WinRT calls succeeded")
    }

    /// The observation flavor: a read that errors mid-materialization
    /// (a null Content cast before the first layout, a not-yet-live
    /// XamlRoot) is a RETRYABLE miss for the harness's bounded polls,
    /// never a panic — a panic here either kills the harness thread
    /// or, worse, aborts the process when it crosses a dispatcher
    /// callback (caught live 2026-07-22: window/grow/panels legs
    /// fail-fasted or hung the moment the settles stopped hiding the
    /// materialization window). Actions keep on_ui: their targets are
    /// proven by a preceding expect, so an error there IS a bug.
    fn on_ui_read<T: Send + 'static>(
        f: impl FnOnce(&CoreState) -> windows_core::Result<T> + Send + 'static,
    ) -> windows_core::Result<T> {
        let (tx, rx) = std::sync::mpsc::channel();
        let dispatcher = DISPATCHER.get().expect("the dispatcher is up");
        let cell = std::sync::Mutex::new(Some((f, tx)));
        let handler = DispatcherQueueHandler::new(move || {
            if let Some((f, tx)) = cell.lock().unwrap().take() {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
        rx.recv().expect("the dispatcher applied the step")
    }
}

#[cfg(feature = "harness")]
impl crate::harness::Stage for WinUiStage {
    fn menu_activate(&self, path: &str) {
        let spec = path.to_owned();
        // Resolve SEMANTICALLY against the model tree — the OPEN
        // context menu exclusively while one is presented, the
        // primary window's catalog otherwise — then drive the REAL
        // invoke pipeline on the materialized item. For a context
        // activation the staged ruling applies: register Closed
        // BEFORE invoking, keep the flyout handle through Closed, and
        // await it before another open may start. No sleeps.
        let wait = Self::on_ui_mut(move |core| {
            // THE HARNESS-ACTIVATION REFRESH (the mac finding, §3),
            // and here it is load-bearing beyond a grayed row: the
            // invoke pipeline goes through the item's automation
            // peer, and Invoke() on a still-disabled item THROWS
            // inside a dispatcher callback — a stowed exception,
            // 0xC000027B, process gone. Focus changes refresh
            // enablement on a DEFERRED tick, so without this a
            // focus-then-activate script races that tick (measured:
            // the clipboard scene's first Edit>Paste, rust leg).
            if core.clipboard_armed {
                refresh_clipboard_roles(core);
            }
            let (roots, flyout, attachment) = match &core.open_context {
                Some((widget, flyout)) => (
                    core.context_roots.get(widget).cloned().unwrap_or_default(),
                    Some(flyout.clone()),
                    MenuAttachment::Context(*widget),
                ),
                None => (
                    core.menu_windows.get(&0).cloned().unwrap_or_default(),
                    None,
                    MenuAttachment::Window(0),
                ),
            };
            let Some(item) = resolve_menu_path(core, &spec, &roots) else {
                panic!("kaya: no such menu item {spec:?}");
            };
            // The OPEN attachment's own instance: the anchor-qualified
            // key is what makes a stamped row invoke ITS copy — never
            // whichever copy an arbitrary rebuild order built last
            // (the keys ARE the noun; docs/traps.md).
            let Some(native) = core.menu_natives.get(&(attachment, item)).cloned() else {
                // A grouping node whose materialization mints no
                // chrome of its own: nothing to activate (parity with
                // the interpreters' silent grouping arm).
                return Ok(None);
            };
            let closed = match &flyout {
                Some(flyout) => {
                    let (tx, rx) = std::sync::mpsc::channel::<()>();
                    let armed = std::sync::Mutex::new(Some(tx));
                    let handler = bindings::Windows::Foundation::EventHandler::<
                        windows_core::IInspectable,
                    >::new(move |_, _| {
                        if let Some(tx) = armed.lock().unwrap().take() {
                            let _ = tx.send(());
                        }
                        Ok(())
                    });
                    flyout.Closed(&handler)?;
                    Some(rx)
                }
                None => None,
            };
            // Deferred one dispatcher tick: the item's Click handler
            // re-borrows CORE, which this closure holds (the back()
            // precedent). The flyout handle rides the closure so it
            // outlives even the anchor row's destruction — the item's
            // occurrence may remove its stamped anchor before event
            // cleanup runs (docs/traps.md).
            let queue = DispatcherQueue::GetForCurrentThread()?;
            let keep = flyout.clone();
            let handler = DispatcherQueueHandler::new(move || {
                let _keep = &keep;
                invoke_menu_native(&native)
            });
            queue.TryEnqueue(&handler)?;
            Ok(closed)
        });
        if let Some(rx) = wait {
            rx.recv_timeout(std::time::Duration::from_secs(10)).expect(
                "kaya: the context flyout never closed after the activation (Closed did not arrive)",
            );
            Self::on_ui_mut(|core| {
                core.open_context = None;
                Ok(())
            });
        }
    }

    fn context_open(&self, t: crate::harness::Target) {
        // The REAL presentation path: ShowAt on the anchor's own
        // ContextFlyout. ShowAt is a request, not a readiness
        // boundary (docs/traps.md): Opened is registered BEFORE the
        // request and this step does not complete until it arrives —
        // the following menu_activate then acts on a live presenter.
        let opened = Self::on_ui_mut(move |core| {
            // A lingering open menu would let this open overtake its
            // close animation; the scene grammar always activates
            // first, so this is the loud belt, not the path.
            if let Some((_, previous)) = core.open_context.take() {
                let _ = previous.Hide();
            }
            let widget = widget_id_for_target(core, t);
            let flyout = core.context_flyouts.get(&widget).cloned().unwrap_or_else(|| {
                panic!("kaya: no context menu attached to {t:?}")
            });
            let (tx, rx) = std::sync::mpsc::channel::<()>();
            let armed = std::sync::Mutex::new(Some(tx));
            let handler = bindings::Windows::Foundation::EventHandler::<
                windows_core::IInspectable,
            >::new(move |_, _| {
                if let Some(tx) = armed.lock().unwrap().take() {
                    let _ = tx.send(());
                }
                Ok(())
            });
            flyout.Opened(&handler)?;
            let anchor: FrameworkElement = core
                .widgets
                .get(&WidgetId(widget))
                .expect("the anchor widget lives")
                .element()?
                .cast()?;
            flyout.ShowAt(&anchor)?;
            core.open_context = Some((widget, flyout));
            Ok(rx)
        });
        opened
            .recv_timeout(std::time::Duration::from_secs(10))
            .expect("kaya: the context flyout never opened (Opened did not arrive)");
    }

    fn menu_count(&self) -> usize {
        // The REAL bar chrome's top-level count, never the model map
        // (the section_count precedent).
        Self::on_ui_read(|core| {
            Ok(core
                .menubars
                .get(&0)
                .map(|bar| bar.Items()?.Size().map(|n| n as usize))
                .transpose()?
                .unwrap_or(0))
        })
        .unwrap_or(0)
    }

    fn ax(&self, target: crate::harness::Target) -> String {
        //
        // Read UIA's own peer, not kaya's model: FrameworkElementAutomationPeer
        // is what an assistive client (Narrator, an automation harness)
        // sees. Correspondence is by IDENTITY — WinUI publishes a
        // settable AutomationId, unlike GTK where none exists below 4.22
        // and the read has to match by ordinal.
        Self::on_ui_read(move |core| {
            use bindings::Microsoft::UI::Xaml::Automation::Peers::{
                AutomationControlType, FrameworkElementAutomationPeer,
            };
            // Resolve the ELEMENT from the per-kind registry, the way
            // every other WinUI verb does (read_label/read_text), with
            // try_resolve so an out-of-range index reports "no such
            // target" instead of panicking. The earlier version reused
            // widget_id_for_target, which serves context_open and
            // handles Label ONLY — every other kind hit its panic!,
            // inside the UI closure, surfacing as an opaque RecvError.
            use crate::harness::{try_resolve, TargetKind as K};
            let element: bindings::Microsoft::UI::Xaml::UIElement = match target.kind {
                K::Checkbox => match try_resolve(target.index, core.checkboxes.len()) {
                    Some(i) => core.checkboxes[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Entry => match try_resolve(target.index, core.entries.len()) {
                    Some(i) => core.entries[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Textarea => match try_resolve(target.index, core.textareas.len()) {
                    Some(i) => core.textareas[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Label => match try_resolve(target.index, core.labels.len()) {
                    Some(i) => core.labels[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Slider => match try_resolve(target.index, core.sliders.len()) {
                    Some(i) => core.sliders[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Row => match try_resolve(target.index, core.rows.len()) {
                    Some(i) => core.rows[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Column => match try_resolve(target.index, core.columns.len()) {
                    Some(i) => core.columns[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Image => match try_resolve(target.index, core.images.len()) {
                    Some(i) => core.images[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Progress => match try_resolve(target.index, core.progresses.len()) {
                    Some(i) => core.progresses[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Select => match try_resolve(target.index, core.selects.len()) {
                    Some(i) => core.selects[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Radio => match try_resolve(target.index, core.radios.len()) {
                    Some(i) => core.radios[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Grid => match try_resolve(target.index, core.grids.len()) {
                    Some(i) => core.grids[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Scroll => match try_resolve(target.index, core.scrolls.len()) {
                    Some(i) => core.scrolls[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                // Buttons live in the registry as CLICK TAGS, not
                // widgets, and the tag is captured in the click
                // closure rather than stored on the Button — so there
                // is no tag->widget link to follow. Both orderings are
                // CREATION order though: core.buttons is a push-order
                // Vec and WidgetId is assigned in sequence, so the Nth
                // button widget by ascending id is the Nth entry. The
                // ids must be sorted explicitly: core.widgets is a
                // HashMap and its iteration order is arbitrary.
                K::Button => {
                    if try_resolve(target.index, core.buttons.len()).is_none() {
                        return Ok("<no such target>".to_owned());
                    }
                    let i = crate::harness::resolve(target.index, core.buttons.len());
                    let mut ids: Vec<_> = core
                        .widgets
                        .iter()
                        .filter(|(_, w)| matches!(w, NativeWidget::Button { .. }))
                        .map(|(id, _)| *id)
                        .collect();
                    ids.sort_by_key(|id| id.0);
                    match ids.get(i).and_then(|id| core.widgets.get(id)) {
                        Some(NativeWidget::Button { button, .. }) => button.cast()?,
                        _ => return Ok("<no such target>".to_owned()),
                    }
                }
                _ => return Ok("<no such target>".to_owned()),
            };
            let fe: bindings::Microsoft::UI::Xaml::FrameworkElement = element.cast()?;
            // FromElement returns an EXISTING peer; a plain container
            // (Row/Column are Grids) has none until one is made, so it
            // reported "<not in the accessibility tree>" for a group
            // that UIA is perfectly willing to describe. CreatePeerForElement
            // makes one on demand — the same thing UIA does when a
            // client walks the tree — and falls back to FromElement for
            // controls that already carry theirs.
            let peer = match FrameworkElementAutomationPeer::CreatePeerForElement(&fe) {
                Ok(p) => p,
                Err(_) => match FrameworkElementAutomationPeer::FromElement(&fe) {
                    Ok(p) => p,
                    Err(_) => return Ok("<not in the accessibility tree>".to_owned()),
                },
            };
            let kind = peer.GetAutomationControlType()?;
            let role = if kind == AutomationControlType::Button {
                "button"
            } else if kind == AutomationControlType::CheckBox {
                "checkbox"
            } else if kind == AutomationControlType::Edit {
                "field"
            } else if kind == AutomationControlType::Text {
                "label"
            } else if kind == AutomationControlType::Slider {
                "slider"
            } else if kind == AutomationControlType::Image {
                "image"
            } else if kind == AutomationControlType::ProgressBar {
                "progress"
            } else if kind == AutomationControlType::ComboBox {
                // The chooser, spelled `combobox` in the closed set:
                // AXPopUpButton on macOS, a UIButton owning a menu on
                // iOS, Role.DropdownList on Compose, ComboBox here and
                // on AT-SPI.
                "combobox"
            } else if kind == AutomationControlType::Group
                || kind == AutomationControlType::Pane
                || kind == AutomationControlType::List
            {
                // NORMALIZED to the coarsest container role every
                // platform publishes. UIA distinguishes Group, Pane and
                // List (a RadioButtons group is a List here); the
                // closed set has one name for "a container an assistive
                // client steps into", because that is all a shared
                // scene can assert.
                "group"
            } else {
                // The role the platform published is one kaya has no
                // name for — the finding this verb exists to surface,
                // and the next question is always WHICH one, so it goes
                // to the log rather than costing a VM round-trip.
                eprintln!("KAYA_AX_TRACE: unmapped UIA control type {kind:?} for {target:?}");
                "unknown"
            };
            let name = peer.GetName()?.to_string();
            // A text field with no authored label publishes an EMPTY
            // UIA Name — its content lives on the ValuePattern, and
            // that value is what a screen reader speaks for it. The
            // same fallback chain the other platforms take (macOS
            // description -> title -> AXValue; GTK name -> AT-SPI Text
            // content), so `field/<its text>` reads the same
            // everywhere. The TextBox's Text IS the value the peer's
            // ValueProvider serves; reading it here stays inside the
            // platform's own property surface.
            let name = if name.is_empty()
                && matches!(target.kind, K::Entry | K::Textarea)
            {
                match target.kind {
                    K::Entry => try_resolve(target.index, core.entries.len())
                        .map(|i| lf(core.entries[i].Text().map(|t| t.to_string()).unwrap_or_default()))
                        .unwrap_or_default(),
                    _ => try_resolve(target.index, core.textareas.len())
                        .map(|i| lf(core.textareas[i].Text().map(|t| t.to_string()).unwrap_or_default()))
                        .unwrap_or_default(),
                }
            } else {
                name
            };
            Ok(format!("{role}/{name}"))
        })
        .unwrap_or_else(|_| "<accessibility read failed>".to_owned())
    }

    fn ax_hint(&self, target: crate::harness::Target) -> String {
        // UIA's HelpText is the hint slot: "a brief description of the
        // control's purpose", read off the same peer `ax` reads.
        Self::on_ui_read(move |core| {
            use bindings::Microsoft::UI::Xaml::Automation::Peers::FrameworkElementAutomationPeer;
            use crate::harness::{try_resolve, TargetKind as K};
            let element: bindings::Microsoft::UI::Xaml::UIElement = match target.kind {
                K::Checkbox => match try_resolve(target.index, core.checkboxes.len()) {
                    Some(i) => core.checkboxes[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Select => match try_resolve(target.index, core.selects.len()) {
                    Some(i) => core.selects[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Radio => match try_resolve(target.index, core.radios.len()) {
                    Some(i) => core.radios[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Button => {
                    if try_resolve(target.index, core.buttons.len()).is_none() {
                        return Ok("<no such target>".to_owned());
                    }
                    let i = crate::harness::resolve(target.index, core.buttons.len());
                    let mut ids: Vec<_> = core
                        .widgets
                        .iter()
                        .filter(|(_, w)| matches!(w, NativeWidget::Button { .. }))
                        .map(|(id, _)| *id)
                        .collect();
                    ids.sort_by_key(|id| id.0);
                    match ids.get(i).and_then(|id| core.widgets.get(id)) {
                        Some(NativeWidget::Button { button, .. }) => button.cast()?,
                        _ => return Ok("<no such target>".to_owned()),
                    }
                }
                // The root admits a11y_hint on activation kinds only.
                _ => {
                    return Ok("<the hint prop applies to activation kinds only>".to_owned())
                }
            };
            let fe: bindings::Microsoft::UI::Xaml::FrameworkElement = element.cast()?;
            let peer = match FrameworkElementAutomationPeer::CreatePeerForElement(&fe) {
                Ok(p) => p,
                Err(_) => match FrameworkElementAutomationPeer::FromElement(&fe) {
                    Ok(p) => p,
                    Err(_) => return Ok("<not in the accessibility tree>".to_owned()),
                },
            };
            Ok(peer.GetHelpText()?.to_string())
        })
        .unwrap_or_else(|_| "<accessibility read failed>".to_owned())
    }

    fn resize_window(&self, window: u64, width: f64, height: f64) {
        Self::on_ui_mut(move |core| {
            // The REAL resize, through the same DPI-aware path the
            // width/height props drive — and then RE-RUN the arm, which
            // is the point: changing the size without letting the
            // platform re-decide gates nothing.
            let target = winui_window(core, window)?;
            resize_request(&target, Some(width), Some(height))?;
            // FORCE A LAYOUT PASS before re-running the arm. SetWindowPos
            // returns before XAML has re-measured, so the arm asked for
            // a width that was still the OLD one — it stamped `stacked`
            // while the read, running a beat later, said `regular`. The
            // two disagreeing about the same instant is the signature of
            // reading a tree mid-update.
            if let Ok(content) = target.Content() {
                if let Ok(root) = content.cast::<FrameworkElement>() {
                    let _ = root.UpdateLayout();
                }
            }
            refresh_nav(core, window)?;
            Ok(())
        })
    }

    fn split_presentation(&self) -> String {
        // on_ui_read, like menu_presentation: a pure read of the UI
        // thread's own state, with no mutation to sequence.
        Self::on_ui_read(|core| {
            // The class comes from XamlRoot's real size, the same 600
            // boundary menu_presentation draws; the presentation from
            // the arm that actually ran.
            //
            // UNREADABLE until the element is in a live visual tree,
            // and this verb is asked within milliseconds of launch.
            // `unknown` is a legal class in the grammar for exactly
            // that state, and the harness POLLS — reporting it lets the
            // bounded retry pick up the real reading a frame later.
            // Propagating the error instead killed the leg, which is
            // not what "not yet" deserves.
            // The SAME source the arm used: an assertion measuring
            // differently from the lowering can disagree with it about
            // one instant, which is how this leg failed with the arm
            // saying stacked and the read saying regular.
            let class = match window_client_width(core, 0) {
                Some(w) if w >= 600.0 => "regular",
                Some(_) => "compact",
                None => "unknown",
            };
            // THE CONTROL'S OWN ANSWER, not a value the arm stamped
            // about itself. Windows decides where one pane becomes two,
            // so the only honest reading of which presentation happened
            // is to ask the control. A window that never asked for
            // list-detail has no control, and falls back to the serial
            // arm's stamp.
            let presentation = match core.split_views.get(&0).map(|v| v.Mode()) {
                Some(Ok(mode)) if mode != TwoPaneViewMode::SinglePane => "split",
                Some(Ok(_)) => "stacked",
                _ => core.split_presentation.get(&0).copied().unwrap_or("stacked"),
            };
            Ok(format!("{class}/{presentation}"))
        })
        // The same fallback menu_presentation uses: a read that cannot
        // reach the UI thread reports `unknown`, and the harness's
        // bounded retry asks again.
        .unwrap_or_else(|_| "unknown/stacked".to_owned())
    }

    fn menu_presentation(&self) -> String {
        // XAML has no size-class type; its own adaptive triggers are
        // width thresholds (`MinWindowWidth`), so a width rule IS the
        // platform idiom here. Same 600 boundary as the others, read
        // off the real root's ActualWidth in effective pixels.
        Self::on_ui_read(|core| {
            // The XamlRoot's size is the client area in DIP — the same
            // notion window_content_size and root_fills read, so the
            // 600 boundary means the same thing here as elsewhere.
            let target = winui_window(core, 0)?;
            let root: FrameworkElement = target.Content()?.cast()?;
            let width = f64::from(root.XamlRoot()?.Size()?.Width);
            let class = if width >= 600.0 { "regular" } else { "compact" };
            // Read off the REAL chrome, like menu_count: a MenuBar with
            // items or nothing. WinUI has only the bar lowering.
            let bar = core
                .menubars
                .get(&0)
                .map(|bar| bar.Items()?.Size().map(|n| n > 0))
                .transpose()?
                .unwrap_or(false);
            Ok(format!("{class}/{}", if bar { "bar" } else { "none" }))
        })
        .unwrap_or_else(|_| "unknown/none".to_owned())
    }

    fn menu_state(&self, path: &str, aspect: crate::harness::MenuAspect) -> String {
        use crate::harness::MenuAspect;
        let path = path.to_owned();
        Self::on_ui_read(move |core| {
            // Open-context EXCLUSIVITY: while presented, the context
            // menu owns resolution — a miss reads as the retryable
            // "no such item", never a bar fallback.
            let (roots, attachment) = match &core.open_context {
                Some((widget, _)) => (
                    core.context_roots.get(widget).cloned().unwrap_or_default(),
                    MenuAttachment::Context(*widget),
                ),
                None => (
                    core.menu_windows.get(&0).cloned().unwrap_or_default(),
                    MenuAttachment::Window(0),
                ),
            };
            let Some(item) = resolve_menu_path(core, &path, &roots) else {
                return Ok("no such item".to_owned());
            };
            Ok(match aspect {
                MenuAspect::Enablement => match core.menu_natives.get(&(attachment, item)) {
                    // The REAL item's flag — the rebuild stamps the
                    // inherited AND onto every native, so a backend
                    // that ignored the write must fail here.
                    Some(native) => if native.is_enabled()? {
                        "enabled"
                    } else {
                        "disabled"
                    }
                    .to_owned(),
                    // An inline nested grouping node mints no titled
                    // chrome (mac segment parity).
                    None => "no such item".to_owned(),
                },
                MenuAspect::Checkedness => match core.menu_natives.get(&(attachment, item)) {
                    Some(MenuNative::Toggle(native)) => if native.IsChecked()? {
                        "checked"
                    } else {
                        "unchecked"
                    }
                    .to_owned(),
                    Some(MenuNative::Option(native)) => if native.IsChecked()? {
                        "checked"
                    } else {
                        "unchecked"
                    }
                    .to_owned(),
                    Some(_) => "unchecked".to_owned(),
                    None => "no such item".to_owned(),
                },
                MenuAspect::Value => {
                    // The group's value IS its checked option, read
                    // from the REAL radio rows (the checkmark idiom).
                    let children = core
                        .menu_models
                        .get(&item)
                        .map(|m| m.children.clone())
                        .unwrap_or_default();
                    let mut found = None;
                    for (index, child) in children.iter().enumerate() {
                        if let Some(MenuNative::Option(radio)) =
                            core.menu_natives.get(&(attachment, *child))
                        {
                            if radio.IsChecked()? {
                                found = Some(index);
                                break;
                            }
                        }
                    }
                    match found {
                        Some(index) => format!("value {index}"),
                        None => "no checked option".to_owned(),
                    }
                }
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn shortcut(&self, spelling: &str) {
        let spec = spelling.to_owned();
        // A chord no catalog action owns is a silent no-op on every
        // platform — gated BEFORE any injection, because keybd_event
        // is OS-GLOBAL and a stray chord could land anywhere
        // (docs/traps.md: menu legs run serially for this verb).
        let owned = Self::on_ui_read({
            let spec = spec.clone();
            move |core| {
                // Same freshness rule as menu_activate: the chord may
                // land on a role item whose enablement is a deferred
                // tick stale.
                if core.clipboard_armed {
                    refresh_clipboard_roles(core);
                }
                Ok(core.menu_shortcuts.contains_key(&spec))
            }
        })
        .unwrap_or(false);
        // A chord no catalog item owns is a SCRIPT error, said out
        // loud. The gate itself is load-bearing (injection is
        // OS-global — docs/traps.md), but a silent return makes a
        // never-pressed key look exactly like a platform that ignored
        // it: that mistake cost eight platform experiments on
        // 2026-07-24, every one of them measuring a keystroke this
        // gate had swallowed.
        assert!(
            owned,
            "kaya: shortcut {spec:?}: no catalog item owns this chord \
             (the leaf kinds that may carry one are action, toggle, and \
             radio option)"
        );
        let hwnd = Self::on_ui(|core| {
            let native: IWindowNative = windows_core::Interface::cast(&core.window)?;
            native.window_handle()
        });
        // Foreground the guest and CONFIRM it before pressing
        // anything; failing to take foreground fails the leg loudly
        // rather than spraying the chord at whatever else is focused.
        // (A bounded confirmation poll, not a lifecycle sleep.)
        let mut confirmed = false;
        for attempt in 0..150 {
            if unsafe { GetForegroundWindow() } == hwnd {
                confirmed = true;
                break;
            }
            unsafe { SetForegroundWindow(hwnd) };
            if attempt == 10 {
                // An ACTIVE MENU categorically blocks SetForegroundWindow
                // — "no menus are active" is one of the documented
                // preconditions, so retrying and the ALT tap below can
                // never win against an open Start menu. ESC dismisses it.
                // This is not hypothetical: an unattended run on
                // 2026-07-25 lost two legs to a Start menu left open by
                // an earlier wedged run, which held the foreground until
                // something else happened to dismiss it. Nothing about
                // that required a human at the VM.
                unsafe {
                    keybd_event(0x1B, 0, 0, 0);
                    keybd_event(0x1B, 0, 2, 0);
                }
            }
            if attempt == 50 {
                // The classic foreground-lock release: a bare ALT tap
                // grants the next SetForegroundWindow call.
                unsafe {
                    keybd_event(0x12, 0, 0, 0);
                    keybd_event(0x12, 0, 2, 0);
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(
            confirmed,
            "kaya: could not foreground the guest window for shortcut \
             injection after 3s (an ACTIVE MENU blocks SetForegroundWindow \
             outright — a Start menu or popup left open on the VM is the \
             usual cause; ESC and the ALT foreground-lock release were \
             both tried)"
        );

        // The REAL KeyboardAccelerator path: the chord goes onto the
        // system input queue; XAML routes it to the accelerator whose
        // default invocation raises the item's own Click — the SAME
        // menu_activated the direct activation emits.
        let mut mods: Vec<u8> = Vec::new();
        let mut key: Option<u8> = None;
        for part in spec.split('+') {
            match part {
                "primary" => mods.push(0x11), // VK_CONTROL
                "shift" => mods.push(0x10),
                "alt" => mods.push(0x12),
                name => key = virtual_key(name).map(|vk| vk.0 as u8),
            }
        }
        let key = key.expect("a root-validated spelling carries one key");
        const KEYEVENTF_KEYUP: u32 = 0x2;
        unsafe {
            for &m in &mods {
                keybd_event(m, 0, 0, 0);
            }
            keybd_event(key, 0, 0, 0);
            keybd_event(key, 0, KEYEVENTF_KEYUP, 0);
            for &m in mods.iter().rev() {
                keybd_event(m, 0, KEYEVENTF_KEYUP, 0);
            }
        }
    }
    fn click(&self, t: crate::harness::Target) {
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.buttons.len());
            core.occurrences.send_click_tag(&core.buttons[i]);
            Ok(())
        });
    }

    fn toggle(&self, t: crate::harness::Target, on: bool) {
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.checkboxes.len());
            let boxed: IReference<bool> = PropertyValue::CreateBoolean(on)?.cast()?;
            core.checkboxes[i].SetIsChecked(&boxed)?;
            Ok(())
        });
    }

    fn set_value(&self, t: crate::harness::Target, value: f64) {
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.sliders.len());
            core.sliders[i].SetValue(value)?;
            Ok(())
        });
    }

    fn set_text(&self, t: crate::harness::Target, text: &str) {
        // Normalized on the way IN: the synthesized occurrence below
        // forwards this string to the guest, and CR-bearing input
        // (the harness's \r escape stands in for a paste) must reach
        // guests as LF like every other path.
        let text = lf(text.to_owned());
        Self::on_ui(move |core| {
            // The user path, ordered: TextChanged is raised async, so
            // the occurrence is emitted here synchronously and the
            // late raise swallowed — a following click can never
            // overtake the edit (see entry_swallow).
            let (field, id) = if t.kind == crate::harness::TargetKind::Textarea {
                let i = crate::harness::resolve(t.index, core.textareas.len());
                (&core.textareas[i], core.textarea_ids[i])
            } else {
                let i = crate::harness::resolve(t.index, core.entries.len());
                (&core.entries[i], core.entry_ids[i])
            };
            if lf(field.Text()?.to_string()) != text {
                if let Some(swallow) = core.entry_swallow.get(&id) {
                    swallow.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                field.SetText(&HSTRING::from(&text))?;
                if let Some(tag) = core.entry_tags.get(&id) {
                    core.occurrences.send_text_tag(tag, &text);
                }
            }
            Ok(())
        });
    }

    fn read_label(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.labels.len()) else {
                return Ok("<no such target>".to_string());
            };
            Ok(core.labels[i].Text()?.to_string())
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn read_text(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            if t.kind == crate::harness::TargetKind::Textarea {
                let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len())
                else {
                    return Ok("<no such target>".to_string());
                };
                return Ok(lf(core.textareas[i].Text()?.to_string()));
            }
            let Some(i) = crate::harness::try_resolve(t.index, core.entries.len()) else {
                return Ok("<no such target>".to_string());
            };
            Ok(lf(core.entries[i].Text()?.to_string()))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn image_size(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.images.len()) else {
                return Ok("<no such target>".to_string());
            };
            // The stored BitmapImage's decoded pixel size; no source
            // (or a source that never decoded) is the placeholder
            // class, "0x0".
            let size = core.images[i]
                .Source()
                .ok()
                .and_then(|source| source.cast::<BitmapImage>().ok())
                .and_then(|bitmap| {
                    Some((bitmap.PixelWidth().ok()?, bitmap.PixelHeight().ok()?))
                });
            Ok(match size {
                Some((w, h)) => format!("{w}x{h}"),
                None => "0x0".into(),
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn is_focused(&self, t: crate::harness::Target) -> bool {
        Self::on_ui_read(move |core| {
            // The element's own FocusState, never FocusManager's global
            // focused element — per-window focus, so parallel tiled
            // legs cannot steal each other's assertion.
            match t.kind {
                crate::harness::TargetKind::Entry => {
                    let Some(i) = crate::harness::try_resolve(t.index, core.entries.len()) else {
                        return Ok(false);
                    };
                    Ok(core.entries[i].FocusState()? != FocusState::Unfocused)
                }
                crate::harness::TargetKind::Textarea => {
                    let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len())
                    else {
                        return Ok(false);
                    };
                    Ok(core.textareas[i].FocusState()? != FocusState::Unfocused)
                }
                other => panic!("kaya: is_focused not wired for {other:?} on winui"),
            }
        }).unwrap_or(false)
    }

    fn child_texts(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let registry = if matches!(t.kind, crate::harness::TargetKind::Column) {
                &core.columns
            } else {
                &core.rows
            };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return Ok("<no such target>".to_string());
            };
            let children = registry[i].Children()?;
            // Child order as the toolkit holds it — the registries are
            // creation-ordered and cannot observe a move.
            let mut texts = Vec::new();
            for at in 0..children.Size()? {
                if let Ok(block) = children.GetAt(at)?.cast::<TextBlock>() {
                    if core.labels.iter().any(|l| l == &block) {
                        texts.push(block.Text()?.to_string());
                    }
                }
            }
            Ok(texts.join("|"))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn child_shares(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            // Kind picks the registry and the definition axis (the
            // runner rejects any other kind before it gets here). The
            // first Windows run of the row assertion caught this method
            // still hard-wired to columns: row#0 resolved against the
            // COLUMNS registry and reported the column's own splits —
            // the registry-misresolution class, one backend short of a
            // clean sweep.
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return Ok("<no such target>".to_string());
            };
            let grid = &registry[i];
            // Measure/arrange are lazy; force them or the first read
            // after mount sees zeros.
            grid.UpdateLayout()?;
            // The TRACK's resolved extent, not the child's: on a Grid
            // the track is the layout rect, and a child only fills it
            // if it stretches. A TextBlock never does — it reports its
            // text height however tall its row is — so reading children
            // turned an exactly correct 25/75 split into 37/63. Same
            // trap as AppKit's alignment rect and GTK's CSS box, in its
            // third dialect.
            let mut extents = Vec::new();
            if vertical {
                let defs = grid.RowDefinitions()?;
                for at in 0..defs.Size()? {
                    extents.push(defs.GetAt(at)?.ActualHeight()?);
                }
            } else {
                let defs = grid.ColumnDefinitions()?;
                for at in 0..defs.Size()? {
                    extents.push(defs.GetAt(at)?.ActualWidth()?);
                }
            }
            Ok(crate::harness::shares(&extents))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn container_fills(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return Ok("<no such target>".to_string());
            };
            let grid = &registry[i];
            grid.UpdateLayout()?;
            // A Grid places tracks from the padding edge with
            // RowSpacing-sized gaps between adjacent ones and no slack
            // anywhere else, so the consumed span is the tracks' sum
            // plus the gaps, and slack shows up as the difference to
            // the content box (ActualSize minus Padding).
            let padding = grid.Padding()?;
            let (inner, sum, gaps) = if vertical {
                let defs = grid.RowDefinitions()?;
                let mut sum = 0.0;
                for at in 0..defs.Size()? {
                    sum += defs.GetAt(at)?.ActualHeight()?;
                }
                (
                    grid.ActualHeight()? - padding.Top - padding.Bottom,
                    sum,
                    grid.RowSpacing()? * f64::from(defs.Size()?.saturating_sub(1)),
                )
            } else {
                let defs = grid.ColumnDefinitions()?;
                let mut sum = 0.0;
                for at in 0..defs.Size()? {
                    sum += defs.GetAt(at)?.ActualWidth()?;
                }
                (
                    grid.ActualWidth()? - padding.Left - padding.Right,
                    sum,
                    grid.ColumnSpacing()? * f64::from(defs.Size()?.saturating_sub(1)),
                )
            };
            let span = sum + gaps;
            Ok(if (span - inner).abs() <= 2.0 {
                String::new()
            } else {
                format!(
                    "children span {}dip of {}dip",
                    span.round() as i64,
                    inner.round() as i64
                )
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn cross_mode(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return Ok("<no such target>".to_string());
            };
            let grid = registry[i].clone();
            grid.UpdateLayout()?;
            let padding = grid.Padding()?;
            let (inner, origin) = if vertical {
                (grid.ActualWidth()? - padding.Left - padding.Right, padding.Left)
            } else {
                (grid.ActualHeight()? - padding.Top - padding.Bottom, padding.Top)
            };
            // The registry holds the Grid; the children live in
            // child_order under its WidgetId — recovered by COM
            // identity, the registries being creation-ordered clones.
            let id = core
                .widgets
                .iter()
                .find_map(|(id, w)| match w {
                    NativeWidget::Column(g) | NativeWidget::Row(g) if *g == grid => Some(*id),
                    _ => None,
                })
                .expect("registry grids live in the widget table");
            let empty = Vec::new();
            let order = core.child_order.get(&id).unwrap_or(&empty);
            let mut rects: Vec<(f64, f64)> = Vec::new();
            let mut baselines: Vec<f64> = Vec::new();
            for child in order {
                let Some(widget) = core.widgets.get(child) else {
                    continue;
                };
                let element: FrameworkElement = widget.element()?.cast()?;
                let at = element
                    .TransformToVisual(&grid)?
                    .TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
                let (start, extent) = if vertical {
                    (f64::from(at.X) - origin, element.ActualWidth()?)
                } else {
                    (f64::from(at.Y) - origin, element.ActualHeight()?)
                };
                rects.push((start, extent));
                if !vertical {
                    let baseline = match widget {
                        NativeWidget::Label(text) => Some(text.BaselineOffset()?),
                        NativeWidget::Button { caption, .. }
                        | NativeWidget::Checkbox { caption, .. } => {
                            let inner_at = caption
                                .TransformToVisual(&element)?
                                .TransformPoint(bindings::Windows::Foundation::Point {
                                    X: 0.0,
                                    Y: 0.0,
                                })?;
                            Some(f64::from(inner_at.Y) + caption.BaselineOffset()?)
                        }
                        _ => None,
                    };
                    if let Some(b) = baseline {
                        baselines.push(start + b);
                    }
                }
            }
            if rects.is_empty() {
                return Ok("no children".to_owned());
            }
            // Multi-match is ambiguity, and ambiguity fails loudly
            // — a first-match answer lets an unseparated scene pass
            // while proving nothing (the separability lesson, made
            // structural).
            let mut matches = Vec::new();
            if rects.iter().all(|r| (r.1 - inner).abs() <= 2.0) {
                matches.push("stretch");
            }
            if rects.iter().all(|r| r.0.abs() <= 2.0) {
                matches.push("start");
            }
            if rects.iter().all(|r| ((2.0 * r.0 + r.1) - inner).abs() <= 4.0) {
                matches.push("center");
            }
            if rects.iter().all(|r| ((r.0 + r.1) - inner).abs() <= 2.0) {
                matches.push("end");
            }
            if !vertical
                && baselines.len() >= 2
                && baselines.iter().all(|b| (b - baselines[0]).abs() <= 2.0)
            {
                matches.push("baseline");
            }
            Ok(match matches.as_slice() {
                [one] => (*one).to_owned(),
                // A baseline-looking row reading mixed is usually the
                // recording, not the geometry — name the recorded
                // count in the verdict.
                [] => {
                    let recorded = if vertical {
                        String::new()
                    } else {
                        format!("; {} baselines recorded", baselines.len())
                    };
                    format!("mixed (cross rects {rects:?} in {inner}dip{recorded})")
                }
                many => format!("ambiguous ({})", many.join("|")),
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn window_title(&self, window: u64) -> String {
        Self::on_ui_read(move |core| Ok(winui_window(core, window)?.Title()?.to_string()))
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn window_content_size(&self, window: u64) -> (f64, f64) {
        Self::on_ui_read(move |core| {
            // The XamlRoot's size IS the client area in DIP — the
            // same notion root_fills reads.
            let target = winui_window(core, window)?;
            let root: FrameworkElement = target.Content()?.cast()?;
            let area = root.XamlRoot()?.Size()?;
            Ok((f64::from(area.Width), f64::from(area.Height)))
        }).unwrap_or((f64::NAN, f64::NAN))
    }

    fn close_window(&self, window: u64) {
        Self::on_ui(move |core| {
            // The REAL chrome path: WM_CLOSE through the subclass, so
            // the veto grammar fires exactly as a user click would.
            // Posted, not sent — the WNDPROC re-enters CORE, and a
            // held borrow here would abort.
            let target = winui_window(core, window)?;
            let native: IWindowNative = windows_core::Interface::cast(&target)?;
            let hwnd = native.window_handle()?;
            unsafe {
                PostMessageW(hwnd, WM_CLOSE, 0, 0);
            }
            Ok(())
        })
    }

    fn window_count(&self) -> usize {
        Self::on_ui(move |core| Ok(1 + core.aux_windows.len()))
    }

    fn alert_title(&self, window: u64) -> Option<String> {
        Self::on_ui_read(move |core| {
            let Some(live) = core.live_alert.as_ref() else {
                return Ok(None);
            };
            if live.window != window {
                return Ok(None);
            }
            // Present-gated: the stored handle answers before the
            // popup is actually open, and an expect_alert that
            // passed then let alert_choose press a not-yet-
            // interactive dialog — the press dropped silently and
            // the alert never retired (caught live 2026-07-22).
            // IsLoaded flips when the dialog enters the tree, i.e.
            // when the popup is really up and pressable.
            if !live.dialog.IsLoaded()? {
                return Ok(None);
            }
            // The REAL dialog object's Title, never the request's
            // copy (boxed at present time; unbox through
            // IPropertyValue).
            let title: IReference<HSTRING> = live.dialog.Title()?.cast()?;
            Ok(Some(title.Value()?.to_string()))
        }).unwrap_or(None)
    }

    fn choose_alert(&self, choice: u32) {
        use bindings::Microsoft::UI::Xaml::Automation::Peers::{
            ButtonAutomationPeer, FrameworkElementAutomationPeer,
        };
        use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
        Self::on_ui(move |core| {
            let Some(live) = core.live_alert.as_ref() else {
                return Ok(());
            };
            if choice == crate::wire::ALERT_CHOICE_CANCEL {
                // The REAL dismissal path: Hide() completes ShowAsync
                // with None exactly as Esc or the close button does.
                live.dialog.Hide()?;
                return Ok(());
            }
            if choice as usize >= live.actions {
                return Ok(());
            }
            // The REAL press: the open dialog lives in the popup
            // layer; find its template button by part name and drive
            // its automation peer's Invoke — the click pipeline a
            // user's press runs (WinUI exposes no direct press).
            let part = if choice == 0 {
                "PrimaryButton"
            } else {
                "SecondaryButton"
            };
            let xaml_root = live.dialog.XamlRoot()?;
            let popups = VisualTreeHelper::GetOpenPopupsForXamlRoot(&xaml_root)?;
            for i in 0..popups.Size()? {
                let popup = popups.GetAt(i)?;
                let child: UIElement = popup.Child()?;
                if let Some(button) = find_template_button(&child, part)? {
                    let peer = FrameworkElementAutomationPeer::CreatePeerForElement(&button)?;
                    let peer: ButtonAutomationPeer = peer.cast()?;
                    peer.Invoke()?;
                    return Ok(());
                }
            }
            Ok(())
        })
    }

    fn entry_count(&self, window: u64) -> usize {
        Self::on_ui(move |core| Ok(core.nav_stacks.get(&window).map_or(0, Vec::len)))
    }

    fn back(&self, window: u64) {
        use bindings::Microsoft::UI::Xaml::Automation::Peers::{
            ButtonAutomationPeer, FrameworkElementAutomationPeer,
        };
        Self::on_ui(move |core| {
            // The REAL affordance: invoke the back bar's button
            // through its automation peer — the click pipeline a
            // user's press runs. Deferred one dispatcher tick: the
            // click handler re-borrows CORE, which this closure
            // holds.
            let Some(&top) = core.nav_stacks.get(&window).and_then(|s| s.last()) else {
                return Ok(());
            };
            let Some(back) = core
                .nav_entries
                .get(&top)
                .and_then(|e| e.back_button.clone())
            else {
                return Ok(());
            };
            // A COLLAPSED button is not an affordance. The automation
            // peer invokes it regardless of visibility, so without this
            // the harness could pop where the split arm has hidden the
            // bar, and the two-pane back rule would pass a test the
            // screen does not satisfy.
            let probe: UIElement = back.cast()?;
            if probe.Visibility()? != Visibility::Visible {
                return Ok(());
            }
            let queue = DispatcherQueue::GetForCurrentThread()?;
            let handler = DispatcherQueueHandler::new(move || {
                let peer = FrameworkElementAutomationPeer::CreatePeerForElement(&back)?;
                let peer: ButtonAutomationPeer = peer.cast()?;
                peer.Invoke()
            });
            queue.TryEnqueue(&handler)?;
            Ok(())
        })
    }

    fn progress_state(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.progresses.len()) else {
                return Ok("<no such target>".to_string());
            };
            let bar = &core.progresses[i];
            // The REAL control's state, never a model copy.
            Ok(if bar.IsIndeterminate()? {
                "indeterminate".to_string()
            } else {
                format!("{}%", (bar.Value()? * 100.0).round() as i64)
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn grid_columns(&self, t: crate::harness::Target, want: usize) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.grids.len()) else {
                return Ok("<no such target>".to_string());
            };
            let grid = &core.grids[i];
            // Geometry, never the model's columns copy: each cell's
            // leading edge in the grid's own space via
            // TransformToVisual; the distinct clusters ARE the
            // columns.
            let children = grid.Children()?;
            let mut edges: Vec<f64> = Vec::new();
            for k in 0..children.Size()? {
                let cell: UIElement = children.GetAt(k)?;
                let transform = cell.TransformToVisual(&grid.cast::<UIElement>()?)?;
                let origin = transform.TransformPoint(bindings::Windows::Foundation::Point {
                    X: 0.0,
                    Y: 0.0,
                })?;
                edges.push(f64::from(origin.X));
            }
            if edges.is_empty() {
                return Ok("no cells".to_string());
            }
            edges.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let mut clusters = 0;
            let mut last = f64::MIN;
            for x in edges {
                if clusters == 0 || x - last > 2.0 {
                    clusters += 1;
                    last = x;
                }
            }
            Ok(if clusters == want {
                String::new()
            } else {
                format!("{clusters} column edges, wanted {want}")
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn choose(&self, t: crate::harness::Target, index: usize) {
        Self::on_ui(move |core| {
            // The REAL selection route per kind: SetSelectedIndex
            // raises SelectionChanged exactly as a native pick does
            // (the quiet guard is off here), the slider's SetValue
            // stance.
            if t.kind == crate::harness::TargetKind::Radio {
                let i = crate::harness::resolve(t.index, core.radios.len());
                core.radios[i].SetSelectedIndex(index as i32)?;
                return Ok(());
            }
            let i = crate::harness::resolve(t.index, core.selects.len());
            core.selects[i].SetSelectedIndex(index as i32)?;
            Ok(())
        });
    }

    fn selected_label(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            if t.kind == crate::harness::TargetKind::Radio {
                // The REAL control's state: the selected row's string
                // out of the group's own Items vector.
                let Some(i) = crate::harness::try_resolve(t.index, core.radios.len()) else {
                    return Ok("<no such target>".to_string());
                };
                let group = &core.radios[i];
                let index = group.SelectedIndex()?;
                if index < 0 {
                    return Ok(String::new());
                }
                let value: IReference<HSTRING> =
                    windows_core::Interface::cast(&group.Items()?.GetAt(index as u32)?)?;
                return Ok(value.Value()?.to_string());
            }
            let Some(i) = crate::harness::try_resolve(t.index, core.selects.len()) else {
                return Ok("<no such target>".to_string());
            };
            let combo = &core.selects[i];
            // The REAL control's state: the selected row's string
            // content out of the ComboBox's items (see
            // select_options for why content is a string).
            let index = combo.SelectedIndex()?;
            if index < 0 {
                return Ok(String::new());
            }
            let item: ComboBoxItem =
                windows_core::Interface::cast(&combo.Items()?.GetAt(index as u32)?)?;
            let value: IReference<HSTRING> =
                windows_core::Interface::cast(&item.Content()?)?;
            Ok(value.Value()?.to_string())
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn scroll_overflow(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.scrolls.len()) else {
                return Ok("<no such target>".to_string());
            };
            let viewer = &core.scrolls[i];
            // The toolkit's own metrics: ScrollableHeight is the
            // overflow itself (extent minus viewport).
            let scrollable = viewer.ScrollableHeight()?;
            Ok(if scrollable > 2.0 {
                String::new()
            } else {
                format!(
                    "content {} in viewport {}",
                    viewer.ExtentHeight()?,
                    viewer.ViewportHeight()?
                )
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn scroll_end(&self, t: crate::harness::Target) {
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.scrolls.len());
            let viewer = &core.scrolls[i];
            // The REAL scrolling API: ChangeView is what scrollbars
            // and touch panning drive.
            let target = viewer.ScrollableHeight()?;
            let offset: IReference<f64> = PropertyValue::CreateDouble(target)?.cast()?;
            viewer.ChangeView(
                None::<&IReference<f64>>,
                &offset,
                None::<&IReference<f32>>,
            )?;
            Ok(())
        })
    }

    fn scroll_at_end(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.scrolls.len()) else {
                return Ok("<no such target>".to_string());
            };
            let viewer = &core.scrolls[i];
            let short = viewer.ScrollableHeight()? - viewer.VerticalOffset()?;
            Ok(if short.abs() <= 2.0 {
                String::new()
            } else {
                format!(
                    "content bottom {} vs viewport {}",
                    viewer.VerticalOffset()? + viewer.ViewportHeight()?,
                    viewer.ExtentHeight()?
                )
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn file_dialog_state(&self) -> Option<(String, Vec<String>)> {
        // The REAL dialog, read through the shell's own view — never
        // this backend's record of what it asked for. A picker aimed at
        // the wrong place, or filtered down to nothing, presents
        // perfectly and is useless.
        //
        // NOT over UI Automation, which cannot be used against this
        // dialog at all: attaching any automation client makes the
        // shell's DirectUI raise event notifications during message
        // dispatch, each one an outgoing COM call that Windows refuses
        // and turns into a NONCONTINUABLE structured exception. See
        // sample_folder_view for the measured stack.
        //
        // NOT through on_ui_read either: the picker is a #32770 the
        // shell owns, not a XAML object, and it runs on its own thread.
        let window = sampler::WINDOW.load(std::sync::atomic::Ordering::SeqCst);
        if window == 0 {
            return None;
        }
        // Ask, then wait briefly for the dialog's own thread to answer.
        // expect_file_dialog is itself a bounded retry, so a slow first
        // sample costs nothing but a second lap.
        unsafe { PostMessageW(window, sampler::SAMPLE, 0, 0) };
        for _ in 0..20 {
            if let Ok(slot) = sampler::VIEW.lock() {
                if let Some(state) = slot.as_ref() {
                    return Some(state.clone());
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        None
    }

    fn choose_file(&self, name: Option<&str>) {
        // POSTED, NEVER SENT. A SendMessage puts the receiving thread
        // into an input-synchronous call, and everything in this dialog
        // calls out over COM while handling messages — the file-name box
        // is backed by shell autocomplete, the buttons drive the shell
        // view. Windows refuses those callouts and raises
        // RPC_E_CANTCALLOUT_ININPUTSYNCCALL, which is fatal under a JVM
        // (sample_folder_view). Posting queues the message and returns,
        // leaving the dialog's thread in no special state at all.
        //
        // The observable is the dialog GOING AWAY, so that is what this
        // waits for rather than a return code: a press that lands before
        // the list is interactive is swallowed with no error anywhere,
        // and the leg would fail three steps later on an assertion about
        // the guest.
        for _ in 0..40 {
            let Some(dialog) = live_dialog() else { return };
            match name {
                // Named in the dialog's own file-name box rather than by
                // hit-testing a row: the rows are DirectUI items, not
                // windows, so there is nothing to click. Typed a
                // character at a time because WM_SETTEXT carries a
                // pointer, and only SendMessage marshals one.
                Some(file) => {
                    if let Some(edit) = dialog_control(dialog, ID_FILENAME, "Edit") {
                        unsafe { PostMessageW(edit, EM_SETSEL, 0, -1) };
                        for ch in file.encode_utf16() {
                            unsafe { PostMessageW(edit, WM_CHAR, ch as usize, 1) };
                        }
                    }
                    if let Some(ok) = dialog_control(dialog, ID_OK, "Button") {
                        unsafe { PostMessageW(ok, BM_CLICK, 0, 0) };
                    }
                }
                // Cancel is the empty list, faithfully: IDCANCEL,
                // pressed on the dialog's own button.
                None => {
                    if let Some(cancel) = dialog_control(dialog, ID_CANCEL, "Button") {
                        unsafe { PostMessageW(cancel, BM_CLICK, 0, 0) };
                    }
                }
            }
            for _ in 0..10 {
                std::thread::sleep(std::time::Duration::from_millis(50));
                if !file_dialog_is_up() {
                    return;
                }
            }
        }
    }

    /// The foreign WRITER: Windows PowerShell 5.1 as a child of this
    /// process — the guest runs in the interactive session (deploy-win
    /// launches through schtasks /it), so its children share the ONE
    /// real clipboard; an ssh-spawned tool would get a per-connection
    /// window station with a clipboard of its own (measured,
    /// docs/clipboard-plan.md §6). 5.1 and never pwsh: -AsHtml,
    /// -LiteralPath, -Format and -TextFormatType all vanish silently
    /// there — the script asserts the edition rather than assuming.
    ///
    /// AND IT WAITS UNTIL THE CONTENT IS REALLY THERE (the osascript
    /// lesson, §3): the script polls the pasteboard's own Contains*
    /// after writing and prints KAYA_SEEDED only when the seed is
    /// visible; a seed that does not verify makes everything after it
    /// race.
    fn clipboard_seed(&self, kind: &str, argument: &str) {
        let script = match kind {
            "text" => format!(
                "Set-Clipboard -Value '{a}'; \
                 foreach ($i in 1..50) {{ if ((Get-Clipboard -Raw) -eq '{a}') {{ 'KAYA_SEEDED'; exit }} ; Start-Sleep -Milliseconds 100 }}; 'KAYA_SEED_LOST'",
                a = ps_quote(argument)
            ),
            "html" => format!(
                "Add-Type -AssemblyName PresentationCore; \
                 Set-Clipboard -Value '{a}' -AsHtml; \
                 foreach ($i in 1..50) {{ if ([Windows.Clipboard]::ContainsText([Windows.TextDataFormat]::Html)) {{ 'KAYA_SEEDED'; exit }}; Start-Sleep -Milliseconds 100 }}; 'KAYA_SEED_LOST'",
                a = ps_quote(argument)
            ),
            "image" => format!(
                // Raw PNG bytes under the \"PNG\" registered format —
                // the same shape wl-copy -t image/png seeds on linux:
                // the seed writes the type the arm reads, and the
                // MemoryStream form writes EXACT bytes (a plain
                // string or object would ride WPF's serialized-object
                // path that only PowerShell can read back).
                "Add-Type -AssemblyName PresentationCore; \
                 $b = [IO.File]::ReadAllBytes('{a}'); \
                 $ms = New-Object IO.MemoryStream (,$b); \
                 [Windows.Clipboard]::SetData('PNG', $ms); \
                 foreach ($i in 1..50) {{ if ([Windows.Clipboard]::ContainsData('PNG')) {{ 'KAYA_SEEDED'; exit }}; Start-Sleep -Milliseconds 100 }}; 'KAYA_SEED_LOST'",
                a = ps_quote(argument)
            ),
            "files" => format!(
                "Add-Type -AssemblyName PresentationCore; \
                 Set-Clipboard -LiteralPath '{a}'; \
                 foreach ($i in 1..50) {{ if ([Windows.Clipboard]::ContainsFileDropList()) {{ 'KAYA_SEEDED'; exit }}; Start-Sleep -Milliseconds 100 }}; 'KAYA_SEED_LOST'",
                a = ps_quote(argument)
            ),
            custom => panic!(
                "kaya: clipboard_seed cannot write {custom:?} from outside the app — \
                 no stock tool writes an app-defined format, and a helper kaya wrote \
                 would be foreign in name only"
            ),
        };
        let out = run_powershell(&script);
        assert!(
            out.contains("KAYA_SEEDED"),
            "kaya: clipboard_seed {kind} never appeared on the clipboard: {out}"
        );
    }

    /// The foreign READER, per kind: text via Get-Clipboard -Raw;
    /// html via PresentationCore's GetText(Html) — NEVER Get-Clipboard
    /// -TextFormatType, which decodes the UTF-8 payload with the ANSI
    /// code page and corrupts non-ASCII irreversibly — with the
    /// CF_HTML fragment sliced out host-side by the same parser the
    /// arm uses; an image as its DECODED size through GDI+ (a real
    /// foreign decode of the PNG bytes, though a lenient one: both
    /// stock decoders accept a bad IDAT CRC, so the strict-decoder
    /// property lives on the linux lane alone — measured); files as
    /// the first entry's basename (pbpaste parity); custom as the
    /// exact bytes via GetData's MemoryStream.
    fn clipboard_read(&self, kind: &str) -> String {
        match kind {
            "text" => lf(run_powershell(
                "$t = Get-Clipboard -Raw; if ($null -ne $t) { $t }",
            ))
            .trim_end_matches('\n')
            .to_owned(),
            "html" => {
                let raw = run_powershell(
                    "Add-Type -AssemblyName PresentationCore; \
                     [Windows.Clipboard]::GetText([Windows.TextDataFormat]::Html)",
                );
                parse_cf_html(raw.as_bytes()).unwrap_or_default()
            }
            "image" => run_powershell(
                "Add-Type -AssemblyName PresentationCore; Add-Type -AssemblyName System.Drawing; \
                 $ms = [Windows.Clipboard]::GetData('PNG'); \
                 if ($ms) { try { $i = [System.Drawing.Image]::FromStream($ms); \"$($i.Width)x$($i.Height)\" } catch { \"<$($ms.Length) bytes of PNG that GDI+ rejects>\" } }",
            )
            .trim()
            .to_owned(),
            "files" => run_powershell(
                "$fd = Get-Clipboard -Format FileDropList; \
                 if ($fd) { ($fd | Select-Object -First 1).Name }",
            )
            .trim()
            .to_owned(),
            custom => run_powershell(&format!(
                "Add-Type -AssemblyName PresentationCore; \
                 $ms = [Windows.Clipboard]::GetData('{}'); \
                 if ($ms) {{ $b = New-Object byte[] $ms.Length; [void]$ms.Read($b, 0, $ms.Length); [Text.Encoding]::UTF8.GetString($b) }}",
                ps_quote(custom)
            ))
            .trim_end_matches("\r\n")
            .trim_end_matches('\n')
            .to_owned(),
        }
    }

    fn goto_directory(&self, path: &str) {
        // ARMED, NOT SET: a dialog reads its folder when it is shown, so
        // this stores it and the apply arm applies it — the same shape
        // as GTK and the SwiftUI interpreter, for the same reason.
        let path = path.to_owned();
        Self::on_ui(move |core| {
            *core.pending_dialog_dir.borrow_mut() = Some(path.clone());
            Ok(())
        });
    }

    fn alert_count(&self) -> usize {
        Self::on_ui(move |core| Ok(usize::from(core.live_alert.is_some())))
    }

    fn root_fills(&self) -> String {
        Self::on_ui_read(move |core| {
            // The mounted root is the window's Content; the content
            // island (XamlRoot) is the framework's own notion of the
            // area handed to it.
            let root: FrameworkElement = core.window.Content()?.cast()?;
            root.UpdateLayout()?;
            let area = root.XamlRoot()?.Size()?;
            let (width, height) = (root.ActualWidth()?, root.ActualHeight()?);
            // Within one device-independent pixel: rounding is not a hug.
            Ok(
                if (width - area.Width as f64).abs() <= 1.0
                    && (height - area.Height as f64).abs() <= 1.0
                {
                    String::new()
                } else {
                    format!(
                        "{}x{}dip inside {}x{}dip",
                        width as i64, height as i64, area.Width as i64, area.Height as i64,
                    )
                },
            )
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn section_count(&self) -> usize {
        // The REAL switcher's item collection, never the section map.
        Self::on_ui_read(|core| {
            Ok(core
                .section_navs
                .get(&0)
                .map(|nav| nav.MenuItems()?.Size().map(|n| n as usize))
                .transpose()?
                .unwrap_or(0))
        })
        .unwrap_or(0)
    }

    fn active_section_title(&self) -> String {
        // The selected item's OWN content string — the platform's
        // selection state, not the model mirror.
        Self::on_ui_read(|core| {
            use windows_core::Interface;
            let Some(nav) = core.section_navs.get(&0) else {
                return Ok(String::new());
            };
            let Ok(selected) = nav.SelectedItem() else {
                return Ok(String::new());
            };
            let Ok(item) = selected.cast::<NavigationViewItem>() else {
                return Ok(String::new());
            };
            let Ok(content) = item.Content() else {
                return Ok(String::new());
            };
            let Ok(text) = content.cast::<IReference<HSTRING>>() else {
                return Ok(String::new());
            };
            Ok(text.Value()?.to_string())
        })
        .unwrap_or_default()
    }

    fn select_section(&self, index: usize) {
        // The user's route: reconcile, move the switcher under the
        // swallow counter, and emit exactly once — the synchronous-
        // emit pattern set_text uses (SelectionChanged raises async).
        Self::on_ui_mut(move |core| {
            let ids = core.sections.get(&0).cloned().unwrap_or_default();
            let Some(&sid) = ids.get(index) else { return Ok(()) };
            if core.selected_sections.get(&0) == Some(&sid) {
                return Ok(());
            }
            core.selected_sections.insert(0, sid);
            core.scene
                .user_selected_section(WindowId(0), WindowId(sid));
            nav_set_selected(core, 0, sid)?;
            show_section_pane(core, 0, sid)?;
            core.occurrences.send(Occurrence::SectionSelected {
                window: WindowId(0),
                section: WindowId(sid),
            });
            Ok(())
        });
    }

    fn finish(&self, code: i32, verdict: &str) {
        if code == 0 {
            println!("{verdict}");
        } else {
            eprintln!("{verdict}");
        }
        // request_exit reads the UI thread's APP; hop before asking.
        Self::on_ui(move |_| {
            request_exit(code);
            Ok(())
        });
    }
}


/// The widget id behind a harness target, recovered by COM identity
/// from the creation-ordered registry (the cross_mode precedent).
/// Context anchors in the scenes are labels; other kinds join as
/// scenes demand them — an unwired kind fails loudly, never silently
/// (the is_focused stance).
// Harness-only, like GTK's context_anchor_id: its sole caller is the
// Stage impl and it speaks harness types.
#[cfg(feature = "harness")]
fn widget_id_for_target(core: &CoreState, t: crate::harness::Target) -> u64 {
    match t.kind {
        crate::harness::TargetKind::Label => {
            let i = crate::harness::resolve(t.index, core.labels.len());
            let block = core.labels[i].clone();
            core.widgets
                .iter()
                .find_map(|(id, w)| match w {
                    NativeWidget::Label(l) if *l == block => Some(id.0),
                    _ => None,
                })
                .expect("registry labels live in the widget table")
        }
        // ACCESSIBILITY needs every kind, not just the Label this
        // function was written for (it served context_open, which is
        // label-only). a11y_id/a11y_label are universal props, so
        // Stage::ax can target anything.
        //
        // The arm below used to be `panic!` for every non-Label kind,
        // which is how the WinUI accessibility read died on its first
        // live run (2026-07-25) — inside the UI closure, so the
        // dispatcher surfaced it as an opaque `RecvError` rather than
        // the message. Returning 0 makes the caller report "no such
        // target", which is a legible failure instead of a crash.
        //
        // NOT YET RESOLVED: the remaining kinds need real lookups.
        // Button and Checkbox are STRUCT variants ({ button, caption }
        // / { check, caption }), and core.buttons holds tags rather
        // than widgets, so this wants the same resolution the other
        // WinUI verbs use rather than a hand-rolled scan.
        _ => 0,
    }
}

/// Depth-first search for the ContentDialog template button with the
/// given part name (PrimaryButton/SecondaryButton) under an element —
/// how the runner presses the REAL button (see choose_alert).
fn find_template_button(
    element: &UIElement,
    part: &str,
) -> windows_core::Result<Option<Button>> {
    use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
    if let Ok(button) = element.cast::<Button>() {
        if let Ok(fe) = element.cast::<FrameworkElement>() {
            if fe.Name()?.to_string() == part {
                return Ok(Some(button));
            }
        }
    }
    let count = VisualTreeHelper::GetChildrenCount(element)?;
    for i in 0..count {
        let child = VisualTreeHelper::GetChild(element, i)?;
        if let Ok(child) = child.cast::<UIElement>() {
            if let Some(found) = find_template_button(&child, part)? {
                return Ok(Some(found));
            }
        }
    }
    Ok(None)
}
