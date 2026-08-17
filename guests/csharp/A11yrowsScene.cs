// The stamped-accessibility scene from C#: two entries stamped from one
// template, each carrying its OWN ROW's accessibility identity, read
// back out of the platform's real tree. The a11y scene proves the
// wrap-native bet for LIVE widgets; this one proves it for COPIES — the
// case none of the accessibility milestone's 719 legs ever exercised,
// because until the template zone could spell the props
// (docs/tpl-props-plan.md P1) no guest could author a stamped widget's
// name at all.
//
// A SEPARATE SCENE BY DESIGN, not by size: a For materializes as a
// column, harness registries are creation-order, and container creation
// order differs by language — so the a11y scene, which asserts every
// container kind ordinally, cannot host a For without `column#0` meaning
// different widgets on different lanes. This scene asserts no container,
// so the For's column may land anywhere in the registry
// (guests/haskell/reorder.hs documents the ordering rule).
//
// Canonical semantics in guests/rust/a11yrows.rs; the byte-frozen
// contract is tools/scenes/a11yrows.steps.

static class A11yrowsScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var root = tx.Column(() =>
            {
                // BOTH PROPS ELEMENT-SOURCED. The label is the point —
                // a list row announcing its own name to assistive tech.
                // The id is forced: expect_ax resolves its target to the
                // authored identifier and then searches the real tree BY
                // that identifier, so copies sharing a const id are
                // indistinguishable to it and the read refuses the
                // ambiguity rather than answering with whichever it
                // found first. A shared const id stays legal in the core
                // — nothing there deduplicates — it is just not a thing
                // that verb can read back.
                var notes = tx.Collection();
                tx.Each(notes, t =>
                {
                    // A scalar collection IS its one field, so both
                    // sources are the element itself.
                    var field = t.Entry();
                    t.SetA11yId(field, Field<string>.Element);
                    t.SetA11yLabel(field, Field<string>.Element);
                });
                // A note here is a line of text and nothing else — no
                // identity of its own — so the key comes from the mint
                // and this scene never names one.
                tx.InsertFresh(notes, "First note");
                tx.InsertFresh(notes, "Second note");

                // THE STAMPED STYLING PROPS. A second collection rather
                // than two elements in the first, because expect_ax
                // addresses the tree by IDENTIFIER and refuses an
                // ambiguous one — a scalar row has one field to spend
                // on an id, so a second readable copy needs its own
                // strings.
                //
                // A RECORD collection where the notes above are scalar,
                // and the difference is C#'s: the SECOND template
                // surface here is the generated <Rec>Row façade, and
                // kaya-csgen emits one per [KayaGen] record — a scalar
                // tx.Collection() has no Rows() to trace. The façade
                // forwards to Tpl one method at a time by hand, so a
                // prop on Tpl and not on it is reachable through tx.Each
                // and not through `foreach (var row in c.Rows())`, which
                // is a difference no guest should have to know; tracing
                // this whole For through the façade is what proves the
                // two forwards are real, and each one calls the Tpl
                // method underneath.
                //
                // Both props are CONST here and const in every binding:
                // what a copy MEANS and how far its prototype holds its
                // children off its edge are facts about the prototype,
                // not about the row's data (SetAccepts's rule).
                var heads = ItemKaya.Collection(tx);
                foreach (var head in heads.Rows())
                {
                    var bar = head.Row(() =>
                    {
                        var title = head.Label(head.Title);
                        head.SetRole(title, Role.Heading);
                        head.SetA11yId(title, head.Title);
                    });
                    head.SetInset(bar, 8);
                }
                // A heading is a line of text too, so its key is minted
                // for the same reason the notes' are.
                heads.InsertFresh(tx, new Item("Heading one"));
                heads.InsertFresh(tx, new Item("Heading two"));
            });
            tx.Mount(root);
        });

        System.Environment.Exit(app.Run());
    }
}
