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
            parts.Add(run.Value == "true"
                ? $"{run.Start}:{run.Stop} {run.Name}"
                : $"{run.Start}:{run.Stop} {run.Name}={run.Value}");
        return string.Join("|", parts);
    }

    public static void Run()
    {
        var app = new KayaApp();

        Signal runs = default;
        Widget body = default;
        Widget heading = default;

        app.Build(tx =>
        {
            tx.Window(title: "richlabel");
            runs = tx.Signal("");

            tx.Mount(tx.Column(() =>
            {
                Signal bodyText = tx.Signal("");
                Signal headingText = tx.Signal(Title);

                body = tx.Label(bind: bodyText, rich: true); // label#0
                tx.SetA11yId(body, "body");
                heading = tx.Label(bind: headingText, role: Role.Heading, // label#1
                    rich: true);
                tx.SetA11yId(heading, "heading");
                Widget mirror = tx.Label(bind: runs); // label#2
                tx.SetA11yId(mirror, "runs");

                tx.Row(() =>
                {
                    tx.Button("seed", onClick: t => // button#0
                    {
                        var doc = new Document(Doc)
                            .Bold(TextRange.In(Doc, 0, 5))
                            .Link(TextRange.In(Doc, 6, 5), Url)
                            .Mark(TextRange.In(Doc, 13, 4), "code", "true");
                        var title = new Document(Title)
                            .Mark(TextRange.In(Title, 13, 6), "italic", "true");
                        t.SetDocument(body, doc);
                        t.SetDocument(heading, title);
                        t.Write(runs, Spell(doc.Runs));
                    });
                    tx.Button("insert", onClick: t => // button#1
                    {
                        var edit = Edit.Insert(TextRange.In(Doc, 5, 0), ", big")
                            .Mark(TextRange.In(", big", 2, 3), "italic", "true");
                        t.ApplyEdit(body, edit);
                        t.Write(runs, Spell(app.Document(body).Runs));
                    });
                });
            }));
        });

        Environment.Exit(app.Run());
    }
}
