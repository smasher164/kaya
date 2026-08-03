// GdkClipProbe — what does GDK4 actually charge for the five
// representations, and does a FOREIGN reader see what it wrote?
//
// THE PREVIOUS PROBE ANSWERED A DIFFERENT QUESTION. tools/linux/clipprobe
// asked which compositor lets the harness read the clipboard from
// outside (answer: sway, via data-control). It never touched the
// BACKEND's side. These are the unknowns the GTK arm turns on, and every
// platform so far has overturned an assumption here.
//
// RUN 1 (2026-08-02) answered Q1 and Q6 and found the blocker: a union
// provider advertises all four representations, an unsatisfiable read
// fails in 0ms, and every foreign read saw NOTHING while GDK reported
// the content set. sway's debug log named the mechanism:
//
//   [wlr_data_device.c] Rejecting set_selection request,
//                       serial 0 was never given to client
//
// Wayland lets a client take the selection only with a serial from an
// input event it was sent, and the lane's seat has NO capabilities
// (headless backend, no input devices), so no client can ever hold
// one. The compositor drops the write and tells the client nothing;
// GDK's own formats() still reports everything.
//
// RUN 2 ruled out candidate 3 and the modifier tap: a mapped, settled
// window's set was still rejected, and `wtype -M shift -m shift`
// changed nothing (a modifier change is not a key event).
//
// RUN 3 settled the mechanism: with a virtual keyboard held open from
// before the window mapped (seat gains the keyboard capability, the
// focused window gets wl_keyboard.enter), the ENTER serial alone was
// still not enough — but ONE REAL KEY EVENT (`wtype -k F24`) was.
// After the tap, the foreign reader listed every representation. Run 3
// then hung, which is its own finding: --list-types is answered by the
// compositor from the offer, but reading DATA needs the owner's main
// loop to serve bytes, and the probe's synchronous wl-paste wait had
// blocked that loop. (The lane never has this shape — the foreign
// reader lives in the runner's process — but the probe reads in
// threads from here on, and carries a safety exit.)
//
// THIS RUN decides the lane recipe's shape and finishes the battery:
//
// QA ONE-SHOT PRIMER, no session holder. `wtype -P F24 -s 800 -p F24`:
//    the virtual keyboard is created on the spot, F24 held 800ms, then
//    released, keyboard destroyed. The press may race GDK's late
//    wl_keyboard bind; the release at +800ms should not. If the
//    foreign reader sees content after this, one self-contained wtype
//    call per leg is the whole recipe.
//
// QB HOLDER + TAP (run 3's proven configuration), as the control and
//    fallback: hold a keyboard open, tap F24, set again.
//
// Q2 HTML's mime type: raw UTF-8 under `text/html`, or does a consumer
//    need the ;charset=utf-8 alias?
// Q3 image: do raw PNG bytes round-trip byte-identical?
// Q4 files: text/uri-list, CRLF-separated, foreign read intact?
// Q5 custom: do the bytes survive under `dev.kaya.note`?
//
// Throwaway; nothing builds or runs this but a human. Answers land on
// stdout under "PROBE". Run via run.sh, which greps sway's debug log
// for set_selection rejections afterwards.

use gtk4::gdk;
use gtk4::glib;
use gtk4::prelude::*;

const PIXEL_PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, // 4 x 4
    0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09, // 8-bit rgb + crc
    0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41, // IDAT length + type
    0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x47, 0x48, 0x4C, 0x74, 0xDE, 0x7F, 0x24, 0x00,
    0x00, 0xD2, 0x6F, 0x17, 0xE9, 0x51, 0xBB, 0x23,
    0x2D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82, // IEND + crc
];

fn say(line: &str) {
    println!("PROBE {line}");
}

/// What a FOREIGN process sees — the whole point. wl-paste is the
/// lane's reader and is not ours, so anything it cannot see is not
/// really on the clipboard. MUST NOT be called on the main thread once
/// this process owns the selection: serving the data needs the main
/// loop (run 3's deadlock).
fn foreign(args: &[&str]) -> String {
    match std::process::Command::new("wl-paste").args(args).output() {
        Ok(out) => {
            let mut text = String::from_utf8_lossy(&out.stdout).trim_end().to_owned();
            if text.is_empty() && !out.stderr.is_empty() {
                text = format!("<none: {}>", String::from_utf8_lossy(&out.stderr).trim_end());
            }
            // An empty success and a failed transfer must read
            // differently: run 4's custom read printed '' and the exit
            // status was the only place the truth could have lived.
            if !out.status.success() {
                text.push_str(&format!(" [exit {}]", out.status.code().unwrap_or(-1)));
            }
            text
        }
        Err(e) => format!("<wl-paste failed: {e}>"),
    }
}

fn wtype(label: &str, args: &[&str]) {
    match std::process::Command::new("wtype").args(args).output() {
        Ok(o) if o.status.success() => say(&format!("{label}: ok")),
        Ok(o) => say(&format!(
            "{label} FAILED: {}",
            String::from_utf8_lossy(&o.stderr).trim_end()
        )),
        Err(e) => say(&format!("{label} MISSING: {e}")),
    }
}

