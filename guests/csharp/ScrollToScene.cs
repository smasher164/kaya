// The scroll-to scene, C# port — guests/rust/scrollto.rs,
// tools/scenes/scrollto.steps. The app scrolls a list of messages to a
// row by key: the newest before the first layout, one on a click, a key
// no row holds, and its own send.

[KayaGen]
record ChatMessage(string Text);

static class ScrollToScene
{
    public static void Run()
    {
        var app = new KayaApp();

        int sent = 60;

        app.Build(tx =>
        {
            var messages = ChatMessageKaya.Collection(tx);
            var count = tx.Signal("60 messages");
            Widget list = default;

            tx.Mount(tx.Column(root =>
            {
                tx.SetA11yId(tx.Label(bind: count), "count");

                tx.Row(_ =>
                {
                    tx.SetA11yId(
                        tx.Button("jump", onClick: t => t.ScrollToRow(list, "m10")), "jump");
                    tx.SetA11yId(
                        tx.Button("nowhere", onClick: t => t.ScrollToRow(list, "m999")), "nowhere");
                    tx.SetA11yId(tx.Button("send", onClick: t =>
                    {
                        sent++;
                        messages.Insert(t, $"m{sent}", new ChatMessage($"message {sent}"));
                        t.Write(count, $"{sent} messages");
                        t.ScrollToRow(list, $"m{sent}");
                    }), "send");
                });

                tx.Scroll(_ =>
                {
                    // The For's own container is what a ScrollToRow
                    // addresses (docs/scroll-to-plan.md S1): Each hands it
                    // back.
                    list = ChatMessageKaya.Each(tx, messages, row => row.Label(row.Text));
                    tx.SetA11yId(list, "messages");
                }, grow: 1);
                return root;
            }));

            for (int i = 1; i <= 60; i++)
                messages.Insert(tx, $"m{i}", new ChatMessage($"message {i}"));
            tx.ScrollToRow(list, "m60");
        });

        System.Environment.Exit(app.Run());
    }
}
