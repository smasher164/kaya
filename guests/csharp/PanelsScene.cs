// The panels conformance scene, C# port — the auxiliary-window
// grammar via named arguments. See guests/rust/panels.rs and
// tools/scenes/panels.steps.

static class PanelsScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        app.Build(tx =>
        {
            tx.WindowTitle("panels");
            status = tx.Signal("two panels");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: status); // label#0
            }));

            tx.CreateWindow(1, title: "inspector", width: 480, height: 320,
                vetoClose: true);
            var aux = tx.Column(() =>
            {
                var caption = tx.Signal("inspector pane");
                tx.Label(bind: caption); // label#1
            });
            tx.MountIn(1, aux);
        });

        app.OnCloseRequested((tx, window) =>
        {
            tx.Write(status, "close requested");
            tx.DestroyWindow(window);
        });

        System.Environment.Exit(app.Run());
    }
}
