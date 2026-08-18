// The background conformance scene, C# port — work off the app thread,
// posted back (docs/background-work-plan.md).
//
// The odd shape is the point: a wrong implementation must DEADLOCK
// rather than disagree. The worker parks until a CLICK releases it, and
// only a live app thread can process a click.
//
// The accumulators are the guest's own state — signals are write-only —
// and need no lock: everything that touches them runs on the app thread
// inside a posted transaction.

using System;
using System.Threading;

static class BackgroundScene
{
    public static void Run()
    {
        var app = new KayaApp();

        var released = new ManualResetEventSlim(false);
        string posted = "";
        string nested = "";

        Signal status = default;
        Signal alive = default;
        Signal detail = default;

        app.Build(tx =>
        {
            tx.Window(title: "background");
            status = tx.Signal("idle");
            alive = tx.Signal("-");
            detail = tx.Signal("-");

            tx.Mount(tx.Column(() =>
            {
                tx.SetA11yId(tx.Label(bind: status), "status");  // label#0
                tx.SetA11yId(tx.Label(bind: alive), "alive");    // label#1
                // Authored because the AX read needs an identifier; an
                // index read passes for an arm that drew nothing.
                tx.SetA11yId(tx.Label(bind: detail), "nested");  // label#2

                tx.Button("start", inner =>  // button#0
                {
                    var worker = new Thread(() =>
                    {
                        // Parks until the scene clicks release.
                        released.Wait();
                        // Three posts: the accumulator makes this a test
                        // of ORDER, not of which one ran last.
                        foreach (var step in new[] { "1", "2", "3" })
                        {
                            var s = step;
                            app.Post(t =>
                            {
                                posted += s;
                                t.Write(status, posted);
                            });
                        }
                    });
                    worker.Name = "background-worker";
                    worker.IsBackground = true;
                    worker.Start();
                    inner.Write(status, "working");
                });
                // Proof the app thread still serves input while the
                // worker is parked.
                tx.Button("ping", inner => inner.Write(alive, "alive"));  // button#1
                tx.Button("release", _ => released.Set());                // button#2
                // A post from inside a handler QUEUES for after; it never
                // nests. So this commits "ac" and the posted closure then
                // commits "acb" — nesting could only produce "abc".
                tx.Button("nest", inner =>  // button#3
                {
                    nested += "a";
                    app.Post(t =>
                    {
                        nested += "b";
                        t.Write(detail, nested);
                    });
                    nested += "c";
                    inner.Write(detail, nested);
                });
            }));
        });

        Environment.Exit(app.Run());
    }
}
