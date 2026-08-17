// The typeface conformance scene, C# port (docs/styling-plan.md Slice
// 2b): the brand typeface swaps the FAMILY and leaves the platform's
// ramp alone.
//
// One call is the whole surface — a family name, plus the per-platform
// rows a lane needs — and everything after it is ordinary widgets, which
// is the claim the scene makes: a typeface is chrome, so the field still
// takes text and the button still fires. What it does NOT do is name a
// size anywhere. Sizes, weights and metrics stay the platform's; the
// role tier is what carries emphasis (Role.Heading on the title label
// below), and that is exactly what makes a family swap safe.
//
// WHY A BUNDLED FONT, and why no platforms: row: the reasoning is in
// guests/rust/typeface.rs's doc comment, which is the canonical note for
// this scene. In short, the scene requests the VENDORED font's bytes so
// the resolved family is one string on every lane and no platform's
// fallback can equal it. font: is C#'s spelling of the blob form;
// platforms: is what a name-based app would reach for instead, and this
// scene needs none.
//
// The byte-frozen contract is tools/scenes/typeface.steps.

static class TypefaceScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        // The fold: widget-owned state arrives as occurrences, and the
        // app's copy is this variable rather than a widget read.
        string draft = "";

        app.Build(tx =>
        {
            // BEFORE THE FIRST MOUNT, per the set-once wall: brand is
            // identity, not state, and a backend never sees a typeface
            // it would have to un-apply.
            // THE VENDORED BYTES, then the family they carry: the blob
            // registers with the platform's app-font machinery and the
            // "Sora" request resolves to it — register-then-resolve, the
            // same call a brand book's licensed font would make.
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
                // the system face. expect_ax resolves it through its
                // authored id, the a11y scene's discipline.
                tx.SetA11yId(tx.Label(bind: heading, role: Role.Heading), "title"); // label#0
                tx.Label(bind: status);                                             // label#1
                // A FIELD AND A TEXTAREA, because they are the two views
                // the observation reads (NSTextField and NSTextView on
                // this platform) and they arrive by DIFFERENT routes:
                // the field inherits the root font, the textarea names
                // its own ramp rung and takes the swap explicitly. A
                // scene with one of them could not tell a half-applied
                // lowering from a whole one.
                tx.Entry((t, text) => draft = text);  // entry#0
                tx.Textarea();                        // textarea#0
                tx.Button("Go",                       // button#0
                    onClick: t => t.Write(status, $"clicked {draft}"));
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
