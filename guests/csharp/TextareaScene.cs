// The textarea conformance scene, C# port. See
// guests/rust/textarea.rs and tools/scenes/textarea.steps.

static class TextareaScene
{
    static string Count(string text) =>
        string.IsNullOrEmpty(text)
            ? "0 lines"
            : $"{text.TrimEnd('\n').Split('\n').Length} lines";

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.WindowTitle("textarea");
            var lines = tx.Signal("0 lines");

            tx.Mount(tx.Column(() =>
            {
                var editor = tx.Textarea((t, text) =>
                    t.Write(lines, Count(text)));
                tx.Label(bind: lines); // label#0
                tx.Button("clear", onClick: t =>
                {
                    t.Clear(editor);
                    t.Focus(editor);
                });
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
