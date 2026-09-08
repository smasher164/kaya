//! The notification conformance scene (tools/scenes/notify.steps): a post
//! the platform holds, an activation the guest answers, a cancel the
//! platform honours — docs/tasks-s3-plan.md N1, N5.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::NotificationOutcome;

    #[derive(Clone, Copy)]
    enum Msg {
        Post,
        Cancel,
        Answered(u64, NotificationOutcome),
    }

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("notify");
        let can = kaya::capabilities().notifications;
        let status = tx.signal(if can { "ready" } else { "cannot post" });
        let root = tx
            .column(|tx| {
                tx.label(status); // label#0
                let post = tx.button("remind").id(); // button#0
                msgs.on_click(post, Msg::Post);
                let cancel = tx.button("clear").id(); // button#1
                msgs.on_click(cancel, Msg::Cancel);
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
                let id = ctx.apply(|tx| {
                    let id = tx
                        .show_notification(12)
                        .title("Call the plumber")
                        .body("Reminder from the notify scene")
                        .show();
                    tx.write(status, kaya::Value::Str(format!("posted {}", posts)));
                    id
                });
                msgs.on_notification(id, move |outcome| Msg::Answered(12, outcome));
            }
            Msg::Cancel => {
                ctx.apply(|tx| {
                    tx.cancel_notification(kaya::NotificationId(12));
                    tx.write(status, kaya::Value::Str("cleared".into()));
                });
            }
            Msg::Answered(id, outcome) => {
                let word = match outcome {
                    NotificationOutcome::Activated => "activated",
                    NotificationOutcome::Refused => "refused",
                };
                ctx.apply(|tx| tx.write(status, kaya::Value::Str(format!("{word} {id}"))));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
