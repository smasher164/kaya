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
        tx.window(kaya::DEFAULT_WINDOW).title("tints").size(420.0, 620.0);
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
                let note = tx.signal("Updated today");
                tx.caption(note).a11y_id("t_caption");
                for (id, text, rgb) in [("t_amber", "Amber", (0xF2, 0xB0, 0x1E)), ("t_navy", "Navy", (0x1D, 0x6F, 0x8C))] {
                    let label = tx.signal(text);
                    tx.row(|tx| {
                        tx.label(label);
                    })
                    .a11y_id(id)
                    .filled_color(kaya::Color::rgb(rgb.0, rgb.1, rgb.2));
                }
                // Two lines: the platform's card radius, where every one-line
                // fill above is a capsule (docs/looks-plan.md §6).
                let (first, second) = (tx.signal("Two lines"), tx.signal("of filled text"));
                tx.column(|tx| {
                    tx.label(first);
                    tx.label(second);
                })
                .a11y_id("t_card")
                .filled(kaya::Tint::Accent);
                for mut row in notes.rows(tx) {
                    let (bubble, _) = row.row(|t| {
                        t.label(Note::text());
                    });
                    row.a11y_id(bubble, "bubble");
                    row.filled(bubble, kaya::Tint::Accent);
                    let (swatch, _) = row.row(|t| {
                        t.label(Note::text());
                    });
                    row.a11y_id(swatch, "swatch");
                    row.filled_color(swatch, kaya::Color::rgb(0x4A, 0x3A, 0xA8));
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
