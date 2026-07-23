//! The Android packaging of milestone 0. The app logic is milestone2.rs,
//! pulled in as a module; only the entry differs, because Android has no
//! native process entry (Zygote forks the process and an Activity is the
//! way in). This builds as a cdylib whose one exported symbol is the JNI
//! entry behind dev.kaya.Kaya.nativeStart; milestone2's fn main comes
//! along but is never linked as an entry point.
#![allow(dead_code)]

// Empty on other targets so `cargo test` on the host still builds every
// example.
#[cfg(target_os = "android")]
#[path = "milestone2.rs"]
mod milestone2;

#[cfg(target_os = "android")]
#[path = "entry.rs"]
mod entry;

#[cfg(target_os = "android")]
#[path = "gallery.rs"]
mod gallery;

#[cfg(target_os = "android")]
#[path = "todos.rs"]
mod todos;

#[cfg(target_os = "android")]
#[path = "reorder.rs"]
mod reorder;

#[cfg(target_os = "android")]
#[path = "feed.rs"]
mod feed;

#[path = "layout.rs"]
mod layout;

#[path = "align.rs"]
mod align;
#[path = "grow.rs"]
mod grow;
#[path = "confirm.rs"]
mod confirm;
#[path = "nav.rs"]
mod nav;
#[path = "scroll.rs"]
mod scroll;
#[path = "progress.rs"]
mod progress;
#[path = "select.rs"]
mod select;
#[path = "radio.rs"]
mod radio;
#[path = "grid.rs"]
mod grid;
#[path = "textarea.rs"]
mod textarea;
#[path = "sections.rs"]
mod sections;

/// One APK hosts every scene: Android has one example app rather than
/// one binary per scene, so the selftest script doubles as the scene
/// selector (the emulator legs pass `--es KAYA_SELFTEST entry`).
#[cfg(target_os = "android")]
fn app(ctx: kaya::AppCtx) {
    match std::env::var("KAYA_SELFTEST").as_deref() {
        Ok("entry") => entry::app(ctx),
        Ok("gallery") => gallery::app(ctx),
        Ok("todos") => todos::app(ctx),
        Ok("reorder") => reorder::app(ctx),
        Ok("feed") => feed::app(ctx),
        Ok("layout") => layout::app(ctx),
        Ok("align") => align::app(ctx),
        Ok("grow") => grow::app(ctx),
        // Alerts are phone-native; confirm runs here for real.
        Ok("confirm") => confirm::app(ctx),
        // Navigation is phone-native too: predictive back IS the
        // affordance; nav runs here for real.
        Ok("nav") => nav::app(ctx),
        Ok("scroll") => scroll::app(ctx),
        Ok("progress") => progress::app(ctx),
        Ok("select") => select::app(ctx),
        Ok("radio") => radio::app(ctx),
        Ok("grid") => grid::app(ctx),
        Ok("textarea") => textarea::app(ctx),
        Ok("sections") => sections::app(ctx),
        _ => milestone2::app(ctx),
    }
}

#[cfg(target_os = "android")]
kaya::android_main!(app);
