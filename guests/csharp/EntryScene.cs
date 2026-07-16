// The entry scene from C#: the uncontrolled contract end to end. The
// field owns its text and reports each edit through OnChange; the app
// folds those into a plain variable (draft) — its own model, per
// doctrine. The add button inserts the draft and answers with the count
// read from the collection model.
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
            nextKey++;
            tx.Insert(todos, $"t{nextKey}", draft);
            int total = tx.Count(todos);
            tx.Write(status, $"added {draft}, {total} total");
        });

        System.Environment.Exit(app.Run());
    }
}
