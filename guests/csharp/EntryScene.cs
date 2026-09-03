// The entry scene, C# port — guests/rust/entry.rs, tools/scenes/entry.steps.

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
            todos = tx.Collection();

            tx.Mount(tx.Column(() =>
            {
                field = tx.Entry();
                add = tx.Button("add");
                tx.Label(bind: status);
                tx.Each(todos, t => t.Label(KayaRecords.FieldAt<string>(0)));
            }));
        });

        string draft = "";
        app.OnChange(field, (tx, text) => draft = text);
        app.OnClick(add, tx =>
        {
            if (draft.Length == 0)
            {
                tx.Write(status, $"nothing to add, {tx.Count(todos)} total");
                return;
            }
            tx.InsertFresh(todos, draft);
            int total = tx.Count(todos);
            tx.Write(status, $"added {draft}, {total} total");
            tx.Clear(field);
            tx.Focus(field);
        });

        System.Environment.Exit(app.Run());
    }
}
