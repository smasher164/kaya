// The safearea scene, C# port — guests/rust/safearea.rs,
// tools/scenes/safearea.steps (docs/safe-area-plan.md A3, A8).

static class SafeareaScene
{
    static readonly Viewbox Ground = new Viewbox(300.0, 200.0);

    static void DrawGround(Draw d, Viewbox size)
    {
        d.MoveTo(0.0, 0.0)
            .LineTo(size.W, 0.0)
            .LineTo(size.W, size.H)
            .LineTo(0.0, size.H)
            .Close()
            .Fill(Paint.SeriesFill, FillRule.Nonzero);
    }

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "safearea", width: 420, height: 640);
            var caption = tx.Signal("inset 16");

            tx.Mount(tx.Column(root =>
            {
                using var photo = tx.Asset("images/photo.jpg");
                var picture = tx.Image(photo).Bleed();
                tx.SetMaxHeight(picture, 160.0);
                tx.SetA11yId(picture, "picture");
                tx.SetA11yLabel(picture, "Photo");
                var label = tx.Label(bind: caption);
                tx.SetA11yId(label, "caption");
                var inset = tx.Button("No inset", onClick: t =>
                {
                    t.Window(inset: 0.0);
                    t.Write(caption, "inset 0");
                });
                tx.SetA11yId(inset, "inset");
                var full = tx.Button("Fullscreen", onClick: t =>
                {
                    t.Window(fullscreen: true);
                    t.Write(caption, "fullscreen");
                });
                tx.SetA11yId(full, "full");
                var ground = tx.Canvas(Ground, grow: 1.0).Bleed().OnDraw(DrawGround);
                tx.SetA11yId(ground, "ground");
                tx.SetA11yLabel(ground, "Ground");
                return root;
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
