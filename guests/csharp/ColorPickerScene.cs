// The colour picker scene, C# port — guests/rust/colorpicker.rs,
// tools/scenes/colorpicker.steps.

using System;

[KayaGen]
record Swatch(string Name, Color Fill);

static class ColorPickerScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var titleText = tx.Signal("color: none");
            var glazeText = tx.Signal("alpha: none");
            var rowText = tx.Signal("row: none");
            var titleSig = tx.Signal(Color.FromHex(0x336699FF));
            var swatches = SwatchKaya.Collection(tx);

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: titleText);                         // label#0
                tx.Label(bind: glazeText);                         // label#1
                tx.Label(bind: rowText);                           // label#2
                var title = tx.ColorPicker(
                    onColor: (t, picked) => t.Write(titleText, $"color: {picked}"),
                    bind: titleSig);                               // color_picker#0
                tx.SetA11yLabel(title, "Title colour");
                tx.SetA11yId(title, "title");
                var glaze = tx.ColorPicker(Color.FromHex(0x26A269FF), alpha: true,
                    onColor: (t, picked) => t.Write(glazeText, $"alpha: {picked}"));
                tx.SetA11yLabel(glaze, "Glaze");                  // color_picker#1
                // Must NOT come back as a title choice.
                tx.Button("reset", t => t.Write(titleSig, Color.FromHex(0x3584E4FF)));
                foreach (var row in swatches.Rows())
                {
                    row.Label(row.Name);
                    var picker = row.ColorPicker(row.Fill, onColor: (t, keys, picked) =>
                    {
                        t.Write(rowText, $"row {keys[0]}: {picked}");
                    });
                    row.SetA11yId(picker, "fill");
                }
                return root;
            }));

            swatches.Insert(tx, "a", new Swatch("a", Color.FromHex(0xE66100FF)));
            swatches.Insert(tx, "b", new Swatch("b", Color.FromHex(0xF6D32DFF)));
        });

        System.Environment.Exit(app.Run());
    }
}
