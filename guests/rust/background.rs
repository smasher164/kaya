//! The background scene (tools/scenes/background.steps): the worker parks
//! for a CLICK, so a binding that used the app thread DEADLOCKS here.

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
                // Addressed by id: an index read passes for an empty arm.
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

    // The send must NOT wait for the receiver — mpsc's does not.
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
                        // Parks: on the app thread that click could never
                        // be processed.
                        let _ = rx.recv();
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
            // A post from INSIDE a transaction QUEUES for after.
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
