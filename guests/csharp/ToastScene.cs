// The toast scene, C# port — guests/rust/toast.rs, tools/scenes/toast.steps.

using System.Collections.Generic;

static class ToastScene
{
    static string Titles(Tx tx, RecordCollection<Item> items)
    {
        var all = new List<string>();
        foreach (var entry in items.Items(tx))
            all.Add(entry.Value.Title);
        return all.Count == 0 ? "empty" : string.Join(", ", all);
    }

    public static void Run()
    {
        var app = new KayaApp();
        var answers = 0;
        var undos = 0;
        ulong? held = null;

        app.Build(tx =>
        {
            var last = tx.Signal("no answer yet");
            var count = tx.Signal("answers 0");
            var undone = tx.Signal("nothing undone");
            var rows = tx.Signal("Milk, Eggs, Bread");
            var items = ItemKaya.Collection(tx);

            void Answer(Tx t, string text, ToastOutcome outcome)
            {
                answers++;
                t.Write(count, $"answers {answers}");
                t.Write(last, $"{text}: {(outcome == ToastOutcome.Action ? "action" : "closed")}");
            }

            async System.Threading.Tasks.Task Show(string text, string? action)
            {
                var outcome = await app.ShowToastAsync(text, action: action);
                app.Build(t => Answer(t, text, outcome));
            }

            var edit = tx.Menu("Edit", items: new[]
            {
                tx.Item("Undo", role: MenuRole.Undo),
                tx.Item("Redo", role: MenuRole.Redo),
            });
            tx.Window(title: "toast", menus: new[] { edit },
                onUndone: (t, label, _) =>
                {
                    undos++;
                    t.Write(undone, $"undone {undos}: {label}");
                    t.Write(rows, Titles(t, items));
                });

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: last);    // label#0
                tx.Label(bind: count);   // label#1
                tx.Label(bind: undone);  // label#2
                tx.Label(bind: rows);    // label#3
                tx.Button("show", onClick: async _ => await Show("Saved", null));      // button#0
                tx.Button("first", onClick: async _ => await Show("First", "Open"));   // button#1
                tx.Button("second", onClick: async _ => await Show("Second", "Open")); // button#2
                tx.Button("delete", onClick: async t =>                   // button#3
                {
                    var entries = items.Items(t);
                    if (entries.Count == 0)
                        return;
                    var first = entries[0];
                    t.Undoable($"delete {first.Value.Title}");
                    t.Remove(items.Collection, first.Key);
                    t.Write(rows, Titles(t, items));
                    var text = $"Deleted {first.Value.Title}";
                    var outcome = await app.ShowToastAsync(text, action: "Undo", undo: true);
                    app.Build(after => Answer(after, text, outcome));
                });
                tx.Button("hold", onClick: t =>                           // button#4
                    held = t.ShowToast("Working", duration: ToastDuration.Long,
                        onResult: (after, outcome) => Answer(after, "Working", outcome)));
                tx.Button("dismiss", onClick: t =>                        // button#5
                {
                    if (held is ulong id)
                    {
                        held = null;
                        t.DismissToast(id);
                    }
                });
                foreach (var row in items.Rows())
                    row.Row(() => row.Label(row.Title));
                return root;
            }));

            foreach (var title in new[] { "Milk", "Eggs", "Bread" })
                items.Insert(tx, title, new Item(title));
        });

        System.Environment.Exit(app.Run());
    }
}
