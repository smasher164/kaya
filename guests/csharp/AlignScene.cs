// The align conformance scene, C# port — see guests/rust/align.rs and
// tools/scenes/align.steps for the full rationale. The root column
// centers children of three different natural widths; the row aligns
// baselines across a label, a checkbox, and a tall no-baseline image
// whose bottom sits ON the baseline (the CSS replaced-element rule) —
// the construction that separates the modes on every platform's
// control metrics.

static class AlignScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var probe = tx.Signal("align probe");
            var @base = tx.Signal("base");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: probe); // label#0
                tx.Button("mid");
                tx.Row(() =>
                {
                    tx.Label(bind: @base); // label#1
                    tx.Button("tick");
                    tx.Image(TallPng);
                }, align: Align.Baseline);
            }, align: Align.Center));
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
