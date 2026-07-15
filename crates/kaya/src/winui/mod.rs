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

use windows_core::HSTRING;

use bindings::Microsoft::UI::Dispatching::{DispatcherQueue, DispatcherQueueHandler};
use bindings::Microsoft::UI::Xaml::Controls::{
    Button, StackPanel, TextBlock, TextBox, TextChangedEventHandler,
};
use bindings::Microsoft::UI::Xaml::{
    Application, ApplicationInitializationCallback, RoutedEventHandler, UIElement,
    UnhandledExceptionEventHandler, Window,
};

use crate::protocol::{
    ApplyOp, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind,
};
use crate::scene::Scene;

enum NativeWidget {
    Column(StackPanel),
    // The caption TextBlock is the button's text surface.
    Button { button: Button, caption: TextBlock },
    Label(TextBlock),
    Entry(TextBox),
}

impl NativeWidget {
    fn element(&self) -> windows_core::Result<UIElement> {
        use windows_core::Interface;
        match self {
            NativeWidget::Column(panel) => panel.cast(),
            NativeWidget::Button { button, .. } => button.cast(),
            NativeWidget::Label(label) => label.cast(),
            NativeWidget::Entry(field) => field.cast(),
        }
    }
}

struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    widgets: HashMap<WidgetId, NativeWidget>,
    // Which panel each widget sits in, for Destroy's detach.
    parents: HashMap<WidgetId, StackPanel>,
    // Click tags of the first and most recently created buttons, for the
    // selftest's round trip.
    selftest_button: Option<Vec<u8>>,
    selftest_last_button: Option<Vec<u8>>,
    selftest_label: Option<TextBlock>,
    selftest_entry: Option<TextBox>,
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

// The composed Application, kept from CreateInstance: the composition
// outer (KayaApplication) answers only its own interfaces and does not
// delegate QI to the inner, so Application::Current() — whose identity
// is the outer — cannot be cast back to Application. Everything the
// backend needs goes through this handle instead. UI thread only.
thread_local! {
    static APP: RefCell<Option<Application>> = const { RefCell::new(None) };
}

