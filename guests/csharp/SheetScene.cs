// The sheet scene, C# port — guests/rust/sheet.rs, tools/scenes/sheet.steps.

static class SheetScene
{
    const ulong Task = 11;
    const ulong Details = 12;

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "sheet");
            var status = tx.Signal("closed");
            var draft = tx.Signal("draft: none");

            void OpenTask(Tx inner, bool armed)
            {
                // Nothing has gone when the request fires; the app keeps the
                // sheet up and says so.
                Action<Tx>? onAsk = armed ? (tx2 => tx2.Write(status, "dismiss requested")) : null;
                inner.PresentSheet(Task, title: "new task", interceptDismiss: armed, detent: Detent.Medium,
                    onDismissed: tx2 => tx2.Write(status, "dismissed"),
                    onDismissRequested: onAsk);
                var body = inner.Column(body =>
                {
                    var caption = inner.Signal("what needs doing?");
                    inner.Label(bind: caption); // label#1
                    inner.Entry((tx2, text) => tx2.Write(draft, "draft: " + text)); // entry#0
                    inner.Label(bind: draft); // label#2
                    inner.Button("details", onClick: tx2 => // button#2
                    {
                        tx2.PresentSheet(Details, title: "details",
                            onDismissed: tx3 => tx3.Write(status, "details dismissed"), parent: Task);
                        var pane = tx2.Column(pane =>
                        {
                            var more = tx2.Signal("more about it");
                            tx2.Label(bind: more);
                            return pane;
                        });
                        tx2.MountIn(Details, pane);
                        tx2.Write(status, "details open");
                    });
                    inner.Button("done", onClick: tx2 => // button#3
                    {
                        // Programmatic: no sheet_dismissed follows, so "done" stays.
                        tx2.DismissSheet(Task);
                        tx2.Write(status, "done");
                    });
                    return body;
                });
                inner.MountIn(Task, body);
                inner.Write(status, "open");
                inner.Write(draft, "draft: none");
            }

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: status); // label#0
                tx.Button("new task", onClick: inner => OpenTask(inner, false)); // button#0
                tx.Button("new task, armed", onClick: inner => OpenTask(inner, true)); // button#1
                return root;
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
