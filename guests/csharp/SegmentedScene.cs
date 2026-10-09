// The segmented control scene, C# port — guests/rust/segmented.rs,
// tools/scenes/segmented.steps.

[KayaGen]
record Habit(string Name, double Cadence);

static class SegmentedScene
{
    static readonly string[] Periods = { "Day", "Week", "Month" };
    static readonly (string Name, Symbol Symbol)[] Views =
        { ("Info", Symbol.Info), ("Edit", Symbol.Edit) };
    static readonly string[] Cadences = { "Daily", "Weekly" };

    public static void Run()
    {
        var app = new KayaApp();
        var heard = 0;

        app.Build(tx =>
        {
            tx.Window(title: "segmented");
            var period = tx.Signal(0.0);
            var periodText = tx.Signal("period: Day");
            var heardText = tx.Signal("heard: 0");
            var viewText = tx.Signal("view: Edit");
            var cadenceText = tx.Signal("cadence: -");
            var habits = HabitKaya.Collection(tx);

            tx.Mount(tx.Column(root =>
            {
                var seg = tx.Segmented(Periods, period, (t, index) =>
                {
                    heard++;
                    t.Write(period, (double)index);
                    t.Write(periodText, $"period: {Periods[index]}");
                    t.Write(heardText, $"heard: {heard}");
                });
                tx.SetA11yId(seg, "period");
                tx.SetA11yLabel(seg, "Period");
                tx.Label(bind: periodText);
                tx.Label(bind: heardText);
                var reset = tx.Button("Reset", t =>
                {
                    t.Write(period, 0.0);
                    t.Write(periodText, "period: Day");
                });
                tx.SetA11yId(reset, "reset");
                var view = tx.SegmentedSymbols(Views, 1, (t, index) =>
                    t.Write(viewText, $"view: {Views[index].Name}"));
                tx.SetA11yId(view, "view");
                tx.SetA11yLabel(view, "View");
                tx.Label(bind: viewText);
                tx.Label(bind: cadenceText);
                foreach (var row in habits.Rows())
                {
                    row.Label(row.Name);
                    var cadence = row.Segmented(Cadences, row.Cadence, (t, keys, index) =>
                        t.Write(cadenceText, $"cadence {keys[0]}: {Cadences[index]}"));
                    row.SetA11yId(cadence, "cadence");
                }
                return root;
            }));

            habits.Insert(tx, "read", new Habit("read", 1.0));
            habits.Insert(tx, "walk", new Habit("walk", 0.0));
        });

        System.Environment.Exit(app.Run());
    }
}
