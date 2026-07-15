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

/// One APK hosts both scenes: Android has one example app rather than
/// one binary per scene, so the selftest script doubles as the scene
/// selector (the emulator legs pass `--es KAYA_SELFTEST entry`).
#[cfg(target_os = "android")]
fn app(ctx: kaya::AppCtx) {
    if std::env::var("KAYA_SELFTEST").as_deref() == Ok("entry") {
        entry::app(ctx)
    } else {
        milestone2::app(ctx)
    }
}

#[cfg(target_os = "android")]
kaya::android_main!(app);
