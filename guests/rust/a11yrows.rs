//! The stamped-a11y scene (tools/scenes/a11yrows.steps). IT ASSERTS NO
//! CONTAINER, and must not start: a For materializes as a column.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let root = tx
            .column(|tx| {
                // expect_ax REFUSES copies that share one const id.
                let notes = tx.collection::<String>();
                for mut note in notes.rows(tx) {
                    let field = note.entry();
                    note.a11y_id(field, kaya::Field::element());
                    note.a11y_label(field, kaya::Field::element());
                }
                tx.insert_fresh(&notes, "First note");
                tx.insert_fresh(&notes, "Second note");

                // A SECOND collection: a scalar row has one field for an
                // id, and both props below are CONST in every binding.
                let heads = tx.collection::<String>();
                for mut head in heads.rows(tx) {
                    // BOTH TEMPLATE SURFACES: `Row` forwards to `Tpl` by
                    // hand, and tools/tpl-surfaces.py holds them level.
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
