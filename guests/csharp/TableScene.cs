// The table scene from C#: column headers and click-to-sort on the
// For vocabulary (docs/tables-plan.md). A header click is a REQUEST —
// this guest reorders its collection BY KEY (the reorder scene's
// idiom) and re-declares the header with the new indicator; the
// platform sorts nothing. The byte-frozen contract is
// tools/scenes/table.steps.

using System.Linq;

[KayaGen]
record TableItem(string Name, string Size);

static class TableScene
{
    // The guest's sort policy — the platform never has one: clicking
    // the sorted column flips it, clicking another starts ascending.
    static long sortedCol = -1;
    static bool sortedDesc;

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var items = TableItemKaya.Collection(tx);
            // The root is a Row so the For's container is the scene's
            // only column-kind widget (the reorder scene's rule). The
            // table IS the For, headers declared on the Widget the
            // template form returns.
            tx.Mount(tx.Row(() =>
            {
                var table = TableItemKaya.Each(tx, items, row =>
                {
                    row.Row(() =>
                    {
                        row.Label(row.Name);
                        row.Label(row.Size);
                    });
                });
                // Grown on purpose: this scene asserts the
                // fill-and-scroll viewport, the grown half of the
                // empty-row ruling — ungrown would hug its rows
                // (tables-plan decision 8).
                tx.SetGrow(table, 1);
                tx.Columns(table, new[] { "Name", "Size" }, Sort.None);
                app.OnSort(table, (t, column) =>
                {
                    bool desc = sortedCol == column && !sortedDesc;
                    (sortedCol, sortedDesc) = (column, desc);
                    var entries = items.Items(t);
                    var ordered = column == 0
                        ? entries.OrderBy(e => e.Value.Name, System.StringComparer.Ordinal)
                        : entries.OrderBy(e => e.Value.Size, System.StringComparer.Ordinal);
                    var target = (desc ? ordered.Reverse() : ordered).ToList();
                    // Keys, never indices: moving each key to the end
                    // in the target order leaves the collection sorted.
                    foreach (var e in target)
                        items.MoveToEnd(t, e.Key);
                    t.Columns(table, new[] { "Name", "Size" },
                        desc ? Sort.Desc(column) : Sort.Asc(column));
                });
            }));
            foreach (var (key, name, size) in new[]
            {
                ("b", "banana", "30"), ("a", "apple", "10"), ("c", "cherry", "20"),
            })
                items.Insert(tx, key, new TableItem(name, size));
        });

        System.Environment.Exit(app.Run());
    }
}
