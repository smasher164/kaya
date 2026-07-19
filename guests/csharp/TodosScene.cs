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

            tx.Mount(tx.Column(() =>
            {
                var field = tx.Entry((t, text) => draft = text);
                tx.Button("Add", t =>
                {
                    if (draft.Length == 0)
                        return;
                    nextKey++;
                    todos.Insert(t, $"t{nextKey}", new Todo(draft, false));
                    // Finish the form: the field empties on screen and
                    // reports text_changed("") through its normal edit
                    // path (the fold empties the draft), and the
                    // cursor lands back in it.
                    t.Clear(field);
                    t.Focus(field);
                });
                tx.Label(bind: itemsLeft);
                // The tracing tier: the foreach IS the For — the body
                // runs once over the generated row surface
                // (exact-index tokens, no probes), and the
                // enumerator's Dispose makes the close structural,
                // even on break.
                foreach (var row in todos.Rows())
                {
                    row.Row(() =>
                    {
                        row.Checkbox(row.Done, (t2, keys, isChecked) =>
                        {
                            // One field's delta: the title never
                            // travels; the derived signal updates
                            // itself.
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
