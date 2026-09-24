// The submit scene, C# port — guests/rust/submit.rs,
// tools/scenes/submit.steps. Return in an entry, a search field and a
// `submits` textarea publishes the field's text; a plain textarea's
// Return is its newline. The app writes each submit into one label.

[KayaGen]
record ChatThread(string Title);

static class SubmitScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var threads = ChatThreadKaya.Collection(tx);
            var sent = tx.Signal("sent: -");

            tx.Mount(tx.Column(root =>
            {
                tx.SetA11yId(tx.Label(bind: sent), "sent");

                var name = tx.Entry();
                tx.SetPlaceholder(name, "Name");
                tx.SetA11yId(name, "name");
                app.OnSubmitted(name, (t, text) => t.Write(sent, $"sent: {text}"));

                var find = tx.Search();
                tx.SetPlaceholder(find, "Search");
                tx.SetA11yId(find, "find");
                app.OnSubmitted(find, (t, text) => t.Write(sent, $"sent: {text}"));

                var plain = tx.Textarea();
                tx.SetA11yId(plain, "plain");
                app.OnSubmitted(plain, (t, text) => t.Write(sent, $"sent: {text}"));

                var compose = tx.Textarea(submits: true);
                tx.SetA11yId(compose, "compose");
                app.OnSubmitted(compose, (t, text) => t.Write(sent, $"sent: {text}"));

                foreach (var row in threads.Rows())
                {
                    row.Label(row.Title);
                    Node reply = row.Entry();
                    row.SetA11yId(reply, "reply");
                    app.OnSubmitted(reply, (t, keys, text) =>
                        t.Write(sent, $"sent: {(string)keys[0]}: {text}"));
                }
                return root;
            }));

            threads.Insert(tx, "r1", new ChatThread("First"));
            threads.Insert(tx, "r2", new ChatThread("Second"));
        });

        System.Environment.Exit(app.Run());
    }
}
