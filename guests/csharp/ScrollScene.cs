// The scroll scene, C# port — guests/rust/scroll.rs,
// tools/scenes/scroll.steps.

static class ScrollScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        app.Build(tx =>
        {
            tx.Window(title: "scroll");
            status = tx.Signal("at top");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: status); // label#0
                tx.Scroll(() => // scroll#0
                {
                    tx.Column(() =>
                    {
                        for (int i = 1; i <= 29; i++)
                        {
                            var caption = tx.Signal($"row {i}");
                            tx.Label(bind: caption);
                        }
                        tx.Button("bottom", onClick: inner => // button#0
                            inner.Write(status, "bottom clicked"));
                    });
                }, grow: 1);
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
