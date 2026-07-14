//! kaya: a cross-platform GUI library that wraps native widgets.
//!
//! Milestone 0: an AppKit skeleton proving the threading model and the
//! ring transport. See DESIGN.md at the repository root.

mod app;
mod protocol;
mod ring;

#[cfg(target_os = "macos")]
mod appkit;

#[cfg(target_os = "windows")]
mod winui;

#[cfg(any(target_os = "macos", target_os = "windows"))]
pub mod capi;

pub use app::AppCtx;
pub use protocol::{Command, Occurrence, WidgetId, skeleton};

#[cfg(target_os = "macos")]
pub(crate) use appkit as backend;
#[cfg(target_os = "windows")]
pub(crate) use winui as backend;

/// Start the core on the current thread (which must be the process main
/// thread) and run `app_main` on the app thread. Does not return.
#[cfg(any(target_os = "macos", target_os = "windows"))]
pub fn run(app_main: impl FnOnce(AppCtx) + Send + 'static) -> ! {
    use std::sync::mpsc;
    let (occ_tx, occ_rx) = mpsc::channel();
    let (cmd_tx, cmd_rx) = mpsc::channel();
    let ctx = AppCtx {
        occurrences: occ_rx,
        commands: cmd_tx,
    };
    std::thread::Builder::new()
        .name("kaya-app".into())
        .spawn(move || app_main(ctx))
        .expect("failed to spawn the app thread");
    std::process::exit(backend::run_core(protocol::OccSink::Mpsc(occ_tx), cmd_rx))
}
