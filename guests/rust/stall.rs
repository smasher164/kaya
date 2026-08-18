//! The stall conformance scene: an app thread that stops taking its
//! occurrences is REPORTED (DESIGN.md, Threading model and protocol).
//! The byte-frozen contract is tools/scenes/stall.steps.
//!
//! THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE — do not "fix"
//! the sleeps below onto a worker. `ping` is load-bearing too: the
//! consumer cursor advances BEFORE a record reaches the guest, so a
//! handler blocking on an empty ring is indistinguishable from an idle
//! app, and only PENDING work makes the stall visible.

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        Block,
        Ping,
        Wedge,
    }

    // Comfortably past the watchdog's one-second threshold, and short
    // enough that the leg is not paying for it.
    const BLOCK: std::time::Duration = std::time::Duration::from_millis(2500);

    // A day, never a literal park (docs/traps.md, "The stall scene
    // wedges for a DAY").
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
            // is.
            Msg::Block => std::thread::sleep(BLOCK),
            Msg::Ping => ctx.apply(|tx| tx.write(status, "pinged")),
            Msg::Wedge => std::thread::sleep(WEDGE),
        }
    }
}

fn main() {
    kaya::run(app)
}
