//! kaya: a cross-platform GUI library that wraps native widgets.
//!
//! Milestone 0: an AppKit skeleton proving the threading model and the
//! ring transport. See DESIGN.md at the repository root.

mod app;
mod protocol;
mod ring;
mod scene;
mod wire;

#[cfg(target_os = "macos")]
mod appkit;

#[cfg(target_os = "windows")]
mod winui;

#[cfg(target_os = "linux")]
mod gtk;

#[cfg(target_os = "ios")]
mod uikit;

// Public because kaya::android_main! expands to a JNI entry in the app's
// own crate, which needs the module's types and start function.
#[cfg(target_os = "android")]
pub mod android;

#[cfg(target_os = "macos")]
mod swiftui_host;

#[cfg(any(
    target_os = "macos",
    target_os = "windows",
    target_os = "linux",
    target_os = "ios",
    target_os = "android"
))]
pub mod capi;

pub use app::{AppCtx, Tpl, Tx};
pub use protocol::{
    CollectionId, DEFAULT_WINDOW, Occurrence, Prop, SignalId, TemplateNodeId, Value, WidgetId,
    WidgetKind, WindowId,
};

#[cfg(target_os = "macos")]
pub(crate) use appkit as backend;
#[cfg(target_os = "windows")]
pub(crate) use winui as backend;
#[cfg(target_os = "linux")]
pub(crate) use gtk as backend;
#[cfg(target_os = "ios")]
pub(crate) use uikit as backend;
#[cfg(target_os = "android")]
pub(crate) use android as backend;

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
    use std::sync::mpsc;

    // Runtime backend selection (interim mechanism: environment). The
    // SwiftUI backend's Swift pump consumes commands through the C API's
    // channel, and its emissions are routed into this AppCtx's inbox.
    #[cfg(target_os = "macos")]
    if std::env::var("KAYA_BACKEND").as_deref() == Ok("swiftui") {
        let (occ_tx, occ_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, capi::presentation_tx_sender());
        std::thread::Builder::new()
            .name("kaya-app".into())
            .spawn(move || app_main(ctx))
            .expect("failed to spawn the app thread");
        capi::set_presentation_sink(protocol::OccSink::Mpsc(occ_tx));
        std::process::exit(swiftui_host::run());
    }

    let (occ_tx, occ_rx) = mpsc::channel();
    let (tx_tx, tx_rx) = mpsc::channel();
    let ctx = AppCtx::new(occ_rx, tx_tx);
    std::thread::Builder::new()
        .name("kaya-app".into())
        .spawn(move || app_main(ctx))
        .expect("failed to spawn the app thread");
    std::process::exit(backend::run_core(protocol::OccSink::Mpsc(occ_tx), tx_rx))
}
