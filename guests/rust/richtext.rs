//! The rich text scene (tools/scenes/richtext.steps): the app declares a
//! document, applies an edit, formats the widget's selection through its
//! own act, and reads every delta back into its own Document. THE OFFSETS
//! ARE UTF-8 BYTES; the é in the first word is what makes a UTF-16 reader
//! fail (docs/ranges-units.md).

const DOC: &str = "Héllo world\nSecond line";

#[derive(Clone)]
enum Msg {
    Edited(kaya::Edit),
    Formatted(kaya::Format),
    Seed,
    Insert,
    SelectWord,
    Unbold,
    Heading,
    Focus,
    Prefix,
}

/// The core's spelling of runs (`expect_runs`), so the binding's document
/// and the core's mirror are compared as one string.
fn spell(runs: &[kaya::Run]) -> String {
    runs.iter()
        .map(|run| {
            if run.value == "true" {
                format!("{}:{} {}", run.start, run.end, run.name)
            } else {
                format!("{}:{} {}={}", run.start, run.end, run.name, run.value)
            }
        })
        .collect::<Vec<_>>()
        .join("|")
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (last, runs, editor) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("richtext");
        let last = tx.signal("");
        let runs = tx.signal("");
        let (root, editor) = tx
            .column(|tx| {
                let editor = tx.textarea().rich().a11y_id("doc").a11y_label("Document").id();
                msgs.on_edit(editor, Msg::Edited);
                msgs.on_format(editor, Msg::Formatted);
                tx.label(last);
                tx.label(runs);
                tx.row(|tx| {
                    for (title, msg) in [
                        ("seed", Msg::Seed),
                        ("insert", Msg::Insert),
                        ("select word", Msg::SelectWord),
                        ("unbold", Msg::Unbold),
                        ("heading", Msg::Heading),
                        ("focus", Msg::Focus),
                        ("prefix", Msg::Prefix),
                    ] {
                        let button = tx.button(title).id();
                        msgs.on_click(button, msg);
                    }
                });
                editor
            })
            .into_parts();
        tx.mount(root);
        (last, runs, editor)
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Edited(edit) => {
                let mirror = spell(&ctx.document(editor).runs);
                ctx.apply(|tx| {
                    tx.write(
                        last,
                        format!(
                            "edit {}:{} <{}> [{}]",
                            edit.start,
                            edit.end,
                            edit.inserted,
                            spell(&edit.runs)
                        ),
                    );
                    tx.write(runs, mirror.clone());
                });
            }
            Msg::Formatted(act) => {
                let mirror = spell(&ctx.document(editor).runs);
                ctx.apply(|tx| {
                    tx.write(
                        last,
                        format!(
                            "format {}:{} {}={}",
                            act.start,
                            act.end,
                            act.name,
                            act.value.as_deref().unwrap_or("off")
                        ),
                    );
                    tx.write(runs, mirror.clone());
                });
            }
            Msg::Seed => {
                let doc = kaya::Document::new(DOC)
                    .bold(0..6)
                    .link(7..12, "https://kaya.dev")
                    .block(13..24, kaya::Block::Heading2);
                ctx.apply(|tx| {
                    tx.set_document(editor, &doc);
                    tx.write(runs, spell(&doc.runs));
                });
            }
            Msg::Insert => {
                let edit = kaya::Edit::insert(6, ", big").mark(2..5, "italic", "true");
                ctx.apply(|tx| tx.apply_edit(editor, &edit));
                let mirror = spell(&ctx.document(editor).runs);
                ctx.apply(|tx| tx.write(runs, mirror.clone()));
            }
            Msg::SelectWord => ctx.apply(|tx| tx.select_range(editor, 0..6)),
            Msg::Unbold => ctx.apply(|tx| tx.unformat(editor, "bold")),
            Msg::Heading => ctx.apply(|tx| tx.set_block(editor, kaya::Block::Heading1)),
            Msg::Focus => ctx.apply(|tx| tx.focus(editor)),
            Msg::Prefix => {
                let edit = kaya::Edit::insert(0, "> ");
                ctx.apply(|tx| tx.apply_edit(editor, &edit));
                let mirror = spell(&ctx.document(editor).runs);
                ctx.apply(|tx| tx.write(runs, mirror.clone()));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
