// The a11yrows scene, C# port — guests/rust/a11yrows.rs,
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
                // Element-sourced: expect_ax refuses an ambiguous authored id.
                var notes = tx.Collection();
                tx.Each(notes, t =>
                {
                    var field = t.Entry();
                    t.SetA11yId(field, Field<string>.Element);
                    t.SetA11yLabel(field, Field<string>.Element);
                });
                tx.InsertFresh(notes, "First note");
                tx.InsertFresh(notes, "Second note");

                // Through the generated <Rec>Row façade deliberately: it forwards
                // to Tpl one method at a time by hand.
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
