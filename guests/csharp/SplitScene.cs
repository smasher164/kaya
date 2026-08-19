// The split conformance scene, C# port — adaptive list-detail via named
// arguments. The guest asks for the presentation ONCE and does nothing
// adaptive after that; there is no prop for WHICH way it presents.
//
// TWO scripts drive this ONE app: split resizes and names the
// presentation on each side, listdetail asserts the bare invariant at
// whatever width its host gives. See guests/rust/split.rs,
// tools/scenes/split.steps and tools/scenes/listdetail.steps.

static class SplitScene
{
    const ulong Detail = 7;

    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        app.Build(tx =>
        {
            tx.Window(title: "split", listDetail: true);
            status = tx.Signal("list pane");

            tx.Mount(tx.Column(() =>
            {
                // Authored ids so the REAL-TREE read can address these: an
                // index read passes whether or not anything reached the
                // screen, which once let a non-rendering split arm look
                // green.
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
