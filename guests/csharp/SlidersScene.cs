// The sliders scene, C# port — guests/rust/sliders.rs, tools/scenes/sliders.steps.

using System;

[KayaGen]
record Track(string Name, double Level);

static class SlidersScene
{
    // The harness's own slider spelling (crates/kaya/src/harness.rs).
    static string Spelled(double v) =>
        v.ToString("F6", System.Globalization.CultureInfo.InvariantCulture)
            .TrimEnd('0').TrimEnd('.');

    public static void Run()
    {
        var app = new KayaApp();
        var commits = 0;

        app.Build(tx =>
        {
            var levelText = tx.Signal("value: 50");
            var commitText = tx.Signal("commits: 0");
            var volumeText = tx.Signal("volume: 0.5");
            var rowText = tx.Signal("row: none");
            var pos = tx.Signal(50.0);
            var tracks = TrackKaya.Collection(tx);

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: levelText);                         // label#0
                tx.Label(bind: commitText);                        // label#1
                tx.Label(bind: volumeText);                        // label#2
                tx.Label(bind: rowText);                           // label#3
                var master = tx.Slider(                            // slider#0
                    min: 0.0, max: 100.0, step: 5.0, tickSpacing: 25.0,
                    onChange: (t, v) => t.Write(levelText, $"value: {Spelled(v)}"),
                    onCommit: (t, _) =>
                    {
                        commits++;
                        t.Write(commitText, $"commits: {commits}");
                    },
                    bind: pos);
                tx.SetA11yId(master, "master");
                tx.SetA11yLabel(master, "Level");
                var volume = tx.Slider(                            // slider#1
                    min: 0.0, max: 1.0, value: 0.5, tickSpacing: 0.25,
                    onChange: (t, v) => t.Write(volumeText, $"volume: {Spelled(v)}"));
                tx.SetA11yLabel(volume, "Volume");
                // A programmatic write must NOT echo a value or a commit.
                tx.Button("reset", t => t.Write(pos, 25.0));       // button#0
                foreach (var row in tracks.Rows())
                {
                    row.Label(row.Name);
                    var level = row.Slider(0.0, 100.0, row.Level, step: 10.0,
                        onCommit: (t, keys, v) =>
                        {
                            t.Write(rowText, $"row {keys[0]}: {Spelled(v)}");
                        });
                    row.SetA11yId(level, "level");
                }
            }));

            tracks.Insert(tx, "a", new Track("a", 70.0));
            tracks.Insert(tx, "b", new Track("b", 20.0));
        });

        System.Environment.Exit(app.Run());
    }
}
