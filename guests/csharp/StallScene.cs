// The stall conformance scene, C# port — an app thread that stops
// taking its occurrences is REPORTED (DESIGN.md, Threading model and
// protocol).
//
// THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE, in every
// language. Every other guest keeps blocking work off the app thread —
// each of the eight filedialog guests carries a paragraph explaining
// why its read goes to a worker — and that discipline was entirely
// unenforced. Nothing would have told anyone that a guest ignoring it
// had wedged the app. The class is not hypothetical: a Haskell release
// once used a blocking put, so a second click would have blocked the
// app thread forever, and no gate saw it.
//
// So `block` does exactly the forbidden thing — it sleeps on the app
// thread — and the scene asserts that kaya NOTICES. A scene that merely
// timed out would prove the app was broken; this proves the framework
// reported it, which is the whole feature.
//
// WHY THE SECOND CLICK MATTERS: the consumer cursor advances BEFORE a
// record reaches the guest, so a handler blocking on an empty queue
// looks exactly like an idle app — and nothing is waiting on it, so it
// may as well be. `ping` is what makes work PENDING while the app
// thread is gone. That is what the watchdog can see, and it is what a
// person reports: they click, and click again, and nothing happens.
//
// The recovery is asserted too: the blocked handler returns, the queued
// click is taken, and the label shows it — so the watchdog reported a
// stall rather than a death, and nothing was dropped.
//
// See guests/rust/stall.rs and tools/scenes/stall.steps.

using System;
using System.Threading;

static class StallScene
{
    // Comfortably past the watchdog's one-second threshold, and short
    // enough that the leg is not paying for it: the scene asserts the
    // stall and then the recovery, so this is the whole cost.
    const int BlockMs = 2500;

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

                // DELIBERATELY WRONG, and the only place in this repo
                // that is. Anything real belongs on a thread of its own
                // with the result posted back through app.Post — which
                // is what every other guest does, and what the
                // watchdog's own message tells you to do.
                tx.Button("block", inner =>  // button#0
                {
                    Thread.Sleep(BlockMs);
                });
                tx.Button("ping", inner =>  // button#1
                {
                    inner.Write(status, "pinged");
                });
            }));
        });

        Environment.Exit(app.Run());
    }
}
