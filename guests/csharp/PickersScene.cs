// The pickers scene, C# port — guests/rust/pickers.rs, tools/scenes/pickers.steps.

using System;

[KayaGen]
record Task(string Name, DateOnly Due);

static class PickersScene
{
    static string Day(DateOnly d) => $"{d.Year:D4}-{d.Month:D2}-{d.Day:D2}";

    static string Clock(TimeOnly t) => $"{t.Hour:D2}:{t.Minute:D2}";

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var dateText = tx.Signal("date: none");
            var timeText = tx.Signal("time: none");
            var rowText = tx.Signal("row: none");
            var dateSig = tx.Signal(new DateOnly(2026, 9, 4));
            var timeSig = tx.Signal(new TimeOnly(14, 30));
            var tasks = TaskKaya.Collection(tx);

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: dateText);                          // label#0
                tx.Label(bind: timeText);                          // label#1
                tx.Label(bind: rowText);                           // label#2
                var when = tx.DatePicker(
                    min: new DateOnly(2026, 1, 1), max: new DateOnly(2026, 12, 31),
                    onDate: (t, picked) => t.Write(dateText, $"date: {Day(picked)}"),
                    bind: dateSig);                                // date_picker#0
                tx.SetA11yId(when, "when");
                tx.SetA11yLabel(when, "Due");
                var at = tx.TimePicker(
                    step: 15,
                    onTime: (t, picked) => t.Write(timeText, $"time: {Clock(picked)}"),
                    bind: timeSig);                                // time_picker#0
                tx.SetA11yId(at, "at");
                tx.SetA11yLabel(at, "At");
                tx.Button("reset", t =>                            // button#0
                {
                    t.Write(dateSig, new DateOnly(2026, 3, 1));
                    t.Write(timeSig, new TimeOnly(9, 0));
                });
                foreach (var row in tasks.Rows())
                {
                    row.Label(row.Name);
                    var picker = row.DatePicker(row.Due, (t, keys, picked) =>
                    {
                        t.Write(rowText, $"row {keys[0]}: {Day(picked)}");
                    });
                    row.SetA11yId(picker, "due");
                }
            }));

            tasks.Insert(tx, "a", new Task("a", new DateOnly(2026, 10, 1)));
            tasks.Insert(tx, "b", new Task("b", new DateOnly(2026, 11, 20)));
        });

        System.Environment.Exit(app.Run());
    }
}
