// The network images affordance scene, C# port — guests/rust/netimage.rs,
// tools/scenes/netimage.steps. No HTTP: each "download" is a job a worker
// thread holds until a click releases it.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

[KayaGen]
record Song(string Title, string ArtUrl, byte[] Art, ImagePhase Phase);

static class NetimageScene
{
    const int Rows = 300;

    abstract record Job;

    sealed record LiveJob(byte[]? Bytes) : Job;

    sealed record RowJob(string Key, string Url, byte[] Bytes) : Job;

    public static void Run()
    {
        var app = new KayaApp();
        var jobs = new BlockingCollection<List<Job>>();
        Job? live = null;
        var pending = new List<RowJob>();
        var needed = new HashSet<string>();
        var ever = new HashSet<string>();
        string? twice = null;

        var (art, phase, band, released, again, songs, artNode, covers) = app.Build(tx =>
        {
            var covers = new[] { "covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg" }
                .Select(name =>
                {
                    using var asset = tx.Asset(name);
                    return asset.Bytes();
                })
                .ToArray();
            tx.Window(title: "netimage", width: 820, height: 640);
            var art = tx.Signal(Array.Empty<byte>());
            var phase = tx.Signal(ImagePhase.Loading);
            var band = tx.Signal("band: -");
            var released = tx.Signal("released: none");
            var again = tx.Signal("again: none");
            var songs = SongKaya.Collection(tx);
            Node artNode = default;
            tx.Mount(tx.Row(root =>
            {
                tx.Column(column =>
                {
                    var cover = tx.Image(bind: art, fit: Fit.Cover, maxWidth: 96, maxHeight: 96);
                    tx.SetPhase(cover, phase);
                    tx.SetA11yId(cover, "cover");
                    tx.SetA11yLabel(cover, "Cover");
                    tx.Row(buttons =>
                    {
                        tx.SetA11yId(tx.Button("release", t =>
                        {
                            if (live is { } job)
                            {
                                live = null;
                                jobs.Add(new List<Job> { job });
                            }
                        }), "release");
                        tx.SetA11yId(tx.Button("refresh", t =>
                        {
                            live = new LiveJob(covers[1]);
                            t.Write(phase, ImagePhase.Loading);
                        }), "refresh");
                        tx.SetA11yId(tx.Button("junk", t =>
                        {
                            t.Write(art, "not an image"u8.ToArray());
                            t.Write(phase, ImagePhase.Shown);
                        }), "junk");
                        tx.SetA11yId(tx.Button("fail", t =>
                        {
                            live = new LiveJob(null);
                            t.Write(art, Array.Empty<byte>());
                            t.Write(phase, ImagePhase.Loading);
                        }), "fail");
                    });
                    tx.Row(rowButtons =>
                    {
                        tx.SetA11yId(tx.Button("rows", t =>
                        {
                            needed.Clear();
                            jobs.Add(pending.Cast<Job>().ToList());
                            pending.Clear();
                        }), "rows");
                        tx.SetA11yId(tx.Button("delete", t => t.Remove(songs.Collection, "t299")), "delete");
                        tx.SetA11yId(tx.Button("retarget", t =>
                        {
                            pending.Insert(0, new RowJob("t298", "u/298b", covers[2]));
                            SongKaya.Patch(t, songs, "t298").ArtUrl("u/298b");
                        }), "retarget");
                    });
                    tx.SetA11yId(tx.Label(bind: band), "band");
                    tx.SetA11yId(tx.Label(bind: released), "released");
                    tx.SetA11yId(tx.Label(bind: again), "again");
                });
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
                tx.SetA11yId(table, "tracks");
                tx.SetGrow(table, 1);
                return root;
            }));
            for (int i = 0; i < Rows; i++)
                songs.Insert(tx, $"t{i:000}",
                    new Song($"Track {i}", $"u/{i}", Array.Empty<byte>(), ImagePhase.Loading));
            return (art, phase, band, released, again, songs, artNode, covers);
        });
        live = new LiveJob(covers[0]);

        app.OnNeeded(artNode, (tx, keys) =>
        {
            var key = (string)keys[0];
            if (!needed.Add(key)) twice ??= key;
            ever.Add(key);
            int i = int.Parse(key[1..]);
            pending.Add(new RowJob(key, $"u/{i}", covers[i % 3]));
            tx.Write(band, ever.Count < Rows ? "band: partial" : $"band: {ever.Count}");
            tx.Write(again, $"again: {twice ?? "none"}");
        });
        app.OnReleased(artNode, (tx, keys) =>
        {
            var key = (string)keys[0];
            needed.Remove(key);
            pending.RemoveAll(job => job.Key == key);
            tx.Write(released, "released: some");
        });

        var worker = new Thread(() =>
        {
            foreach (var batch in jobs.GetConsumingEnumerable())
                foreach (var job in batch)
                    switch (job)
                    {
                        case LiveJob { Bytes: { } bytes }:
                            app.Post(t =>
                            {
                                t.Write(art, bytes);
                                t.Write(phase, ImagePhase.Shown);
                            });
                            break;
                        case LiveJob:
                            app.Post(t => t.Write(phase, ImagePhase.Failed));
                            break;
                        case RowJob row:
                            app.Post(t => SongKaya.PatchIf(t, songs, row.Key, SongKaya.ArtUrl, row.Url,
                                p => p.Art(row.Bytes).Phase(ImagePhase.Shown)));
                            break;
                    }
        });
        worker.Name = "netimage-worker";
        worker.IsBackground = true;
        worker.Start();

        Environment.Exit(app.Run());
    }
}
