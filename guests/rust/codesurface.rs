//! The code surface scene (tools/scenes/codesurface.steps,
//! docs/code-surface-plan.md): a textarea that numbers its lines, the
//! platform's monospaced face, a family the app picks from the platform's
//! list, a family the platform lacks, and a label at twice the platform's size.

/// Forty lines; the third wraps at every lane's width.
fn document() -> String {
    let mut lines = vec![
        "// codesurface".to_string(),
        "fn main() {".to_string(),
        "    let note = \"this line is long on purpose, so that the textarea wraps it onto a second row \
         and the gutter has a continuation to leave unnumbered, the way every editor does\";"
            .to_string(),
    ];
    for i in 4..40 {
        lines.push(format!("    let value_{i:02} = {i} * 2;"));
    }
    lines.push("}".to_string());
    lines.join("\n")
}

#[derive(Clone)]
enum Msg {
    End,
    List,
    Families(Vec<String>),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let doc = document();
    let (code, listed, picked) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("codesurface");
        let listed = tx.signal("families: -".to_string());
        let picked_family = tx.signal(String::new());
        let (root, code) = tx
            .column(|tx| {
                let code = tx.textarea().line_numbers(true).monospaced(true).a11y_id("code").id();
                tx.set_text(code, &doc);
                let plain = tx.textarea().a11y_id("plain").id();
                tx.set_text(plain, "plain text\nin the app's face");
                let text = tx.signal("let x = 1;");
                tx.label(text).monospaced(true).a11y_id("mono");
                let entry = tx.entry().monospaced(true).a11y_id("mono_entry").id();
                tx.set_text(entry, "let y = 2;");
                let text = tx.signal("missing");
                tx.label(text).family("Kaya No Such Family").monospaced(true).a11y_id("missing");
                let text = tx.signal("Big");
                tx.label(text).text_scale(2.0).a11y_id("big");
                let text = tx.signal("Plain");
                tx.label(text).a11y_id("plain_label");
                tx.label(listed).a11y_id("families");
                let text = tx.signal("picked");
                tx.label(text).family(picked_family).a11y_id("picked");
                tx.row(|tx| {
                    let end = tx.button("end").a11y_id("end").id();
                    msgs.on_click(end, Msg::End);
                    let list = tx.button("fonts").a11y_id("fonts").id();
                    msgs.on_click(list, Msg::List);
                });
                code
            })
            .into_parts();
        tx.mount(root);
        (code, listed, picked_family)
    });
    msgs.on_font_families(|families| Msg::Families(families.to_vec()));

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::End => ctx.apply(|tx| {
                let end = doc.len();
                tx.focus(code);
                tx.select_range(code, end..end);
                tx.reveal_range(code, end..end);
            }),
            Msg::List => ctx.apply(|tx| tx.list_font_families()),
            Msg::Families(families) => {
                let ordered = families.windows(2).all(|pair| pair[0] < pair[1]);
                let word = if families.is_empty() {
                    "families: none"
                } else if ordered {
                    "families: listed, unique, in order"
                } else {
                    "families: out of order"
                };
                ctx.apply(|tx| {
                    tx.write(listed, word.to_string());
                    if let Some(first) = families.first() {
                        tx.write(picked, first.clone());
                    }
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
