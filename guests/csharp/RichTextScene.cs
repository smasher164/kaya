// The rich text scene, C# port — guests/rust/richtext.rs,
// tools/scenes/richtext.steps. THE OFFSETS ARE UTF-8 BYTES; the é in the
// first word is what makes a UTF-16 reader fail (docs/ranges-units.md),
// so every range here goes through TextRange.In, which converts against
// the text it indexes.

using System;
using System.Collections.Generic;

static class RichTextScene
{
    const string Doc = "Héllo world\nSecond line";
    const string Url = "https://kaya.dev";

    /// The core's spelling of runs (`expect_runs`), so the binding's
    /// document and the core's mirror are compared as one string.
    static string Spell(IReadOnlyList<TextRun> runs)
    {
        var parts = new List<string>();
        foreach (TextRun run in runs)
            parts.Add(run.Value == "true"
                ? $"{run.Start}:{run.Stop} {run.Name}"
                : $"{run.Start}:{run.Stop} {run.Name}={run.Value}");
        return string.Join("|", parts);
    }

    public static void Run()
    {
        var app = new KayaApp();

        Signal last = default;
        Signal runs = default;
        Widget editor = default;

        app.Build(tx =>
        {
            tx.Window(title: "richtext");
            last = tx.Signal("");
            runs = tx.Signal("");

            tx.Mount(tx.Column(() =>
            {
                editor = tx.Textarea(rich: true);
                tx.SetA11yId(editor, "doc");
                tx.SetA11yLabel(editor, "Document");
                app.OnEdit(editor, (t, edit) =>
                {
                    t.Write(last,
                        $"edit {edit.Start}:{edit.Stop} <{edit.Inserted}> [{Spell(edit.Runs)}]");
                    t.Write(runs, Spell(app.Document(editor).Runs));
                });
                app.OnFormat(editor, (t, act) =>
                {
                    t.Write(last,
                        $"format {act.Start}:{act.Stop} {act.Name}={act.Value ?? "off"}");
                    t.Write(runs, Spell(app.Document(editor).Runs));
                });

                tx.Label(bind: last); // label#0
                tx.Label(bind: runs); // label#1

                tx.Row(() =>
                {
                    tx.Button("seed", onClick: t => // button#0
                    {
                        var doc = new Document(Doc)
                            .Bold(TextRange.In(Doc, 0, 5))
                            .Link(TextRange.In(Doc, 6, 5), Url)
                            .Block(TextRange.In(Doc, 12, 11), BlockKind.Heading2);
                        t.SetDocument(editor, doc);
                        t.Write(runs, Spell(doc.Runs));
                    });
                    tx.Button("insert", onClick: t => // button#1
                    {
                        var edit = Edit.Insert(TextRange.In(Doc, 5, 0), ", big")
                            .Mark(TextRange.In(", big", 2, 3), "italic", "true");
                        t.ApplyEdit(editor, edit);
                        t.Write(runs, Spell(app.Document(editor).Runs));
                    });
                    tx.Button("select word", onClick: t => // button#2
                        t.SelectRange(editor, TextRange.In(Doc, 0, 5)));
                    tx.Button("unbold", onClick: t => t.Unformat(editor, "bold")); // button#3
                    tx.Button("heading", onClick: t => // button#4
                        t.SetBlock(editor, BlockKind.Heading1));
                    tx.Button("focus", onClick: t => t.Focus(editor)); // button#5
                    tx.Button("prefix", onClick: t => // button#6
                    {
                        t.ApplyEdit(editor, Edit.Insert(TextRange.In(Doc, 0, 0), "> "));
                        t.Write(runs, Spell(app.Document(editor).Runs));
                    });
                });
            }));
        });

        Environment.Exit(app.Run());
    }
}
