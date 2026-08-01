//! The stall conformance scene: an app thread that stops taking its
//! occurrences is REPORTED (DESIGN.md, Threading model and protocol —
//! "the core reads the app's consumer cursor directly, so stall
//! detection requires no protocol").
//!
//! THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE, and it has to
//! be. Every other guest keeps blocking work off the app thread; the
//! eight filedialog guests each carry a paragraph explaining why the
//! read goes to a worker. That discipline was entirely unenforced —
//! nothing would have told anyone that a guest which ignored it had
//! wedged the app. The class is not hypothetical: a Haskell release
//! once used `putMVar`, which blocks when full, so a second click
//! would have blocked the app thread forever, and no gate saw it.
//!
//! So `block` does exactly the forbidden thing — it sleeps on the app
//! thread — and the scene asserts that kaya NOTICES. A scene that only
//! timed out would prove the app was broken; this proves the framework
//! reported it, which is the whole feature.
//!
//! WHY THE SECOND CLICK MATTERS: the consumer cursor advances BEFORE a
//! record reaches the guest, so a handler blocking on an empty ring
//! looks exactly like an idle app — and nothing is waiting on it, so it
//! may as well be. `ping` is what makes work PENDING while the app
//! thread is gone. That is what the watchdog can see, and it is also
//! what a person reports: they click, and click again, and nothing
//! happens.
//!
//! The recovery is asserted too. The blocked handler returns, the
//! queued click is taken, and the label shows it — so the watchdog
//! reported a stall rather than a death, and nothing was dropped.
//!
//! AND THEN ONE THAT NEVER COMES BACK. A handler blocking for 2.5
//! seconds is a SLOW handler, and every assertion above would pass for
//! one; a real deadlock does not politely end. `wedge` never returns,
//! so the scene ends there — and the leg still reports its verdict,
//! because the harness runs on its own thread and asks the MAIN thread
//! to exit. Neither path needs the app thread that is gone.

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        Block,
        Ping,
        Wedge,
    }

    // Comfortably past the watchdog's one-second threshold, and short
    // enough that the leg is not paying for it: the scene asserts the
    // stall and then the recovery, so this is the whole cost.
    const BLOCK: std::time::Duration = std::time::Duration::from_millis(2500);

    // AND ONE THAT NEVER COMES BACK, which is the shape a real deadlock
    // has. A day rather than a literal park, because "forever" is
    // spelled differently in all eight languages and some of those
    // spellings wake their runtime's own deadlock detector; within a
    // leg that lasts seconds, a day and forever are the same thing. The
    // process exits out from under it.
    const WEDGE: std::time::Duration = std::time::Duration::from_secs(86_400);

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("stall");
        let status = tx.signal("ready");
        let root = tx
            .column(|tx| {
                tx.label(status); // label#0
                let block = tx.button("block").id(); // button#0
                msgs.on_click(block, Msg::Block);
                let ping = tx.button("ping").id(); // button#1
                msgs.on_click(ping, Msg::Ping);
                let wedge = tx.button("wedge").id(); // button#2
                msgs.on_click(wedge, Msg::Wedge);
            })
            .id();
        tx.mount(root);
        status
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            // DELIBERATELY WRONG, and the only place in this repo that
            // is. Anything real belongs on a thread of its own with the
            // result posted back — which is what every other guest
            // does, and what the watchdog's message tells you to do.
            Msg::Block => std::thread::sleep(BLOCK),
            Msg::Ping => ctx.apply(|tx| tx.write(status, "pinged")),
            Msg::Wedge => std::thread::sleep(WEDGE),
        }
    }
}

fn main() {
    kaya::run(app)
}
