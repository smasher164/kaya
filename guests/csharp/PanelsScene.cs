// The panels scene, C# port — guests/rust/panels.rs,
// tools/scenes/panels.steps.

static class PanelsScene
{
    public static void Run()
    {
        var app = new KayaApp();

        var status = app.Build(tx =>
        {
            tx.Window(title: "panels");
            var status = tx.Signal("two panels");

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: status); // label#0
                return root;
            }));

            tx.CreateWindow(1, title: "inspector", width: 480, height: 320,
                vetoClose: true,
                onCloseRequested: tx2 =>
                {
                    tx2.Write(status, "close requested");
                    tx2.DestroyWindow(1);
                });
            var aux = tx.Column(aux =>
            {
                var caption = tx.Signal("inspector pane");
                tx.Label(bind: caption); // label#1
                return aux;
            });
            tx.MountIn(1, aux);
            return status;
        });

        System.Environment.Exit(app.Run());
    }
}
