//! The save conformance scene: the ROUND TRIP an editor actually walks
//! (docs/save-plan.md D5), which is open, edit, save, save-as, reopen.
//!
//! WHAT THIS PROVES, and why none of it is about a dialog closing:
//!
//! 1. **Save-back works.** Writing through the handle the OPEN picker
//!    handed over — the thing DESIGN.md has claimed since the picker
//!    landed ("the document the user opened can be opened `O_RDWR`
//!    through the ordinary handle, the write lands") and that NO scene,
//!    leg or test has ever driven. The claim rested on reading the code.
//! 2. **A save destination is openable at all.** A save dialog on this
//!    platform answers with a name for a file NOBODY HAS MADE (measured:
//!    `exists=false` after a clean Save), so opening it would fail with
//!    "No such file or directory" for a file the user just named. The
//!    core's `SaveDestination` creates; docs/save-plan.md D1 is the
//!    decision and this step is where it shows.
//! 3. **The two files stay different.** The last step reopens BOTH
//!    handles and reports both contents, so a save-as that quietly wrote
//!    back into the ORIGINAL — the plausible bug, since the guest is
//!    holding two handles that look alike — fails here and nowhere else.
//! 4. **Cancel is nothing, and the dialog id retires.** The scene shows
//!    a save dialog, cancels it, and shows another. A cancel that leaked
//!    the live slot would panic on the second show.
//!
//! THE STRINGS ARE BYTE-FROZEN and compared identically on every lane, so
//! they carry the CONTENT rather than a verdict: "saved second draft" is
//! what came back off the disk, not what the guest hoped it wrote. Every
//! status here is a read-back — write, reopen, read, report.
//!
//! THE WORK RUNS OFF THE APP THREAD, which is what `PickedFile::open`
//! tells every caller to do: it blocks, and a cloud provider may download
//! the whole file first. A guest that did this inline would contradict
//! its own API doc. The parking dance that PROVES the thread hop belongs
//! to the filedialog scene and is not repeated here — this one owns the
//! round trip.
//!
//! NO EXTENSIONS ON THE NAMES, deliberately. NSSavePanel publishes the
//! name field's value with the extension HIDDEN when the user's Finder
//! preference says so, which would make `expect_save_dialog` read the
//! stem on one machine and the whole name on another — a machine-wide
//! setting deciding a lane's colour, which the panel view modes already
//! cost this project a day for. A name with no extension has no stem to
//! differ from, on any platform.

use std::io::{Read, Write};

/// Both halves compute this identically; the filedialog scene's module
/// note carries the reasoning for each platform's root (Android's
/// providers cannot see an app's private storage, iOS's picker cannot
/// see its container, and the desktops just use the temp directory).
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

/// Read a handle back through kaya, with the guest's own file API. THE
/// READ-BACK IS THE ASSERTION in every step of this scene: a write that
/// returned Ok and landed nowhere is exactly the failure "save" has, and
/// only reopening can see it.
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
        // THE FAILURE D1 EXISTS TO PREVENT reaches the label verbatim:
        // without the create, a save destination answers "No such file
        // or directory (os error 2)" here.
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

    // The file the scene opens, written before anything is shown, plus
    // the decoy the picker needs: with ONE file in the directory a
    // dialog completes with it when nothing is selected, so
    // `file_choose` would pass on a backend that ignored the name.
    // "decoy" sorts first, so a backend that skips the selection gets
    // the wrong file and its bytes fail too.
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

    // The two capabilities the scene carries: the file the user OPENED,
    // and the destination the user later NAMED. Held as handles, never
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
                // SAVE-BACK NEEDS NO DIALOG. The user already chose this
                // file, and the handle they chose it with is writable —
                // the claim this step exists to drive.
                let file = source.clone().expect("the scene opens a file before saving");
                work(Box::new(move || format!("saved {}", write_back(&file, "second draft"))));
            }
            Msg::SaveAs => {
                // The suggested name the dialog OPENS with; the scene
                // types over it, which is what a save dialog is for.
                let dialog = ctx.apply(|tx| tx.save_file("copy").show());
                msgs.on_saved(dialog, Msg::Saved);
            }
            Msg::Saved(file) => {
                let Some(file) = file else {
                    // Cancel is None. Nothing was named, so nothing is
                    // written and no destination is remembered.
                    ctx.apply(|tx| tx.write(status, "save cancelled"));
                    continue;
                };
                destination = Some(file.clone());
                work(Box::new(move || format!("saved {}", write_back(&file, "third draft"))));
            }
            Msg::Reopen => {
                // BOTH, in order: the file that was opened must still
                // hold the save-back, and the destination must hold the
                // save-as. A save that went to the wrong handle passes
                // every earlier step and fails here.
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
