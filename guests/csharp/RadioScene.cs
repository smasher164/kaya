// The radio conformance scene, C# port. See
// guests/rust/radio.rs and tools/scenes/radio.steps.

static class RadioScene
{
    static readonly string[] Options = { "Small", "Medium", "Large" };

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "radio");
            var size = tx.Signal("size: Small");

            tx.Mount(tx.Column(() =>
            {
                tx.Radio(Options, 0, (t, index) =>
                    t.Write(size, $"size: {Options[index]}"));
                tx.Label(bind: size); // label#0
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
