// The reorder scene from C#: order as collection data, end to end.
// Three stamped rows and two buttons that never touch a widget — each
// handler repositions an entry by key (collection_move on the wire,
// move_child at the toolkit), and the selftest's expect_order reads
// the toolkit's actual child order back. The root is a row so the
// For's container is the scene's only column-kind widget: languages
// disagree on whether containers are created before or after their
// children, and column#0 must name the same widget everywhere.
//
//     KAYA_SELFTEST=reorder KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

// The record is the schema.
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
            tx.Mount(tx.Row(
                tx.Button("rotate", t =>
                {
                    // First entry to the end. The model owns the
                    // order, so the handler asks it which key is
                    // first — it never counts widgets.
                    var entries = items.Items(t);
                    items.MoveToEnd(t, entries[0].Key);
                }),
                tx.Button("lift", t =>
                {
                    // Last entry to the front: MoveToFront is sugar
                    // for MoveBefore the current first key — the same
                    // wire op, keys never indices.
                    var entries = items.Items(t);
                    items.MoveToFront(t, entries[entries.Count - 1].Key);
                }),
                tx.Each(items.Collection, t => items.Label(t, x => x.Title))));
            foreach (var key in new[] { "a", "b", "c" })
                items.Insert(tx, key, new Item(key));
        });

        System.Environment.Exit(app.Run());
    }
}
