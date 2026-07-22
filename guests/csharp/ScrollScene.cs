// The scroll conformance scene, C# port — the viewport grows so the
// enclosing track constrains it (an unconstrained viewport hugs its
// content and nothing overflows); the bottom button, reachable only
// by scrolling, proves the scrolled-to content is live. See
// guests/rust/scroll.rs and tools/scenes/scroll.steps.

static class ScrollScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        app.Build(tx =>
        {
            tx.WindowTitle("scroll");
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
