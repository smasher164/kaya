//! The submit scene (tools/scenes/submit.steps): Return in an entry, a
//! search field and a `submits` textarea publishes `submitted` with the
//! field's text (docs/submit-plan.md); a plain textarea's Return is its
//! newline. The app writes each submit into one label.

use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Thread {
    title: String,
}

#[derive(Clone)]
enum Msg {
    Sent(String),
    Replied(kaya::Path, String),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let sent = ctx.apply(|tx| {
        let threads = tx.collection::<Thread>();
        let sent = tx.signal("sent: -".to_string());
        let root = tx
            .column(|tx| {
                tx.label(sent).a11y_id("sent");
                let name = tx.entry().placeholder("Name").a11y_id("name").id();
                msgs.on_submit(name, Msg::Sent);
                let find = tx.search().placeholder("Search").a11y_id("find").id();
                msgs.on_submit(find, Msg::Sent);
                let plain = tx.textarea().a11y_id("plain").id();
                msgs.on_submit(plain, Msg::Sent);
                let compose = tx.textarea().submits().a11y_id("compose").id();
                msgs.on_submit(compose, Msg::Sent);
                let rows = threads.rows(tx);
                for mut row in rows {
                    row.label(Thread::title());
                    let reply = row.entry();
                    row.a11y_id(reply, "reply");
                    msgs.on_submit_node(reply, Msg::Replied);
                }
            })
            .id();
        tx.mount(root);
        for (key, title) in [("r1", "First"), ("r2", "Second")] {
            tx.insert(&threads, key.to_string(), Thread { title: title.to_string() });
        }
        sent
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Sent(text) => ctx.apply(|tx| tx.write(sent, format!("sent: {text}"))),
            Msg::Replied(path, text) => {
                let key: String = path.key(0);
                ctx.apply(|tx| tx.write(sent, format!("sent: {key}: {text}")));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
