// The reorder scene from C#: order as collection data. Handlers
// reposition an entry BY KEY and never touch a widget.
//
// The root is a Row so the For's container is the scene's only
// column-kind widget: languages disagree on whether containers are
// created before or after their children, and column#0 must name the
// same widget everywhere.
//
//     KAYA_SELFTEST=reorder KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

// The record is the schema; kaya-csgen reads this declaration and
// generates ItemKaya, the collection factory.
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
                    // The model owns the order, so the handler asks it
                    // which key is first; it never counts widgets.
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
