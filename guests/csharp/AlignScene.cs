// The align scene, C# port — guests/rust/align.rs, tools/scenes/align.steps.

static class AlignScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var probe = tx.Signal("align probe");
            var @base = tx.Signal("base");
            var anchor = tx.Signal("anchor");
            var fit = tx.Signal("fit");
            var plain = tx.Signal("plain probe");

            var root = tx.Column(() =>
            {
                var centered = tx.Column(() =>
                {
                    tx.Label(bind: probe); // label#0
                    tx.Button("mid");
                    var baseline = tx.Row(() =>
                    {
                        tx.Label(bind: @base); // label#1
                        tx.Button("tick");
                        tx.Image(TallPng);
                    }, align: Align.Baseline); // the baseline trio
                    tx.SetA11yId(baseline, "baseline");
                }, align: Align.Center); // the center trio
                tx.SetA11yId(centered, "centered");
                tx.Row(() => // row#1: the stretch pair's host
                {
                    tx.Label(bind: anchor); // label#2
                    var fitcol = tx.Column(() =>
                    {
                        tx.Label(bind: fit); // label#3
                        tx.Button("wide");
                    }, grow: 1, align: Align.Stretch);
                    tx.SetA11yId(fitcol, "fitcol");
                });
                // row@plain: NO align, so the core's centre default is what
                // the scene reads
                var plainRow = tx.Row(() =>
                {
                    tx.SetA11yId(tx.Label(bind: plain), "plainlabel"); // label#4
                    tx.Image(TallPng);
                });
                tx.SetA11yId(plainRow, "plain");
            }, align: Align.Stretch);
            tx.SetA11yId(root, "root");
            tx.Mount(root);
        });

        System.Environment.Exit(app.Run());
    }

    // A 2x64 PNG: the tall no-baseline child.
    static readonly byte[] TallPng =
    {
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72,
        68, 82, 0, 0, 0, 2, 0, 0, 0, 64, 8, 2, 0, 0,
        0, 191, 68, 49, 20, 0, 0, 0, 18, 73, 68, 65, 84, 120,
        156, 99, 8, 8, 138, 2, 34, 134, 81, 106, 104, 82, 0, 67,
        50, 126, 1, 49, 1, 65, 124, 0, 0, 0, 0, 73, 69, 78,
        68, 174, 66, 96, 130,
    };
}
