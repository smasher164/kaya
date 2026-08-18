//! The save conformance scene: the ROUND TRIP an editor walks
//! (docs/save-plan.md D5) — open, edit, save, save-as, reopen. The
//! byte-frozen contract is tools/scenes/save.steps, which also carries
//! why no name here has an extension.
//!
//! Every status is a READ-BACK: write, reopen, read, report. A write
//! that returned Ok and landed nowhere is exactly the failure "save"
//! has, and only reopening can see it.
//!
//! THE WORK RUNS OFF THE APP THREAD, which is what `PickedFile::open`
//! tells every caller to do: it blocks. The parking dance that PROVES
//! the thread hop belongs to the filedialog scene.

use std::io::{Read, Write};

/// Both halves compute this identically; guests/rust/filedialog.rs
/// carries the reasoning for each platform's root.
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

/// Read a handle back through kaya, with the guest's own file API.
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

/// Write `bytes` through a handle and report what the file says
/// afterwards. `FileMode::Write` truncates, on a picked file and on a
/// save destination alike — the destination only adds the create.
fn write_back(file: &kaya::PickedFile, bytes: &str) -> String {
    match file.open(kaya::FileMode::Write) {
        Ok(mut opened) => {
            if let Err(e) = opened.file.write_all(bytes.as_bytes()) {
                return format!("write failed: {e}");
            }
            // Dropped before the reopen, so the bytes are the FILE's and
            // not a buffer's.
            drop(opened.file);
            read_back(file)
        }
        // The failure docs/save-plan.md D1 exists to prevent reaches the
        // label verbatim: without the create, a save destination answers
        // "No such file or directory (os error 2)" here.
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

    // The file the scene opens, plus the decoy the picker needs — see
    // guests/rust/filedialog.rs for why one file in the directory would
    // let a backend that ignores the name pass.
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

    // The two capabilities the scene carries, held as handles and never
    // as paths — the phones have no re-openable path at all.
    let mut source: Option<kaya::PickedFile> = None;
    let mut destination: Option<kaya::PickedFile> = None;

    // Every file operation runs on a thread of the guest's own, because
    // `open` blocks; the answer comes back through the poster.
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
                // No dialog: the handle the user opened with is writable.
                let file = source.clone().expect("the scene opens a file before saving");
                work(Box::new(move || format!("saved {}", write_back(&file, "second draft"))));
            }
            Msg::SaveAs => {
                // The suggested name the dialog OPENS with; the scene
                // types over it.
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
                // BOTH, in order: a save-as that quietly wrote back into
                // the ORIGINAL passes every earlier step and fails here.
                let first = source.clone().expect("the scene opens a file");
                let second = destination.clone().expect("the scene saves as");
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
