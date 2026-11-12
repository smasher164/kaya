//! The rich document scene (tools/scenes/richdoc.steps,
//! docs/rich-document-plan.md §9 step 2): a heading, a body paragraph with a
//! preset colour, a bullet list with a nested item, a numbered list and a
//! checklist, then the paragraph acts from buttons, the platform's colour
//! picker and a `.kdoc` round trip, then a file carrying keys this kaya
//! does not know (RD17). label#1 is the binding's own Document, folded from
//! the same deltas, so it must spell what the core holds.

const DOC: &str = "Groceries\nFresh from the market.\nApples\nGreen ones\nBread\nWash\nSlice\nMilk\nEggs";

const UNKNOWN: &str = r#"{"kaya": "document", "version": 1, "com.example.theme": {"page": "sepia"}, "paragraphs": [{"embed": "e1", "spans": [["Loose"]]}, {"com.example.pinned": true, "spans": [["Pinned"]]}]}"#;

#[derive(Clone)]
enum Msg {
    Edited(kaya::Edit),
    Formatted(kaya::Format),
    Numbered,
    Indent,
    Red,
    PickColour,
    Kdoc,
    Unknown,
}

fn spell(runs: &[kaya::Run]) -> String {
    runs.iter()
        .map(|run| {
            if run.is_flag() {
                format!("{}:{} {}", run.range.start, run.range.end, run.name)
            } else {
                format!("{}:{} {}={}", run.range.start, run.range.end, run.name, run.value)
            }
        })
        .collect::<Vec<_>>()
        .join("|")
}

fn seeded() -> kaya::Document {
    kaya::Document::new(DOC)
        .block(0..9, kaya::Block::Heading1)
        .color(25..31, "#016FEF")
        .list(33..56, kaya::ListKind::Bullet)
        .indent(40..50, 1)
        .list(57..67, kaya::ListKind::Numbered)
        .checked(68..72)
        .list(68..77, kaya::ListKind::Check)
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let doc = seeded();
    let (last, runs, kdoc, editor) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("richdoc")
            .size(560.0, 620.0)
            .menu("Edit", |m| {
                m.item("Cut").role(kaya::MenuRole::Cut).id();
                m.item("Copy").role(kaya::MenuRole::Copy).id();
                m.item("Paste").role(kaya::MenuRole::Paste).id();
            })
            .id();
        let last = tx.signal("");
        let runs = tx.signal(spell(&doc.runs));
        let kdoc = tx.signal("");
        let (root, editor) = tx
            .column(|tx| {
                let editor = tx.textarea().rich().grow(1.0).a11y_id("doc").a11y_label("Document").id();
                msgs.on_edit(editor, Msg::Edited);
                msgs.on_format(editor, Msg::Formatted);
                tx.label(last);
                tx.label(runs);
                tx.label(kdoc);
                tx.row(|tx| {
                    for (title, msg) in [
                        ("numbered", Msg::Numbered),
                        ("indent", Msg::Indent),
                        ("red", Msg::Red),
                        ("colour", Msg::PickColour),
                        ("kdoc", Msg::Kdoc),
                        ("unknown", Msg::Unknown),
                    ] {
                        let button = tx.button(title).id();
                        msgs.on_click(button, msg);
                    }
                });
                editor
            })
            .into_parts();
        tx.mount(root);
        tx.set_document(editor, &doc);
        (last, runs, kdoc, editor)
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Edited(edit) => {
                let mirror = spell(&ctx.document(editor).runs);
                ctx.apply(|tx| {
                    tx.write(
                        last,
                        format!(
                            "edit {}:{} <{}> {} [{}]",
                            edit.start,
                            edit.end,
                            edit.inserted.replace('\n', "\\n"),
                            edit.source.map_or("?", |s| s.name()),
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
                        format!("format {}:{} {}={}", act.start, act.end, act.name, act.value.as_deref().unwrap_or("off")),
                    );
                    tx.write(runs, mirror.clone());
                });
            }
            Msg::Numbered => ctx.apply(|tx| tx.set_list(editor, kaya::ListKind::Numbered)),
            Msg::Indent => ctx.apply(|tx| tx.indent(editor)),
            Msg::Red => ctx.apply(|tx| tx.color(editor, "#DD1F24")),
            Msg::PickColour => ctx.apply(|tx| tx.pick_text_color(editor)),
            Msg::Kdoc => {
                let now = ctx.document(editor);
                let bytes = now.to_kdoc();
                let back = kaya::Document::from_kdoc(&bytes).expect("kaya wrote a .kdoc it cannot read");
                let status = format!(
                    "kdoc {} bytes, read_only {}, same {}, extra {}",
                    bytes.len(),
                    back.read_only.as_deref().unwrap_or("none"),
                    back.document == now,
                    if back.document.extra.is_empty() { "none".to_owned() } else { back.document.extra.replace('"', "'") }
                );
                ctx.apply(|tx| {
                    tx.set_document(editor, &back.document);
                    tx.write(kdoc, status.clone());
                    tx.write(runs, spell(&back.document.runs));
                });
            }
            Msg::Unknown => {
                let file = kaya::Document::from_kdoc(UNKNOWN.as_bytes()).expect("the scene's file reads");
                let status =
                    format!("opened read_only {}, extra {}", file.read_only.as_deref().unwrap_or("none"), file.document.extra.replace('"', "'"));
                ctx.apply(|tx| {
                    tx.set_document(editor, &file.document);
                    tx.write(kdoc, status.clone());
                    tx.write(runs, spell(&file.document.runs));
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
