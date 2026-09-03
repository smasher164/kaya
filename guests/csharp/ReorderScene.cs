// The reorder scene, C# port — guests/rust/reorder.rs,
// tools/scenes/reorder.steps.

[KayaGen]
record Item(string Title);

static class ReorderScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var items = ItemKaya.Collection(tx);
            tx.Mount(tx.Row(() =>
            {
                tx.Button("rotate", t =>
                {
                    var entries = items.Items(t);
                    items.MoveToEnd(t, entries[0].Key);
                });
                tx.Button("lift", t =>
                {
                    var entries = items.Items(t);
                    items.MoveToFront(t, entries[entries.Count - 1].Key);
                });
                foreach (var row in items.Rows())
                    row.Label(row.Title);
            }));
            foreach (var key in new[] { "a", "b", "c" })
                items.Insert(tx, key, new Item(key));
        });

        System.Environment.Exit(app.Run());
    }
}
