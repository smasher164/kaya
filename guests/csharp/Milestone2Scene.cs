// The milestone-2 scene from C#: how occurrences reach an app. A
// stamped copy's handler is registered CENTRALLY after the build,
// against the template node, and arrives carrying that copy's key path;
// a live widget's handler rides its constructor.
//
// A C# lambda captures its enclosing locals by reference, so the two
// handles the central registration needs are assigned to the scene's
// own locals from inside the template bodies that build them.
//
// Build the library first (cargo build / cargo xwin build --release),
// keep kaya.dll on PATH or set KAYA_LIB, then: dotnet run

static class Milestone2Scene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        Collection items = default;
        Node removeButton = default;

        int steps = 0;
        app.Build(tx =>
        {
            status = tx.Signal("step 0");
            var stepCount = tx.Signal(0);

            var groups = tx.Collection();

            tx.Mount(tx.Column(() =>
            {
                tx.Button("step", t =>
                {
                    steps++;
                    if (steps == 1)
                    {
                        t.Insert(groups, "g1", "Work");
                        var todos = items.At("g1");
                        t.Insert(todos, "a", "send report");
                        t.Insert(todos, "b", "buy milk");
                    }
                    else if (steps == 2)
                    {
                        t.Insert(groups, "g2", "Home");
                        t.Insert(items.At("g2"), "a", "water plants");
                        t.Update(groups, "g1", "Office");
                    }
                    t.Write(stepCount, steps);
                    t.Write(status, $"step {steps}");
                });
                tx.Label(bind: status);
                tx.When(stepCount == 1, t => t.Label("extras on"));
                tx.Each(groups, group =>
                {
                    group.Column(() =>
                    {
                        // A scalar collection's element IS its one wire
                        // field, so the row's label addresses field 0.
                        group.Label(KayaRecords.FieldAt<string>(0));
                        items = group.Collection();
                        group.Each(items, item =>
                        {
                            item.Column(() =>
                            {
                                item.Label(KayaRecords.FieldAt<string>(0));
                                removeButton = item.Button("remove");
                            });
                        });
                    });
                });
            }));
        });

        app.OnClick(removeButton, (tx, keys) =>
        {
            string group = (string)keys[0];
            string item = (string)keys[1];
            var todos = items.At(group);
            tx.Remove(todos, item);
            int left = tx.Count(todos);
            tx.Write(status, $"removed {group}/{item}, {left} left");
        });

        System.Environment.Exit(app.Run());
    }
}
