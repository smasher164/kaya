// The progress scene, C# port — guests/rust/progress.rs,
// tools/scenes/progress.steps.

static class ProgressScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "progress");
            tx.Mount(tx.Column(() =>
            {
                tx.Progress(value: 0.25); // progress#0
                tx.Progress(indeterminate: true); // progress#1
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
