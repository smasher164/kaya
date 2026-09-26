//! The app badge's scene (tools/scenes/badge.steps): a count on the app's
//! icon, set and cleared, beside a notification — docs/app-badge-plan.md.

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        Post,
        Badge(u32),
    }

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("badge");
        // A badge is drawn on the app's icon, so the app declares one: on
        // the mac that is also what gives it a Dock tile.
        tx.app_identity();
        let status = tx.signal("ready");
        let root = tx
            .column(|tx| {
                tx.label(status); // label#0
                let post = tx.button("post").id(); // button#0
                msgs.on_click(post, Msg::Post);
                let three = tx.button("3 unread").id(); // button#1
                msgs.on_click(three, Msg::Badge(3));
                let clear = tx.button("clear").id(); // button#2
                msgs.on_click(clear, Msg::Badge(0));
            })
            .id();
        tx.mount(root);
        status
    });

    let mut posts = 0u64;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Post => {
                posts += 1;
                ctx.apply(|tx| {
                    tx.show_notification(21)
                        .title("Unread messages")
                        .body("From the badge scene")
                        .show();
                    tx.write(status, format!("posted {posts}"));
                });
            }
            Msg::Badge(count) => ctx.apply(|tx| {
                tx.set_badge(count);
                tx.write(status, format!("badge {count}"));
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
