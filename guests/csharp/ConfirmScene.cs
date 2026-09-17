// The confirm scene, C# port — guests/rust/confirm.rs,
// tools/scenes/confirm.steps.

static class ConfirmScene
{
    public static void Run()
    {
        var app = new KayaApp();

        var status = app.Build(tx =>
        {
            tx.Window(title: "confirm");
            var status = tx.Signal("no decision");

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: status); // label#0
                tx.Button("delete", onClick: inner =>
                {
                    inner.ShowAlert(
                        title: "delete item?",
                        message: "this cannot be undone",
                        action0: "Delete", action1: "Archive",
                        cancel: "Keep",
                        onResult: (tx, choice) => tx.Write(status, choice switch
                        {
                            AlertChoice.Action0 => "deleted",
                            AlertChoice.Action1 => "archived",
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
                            choice == AlertChoice.Cancel ? "held" : "ejected"));
                });
                return root;
            }));
            return status;
        });

        System.Environment.Exit(app.Run());
    }
}
