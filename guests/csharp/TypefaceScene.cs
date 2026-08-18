// The typeface conformance scene, C# port (docs/styling-plan.md Slice
// 2b): the brand typeface swaps the FAMILY and leaves the platform's
// ramp alone.
//
// The scene names no size anywhere: sizes, weights and metrics stay the
// platform's and the role tier carries emphasis. It requests the
// VENDORED font's bytes so the resolved family is one string on every
// lane — the canonical note is guests/rust/typeface.rs's doc comment.
//
// The byte-frozen contract is tools/scenes/typeface.steps.

static class TypefaceScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        string draft = "";

        app.Build(tx =>
        {
            // BEFORE THE FIRST MOUNT, per the set-once wall. The blob
            // registers with the platform's app-font machinery and the
            // "Sora" request then resolves to it.
            var fontPath =
                System.Environment.GetEnvironmentVariable("KAYA_FONT_FILE")
                ?? "guests/assets/fonts/sora-wght.ttf";
            byte[] font;
            try
            {
                font = System.IO.File.ReadAllBytes(fontPath);
            }
            catch (System.Exception e)
                when (e is System.IO.IOException
                      or System.UnauthorizedAccessException)
            {
                throw new System.InvalidOperationException(
                    $"kaya: the typeface scene needs the vendored font at " +
                    $"{fontPath} (set KAYA_FONT_FILE or run from the repo " +
                    $"root): {e.Message}", e);
            }
            tx.BrandTypeface("Sora", font: font);
            tx.Window(title: "typeface", width: 480, height: 360);
            var heading = tx.Signal("typeface");
            status = tx.Signal("ready");

            tx.Mount(tx.Column(() =>
            {
                // The heading's text style OVERRIDES the root font, so
                // this label is the one a root-only lowering leaves in
                // the system face.
                tx.SetA11yId(tx.Label(bind: heading, role: Role.Heading), "title"); // label#0
                tx.Label(bind: status);                                             // label#1
                // Both, because they take the swap by DIFFERENT routes:
                // the field inherits the root font, the textarea names
                // its own ramp rung. One of them alone could not tell a
                // half-applied lowering from a whole one.
                tx.Entry((t, text) => draft = text);  // entry#0
                tx.Textarea();                        // textarea#0
                tx.Button("Go",                       // button#0
                    onClick: t => t.Write(status, $"clicked {draft}"));
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
