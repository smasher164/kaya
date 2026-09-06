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
                // column@knobs: NO align; fill opts one child out of its
                // default and one in
                var knobs = tx.Column(() =>
                {
                    var optout = tx.Textarea();
                    tx.SetFill(optout, false);
                    tx.SetA11yId(optout, "optout");
                    var fills = tx.Button("fills");
                    tx.SetFill(fills, true);
                    tx.SetA11yId(fills, "fills");
                    // row@wrapped: six exact-width images flow onto two lines
                    var wrapped = tx.Row(() =>
                    {
                        for (var i = 0; i < 6; i++)
                        {
                            tx.Image(WidePng);
                        }
                    });
                    tx.SetWrap(wrapped, true);
                    tx.SetA11yId(wrapped, "wrapped");
                });
                tx.SetA11yId(knobs, "knobs");
            }, align: Align.Stretch);
            tx.SetA11yId(root, "root");
            tx.Mount(root);
        });

        System.Environment.Exit(app.Run());
    }

    // A 100x20 PNG: exact pixel widths, so row@wrapped breaks onto two
    // lines in every lane's window (docs/layout-knobs-plan.md §2).
    static readonly byte[] WidePng =
    {
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72,
        68, 82, 0, 0, 0, 100, 0, 0, 0, 20, 8, 2, 0, 0,
        0, 244, 162, 15, 194, 0, 0, 0, 56, 73, 68, 65, 84, 120,
        218, 237, 208, 1, 13, 0, 0, 8, 3, 160, 7, 177, 164, 109,
        141, 99, 133, 7, 96, 35, 1, 153, 61, 74, 81, 32, 75, 150,
        44, 89, 178, 100, 41, 144, 37, 75, 150, 44, 89, 178, 20, 200,
        146, 37, 75, 150, 44, 89, 10, 122, 15, 34, 121, 229, 167, 65,
        55, 75, 87, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96,
        130,
    };

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
