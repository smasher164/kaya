// The search scene, C# port — guests/rust/search.rs,
// tools/scenes/search.steps. The app owns the filter
// (docs/search-plan.md S9): the visible set is a diff of removes and
// inserts by key.

using System.Collections.Generic;
using System.Linq;

[KayaGen]
record SearchItem(string Name);

static class SearchScene
{
    static readonly string[] Names = { "apple", "banana", "cherry", "mango" };

    public static void Run()
    {
        var app = new KayaApp();
        var visible = new List<string>(Names);

        app.Build(tx =>
        {
            var items = SearchItemKaya.Collection(tx);
            var count = tx.Signal($"{Names.Length} items");

            tx.Mount(tx.Column(() =>
            {
                var find = tx.Search(onChange: (t, text) =>
                {
                    var query = text.ToLowerInvariant();
                    var wanted = Names.Where(n => n.Contains(query)).ToList();
                    // A DIFF, never clear-and-refill: only the rows whose
                    // membership changed move (docs/search-plan.md S9).
                    foreach (var name in visible)
                        if (!wanted.Contains(name))
                            t.Remove(items.Collection, name);
                    foreach (var name in wanted)
                        if (!visible.Contains(name))
                            items.Insert(t, name, new SearchItem(name));
                    // Insertion order is arrival order, so a row coming back
                    // lands last; walking the wanted keys to the end in
                    // order puts the list back in Names order.
                    foreach (var name in wanted)
                        items.MoveToEnd(t, name);
                    t.Write(count, query.Length == 0
                        ? $"{Names.Length} items"
                        : $"{wanted.Count} of {Names.Length} match");
                    visible = wanted;
                });
                tx.SetPlaceholder(find, "Search");
                tx.SetA11yId(find, "find");
                tx.SetA11yLabel(find, "Find items");
                tx.SetA11yId(tx.Label(bind: count), "count");
                // The For IS the list: expect_order reads its label children.
                var list = tx.Each(items.Collection, t =>
                {
                    var row = new SearchItemRow(t);
                    row.Label(row.Name);
                });
                tx.SetA11yId(list, "list");
            }));

            foreach (var name in Names)
                items.Insert(tx, name, new SearchItem(name));
        });

        System.Environment.Exit(app.Run());
    }
}
