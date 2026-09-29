// The range scene, C# port — guests/rust/range.rs, tools/scenes/range.steps.

using System;

[KayaGen]
record Clip(string Name, double TrimIn, double TrimOut);

static class RangeScene
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
            var liveText = tx.Signal("live: 2 8");
            var commitText = tx.Signal("commits: 0");
            var volumeText = tx.Signal("volume: 0.25");
            var clipText = tx.Signal("clip: none");
            var lowSig = tx.Signal(2.0);
            var highSig = tx.Signal(8.0);
            var clips = ClipKaya.Collection(tx);

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: liveText);                          // label#0
                tx.Label(bind: commitText);                        // label#1
                tx.Label(bind: volumeText);                        // label#2
                tx.Label(bind: clipText);                          // label#3
                var trim = tx.Range(                               // range#0
                    min: 0.0, max: 10.0, step: 0.5, tickSpacing: 1.0, minGap: 1.0,
                    lowLabel: "In", highLabel: "Out",
                    onChange: (t, low, high) =>
                        t.Write(liveText, $"live: {Spelled(low)} {Spelled(high)}"),
                    onCommit: (t, low, high) =>
                    {
                        commits++;
                        t.Write(commitText,
                            $"commits: {commits} at {Spelled(low)} {Spelled(high)}");
                    },
                    bindLow: lowSig, bindHigh: highSig);
                tx.SetA11yLabel(trim, "Trim");
                tx.SetA11yId(trim, "trim");
                var tie = tx.Range(                                // range#1
                    min: 0.0, max: 10.0, low: 4.0, high: 6.0, step: 0.5, tickSpacing: 1.0,
                    minGap: 0.0);
                tx.SetA11yLabel(tie, "Tie");
                var playhead = tx.Slider(min: 0.0, max: 10.0, value: 5.0); // slider#0
                tx.SetA11yLabel(playhead, "Playhead");
                var volume = tx.Slider(                            // slider#1
                    min: 0.0, max: 1.0, value: 0.25, step: 0.25, axis: Axis.Vertical,
                    onChange: (t, v) => t.Write(volumeText, $"volume: {Spelled(v)}"));
                tx.SetA11yLabel(volume, "Volume");
                tx.SetA11yId(volume, "volume");
                // Must NOT come back as a move or a commit.
                tx.Button("reset", t => t.Write(lowSig, 1.0));     // button#0
                // Crosses a high thumb the user moved; the core clamps it (docs/range-plan.md §3).
                tx.Button("late", t => t.Write(lowSig, 6.0));      // button#1
                foreach (var row in clips.Rows())
                {
                    row.Label(row.Name);
                    var clip = row.Range(0.0, 10.0, row.TrimIn, row.TrimOut, step: 0.5,
                        minGap: 1.0,
                        onCommit: (t, keys, low, high) =>
                            t.Write(clipText, $"clip {keys[0]}: {Spelled(low)} {Spelled(high)}"));
                    row.SetA11yId(clip, "clip");
                }
                return root;
            }));

            clips.Insert(tx, "a", new Clip("a", 1.0, 4.0));
            clips.Insert(tx, "b", new Clip("b", 3.0, 7.0));
        });

        System.Environment.Exit(app.Run());
    }
}
