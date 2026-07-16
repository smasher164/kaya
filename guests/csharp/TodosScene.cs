// The todos scene from C#, on the construction sugar: the record type
// is the schema, constructors carry their props and handlers, and
// params-array containers make the build body the scene's shape. The
// sugar lowers eagerly to the same records as the explicit floor —
// Milestone2Scene keeps that style on purpose.
//
//     KAYA_SELFTEST=todos KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

using System.Collections.Generic;

// The record is the schema.
record Todo(string Title, bool Done);

static class TodosScene
{
    public static void Run()
    {
        var app = new KayaApp();

        // The fold: widget-owned state arrives as occurrences; the
        // app's copy is this variable, not a widget read.
        string draft = "";
        int nextKey = 0;

        app.Build(tx =>
        {
            var itemsLeft = tx.Signal("0 items left");
            var todos = tx.CollectionOf<Todo>();

            string ItemsLeftText(Tx t)
            {
                int n = 0;
                foreach (var entry in todos.Items(t))
                    if (!entry.Value.Done)
                        n++;
                return n == 1 ? "1 item left" : $"{n} items left";
            }

            tx.Mount(tx.Column(
                tx.Entry((t, text) => draft = text),
                tx.Button("Add", t =>
                {
                    nextKey++;
                    todos.Insert(t, $"t{nextKey}", new Todo(draft, false));
                    t.Write(itemsLeft, ItemsLeftText(t));
                }),
                tx.Label(bind: itemsLeft),
                tx.Each(todos.Collection, t => t.Row(
                    todos.Checkbox(t, x => x.Done, (t2, keys, isChecked) =>
                    {
                        // One field's delta: the title never travels.
                        todos.Patch(t2, keys[0]).Set(x => x.Done, isChecked);
                        t2.Write(itemsLeft, ItemsLeftText(t2));
                    }),
                    todos.Label(t, x => x.Title)))));
        });

        System.Environment.Exit(app.Run());
    }
}
