//! The background conformance scene: work off the app thread, posted
//! back (DESIGN.md's threading model; docs/background-work-plan.md).
//! The byte-frozen contract is tools/scenes/background.steps.
//!
//! THE ODD SHAPE IS THE POINT: a wrong implementation must DEADLOCK
//! rather than disagree. The worker parks until a CLICK releases it, so
//! a binding that let background work occupy the app thread could not
//! even deliver its own release.
//!
//! Signals are write-only, so the accumulators are the guest's own
//! state. `Arc<Mutex<..>>` because a posted closure must be `Send`.

use std::sync::mpsc;
use std::sync::{Arc, Mutex};

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        Start,
        Ping,
        Release,
        Nest,
    }

    let msgs = kaya::Messages::<Msg>::new();
    let (status, alive, nested) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("background");
        let status = tx.signal("idle");
        let alive = tx.signal("-");
        let nested = tx.signal("-");
        let root = tx
            .column(|tx| {
                tx.label(status).a11y_id("status"); // label#0
                tx.label(alive).a11y_id("alive"); // label#1
                // Authored because the closing AX read needs an
                // identifier: an index read passes for an arm that ran
                // and drew nothing.
                tx.label(nested).a11y_id("nested"); // label#2
                let start = tx.button("start").id(); // button#0
                msgs.on_click(start, Msg::Start);
                let ping = tx.button("ping").id(); // button#1
                msgs.on_click(ping, Msg::Ping);
                let release = tx.button("release").id(); // button#2
                msgs.on_click(release, Msg::Release);
                let nest = tx.button("nest").id(); // button#3
                msgs.on_click(nest, Msg::Nest);
            })
            .id();
        tx.mount(root);
        (status, alive, nested)
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
            Msg::Start => {
                let poster = ctx.poster();
                let rx = release_rx.take().expect("start is clicked once");
                let acc = Arc::new(Mutex::new(String::new()));
                std::thread::Builder::new()
                    .name("background-worker".into())
                    .spawn(move || {
                        // Parks until the scene clicks release; on the
                        // app thread that click could never be processed.
                        let _ = rx.recv();
                        // The accumulator makes this a test of ORDER,
                        // not merely of which post ran last.
                        for step in ["1", "2", "3"] {
                            let acc = Arc::clone(&acc);
                            poster.post(move |tx| {
                                let mut seen = acc.lock().unwrap();
                                seen.push_str(step);
                                tx.write(status, seen.clone());
                            });
                        }
                    })
                    .expect("failed to spawn the background worker");
                ctx.apply(|tx| tx.write(status, "working"));
            }
            Msg::Ping => ctx.apply(|tx| tx.write(alive, "alive")),
            Msg::Release => {
                if let Some(tx) = release_tx.take() {
                    let _ = tx.send(());
                }
            }
            // A post from INSIDE a transaction queues for after; it never
            // nests. Queued writes "ac" and then "acb"; nesting can only
            // ever produce "abc", and the two are unreachable from each
            // other.
            Msg::Nest => {
                let poster = ctx.poster();
                let seq = Arc::new(Mutex::new(String::new()));
                let inner = Arc::clone(&seq);
                ctx.apply(|tx| {
                    seq.lock().unwrap().push('a');
                    poster.post(move |tx| {
                        let mut s = inner.lock().unwrap();
                        s.push('b');
                        tx.write(nested, s.clone());
                    });
                    seq.lock().unwrap().push('c');
                    let now = seq.lock().unwrap().clone();
                    tx.write(nested, now);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
