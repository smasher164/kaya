// The a11y scene, C# port — guests/rust/a11y.rs, tools/scenes/a11y.steps.

static class A11yScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var form = tx.Column(form =>
            {
                // Deliberately not labelled: the platform must speak the caption.
                var save = tx.Button("Save");
                tx.SetA11yId(save, "save");
                tx.SetA11yHint(save, "save the draft");
                var details = tx.Checkbox("Details");
                tx.SetA11yId(details, "details");
                tx.SetA11yHint(details, "show more detail");
                tx.SetA11yId(tx.Button("Reset"), "reset");
                tx.SetA11yId(tx.Label("Ready"), "status");
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
                // Safe: the blob table holds its own reference by now.
                using var mark = tx.Asset("images/a11y-logo.png");
                var logo = tx.Image(mark);
                tx.SetA11yId(logo, "logo");
                tx.SetA11yLabel(logo, "Logo");
                var color = tx.Select(new[] { "Red", "Green" });
                tx.SetA11yId(color, "color");
                tx.SetA11yLabel(color, "Color");
                var size = tx.Radio(new[] { "Small", "Large" });
                tx.SetA11yId(size, "size");
                tx.SetA11yLabel(size, "Size");
                var cells = tx.Grid(2, cells =>
                {
                    tx.Label("Name");
                    tx.Label("Ada");
                    return cells;
                });
                tx.SetA11yId(cells, "cells");
                tx.SetA11yLabel(cells, "Cells");
                var feed = tx.Scroll(feed =>
                {
                    tx.Label("Item");
                    return feed;
                });
                tx.SetA11yId(feed, "feed");
                tx.SetA11yLabel(feed, "Feed");
                var actions = tx.Row(actions =>
                {
                    tx.SetA11yId(tx.Button("Cancel"), "cancel");
                    tx.SetA11yId(tx.Button("OK"), "ok");
                    return actions;
                });
                tx.SetA11yId(actions, "actions");
                tx.SetA11yLabel(actions, "Actions");
                var spoken = tx.Signal("Before");
                var spokenLabel = tx.Label("Spoken");
                tx.SetA11yId(spokenLabel, "spoken");
                tx.SetA11yLabel(spokenLabel, spoken);
                tx.SetA11yId(
                    tx.Button("Rename", onClick: inner => inner.Write(spoken, "After")),
                    "rename");
                return form;
            });
            tx.SetA11yId(form, "form");
            tx.SetA11yLabel(form, "Form");
            tx.Mount(form);
        });

        System.Environment.Exit(app.Run());
    }
}
