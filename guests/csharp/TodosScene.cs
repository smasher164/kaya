// The todos scene from C#: records and field projection. The record
// type is the schema — CollectionOf reflects its primary constructor
// once at declaration — the template binds each field to its own
// widget through typed field tokens, and toggling a row sends one
// field's delta through UpdateField: the title never travels.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=todos KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

// The record is the schema.
record Todo(string Title, bool Done);

static class TodosScene
{
    // The field tokens, checked against the record at startup.
    static readonly Field<string> FieldTitle = KayaRecords.FieldOf<Todo, string>("Title");
    static readonly Field<bool> FieldDone = KayaRecords.FieldOf<Todo, bool>("Done");

    public static void Run()
    {
        var app = new KayaApp();

        Signal itemsLeft = default;
        Widget field = default, add = default;
        RecordCollection<Todo> todos = null;
        Node check = default;

        string ItemsLeftText(Tx tx)
        {
            int n = 0;
            foreach (var entry in todos.Items(tx))
                if (!entry.Value.Done)
                    n++;
            return n == 1 ? "1 item left" : $"{n} items left";
        }

        app.Build(tx =>
        {
            itemsLeft = tx.Signal("0 items left");

            var column = tx.Widget(KayaWire.KindColumn);
            field = tx.Widget(KayaWire.KindEntry);
            add = tx.Widget(KayaWire.KindButton);
            tx.SetText(add, "Add");
            var status = tx.Widget(KayaWire.KindLabel);
            tx.BindText(status, itemsLeft);

            todos = tx.CollectionOf<Todo>();
            var todoList = tx.ForEach(todos.Collection, t =>
            {
                var row = t.Widget(KayaWire.KindRow);
                check = t.Widget(KayaWire.KindCheckbox);
                t.BindCheckedField(check, 0, FieldDone);
                var title = t.Widget(KayaWire.KindLabel);
                t.BindTextField(title, 0, FieldTitle);
                t.AddChild(row, check);
                t.AddChild(row, title);
            });

            tx.AddChild(column, field);
            tx.AddChild(column, add);
            tx.AddChild(column, status);
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
            todos.Insert(tx, $"t{nextKey}", new Todo(draft, false));
            tx.Write(itemsLeft, ItemsLeftText(tx));
        });
        app.OnToggle(check, (tx, keys, isChecked) =>
        {
            // One field's delta: the title never travels.
            todos.UpdateField(tx, keys[0], FieldDone, isChecked);
            tx.Write(itemsLeft, ItemsLeftText(tx));
        });

        System.Environment.Exit(app.Run());
    }
}
