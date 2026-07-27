// The split conformance scene, C# port — adaptive list-detail via
// named arguments: listDetail rides the window, PushEntry(title:,
// onPopped:) plus MountIn presents the detail.
//
// The guest asks for the presentation ONCE and then does nothing
// adaptive ever again. Everything after that is the platform
// re-deciding as the size class changes: an app does not write two
// layouts and pick one, and there is no prop for WHICH way it
// presents. Nothing here is split-specific except that one prop.
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
            // The one adaptive declaration in the whole guest.
            tx.Window(title: "split", listDetail: true);
            status = tx.Signal("list pane");

            tx.Mount(tx.Column(() =>
            {
                // Authored ids so the REAL-TREE read can address
                // these: an index read passes whether or not anything
                // reached the screen, which is the gap that let a
                // non-rendering split arm look green.
                tx.SetA11yId(tx.Label(bind: status), "list"); // label#0
                tx.Button("open detail", onClick: inner => // button#0
                {
                    // The popped handler rides the push, per-entry —
                    // the onResult precedent, unchanged by the split.
                    inner.PushEntry(Detail, title: "detail",
                        // Retention: the base root took this write
                        // while the detail was up, on a regular window
                        // where it was VISIBLE the whole time.
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
