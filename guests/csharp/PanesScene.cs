// The panes conformance scene, C# port — a THREE-pane ceiling as
// assertions (docs/multicolumn-plan.md D1/D5). Nothing here is
// panes-specific except panes: 3, asked for ONCE — the stack is the
// ordinary navigation stack, and how many of the three fit is the
// platform's re-decision at every width. See guests/rust/panes.rs and
// tools/scenes/panes.steps.

static class PanesScene
{
    const ulong Content = 7;
    const ulong Detail = 8;

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "panes", panes: 3);
            var caption = tx.Signal("root pane");

            tx.Mount(tx.Column(() =>
            {
                // Authored ids so the REAL-TREE read can address these: an
                // index read passes whether or not anything reached the
                // screen.
                tx.SetA11yId(tx.Label(bind: caption), "root"); // label#0
                tx.Button("open content", onClick: OpenContent); // button#0
            }));
        });

        System.Environment.Exit(app.Run());
    }

    static void OpenContent(Tx tx)
    {
        tx.PushEntry(Content, title: "content");
        var pane = tx.Column(() =>
        {
            var caption = tx.Signal("content pane");
            tx.SetA11yId(tx.Label(bind: caption), "content"); // label#1
            tx.Button("open detail", onClick: OpenDetail); // button#1
        });
        tx.MountIn(Content, pane);
    }

    static void OpenDetail(Tx tx)
    {
        tx.PushEntry(Detail, title: "detail");
        var pane = tx.Column(() =>
        {
            var caption = tx.Signal("detail pane");
            tx.SetA11yId(tx.Label(bind: caption), "detail"); // label#last
        });
        tx.MountIn(Detail, pane);
    }
}
