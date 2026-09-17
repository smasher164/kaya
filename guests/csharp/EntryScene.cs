// The entry scene, C# port — guests/rust/entry.rs, tools/scenes/entry.steps.

static class EntryScene
{
    public static void Run()
    {
        var app = new KayaApp();

        var (status, field, add, todos) = app.Build(tx =>
        {
            var status = tx.Signal("no todos");
            var todos = tx.Collection();

            var (root, field, add) = tx.Column(root =>
            {
                var field = tx.Entry();
                var add = tx.Button("add");
                tx.Label(bind: status);
                tx.Each(todos, t => t.Label(KayaRecords.FieldAt<string>(0)));
                return (root, field, add);
            });
            tx.Mount(root);
            return (status, field, add, todos);
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
