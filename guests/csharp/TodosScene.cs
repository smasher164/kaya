// The todos scene from C#, on the construction sugar. Keys come from
// InsertFresh rather than the app (docs/fresh-key-plan.md); undo is
// docs/undo-plan.md.
//
//     KAYA_SELFTEST=todos KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

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
            // No onUndone and no onRedone, deliberately: everything this
            // scene shows is core state, so there is no app model left
            // over to fold a delta into.
            tx.Window(title: "todos", menus: new[] { edit });
            var todos = TodoKaya.Collection(tx);
            // A derived signal: the binding recomputes it after every
            // mutation and writes it INTO THAT MUTATION'S transaction, so
            // it walks back and forward with an undone step.
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
                    // Finishing the form is not part of the step, and
                    // Clear inside an undoable group is refused at apply
                    // (docs/undo-plan.md D4).
                    app.Post(after =>
                    {
                        after.Clear(field);
                        after.Focus(field);
                    });
                });
                tx.Label(bind: itemsLeft);
                // The foreach IS the For: the body runs once, and the
                // enumerator's Dispose closes the template even on break.
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
