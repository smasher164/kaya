// The styling conformance scene, C# port — the brand accent, the role
// tier and the window inset, together because they are one design
// (docs/styling-plan.md, slice 1): brand slots fill each platform's
// token system, roles say what a widget MEANS, and the inset is the one
// layout knob the pass admitted (D3).
//
// The C# spelling is the named-argument one this binding uses
// everywhere: role: rides the widget constructor beside grow:, inset:
// rides the window construct beside title: and size, and BrandAccent is
// a call of its own because brand is APP identity rather than a
// window's attribute.
//
// What each piece demonstrates:
//   - BrandAccent(0x3584E4) — Adwaita blue, the derivation's empirical
//     anchor: one hex is the whole call, the core derives fills and
//     foregrounds, and a platform may let its user override the result
//     (D2).
//   - role: Role.Heading on the title label — the platform's heading
//     text style AND the assistive heading trait, which is the one role
//     the steps freeze from the real tree on every lane.
//   - role: Role.Destructive / Role.Prominent on the two buttons — the
//     platform's own emphasis chrome, and (the scene's point) NO change
//     to what pressing them does.
//   - inset: 0 — full bleed, the editor's own need, honored
//     unconditionally because the inset is kaya's padding (D3).
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
            // BEFORE THE FIRST MOUNT, per the set-once wall: brand is
            // identity, not state.
            tx.BrandAccent(0x3584E4);
            tx.Window(title: "styling", width: 480, height: 360, inset: 0);
            var heading = tx.Signal("Sections");
            status = tx.Signal("ready");

            tx.Mount(tx.Column(() =>
            {
                // expect_ax resolves a target through its AUTHORED id
                // into the real tree, so everything the steps read back
                // is identified (the a11y scene's discipline).
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
