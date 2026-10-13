// The network images scene over HTTP, C# port (the file name is check-steps'
// {Scene}Scene.cs pattern) — guests/rust/netimage_http.rs,
// tools/scenes/netimage_http.steps: the row image helper fetching from the
// lane's media server with its default HttpClient fetch.

using System;

static class NetimageHttpScene
{
    static readonly string[] Covers =
        { "covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg" };

    public static void Run()
    {
        var baseUrl = Environment.GetEnvironmentVariable("KAYA_MEDIA_URL")
            ?? throw new InvalidOperationException(
                "kaya: the netimage_http scene reads KAYA_MEDIA_URL, the local server the lane "
                + "starts (tools/lib/media_server.py)");
        var app = new KayaApp();
        int failures = 0;
        var (songs, artNode, errors) = app.Build(tx =>
        {
            tx.Window(title: "netimage_http", width: 640, height: 560);
            var errors = tx.Signal("errors: 0");
            var songs = SongKaya.Collection(tx);
            Node artNode = default;
            tx.Mount(tx.Row(root =>
            {
                tx.SetA11yId(tx.Label(bind: errors), "errors");
                var table = SongKaya.Each(tx, songs, row =>
                {
                    row.Row(() =>
                    {
                        var image = row.Image(row.Art);
                        row.SetFit(image, Fit.Cover);
                        row.SetMaxWidth(image, 20);
                        row.SetMaxHeight(image, 20);
                        row.SetPhase(image, row.Phase);
                        row.SetA11yId(image, "art");
                        artNode = image;
                        row.Label(row.Title);
                    });
                });
                tx.Columns(table, new[] { "Art", "Title" }, Sort.None);
                tx.SetGrow(table, 1);
                return root;
            }));
            foreach (var (key, path) in new[]
            {
                ("missing", "status/404/"),
                ("broken", "status/500/"),
                ("junk", "covers/README.md"),
                ("slow", "trickle/covers/cover-600.jpg"),
            })
                songs.Insert(tx, key,
                    new Song(key, $"{baseUrl}/{path}", Array.Empty<byte>(), ImagePhase.Loading));
            for (int i = 0; i < 12; i++)
                songs.Insert(tx, $"a{i:00}", new Song($"Track {i}", $"{baseUrl}/{Covers[i % 3]}",
                    Array.Empty<byte>(), ImagePhase.Loading));
            return (songs, artNode, errors);
        });

        var images = new RowImages<Song>(app, songs, SongKaya.ArtUrl, SongKaya.Art, SongKaya.Phase);
        images.OnError((tx, _, _) => tx.Write(errors, $"errors: {++failures}"));
        images.Attach(artNode);

        Environment.Exit(app.Run());
    }
}
