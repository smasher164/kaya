//! The clipboard conformance scene: one clip in several
//! representations, and the privileged read that takes one back
//! (DESIGN.md, Clipboard; docs/clipboard-plan.md).
//!
//! EVERY ASSERTION CROSSES A PROCESS BOUNDARY, and that is the whole
//! design of this scene. kaya's representation set is closed because
//! the LOWERINGS are the hard part — CF_HTML's mandatory offset header,
//! Android's content:// URI for an image, CF_HDROP's double-NUL
//! struct — and a check where kaya reads what kaya wrote parses its own
//! malformed header perfectly happily. That is not merely less
//! coverage: it is a check that cannot fail for the reason the design
//! exists, which is worse than none because it looks like coverage.
//!
//! So what this guest copies is read back by `pbpaste` and `sips`, and
//! what it reads was put there by `pbcopy` and `osascript` — the
//! platform's own tools, in their own processes, on the other side of
//! the boundary the design is about.
//!
//! THE ONE EXCEPTION IS THE CUSTOM FORMAT, deliberately. No stock tool
//! on any platform writes an app-defined type, and a helper kaya wrote
//! would be foreign in name only. A custom format's whole specification
//! is that it round-trips within the app and that kaya does nothing
//! clever with the bytes — so the guest copies one and reads it back,
//! with the foreign reader confirming the bytes really are on the
//! clipboard under that id.
//!
//! THE PASTED FILE GOES ALL THE WAY TO THE BYTES, the filedialog
//! scene's claim in the other direction: a file arriving on the
//! clipboard is the SAME capability the picker returns, so the guest
//! redeems the handle with `kaya_open_picked` and reads it with
//! ordinary `std::fs`. The read runs off the app thread for the reason
//! `PickedFile::open` documents — it blocks, and a cloud provider may
//! download the file first.
//!
//! THE IMAGE IS ASSERTED AS A DECODED SIZE, never as bytes. Every host
//! re-encodes freely between image types (macOS synthesizes tiff, jpeg,
//! gif and four more from one png on demand), so a byte count would be
//! a different number on every platform for the same picture. The
//! guest reads the image and copies it straight back, and the foreign
//! decoder reports "4x4" — which is the same string on every lane.

use std::io::Read;

/// The scene's own directory, computed identically on both sides — the
/// filedialog rule, and for the same reason: guest and interpreter are
/// the same process, so they can agree on a path with no runner
/// involvement, and the pid keeps parallel legs from colliding.
///
/// The phones need the shared collections rather than the temp dir,
/// because the OUTSIDE process has to reach these files too: an
/// Android helper app and `simctl` see the shared Documents
/// collection, and neither can see another app's private cache.
#[cfg(target_os = "android")]
fn scene_root() -> std::path::PathBuf {
    let root = std::env::var("EXTERNAL_STORAGE").unwrap_or_else(|_| "/sdcard".into());
    std::path::PathBuf::from(root).join("Documents")
}

#[cfg(target_os = "ios")]
fn scene_root() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::PathBuf::from(home).join("Documents")
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn scene_root() -> std::path::PathBuf {
    std::env::temp_dir()
}

fn scene_dir() -> std::path::PathBuf {
    scene_root().join(format!("kaya-clip-{}", std::process::id()))
}

/// A 4x4 PNG, spelled out rather than generated: the scene asserts
/// "4x4" through a foreign decoder, so the picture has to be a real
/// encoded image and its size has to be knowable from the script.
/// Written to disk for the seeding tool to read, and handed to `copy`
/// as bytes — the same picture on both paths.
const PIXEL_PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, // 4 x 4
    0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09, // 8-bit rgb + crc
    0x29, 0x00, 0x00, 0x00, 0x1C, 0x49, 0x44, 0x41, // IDAT length + type
    0x54, 0x18, 0x57, 0x63, 0xFC, 0xCF, 0xC0, 0xF0, //
    0x9F, 0x81, 0xE1, 0x3F, 0x03, 0xC3, 0x7F, 0x06, //
    0x86, 0xFF, 0x0C, 0x0C, 0xFF, 0x19, 0x18, 0xFE, //
    0x33, 0x30, 0x00, 0x00, 0x3D, 0x94, 0x07, 0xF9, //
    0x8A, 0x2C, 0xEA, 0x84, 0x00, 0x00, 0x00, 0x00, // IEND length
    0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, // IEND + crc
];

