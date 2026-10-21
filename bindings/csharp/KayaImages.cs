// N12's helper (docs/network-images-plan.md): a row's image fetched when the
// core says the row needs it, and written back with N7's conditional write.
// crates/kaya/src/app/images.rs is the reference; this one awaits on the app
// thread (AppThreadContext) instead of running workers.

using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

/// Rows whose image loads on demand. Each row holds the URL it wants, its
/// bytes and its phase; a row realized Loading with no bytes is fetched, at
/// most DefaultLimit at a time, rows sharing a URL share one fetch, and a
/// URL no realized row waits on any longer is not fetched, or is cancelled.
sealed class RowImages<T>
{
    public const int DefaultLimit = 6;

    /// The encoded bytes kept by URL, least recently used out past this.
    public const long CacheBudget = 32L << 20;

    static readonly HttpClient Client = new();

    /// The default fetch: HttpClient, the status checked, cancelled through
    /// the token when no row waits.
    public static async Task<byte[]> HttpFetch(string url, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd("kaya/" + KayaWire.Version);
        using var response = await Client.SendAsync(request, token).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false);
    }

    readonly KayaApp app;
    readonly RecordCollection<T> rows;
    readonly Field<string> url;
    readonly Field<byte[]> art;
    readonly Field<ImagePhase> phase;
    readonly Func<string, CancellationToken, Task<byte[]>> fetch;
    Action<Tx, List<object>, string>? onError;

    readonly LinkedList<string> queue = new();
    readonly Dictionary<string, List<List<object>>> waiting = new();
    readonly Dictionary<string, CancellationTokenSource> inFlight = new();
    readonly Dictionary<string, LinkedListNode<(string Url, byte[] Bytes)>> cached = new();
    readonly LinkedList<(string Url, byte[] Bytes)> recency = new();
    long cachedBytes;
    int running;

    /// `url`, `art` and `phase` are the row's fields; `rows` is the root
    /// handle of the collection the template image's For stamps. Without a
    /// `fetch`, HttpFetch.
    public RowImages(KayaApp app, RecordCollection<T> rows, Field<string> url,
        Field<byte[]> art, Field<ImagePhase> phase,
        Func<string, CancellationToken, Task<byte[]>>? fetch = null)
    {
        this.app = app;
        this.rows = rows;
        this.url = url;
        this.art = art;
        this.phase = phase;
        this.fetch = fetch ?? HttpFetch;
    }

    /// Run inside the transaction that writes Failed, with the copy's keys
    /// and why.
    public void OnError(Action<Tx, List<object>, string> handler) => onError = handler;

    /// Fetch for the stamped copies of template image `image`.
    public void Attach(Node image)
    {
        if (!app.ImageFeeds.TryGetValue(image.Id, out var feeds))
            app.ImageFeeds[image.Id] = feeds = new();
        feeds.Add((Needed, Released));
    }

    internal int Running => running;

    internal int Queued => queue.Count;

    (RecordCollection<T>, object) Instance(List<object> keys)
    {
        var instance = rows;
        for (int i = 0; i < keys.Count - 1; i++)
            instance = instance.At(keys[i]);
        return (instance, keys[^1]);
    }

    void Needed(Tx tx, List<object> keys)
    {
        if (keys.Count == 0) return;
        var (instance, key) = Instance(keys);
        if (!instance.TryGet(tx, key, out var row)
            || instance.Info.FieldOfWire(row!, url.Index) is not string wanted
            || wanted.Length == 0)
            return;
        if (cached.TryGetValue(wanted, out var hit))
        {
            recency.Remove(hit);
            recency.AddFirst(hit);
            Write(tx, new() { keys }, wanted, hit.Value.Bytes, null);
            return;
        }
        if (!waiting.TryGetValue(wanted, out var rowsWaiting))
            waiting[wanted] = rowsWaiting = new();
        rowsWaiting.Add(keys);
        if (rowsWaiting.Count > 1) return;
        queue.AddLast(wanted);
        Pump();
    }

    /// A released row stops waiting; a URL nobody waits on leaves the queue,
    /// and a running fetch for it is cancelled.
    void Released(Tx tx, List<object> keys)
    {
        var emptied = new List<string>();
        foreach (var (u, list) in waiting)
        {
            list.RemoveAll(k => SameKeys(k, keys));
            if (list.Count == 0) emptied.Add(u);
        }
        foreach (var u in emptied)
        {
            waiting.Remove(u);
            queue.Remove(u);
            if (inFlight.Remove(u, out var cts)) cts.Cancel();
        }
    }

    static bool SameKeys(List<object> a, List<object> b)
    {
        if (a.Count != b.Count) return false;
        for (int i = 0; i < a.Count; i++)
            if (!Equals(a[i], b[i])) return false;
        return true;
    }

    // Starts run outside any transaction, as async work queued on the app
    // thread: a fetch that answers synchronously then writes through its
    // own Build rather than inside the occurrence's.
    void Pump()
    {
        while (running < DefaultLimit && queue.First is { } next)
        {
            queue.RemoveFirst();
            running++;
            var u = next.Value;
            var cts = new CancellationTokenSource();
            inFlight[u] = cts;
            app.QueueAsync(() => Run(u, cts));
        }
    }

    async void Run(string u, CancellationTokenSource cts)
    {
        byte[]? bytes = null;
        string? error = null;
        try
        {
            bytes = await fetch(u, cts.Token);
        }
        catch (OperationCanceledException) when (cts.IsCancellationRequested)
        {
        }
        catch (Exception e)
        {
            error = e.Message;
            if (!cts.IsCancellationRequested) FetchFailed(u, error);
        }
        finally
        {
            running--;
            if (inFlight.TryGetValue(u, out var current) && current == cts)
                inFlight.Remove(u);
            cts.Dispose();
        }
        if (!cts.IsCancellationRequested && waiting.Remove(u, out var rowsWaiting))
        {
            if (bytes != null) Keep(u, bytes);
            // A fetch that completes inside a transaction on this thread
            // resumes inline; its write waits for that one to end.
            void Land() => app.Build(tx => Write(tx, rowsWaiting, u, bytes, error ?? ""));
            if (app.CurrentTx == null) Land();
            else app.QueueAsync(Land);
        }
        Pump();
    }

    // docs/traps.md, "The sockets a stale freeze destroyed": one write, the
    // same line in all nine bindings.
    static void FetchFailed(string u, string why)
    {
        Console.Error.Write($"kaya: row image fetch failed: {u}: {why.Replace('\n', ' ').Replace('\r', ' ')}\n");
        Console.Error.Flush();
    }

    void Write(Tx tx, List<List<object>> keysList, string u, byte[]? bytes, string? error)
    {
        foreach (var keys in keysList)
        {
            var (instance, key) = Instance(keys);
            if (bytes != null)
                instance.PatchIf(tx, key, url, u, p => p.Set(art, bytes).Set(phase, ImagePhase.Shown));
            else
            {
                instance.PatchIf(tx, key, url, u, p => p.Set(phase, ImagePhase.Failed));
                onError?.Invoke(tx, keys, error ?? "");
            }
        }
    }

    void Keep(string u, byte[] bytes)
    {
        if (cached.Remove(u, out var old))
        {
            recency.Remove(old);
            cachedBytes -= old.Value.Bytes.Length;
        }
        cached[u] = recency.AddFirst((u, bytes));
        cachedBytes += bytes.Length;
        while (cachedBytes > CacheBudget && recency.Count > 1 && recency.Last is { } oldest)
        {
            recency.RemoveLast();
            cached.Remove(oldest.Value.Url);
            cachedBytes -= oldest.Value.Bytes.Length;
        }
    }
}
