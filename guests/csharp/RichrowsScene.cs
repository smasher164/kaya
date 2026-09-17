// The rich rows scene, C# port — guests/rust/richrows.rs,
// tools/scenes/richrows.steps: a rich textarea per stamped ROW whose
// document is a FIELD of the row (docs/rich-text-plan.md §19). The app
// writes a copy's document by patching its row, and a copy's own act
// folds into the row the app reads back.

using System;
using System.Collections.Generic;

// Its own namespace: one binary hosts every scene and feed owns the
// bare Note.
namespace Richrows;

[KayaGen]
record Note(string Title, Document Body);

static class RichrowsScene
{
    /// The core's spelling of runs (`expect_runs`), so the row's field
    /// and the core's mirror are compared as one string.
    static string Spell(IReadOnlyList<TextRun> runs)
    {
        var parts = new List<string>();
        foreach (TextRun run in runs)
            parts.Add(run.IsFlag
                ? $"{run.Range.Start}:{run.Range.Stop} {run.Name}"
                : $"{run.Range.Start}:{run.Range.Stop} {run.Name}={run.Value}");
        return string.Join("|", parts);
    }

    static string KeyText(object key) => key is string s ? s : $"{key}";

    static Note Row(Tx tx, RecordCollection<Note> notes, object key) =>
        notes.TryGet(tx, key, out var note)
            ? note
            : throw new InvalidOperationException($"richrows: no row {key}");

    public static void Run()
    {
        var app = new KayaApp();

        var (last, view, notes) = app.Build(tx =>
        {
            var edit = tx.Menu("Edit", items: new[]
            {
                tx.Item("Undo", role: MenuRole.Undo),
                tx.Item("Redo", role: MenuRole.Redo),
            });
            var notes = NoteKaya.Collection(tx);
            var last = tx.Signal("");
            var view = tx.Signal("");
            // An undo or redo moved the row back: the app reads ITS OWN
            // mirror of row b, which is the fold a restored Blob field
            // lands in.
            void Restored(Tx t, string label, UndoDelta delta)
            {
                Note note = Row(t, notes, "b");
                t.Write(view, $"{note.Body.Text} | {Spell(note.Body.Runs)}");
            }
            tx.Window(title: "richrows", menus: new[] { edit },
                onUndone: Restored, onRedone: Restored);

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: last); // label#0
                tx.Label(bind: view); // label#1

                tx.Row(_ =>
                {
                    tx.Button("patch b", onClick: t => // button#0
                    {
                        t.Undoable("patch b");
                        NoteKaya.Patch(t, notes, "b").Body(
                            new Document("Patched")
                                .Mark(TextRange.Bytes(0, 7), "italic", true));
                    });
                    tx.Button("read a", onClick: t => // button#1
                    {
                        Note note = Row(t, notes, "a");
                        t.Write(view, $"{note.Body.Text} | {Spell(note.Body.Runs)}");
                    });
                });

                foreach (var row in notes.Rows())
                {
                    row.Column(() =>
                    {
                        row.Label(row.Title);
                        Node body = row.Textarea(row.Body);
                        row.SetA11yId(body, "body");
                        // The row's field already carries the copy's act
                        // when these fire: the app reads the row, never
                        // the widget.
                        app.OnEdit(body, (t, keys, _) => Acted(t, notes, last, keys));
                        app.OnFormat(body, (t, keys, _) => Acted(t, notes, last, keys));
                    });
                }
                return root;
            }));

            notes.Insert(tx, "a", new Note("a",
                new Document("Héllo world").Mark(TextRange.Bytes(0, 6), "bold", true)));
            notes.Insert(tx, "b", new Note("b",
                new Document("Second note").Mark(
                    TextRange.Bytes(7, 11), "link", "https://kaya.dev")));
            return (last, view, notes);
        });

        Environment.Exit(app.Run());
    }

    static void Acted(Tx tx, RecordCollection<Note> notes, Signal last, List<object> keys)
    {
        Note note = Row(tx, notes, keys[0]);
        tx.Write(last, $"{KeyText(keys[0])}: {Spell(note.Body.Runs)}");
    }
}
