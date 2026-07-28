//! The background conformance scene: work off the app thread, posted
//! back (DESIGN.md's threading model; docs/background-work-plan.md).
//!
//! WHAT IT PROVES, and the reason for its odd shape: a wrong
//! implementation must DEADLOCK rather than disagree. The worker parks
//! until a CLICK releases it, and only a live app thread can process a
//! click — so a binding that let background work occupy the app thread
//! cannot reach the end of the script at all. It could not even deliver
//! its own release. That is much stronger than reading a different
//! value, and it is what stops the scene passing for an implementation
//! that simply blocked.
//!
//! The parking is a plain `Receiver::recv` on a channel this guest owns.
//! kaya supplies no waiting primitive and should not: the whole point is
//! that a guest uses its own language's concurrency and hands back only
//! the result.
//!
//! The accumulators are the guest's own state, not read back from
//! signals — signals are write-only by doctrine (the app owns its
//! model). They are `Arc<Mutex<..>>` because a posted closure must be
//! `Send` to get here; the lock is uncontended, since everything that
//! touches it runs on the app thread.

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
                // Authored so the CLOSING read can address it: the AX
                // read needs an identifier, and an index read passes for
                // an arm that ran and drew nothing.
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
                        // Parks here until the scene clicks release. Were
                        // the binding running this on the app thread,
                        // that click could never be processed and the
                        // whole scene would deadlock — the point.
                        let _ = rx.recv();
                        // Three posts, in order. The accumulator makes
                        // this a test of ORDER and not merely of which
                        // one ran last.
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
            // Proof the app thread is still serving input while the
            // worker is parked and has posted nothing.
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
