//! The fullscreen scene (tools/scenes/fullscreen.steps,
//! docs/fullscreen-plan.md §5). The app keeps its own copy of the state:
//! a toggle writes `!on`, and the user's door moves the copy through
//! `on_fullscreen_changed`.

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        Toggle,
        Ping,
        User(bool),
    }

    let msgs = kaya::Messages::<Msg>::new();
    let (asked, user, pings) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("fullscreen");
        let asked = tx.signal("windowed");
        let user = tx.signal("no change from the user");
        let pings = tx.signal("pings 0");
        let root = tx
            .column(|tx| {
                tx.label(asked); // label#0
                tx.label(user); // label#1
                tx.label(pings); // label#2
                let toggle = tx.button("toggle fullscreen").id(); // button#0
                msgs.on_click(toggle, Msg::Toggle);
                let ping = tx.button("ping").id(); // button#1
                msgs.on_click(ping, Msg::Ping);
            })
            .id();
        tx.mount(root);
        (asked, user, pings)
    });

    msgs.on_fullscreen_changed(kaya::DEFAULT_WINDOW, Msg::User);

    let mut on = false;
    let mut pinged = 0;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Toggle => {
                on = !on;
                ctx.apply(|tx| {
                    tx.window(kaya::DEFAULT_WINDOW).fullscreen(on);
                    tx.write(asked, if on { "asked for fullscreen" } else { "asked for a window" });
                });
            }
            Msg::Ping => {
                pinged += 1;
                ctx.apply(|tx| tx.write(pings, format!("pings {pinged}")));
            }
            Msg::User(now) => {
                on = now;
                ctx.apply(|tx| {
                    tx.write(
                        user,
                        if now {
                            "the user turned fullscreen on"
                        } else {
                            "the user turned fullscreen off"
                        },
                    )
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
