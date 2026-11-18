// The restoration scene, C# port — guests/rust/restore.rs,
// tools/scenes/restore.steps (docs/restoration-plan.md SR15).

namespace Restore;

[KayaGen]
record RestoreLine(string Text);

static class RestoreScene
{
    public static void Run()
    {
        var app = new KayaApp();
        var session = KayaApp.Session();

        app.Build(tx =>
        {
            tx.Window(title: "restore");
            var messages = RestoreLineKaya.Collection(tx);
            var launch = tx.Signal($"launch {KayaApp.Restored()}");
            Widget list = default;
            Widget doc = default;
            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: launch);
                var field = tx.Entry(onChange: (_, text) => session.SetString("draft", text));
                tx.SetText(field, session.GetString("draft", ""));
                tx.Row(_ =>
                {
                    tx.SetA11yId(tx.Button("jump", onClick: t => t.ScrollToRow(list, "m30")), "jump");
                    tx.SetA11yId(tx.Button("select", onClick: t => t.SelectRange(doc, TextRange.Bytes(4, 9))),
                        "select");
                });
                doc = tx.Textarea();
                tx.SetA11yId(doc, "doc");
                tx.SetText(doc, "the quick brown fox");
                tx.Scroll(scroll =>
                {
                    tx.SetA11yId(scroll, "list");
                    list = RestoreLineKaya.Each(tx, messages, row => row.Label(row.Text));
                    tx.SetA11yId(list, "messages");
                }, grow: 1);
                return root;
            }));
            for (int i = 1; i <= 60; i++)
                messages.Insert(tx, $"m{i}", new RestoreLine($"message {i}"));
        });

        System.Environment.Exit(app.Run());
    }
}
