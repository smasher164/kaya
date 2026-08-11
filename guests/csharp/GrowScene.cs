// The grow conformance scene, C# port — see guests/rust/grow.rs for
// the full rationale. Every child of the column and of the row is a
// grower, so each split is exactly weight/Σweight: 1,2,1 divide the
// column 25/50/25 and the row's 1,3 divide its width 25/75. The
// harness (KAYA_SELFTEST=grow) asserts both splits, root-fills, and
// that the textarea TAKES the track its weight earned, byte-for-byte
// against every other language and backend.
//
// The `grow:` argument is the declarative spelling; tx.SetGrow is the
// dynamic path this scene has no reason to use.

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
