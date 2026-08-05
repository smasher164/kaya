// The todos scene from C#, on the construction sugar: the record type
// is the schema, constructors carry their props and handlers, and
// params-array containers make the build body the scene's shape. The
// sugar lowers eagerly to the same records as the explicit floor —
// the C guests keep that style on purpose.
//
// AND THE APP NAMES NO TODO. A todo here is a title and a done flag,
// and neither of them identifies it, so the key comes from InsertFresh:
// the binding mints one per collection instance and hands it back
// (docs/fresh-key-plan.md). The row's checkbox carries that key back
// out through the stamped path and straight into Patch, which is the
// whole of what this scene asks of a key — the app never reads it,
// formats it or compares it, and so has no reason to author it.
//
// AND THE DERIVED LABEL COMES BACK FROM AN UNDO WITH NOBODY RESTORING
// IT. The add names its transaction (t.Undoable), and the Derive below
// writes into that same one: InsertFresh recomputes, and the binding
// pushes an ordinary signal write into the batch that caused it. So the
// core banks "0 items left" in the step's inverse and "1 item left" in
// its forward, and hands the label back together with the collection it
// counts. That is why this file passes no onUndone to tx.Window — there
// is nothing for a handler to fix up, and a binding that recomputed the
// Derive while folding an undo payload would be writing a value the
// ledger never banked (KayaApp.AbsorbUndo says so from the other end).
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

        app.Build(tx =>
        {
            // THE GESTURE LAYER, and the two items are the whole of it:
            // an app declares them and writes nothing else. They act on
            // what is focused, lower to the platform's own command where
            // it has one, and work out their own enablement from what
            // the ledger holds (docs/undo-plan.md D1-D6).
            var edit = tx.Menu("Edit", items: new[]
            {
                tx.Item("Undo", role: Tx.RoleUndo),
                tx.Item("Redo", role: Tx.RoleRedo),
            });
            // No onUndone and no onRedone, deliberately: everything this
            // scene shows is core state, so the core restores all of it
            // and there is no app model left over to fold a delta into.
            tx.Window(title: "todos", menus: new[] { edit });
            var todos = TodoKaya.Collection(tx);
            // The items-left label is a derived signal: the binding
            // recomputes it from the collection after every mutation and
            // writes it INTO THAT MUTATION'S TRANSACTION, so no handler
            // mentions it — going forward or coming back.
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
                    // ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The
                    // name is what the step is called; everything in this
                    // transaction is what it did — including the
                    // items-left write the Derive makes on the way past,
                    // which is why the label walks back and forward with
                    // the todo instead of going stale behind it.
                    t.Undoable($"add {draft}");
                    // NO KEY, AND NO COUNTER TO GET WRONG: the binding
                    // mints the name and hands it back. This app has no
                    // use for the returned key — a todo is looked up by
                    // nothing, and the checkbox's own path names its row
                    // — so the call is made for effect.
                    todos.InsertFresh(t, new Todo(draft, false));
                    // FINISHING THE FORM IS NOT PART OF THE STEP. In C# a
                    // handler IS a transaction, so the rest reaches its
                    // own one through App.Post — undoing the add must not
                    // put "buy milk" back in the field beside a todo that
                    // is gone, and Clear inside a group would be refused
                    // at apply anyway (D4), because it destroys
                    // widget-owned text the core never held. The field
                    // empties on screen and reports text_changed("")
                    // through its normal edit path (the fold empties the
                    // draft), and the cursor lands back in it.
                    app.Post(after =>
                    {
                        after.Clear(field);
                        after.Focus(field);
                    });
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
