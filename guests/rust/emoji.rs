//! The emoji scene (tools/scenes/emoji.steps): a button beside a field that
//! opens the platform's emoji picker on it — docs/emoji-picker-plan.md.

#[derive(Clone)]
enum Msg {
    Typed(String),
    Emoji,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (echo, message) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("emoji");
        let echo = tx.signal(String::new());
        let mut message = None;
        let root = tx
            .column(|tx| {
                tx.label(echo).a11y_id("echo");
                tx.row(|tx| {
                    let field = tx.entry().placeholder("Message").a11y_id("message").id();
                    msgs.on_change(field, Msg::Typed);
                    message = Some(field);
                    let emoji = tx.button("Emoji").a11y_id("emoji").id();
                    msgs.on_click(emoji, Msg::Emoji);
                });
            })
            .id();
        tx.mount(root);
        (echo, message.expect("the row declared the field"))
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Typed(text) => ctx.apply(|tx| tx.write(echo, text)),
            Msg::Emoji => ctx.apply(|tx| tx.show_emoji_picker(message)),
        }
    }
}

fn main() {
    kaya::run(app)
}
