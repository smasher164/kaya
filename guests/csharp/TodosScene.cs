// The todos scene from C#, on the construction sugar: the record type
// is the schema, constructors carry their props and handlers, and
// params-array containers make the build body the scene's shape. The
// sugar lowers eagerly to the same records as the explicit floor —
// the C guests keep that style on purpose.
//
//     KAYA_SELFTEST=todos KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

using System.Collections.Generic;

// The record is the schema.
// The record is the schema; kaya-csgen reads this declaration and
// generates TodoKaya: the collection factory, exact-index field
// tokens, and the named-setter patch.
[KayaGen]
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
            var todos = TodoKaya.Collection(tx);
            // The items-left label is a derived signal: the binding
            // recomputes it from the collection after every mutation,
            // so no handler mentions it.
            var itemsLeft = todos.Derive(tx, items =>
            {
                int n = 0;
                foreach (var entry in items)
                    if (!entry.Value.Done)
                        n++;
                return n == 1 ? "1 item left" : $"{n} items left";
            });

            tx.Mount(tx.Column(
                tx.Entry((t, text) => draft = text),
                tx.Button("Add", t =>
                {
                    nextKey++;
                    todos.Insert(t, $"t{nextKey}", new Todo(draft, false));
                }),
                tx.Label(bind: itemsLeft),
                // The generated row surface: exact-index tokens, no
                // expression trees or probes; the body runs once,
                // authoring the blueprint.
                TodoKaya.Each(tx, todos, (t, row) => t.Row(
                    row.Checkbox(t, row.Done, (t2, keys, isChecked) =>
                    {
                        // One field's delta: the title never travels;
                        // the derived signal updates itself.
                        TodoKaya.Patch(t2, todos, keys[0]).Done(isChecked);
                    }),
                    row.Label(t, row.Title)))));
        });

        System.Environment.Exit(app.Run());
    }
}
