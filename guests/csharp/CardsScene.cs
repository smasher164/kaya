// The cards scene, C# port — guests/rust/cards.rs, tools/scenes/cards.steps.

[KayaGen]
record LibraryPlaylist(string Name, bool Selected, Symbol Symbol);

static class CardsScene
{
    static readonly (string Id, string Name)[] Cards =
        { ("card1", "Daily Mix 1"), ("card2", "Daily Mix 2"), ("card3", "Discover Weekly") };
    // The third card is taller, so the row's cards take its height (M16 (1)).
    const string Tall = "card3";
    // Cut at two lines with the platform's ellipsis (M16 (2)).
    const string Blurb = "Fresh picks every Monday, from the artists you play the most and the ones they listen to";
    static readonly (string Key, string Name)[] Library =
        { ("p1", "Liked Songs"), ("p2", "Late Night Jazz"), ("p3", "Focus") };

    static Widget Card(Tx tx, Signal status, string id, string name) =>
        tx.Column(card =>
        {
            tx.Label(bind: tx.Signal(name));
            tx.Caption(bind: tx.Signal("Made for you"));
            if (id == Tall)
            {
                var blurb = tx.Caption(bind: tx.Signal(Blurb));
                tx.SetMaxLines(blurb, 2);
                tx.SetA11yId(blurb, "blurb");
            }
            tx.SetA11yId(card, id);
            return card;
        }, filled: Tint.Neutral, onActivate: t => t.Write(status, $"opened: {name}"));

    public static void Run()
    {
        var app = new KayaApp();
        app.Build(tx =>
        {
            tx.Window(title: "cards", width: 520, height: 520);
            var status = tx.Signal("opened: none");
            var library = LibraryPlaylistKaya.Collection(tx);
            // A section hidden by a When and an empty For take no space (M16 (3)).
            var hidden = tx.Signal(false);
            var empty = LibraryPlaylistKaya.Collection(tx);
            tx.Mount(tx.Column(root =>
            {
                var grid = tx.Grid(1, g =>
                {
                    foreach (var (id, name) in Cards) Card(tx, status, id, name);
                    return g;
                }, spacing: 12);
                tx.SetColumnsAuto(grid, 140);
                tx.SetA11yId(grid, "cards");
                tx.SetA11yId(tx.Button("More", t => t.Within(grid, () => Card(t, status, "card4", "Release Radar"))), "more");
                tx.SetA11yId(tx.Label(bind: status), "status");
                tx.When(hidden, t => t.Label("never shown"));
                LibraryPlaylistKaya.Each(tx, empty, row => row.Row(() => row.Label(row.Name)));
                tx.SetA11yId(tx.Label("end"), "end");
                LibraryPlaylistKaya.Each(tx, library, row =>
                {
                    Node item = default!;
                    row.Row(() =>
                    {
                        item = row.Row(() => row.Label(row.Name));
                        var play = row.Button("Play");
                        row.SetSymbol(play, row.Symbol);
                        row.SetA11yId(play, "go");
                        app.OnClick(play, (t, keys) =>
                        {
                            var played = (string)keys[0];
                            foreach (var (key, _) in Library)
                                LibraryPlaylistKaya.Patch(t, library, key)
                                    .Symbol(key == played ? Symbol.Pause : Symbol.Play);
                        });
                    });
                    row.SetA11yId(item, "lib");
                    row.SetSelected(item, row.Selected);
                    row.OnActivate(item, (t, keys) =>
                    {
                        var picked = (string)keys[0];
                        foreach (var (key, _) in Library)
                            LibraryPlaylistKaya.Patch(t, library, key).Selected(key == picked);
                    });
                });
                return root;
            }, spacing: 16));
            foreach (var (key, name) in Library)
                library.Insert(tx, key, new LibraryPlaylist(name, false, Symbol.Play));
        });
        System.Environment.Exit(app.Run());
    }
}
