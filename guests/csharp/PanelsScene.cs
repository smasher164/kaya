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
            tx.Window(title: "panels");
            status = tx.Signal("two panels");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: status); // label#0
            }));

            // The veto handler binds to the inspector at its
            // declaration (handlers scope to the thing that creates
            // them): it can only ever mean this window's close.
            tx.CreateWindow(1, title: "inspector", width: 480, height: 320,
                vetoClose: true,
                onCloseRequested: tx2 =>
                {
                    tx2.Write(status, "close requested");
                    tx2.DestroyWindow(1);
                });
            var aux = tx.Column(() =>
            {
                var caption = tx.Signal("inspector pane");
                tx.Label(bind: caption); // label#1
            });
            tx.MountIn(1, aux);
        });

        System.Environment.Exit(app.Run());
    }
}
