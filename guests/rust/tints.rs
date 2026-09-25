//! The tints scene (tools/scenes/tints.steps; docs/tints-plan.md): one
//! filled row per tint, an unfilled row beside them, and a stamped row
//! filled from the template zone, which is where a chat thread's bubbles
//! live.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Note {
    text: String,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("tints").size(420.0, 520.0);
        let notes = tx.collection::<Note>();
        let root = tx
            .column(|tx| {
                for (id, text, tint) in [
                    ("t_accent", "Accent", kaya::Tint::Accent),
                    ("t_success", "Saved", kaya::Tint::Success),
                    ("t_warning", "Almost full", kaya::Tint::Warning),
                    ("t_critical", "Failed to send", kaya::Tint::Critical),
                    ("t_neutral", "Neutral", kaya::Tint::Neutral),
                ] {
                    let label = tx.signal(text);
                    tx.row(|tx| {
                        tx.label(label);
                    })
                    .a11y_id(id)
                    .filled(tint);
                }
                let plain = tx.signal("Plain");
                tx.row(|tx| {
                    tx.label(plain);
                })
                .a11y_id("t_plain");
                for mut row in notes.rows(tx) {
                    let (bubble, _) = row.row(|t| {
                        t.label(Note::text());
                    });
                    row.a11y_id(bubble, "bubble");
                    row.filled(bubble, kaya::Tint::Accent);
                }
            })
            .spacing(8.0)
            .id();
        tx.mount(root);
        tx.insert(&notes, "n1", Note { text: "On my way".to_string() });
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
