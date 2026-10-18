// The tracks scene, C# port — guests/rust/tracks.rs, tools/scenes/tracks.steps.

[KayaGen]
record PlaylistTrack(string Number, string Title, string Artist, string Album, byte[] Art, Tint TitleTint, bool Selected);

static class TracksScene
{
    const int Playlist = 60;
    const int Playing = 3;
    static readonly (string Title, string Artist, string Album)[] Names =
    {
        ("Blue in Green", "Miles Davis", "Kind of Blue"),
        ("So What", "Miles Davis", "Kind of Blue"),
        ("Naima", "John Coltrane", "Giant Steps"),
    };

    static Widget Table(Tx tx, RecordCollection<PlaylistTrack> tracks, string id, string rowId,
        System.Action<Tx, string> pick, System.Action<Tx, string> play)
    {
        var table = PlaylistTrackKaya.Each(tx, tracks, row =>
        {
            var line = row.Row(() =>
            {
                row.Label(row.Number);
                row.Row(() =>
                {
                    var image = row.Image(row.Art);
                    row.SetFit(image, Fit.Cover);
                    row.SetMaxWidth(image, 40);
                    row.SetMaxHeight(image, 40);
                    row.SetShape(image, Shape.Rounded);
                    row.SetA11yId(image, "art");
                    row.Column(() =>
                    {
                        var title = row.Label(row.Title);
                        row.SetTint(title, row.TitleTint);
                        row.SetA11yId(title, "name");
                        row.Caption(row.Artist);
                    });
                });
                row.Label(row.Album);
            });
            row.SetA11yId(line, rowId);
            row.SetSelected(line, row.Selected);
            row.OnSelect(line, (t, keys) => pick(t, (string)keys[0]));
            row.OnActivate(line, (t, keys) => play(t, (string)keys[0]));
        });
        tx.Columns(table, new[] { "#", "Title", "Album" }, Sort.None);
        tx.SetA11yId(table, id);
        return table;
    }

    static PlaylistTrack Track(int i, byte[] art)
    {
        var (title, artist, album) = Names[i % Names.Length];
        return new PlaylistTrack((i + 1).ToString(), title, artist, album, art,
            i + 1 == Playing ? Tint.Accent : Tint.None, false);
    }

    public static void Run()
    {
        var app = new KayaApp();
        app.Build(tx =>
        {
            tx.Window(title: "tracks", width: 720, height: 640);
            byte[] art;
            using (var asset = tx.Asset("covers/cover-600.jpg")) art = asset.Bytes();
            var album = PlaylistTrackKaya.Collection(tx);
            var playlist = PlaylistTrackKaya.Collection(tx);
            var pickedText = tx.Signal("picked: none");
            var played = tx.Signal("played: none");
            void Select(Tx t, string picked)
            {
                for (int i = 0; i < Names.Length; i++)
                    PlaylistTrackKaya.Patch(t, album, $"a{i + 1}").Selected($"a{i + 1}" == picked);
                for (int i = 0; i < Playlist; i++)
                    PlaylistTrackKaya.Patch(t, playlist, $"t{i + 1}").Selected($"t{i + 1}" == picked);
            }
            void Pick(Tx t, string picked)
            {
                t.Write(pickedText, $"picked: {picked}");
                Select(t, picked);
            }
            void Play(Tx t, string picked)
            {
                t.Write(played, $"played: {picked}");
                Select(t, picked);
            }
            tx.Mount(tx.Column(root =>
            {
                tx.SetA11yId(tx.Label(bind: pickedText), "picked");
                tx.SetA11yId(tx.Label(bind: played), "played");
                Table(tx, album, "album", "a", Pick, Play);
                var lng = Table(tx, playlist, "tracks", "t", Pick, Play);
                tx.SetGrow(lng, 1);
                return root;
            }, spacing: 12));
            for (int i = 0; i < Names.Length; i++)
                album.Insert(tx, $"a{i + 1}", Track(i, art));
            for (int i = 0; i < Playlist; i++)
                playlist.Insert(tx, $"t{i + 1}", Track(i, art));
        });
        System.Environment.Exit(app.Run());
    }
}
