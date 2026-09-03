// The window scene, C# port — guests/rust/window.rs,
// tools/scenes/window.steps.

static class WindowScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "window probe", width: 640, height: 400);
            var probe = tx.Signal("window probe");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: probe); // label#0
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
