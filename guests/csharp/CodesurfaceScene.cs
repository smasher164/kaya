// The code surface scene, C# port: guests/rust/codesurface.rs,
// tools/scenes/codesurface.steps (docs/code-surface-plan.md): a textarea that
// numbers its lines, the platform's monospaced face, a family picked from the
// platform's list, a family the platform lacks, a label at twice the size.

static class CodesurfaceScene
{
    // Forty lines; the third wraps at every lane's width.
    static string Document()
    {
        var lines = new List<string>
        {
            "// codesurface",
            "fn main() {",
            "    let note = \"this line is long on purpose, so that the textarea wraps it onto a second row "
                + "and the gutter has a continuation to leave unnumbered, the way every editor does\";",
        };
        for (int i = 4; i < 40; i++) lines.Add($"    let value_{i:00} = {i} * 2;");
        lines.Add("}");
        return string.Join("\n", lines);
    }

    public static void Run()
    {
        var app = new KayaApp();
        string doc = Document();
        Widget code = default, picked = default;
        Signal listed = default;

        app.OnFontFamilies((t, families) =>
        {
            bool ordered = true;
            for (int i = 1; i < families.Count; i++)
                if (string.CompareOrdinal(families[i - 1], families[i]) >= 0) ordered = false;
            t.Write(listed, families.Count == 0 ? "families: none"
                : ordered ? "families: listed, unique, in order" : "families: out of order");
            if (families.Count > 0) t.SetFamily(picked, families[0]);
        });

        app.Build(tx =>
        {
            tx.Window(title: "codesurface");
            listed = tx.Signal("families: -");
            tx.Mount(tx.Column(root =>
            {
                code = tx.Textarea();
                tx.SetLineNumbers(code, true);
                tx.SetMonospaced(code, true);
                tx.SetA11yId(code, "code");
                tx.SetText(code, doc);
                var plain = tx.Textarea();
                tx.SetA11yId(plain, "plain");
                tx.SetText(plain, "plain text\nin the app's face");
                var mono = tx.Label("let x = 1;");
                tx.SetMonospaced(mono, true);
                tx.SetA11yId(mono, "mono");
                var monoEntry = tx.Entry();
                tx.SetMonospaced(monoEntry, true);
                tx.SetA11yId(monoEntry, "mono_entry");
                tx.SetText(monoEntry, "let y = 2;");
                var missing = tx.Label("missing");
                tx.SetFamily(missing, "Kaya No Such Family");
                tx.SetMonospaced(missing, true);
                tx.SetA11yId(missing, "missing");
                var big = tx.Label("Big");
                tx.SetTextScale(big, 2);
                tx.SetA11yId(big, "big");
                tx.SetA11yId(tx.Label("Plain"), "plain_label");
                tx.SetA11yId(tx.Label(bind: listed), "families");
                picked = tx.Label("picked");
                tx.SetA11yId(picked, "picked");
                tx.Row(_ =>
                {
                    var end = tx.Button("end", onClick: t =>
                    {
                        var at = TextRange.In(doc, doc.Length, 0);
                        t.Focus(code);
                        t.SelectRange(code, at);
                        t.RevealRange(code, at);
                    });
                    tx.SetA11yId(end, "end");
                    var fonts = tx.Button("fonts", onClick: t => t.ListFontFamilies());
                    tx.SetA11yId(fonts, "fonts");
                });
                return root;
            }));
        });
        Environment.Exit(app.Run());
    }
}
