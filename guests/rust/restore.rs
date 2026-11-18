//! The restoration scene (tools/scenes/restore.steps,
//! docs/restoration-plan.md SR15): the draft lives in the session store and
//! comes back through the ordinary build.

#[derive(Clone)]
enum Msg {
    Draft(String),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let session = kaya::session();
    let draft = session.get_string("draft", "");
    let msgs = kaya::Messages::<Msg>::new();
    let field = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("restore");
        let launch = tx.signal(format!("launch {}", kaya::restored().as_str()));
        let (root, field) = tx
            .column(|tx| {
                tx.label(launch); // label#0
                tx.entry().id() // entry#0
            })
            .into_parts();
        tx.set_text(field, &draft);
        tx.mount(root);
        field
    });
    msgs.on_change(field, Msg::Draft);
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Draft(text) => session.set_string("draft", &text),
        }
    }
}

fn main() {
    kaya::run(app)
}
