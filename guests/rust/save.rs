//! The save round trip (tools/scenes/save.steps). EVERY STATUS IS A
//! READ-BACK, and no name here carries an extension.

use std::io::{Read, Write};

/// guests/rust/filedialog.rs carries each platform's reasoning.
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

pub(crate) fn save_dir() -> std::path::PathBuf {
    scene_root().join(format!("kaya-save-{}", std::process::id()))
}

/// Reads a handle back through kaya.
fn read_back(file: &kaya::PickedFile) -> String {
    let mut text = String::new();
    match file.open(kaya::FileMode::Read) {
        Ok(mut opened) => {
            if let Err(e) = opened.file.read_to_string(&mut text) {
                text = format!("read failed: {e}");
            }
        }
        Err(e) => text = format!("open failed: {e}"),
    }
    text
}

/// Reports what the file says afterwards. `FileMode::Write` truncates, and
/// the destination only adds the create.
fn write_back(file: &kaya::PickedFile, bytes: &str) -> String {
    match file.open(kaya::FileMode::Write) {
        Ok(mut opened) => {
            if let Err(e) = opened.file.write_all(bytes.as_bytes()) {
                return format!("write failed: {e}");
            }
            // Dropped before the reopen, so the bytes are the FILE's.
            drop(opened.file);
            read_back(file)
        }
        // Without the create a save destination answers ENOENT here
        // (docs/save-plan.md D1).
        Err(e) => format!("save failed: {e}"),
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone)]
    enum Msg {
        Open,
        Picked(Vec<kaya::PickedFile>),
        SaveBack,
        SaveAs,
        Saved(Option<kaya::PickedFile>),
        Reopen,
    }

    // The decoy the picker needs; guests/rust/filedialog.rs says why.
    let dir = save_dir();
    std::fs::create_dir_all(&dir).expect("failed to make the scene's directory");
    std::fs::write(dir.join("draft"), b"first draft").expect("failed to write the file");
    std::fs::write(dir.join("decoy"), b"decoy").expect("failed to write the decoy");

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("save");
        let status = tx.signal("no file");
        let root = tx
            .column(|tx| {
                tx.label(status).a11y_id("status"); // label#0
                let open = tx.button("open").id(); // button#0
                msgs.on_click(open, Msg::Open);
                let save = tx.button("save").id(); // button#1
                msgs.on_click(save, Msg::SaveBack);
                let save_as = tx.button("save as").id(); // button#2
                msgs.on_click(save_as, Msg::SaveAs);
                let reopen = tx.button("reopen").id(); // button#3
                msgs.on_click(reopen, Msg::Reopen);
            })
            .id();
        tx.mount(root);
        status
    });

    // Handles and never paths: the phones have no re-openable path.
    let mut source: Option<kaya::PickedFile> = None;
    let mut destination: Option<kaya::PickedFile> = None;

    // Off the app thread, because `open` blocks.
    let work = |job: Box<dyn FnOnce() -> String + Send>| {
        let poster = ctx.poster();
        std::thread::Builder::new()
            .name("save-worker".into())
            .spawn(move || {
                let text = job();
                poster.post(move |tx| tx.write(status, text));
            })
            .expect("failed to spawn the worker");
    };

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Open => {
                let dialog = ctx.apply(|tx| tx.pick_file().show());
                msgs.on_files(dialog, Msg::Picked);
            }
            Msg::Picked(files) => {
                let Some(file) = files.into_iter().next() else {
                    ctx.apply(|tx| tx.write(status, "open cancelled"));
                    continue;
                };
                source = Some(file.clone());
                work(Box::new(move || format!("opened {}", read_back(&file))));
            }
            Msg::SaveBack => {
                // No dialog: the chosen handle is writable. A missing one
                // gets its OWN sentence, never a panic (save-jvm WATCH).
                let Some(file) = source.clone() else {
                    ctx.apply(|tx| tx.write(status, "nothing open to save"));
                    continue;
                };
                work(Box::new(move || format!("saved {}", write_back(&file, "second draft"))));
            }
            Msg::SaveAs => {
                // The name the dialog OPENS with; the scene types over it.
                let dialog = ctx.apply(|tx| tx.save_file("copy").show());
                msgs.on_saved(dialog, Msg::Saved);
            }
            Msg::Saved(file) => {
                let Some(file) = file else {
                    // Cancel is None: nothing named, nothing written.
                    ctx.apply(|tx| tx.write(status, "save cancelled"));
                    continue;
                };
                destination = Some(file.clone());
                work(Box::new(move || format!("saved {}", write_back(&file, "third draft"))));
            }
            Msg::Reopen => {
                // A save-as through the ORIGINAL handle fails only here.
                let (Some(first), Some(second)) = (source.clone(), destination.clone())
                else {
                    ctx.apply(|tx| tx.write(status, "nothing to reopen"));
                    continue;
                };
                work(Box::new(move || {
                    format!("reopened {} {}", read_back(&first), read_back(&second))
                }));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
