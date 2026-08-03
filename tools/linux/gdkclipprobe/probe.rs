// GdkClipProbe — what does GDK4 actually charge for the five
// representations, and does a FOREIGN reader see what it wrote?
//
// THE PREVIOUS PROBE ANSWERED A DIFFERENT QUESTION. tools/linux/clipprobe
// asked which compositor lets the harness read the clipboard from
// outside (answer: sway, via data-control). It never touched the
// BACKEND's side. These are the unknowns the GTK arm turns on, and every
// platform so far has overturned an assumption here.
//
// Q1 OFFERING SEVERAL AT ONCE. kaya's clip is one item in several types.
//    GDK models content as a GdkContentProvider; the union constructor
//    is meant to merge several. Does a union of text + html + image +
//    custom really advertise all four targets, or does the last one win?
//
// Q2 HTML'S MIME TYPE AND ENCODING. Windows needs CF_HTML's offset
//    header. Linux is believed to want raw UTF-8 under `text/html`, but
//    GTK also ships `text/html;charset=utf-8` in places, and a consumer
//    that asked for the bare type would find nothing. Which does a
//    foreign reader see?
//
// Q3 IMAGE: BYTES OR TEXTURE. macOS lost PNG bytes when they went
//    through NSImage (writeObjects declares TIFF alone). GDK has the
//    same fork: GdkTexture (re-encoded on demand) versus raw bytes under
//    `image/png`. Does the byte path round-trip byte-identical, and does
//    wl-paste see `image/png` either way?
//
// Q4 FILES. `text/uri-list` with file:// URIs, CRLF-separated per the
//    RFC. Does GTK add the trailing CRLF, and does a foreign reader
//    accept it without one?
//
// Q5 CUSTOM. An app-defined mime type carried verbatim. Does GDK let a
//    provider advertise an arbitrary type, and do the bytes survive?
//
// Q6 THE READ IS ASYNC. gdk_clipboard_read_async answers on the main
//    loop. kaya's read is "answered exactly once", so the arm has to
//    bridge async-to-once. Does a read of a type nothing offers fail
//    fast, or hang? (An empty answer is the universal no; a HANG is a
//    wedged leg.)
//
// Throwaway; nothing builds or runs this but a human. Answers land on
// stdout under "PROBE". Build inside the lane's image:
//   rustc --edition 2021 probe.rs $(pkg-config --cflags --libs gtk4) ...
// or more simply, run it as a cargo example against the gtk4 crate the
// backend already depends on.

use gtk4::gdk;
use gtk4::glib;
use gtk4::prelude::*;

const PIXEL_PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09,
    0x29, 0x00, 0x00, 0x00, 0x1C, 0x49, 0x44, 0x41, 0x54, 0x18, 0x57, 0x63, 0xFC, 0xCF, 0xC0, 0xF0,
    0x9F, 0x81, 0xE1, 0x3F, 0x03, 0xC3, 0x7F, 0x06, 0x86, 0xFF, 0x0C, 0x0C, 0xFF, 0x19, 0x18, 0xFE,
    0x33, 0x30, 0x00, 0x00, 0x3D, 0x94, 0x07, 0xF9, 0x8A, 0x2C, 0xEA, 0x84, 0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

fn say(line: &str) {
    println!("PROBE {line}");
}

