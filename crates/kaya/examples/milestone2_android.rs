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
kaya::android_main!(milestone2::app);
