// The accessibility conformance scene from C#: the two universal props
// (SetA11yId, SetA11yLabel), read back out of the PLATFORM'S OWN
// accessibility tree. EXACTLY ONE CONTAINER OF EACH KIND — container
// targets are ordinal. See guests/rust/a11y.rs, tools/scenes/a11y.steps.

static class A11yScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var form = tx.Column(() =>
            {
                // Caption-bearing controls: identified, deliberately NOT
                // labelled — the platform must speak the caption.
                var save = tx.Button("Save");
                tx.SetA11yId(save, "save");
                tx.SetA11yHint(save, "save the draft");
                var details = tx.Checkbox("Details");
                tx.SetA11yId(details, "details");
                tx.SetA11yHint(details, "show more detail");
                tx.SetA11yId(tx.Button("Reset"), "reset");
                tx.SetA11yId(tx.Label("Ready"), "status");
                // Caption-less controls: an app MUST name these, and
                // the tree must report the authored name.
                var name = tx.Entry();
                tx.SetA11yId(name, "name");
                tx.SetA11yLabel(name, "Full name");
                var notes = tx.Textarea();
                tx.SetA11yId(notes, "notes");
                tx.SetA11yLabel(notes, "Notes");
                var volume = tx.Slider(0.0, 1.0, 0.5);
                tx.SetA11yId(volume, "volume");
                tx.SetA11yLabel(volume, "Volume");
                var loading = tx.Progress(0.25);
                tx.SetA11yId(loading, "loading");
                tx.SetA11yLabel(loading, "Loading");
                var logo = tx.Image(TestPng);
                tx.SetA11yId(logo, "logo");
                tx.SetA11yLabel(logo, "Logo");
                var color = tx.Select(new[] { "Red", "Green" });
                tx.SetA11yId(color, "color");
                tx.SetA11yLabel(color, "Color");
                var size = tx.Radio(new[] { "Small", "Large" });
                tx.SetA11yId(size, "size");
                tx.SetA11yLabel(size, "Size");
                var cells = tx.Grid(2, () =>
                {
                    tx.Label("Name");
                    tx.Label("Ada");
                });
                tx.SetA11yId(cells, "cells");
                tx.SetA11yLabel(cells, "Cells");
                var feed = tx.Scroll(() => tx.Label("Item"));
                tx.SetA11yId(feed, "feed");
                tx.SetA11yLabel(feed, "Feed");
                var actions = tx.Row(() =>
                {
                    tx.SetA11yId(tx.Button("Cancel"), "cancel");
                    tx.SetA11yId(tx.Button("OK"), "ok");
                });
                tx.SetA11yId(actions, "actions");
                tx.SetA11yLabel(actions, "Actions");
            });
            tx.SetA11yId(form, "form");
            tx.SetA11yLabel(form, "Form");
            tx.Mount(form);
        });

        System.Environment.Exit(app.Run());
    }

    // A 2x2 RGB PNG, 75 bytes, embedded as source.
    static readonly byte[] TestPng =
    {
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0,
        0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192, 0,
        194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0,
        0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    };
}
