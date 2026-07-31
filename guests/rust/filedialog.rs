//! The filedialog conformance scene: the picker's request/result
//! grammar, and the capability it hands back (DESIGN.md, File dialogs).
//!
//! WHAT THIS PROVES, and why it goes all the way to the bytes: the
//! design's whole claim is that kaya hands over a CAPABILITY and never
//! moves the data. So the guest does not assert that a dialog closed —
//! it opens the handle it was given, reads the file with ORDINARY
//! `std::fs`, and writes what it read into a signal. `expect label#0
//! "picked bytes"` therefore fails unless a real descriptor came back
//! carrying the real file.
//!
//! THE FILE IS THE GUEST'S OWN. The guest and the interpreter are the
//! same process, so they can agree on a path with no runner
//! involvement: `<temp>/kaya-picked-<pid>/picked.txt`. The pid matters —
//! validate-mac runs legs in parallel and a fixed name would collide.
//! The scene names only the BASENAME, so one script serves five lanes
//! whose temp directories differ.
//!
//! THE READ RUNS OFF THE APP THREAD, which is what `PickedFile::open`
//! tells every caller to do: it blocks, and a cloud provider may
//! download the whole file before it returns. An example that read
//! inline would contradict its own API doc, and would leave the one
//! property this scene can uniquely prove untested — that the CAPABILITY
//! SURVIVES THE THREAD HOP. That is the platform-sensitive part: a
//! security-scoped URL on iOS, a `content://` URI plus a JNI reference
//! on Android. A handle that only opens on the thread that picked it
//! would pass every assertion here if the guest read inline.
//!
//! HOW THE TWO WRONG IMPLEMENTATIONS ARE CAUGHT. The worker PARKS
//! between reading and posting, and only a click releases it. Both
//! shapes were built and run, because a discriminator nobody has fired
//! is a hope:
//!
//! - Read inline in the handler, no worker: the label is already final
//!   when the scene looks, and `expect label#0 "reading"` fails on the
//!   spot with "reads \"1 picked bytes\", wanted \"reading\"".
//! - Do the work AND the park on the app thread: the app thread wedges,
//!   and the failure CASCADES — the release does nothing, the second
//!   picker never opens, cancel never lands, and the closing
//!   accessibility read still sees "reading". Four failures from one
//!   cause.
//!
//! It is the cascade, not a hang, that makes the second one unmistakable.
//! A guest that is merely FAST cannot produce it: every step after the
//! wedge fails, which no amount of speed imitates.
//!
//! What this scene does NOT re-prove: post ordering, and that a post
//! from inside a transaction queues rather than nests. background.steps
//! owns those. This one owns the handoff.
//!
//! CANCEL IS THE EMPTY LIST, faithfully: no platform can confirm an
//! empty selection, so there is no sentinel to invent.

use std::io::Read;
use std::sync::mpsc;

/// Both sides compute this identically; see the module note.
pub(crate) fn picked_dir() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("kaya-picked-{}", std::process::id()))
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
    // is shown. THE DECOY IS LOAD-BEARING: with one file in the
    // directory, pressing Open with nothing selected returns that file,
    // so `file_choose picked.txt` would pass on a backend that ignored
    // the name entirely. Measured on GTK, where the dialog completes
    // with the only row when none is selected. "decoy" sorts before
    // "picked" alphabetically, so a backend that skips selection gets
    // the WRONG file, and its five bytes fail the byte assertion as well
    // as the name.
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
                    // ADVISORY on every platform: a default view, never
                    // a guarantee, so a guest still validates what it
                    // got — which is what the read below does.
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
                        // THE CLAIM, and it is made HERE rather than in
                        // the handler on purpose: the handle crossed a
                        // thread boundary, and it is redeemed and read
                        // with the guest's own file API on the thread
                        // that received it. kaya is not in this data
                        // path, and `open` is documented to block.
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
                        // Parks holding the result, standing in for the
                        // tail of a slow transfer. Were this work running
                        // on the app thread, the release click could
                        // never be processed and the whole scene would
                        // deadlock — the point, and much stronger than
                        // reading back a different value.
                        let _ = rx.recv();
                        poster.post(move |tx| tx.write(status, format!("{count} {text}")));
                    })
                    .expect("failed to spawn the reader");
                // The handler RETURNED without reading. A guest that did
                // the work eagerly arrives at the next step already
                // showing the final text, and the scene says so.
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
