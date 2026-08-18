// The entry scene from C#: the uncontrolled contract end to end. The
// field owns its text and reports each edit through OnChange; the app
// folds those into a plain variable (draft) — its own model, per
// doctrine. The add button inserts the draft and answers with the count
// read from the collection model.
//
// This scene documents CENTRAL REGISTRATION: the build body hands the
// widget handles back out and app.OnChange/app.OnClick attach to them
// afterwards, so the constructors below deliberately pass no handler
// argument. That is the only thing separating this build body from
// TodosScene.cs's.
//
// Keys come from InsertFresh rather than the app
// (docs/fresh-key-plan.md).
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
            todos = tx.Collection();

            tx.Mount(tx.Column(() =>
            {
                // The two handles the registrations below need. No
                // onChange:/onClick: here — see the header.
                field = tx.Entry();
                add = tx.Button("add");
                tx.Label(bind: status);
                // A scalar collection IS its one field, so the row's
                // label addresses field 0 of the element.
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
            // Atomically with the insert. The field answers with
            // text_changed("") through its normal edit path, so the fold
            // above empties the draft.
            tx.Clear(field);
            tx.Focus(field);
        });

        System.Environment.Exit(app.Run());
    }
}
