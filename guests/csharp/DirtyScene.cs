// The dirty-state conformance scene, C# port — unsaved work as window
// chrome (docs/dirty-plan.md). kaya never infers it, so the app declares
// it on both edges. See guests/rust/dirty.rs and tools/scenes/dirty.steps.

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

            // dirty: and vetoClose: are orthogonal. No dirty: here: the
            // clean state is the scene's first assertion.
            tx.Window(title: "dirty", vetoClose: true, onCloseRequested: t =>
            {
                t.ShowAlert(
                    title: "unsaved changes",
                    message: "the document has unsaved changes",
                    action0: "Discard", cancel: "Keep Editing",
                    onResult: (inner, choice) =>
                    {
                        // The scene always answers cancel: this arm
                        // ABORTS if it ever runs (docs/traps.md, "An app
                        // can VETO a close but cannot AGREE to one").
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
