// The stall scene, C# port — guests/rust/stall.rs, tools/scenes/stall.steps.

using System;
using System.Threading;

static class StallScene
{
    // Past the watchdog's one-second threshold, short enough not to cost.
    const int BlockMs = 2500;

    // A day, never a literal park (docs/traps.md, the stall scene wedges for a DAY).
    const int WedgeMs = 86400 * 1000;

    public static void Run()
    {
        var app = new KayaApp();


        var status = app.Build(tx =>
        {
            tx.Window(title: "stall");
            var status = tx.Signal("ready");

            tx.Mount(tx.Column(root =>
            {
                tx.SetA11yId(tx.Label(bind: status), "status");  // label#0

                // DELIBERATELY WRONG, and the only place in this repo that is.
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
                return root;
            }));
            return status;
        });

        Environment.Exit(app.Run());
    }
}
