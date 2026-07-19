// The entry scene from C#: the uncontrolled contract end to end. The
// field owns its text and reports each edit through OnChange; the app
// folds those into a plain variable (draft) — its own model, per
// doctrine. The add button inserts the draft and answers with the count
// read from the collection model.
//
// The backend selftest (KAYA_SELFTEST=entry) types "milk", clicks add,
// and expects the status label to read "added milk, 1 total", the
// field cleared and refocused (the one-shot commands riding the same
// transaction as the insert), and a second add to answer "nothing to
// add, 1 total" — proving the clear's text_changed("") re-entered
// through the normal fold and emptied the draft.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=entry KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

static class EntryScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        Widget field = default, add = default;
        Collection todos = default;

        app.Build(tx =>
        {
            status = tx.Signal("no todos");

            var column = tx.Widget(KayaWire.KindColumn);
            field = tx.Widget(KayaWire.KindEntry);
            add = tx.Widget(KayaWire.KindButton);
            tx.SetText(add, "add");
            var statusLabel = tx.Widget(KayaWire.KindLabel);
            tx.BindText(statusLabel, status);

            todos = tx.Collection();
            var todoList = tx.ForEach(todos, t =>
            {
                var label = t.Widget(KayaWire.KindLabel);
                t.BindTextElement(label);
            });

            tx.AddChild(column, field);
            tx.AddChild(column, add);
            tx.AddChild(column, statusLabel);
            tx.AddChild(column, todoList);
            tx.Mount(column);
        });

        // The fold: widget-owned state arrives as occurrences; the
        // app's copy is this variable, not a widget read.
        string draft = "";
        int nextKey = 0;
        app.OnChange(field, (tx, text) => draft = text);
        app.OnClick(add, tx =>
        {
            // The empty-draft guard every real form has — and the
            // scene's proof that clear emptied the draft through the
            // occurrence fold, not a side assignment.
            if (draft.Length == 0)
            {
                tx.Write(status, $"nothing to add, {tx.Count(todos)} total");
                return;
            }
            nextKey++;
            tx.Insert(todos, $"t{nextKey}", draft);
            int total = tx.Count(todos);
            tx.Write(status, $"added {draft}, {total} total");
            // Finish the form: drop the field's content and put the
            // cursor back, atomically with the insert. The field
            // answers with text_changed("") through its normal edit
            // path, and OnChange empties the draft.
            tx.Clear(field);
            tx.Focus(field);
        });

        System.Environment.Exit(app.Run());
    }
}
