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
            });
            tx.Mount(root);
        });

        System.Environment.Exit(app.Run());
    }
}
