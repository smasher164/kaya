// The number field scene, C# port — guests/rust/numberfield.rs,
// tools/scenes/numberfield.steps.

using System;

[KayaGen]
record Line(string Name, double Qty);

static class NumberFieldScene
{
    // The harness's own value spelling (crates/kaya/src/harness.rs).
    static string Spelled(double v) =>
        v.ToString("F6", System.Globalization.CultureInfo.InvariantCulture)
            .TrimEnd('0').TrimEnd('.');

    public static void Run()
    {
        var app = new KayaApp();
        var commits = 0;

        app.Build(tx =>
        {
            var commitText = tx.Signal("commits: 0");
            var rowText = tx.Signal("row: none");
            var amountValue = tx.Signal(0.0);
            var lines = LineKaya.Collection(tx);

            tx.Mount(tx.Column(root =>
            {
                tx.SetA11yId(tx.Label(bind: commitText), "commits");
                tx.SetA11yId(tx.Label(bind: rowText), "row");
                var amount = tx.NumberField(
                    min: 0.0, max: 100.0, step: 0.5,
                    onCommit: (t, _) =>
                    {
                        commits++;
                        t.Write(commitText, $"commits: {commits}");
                    },
                    bind: amountValue);
                tx.SetA11yId(amount, "amount");
                tx.SetA11yLabel(amount, "Amount");
                tx.SetA11yId(tx.Entry(), "note");
                // A programmatic write must NOT come back as a commit.
                tx.SetA11yId(tx.Button("forty", t => t.Write(amountValue, 40.0)), "forty");
                foreach (var row in lines.Rows())
                {
                    row.Label(row.Name);
                    var qty = row.NumberField(row.Qty, min: 0.0,
                        onCommit: (t, keys, v) =>
                        {
                            t.Write(rowText, $"row {keys[0]}: {Spelled(v)}");
                        });
                    row.SetA11yId(qty, "qty");
                }
                return root;
            }));

            lines.Insert(tx, "a", new Line("a", 1.0));
            lines.Insert(tx, "b", new Line("b", 2.0));
        });

        System.Environment.Exit(app.Run());
    }
}
