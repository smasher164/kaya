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
    Button, CheckBox, ColumnDefinition, Grid, Image, RowDefinition, Slider, TextBlock, TextBox,
    TextChangedEventHandler,
};
use bindings::Microsoft::UI::Xaml::{GridLength, GridUnitType};
use bindings::Microsoft::UI::Xaml::Media::Imaging::BitmapImage;
use bindings::Windows::Foundation::{IReference, PropertyValue};
use bindings::Windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};
use bindings::Microsoft::UI::Xaml::{
    Application, ApplicationInitializationCallback, FocusState, FrameworkElement,
    RoutedEventHandler, UIElement, UnhandledExceptionEventHandler, Window,
};

use crate::protocol::{
    ApplyOp, CommandKind, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind,
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
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index. Clicks emit the stored
    // tag directly; the other controls fire their real events for
    // programmatic writes (SetIsChecked raises Checked, SetText raises
    // TextChanged, SetValue raises ValueChanged).
    buttons: Vec<Vec<u8>>,
    checkboxes: Vec<CheckBox>,
    labels: Vec<TextBlock>,
    entries: Vec<TextBox>,
    sliders: Vec<Slider>,
    images: Vec<Image>,
    columns: Vec<Grid>,
    rows: Vec<Grid>,
    window: Window,
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
        // Scene setup runs via the dispatcher from run_core's
        // initialization callback; nothing to do at launch.
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
                    let field_for_handler = field.clone();
                    let handler = TextChangedEventHandler::new(move |_, _| {
                        let text = field_for_handler.Text()?.to_string();
                        sink.send_text_tag(&tag, &text);
                        Ok(())
                    });
                    field.TextChanged(&handler)?;
                    core.entries.push(field.clone());
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
                    // (WinUI raises them for programmatic SetIsChecked
                    // too, which is what lets the selftest click like a
                    // user.) The caption is the CheckBox's content, the
                    // same shape as Button.
                    let check = CheckBox::new()?;
                    let caption = TextBlock::new()?;
                    check.SetContent(&caption)?;
                    let tag = tag.expect("checkboxes carry a tag");
                    let on_sink = core.occurrences.clone();
                    let on_tag = tag.clone();
                    let checked = RoutedEventHandler::new(move |_, _| {
                        on_sink.send_toggle_tag(&on_tag, true);
                        Ok(())
                    });
                    check.Checked(&checked)?;
                    let off_sink = core.occurrences.clone();
                    let off_tag = tag.clone();
                    let unchecked = RoutedEventHandler::new(move |_, _| {
                        off_sink.send_toggle_tag(&off_tag, false);
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
                    let handler = bindings::Microsoft::UI::Xaml::Controls::Primitives::RangeBaseValueChangedEventHandler::new(
                        move |_, args: windows_core::Ref<'_, bindings::Microsoft::UI::Xaml::Controls::Primitives::RangeBaseValueChangedEventArgs>| {
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
                }
                (NativeWidget::Entry(field), Prop::Text, Value::Str(s)) => {
                    field.SetText(&HSTRING::from(&s))?;
                }
                (NativeWidget::Checkbox { caption, .. }, Prop::Text, Value::Str(s)) => {
                    caption.SetText(&HSTRING::from(&s))?;
                }
                (NativeWidget::Checkbox { check, .. }, Prop::Checked, Value::Bool(b)) => {
                    let boxed: IReference<bool> =
                        PropertyValue::CreateBoolean(b)?.cast()?;
                    check.SetIsChecked(&boxed)?;
                }
                (NativeWidget::Slider(slider), Prop::Value, Value::F64(v)) => {
                    slider.SetValue(v)?;
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
            }
            core.parents.insert(child, panel);
            core.child_order.entry(parent).or_default().push(child);
            // A new child means a new track and a shifted set of indices.
            reindex(core, parent)?;
        }
        ApplyOp::Mount { window: _, root } => {
            match core.widgets.get(&root).expect("scene validated the id") {
                NativeWidget::Column(panel) | NativeWidget::Row(panel) => {
                    core.window.SetContent(panel)?
                }
                NativeWidget::Button { button, .. } => core.window.SetContent(button)?,
                NativeWidget::Label(label) => core.window.SetContent(label)?,
                NativeWidget::Entry(field) => core.window.SetContent(field)?,
                NativeWidget::Checkbox { check, .. } => core.window.SetContent(check)?,
                NativeWidget::Slider(slider) => core.window.SetContent(slider)?,
                NativeWidget::Image(image) => core.window.SetContent(image)?,
            }
        }
        ApplyOp::Command { id, command } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match command {
                CommandKind::Clear => {
                    let NativeWidget::Entry(field) = widget else {
                        panic!("kaya: clear on a non-entry (scene validates kinds)")
                    };
                    // WinUI raises TextChanged for programmatic SetText
                    // (the Create arm's comment), so the empty edit
                    // reaches the app through the entry's own path —
                    // no manual emit.
                    field.SetText(&HSTRING::new())?;
                }
                CommandKind::Focus => {
                    let _ = widget.element()?.Focus(FocusState::Programmatic)?;
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
                6 + (n % 2) * 512,
                6 + (n / 2) * 372,
                500,
                360,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
    }

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
            sliders: Vec::new(),
            images: Vec::new(),
            columns: Vec::new(),
            rows: Vec::new(),
            child_order: HashMap::new(),
            grow: HashMap::new(),
            window,
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
        let text = text.to_owned();
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.entries.len());
            core.entries[i].SetText(&HSTRING::from(&text))?;
            Ok(())
        });
    }

    fn read_label(&self, t: crate::harness::Target) -> String {
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.labels.len());
            Ok(core.labels[i].Text()?.to_string())
        })
    }

    fn read_text(&self, t: crate::harness::Target) -> String {
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.entries.len());
            Ok(core.entries[i].Text()?.to_string())
        })
    }

    fn image_size(&self, t: crate::harness::Target) -> String {
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.images.len());
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
    }

    fn is_focused(&self, t: crate::harness::Target) -> bool {
        Self::on_ui(move |core| {
            // The element's own FocusState, never FocusManager's global
            // focused element — per-window focus, so parallel tiled
            // legs cannot steal each other's assertion.
            match t.kind {
                crate::harness::TargetKind::Entry => {
                    let i = crate::harness::resolve(t.index, core.entries.len());
                    Ok(core.entries[i].FocusState()? != FocusState::Unfocused)
                }
                other => panic!("kaya: is_focused not wired for {other:?} on winui"),
            }
        })
    }

    fn child_texts(&self, t: crate::harness::Target) -> String {
        Self::on_ui(move |core| {
            let registry = if matches!(t.kind, crate::harness::TargetKind::Column) {
                &core.columns
            } else {
                &core.rows
            };
            let i = crate::harness::resolve(t.index, registry.len());
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
    }

    fn child_shares(&self, t: crate::harness::Target) -> String {
        Self::on_ui(move |core| {
            // Kind picks the registry and the definition axis (the
            // runner rejects any other kind before it gets here). The
            // first Windows run of the row assertion caught this method
            // still hard-wired to columns: row#0 resolved against the
            // COLUMNS registry and reported the column's own splits —
            // the registry-misresolution class, one backend short of a
            // clean sweep.
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let i = crate::harness::resolve(t.index, registry.len());
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
    }

    fn root_fills(&self) -> String {
        Self::on_ui(move |core| {
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
