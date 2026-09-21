using System.Collections.Concurrent;

sealed class ProbeContext(KayaApp app, bool transactional) : SynchronizationContext
{
    readonly ConcurrentQueue<(SendOrPostCallback, object?)> queue = new();
    public int Posts;
    public override void Post(SendOrPostCallback callback, object? state)
    {
        Interlocked.Increment(ref Posts);
        if (transactional) app.Post(_ => callback(state));
        else queue.Enqueue((callback, state));
    }
    public void Drain()
    {
        if (transactional) app.DrainPosted();
        else
        {
            int count = queue.Count;
            for (int i = 0; i < count; i++)
            {
                if (!queue.TryDequeue(out var item)) throw new Exception("missing work");
                try { item.Item1(item.Item2); }
                catch (Exception e) { Console.Error.WriteLine($"probe: async handler threw: {e.Message}"); }
            }
        }
    }
}

static class Probe
{
    static int Main(string[] args)
    {
        string mode = args.Single();
        var app = new KayaApp();
        KayaApp.ClaimAppThread();
        var signal = app.Build(tx => tx.Signal("initial"));
        var context = new ProbeContext(app, mode != "raw");
        SynchronizationContext.SetSynchronizationContext(context);
        var answer = new TaskCompletionSource<int>();
        int owner = Environment.CurrentManagedThreadId;
        bool resumed = false, staleRefused = false;
        Tx? retained = null;
        var error = new StringWriter();
        Console.SetError(error);
        app.Post(async tx =>
        {
            retained = tx;
            tx.Write(signal, "before");
            await answer.Task;
            resumed = Environment.CurrentManagedThreadId == owner;
            Console.WriteLine($"resumed-owner={resumed} ambient={app.CurrentTx != null}");
            try { retained.Write(signal, "stale"); }
            catch (ObjectDisposedException) { staleRefused = true; }
            Console.WriteLine($"stale-tx-refused={staleRefused}");
            if (mode == "ambient") app.CurrentTx!.Write(signal, "after");
            else app.Build(next =>
            {
                next.Write(signal, "after");
                if (mode == "inside") throw new InvalidOperationException("inside-build");
            });
            throw new InvalidOperationException("outside-build");
        });
        app.DrainPosted();
        bool beforeCommitted = Equals(app.SignalMirrors[signal.Id], "before");
        Console.WriteLine($"before-answer={app.SignalMirrors[signal.Id]}");
        var worker = new Thread(() => answer.SetResult(1));
        worker.Start();
        worker.Join();
        context.Drain();
        bool errorDelayed = error.ToString().Length == 0;
        Console.WriteLine($"after-continuation={app.SignalMirrors[signal.Id]} error-reported={!errorDelayed}");
        context.Drain();
        Console.WriteLine($"after-error={app.SignalMirrors[signal.Id]} posts={context.Posts}");
        Console.Write(error.ToString());
        string expected = mode == "inside" ? "before" : "after";
        if (!beforeCommitted || !resumed || !staleRefused || !errorDelayed
            || !Equals(app.SignalMirrors[signal.Id], expected) || context.Posts != 2
            || !error.ToString().Contains(mode == "inside" ? "inside-build" : "outside-build"))
        {
            Console.WriteLine($"probe: observation mismatch, want final={expected}");
            return 1;
        }
        Console.WriteLine("probe: measured");
        return 0;
    }
}
