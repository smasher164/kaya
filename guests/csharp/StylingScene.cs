// The styling conformance scene, C# port — the brand accent, the role
// tier and the window inset, together because they are one design
// (docs/styling-plan.md slice 1, D2/D3). A role changes a widget's
// chrome and its assistive trait, never what pressing it does.
//
// See guests/rust/styling.rs; the byte-frozen contract is
// tools/scenes/styling.steps.

static class StylingScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        app.Build(tx =>
        {
            // BEFORE THE FIRST MOUNT, per the set-once wall.
            tx.BrandAccent(0x3584E4);
            tx.Window(title: "styling", width: 480, height: 360, inset: 0);
            var heading = tx.Signal("Sections");
            status = tx.Signal("ready");

            tx.Mount(tx.Column(() =>
            {
                // expect_ax resolves its target through the AUTHORED id,
                // so everything the steps read back is identified.
                tx.SetA11yId(tx.Label(bind: heading, role: Role.Heading), "title"); // label#0
                tx.Label(bind: status);                                             // label#1
                tx.SetA11yId(
                    tx.Button("Delete", role: Role.Destructive,
                        onClick: t => t.Write(status, "deleted")),
                    "delete"); // button#0
                tx.SetA11yId(
                    tx.Button("Save", role: Role.Prominent,
                        onClick: t => t.Write(status, "saved")),
                    "save"); // button#1
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
