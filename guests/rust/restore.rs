//! The restoration scene (tools/scenes/restore.steps,
//! docs/restoration-plan.md SR15): the draft lives in the session store and
//! comes back through the ordinary build; the list's scroll and the text's
//! caret come back on their own.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Message {
    text: String,
}

#[derive(Clone)]
enum Msg {
    Draft(String),
    Jump,
    Select,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let session = kaya::session();
    let draft = session.get_string("draft", "");
    let msgs = kaya::Messages::<Msg>::new();
    let (field, list, doc) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("restore");
        let messages = tx.collection::<Message>();
        let launch = tx.signal(format!("launch {}", kaya::restored().as_str()));
        let mut list = None;
        let mut doc = None;
        let (root, field) = tx
            .column(|tx| {
                tx.label(launch); // label#0
                let field = tx.entry().id(); // entry#0
                tx.row(|tx| {
                    let jump = tx.button("jump").a11y_id("jump").id();
                    msgs.on_click(jump, Msg::Jump);
                    let select = tx.button("select").a11y_id("select").id();
                    msgs.on_click(select, Msg::Select);
                });
                doc = Some(tx.textarea().a11y_id("doc").id());
                tx.scroll(|tx| {
                    let rows = messages.rows(tx);
                    let inner = rows.id();
                    for mut row in rows {
                        row.label(Message::text());
                    }
                    tx.a11y_id(inner, "messages");
                    list = Some(inner);
                })
                .grow(1.0)
                .a11y_id("list");
                field
            })
            .into_parts();
        let doc = doc.expect("the textarea was built");
        tx.set_text(field, &draft);
        tx.set_text(doc, "the quick brown fox");
        tx.mount(root);
        for i in 1..=60 {
            tx.insert(&messages, format!("m{i}"), Message { text: format!("message {i}") });
        }
        (field, list.expect("the scroll's column was built"), doc)
    });
    msgs.on_change(field, Msg::Draft);
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Draft(text) => session.set_string("draft", &text),
            Msg::Jump => ctx.apply(|tx| tx.scroll_to_row(list, "m30".to_string())),
            Msg::Select => ctx.apply(|tx| tx.select_range(doc, 4..9)),
        }
    }
}

fn main() {
    kaya::run(app)
}
