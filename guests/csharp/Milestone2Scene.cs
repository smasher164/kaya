// The milestone-2 scene from C#, on the construction sugar: typed
// handles, constructors carrying their handlers, containers taking
// their children, and Action<Tpl> closures instead of template_end
// bookkeeping. The wire vocabulary underneath (KayaWire.cs) is
// generated from kaya::spec by kaya-bindgen.
//
// Build the library first (cargo build / cargo xwin build --release),
// keep kaya.dll on PATH or set KAYA_LIB, then: dotnet run

using System.Collections.Generic;

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
            var extras = tx.Signal(false);

            Widget banner = tx.When(extras, t =>
            {
                Node bannerLabel = t.Widget(KayaWire.KindLabel);
                t.SetText(bannerLabel, "extras on");
            });

            var groups = tx.Collection();
            Widget groupList = tx.ForEach(groups, t =>
            {
                Node name = t.Widget(KayaWire.KindLabel);
                t.BindTextElement(name);

                items = t.Collection();
                Node itemList = t.ForEach(items, item =>
                {
                    Node text = item.Widget(KayaWire.KindLabel);
                    item.BindTextElement(text);
                    removeButton = item.Widget(KayaWire.KindButton);
                    item.SetText(removeButton, "remove");
                    item.Column(text, removeButton);
                });
                t.Column(name, itemList);
            });

            tx.Mount(tx.Column(
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
                    t.Write(extras, steps == 1);
                    t.Write(status, $"step {steps}");
                }),
                tx.Label(bind: status),
                banner,
                groupList));
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
