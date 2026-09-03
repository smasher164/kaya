// The background scene, C# port — guests/rust/background.rs,
// tools/scenes/background.steps.

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
                tx.SetA11yId(tx.Label(bind: detail), "nested");  // label#2

                tx.Button("start", inner =>  // button#0
                {
                    var worker = new Thread(() =>
                    {
                        released.Wait();
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
                tx.Button("ping", inner => inner.Write(alive, "alive"));  // button#1
                tx.Button("release", _ => released.Set());                // button#2
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
