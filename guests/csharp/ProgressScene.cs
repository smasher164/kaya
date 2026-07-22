// The progress conformance scene, C# port. See
// guests/rust/progress.rs and tools/scenes/progress.steps.

static class ProgressScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.WindowTitle("progress");
            tx.Mount(tx.Column(() =>
            {
                tx.Progress(value: 0.25); // progress#0
                tx.Progress(indeterminate: true); // progress#1
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
