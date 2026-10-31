// The search scene, C# port — guests/rust/search.rs,
// tools/scenes/search.steps. The app owns the predicate
// (docs/search-plan.md S9) and each row hides in place
// (docs/hidden-plan.md).

using System.Linq;

[KayaGen]
record SearchItem(string Name, bool Unmatched);

static class SearchScene
{
    static readonly string[] Names = { "apple", "banana", "cherry", "mango" };

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "search");
            var items = SearchItemKaya.Collection(tx);
            var count = tx.Signal($"{Names.Length} items");

            tx.Mount(tx.Column(root =>
            {
                var find = tx.Search(onChange: (t, text) =>
                {
                    var query = text.ToLowerInvariant();
                    var wanted = Names.Count(n => n.Contains(query));
                    foreach (var name in Names)
                        SearchItemKaya.Patch(t, items, name).Unmatched(!name.Contains(query));
                    t.Write(count, query.Length == 0
                        ? $"{Names.Length} items"
                        : $"{wanted} of {Names.Length} match");
                });
                tx.SetPlaceholder(find, "Search");
                tx.SetA11yId(find, "find");
                tx.SetA11yLabel(find, "Find items");
                tx.SetA11yId(tx.Label(bind: count), "count");
                // The For IS the list: expect_order reads its label children.
                var list = tx.Each(items.Collection, t =>
                {
                    var row = new SearchItemRow(t);
                    t.SetHidden(row.Label(row.Name), SearchItemKaya.Unmatched);
                });
                tx.SetA11yId(list, "list");
                return root;
            }));

            foreach (var name in Names)
                items.Insert(tx, name, new SearchItem(name, false));
        });

        System.Environment.Exit(app.Run());
    }
}
