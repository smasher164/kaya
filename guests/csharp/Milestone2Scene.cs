// The milestone-2 scene from C#, on the idiomatic surface (KayaApp.cs):
// typed handles instead of hand-numbered ids, Action<Tpl> closures
// instead of template_end bookkeeping, and click handlers instead of a
// hand-rolled dispatch loop. The wire vocabulary underneath
// (KayaWire.cs) is generated from kaya::spec by kaya-bindgen.
//
// Build the library first (cargo build / cargo xwin build --release),
// keep kaya.dll on PATH or set KAYA_LIB, then: dotnet run

using System.Collections.Generic;

static class Milestone2Scene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default, extras = default;
        Widget step = default;
        Collection groups = default, items = default;
        Node removeButton = default;

        app.Build(tx =>
        {
            status = tx.Signal("step 0");
            extras = tx.Signal(false);

            Widget column = tx.Widget(KayaWire.KindColumn);
            step = tx.Widget(KayaWire.KindButton);
            tx.SetText(step, "step");
            Widget statusLabel = tx.Widget(KayaWire.KindLabel);
            tx.BindText(statusLabel, status);

            Widget banner = tx.When(extras, t =>
            {
                Node bannerLabel = t.Widget(KayaWire.KindLabel);
                t.SetText(bannerLabel, "extras on");
            });

            groups = tx.Collection();
            Widget groupList = tx.ForEach(groups, t =>
            {
                Node groupColumn = t.Widget(KayaWire.KindColumn);
                Node name = t.Widget(KayaWire.KindLabel);
                t.BindTextElement(name);
                t.AddChild(groupColumn, name);

                items = t.Collection();
                Node itemList = t.ForEach(items, item =>
                {
                    Node row = item.Widget(KayaWire.KindColumn);
                    Node text = item.Widget(KayaWire.KindLabel);
                    item.BindTextElement(text);
                    removeButton = item.Widget(KayaWire.KindButton);
                    item.SetText(removeButton, "remove");
                    item.AddChild(row, text);
                    item.AddChild(row, removeButton);
                });
                t.AddChild(groupColumn, itemList);
            });

            tx.AddChild(column, step);
            tx.AddChild(column, statusLabel);
            tx.AddChild(column, banner);
            tx.AddChild(column, groupList);
            tx.Mount(column);
        });

        int steps = 0;
        app.OnClick(step, tx =>
        {
            steps++;
            if (steps == 1)
            {
                tx.Insert(groups, "g1", "Work");
                var todos = items.At("g1");
                tx.Insert(todos, "a", "send report");
                tx.Insert(todos, "b", "buy milk");
            }
            else if (steps == 2)
            {
                tx.Insert(groups, "g2", "Home");
                tx.Insert(items.At("g2"), "a", "water plants");
                tx.Update(groups, "g1", "Office");
            }
            tx.Write(extras, steps == 1);
            tx.Write(status, $"step {steps}");
        });

        app.OnClick(removeButton, (tx, keys) =>
        {
            string group = (string)keys[0];
            string item = (string)keys[1];
            // The instance handle names the target once; mutation and
            // read hang off the same value. The collection is the
            // model: the count read is the fold of the patches, this
            // one included.
            var todos = items.At(group);
            tx.Remove(todos, item);
            int left = tx.Count(todos);
            tx.Write(status, $"removed {group}/{item}, {left} left");
        });

        System.Environment.Exit(app.Run());
    }
}