fn request_exit(code: i32) {
    EXIT_CODE.store(code, std::sync::atomic::Ordering::Relaxed);
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
                    // KNOWN LIMITATION (investigated 2026-07-15, VM
                    // evidence): rendering any TextBox in this
                    // unpackaged, code-only Application dies within
                    // ~1s of mount — a stowed exception (0xC000027B)
                    // inside Microsoft.UI.Xaml.dll 3.2.2 — regardless
                    // of resources.pri content, this minimal template,
                    // IsEnabled, or focus. Two real prerequisites were
                    // found and kept (MRT init needs an exe-adjacent
                    // resources.pri — the deploy ships
                    // tools/guest/minimal-resources.pri — and the
                    // default template's chrome resources cannot
                    // resolve, hence the minimal template below), but
                    // the remaining crash needs dump analysis or a
                    // different WinAppSDK runtime. Entry suites stay
                    // gated in deploy-win.sh.
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
                    if core.selftest_entry.is_none() {
                        core.selftest_entry = Some(field.clone());
                    }
                    NativeWidget::Entry(field)
                }
                WidgetKind::Column => NativeWidget::Column(StackPanel::new()?),
                WidgetKind::Button => {
                    let button = Button::new()?;
                    let caption = TextBlock::new()?;
                    button.SetContent(&caption)?;
                    let click_sink = core.occurrences.clone();
                    // The tag is the click's identity, emitted verbatim;
                    // this backend never learns what it means.
                    let tag = tag.expect("buttons carry a click tag");
                    if core.selftest_button.is_none() {
                        core.selftest_button = Some(tag.clone());
                    }
                    core.selftest_last_button = Some(tag.clone());
                    let handler = RoutedEventHandler::new(move |_, _| {
                        click_sink.send_click_tag(&tag);
                        Ok(())
                    });
                    button.Click(&handler)?;
                    NativeWidget::Button { button, caption }
                }
                WidgetKind::Label => {
                    let label = TextBlock::new()?;
                    if core.selftest_label.is_none() {
                        core.selftest_label = Some(label.clone());
                    }
                    NativeWidget::Label(label)
                }
            };
            core.widgets.insert(id, native);
        }
        ApplyOp::Destroy { id } => {
            let widget = core.widgets.remove(&id).expect("scene validated the id");
            if let Some(panel) = core.parents.remove(&id) {
                let children = panel.Children()?;
                let mut index = 0u32;
                if children.IndexOf(&widget.element()?, &mut index)? {
                    children.RemoveAt(index)?;
                }
            }
        }
        ApplyOp::SetProp { id, prop, value } => {
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
                (_, prop, value) => {
                    panic!("kaya: winui cannot apply {prop:?} = {value:?} here")
                }
            }
        }
        ApplyOp::AddChild { parent, child } => {
            let panel = match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(panel) => panel.clone(),
                _ => panic!("kaya: add_child parent is not a container"),
            };
            let children = panel.Children()?;
            match core.widgets.get(&child).expect("scene validated the id") {
                NativeWidget::Column(p) => children.Append(p)?,
                NativeWidget::Button { button, .. } => children.Append(button)?,
                NativeWidget::Label(label) => children.Append(label)?,
                NativeWidget::Entry(field) => children.Append(field)?,
            }
            core.parents.insert(child, panel);
        }
        ApplyOp::Mount { window: _, root } => {
            match core.widgets.get(&root).expect("scene validated the id") {
                NativeWidget::Column(panel) => core.window.SetContent(panel)?,
                NativeWidget::Button { button, .. } => core.window.SetContent(button)?,
                NativeWidget::Label(label) => core.window.SetContent(label)?,
                NativeWidget::Entry(field) => core.window.SetContent(field)?,
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

fn setup(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> windows_core::Result<()> {
    let window = Window::new()?;
    window.SetTitle(&HSTRING::from("kaya milestone 2"))?;

    // Closing the window exits the app, matching the AppKit backend's
    // terminate-after-last-window-closed behavior.
    let closed = bindings::Windows::Foundation::TypedEventHandler::new(|_, _| {
        request_exit(0);
        Ok(())
    });
    window.Closed(&closed)?;
    window.Activate()?;

    match std::env::var("KAYA_SELFTEST") {
        Ok(script) if script.trim() == "entry" => {
            eprintln!("kaya: winui selftest armed (entry)");
            spawn_entry_selftest();
        }
        Ok(script) => {
            eprintln!("kaya: winui selftest armed ({script:?})");
            spawn_selftest();
        }
        Err(_) => {}
    }

    CORE.with_borrow_mut(|core| {
        *core = Some(CoreState {
            transactions: tx_rx,
            scene: Scene::new(),
            occurrences: occ_tx,
            widgets: HashMap::new(),
            parents: HashMap::new(),
            selftest_button: None,
            selftest_last_button: None,
            selftest_label: None,
            selftest_entry: None,
            window,
        });
    });

    // The first transaction may already be queued; drain now.
    drain_transactions();
    Ok(())
}

/// Drives the round trip without a human. Uses the button's automation
/// invoke path once peers are bound; for the skeleton it performs the
/// click on the UI thread by raising the same handler path the pointer
/// would take.
fn spawn_selftest() {
    fn on_ui(f: impl Fn() -> windows_core::Result<()> + Send + 'static) {
        if let Some(dispatcher) = DISPATCHER.get() {
            let handler = DispatcherQueueHandler::new(move || f());
            let _ = dispatcher.0.TryEnqueue(&handler);
        }
    }

    std::thread::spawn(|| {
        // TODO(selftest): use ButtonAutomationPeer::Invoke once automation
        // bindings are generated, to exercise the real input path instead
        // of the handler's emission directly.
        let click_first = || {
            on_ui(|| {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    core.occurrences.send_click_tag(
                        core.selftest_button
                            .as_ref()
                            .expect("the scene has a button"),
                    );
                });
                Ok(())
            });
        };
        let click_last = || {
            on_ui(|| {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    core.occurrences.send_click_tag(
                        core.selftest_last_button
                            .as_ref()
                            .expect("the scene has stamped a button"),
                    );
                });
                Ok(())
            });
        };

        std::thread::sleep(std::time::Duration::from_millis(800));
        click_first();
        std::thread::sleep(std::time::Duration::from_millis(300));
        click_first();
        std::thread::sleep(std::time::Duration::from_millis(400));
        click_last();
        std::thread::sleep(std::time::Duration::from_millis(700));

        on_ui(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let text = core
                    .selftest_label
                    .as_ref()
                    .expect("the scene has a label")
                    .Text()?
                    .to_string();
                if text == "removed g2/a, 0 left" {
                    println!("KAYA_SELFTEST: OK ({text})");
                    request_exit(0);
                } else {
                    eprintln!("KAYA_SELFTEST: FAILED (label reads {text:?})");
                    request_exit(1);
                }
                Ok(())
            })
        });
    });
}

/// The entry scene's round trip (KAYA_SELFTEST=entry): SetText raises
/// TextChanged — the same path a keystroke takes — then the add button,
/// then the status label.
fn spawn_entry_selftest() {
    fn on_ui(f: impl Fn() -> windows_core::Result<()> + Send + 'static) {
        if let Some(dispatcher) = DISPATCHER.get() {
            let handler = DispatcherQueueHandler::new(move || f());
            let _ = dispatcher.0.TryEnqueue(&handler);
        }
    }

    std::thread::spawn(|| {
        eprintln!("kaya: winui selftest thread running");
        std::thread::sleep(std::time::Duration::from_millis(800));
        eprintln!("kaya: winui selftest step: set entry text");
        on_ui(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                core.selftest_entry
                    .as_ref()
                    .expect("the scene has an entry")
                    .SetText(&HSTRING::from("milk"))?;
                Ok(())
            })
        });
        std::thread::sleep(std::time::Duration::from_millis(300));
        eprintln!("kaya: winui selftest step: click add");
        on_ui(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                core.occurrences.send_click_tag(
                    core.selftest_button
                        .as_ref()
                        .expect("the scene has a button"),
                );
            });
            Ok(())
        });
        std::thread::sleep(std::time::Duration::from_millis(700));
        on_ui(|| {
            CORE.with_borrow(|core| {
                let core = core.as_ref().expect("core state initialized");
                let text = core
                    .selftest_label
                    .as_ref()
                    .expect("the scene has a label")
                    .Text()?
                    .to_string();
                if text == "added milk, 1 total" {
                    println!("KAYA_SELFTEST: OK ({text})");
                    request_exit(0);
                } else {
                    eprintln!("KAYA_SELFTEST: FAILED (label reads {text:?})");
                    request_exit(1);
                }
                Ok(())
            })
        });
    });
}
