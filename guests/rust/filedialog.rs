//! The filedialog conformance scene: the picker's request/result
//! grammar, and the capability it hands back (DESIGN.md, File dialogs).
//! The byte-frozen contract is tools/scenes/filedialog.steps.
//!
//! The file is the guest's own — guest and interpreter are the same
//! process, so they agree on `<root>/kaya-picked-<pid>/picked.txt` with
//! no runner involvement, and the pid keeps parallel legs from
//! colliding. The scene names only the BASENAME, so one script serves
//! five lanes whose roots differ.
//!
//! THE READ RUNS OFF THE APP THREAD, which is what `PickedFile::open`
//! tells every caller to do: it blocks. The worker also PARKS between
//! reading and posting, so a guest that read inline, or that parked on
//! the app thread, fails rather than passing by being fast.
//!
//! Cancel is the empty list: no platform can confirm an empty
//! selection, so there is no sentinel to invent.

use std::io::Read;
use std::sync::mpsc;

/// Both sides compute this identically; see the module note.
///
/// NOT THE TEMP DIRECTORY ON ANDROID: DocumentsUI browses document
/// providers and none exposes an app's private cache, so a picker aimed
/// there opens on Recent instead, silently. The shared Documents
/// collection is the one directory both halves can have
/// (docs/file-dialogs-plan.md). EXTERNAL_STORAGE rather than a written
/// out /storage/emulated/0, which rots the first time a device numbers
/// its users differently.
#[cfg(target_os = "android")]
fn scene_root() -> std::path::PathBuf {
    let root = std::env::var("EXTERNAL_STORAGE").unwrap_or_else(|_| "/sdcard".into());
    std::path::PathBuf::from(root).join("Documents")
}

/// iOS is the same story with a different spelling. The app's own
/// Documents directory is reachable only because the bundle declares
/// `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`
/// (tools/ios/Info.plist.in); `HOME` is the container in every iOS
/// process.
#[cfg(target_os = "ios")]
fn scene_root() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::PathBuf::from(home).join("Documents")
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn scene_root() -> std::path::PathBuf {
    std::env::temp_dir()
}

pub(crate) fn picked_dir() -> std::path::PathBuf {
    scene_root().join(format!("kaya-picked-{}", std::process::id()))
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone)]
    enum Msg {
        Ask,
        AskOne,
        Picked(Vec<kaya::PickedFile>),
        Release,
    }

    // The files the scene will choose between, written before anything
    // is shown. THE DECOY IS REQUIRED: with one file in the directory a
    // dialog completes with it when nothing is selected (measured on
    // GTK), so `file_choose picked.txt` would pass on a backend that
    // ignored the name. "decoy" sorts first and its bytes differ, so
    // such a backend fails both assertions (docs/traps.md).
    let dir = picked_dir();
    std::fs::create_dir_all(&dir).expect("failed to make the scene's directory");
    std::fs::write(dir.join("picked.txt"), b"picked bytes").expect("failed to write the file");
    std::fs::write(dir.join("decoy.txt"), b"decoy").expect("failed to write the decoy");

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("filedialog");
        let status = tx.signal("no file");
        let root = tx
            .column(|tx| {
                tx.label(status).a11y_id("status"); // label#0
                let ask = tx.button("open").id(); // button#0
                msgs.on_click(ask, Msg::Ask);
                let one = tx.button("open one").id(); // button#1
                msgs.on_click(one, Msg::AskOne);
                let release = tx.button("release").id(); // button#2
                msgs.on_click(release, Msg::Release);
            })
            .id();
        tx.mount(root);
        status
    });

    // The release channel: the app thread sends, the worker receives.
    // A handler that blocked handing this over would fail the very claim
    // being tested, so the send must not wait for the receiver — mpsc's
    // does not.
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let mut release_tx = Some(release_tx);
    let mut release_rx = Some(release_rx);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Ask | Msg::AskOne => {
                let one = matches!(msg, Msg::AskOne);
                let dialog = ctx.apply(|tx| {
                    let r = if one { tx.pick_file() } else { tx.pick_files() };
                    // Advisory on every platform: a default view, never
                    // a guarantee.
                    r.filter("Text", "txt").show()
                });
                msgs.on_files(dialog, Msg::Picked);
            }
            Msg::Picked(files) => {
                if files.is_empty() {
                    // The empty list IS cancel. Nothing to read, so no
                    // worker and no release.
                    ctx.apply(|tx| tx.write(status, "cancelled"));
                    continue;
                }
                let poster = ctx.poster();
                let rx = release_rx
                    .take()
                    .expect("the scene picks a file exactly once");
                std::thread::Builder::new()
                    .name("filedialog-reader".into())
                    .spawn(move || {
                        // The handle crossed a thread boundary and is
                        // redeemed here, not in the handler: `open`
                        // blocks, and kaya is not in this data path.
                        let count = files.len();
                        let mut text = String::new();
                        match files[0].open(kaya::FileMode::Read) {
                            Ok(mut opened) => {
                                if let Err(e) = opened.file.read_to_string(&mut text) {
                                    text = format!("read failed: {e}");
                                }
                            }
                            Err(e) => text = format!("open failed: {e}"),
                        }
                        // Parks holding the result. On the app thread
                        // the release click could never be processed and
                        // the scene would deadlock — the discriminator.
                        let _ = rx.recv();
                        poster.post(move |tx| tx.write(status, format!("{count} {text}")));
                    })
                    .expect("failed to spawn the reader");
                // The handler RETURNED without reading; a guest that read
                // eagerly arrives here already showing the final text.
                ctx.apply(|tx| tx.write(status, "reading"));
            }
            Msg::Release => {
                if let Some(tx) = release_tx.take() {
                    let _ = tx.send(());
                }
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
