//! kaya: a cross-platform GUI library that wraps native widgets.
//!
//! See DESIGN.md at the repository root.

mod app;
// Asset resolution: docs/assets-plan.md. Ungated on purpose — capi
// compiles on all five targets and every one can be handed a name.
mod assets;
mod brand;
// The canvas raster (docs/canvas-plan.md). Ungated for assets' reason:
// the core draws once and every platform blits, so every target compiles
// the rasterizer.
mod canvas;
// The nounwind boundaries' one report path (docs/deferred.md, "A GUARD
// THAT ABORTS THE PROCESS IS THE WRONG SHAPE"). Ungated for the reason
// assets is: every target has frames that cannot unwind.
mod fault;
#[cfg(any(target_os = "windows", target_os = "linux", test))]
#[cfg(feature = "harness")]
mod harness;
mod protocol;
mod ring;
// The row-windowing band machine (docs/virtualization-plan.md §1-§2);
// scene.rs owns the sites it keys on.
mod rowwindow;
mod scene;
// Not harness-gated: a shipped app is where an unreported stall costs
// the most (DESIGN.md, Threading model and protocol).
mod stall;
/// The protocol as data — the root document tools/kaya-bindgen walks.
pub mod spec;
// The harness's verb trace, gated exactly like harness: it is that
// module's alone, and a scripted-verb instrument is not something a
// shipped app carries.
#[cfg(any(target_os = "windows", target_os = "linux", test))]
#[cfg(feature = "harness")]
mod vtrace;
mod wire;


#[cfg(target_os = "windows")]
mod winui;

#[cfg(target_os = "linux")]
mod gtk;


// pub because kaya::android_main! expands to a JNI entry in the app's
// own crate, which needs the module's types and start function.
#[cfg(target_os = "android")]
pub mod android;

// The JVM guest tier's transport (the KayaRing natives).
#[cfg(any(
    target_os = "android",
    target_os = "macos",
    target_os = "windows",
    target_os = "linux"
))]
mod jvm;

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod swiftui_host;

#[cfg(any(
    target_os = "macos",
    target_os = "windows",
    target_os = "linux",
    target_os = "ios",
    target_os = "android"
))]
pub mod capi;

// The derive's generated code names types through `::kaya::...`; this
// alias makes that path resolve inside the crate itself.
extern crate self as kaya;

pub use app::{
    Accepts, ActionRef, Align, AnyAnchor, AppCtx, Axis, Asset, BarAnchor, BlobSource, Capabilities, Collection, ContextAnchor, ContextCatalog,
    capabilities,
    Field, ForScope, KayaCases, KayaField, KayaPatch, KayaRecord, KayaSum, MenuAnchor, MenuItemRef,
    MenuItems, MenuRef, MenuSource, Messages, OptionRef, PropToken, RadioGroupRef, RadioOptions,
    CatalogHome, MenuRole, Platform, Role, Sort, Symbol, ToggleRef, Tpl, TplSource, Tx, ValueKind,
    props,
};

/// The canvas surface (docs/canvas-plan.md §2.2).
pub use app::{Draw, FillRule, Paint, TextAlign, TextBaseline, Viewbox};

/// The type's own shape is the schema: an enum derives the element sum,
/// a struct the one-variant case.
pub use kaya_derive::KayaGen;
pub use protocol::{
    AlertChoice, AlertId, CollectionId, DEFAULT_WINDOW, EntryProp, MenuItemId, MenuItemKind,
    MenuProp, Occurrence, Path, Prop, SectionProp, SectionsPresentation, SignalId, TemplateNodeId,
    FileDialogId, FileMode, PickedFile, PickedId, Representation, UndoDelta, UndoText, Value,
    ValueType, WidgetId, WidgetKind, WindowId,
};

#[cfg(target_os = "windows")]
pub(crate) use winui as backend;
#[cfg(target_os = "linux")]
pub(crate) use gtk as backend;
// The SwiftUI and Compose pumps block in kaya_next_commands on the
// presentation channel itself, so a sent transaction IS the wakeup and
// the doorbell has nothing to ring.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
pub(crate) mod backend {
    pub(crate) fn ring_doorbell() {}
}

#[cfg(any(
    target_os = "macos",
    target_os = "windows",
    target_os = "linux",
    target_os = "ios",
    target_os = "android"
))]
/// The one spelling of "this backend has not reached that scene yet".
///
/// check-stubs and check-steps both read THIS CALL, never a sentence; a
/// backend that refuses in its own words fails check-stubs.
// Most callers are cfg'd out on any given build, so this looks dead.
#[allow(dead_code)]
pub(crate) fn depth_stub(scene: &str) -> ! {
    panic!(
        "kaya: the {scene} scene is not yet materialized on this backend — \
         it is a depth slice; see CLAUDE.md's sequencing"
    )
}

/// Start the core on the current thread (which must be the process main
/// thread) and run `app_main` on the app thread. Does not return.
///
/// Not the entry point on Android, where the OS owns the process main:
/// use [`android_main!`](crate::android_main) and start from an Activity.
pub fn run(app_main: impl FnOnce(AppCtx) + Send + 'static) -> ! {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        let (occ_tx, occ_rx) = std::sync::mpsc::channel();
        let ctx = AppCtx::new(occ_rx, capi::presentation_tx_sender(), occ_tx.clone());
        std::thread::Builder::new()
            .name("kaya-app".into())
            .spawn(move || app_main(ctx))
            .expect("failed to spawn the app thread");
        capi::set_presentation_sink(protocol::OccSink::Mpsc(occ_tx));
        std::process::exit(swiftui_host::run());
    }

    #[cfg(any(target_os = "windows", target_os = "linux"))]
    {
        let (occ_tx, occ_rx) = std::sync::mpsc::channel();
        let (tx_tx, tx_rx) = std::sync::mpsc::channel();
        let ctx = AppCtx::new(occ_rx, tx_tx, occ_tx.clone());
        std::thread::Builder::new()
            .name("kaya-app".into())
            .spawn(move || app_main(ctx))
            .expect("failed to spawn the app thread");
        std::process::exit(backend::run_core(protocol::OccSink::Mpsc(occ_tx), tx_rx))
    }

    #[cfg(target_os = "android")]
    {
        let _ = app_main;
        panic!(
            "Android owns the process entry; start the core from an Activity via kaya::android_main!"
        )
    }
}
