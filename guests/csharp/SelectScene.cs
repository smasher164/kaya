// The select conformance scene, C# port. See
// guests/rust/select.rs and tools/scenes/select.steps.

static class SelectScene
{
    static readonly string[] Options = { "Red", "Green", "Blue" };

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "select");
            var picked = tx.Signal("picked: Red");

            tx.Mount(tx.Column(() =>
            {
                tx.Select(Options, 0, (t, index) =>
                    t.Write(picked, $"picked: {Options[index]}"));
                tx.Label(bind: picked); // label#0
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
