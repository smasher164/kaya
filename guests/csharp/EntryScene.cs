// The entry scene from C#: the uncontrolled contract end to end. The
// field owns its text and reports each edit through OnChange; the app
// folds those into a plain variable (draft) — its own model, per
// doctrine. The add button inserts the draft and answers with the count
// read from the collection model.
//
// WHAT THIS SCENE DOCUMENTS IS EVENT RECEPTION, and in C# that is
// CENTRAL REGISTRATION: the build body hands the widget handles back
// out, and app.OnChange/app.OnClick attach to them afterwards. So the
// constructors below deliberately pass no handler argument, which is
// the one thing separating this build body from TodosScene.cs's.
// Everything else is the ordinary construction sugar every example
// scene uses — containers parent their own body, constructors carry
// their props — because the carve-out is the event mechanism and
// nothing else (DESIGN.md, scope ratified 2026-08-05).
//
// AND THE APP NAMES NO TODO. A todo here is a line of text and nothing
// else — it has no identity of its own — so the key comes from
// InsertFresh: the binding mints one per collection instance and hands
// it back (docs/fresh-key-plan.md). This app has no use for the key —
// nothing here looks a todo up — so the call is made for effect; an
// app that selects the new row takes the key from here rather than
// inventing a second name for the same datum.
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

        // The fold: widget-owned state arrives as occurrences; the
        // app's copy is this variable, not a widget read.
        string draft = "";
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
            tx.InsertFresh(todos, draft);
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
