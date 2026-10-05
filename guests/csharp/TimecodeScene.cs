using System;

static class TimecodeScene
{
    public static void Run()
    {
        var app = new KayaApp();
        var normal = new TimecodeRate(25);
        var drop = new TimecodeRate(30000, 1001, true);
        var commits = 0;
        var phase = 0;
        app.Build(tx =>
        {
            tx.Window(title: "Timecode", width: 440, height: 500);
            var status = tx.Signal("commits: 0");
            var rowStatus = tx.Signal("row: none");
            var playhead = tx.Signal(Kaya.Fmt.Timecode(93087, normal));
            var rows = LineKaya.Collection(tx);
            var switchValue = tx.Signal(-2.0);
            Action<Tx, double> committed = (t, frames) =>
            {
                commits++;
                t.Write(status, $"commits: {commits}");
                t.Write(playhead, Kaya.Fmt.Timecode((long)frames, normal));
            };
            tx.Mount(tx.Column(root =>
            {
                tx.Label("25 fps");
                tx.SetA11yId(tx.Label(bind: playhead), "playhead");
                var position = tx.NumberField(93087, format: NumberFormat.Timecode(normal), onCommit: committed);
                tx.SetA11yId(position, "position");
                tx.SetA11yLabel(position, "Position");
                tx.SetA11yId(tx.Label(bind: status), "commits");
                tx.Label("29.97 drop-frame");
                var field = tx.NumberField(1799, format: NumberFormat.Timecode(drop), onCommit: committed);
                tx.SetA11yId(field, "drop");
                tx.SetA11yLabel(field, "Drop frame");
                tx.SetA11yId(tx.Entry(), "note");
                foreach (var row in rows.Rows())
                {
                    var stamped = row.NumberField(row.Qty, format: NumberFormat.Timecode(normal),
                        onCommit: (t, keys, frames) => t.Write(rowStatus,
                            FormattableString.Invariant($"row {keys[0]}: {frames}")));
                    row.SetA11yId(stamped, "rowtime");
                }
                tx.SetA11yId(tx.Label(bind: rowStatus), "row");
                var switching = tx.NumberField(bind: switchValue);
                tx.SetA11yId(switching, "switching");
                tx.SetA11yId(tx.Button("Switch format", t =>
                {
                    switch (phase)
                    {
                        case 0:
                            t.SetFormat(switching, NumberFormat.Timecode(drop));
                            t.Write(switchValue, 1800.0);
                            break;
                        case 1:
                            t.Write(switchValue, -2.0);
                            t.SetFormat(switching, NumberFormat.Number);
                            break;
                        case 2:
                            t.Write(switchValue, 1800.0);
                            t.SetFormat(switching, NumberFormat.Timecode(drop));
                            break;
                        default:
                            t.SetFormat(switching, NumberFormat.Number);
                            t.Write(switchValue, -2.0);
                            break;
                    }
                    phase = (phase + 1) % 4;
                }), "switchformat");
                return root;
            }));
            rows.Insert(tx, "a", new Line("a", 25));
        });
        Environment.Exit(app.Run());
    }
}
