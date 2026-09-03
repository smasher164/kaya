//! THE ONE GUEST THAT MISUSES KAYA ON PURPOSE (tools/scenes/stall.steps):
//! do not "fix" the sleeps onto a worker; `ping` makes the work PENDING.

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        Block,
        Ping,
        Wedge,
    }

    // Past the watchdog's one-second threshold, and no longer.
    const BLOCK: std::time::Duration = std::time::Duration::from_millis(2500);

    // A day, never a literal park (docs/traps.md, "The stall scene wedges
    // for a DAY").
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
            // DELIBERATELY WRONG, and the only place in this repo that is.
            Msg::Block => std::thread::sleep(BLOCK),
            Msg::Ping => ctx.apply(|tx| tx.write(status, "pinged")),
            Msg::Wedge => std::thread::sleep(WEDGE),
        }
    }
}

fn main() {
    kaya::run(app)
}
