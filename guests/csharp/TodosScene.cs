// The todos scene, C# port — guests/rust/todos.rs, tools/scenes/todos.steps.

using System.Collections.Generic;

[KayaGen]
record Todo(string Title, bool Done);

static class TodosScene
{
    public static void Run()
    {
        var app = new KayaApp();

        string draft = "";

        app.Build(tx =>
        {
            var edit = tx.Menu("Edit", items: new[]
            {
                tx.Item("Undo", role: Tx.RoleUndo),
                tx.Item("Redo", role: Tx.RoleRedo),
            });
            // No onUndone and no onRedone, deliberately: this scene shows core
            // state only.
            tx.Window(title: "todos", menus: new[] { edit });
            var todos = TodoKaya.Collection(tx);
            var itemsLeft = todos.Derive(tx, items =>
            {
                int n = 0;
                foreach (var entry in items)
                    if (!entry.Value.Done)
                        n++;
                return n == 1 ? "1 item left" : $"{n} items left";
            });

            tx.Mount(tx.Column(() =>
            {
                var field = tx.Entry((t, text) => draft = text);
                tx.Button("Add", t =>
                {
                    if (draft.Length == 0)
                        return;
                    t.Undoable($"add {draft}");
                    todos.InsertFresh(t, new Todo(draft, false));
                    // Clear inside an undoable group is refused at apply
                    // (docs/undo-plan.md D4).
                    app.Post(after =>
                    {
                        after.Clear(field);
                        after.Focus(field);
                    });
                });
                tx.Label(bind: itemsLeft);
                // The foreach IS the For: the enumerator's Dispose closes the
                // template even on break.
                foreach (var row in todos.Rows())
                {
                    row.Row(() =>
                    {
                        row.Checkbox(row.Done, (t2, keys, isChecked) =>
                        {
                            TodoKaya.Patch(t2, todos, keys[0]).Done(isChecked);
                        });
                        row.Label(row.Title);
                    });
                }
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
