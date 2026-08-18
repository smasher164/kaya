// The grow conformance scene, C# port — see guests/rust/grow.rs for the
// rationale. EVERY child is a grower, so each split is exactly
// weight/Σweight: 1,2,1 divide the column 25/50/25 and the row's 1,3
// divide its width 25/75. Those numbers are what KAYA_SELFTEST=grow
// asserts, so a non-growing child changes them.

static class GrowScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var probe = tx.Signal("grow probe");
            var one = tx.Signal("one");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: probe, grow: 1); // label#0
                tx.Textarea(grow: 2); // textarea#0
                tx.Row(() =>
                {
                    tx.Label(bind: one, grow: 1); // label#1
                    tx.Button("three", grow: 3);
                }, grow: 1, spacing: 12);
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
