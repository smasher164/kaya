//! The Android packaging: ONE APK hosts every scene, so this file is a
//! `mod` per scene plus a match on KAYA_SELFTEST. Android has no native
//! process entry, so this builds as a cdylib whose one exported symbol
//! is the JNI entry behind dev.kaya.Kaya.nativeStart.
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
#[path = "stall.rs"]
mod stall;
#[path = "nav.rs"]
mod nav;
mod split;
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
#[path = "menus.rs"]
mod menus;
#[path = "commands.rs"]
mod commands;
#[path = "a11y.rs"]
mod a11y;
#[path = "a11yrows.rs"]
mod a11yrows;
#[path = "filedialog.rs"]
mod filedialog;
#[path = "clipboard.rs"]
mod clipboard;
#[path = "save.rs"]
mod save;

#[path = "undo.rs"]
mod undo;

#[path = "dirty.rs"]
mod dirty;

#[path = "ranges.rs"]
mod ranges;

#[path = "styling.rs"]
mod styling;

#[path = "toolbar.rs"]
mod toolbar;

#[path = "typeface.rs"]
mod typeface;

#[path = "identity.rs"]
mod identity;

/// The scene selector: the emulator legs pass `--es KAYA_SELFTEST entry`.
/// A LEG NEEDS ITS ARM HERE — tools/check-stubs.sh and the panic below
/// hold that.
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
        Ok("confirm") => confirm::app(ctx),
        Ok("stall") => stall::app(ctx),
        Ok("nav") => nav::app(ctx),
        Ok("split") => split::app(ctx),
        // Two SCRIPTS, one app: `split` drives resizes this host cannot
        // perform, `listdetail` asserts the bare invariant at the width
        // the device picked.
        Ok("listdetail") => split::app(ctx),
        Ok("scroll") => scroll::app(ctx),
        Ok("progress") => progress::app(ctx),
        Ok("select") => select::app(ctx),
        Ok("radio") => radio::app(ctx),
        Ok("grid") => grid::app(ctx),
        Ok("textarea") => textarea::app(ctx),
        Ok("sections") => sections::app(ctx),
        Ok("menus") => menus::app(ctx),
        Ok("commands") => commands::app(ctx),
        Ok("a11y") => a11y::app(ctx),
        Ok("a11yrows") => a11yrows::app(ctx),
        Ok("filedialog") => filedialog::app(ctx),
        Ok("clipboard") => clipboard::app(ctx),
        Ok("save") => save::app(ctx),
        Ok("undo") => undo::app(ctx),
        Ok("dirty") => dirty::app(ctx),
        Ok("ranges") => ranges::app(ctx),
        Ok("styling") => styling::app(ctx),
        Ok("toolbar") => toolbar::app(ctx),
        // The typeface scene reads the vendored font's BYTES and its
        // default path is repo-relative, which no device has: the leg
        // pushes the file and names it in KAYA_FONT_FILE
        // (tools/android/run-emulator.sh).
        Ok("typeface") => typeface::app(ctx),
        // The identity scene reads the vendored MARK's bytes, the
        // typeface's story one asset over: its default path is
        // guests/assets/icons/kaya-mark.png, which is repo-relative and
        // so no device has it, and the leg pushes that declared file and
        // names the pushed copy in KAYA_ICON_FILE
        // (tools/android/run-emulator.sh).
        Ok("identity") => identity::app(ctx),
        // "1" is the selftest flag's original spelling, from before the
        // value doubled as a scene selector.
        Ok("1") | Err(_) => milestone2::app(ctx),
        Ok(other) => panic!(
            "kaya: no scene named {other:?} in this APK — the runner asked for a leg \
             the guest does not carry"
        ),
    }
}

#[cfg(target_os = "android")]
kaya::android_main!(app);
