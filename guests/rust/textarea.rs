//! The textarea conformance scene (tools/scenes/textarea.steps): a newline
//! rides the text both ways, and `clear` echoes text_changed("").

#[derive(Clone)]
enum Msg {
    Edited(String),
    Clear,
}

fn count(text: &str) -> String {
    if text.is_empty() {
        "0 lines".to_string()
    } else {
        format!("{} lines", text.lines().count())
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (lines, editor) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("textarea");
        let lines = tx.signal("0 lines");
        let (root, editor) = tx
            .column(|tx| {
                let editor = tx.textarea().id();
                msgs.on_change(editor, Msg::Edited);
                tx.label(lines);
                let clear = tx.button("clear").id();
                msgs.on_click(clear, Msg::Clear);
                editor
            })
            .into_parts();
        tx.mount(root);
        (lines, editor)
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Edited(text) => {
                ctx.apply(|tx| {
                    tx.write(lines, count(&text));
                });
            }
            Msg::Clear => {
                ctx.apply(|tx| {
                    tx.clear(editor);
                    tx.focus(editor);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
