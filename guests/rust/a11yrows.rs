//! The stamped-accessibility scene: two entries stamped from one
//! template, each carrying its OWN ROW's a11y identity, read back out
//! of the platform's real accessibility tree. The a11y scene proves the
//! wrap-native bet for LIVE widgets; this one proves it for COPIES —
//! the case none of the accessibility milestone's 719 legs ever
//! exercised, because until the template zone could spell the props
//! (docs/tpl-props-plan.md P1) no guest could author a stamped widget's
//! name at all.
//!
//! A SEPARATE SCENE BY DESIGN, not by size: a For materializes as a
//! column, harness registries are creation-order, and container
//! creation order differs by language — so the a11y scene, which
//! asserts every container kind ordinally, cannot host a For without
//! `column#0` meaning different widgets on different lanes. This scene
//! asserts no container, so the For's column may land anywhere in the
//! registry (guests/haskell/reorder.hs documents the ordering rule).
//!
//! The byte-frozen contract is tools/scenes/a11yrows.steps.

pub(crate) fn app(ctx: kaya::AppCtx) {
    // Static after construction: the keep-alive idiom, as the a11y
    // scene uses.
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let root = tx
            .column(|tx| {
                // BOTH PROPS ELEMENT-SOURCED. The label is the point —
                // a list row announcing its own name to assistive tech.
                // The id is forced: expect_ax searches the real tree BY
                // the authored identifier, so copies sharing a const id
                // are indistinguishable to it and the read refuses them
                // (it answered with the first copy's label for the
                // second's index until it learned to). A shared const
                // id stays legal in the core; it is just unreadable by
                // that verb.
                let notes = tx.collection::<String>();
                for mut note in notes.rows(tx) {
                    let field = note.entry();
                    note.a11y_id(field, kaya::Field::element());
                    note.a11y_label(field, kaya::Field::element());
                }
                tx.insert_fresh(&notes, "First note");
                tx.insert_fresh(&notes, "Second note");

                // THE STAMPED STYLING PROPS. A second collection rather
                // than two elements in the first, because expect_ax
                // addresses the tree by IDENTIFIER and refuses an
                // ambiguous one — a scalar row has one field to spend on
                // an id, so a second readable copy needs its own strings.
                //
                // Both props are CONST here and const in every binding:
                // what a copy MEANS and how far its prototype holds its
                // children off its edge are facts about the prototype,
                // not about the row's data (`accepts`'s rule).
                let heads = tx.collection::<String>();
                for mut head in heads.rows(tx) {
                    // BOTH TEMPLATE SURFACES, deliberately: the row trace
                    // itself carries `inset`, the `Tpl` handed to the
                    // container body carries `role`. `Row` forwards to
                    // `Tpl` one method at a time by hand, so a prop on
                    // one and not the other is reachable through
                    // `for_each` and not `for row in rows`
                    // (tools/tpl-surfaces.py holds the pair level).
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
