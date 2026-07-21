// The window conformance scene, C# port — see guests/rust/window.rs
// and tools/scenes/window.steps. The primary surface's props as
// assertions: the title must materialize in the real title bar, the
// advisory 640x400 request must be honored on a desktop.

static class WindowScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.WindowTitle("window probe");
            tx.WindowSize(640, 400);
            var probe = tx.Signal("window probe");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: probe); // label#0
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
