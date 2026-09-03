// The typeface scene, C# port — guests/rust/typeface.rs,
// tools/scenes/typeface.steps.

static class TypefaceScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        string draft = "";

        app.Build(tx =>
        {
            // BEFORE THE FIRST MOUNT, per the set-once wall.
            using var font = tx.Asset("fonts/sora-wght.ttf");
            tx.BrandTypeface("Sora", font);
            tx.Window(title: "typeface", width: 480, height: 360);
            var heading = tx.Signal("typeface");
            status = tx.Signal("ready");

            tx.Mount(tx.Column(() =>
            {
                // The heading's text style OVERRIDES the root font: a root-only
                // lowering leaves this label in the system face.
                tx.SetA11yId(tx.Label(bind: heading, role: Role.Heading), "title"); // label#0
                tx.Label(bind: status);                                             // label#1
                // Both, because they take the swap by DIFFERENT routes.
                tx.Entry((t, text) => draft = text);  // entry#0
                tx.Textarea();                        // textarea#0
                tx.Button("Go",                       // button#0
                    onClick: t => t.Write(status, $"clicked {draft}"));
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
