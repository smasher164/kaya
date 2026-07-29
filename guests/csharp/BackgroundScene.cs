// The background conformance scene, C# port — work off the app thread,
// posted back (docs/background-work-plan.md).
//
// WHAT IT PROVES, and the reason for its odd shape: a wrong
// implementation must DEADLOCK rather than disagree. The worker parks
// until a CLICK releases it, and only a live app thread can process a
// click — so a binding that let background work occupy the app thread
// cannot reach the end of the script at all. It could not even deliver
// its own release.
//
// The parking is a plain ManualResetEventSlim and the worker a plain
// background thread. kaya supplies no waiting primitive and should not:
// the point is that a guest uses its own language's concurrency and
// hands back only the result.
//
// The accumulators are the guest's own state rather than signal
// read-backs — signals are write-only by doctrine. They need no lock:
// everything that touches them runs on the app thread, inside a posted
// transaction.

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
                // Authored so the CLOSING read can address it: the AX
                // read needs an identifier, and an index read passes for
                // an arm that ran and drew nothing.
                tx.SetA11yId(tx.Label(bind: detail), "nested");  // label#2

                tx.Button("start", inner =>  // button#0
                {
                    var worker = new Thread(() =>
                    {
                        // Parks here until the scene clicks release. Were
                        // the binding running this on the app thread,
                        // that click could never be processed and the
                        // whole scene would deadlock — the point.
                        released.Wait();
                        // Three posts, in order. The accumulator makes
                        // this a test of ORDER and not merely of which
                        // one ran last.
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
                // Proof the app thread is still serving input while the
                // worker is parked and has posted nothing.
                tx.Button("ping", inner => inner.Write(alive, "alive"));  // button#1
                tx.Button("release", _ => released.Set());                // button#2
                // A post from INSIDE a handler QUEUES for after; it never
                // nests. The handler appends a, posts a closure appending
                // b, appends c — so it commits "ac" and the posted
                // closure then commits "acb". Nesting can only ever
                // produce "abc".
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