/// One item, four representations — rebuilt per set because a provider
/// is consumed by the claim.
fn union_of_four() -> gdk::ContentProvider {
    let text = gdk::ContentProvider::for_value(&"kaya clip".to_value());
    let html = gdk::ContentProvider::for_bytes(
        "text/html",
        &glib::Bytes::from_static(b"<b>kaya</b> clip"),
    );
    let image = gdk::ContentProvider::for_bytes(
        "image/png",
        &glib::Bytes::from_static(PIXEL_PNG),
    );
    let custom = gdk::ContentProvider::for_bytes(
        "dev.kaya.note",
        &glib::Bytes::from_static(b"note=1"),
    );
    gdk::ContentProvider::new_union(&[text, html, image, custom])
}

/// One measurement cell: set the provider at `t`, foreign-read
/// `read_type` (off the main thread) at `t+2`.
fn case(
    t: u32,
    label: &'static str,
    mk: impl Fn() -> gdk::ContentProvider + 'static,
    read_type: &'static str,
) {
    at(t, move || {
        let clipboard = gdk::Display::default().unwrap().clipboard();
        match clipboard.set_content(Some(&mk())) {
            Ok(()) => say(&format!("{label}: set Ok")),
            Err(e) => say(&format!("{label}: set FAILED: {e}")),
        }
    });
    at(t + 1, move || {
        std::thread::spawn(move || {
            say(&format!(
                "{label}: targets: {}",
                foreign(&["--list-types"]).replace('\n', " ")
            ));
            say(&format!("{label}: read: '{}'", foreign(&["-t", read_type])));
        });
    });
}

/// Main-loop scheduling sugar: run `f` on the GTK main loop `secs` from
/// now, once.
fn at(secs: u32, f: impl FnOnce() + 'static) {
    let cell = std::cell::Cell::new(Some(f));
    glib::timeout_add_seconds_local(secs, move || {
        if let Some(f) = cell.take() {
            f();
        }
        glib::ControlFlow::Break
    });
}

fn main() {
    let app = gtk4::Application::builder()
        .application_id("dev.kaya.gdkclipprobe")
        .build();

    app.connect_activate(|app| {
        // A real window: a Wayland client with no surface gets no seat,
        // and without a seat there is no data device (the lesson the
        // Weston finding already paid for).
        let window = gtk4::ApplicationWindow::builder()
            .application(app)
            .title("gdkclipprobe")
            .build();

        // Instrumentation: does ANY key event reach this window? A key
        // that arrives and does not help reads differently from a key
        // that never arrives.
        let keys = gtk4::EventControllerKey::new();
        keys.connect_key_pressed(|_, keyval, keycode, _| {
            say(&format!(
                "KEY pressed: keyval={} keycode={keycode}",
                keyval.name().map(|n| n.to_string()).unwrap_or_default()
            ));
            glib::Propagation::Proceed
        });
        keys.connect_key_released(|_, keyval, keycode, _| {
            say(&format!(
                "KEY released: keyval={} keycode={keycode}",
                keyval.name().map(|n| n.to_string()).unwrap_or_default()
            ));
        });
        window.add_controller(keys);
        window.present();

        // The one-shot primer, proven by run 4: the press races GDK's
        // late wl_keyboard bind and is lost; the release at +800ms
        // arrives after it and its serial is what GDK spends. The
        // serial stayed valid even after wtype's device was removed.
        at(1, || {
            std::thread::spawn(|| {
                wtype(
                    "primer wtype -P F24 -s 800 -p F24",
                    &["-P", "F24", "-s", "800", "-p", "F24"],
                );
            });
        });

        // --- Q5, isolated: why does the custom type serve EMPTY? -----
        // Run 4: dev.kaya.note ADVERTISED in the union, read returned
        // zero bytes, no error — while image/png through the same
        // union served byte-identical. Run 5's 2x2 ({union, sole} x
        // {slashless, slashed}) pinned it: the union is innocent, and
        // a for_bytes type WITHOUT A SLASH is advertised but never
        // served. GDK's serving path interns the requested type as a
        // mime type, and a string with no slash fails the interning
        // and is dropped with the fd closed — zero bytes, exit 0.
        //
        // THIS RUN: does the MINIMAL slash satisfy it — `dev.kaya/note`,
        // the scene's id with one slash added, no other respelling?
        // The subtype-first spelling matters because the scene id is
        // byte-compared on every platform, so the cheapest respelling
        // that GDK serves is the one worth knowing about.
        case(3, "C5 sole dev.kaya/note", || {
            gdk::ContentProvider::for_bytes(
                "dev.kaya/note",
                &glib::Bytes::from_static(b"note=1"),
            )
        }, "dev.kaya/note");
        case(6, "C6 union with dev.kaya/note", || {
            let text = gdk::ContentProvider::for_value(&"kaya clip".to_value());
            let custom = gdk::ContentProvider::for_bytes(
                "dev.kaya/note",
                &glib::Bytes::from_static(b"note=1"),
            );
            gdk::ContentProvider::new_union(&[text, custom])
        }, "dev.kaya/note");

        at(9, || {
            say("==== end");
            std::process::exit(0);
        });

        // A probe that can wedge measures nothing twice. Run 3 hung on
        // its own deadlock; whatever goes wrong above, this run ends.
        at(30, || {
            say("SAFETY: 30s elapsed without the battery finishing — something wedged");
            say("==== end");
            std::process::exit(1);
        });
    });

    say("==== begin");
    app.run_with_args::<&str>(&[]);
}
