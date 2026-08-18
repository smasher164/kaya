//! The stamped-accessibility scene: two entries stamped from one
//! template, each carrying its OWN ROW's a11y identity, read back out
//! of the platform's real accessibility tree. The byte-frozen contract
//! is tools/scenes/a11yrows.steps.
//!
//! IT ASSERTS NO CONTAINER, and must not start: a For materializes as a
//! column, so a scene with a For cannot also name containers ordinally
//! (the a11y scene does, which is why this is separate).

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let root = tx
            .column(|tx| {
                // BOTH PROPS ELEMENT-SOURCED. The id is forced: expect_ax
                // searches the real tree BY the authored identifier and
                // refuses an ambiguous one, so copies may not share a
                // const id (legal in the core, just unreadable here).
                let notes = tx.collection::<String>();
                for mut note in notes.rows(tx) {
                    let field = note.entry();
                    note.a11y_id(field, kaya::Field::element());
                    note.a11y_label(field, kaya::Field::element());
                }
                tx.insert_fresh(&notes, "First note");
                tx.insert_fresh(&notes, "Second note");

                // THE STAMPED STYLING PROPS, in a SECOND collection: a
                // scalar row has one field to spend on an id, so a
                // second readable copy needs its own strings. Both props
                // are const in every binding.
                let heads = tx.collection::<String>();
                for mut head in heads.rows(tx) {
                    // BOTH TEMPLATE SURFACES, deliberately: `inset` off
                    // the row trace, `role` off the `Tpl`. `Row` forwards
                    // to `Tpl` by hand, so tools/tpl-surfaces.py is what
                    // holds the pair level.
                    let (bar, _) = head.row(|t| {
                        let title = t.label(kaya::Field::element());
                        t.role(title, kaya::Role::Heading);
                        t.a11y_id(title, kaya::Field::element());
                    });
                    head.inset(bar, 8.0);
                }
                tx.insert_fresh(&heads, "Heading one");
                tx.insert_fresh(&heads, "Heading two");
            })
            .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
