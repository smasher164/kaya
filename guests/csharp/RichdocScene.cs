// The rich document scene, C# port — guests/rust/richdoc.rs,
// tools/scenes/richdoc.steps (docs/rich-document-plan.md §9 step 2): a
// heading, a body paragraph with a preset colour, a bullet list with a
// nested item, a numbered list and a checklist, then the paragraph acts from
// buttons, the platform's colour picker and a `.kdoc` round trip. label#1 is
// the binding's own Document, folded from the same deltas, so it must spell
// what the core holds.

using System;
using System.Collections.Generic;
using System.Linq;

static class RichdocScene
{
    // BYTE-IDENTICAL to guests/rust/richdoc.rs's DOC.
    const string Doc = "Groceries\nFresh from the market.\nApples\nGreen ones\nBread\nWash\nSlice\nMilk\nEggs";

    static string Spell(IReadOnlyList<TextRun> runs)
    {
        var parts = new List<string>();
        foreach (TextRun run in runs)
            parts.Add(run.IsFlag
                ? $"{run.Range.Start}:{run.Range.Stop} {run.Name}"
                : $"{run.Range.Start}:{run.Range.Stop} {run.Name}={run.Value}");
        return string.Join("|", parts);
    }

    static TextRange Span(int start, int end) => TextRange.In(Doc, start, end - start);

    public static void Run()
    {
        var app = new KayaApp();
        var doc = new Document(Doc)
            .Block(Span(0, 9), BlockKind.Heading1)
            .Color(Span(25, 31), "#016FEF")
            .List(Span(33, 56), ListKind.Bullet)
            .Indent(Span(40, 50), 1)
            .List(Span(57, 67), ListKind.Numbered)
            .Checked(Span(68, 72))
            .List(Span(68, 77), ListKind.Check);

        // A SELF-REFERENCE, not a smuggle: the textarea's own OnEdit reads
        // the document of the widget being declared.
        Widget editor = default;

        app.Build(tx =>
        {
            var edit = tx.Menu("Edit", items: new[]
            {
                tx.Item("Cut", role: MenuRole.Cut),
                tx.Item("Copy", role: MenuRole.Copy),
                tx.Item("Paste", role: MenuRole.Paste),
            });
            tx.Window(title: "richdoc", width: 560, height: 620, menus: new[] { edit });
            var last = tx.Signal("");
            var runs = tx.Signal(Spell(doc.Runs));
            var kdoc = tx.Signal("");

            tx.Mount(tx.Column(root =>
            {
                editor = tx.Textarea(rich: true, grow: 1);
                tx.SetA11yId(editor, "doc");
                tx.SetA11yLabel(editor, "Document");
                app.OnEdit(editor, (t, edit) =>
                {
                    string source = edit.Source is EditSource s ? s.Name() : "?";
                    t.Write(last,
                        $"edit {edit.Range.Start}:{edit.Range.Stop} <{edit.Inserted.Replace("\n", "\\n")}> {source} "
                            + $"[{Spell(edit.Runs)}]");
                    t.Write(runs, Spell(app.Document(editor).Runs));
                });
                app.OnFormat(editor, (t, act) =>
                {
                    t.Write(last,
                        $"format {act.Range.Start}:{act.Range.Stop} {act.Name}={act.Value ?? "off"}");
                    t.Write(runs, Spell(app.Document(editor).Runs));
                });

                tx.Label(bind: last); // label#0
                tx.Label(bind: runs); // label#1
                tx.Label(bind: kdoc); // label#2

                tx.Row(_ =>
                {
                    tx.Button("numbered", onClick: t => t.SetList(editor, ListKind.Numbered)); // button#0
                    tx.Button("indent", onClick: t => t.Indent(editor)); // button#1
                    tx.Button("red", onClick: t => t.Color(editor, "#DD1F24")); // button#2
                    tx.Button("colour", onClick: t => t.PickTextColor(editor)); // button#3
                    tx.Button("kdoc", onClick: t => // button#4
                    {
                        Document now = app.Document(editor);
                        byte[] bytes = now.ToKdoc();
                        Kdoc back = Document.FromKdoc(bytes);
                        bool same = back.Document.Equals(now);
                        t.SetDocument(editor, back.Document);
                        t.Write(kdoc,
                            $"kdoc {bytes.Length} bytes, read_only {back.ReadOnly ?? "none"}, "
                                + $"same {(same ? "true" : "false")}");
                        t.Write(runs, Spell(back.Document.Runs));
                    });
                });
                return root;
            }));
            tx.SetDocument(editor, doc);
        });

        Environment.Exit(app.Run());
    }
}
