// The nav conformance scene, C# port — the serial navigation grammar.
// The covered root is RETAINED (status keeps taking writes while
// covered), and a programmatic PopEntry does not echo entry_popped, so
// the settings round's final status stays "back requested". See
// guests/rust/nav.rs and tools/scenes/nav.steps.

static class NavScene
{
    const ulong Detail = 7;
    const ulong Settings = 8;

    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        app.Build(tx =>
        {
            tx.Window(title: "nav");
            status = tx.Signal("at root");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: status); // label#0
                tx.Button("open detail", onClick: inner => // button#0
                {
                    inner.PushEntry(Detail, title: "detail",
                        onPopped: tx2 => tx2.Write(status, "popped detail"));
                    var pane = inner.Column(() =>
                    {
                        var caption = inner.Signal("detail pane");
                        inner.Label(bind: caption);
                    });
                    inner.MountIn(Detail, pane);
                    inner.Write(status, "pushed detail");
                });
                tx.Button("open settings", onClick: inner => // button#1
                {
                    // The veto class: nothing has popped yet. No
                    // entry_popped will follow the PopEntry below.
                    inner.PushEntry(Settings, title: "settings", interceptBack: true,
                        onBackRequested: tx2 =>
                        {
                            tx2.Write(status, "back requested");
                            tx2.PopEntry();
                        });
                    var pane = inner.Column(() =>
                    {
                        var caption = inner.Signal("settings pane");
                        inner.Label(bind: caption);
                    });
                    inner.MountIn(Settings, pane);
                    inner.Write(status, "pushed settings");
                });
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
