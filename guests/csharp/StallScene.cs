// The stall conformance scene, C# port — an app thread that stops
// taking its occurrences is REPORTED (DESIGN.md, Threading model and
// protocol).
//
// THIS GUEST MISUSES KAYA ON PURPOSE — the only one that does, in any
// language. Do not "fix" it: `block` sleeps on the app thread, and the
// scene asserts that kaya NOTICES and then that the app recovers.
//
// The second click is load-bearing: the consumer cursor advances BEFORE
// a record reaches the guest, so a handler blocking on an empty queue
// is indistinguishable from an idle app. `ping` is what makes work
// PENDING while the app thread is gone, which is what the watchdog sees.
//
// `wedge` never returns, so the scene ends there; the leg still reports
// its verdict because the harness runs on its own thread and asks the
// MAIN thread to exit.
//
// See guests/rust/stall.rs and tools/scenes/stall.steps.

using System;
using System.Threading;

static class StallScene
{
    // Comfortably past the watchdog's one-second threshold, and short
    // enough that the leg is not paying for it.
    const int BlockMs = 2500;

    // A day, never a literal park (docs/traps.md, "The stall scene
    // wedges for a DAY").
    const int WedgeMs = 86400 * 1000;

    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;

        app.Build(tx =>
        {
            tx.Window(title: "stall");
            status = tx.Signal("ready");

            tx.Mount(tx.Column(() =>
            {
                tx.SetA11yId(tx.Label(bind: status), "status");  // label#0

                // Deliberately wrong. Real work belongs on a thread of
                // its own with the result posted back through app.Post.
                tx.Button("block", inner =>  // button#0
                {
                    Thread.Sleep(BlockMs);
                });
                tx.Button("ping", inner =>  // button#1
                {
                    inner.Write(status, "pinged");
                });
                tx.Button("wedge", inner =>  // button#2
                {
                    Thread.Sleep(WedgeMs);
                });
            }));
        });

        Environment.Exit(app.Run());
    }
}
