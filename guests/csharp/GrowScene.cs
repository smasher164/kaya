// The grow scene, C# port — guests/rust/grow.rs, tools/scenes/grow.steps.

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