/// What a FOREIGN process sees — the whole point. wl-paste is the
/// lane's reader and is not ours, so anything it cannot see is not
/// really on the clipboard.
fn foreign(args: &[&str]) -> String {
    match std::process::Command::new("wl-paste").args(args).output() {
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout).trim_end().to_owned();
            if text.is_empty() && !out.stderr.is_empty() {
                format!("<none: {}>", String::from_utf8_lossy(&out.stderr).trim_end())
            } else {
                text
            }
        }
        Err(e) => format!("<wl-paste failed: {e}>"),
    }
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
        window.present();

        let clipboard = gtk4::prelude::WidgetExt::display(&window).clipboard();

        // --- Q1/Q2/Q3/Q5: offer four representations at once --------
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
        let union = gdk::ContentProvider::new_union(&[text, html, image, custom]);
        match clipboard.set_content(Some(&union)) {
            Ok(()) => say("Q1 set_content(union of 4) returned Ok"),
            Err(e) => say(&format!("Q1 set_content FAILED: {e}")),
        }

        // What the union advertises, as GDK sees it and as the
        // compositor hands it to a foreign client. These two disagreeing
        // is the answer that would change the arm.
        say(&format!(
            "Q1 gdk formats: {}",
            clipboard.formats().to_string()
        ));
        glib::timeout_add_seconds_local(1, {
            let app = app.clone();
            move || {
                say(&format!("Q1 foreign targets: {}", foreign(&["--list-types"])));
                say(&format!("Q2 foreign text/html: '{}'", foreign(&["-t", "text/html"])));
                say(&format!(
                    "Q2 foreign text/html;charset=utf-8: '{}'",
                    foreign(&["-t", "text/html;charset=utf-8"])
                ));
                say(&format!("Q1 foreign text: '{}'", foreign(&["-t", "text/plain"])));
                say(&format!("Q5 foreign custom: '{}'", foreign(&["-t", "dev.kaya.note"])));

                // Q3: bytes in, bytes out, byte-identical?
                let png = std::process::Command::new("wl-paste")
                    .args(["-t", "image/png"])
                    .output()
                    .map(|o| o.stdout)
                    .unwrap_or_default();
                say(&format!(
                    "Q3 foreign image/png: {} bytes in, {} out, identical={}",
                    PIXEL_PNG.len(),
                    png.len(),
                    png == PIXEL_PNG
                ));

                // --- Q4: files as text/uri-list -------------------
                // Written with the RFC's CRLF and a trailing one; the
                // question is whether a reader minds either way.
                let uris = b"file:///tmp/kaya-probe-a.txt\r\nfile:///tmp/kaya-probe-b.txt\r\n";
                let files = gdk::ContentProvider::for_bytes(
                    "text/uri-list",
                    &glib::Bytes::from_static(uris),
                );
                let window = app.windows().first().cloned().unwrap();
                let clipboard = gtk4::prelude::WidgetExt::display(&window).clipboard();
                let _ = clipboard.set_content(Some(&files));
                glib::timeout_add_seconds_local(1, {
                    let app = app.clone();
                    move || {
                        say(&format!(
                            "Q4 foreign text/uri-list: {:?}",
                            foreign(&["-t", "text/uri-list"])
                        ));

                        // --- Q6: read a type nothing offers ---------
                        // Fast empty, or a hang? A hang is a wedged leg,
                        // and the arm would need its own timeout.
                        let window = app.windows().first().cloned().unwrap();
                        let clipboard = gtk4::prelude::WidgetExt::display(&window).clipboard();
                        let started = std::time::Instant::now();
                        clipboard.read_async(
                            &["image/png"],
                            glib::Priority::DEFAULT,
                            gtk4::gio::Cancellable::NONE,
                            move |res| {
                                say(&format!(
                                    "Q6 read of an unoffered type answered in {}ms: {}",
                                    started.elapsed().as_millis(),
                                    match res {
                                        Ok(_) => "Ok(stream)".to_owned(),
                                        Err(e) => format!("Err({e})"),
                                    }
                                ));
                                say("==== end");
                                std::process::exit(0);
                            },
                        );
                        // A read that never answers is the finding.
                        glib::timeout_add_seconds_local(5, || {
                            say("Q6 NO ANSWER IN 5s — the read HANGS, and the arm needs its own bound");
                            say("==== end");
                            std::process::exit(0);
                        });
                        glib::ControlFlow::Break
                    }
                });
                glib::ControlFlow::Break
            }
        });
    });

    say("==== begin");
    app.run_with_args::<&str>(&[]);
}
