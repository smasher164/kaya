// The nav scene, C# port — guests/rust/nav.rs, tools/scenes/nav.steps.

static class NavScene
{
    const ulong Detail = 7;
    const ulong Settings = 8;

    public static void Run()
    {
        var app = new KayaApp();

        var status = app.Build(tx =>
        {
            tx.Window(title: "nav");
            var status = tx.Signal("at root");

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: status); // label#0
                tx.Button("open detail", onClick: inner => // button#0
                {
                    inner.PushEntry(Detail, title: "detail",
                        onPopped: tx2 => tx2.Write(status, "popped detail"));
                    var pane = inner.Column(pane =>
                    {
                        var caption = inner.Signal("detail pane");
                        inner.Label(bind: caption);
                        return pane;
                    });
                    inner.MountIn(Detail, pane);
                    inner.Write(status, "pushed detail");
                });
                tx.Button("open settings", onClick: inner => // button#1
                {
                    // Nothing has popped yet, so no entry_popped follows this pop.
                    inner.PushEntry(Settings, title: "settings", interceptBack: true,
                        onBackRequested: tx2 =>
                        {
                            tx2.Write(status, "back requested");
                            tx2.PopEntry();
                        });
                    var pane = inner.Column(pane =>
                    {
                        var caption = inner.Signal("settings pane");
                        inner.Label(bind: caption);
                        return pane;
                    });
                    inner.MountIn(Settings, pane);
                    inner.Write(status, "pushed settings");
                });
                return root;
            }));
            return status;
        });

        System.Environment.Exit(app.Run());
    }
}
