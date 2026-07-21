//! kaya: a cross-platform GUI library that wraps native widgets.
//!
//! Milestone 0: an AppKit skeleton proving the threading model and the
//! ring transport. See DESIGN.md at the repository root.

mod app;
// The Rust-side harness serves the Rust-native backends (GTK, WinUI)
// and the unit tests; the interpreter platforms run their own Kotlin/
// Swift step runners against the shared .steps scripts.
#[cfg(any(target_os = "windows", target_os = "linux", test))]
mod harness;
mod protocol;
mod ring;
mod scene;
/// The protocol as data — the root document tools/kaya-bindgen walks.
pub mod spec;
mod wire;


#[cfg(target_os = "windows")]
mod winui;

#[cfg(target_os = "linux")]
mod gtk;


// Public because kaya::android_main! expands to a JNI entry in the app's
// own crate, which needs the module's types and start function.
#[cfg(target_os = "android")]
pub mod android;

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
// alias makes that path resolve inside the crate itself (examples and
// unit tests), the serde trick.
extern crate self as kaya;

pub use app::{
    AppCtx, Collection, Field, KayaCases, KayaField, KayaPatch, KayaRecord, KayaSum, Messages,
    PropToken, Tpl, TplSource, Tx, ValueKind, props,
};

/// The type's own shape is the schema: an enum derives the element
/// sum, a struct the one-variant case (with field tokens and the typed
/// patch builder).
pub use kaya_derive::KayaGen;
pub use protocol::{
    CollectionId, DEFAULT_WINDOW, Occurrence, Path, Prop, SignalId, TemplateNodeId, Value,
    ValueType, WidgetId, WidgetKind, WindowId,
};

#[cfg(target_os = "windows")]
pub(crate) use winui as backend;
#[cfg(target_os = "linux")]
pub(crate) use gtk as backend;
// Apple's and Android's backends are the SwiftUI and Compose
// interpreters: their pumps block in kaya_next_commands on the
// presentation channel itself, so a sent transaction IS the wakeup
// and the doorbell has nothing to ring.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "android"))]
pub(crate) mod backend {
    pub(crate) fn ring_doorbell() {}
}

/// Start the core on the current thread (which must be the process main
/// thread) and run `app_main` on the app thread. Does not return.
///
/// Not the entry point on Android, where the OS owns the process main
/// (Zygote forks it and an Activity is the way in): use
/// [`android_main!`](crate::android_main) and start from the Activity.
#[cfg(any(
    target_os = "macos",
    target_os = "windows",
    target_os = "linux",
    target_os = "ios",
    target_os = "android"
))]
pub fn run(app_main: impl FnOnce(AppCtx) + Send + 'static) -> ! {
    

    // One backend per platform. On Apple that is the SwiftUI
    // interpreter: its Swift pump consumes resolved commands through
    // the C API, its emissions route into this AppCtx's inbox, and
    // the host dylib takes the main thread (which Apple pins the UI
    // to regardless of toolkit).
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        let (occ_tx, occ_rx) = std::sync::mpsc::channel();
        let ctx = AppCtx::new(occ_rx, capi::presentation_tx_sender());
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
        let ctx = AppCtx::new(occ_rx, tx_tx);
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
