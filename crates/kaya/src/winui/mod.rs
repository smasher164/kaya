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
    ContentDialogButton, ContentDialogResult, Grid, Image, ProgressBar, RowDefinition,
    RadioButtons, ScrollBarVisibility, ScrollMode, ScrollViewer, SelectionChangedEventHandler,
    Slider, TextBlock, TextBox, TextChangedEventHandler,
};
use bindings::Microsoft::UI::Xaml::{GridLength, GridUnitType, Thickness};
use bindings::Microsoft::UI::Xaml::Media::Imaging::BitmapImage;
use bindings::Windows::Foundation::{IReference, PropertyValue};
use bindings::Windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};
use bindings::Microsoft::UI::Xaml::{
    Application, ApplicationInitializationCallback, FocusState, FrameworkElement,
    RoutedEventHandler, UIElement, UnhandledExceptionEventHandler, Window,
};

use crate::protocol::{
    ApplyOp, CommandKind, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind,
    WindowId, WindowProp,
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
    window_roots: HashMap<u64, UIElement>,
    window_titles: HashMap<u64, String>,
    /// Sections (DESIGN.md, Sections): per-window ordered sets, pane
    /// containers by section id, and the selection mirror. The
    /// switcher is KAYA-OWNED chrome (a bar of Buttons over/beside a
    /// content Grid) — this backend's established stance: its nav
    /// back-affordance is a kaya-owned wrapper too, and the platform's
    /// NavigationView dies with stowed E_NOINTERFACE in dll-hosted
    /// guests (docs/deferred.md carries the upgrade). A section's
    /// pane swaps between its own root and its stack's top entry
    /// (stacks are per-surface; nav_stacks keys sections too).
    sections: HashMap<u64, Vec<u64>>,
    section_panes: HashMap<u64, WinSection>,
    /// Per-window: (the hint the chrome was built for, outer chrome
    /// Grid, the bar panel holding the switcher buttons, the content
    /// Grid the active pane fills). Built once and grown
    /// incrementally — XAML refuses re-parenting, so a rebuild (hint
    /// change only) detaches everything first.
    section_chrome: HashMap<u64, (i64, Grid, Grid, Grid)>,
    /// Per-section switcher button; the ACTIVE one is disabled — the
    /// real control state the harness reads back.
    section_buttons: HashMap<u64, Button>,
    selected_sections: HashMap<u64, u64>,
    sections_presentation: HashMap<u64, i64>,
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
// outer (KayaApplication) answers only its own interfaces and does not
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

fn drain_transactions() {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        while let Ok(tx) = core.transactions.try_recv() {
            for op in core.scene.apply(tx) {
                apply(core, op).expect("kaya: applying an op failed");
            }
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

/// Implement-scaffolding for the Application overrides interface: the
/// generator emits it caller-side only (it is exclusive-to
/// Application), so the trait, thunk, and vtable constructor the
/// #[implement] macro expects live here, mirroring the generator's own
/// pattern for IXamlMetadataProvider. The re-exports make the _Vtbl
/// and _Impl names resolvable as siblings of the interface path the
/// macro is given.
mod app_overrides {
    pub use super::bindings::Microsoft::UI::Xaml::IApplicationOverrides;
    pub use super::bindings::Microsoft::UI::Xaml::IApplicationOverrides_Vtbl;
    use super::bindings::Microsoft::UI::Xaml::LaunchActivatedEventArgs;

    // The generator emits RuntimeName only for public interfaces; the
    // implement macro needs it for IInspectable::GetRuntimeClassName.
    impl windows_core::RuntimeName for IApplicationOverrides {
        const NAME: &'static str = "Microsoft.UI.Xaml.IApplicationOverrides";
    }

    pub trait IApplicationOverrides_Impl: windows_core::IUnknownImpl {
        fn OnLaunched(
            &self,
            args: windows_core::Ref<'_, LaunchActivatedEventArgs>,
        ) -> windows_core::Result<()>;
    }

    impl IApplicationOverrides_Vtbl {
        pub const fn new<Identity: IApplicationOverrides_Impl, const OFFSET: isize>() -> Self {
            unsafe extern "system" fn OnLaunched<
                Identity: IApplicationOverrides_Impl,
                const OFFSET: isize,
            >(
                this: *mut core::ffi::c_void,
                args: *mut core::ffi::c_void,
            ) -> windows_core::HRESULT {
                unsafe {
                    let this: &Identity =
                        &*((this as *const *const ()).offset(OFFSET) as *const Identity);
                    IApplicationOverrides_Impl::OnLaunched(this, core::mem::transmute(&args))
                        .into()
                }
            }
            Self {
                base__: windows_core::IInspectable_Vtbl::new::<
                    Identity,
                    IApplicationOverrides,
                    OFFSET,
                >(),
                OnLaunched: OnLaunched::<Identity, OFFSET>,
            }
        }

        pub fn matches(iid: &windows_core::GUID) -> bool {
            iid == &<IApplicationOverrides as windows_core::Interface>::IID
        }
    }
}

/// The load-bearing piece of code-only WinUI: the XAML parser resolves
/// non-core types (TextCommandBarFlyout inside TextBox's built-in
/// style, everything in XamlControlsResources) through an
/// IXamlMetadataProvider it obtains by QIing the Application object —
/// normally the subclass the XAML compiler generates. Without one,
/// deferred theme XAML fail-fasts the process
/// (STOWED_EXCEPTION_80004005 ... XamlSchemaContext::
/// GetTypeInfoProvider — microsoft-ui-xaml discussions #7357/#8151).
/// This is that subclass, done the official way: the Application is
/// composed via COM aggregation with this object as the outer, which
/// answers IXamlMetadataProvider by delegating to the framework's own
/// XamlControlsXamlMetaDataProvider (prior art: windows-rs reactor,
/// compio-rs/winio).
#[windows_core::implement(
    app_overrides::IApplicationOverrides,
    bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider
)]
struct KayaApplication {
    // Lazily created: the provider activates WinUI machinery that is
    // not ready until the application object exists.
    provider: RefCell<Option<bindings::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider>>,
}

impl KayaApplication_Impl {
    fn provider(
        &self,
    ) -> windows_core::Result<bindings::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider>
    {
        let mut slot = self.provider.borrow_mut();
        if slot.is_none() {
            *slot = Some(
                bindings::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider::new()?,
            );
        }
        Ok(slot.as_ref().expect("just filled").clone())
    }
}

impl app_overrides::IApplicationOverrides_Impl for KayaApplication_Impl {
    fn OnLaunched(
        &self,
        _args: windows_core::Ref<'_, bindings::Microsoft::UI::Xaml::LaunchActivatedEventArgs>,
    ) -> windows_core::Result<()> {
        // Merge the framework's control resources once, at launch: a
        // code-only app has no App.xaml to do it, and while most
        // control templates happen to resolve without the merge,
        // ProgressBar's was the first to hit a missing theme key
        // ("Cannot find a Resource ... TabViewScrollButtonBackground",
        // 2026-07-22) — the research footnote from the entry work,
        // now load-bearing. Application.Current() is unusable here
        // (the composition trap: identity is the outer), so the
        // handle comes from the thread-local stashed at composition.
        //
        // The merge is TIERED because it cannot always load:
        // XamlControlsResources resolves through ms-appx, which needs
        // the exe-adjacent resources.pri — present for the scene
        // executables, structurally absent for dll-hosted guests
        // (python.exe, java.exe, dotnet, go: kaya.dll is not the
        // exe). Where the real merge fails, kaya logs and continues:
        // every control except ProgressBar resolves without it (the
        // dll-hosted ProgressBar gap is ledgered — app-scope stub
        // keys were tried and do NOT satisfy the realization walk;
        // it fail-fasts 0xC000027B regardless).
        APP.with_borrow(|app| -> windows_core::Result<()> {
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
        })?;
        // Scene setup runs via the dispatcher from run_core's
        // initialization callback.
        Ok(())
    }
}

impl bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Impl for KayaApplication_Impl {
    fn GetXamlType(
        &self,
        r#type: &bindings::Windows::UI::Xaml::Interop::TypeName,
    ) -> windows_core::Result<bindings::Microsoft::UI::Xaml::Markup::IXamlType> {
        self.provider()?.GetXamlType(r#type)
    }

    fn GetXamlTypeByFullName(
        &self,
        full_name: &windows_core::HSTRING,
    ) -> windows_core::Result<bindings::Microsoft::UI::Xaml::Markup::IXamlType> {
        self.provider()?.GetXamlTypeByFullName(full_name)
    }

    fn GetXmlnsDefinitions(
        &self,
    ) -> windows_core::Result<
        windows_core::Array<bindings::Microsoft::UI::Xaml::Markup::XmlnsDefinition>,
    > {
        self.provider()?.GetXmlnsDefinitions()
    }
}

/// Construct the Application composed with KayaApplication as the COM
/// aggregation outer: the returned instance is the framework object,
/// but identity QIs route to the outer, so the XAML parser finds
/// IXamlMetadataProvider. The outer and the returned inner reference
/// live for the process lifetime, matching the Application itself.
fn compose_application() -> windows_core::Result<Application> {
    use windows_core::Interface;
    let outer: windows_core::IInspectable = KayaApplication {
        provider: RefCell::new(None),
    }
    .into();
    let factory = windows_core::factory::<
        Application,
        bindings::Microsoft::UI::Xaml::IApplicationFactory,
    >()?;
    unsafe {
        let mut inner: *mut core::ffi::c_void = core::ptr::null_mut();
        let mut result: *mut core::ffi::c_void = core::ptr::null_mut();
        (Interface::vtable(&factory).CreateInstance)(
            Interface::as_raw(&factory),
            outer.as_raw(),
            &mut inner,
            &mut result,
        )
        .ok()?;
        // The composed pair must outlive this frame: the framework
        // holds the app for the process lifetime, and dropping our
        // references here would release the aggregation.
        std::mem::forget(outer);
        let _ = inner; // owned by the composition; never released by us
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
    match top.and_then(|id| core.nav_entries.get(&id)) {
        Some(entry) => {
            if let Some(wrapper) = &entry.wrapper {
                target.SetContent(wrapper)?;
            }
            target.SetTitle(&HSTRING::from(&*entry.title))?;
        }
        None => {
            if let Some(root) = core.window_roots.get(&window) {
                target.SetContent(root)?;
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

/// Assemble (or reassemble on a hint change) the window's sections
/// chrome — KAYA-OWNED, the back-bar precedent: a bar of switcher
/// Buttons over (hint `bar`) or beside (auto/`sidebar` — Left, the
/// ratified Windows default) a content Grid the active pane fills.
/// A button click is the USER route: it reconciles the core, swaps
/// the pane, re-marks the buttons, and emits — synchronously, no
/// async raises to swallow. The ACTIVE button is disabled: a real
/// control state, which is what the harness reads back.
fn refresh_sections(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    let ids = core.sections.get(&window).cloned().unwrap_or_default();
    if ids.is_empty() {
        return Ok(());
    }
    let hint = core
        .sections_presentation
        .get(&window)
        .copied()
        .unwrap_or(0);
    // A hint change is the ONE rebuild: detach the long-lived buttons
    // and panes from the old chrome first (XAML refuses a second
    // parent), then drop it.
    if matches!(core.section_chrome.get(&window), Some((h, ..)) if *h != hint) {
        for sid in &ids {
            if let Some(button) = core.section_buttons.get(sid) {
                let el: UIElement = button.cast()?;
                detach(&el)?;
            }
            if let Some(record) = core.section_panes.get(sid) {
                let el: UIElement = record.pane.cast()?;
                detach(&el)?;
            }
        }
        core.section_chrome.remove(&window);
    }
    let horizontal = hint == 1;
    if !core.section_chrome.contains_key(&window) {
        // Build once: bar + content in a 2-track Grid, the track axis
        // picked by the hint (`bar` = top row; auto/`sidebar` = the
        // leading column, the ratified Windows default).
        let outer = Grid::new()?;
        let bar = Grid::new()?;
        let content = Grid::new()?;
        if horizontal {
            let rows = outer.RowDefinitions()?;
            let bar_track = RowDefinition::new()?;
            bar_track.SetHeight(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
            rows.Append(&bar_track)?;
            let fill = RowDefinition::new()?;
            fill.SetHeight(GridLength { Value: 1.0, GridUnitType: GridUnitType::Star })?;
            rows.Append(&fill)?;
            let bar_el: FrameworkElement = bar.cast()?;
            Grid::SetRow(&bar_el, 0)?;
            let content_el: FrameworkElement = content.cast()?;
            Grid::SetRow(&content_el, 1)?;
        } else {
            let cols = outer.ColumnDefinitions()?;
            let bar_track = ColumnDefinition::new()?;
            bar_track.SetWidth(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
            cols.Append(&bar_track)?;
            let fill = ColumnDefinition::new()?;
            fill.SetWidth(GridLength { Value: 1.0, GridUnitType: GridUnitType::Star })?;
            cols.Append(&fill)?;
            let bar_el: FrameworkElement = bar.cast()?;
            Grid::SetColumn(&bar_el, 0)?;
            let content_el: FrameworkElement = content.cast()?;
            Grid::SetColumn(&content_el, 1)?;
        }
        outer.Children()?.Append(&bar)?;
        outer.Children()?.Append(&content)?;
        core.section_chrome
            .insert(window, (hint, outer.clone(), bar, content));
        let target = winui_window(core, window)?;
        target.SetContent(&outer)?;
    }
    // Grow the bar incrementally: a track + button per section not
    // yet appended (add order; ids never leave — the set is
    // append-only by grammar).
    let (_, _, bar, _) = core.section_chrome[&window].clone();
    for (i, sid) in ids.iter().enumerate() {
        if core.section_buttons.contains_key(sid) {
            continue;
        }
        if horizontal {
            let track = ColumnDefinition::new()?;
            track.SetWidth(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
            bar.ColumnDefinitions()?.Append(&track)?;
        } else {
            let track = RowDefinition::new()?;
            track.SetHeight(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
            bar.RowDefinitions()?.Append(&track)?;
        }
        let button = Button::new()?;
        let sid_copy = *sid;
        let handler = RoutedEventHandler::new(move |_, _| {
            // Fires from the message loop, never under an apply
            // borrow (the back-button precedent).
            let mut emit = None;
            CORE.with_borrow_mut(|core| -> windows_core::Result<()> {
                let Some(core) = core.as_mut() else { return Ok(()) };
                let Some(&window) = core
                    .section_panes
                    .get(&sid_copy)
                    .map(|record| &record.window)
                else {
                    return Ok(());
                };
                if core.selected_sections.get(&window) == Some(&sid_copy) {
                    return Ok(());
                }
                core.selected_sections.insert(window, sid_copy);
                core.scene
                    .user_selected_section(WindowId(window), WindowId(sid_copy));
                show_section_pane(core, window, sid_copy)?;
                mark_section_buttons(core, window)?;
                emit = Some(window);
                Ok(())
            })?;
            if let Some(window) = emit {
                CORE.with_borrow(|core| {
                    if let Some(core) = core.as_ref() {
                        core.occurrences.send(Occurrence::SectionSelected {
                            window: WindowId(window),
                            section: WindowId(sid_copy),
                        });
                    }
                });
            }
            Ok(())
        });
        button.Click(&handler)?;
        let caption = TextBlock::new()?;
        caption.SetText(&HSTRING::from(&*core.section_panes[sid].title))?;
        button.SetContent(&caption)?;
        let button_el: FrameworkElement = button.cast()?;
        if horizontal {
            Grid::SetColumn(&button_el, i as i32)?;
        } else {
            Grid::SetRow(&button_el, i as i32)?;
        }
        bar.Children()?.Append(&button)?;
        core.section_buttons.insert(*sid, button);
    }
    if let Some(sel) = core.selected_sections.get(&window).copied() {
        show_section_pane(core, window, sel)?;
        mark_section_buttons(core, window)?;
    }
    Ok(())
}

/// Remove an element from its current panel parent, if any — chrome
/// rebuilds re-home long-lived buttons and panes, and XAML refuses a
/// second parent ("Element is already the child of another element").
fn detach(element: &UIElement) -> windows_core::Result<()> {
    let framework: FrameworkElement = element.cast()?;
    let Ok(parent) = framework.Parent() else {
        return Ok(());
    };
    let Ok(panel) = parent.cast::<bindings::Microsoft::UI::Xaml::Controls::Panel>() else {
        return Ok(());
    };
    let children = panel.Children()?;
    let mut index = 0u32;
    if bool::from(children.IndexOf(element, &mut index)?) {
        children.RemoveAt(index)?;
    }
    Ok(())
}

/// Re-mark the switcher: the active section's button is DISABLED —
/// the selection state the harness's active-title read uses.
fn mark_section_buttons(core: &CoreState, window: u64) -> windows_core::Result<()> {
    let selected = core.selected_sections.get(&window).copied();
    for sid in core.sections.get(&window).cloned().unwrap_or_default() {
        if let Some(button) = core.section_buttons.get(&sid) {
            button.SetIsEnabled(Some(sid) != selected)?;
        }
    }
    Ok(())
}

/// Put the section's pane into the chrome's content slot.
fn show_section_pane(
    core: &CoreState,
    window: u64,
    section: u64,
) -> windows_core::Result<()> {
    let (Some((_, _, _, content)), Some(record)) = (
        core.section_chrome.get(&window),
        core.section_panes.get(&section),
    ) else {
        return Ok(());
    };
    let children = content.Children()?;
    children.Clear()?;
    let pane_el: UIElement = record.pane.cast()?;
    detach(&pane_el)?;
    children.Append(&pane_el)?;
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
                    // (see KayaApplication below) — without it the XAML
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
                core.section_buttons.remove(&sid);
                for entry in core.nav_stacks.remove(&sid).unwrap_or_default() {
                    core.nav_entries.remove(&entry);
                }
            }
            core.section_chrome.remove(&window.0);
            core.selected_sections.remove(&window.0);
            core.sections_presentation.remove(&window.0);
            core.window_roots.remove(&window.0);
            core.window_titles.remove(&window.0);
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
            // Programmatic and QUIET (the echo doctrine): the pane
            // swaps and the buttons re-mark; no user path is touched
            // and nothing emits.
            core.selected_sections.insert(window.0, section.0);
            show_section_pane(core, window.0, section.0)?;
            mark_section_buttons(core, window.0)?;
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
                    let caption = record.title.clone();
                    if let Some(button) = core.section_buttons.get(&section.0) {
                        let text = TextBlock::new()?;
                        text.SetText(&HSTRING::from(&*caption))?;
                        button.SetContent(&text)?;
                    }
                }
                // Day-one slot: accepted; the switcher TITLE is the
                // harness observable.
                (SectionProp::Icon, Value::Blob(_)) => {}
                (p, v) => unreachable!("scene validated section prop {p:?}/{v:?}"),
            }
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
                core.window.SetContent(&element)?;
                core.window_roots.insert(0, element);
            } else {
                let target = winui_window(core, window.0)?;
                target.SetContent(&element)?;
                // Mounting presents.
                target.Activate()?;
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
    fn GetDpiForWindow(hwnd: isize) -> u32;
    fn SetWindowLongPtrW(hwnd: isize, index: i32, value: isize) -> isize;
    fn CallWindowProcW(
        prev: isize,
        hwnd: isize,
        msg: u32,
        wparam: usize,
        lparam: isize,
    ) -> isize;
    fn DefWindowProcW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> isize;
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

    if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
        let scene = scene.trim().to_owned();
        eprintln!("kaya: winui selftest armed ({scene})");
        crate::harness::spawn(&scene, WinUiStage, |line| println!("{line}"));
    }

    CORE.with_borrow_mut(|core| {
        *core = Some(CoreState {
            transactions: tx_rx,
            scene: Scene::new(),
            occurrences: occ_tx,
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
            section_chrome: HashMap::new(),
            section_buttons: HashMap::new(),
            selected_sections: HashMap::new(),
            sections_presentation: HashMap::new(),
            nav_stacks: HashMap::new(),
            window_roots: HashMap::new(),
            window_titles: HashMap::new(),
            window_veto: HashMap::new(),
            tearing_down: std::collections::HashSet::new(),
            live_alert: None,
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
struct WinUiStage;

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

impl crate::harness::Stage for WinUiStage {
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
        // The REAL switcher bar's child count, never the section map.
        Self::on_ui_read(|core| {
            Ok(core
                .section_chrome
                .get(&0)
                .map(|(_, _, bar, _)| bar.Children()?.Size().map(|n| n as usize))
                .transpose()?
                .unwrap_or(0))
        })
        .unwrap_or(0)
    }

    fn active_section_title(&self) -> String {
        // The DISABLED button's caption — the real selection marker
        // on this backend's kaya-owned chrome.
        Self::on_ui_read(|core| {
            let ids = core.sections.get(&0).cloned().unwrap_or_default();
            for sid in ids {
                let Some(button) = core.section_buttons.get(&sid) else {
                    continue;
                };
                if !bool::from(button.IsEnabled()?) {
                    let content = button.Content()?;
                    if let Ok(text) = content.cast::<TextBlock>() {
                        return Ok(text.Text()?.to_string());
                    }
                }
            }
            Ok(String::new())
        })
        .unwrap_or_default()
    }

    fn select_section(&self, index: usize) {
        // The user's route: the same reconcile + re-mark + emit the
        // switcher button's Click runs, synchronously.
        Self::on_ui_mut(move |core| {
            let ids = core.sections.get(&0).cloned().unwrap_or_default();
            let Some(&sid) = ids.get(index) else { return Ok(()) };
            if core.selected_sections.get(&0) == Some(&sid) {
                return Ok(());
            }
            core.selected_sections.insert(0, sid);
            core.scene
                .user_selected_section(WindowId(0), WindowId(sid));
            show_section_pane(core, 0, sid)?;
            mark_section_buttons(core, 0)?;
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
