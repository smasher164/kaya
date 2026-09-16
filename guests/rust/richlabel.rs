//! The rich label scene (tools/scenes/richlabel.steps; docs/rich-text-plan.md
//! R8, §15): a label carries the inline vocabulary read-only — the app writes
//! its document and edits it, and the widget draws the runs over the role's
//! own font. THE OFFSETS ARE UTF-8 BYTES (docs/ranges-units.md).

const DOC: &str = "Héllo world, code";

#[derive(Clone)]
enum Msg {
    Seed,
    Insert,
    Mark,
}

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
    let (runs, body, heading) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("richlabel");
        let runs = tx.signal("");
        let (root, (body, heading)) = tx
            .column(|tx| {
                let body_text = tx.signal("");
                let heading_text = tx.signal("Heading with italic");
                let body = tx.label(body_text).rich().a11y_id("body").id(); // label#0
                let heading = tx
                    .label(heading_text)
                    .role(kaya::Role::Heading)
                    .rich()
                    .a11y_id("heading")
                    .id(); // label#1
                tx.label(runs).a11y_id("runs"); // label#2
                tx.row(|tx| {
                    for (title, msg) in [("seed", Msg::Seed), ("insert", Msg::Insert), ("mark", Msg::Mark)] {
                        let button = tx.button(title).id();
                        msgs.on_click(button, msg);
                    }
                });
                (body, heading)
            })
            .into_parts();
        tx.mount(root);
        (runs, body, heading)
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Seed => {
                let doc = kaya::Document::new(DOC)
                    .bold(0..6)
                    .link(7..12, "https://kaya.dev")
                    .mark(14..18, "code", "true");
                let title = kaya::Document::new("Heading with italic").mark(13..19, "italic", "true");
                ctx.apply(|tx| {
                    tx.set_document(body, &doc);
                    tx.set_document(heading, &title);
                    tx.write(runs, spell(&doc.runs));
                });
            }
            Msg::Insert => {
                let edit = kaya::Edit::insert(6, ", big").mark(2..5, "italic", "true");
                ctx.apply(|tx| tx.apply_edit(body, &edit));
                let mirror = spell(&ctx.document(body).runs);
                ctx.apply(|tx| tx.write(runs, mirror.clone()));
            }
            // THE RANGED ACT ON A LABEL (docs/rich-text-plan.md §17): an italic
            // over a range and the bold taken off another, the label's own
            // document written by range; the runs label is the binding's fold.
            Msg::Mark => {
                ctx.apply(|tx| {
                    tx.format_range(body, 1..4, "italic", "true");
                    tx.unformat_range(body, 0..3, "bold"); // "Hé": byte 2 is inside the é
                });
                let mirror = spell(&ctx.document(body).runs);
                ctx.apply(|tx| tx.write(runs, mirror.clone()));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
