// The scroll-to scene, C# port — guests/rust/scrollto.rs,
// tools/scenes/scrollto.steps. The app scrolls a list of messages to a
// row by key: the newest before the first layout, one on a click, a key
// no row holds, and its own send.

[KayaGen]
record ChatMessage(string Text);

[KayaGen]
record Frame(string Name);

static class ScrollToScene
{
    public static void Run()
    {
        var app = new KayaApp();

        int sent = 60;
        int framed = 30;

        app.Build(tx =>
        {
            var messages = ChatMessageKaya.Collection(tx);
            var frames = FrameKaya.Collection(tx);
            var count = tx.Signal("60 messages");
            Widget list = default;
            Widget strip = default;

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
                    tx.SetA11yId(
                        tx.Button("frame", onClick: t => t.ScrollToRow(strip, "f10")), "frame");
                    tx.SetA11yId(tx.Button("add frame", onClick: t =>
                    {
                        framed++;
                        frames.Insert(t, $"f{framed}", new Frame($"frame {framed}"));
                    }), "add_frame");
                });

                tx.Scroll(scroll =>
                {
                    tx.SetA11yId(scroll, "list");
                    // The For's own container is what a ScrollToRow
                    // addresses (docs/scroll-to-plan.md S1): Each hands it
                    // back.
                    list = ChatMessageKaya.Each(tx, messages, row => row.Label(row.Text));
                    tx.SetA11yId(list, "messages");
                }, grow: 1);
                // A filmstrip that runs sideways (docs/hscroll-plan.md): the
                // same ScrollToRow and followsEnd, along its own axis.
                tx.Scroll(scroll =>
                {
                    tx.SetA11yId(scroll, "strip");
                    strip = FrameKaya.Each(tx, frames, row => row.Label(row.Name));
                    tx.SetAxis(strip, Axis.Horizontal);
                    tx.SetA11yId(strip, "frames");
                }, followsEnd: true, axis: Axis.Horizontal);
                return root;
            }));

            for (int i = 1; i <= 30; i++)
                frames.Insert(tx, $"f{i}", new Frame($"frame {i}"));

            for (int i = 1; i <= 60; i++)
                messages.Insert(tx, $"m{i}", new ChatMessage($"message {i}"));
            tx.ScrollToRow(list, "m60");
        });

        System.Environment.Exit(app.Run());
    }
}
