// The network images surface (docs/network-images-plan.md N7, N8, N12), run
// rather than read. Headless, driven by tools/check-abort.py with
// KAYA_CHECK=netimage: the conditional write's two drops through the mirror,
// the wrong-thread write refused, and the row helper's coalescing, cap and
// release.

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

static class NetimageCheck
{
    static void Check(bool ok, string what)
    {
        if (!ok)
        {
            Console.WriteLine("netimage-check: FAIL — " + what);
            Environment.Exit(1);
        }
    }

    public static void Run()
    {
        var app = new KayaApp();
        KayaApp.ClaimAppThread();
        var previous = SynchronizationContext.Current;
        app.InstallAsyncContext();
        try
        {
            Guard(app);
            Helper(app);
        }
        finally { SynchronizationContext.SetSynchronizationContext(previous); }
        Console.WriteLine("netimage-check: OK");
    }

    static void Guard(KayaApp app)
    {
        var songs = app.Build(tx =>
        {
            var songs = SongKaya.Collection(tx);
            songs.Insert(tx, "a", new Song("A", "u/1", Array.Empty<byte>(), ImagePhase.Loading));
            return songs;
        });
        app.Build(tx =>
        {
            int before = tx.Records.Count;
            bool held = SongKaya.PatchIf(tx, songs, "a", SongKaya.ArtUrl, "u/1",
                p => p.Art(new byte[] { 1, 2 }).Phase(ImagePhase.Shown));
            bool moved = SongKaya.PatchIf(tx, songs, "a", SongKaya.ArtUrl, "u/0",
                p => p.Phase(ImagePhase.Failed));
            bool gone = SongKaya.PatchIf(tx, songs, "zz", SongKaya.ArtUrl, "u/1",
                p => p.Phase(ImagePhase.Failed));
            Check(held && !moved && !gone, $"guard answers held={held} moved={moved} gone={gone}");
            int records = tx.Records.Count - before;
            Check(records == 3,
                $"each conditional write is ONE record whether or not it held, saw {records}");
        });
        var row = app.Build(tx => songs[tx, "a"]);
        Check(row.Phase == ImagePhase.Shown && row.Art.Length == 2,
            $"the mirror took the writes its guard held for and only those, holds {row.Phase} "
            + $"with {row.Art.Length} bytes");
        Check(!app.Build(tx => songs.TryGet(tx, "zz", out _)),
            "a write whose row was gone created it in the mirror");
        Console.WriteLine("netimage-check: patch_if held once, dropped for a moved guard and a gone "
            + "row, one record each");

        bool refused = false;
        var worker = new Thread(() =>
        {
            try
            {
                app.Build(tx => SongKaya.PatchIf(tx, songs, "a", SongKaya.ArtUrl, "u/1",
                    p => p.Phase(ImagePhase.Failed)));
            }
            catch (InvalidOperationException e) { refused = e.Message.Contains("app thread"); }
        });
        worker.Start();
        Check(worker.Join(5000) && refused, "a conditional write from a foreign thread was not refused");
        Console.WriteLine("netimage-check: a foreign thread's conditional write refused");
    }

    static void Helper(KayaApp app)
    {
        var fetched = new List<string>();
        var answers = new Dictionary<string, TaskCompletionSource<byte[]>>();
        var cancelled = new List<string>();
        var (songs, node) = app.Build(tx =>
        {
            var songs = SongKaya.Collection(tx);
            Node node = default;
            SongKaya.Each(tx, songs, row => node = row.Image(row.Art));
            for (int i = 0; i < 12; i++)
                songs.Insert(tx, $"r{i:00}", new Song("", i < 3 ? "u/shared" : $"u/{i}",
                    Array.Empty<byte>(), ImagePhase.Loading));
            return (songs, node);
        });
        var images = new RowImages<Song>(app, songs, SongKaya.ArtUrl, SongKaya.Art, SongKaya.Phase,
            (url, token) =>
            {
                fetched.Add(url);
                var answer = new TaskCompletionSource<byte[]>();
                answers[url] = answer;
                token.Register(() =>
                {
                    cancelled.Add(url);
                    answer.TrySetCanceled(token);
                });
                return answer.Task;
            });
        int errors = 0;
        images.OnError((_, _, _) => errors++);
        images.Attach(node);
        for (int i = 0; i < 12; i++)
            app.DispatchImage(new ImageNeeded(node.Id, new List<object> { $"r{i:00}" }));
        app.DrainAsync();
        Check(fetched.Count == 6 && fetched.FindAll(u => u == "u/shared").Count == 1,
            $"three rows sharing a URL make one fetch and at most six run, fetched {string.Join(",", fetched)}");
        Check(images.Queued == 4, $"the four past the cap wait, {images.Queued} queued");

        app.DispatchImage(new ImageReleased(node.Id, new List<object> { "r11" }));
        Check(images.Queued == 3, $"a released row's URL leaves the queue, {images.Queued} queued");
        app.DispatchImage(new ImageReleased(node.Id, new List<object> { "r03" }));
        app.DrainAsync();
        Check(cancelled.Contains("u/3") && images.Queued == 2 && fetched.Contains("u/8"),
            $"a released row's running fetch is cancelled and the queue moves up, cancelled "
            + $"{string.Join(",", cancelled)}, {images.Queued} queued");

        answers["u/shared"].SetResult(new byte[] { 7, 7, 7 });
        answers["u/4"].SetException(new Exception("404"));
        app.DrainAsync();
        app.DrainAsync();
        app.Build(tx =>
        {
            for (int i = 0; i < 3; i++)
            {
                var row = songs[tx, $"r{i:00}"];
                Check(row.Phase == ImagePhase.Shown && row.Art.Length == 3,
                    $"r{i:00} reads {row.Phase} with {row.Art.Length} bytes after its shared fetch");
            }
            Check(songs[tx, "r04"].Phase == ImagePhase.Failed && errors == 1,
                $"a failed fetch writes failed and tells the app once, r04 {songs[tx, "r04"].Phase}, "
                + $"{errors} errors");
            Check(songs[tx, "r03"].Phase == ImagePhase.Loading, "a cancelled fetch wrote its row");
        });
        Check(fetched.Contains("u/6") && fetched.Contains("u/7") && fetched.Contains("u/8")
                && !fetched.Contains("u/11"),
            $"the queue moved up as fetches ended and skipped the released URL, fetched "
            + string.Join(",", fetched));
        Console.WriteLine("netimage-check: the helper coalesced a shared URL, held six, released a "
            + "queued URL, cancelled a running one, wrote shown and failed");
    }
}
