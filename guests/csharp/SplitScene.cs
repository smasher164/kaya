// The split scene, C# port — guests/rust/split.rs, tools/scenes/split.steps.

static class SplitScene
{
    const ulong Detail = 7;

    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        app.Build(tx =>
        {
            tx.Window(title: "split", panes: 2);
            status = tx.Signal("list pane");

            tx.Mount(tx.Column(() =>
            {
                // Authored ids: an index read passes whether or not anything
                // reached the screen.
                tx.SetA11yId(tx.Label(bind: status), "list"); // label#0
                tx.Button("open detail", onClick: inner => // button#0
                {
                    inner.PushEntry(Detail, title: "detail",
                        onPopped: tx2 => tx2.Write(status, "popped detail"));
                    var pane = inner.Column(() =>
                    {
                        var caption = inner.Signal("detail pane");
                        inner.SetA11yId(inner.Label(bind: caption), "detail");
                    });
                    inner.MountIn(Detail, pane);
                });
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
