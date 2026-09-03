// The dirty scene, C# port — guests/rust/dirty.rs, tools/scenes/dirty.steps.

static class DirtyScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal doc = default, status = default;
        app.Build(tx =>
        {
            doc = tx.Signal("notes");
            status = tx.Signal("saved");

            // No dirty: here — the clean state is the first assertion.
            tx.Window(title: "dirty", vetoClose: true, onCloseRequested: t =>
            {
                t.ShowAlert(
                    title: "unsaved changes",
                    message: "the document has unsaved changes",
                    action0: "Discard", cancel: "Keep Editing",
                    onResult: (inner, choice) =>
                    {
                        // Aborts if it ever runs (docs/traps.md, an app can VETO a
                        // close but cannot AGREE to one).
                        if (choice == KayaWire.AlertChoiceCancel)
                            inner.Write(status, "kept editing");
                        else
                            inner.DestroyWindow(0);
                    });
            });

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: doc);    // label#0
                tx.Label(bind: status); // label#1
                tx.Button("edit", onClick: t =>
                {
                    t.Write(doc, "notes and a line");
                    t.Write(status, "unsaved");
                    t.Window(dirty: true);
                }); // button#0
                tx.Button("save", onClick: t =>
                {
                    t.Write(status, "saved");
                    t.Window(dirty: false);
                }); // button#1
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
