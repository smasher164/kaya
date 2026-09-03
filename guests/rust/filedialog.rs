//! The filedialog scene (tools/scenes/filedialog.steps). THE READ RUNS OFF
//! THE APP THREAD, and the worker PARKS between reading and posting.

use std::io::Read;
use std::sync::mpsc;

/// NOT THE TEMP DIRECTORY ON ANDROID: DocumentsUI browses providers and
/// none exposes an app's private cache, so a picker there opens on Recent.
#[cfg(target_os = "android")]
fn scene_root() -> std::path::PathBuf {
    let root = std::env::var("EXTERNAL_STORAGE").unwrap_or_else(|_| "/sdcard".into());
    std::path::PathBuf::from(root).join("Documents")
}

/// Reachable only because the bundle declares `UIFileSharingEnabled` and
/// `LSSupportsOpeningDocumentsInPlace` (tools/ios/Info.plist.in).
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

    // THE DECOY IS REQUIRED: a dialog with ONE file completes with it
    // having selected nothing (docs/traps.md).
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

    // The send must NOT wait for the receiver — mpsc's does not.
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let mut release_tx = Some(release_tx);
    let mut release_rx = Some(release_rx);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Ask | Msg::AskOne => {
                let one = matches!(msg, Msg::AskOne);
                let dialog = ctx.apply(|tx| {
                    let r = if one { tx.pick_file() } else { tx.pick_files() };
                    // Advisory on every platform, never a guarantee.
                    r.filter("Text", "txt").show()
                });
                msgs.on_files(dialog, Msg::Picked);
            }
            Msg::Picked(files) => {
                if files.is_empty() {
                    // The empty list IS cancel.
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
                        // Parks: on the app thread the release click could
                        // never be processed.
                        let _ = rx.recv();
                        poster.post(move |tx| tx.write(status, format!("{count} {text}")));
                    })
                    .expect("failed to spawn the reader");
                // The handler RETURNED without reading; the scene reads this.
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
