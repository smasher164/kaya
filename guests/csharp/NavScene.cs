// The nav conformance scene, C# port — the serial navigation grammar
// via named arguments: PushEntry(title:, interceptBack:) plus MountIn
// presents each screen, OnEntryPopped hears the user's native pop,
// and OnBackRequested answers the intercept_back veto with PopEntry.
// The covered root is RETAINED (status keeps taking writes while
// covered); a programmatic PopEntry does not echo entry_popped, so
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
            tx.WindowTitle("nav");
            status = tx.Signal("at root");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: status); // label#0
                tx.Button("open detail", onClick: inner => // button#0
                {
                    // The popped handler rides the push (per-entry,
                    // the onResult precedent): it can only ever mean
                    // the detail screen popped, and it retires with
                    // the one pop.
                    inner.PushEntry(Detail, title: "detail",
                        onPopped: tx2 => tx2.Write(status, "popped detail"));
                    var pane = inner.Column(() =>
                    {
                        var caption = inner.Signal("detail pane");
                        inner.Label(bind: caption);
                    });
                    inner.MountIn(Detail, pane);
                    // The covered root keeps taking writes —
                    // retention, observable after the pop.
                    inner.Write(status, "pushed detail");
                });
                tx.Button("open settings", onClick: inner => // button#1
                {
                    // The veto class: nothing has popped; agree and
                    // confirm. No entry_popped will fire — the write
                    // is the round's final status.
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
