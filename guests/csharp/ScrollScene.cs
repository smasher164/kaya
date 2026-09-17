// The scroll scene, C# port — guests/rust/scroll.rs,
// tools/scenes/scroll.steps.

static class ScrollScene
{
    public static void Run()
    {
        var app = new KayaApp();

        var status = app.Build(tx =>
        {
            tx.Window(title: "scroll");
            var status = tx.Signal("at top");

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: status); // label#0
                tx.Scroll(_ => // scroll#0
                {
                    tx.Column(_ =>
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
                return root;
            }));
            return status;
        });

        System.Environment.Exit(app.Run());
    }
}
