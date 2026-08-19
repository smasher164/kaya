//! The clipboard conformance scene: one clip in several
//! representations, and the privileged read that takes one back
//! (DESIGN.md, Clipboard; docs/clipboard-plan.md). The byte-frozen
//! contract, and why every assertion crosses a process boundary, is
//! tools/scenes/clipboard.steps.
//!
//! The read of a pasted file runs OFF THE APP THREAD, which is what
//! `PickedFile::open` documents: it blocks.

use std::io::Read;

/// The scene's own directory, computed identically on both sides; the
/// pid keeps parallel legs from colliding. The phones must use the
/// shared collections, not the temp dir — the OUTSIDE process has to
/// reach these files and cannot see an app's private cache
/// (guests/rust/filedialog.rs carries the per-platform reasoning).
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
/// "4x4" through a foreign decoder, so the size has to be knowable from
/// the script.
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

/// The app-defined format's id. Reverse-DNS and space-free: it reaches
/// every platform's own registry VERBATIM.
const NOTE_ID: &str = "dev.kaya/note";
/// NO QUOTES IN THE PAYLOAD: the step grammar's escapes are `\n`, `\r`
/// and `\\` with no `\"`, so a quoted byte could not be spelled in the
/// expectation.
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
        RowPasted(kaya::Path, kaya::Representation),
    }

    let dir = scene_dir();
    std::fs::create_dir_all(&dir).expect("failed to make the scene's directory");
    std::fs::write(dir.join("pixel.png"), PIXEL_PNG).expect("failed to write the picture");
    std::fs::write(dir.join("pasted.txt"), b"pasted bytes").expect("failed to write the file");

    let msgs = kaya::Messages::<Msg>::new();
    let (status, row_status, rich_field, plain_field) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("clipboard").menu("Edit", |m| {
            m.item("Cut").role(kaya::MenuRole::Cut).id();
            m.item("Copy").role(kaya::MenuRole::Copy).id();
            m.item("Paste").role(kaya::MenuRole::Paste).id();
        });
        let status = tx.signal("ready");
        let row_status = tx.signal("");
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

                let field = tx
                    .entry()
                    .accepts(&[kaya::Accepts::Text])
                    .a11y_id("rich")
                    .id(); // entry#0
                msgs.on_paste(field, Msg::Pasted);
                rich_field = Some(field);

                plain_field = Some(tx.entry().a11y_id("plain").id()); // entry#1

                // A STAMPED paste target: the accept list comes from the
                // TEMPLATE (docs/tpl-props-plan.md P1), and without it
                // the hook registers and waits forever.
                tx.label(row_status).a11y_id("row-status"); // label#1
                let rows = tx.collection::<String>();
                for mut r in rows.rows(tx) {
                    let field = r.entry(); // entry#2 once r1 stamps
                    r.accepts(field, &[kaya::Accepts::Text]);
                    msgs.on_paste_node(field, |path, clip| Msg::RowPasted(path, clip));
                }
                tx.insert(&rows, "r1", "");
            })
            .id();
        tx.mount(root);
        (status, row_status, rich_field.unwrap(), plain_field.unwrap())
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::CopyRich => {
                // One clip, four representations: kaya derives none of
                // them from any other, and the wire order is kaya's
                // (descending richness), not this call's.
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
            Msg::Pasted(kaya::Representation::Text(text)) => {
                ctx.apply(|tx| tx.write(status, format!("pasted {text}")));
            }
            Msg::Pasted(other) => {
                ctx.apply(|tx| tx.write(status, format!("pasted {other:?}")));
            }
            Msg::RowPasted(path, kaya::Representation::Text(text)) => {
                let key = match path.first() {
                    Some(kaya::Value::Str(k)) => k.clone(),
                    other => format!("{other:?}"),
                };
                ctx.apply(|tx| tx.write(row_status, format!("row {key} pasted {text}")));
            }
            Msg::RowPasted(path, other) => {
                ctx.apply(|tx| tx.write(row_status, format!("row {path:?} pasted {other:?}")));
            }
            Msg::Answer(clip) => match clip {
                // Empty is the universal no, and its four causes —
                // denied, unfocused, absent, not accepted — cannot be
                // told apart: the platforms decline to say which.
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
                    // Straight back out: the assertion is a foreign
                    // DECODER's, since a byte count differs per host for
                    // one picture and a decoded size does not.
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
                    // Off the app thread: `open` blocks.
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
