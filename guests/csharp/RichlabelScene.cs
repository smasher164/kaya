// The rich label scene, C# port — guests/rust/richlabel.rs,
// tools/scenes/richlabel.steps (docs/rich-text-plan.md R8, §15): a label
// carries the inline vocabulary read-only. THE OFFSETS ARE UTF-8 BYTES; the
// é in the first word is what makes a UTF-16 reader fail
// (docs/ranges-units.md), so every range goes through TextRange.In, which
// converts against the text it indexes.

using System;
using System.Collections.Generic;

static class RichlabelScene
{
    const string Doc = "Héllo world, code";
    const string Title = "Heading with italic";
    const string Url = "https://kaya.dev";

    /// The core's spelling of runs (`expect_runs`), so the binding's
    /// document and the core's mirror are compared as one string.
    static string Spell(IReadOnlyList<TextRun> runs)
    {
        var parts = new List<string>();
        foreach (TextRun run in runs)
            parts.Add(run.IsFlag
                ? $"{run.Range.Start}:{run.Range.Stop} {run.Name}"
                : $"{run.Range.Start}:{run.Range.Stop} {run.Name}={run.Value}");
        return string.Join("|", parts);
    }

    public static void Run()
    {
        var app = new KayaApp();

        var (runs, body, heading) = app.Build(tx =>
        {
            tx.Window(title: "richlabel");
            var runs = tx.Signal("");

            var (root, body, heading) = tx.Column(root =>
            {
                Signal bodyText = tx.Signal("");
                Signal headingText = tx.Signal(Title);

                var body = tx.Label(bind: bodyText, rich: true); // label#0
                tx.SetA11yId(body, "body");
                var heading = tx.Label(bind: headingText, role: Role.Heading, // label#1
                    rich: true);
                tx.SetA11yId(heading, "heading");
                Widget mirror = tx.Label(bind: runs); // label#2
                tx.SetA11yId(mirror, "runs");

                tx.Row(_ =>
                {
                    tx.Button("seed", onClick: t => // button#0
                    {
                        var doc = new Document(Doc)
                            .Bold(TextRange.In(Doc, 0, 5))
                            .Link(TextRange.In(Doc, 6, 5), Url)
                            .Mark(TextRange.In(Doc, 13, 4), "code", true);
                        var title = new Document(Title)
                            .Mark(TextRange.In(Title, 13, 6), "italic", true);
                        t.SetDocument(body, doc);
                        t.SetDocument(heading, title);
                        t.Write(runs, Spell(doc.Runs));
                    });
                    tx.Button("insert", onClick: t => // button#1
                    {
                        var edit = Edit.Insert(TextRange.In(Doc, 5, 0), ", big")
                            .Mark(TextRange.In(", big", 2, 3), "italic", true);
                        t.ApplyEdit(body, edit);
                        t.Write(runs, Spell(app.Document(body).Runs));
                    });
                    // THE RANGED ACT ON A LABEL (docs/rich-text-plan.md §17):
                    // the label's own document written by range, no selection
                    // to move; the ranges convert against the CURRENT text,
                    // which the insert moved.
                    tx.Button("mark", onClick: t => // button#2
                    {
                        string text = app.Document(body).Text;
                        t.FormatRange(body, TextRange.In(text, 1, 2), "italic", true);
                        t.UnformatRange(body, TextRange.In(text, 0, 2), "bold"); // "Hé"
                        t.Write(runs, Spell(app.Document(body).Runs));
                    });
                });
                return (root, body, heading);
            });
            tx.Mount(root);
            return (runs, body, heading);
        });

        Environment.Exit(app.Run());
    }
}
