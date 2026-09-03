// The table scene, C# port — guests/rust/table.rs, tools/scenes/table.steps.

using System.Linq;

[KayaGen]
record TableItem(string Name, string Size);

static class TableScene
{
    // The guest's sort policy; the platform never has one.
    static long sortedCol = -1;
    static bool sortedDesc;

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var items = TableItemKaya.Collection(tx);
            // The root is a Row so the For's container is the scene's only
            // column-kind widget (the reorder scene's rule).
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
                // Grown on purpose: ungrown would hug its rows
                // (docs/tables-plan.md decision 8).
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
                    // Keys, never indices.
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
