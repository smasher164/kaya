// The undo scene from C#: two tiers, one Edit menu, and one ledger that
// orders them. Reasoning in docs/undo-plan.md; canonical semantics in
// guests/rust/undo.rs; frozen script in tools/scenes/undo.steps.
//
//     KAYA_SELFTEST=undo KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

using System.Collections.Generic;

static class UndoScene
{
    /// kaya names no typing episode, so the empty label is the app's to
    /// spell (docs/undo-plan.md D8).
    static string What(string label) => label.Length == 0 ? "typing" : label;

    static string KeyList(Tx tx, RecordCollection<Todo> todos)
    {
        var keys = new List<string>();
        foreach (var entry in todos.Items(tx))
            keys.Add(((long)entry.Key).ToString());
        return keys.Count == 0 ? "no keys" : $"keys {string.Join(",", keys)}";
    }

    /// The key path of a stamped copy's occurrence: one key for a
    /// top-level For, minted by InsertFresh.
    static long RowKey(List<object> path) => (long)path[0];

    static string NoteList(SortedDictionary<long, string> notes)
    {
        if (notes.Count == 0)
            return "no notes";
        var rendered = new List<string>();
        foreach (var note in notes)
            rendered.Add($"{note.Key}={note.Value}");
        return $"notes {string.Join(",", rendered)}";
    }

    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default, history = default, keys = default, notes = default;
        Widget field = default;
        RecordCollection<Todo> todos = null;

        string draft = "";
        var rowNotes = new SortedDictionary<long, string>();

        // One texts run, folded into both mirrors: the empty path is the
        // draft, a path names a row, and an empty note is no note.
        void FoldTexts(List<UndoText> texts)
        {
            foreach (var text in texts)
            {
                if (text.Path.Count == 0)
                    draft = text.Text;
                else if (text.Text.Length == 0)
                    rowNotes.Remove(RowKey(text.Path));
                else
                    rowNotes[RowKey(text.Path)] = text.Text;
            }
        }

        app.Build(tx =>
        {
            var edit = tx.Menu("Edit", items: new[]
            {
                tx.Item("Undo", role: Tx.RoleUndo),
                tx.Item("Redo", role: Tx.RoleRedo),
            });
            status = tx.Signal("no todos");
            history = tx.Signal("history empty");
            keys = tx.Signal("no keys");
            notes = tx.Signal("no notes");
            todos = TodoKaya.Collection(tx);

            tx.Window(title: "undo", menus: new[] { edit },
                onUndone: (t, label, delta) =>
                {
                    FoldTexts(delta.Texts);
                    t.Write(history,
                        $"undid {What(label)}, {t.Count(todos.Collection)} total");
                    // history, keys and notes ride ONE transaction: the
                    // script reads them in that order and must never see a
                    // half-updated screen.
                    t.Write(keys, KeyList(t, todos));
                    t.Write(notes, NoteList(rowNotes));
                },
                onRedone: (t, label, delta) =>
                {
                    FoldTexts(delta.Texts);
                    t.Write(history,
                        $"redid {What(label)}, {t.Count(todos.Collection)} total");
                    t.Write(keys, KeyList(t, todos));
                    t.Write(notes, NoteList(rowNotes));
                });

            var root = tx.Column(() =>
            {
                tx.SetA11yId(tx.Label(bind: status), "status");    // label#0
                tx.SetA11yId(tx.Label(bind: history), "history");  // label#1
                tx.SetA11yId(tx.Label(bind: keys), "keys");        // label#2
                tx.SetA11yId(tx.Label(bind: notes), "notes");      // label#3
                field = tx.Entry((t, text) => draft = text);       // entry#0
                tx.SetA11yId(field, "draft");
                tx.Button("add", onClick: t =>                     // button#0
                {
                    if (draft.Length == 0)
                    {
                        t.Write(status, $"nothing to add, {t.Count(todos.Collection)} total");
                        return;
                    }
                    t.Undoable($"add {draft}");
                    todos.InsertFresh(t, new Todo(draft, false));
                    t.Write(status, $"added {draft}, {t.Count(todos.Collection)} total");
                    t.Write(keys, KeyList(t, todos));
                    t.Focus(field);
                    // Clearing the field is not part of the step, and Clear
                    // inside an undoable group is refused at apply
                    // (docs/undo-plan.md D4) — so it gets its own
                    // transaction.
                    app.Post(after => after.Clear(field));
                });
                tx.Button("star", onClick: t =>                    // button#1
                {
                    t.Undoable("star");
                    t.Write(status, "starred");
                });
                tx.Button("focus", onClick: t => t.Focus(field));  // button#2
                tx.Button("remove", onClick: t =>                  // button#3
                {
                    var items = todos.Items(t);
                    if (items.Count == 0)
                    {
                        t.Write(status,
                            $"nothing to remove, {t.Count(todos.Collection)} total");
                        return;
                    }
                    var first = items[0];
                    t.Undoable($"remove {first.Value.Title}");
                    t.Remove(todos.Collection, first.Key);
                    t.Write(status,
                        $"removed {first.Value.Title}, {t.Count(todos.Collection)} total");
                    t.Write(keys, KeyList(t, todos));
                });
                foreach (var row in todos.Rows())
                {
                    row.Row(() =>
                    {
                        row.Label(row.Title);
                        var note = row.Entry();
                        // Folded exactly as the undo payload's restore of
                        // the same field is: one rule, two arrival paths.
                        app.OnChange(note, (t2, path, text) =>
                        {
                            long key = RowKey(path);
                            if (text.Length == 0)
                                rowNotes.Remove(key);
                            else
                                rowNotes[key] = text;
                            t2.Write(notes, NoteList(rowNotes));
                        });
                    });
                }
            });
            // The script types with real keystrokes, so something has to
            // be holding focus when it does.
            tx.Focus(field);
            tx.Mount(root);
        });

        System.Environment.Exit(app.Run());
    }
}
