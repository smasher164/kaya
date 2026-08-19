// The stamped-accessibility scene from C#: two entries stamped from one
// template, each carrying its OWN ROW's identity, read back out of the
// platform's real tree (docs/tpl-props-plan.md P1). It may not be folded
// into the a11y scene: a For materializes as a column and container
// creation order differs by language, so a scene asserting containers
// ordinally cannot host one. See guests/rust/a11yrows.rs,
// tools/scenes/a11yrows.steps.

static class A11yrowsScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var root = tx.Column(() =>
            {
                // Both props element-sourced. The id has to be: expect_ax
                // searches the real tree BY the authored identifier and
                // refuses an ambiguous one, so copies may not share a
                // const id (legal in the core, just unreadable there).
                var notes = tx.Collection();
                tx.Each(notes, t =>
                {
                    // A scalar collection IS its one field, so both
                    // sources are the element itself.
                    var field = t.Entry();
                    t.SetA11yId(field, Field<string>.Element);
                    t.SetA11yLabel(field, Field<string>.Element);
                });
                tx.InsertFresh(notes, "First note");
                tx.InsertFresh(notes, "Second note");

                // The stamped styling props, on a second collection: a
                // scalar row has one field to spend on an id, so a second
                // readable copy needs its own strings.
                //
                // Traced through the generated <Rec>Row façade rather than
                // tx.Each deliberately: that façade forwards to Tpl one
                // method at a time by hand.
                //
                // Both props are const here and const in every binding.
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
                heads.InsertFresh(tx, new Item("Heading one"));
                heads.InsertFresh(tx, new Item("Heading two"));
            });
            tx.Mount(root);
        });

        System.Environment.Exit(app.Run());
    }
}
