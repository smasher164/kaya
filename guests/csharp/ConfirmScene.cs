// The confirm conformance scene, C# port — the modal-alert grammar.
// The three rounds take the three answer paths (action 0, action 1,
// KayaWire.AlertChoiceCancel, which is every platform-native
// dismissal). See guests/rust/confirm.rs and tools/scenes/confirm.steps.

static class ConfirmScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        app.Build(tx =>
        {
            tx.Window(title: "confirm");
            status = tx.Signal("no decision");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: status); // label#0
                tx.Button("delete", onClick: inner =>
                {
                    // The result handler rides the request and retires
                    // with its one answer; ids are binding-allocated.
                    inner.ShowAlert(
                        title: "delete item?",
                        message: "this cannot be undone",
                        action0: "Delete", action1: "Archive",
                        cancel: "Keep",
                        onResult: (tx, choice) => tx.Write(status, choice switch
                        {
                            0u => "deleted",
                            1u => "archived",
                            _ => "kept",
                        }));
                });
                tx.Button("eject", onClick: inner =>
                {
                    inner.ShowAlert(
                        title: "eject disk?",
                        message: "it is still mounted",
                        action0: "Eject", cancel: "Hold",
                        onResult: (tx, choice) => tx.Write(
                            status,
                            choice == KayaWire.AlertChoiceCancel ? "held" : "ejected"));
                });
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