/// The app-defined format's id. Reverse-DNS and space-free because it
/// reaches every platform's own registry VERBATIM — a UTI on Apple,
/// RegisterClipboardFormat on Windows, a target atom on X11 and
/// Wayland, a MIME type on Android. That is kaya's whole promise here.
const NOTE_ID: &str = "dev.kaya.note";
/// NO QUOTES IN THE PAYLOAD, and the reason is the script rather than
/// the clipboard: the step grammar's escapes are `\n`, `\r` and `\\`
/// in all three interpreters, with no `\"` — so a quoted byte could not
/// be spelled in the expectation. The bytes are arbitrary either way,
/// which is the property under test.
const NOTE_BYTES: &[u8] = b"note=1";

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone)]
    enum Msg {
        CopyRich,
        ReadCustom,
        ReadText,
        ReadImage,
        ReadFiles,
        Answer(Option<kaya::Representation>),
        FocusRich,
        FocusPlain,
        Pasted(kaya::Representation),
    }

    // The files the outside process will seed from, written before
    // anything is shown — the filedialog rule again.
    let dir = scene_dir();
    std::fs::create_dir_all(&dir).expect("failed to make the scene's directory");
    std::fs::write(dir.join("pixel.png"), PIXEL_PNG).expect("failed to write the picture");
    std::fs::write(dir.join("pasted.txt"), b"pasted bytes").expect("failed to write the file");

    let msgs = kaya::Messages::<Msg>::new();
    let (status, rich_field, plain_field) = ctx.apply(|tx| {
        // THE GESTURE LAYER'S DECLARATION, and an app writes nothing
        // else for it: the Paste command lowers to the platform's own,
        // acts on whatever is focused, and works out its own enablement
        // from what the clipboard offers and what the focused widget
        // takes. kaya has no selection API, which is exactly why copy
        // of a selection has to be a command rather than something an
        // app assembles out of the data layer.
        tx.window(kaya::DEFAULT_WINDOW).title("clipboard").menu("Edit", |m| {
            m.item("Cut").role(kaya::MenuRole::Cut).id();
            m.item("Copy").role(kaya::MenuRole::Copy).id();
            m.item("Paste").role(kaya::MenuRole::Paste).id();
        });
        let status = tx.signal("ready");
        let mut rich_field = None;
        let mut plain_field = None;
        let root = tx
            .column(|tx| {
                tx.label(status).a11y_id("status"); // label#0
                let rich = tx.button("copy").id(); // button#0
                msgs.on_click(rich, Msg::CopyRich);
                let custom = tx.button("read custom").id(); // button#1
                msgs.on_click(custom, Msg::ReadCustom);
                let text = tx.button("read text").id(); // button#2
                msgs.on_click(text, Msg::ReadText);
                let image = tx.button("read image").id(); // button#3
                msgs.on_click(image, Msg::ReadImage);
                let files = tx.button("read files").id(); // button#4
                msgs.on_click(files, Msg::ReadFiles);
                let focus_rich = tx.button("focus rich").id(); // button#5
                msgs.on_click(focus_rich, Msg::FocusRich);
                let focus_plain = tx.button("focus plain").id(); // button#6
                msgs.on_click(focus_plain, Msg::FocusPlain);

                // DECLARES WHAT IT TAKES, so a paste lands in the hook
                // and this app decides what to do with it.
                let field = tx
                    .entry()
                    .accepts(&[kaya::Accepts::Text])
                    .a11y_id("rich")
                    .id(); // entry#0
                msgs.on_paste(field, Msg::Pasted);
                rich_field = Some(field);

                // DECLARES NOTHING, so the platform's own insertion
                // happens and the field's ordinary change path reports
                // it — which is what a plain text editor gets for free.
                plain_field = Some(tx.entry().a11y_id("plain").id()); // entry#1
            })
            .id();
        tx.mount(root);
        (status, rich_field.unwrap(), plain_field.unwrap())
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::CopyRich => {
                // ONE CLIP, FOUR REPRESENTATIONS. kaya derives none of
                // them from any other: whether list bullets survive
                // html-to-text is this app's decision, so it spells out
                // both. The order the values go on the wire is kaya's,
                // not this call's — descending richness, which is
                // preference order on every host that has one.
                ctx.apply(|tx| {
                    tx.copy()
                        .text("kaya clip")
                        .html("<b>kaya</b> clip")
                        .image(PIXEL_PNG.to_vec())
                        .custom(NOTE_ID, NOTE_BYTES.to_vec())
                        .send();
                    tx.write(status, "copied");
                });
            }
            Msg::ReadCustom => {
                let request = ctx.apply(|tx| tx.read_clipboard().custom(NOTE_ID).send());
                msgs.on_clipboard(request, Msg::Answer);
            }
            Msg::ReadText => {
                let request = ctx.apply(|tx| tx.read_clipboard().text().send());
                msgs.on_clipboard(request, Msg::Answer);
            }
            Msg::ReadImage => {
                let request = ctx.apply(|tx| tx.read_clipboard().image().send());
                msgs.on_clipboard(request, Msg::Answer);
            }
            Msg::ReadFiles => {
                let request = ctx.apply(|tx| tx.read_clipboard().files().send());
                msgs.on_clipboard(request, Msg::Answer);
            }
            Msg::FocusRich => ctx.apply(|tx| tx.focus(rich_field)),
            Msg::FocusPlain => ctx.apply(|tx| tx.focus(plain_field)),
            // THE SAME SHAPE THE READ ANSWERS WITH, and free where the
            // read is not: a gesture is its own authorisation, so no
            // platform charges a prompt for this one.
            Msg::Pasted(kaya::Representation::Text(text)) => {
                ctx.apply(|tx| tx.write(status, format!("pasted {text}")));
            }
            Msg::Pasted(other) => {
                ctx.apply(|tx| tx.write(status, format!("pasted {other:?}")));
            }
            Msg::Answer(clip) => match clip {
                // EMPTY IS THE UNIVERSAL NO, and the guest does not try
                // to tell its four causes apart — denied, unfocused,
                // absent, or nothing this read accepted. The platforms
                // deliberately decline to say which.
                None => ctx.apply(|tx| tx.write(status, "empty")),
                Some(kaya::Representation::Text(text)) => {
                    ctx.apply(|tx| tx.write(status, format!("text {text}")));
                }
                Some(kaya::Representation::Html(html)) => {
                    ctx.apply(|tx| tx.write(status, format!("html {html}")));
                }
                Some(kaya::Representation::Custom { id, bytes }) => {
                    let body = String::from_utf8_lossy(&bytes.0).into_owned();
                    ctx.apply(|tx| tx.write(status, format!("custom {id} {body}")));
                }
                Some(kaya::Representation::Image(bytes)) => {
                    // STRAIGHT BACK OUT, because the assertion that
                    // matters is a foreign DECODER's: the byte count
                    // differs per host for one picture, and the decoded
                    // size does not.
                    let bytes = bytes.0.to_vec();
                    ctx.apply(|tx| {
                        tx.copy().image(bytes).send();
                        tx.write(status, "image");
                    });
                }
                Some(kaya::Representation::Files(files)) => {
                    let Some(file) = files.into_iter().next() else {
                        ctx.apply(|tx| tx.write(status, "files none"));
                        continue;
                    };
                    // OFF THE APP THREAD, which is what
                    // `PickedFile::open` documents: it blocks, and a
                    // pasted file is no different from a picked one —
                    // it IS a picked one, the same capability arriving
                    // through a second door.
                    let poster = ctx.poster();
                    std::thread::Builder::new()
                        .name("clipboard-reader".into())
                        .spawn(move || {
                            let name = file.name.clone();
                            let mut text = String::new();
                            match file.open(kaya::FileMode::Read) {
                                Ok(mut opened) => {
                                    if let Err(e) = opened.file.read_to_string(&mut text) {
                                        text = format!("read failed: {e}");
                                    }
                                }
                                Err(e) => text = format!("open failed: {e}"),
                            }
                            poster.post(move |tx| {
                                tx.write(status, format!("files {name} {text}"));
                            });
                        })
                        .expect("failed to spawn the reader");
                    ctx.apply(|tx| tx.write(status, "reading"));
                }
            },
        }
    }
}

fn main() {
    kaya::run(app)
}
