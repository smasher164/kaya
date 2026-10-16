// The cards scene, C# port — guests/rust/cards.rs, tools/scenes/cards.steps.

[KayaGen]
record LibraryPlaylist(string Name, bool Selected);

static class CardsScene
{
    static readonly (string Id, string Name)[] Cards =
        { ("card1", "Daily Mix 1"), ("card2", "Daily Mix 2"), ("card3", "Discover Weekly") };
    static readonly (string Key, string Name)[] Library =
        { ("p1", "Liked Songs"), ("p2", "Late Night Jazz"), ("p3", "Focus") };

    public static void Run()
    {
        var app = new KayaApp();
        app.Build(tx =>
        {
            tx.Window(title: "cards", width: 520, height: 520);
            var status = tx.Signal("opened: none");
            var library = LibraryPlaylistKaya.Collection(tx);
            tx.Mount(tx.Column(root =>
            {
                tx.Grid(3, _ =>
                {
                    foreach (var (id, name) in Cards)
                    {
                        var title = tx.Signal(name);
                        var line = tx.Signal("Made for you");
                        tx.Column(card =>
                        {
                            tx.Label(bind: title);
                            tx.Caption(bind: line);
                            tx.SetA11yId(card, id);
                        }, filled: Tint.Neutral, onActivate: t => t.Write(status, $"opened: {name}"));
                    }
                }, spacing: 12);
                tx.SetA11yId(tx.Label(bind: status), "status");
                LibraryPlaylistKaya.Each(tx, library, row =>
                {
                    var item = row.Row(() => row.Label(row.Name));
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
                library.Insert(tx, key, new LibraryPlaylist(name, false));
        });
        System.Environment.Exit(app.Run());
    }
}
