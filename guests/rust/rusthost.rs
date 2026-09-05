//! The Android packaging: ONE APK hosts every scene, as a cdylib whose one
//! exported symbol is the JNI entry behind dev.kaya.Kaya.nativeStart.
#![allow(dead_code)]

// Empty off Android so `cargo test` still builds every example.
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
#[path = "background.rs"]
mod background;
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

#[path = "table.rs"]
mod table;

#[path = "windowed.rs"]
mod windowed;

#[path = "identity.rs"]
mod identity;

#[path = "assets.rs"]
mod assets;

#[path = "canvas.rs"]
mod canvas;

#[path = "sizepolicy.rs"]
mod sizepolicy;

#[path = "adaptive.rs"]
mod adaptive;

#[path = "dnd.rs"]
mod dnd;

#[path = "pickers.rs"]
mod pickers;

#[path = "sliders.rs"]
mod sliders;

#[path = "tooltips.rs"]
mod tooltips;

/// A LEG NEEDS ITS ARM HERE — tools/check-stubs.py and the panic below
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
        // Two SCRIPTS, one app: this host cannot perform a resize.
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
        Ok("background") => background::app(ctx),
        Ok("save") => save::app(ctx),
        Ok("undo") => undo::app(ctx),
        Ok("dirty") => dirty::app(ctx),
        Ok("ranges") => ranges::app(ctx),
        Ok("styling") => styling::app(ctx),
        Ok("toolbar") => toolbar::app(ctx),
        Ok("table") => table::app(ctx),
        // The COMPILED windowed guest: ledger and varied are Python and
        // stop at the desktops.
        Ok("windowed") => windowed::app(ctx),
        Ok("canvas") => canvas::app(ctx),
        Ok("sizepolicy") => sizepolicy::app(ctx),
        // Narrower than the breakpoint and never resized: first-report arm.
        Ok("adaptive") => adaptive::app(ctx),
        Ok("dnd") => dnd::app(ctx),
        Ok("pickers") => pickers::app(ctx),
        Ok("sliders") => sliders::app(ctx),
        Ok("tooltips") => tooltips::app(ctx),
        // WHICH ROUTE THE CORE TAKES IS THE RUNNER'S CHOICE: this leg
        // arrives with a KAYA_ASSET_DIR and resolves through a directory.
        Ok("typeface") => typeface::app(ctx),
        // THE OTHER HALF DOES NOT COME THROUGH THE ASSET ROOT: the launcher
        // icon and android:label are baked by the BUILD.
        Ok("identity") => identity::app(ctx),
        // THE ONE LEG THAT RESOLVES OUT OF ITS OWN PACKAGE: no
        // KAYA_ASSET_DIR, so the core reads through the AssetManager.
        Ok("assets") => assets::app(ctx),
        // "1" is the selftest flag's original spelling.
        Ok("1") | Err(_) => milestone2::app(ctx),
        Ok(other) => panic!(
            "kaya: no scene named {other:?} in this APK — the runner asked for a leg \
             the guest does not carry"
        ),
    }
}

#[cfg(target_os = "android")]
kaya::android_main!(app);
