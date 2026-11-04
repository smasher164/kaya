//! The icons scene (tools/scenes/icons.steps; docs/looks-plan.md §3.1): a
//! symbol on its own, tinted, scaled, named, inside an accent fill, and
//! stamped from a template.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Note {
    text: String,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("icons").size(420.0, 520.0);
        let notes = tx.collection::<Note>();
        let root = tx
            .column(|tx| {
                tx.icon(kaya::Symbol::Star).a11y_id("plain");
                tx.icon(kaya::Symbol::Favorite).tint(kaya::Tint::Accent).a11y_id("accent");
                tx.icon(kaya::Symbol::Warning).tint(kaya::Tint::Critical).a11y_id("critical");
                tx.icon(kaya::Symbol::Done).text_scale(2.0).a11y_id("big");
                tx.icon(kaya::Symbol::Info).a11y_label("Information").a11y_id("named");
                let sent = tx.signal("Sent");
                tx.row(|tx| {
                    tx.icon(kaya::Symbol::Send).a11y_id("onfill");
                    tx.label(sent);
                })
                .a11y_id("fillrow")
                .filled(kaya::Tint::Accent);
                for mut row in notes.rows(tx) {
                    let (line, _) = row.row(|t| {
                        let glyph = t.icon(kaya::Symbol::Edit);
                        t.a11y_id(glyph, "stamped");
                        t.label(Note::text());
                    });
                    row.a11y_id(line, "note");
                }
            })
            .id();
        tx.mount(root);
        tx.insert(&notes, "n1", Note { text: "A note".into() });
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
