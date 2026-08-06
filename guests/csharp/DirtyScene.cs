// The dirty-state conformance scene, C# port — unsaved work as window
// chrome (docs/dirty-plan.md), spelled with named arguments: dirty:
// rides the window construct exactly as vetoClose: and title: do,
// because a window's attributes ride its window construct. One boolean
// and the backend shows its platform's own affordance (the dot in the
// close button on macOS, a leading `*` in the rendered caption on
// Windows, a bullet in the GTK header bar, nothing on the phones,
// which have none).
//
// TWO DECLARATIONS, ON PURPOSE. An edit writes the document AND says
// dirty: true; saving writes it back and says dirty: false. kaya does
// not watch your signals and guess — "the document has unsaved
// changes" is a statement only the app can make, and the window
// construct is where it makes it.
//
// AND THE MARK ARMS NOTHING. The close attempt fires the veto class
// this window already opted into, the app opens its own dialog, and
// cancelling keeps the window with the mark still up. That flow is
// composed here out of parts that predate this prop — which is the
// whole reason dirty: is presentation and nothing else.
//
// See guests/rust/dirty.rs and tools/scenes/dirty.steps.

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

            // dirty: and vetoClose: are orthogonal — either can be set
            // without the other, on every platform. This window takes
            // vetoClose because it is an editor: it owns its close so
            // it can ask. It does NOT take dirty: here, because a
            // freshly opened document has no unsaved work, and that
            // clean state is the scene's first assertion.
            //
            // The close handler binds to THE WINDOW at its declaration
            // (handlers scope to the thing that creates them): it can
            // only ever mean this surface's close was asked for.
            tx.Window(title: "dirty", vetoClose: true, onCloseRequested: t =>
            {
                // Nothing has closed: the veto class says so. An
                // editor with unsaved work asks; a clean one agrees at
                // once. The result handler rides the REQUEST and
                // retires with its one answer.
                t.ShowAlert(
                    title: "unsaved changes",
                    message: "the document has unsaved changes",
                    action0: "Discard", cancel: "Keep Editing",
                    onResult: (inner, choice) =>
                    {
                        // Agreeing destroys the surface, which for the
                        // PRIMARY window is the process itself — so the
                        // scene answers cancel and this arm stays the
                        // honest spelling of "yes, close it" rather
                        // than a step. Answering a dialog is not
                        // saving: the mark stays up either way.
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
                    // The model and the declaration in ONE
                    // transaction, and neither implies the other.
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
