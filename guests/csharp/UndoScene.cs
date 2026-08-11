// The undo scene from C#: two tiers, one Edit menu, and one ledger that
// orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).
//
// WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP. tx.Undoable(...)
// names a transaction, and that name is the step: the core keeps the
// inverse of what the batch did to signals and collections, and hands it
// back through the window's onUndone. There is no undo stack in this
// file, no command objects, and no re-run of any handler — an undo is a
// programmatic write of the state that was there before, which is why it
// emits nothing and why the occurrence carries the whole delta.
//
// THE FIELD'S OWN TYPING UNDO IS THE PLATFORM'S, and this app writes
// nothing for it at all. Both tiers arrive through the same Edit>Undo
// item, and which one answers is kaya's routing question, not the app's
// (D6).
//
// THE SCENARIO THAT MOTIVATED THE MILESTONE is the add button, which is
// the entry scene's add: it appends a todo AND empties the field. Two
// transactions, deliberately — the undoable group is the insert and the
// status it wrote, and the clear that finishes the form is not part of
// the step. Under two unordered stacks one Cmd+Z takes back the CLEAR:
// "milk" returns to the field, the todo stays, and the user is looking
// at a state that never existed (docs/undo-plan.md §2). Here it takes
// back the ADD.
//
// It is also the design saying the same thing twice: Clear inside a
// group is REFUSED at apply, because it destroys widget-owned text the
// core never held (D4). Undo restores state, and state is signals plus
// collections. In C# a handler IS a transaction, so the clear reaches
// its own one through App.Post — the binding's answer to "another
// transaction, after this one".
//
// AND THE APP NAMES NO TODO. A todo is a title and nothing else — it
// has no identity of its own — so the key comes from InsertFresh, which
// mints one per collection instance and hands it back
// (docs/fresh-key-plan.md). What that buys here is the whole point of
// the minter: this file used to carry nextKey, a counter beside the
// collection whose safety rested on never rewinding, and an undo that
// rewound it would have handed the same name to two todos.
//
// Canonical semantics in guests/rust/undo.rs; the byte-frozen contract
// in tools/scenes/undo.steps.
//
//     KAYA_SELFTEST=undo KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

using System.Collections.Generic;

static class UndoScene
{
    /// What the history label says a step was. A typing episode has no
    /// authored name and kaya invents none ("Undo Typing" is an Apple
    /// convention, not a scene string — docs/undo-plan.md D8), so the
    /// empty label is the app's to spell.
    static string What(string label) => label.Length == 0 ? "typing" : label;

    /// The app's collection mirror, rendered: every key it holds, in the
    /// order it holds them.
    ///
    /// THIS IS THE ONLY PART OF AN UNDO A COUNT CANNOT SEE. A restored
    /// entry that came back under a fresh name, or at the end instead of
    /// where it was, leaves every total in this file correct — the
    /// entries and orders runs of the delta are what say otherwise, and
    /// this is where the scene reads them (D5).
    static string KeyList(Tx tx, RecordCollection<Todo> todos)
    {
        var keys = new List<string>();
        foreach (var entry in todos.Items(tx))
            // The minter's keys are I64, and the unboxing cast is what
            // says so: a key of any other type is a bug, and this names
            // it instead of printing it.
            keys.Add(((long)entry.Key).ToString());
        return keys.Count == 0 ? "no keys" : $"keys {string.Join(",", keys)}";
    }

    /// The row a stamped copy's occurrence names: the copy's key path,
    /// which for a top-level For is one key — the todo's own, minted by
    /// InsertFresh and unboxed exactly as KeyList unboxes the
    /// collection's keys, so a key of any other type names itself here
    /// instead of being printed.
    static long RowKey(List<object> path) => (long)path[0];

    /// The app's copy of what is typed in the ROWS, rendered: every note
    /// it holds, by key, ascending.
    ///
    /// THE ROWS' FIELDS ARE UNCONTROLLED LIKE THE DRAFT, so this map is
    /// the app's own and nothing reads it back off a widget. It is also
    /// where this scene proves the payload's new shape: an undone note
    /// arrives naming (template node, key path), and an app with two rows
    /// can only put it back in the right one because the path says which.
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

        // The fold: widget-owned state arrives as occurrences; the app's
        // copy is these variables, not a widget read. Two of them,
        // because there are two kinds of text field on screen — the
        // draft, and one per row — and the payload's path is what tells
        // them apart.
        string draft = "";
        var rowNotes = new SortedDictionary<long, string>();

        // One texts run, folded into those two mirrors. The empty path is
        // the draft; a path names a row.
        //
        // AN EMPTY NOTE IS NO NOTE, which is what makes the undo
        // falsifiable: the restore of a row's field to "" has to REMOVE
        // the key, so an app that ignored this run reads its stale note
        // back out and the script says so.
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
            // THE GESTURE LAYER, one tier deeper: an app declares the two
            // items and writes nothing else. They act on the focused
            // widget, lower to the platform's own command where it has
            // one, and work out their own enablement from what is focused
            // and what the ledger holds.
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

            // Per window, and PERSISTENT: a history is walked as often as
            // the user likes. The binding has already reconciled its
            // collection mirror from this payload before the handler
            // runs, which is why Count below answers about the restored
            // state.
            //
            // THE DELTA IS THE ONLY NOTIFICATION for the restored text:
            // restoring an episode is a programmatic write, and a
            // programmatic write never echoes, so an app that folds text
            // changes into its own model — which is every app, the field
            // being uncontrolled — would go stale on exactly this step if
            // the payload did not carry it (D5).
            //
            // THE RUN IS WALKED WHOLE, not reduced to its last string,
            // because an entry NAMES the field it restores: the empty
            // path is the draft, and a path names the row whose note came
            // back.
            tx.Window(title: "undo", menus: new[] { edit },
                onUndone: (t, label, delta) =>
                {
                    FoldTexts(delta.Texts);
                    t.Write(history,
                        $"undid {What(label)}, {t.Count(todos.Collection)} total");
                    // ONE TRANSACTION WITH THE LABEL ABOVE, deliberately:
                    // the script reads that label first, so by the time it
                    // reads this one the app's own answer is what is on
                    // screen — not the value the core restored on its way
                    // past. The notes ride the same transaction for the
                    // same reason.
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
                        // NOT A STEP, so it names no group and the
                        // forward history survives it. It is also the one
                        // place this app READS ITS OWN DRAFT out loud,
                        // which is how the script proves the restored
                        // text of an undone typing episode reached it at
                        // all.
                        t.Write(status, $"nothing to add, {t.Count(todos.Collection)} total");
                        return;
                    }
                    // ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The
                    // name is what the step is called; everything in this
                    // transaction is what it did.
                    t.Undoable($"add {draft}");
                    // NO KEY, AND NO COUNTER TO GET WRONG: the binding
                    // mints the name and hands it back. This app has no
                    // use for it — a todo is looked up by nothing — and
                    // an app that does (selecting the new row, say) takes
                    // it from here rather than inventing a second name
                    // for the same datum.
                    todos.InsertFresh(t, new Todo(draft, false));
                    t.Write(status, $"added {draft}, {t.Count(todos.Collection)} total");
                    t.Write(keys, KeyList(t, todos));
                    // A PURE EFFECT rides along and is simply not
                    // restored: undo restores state, not where you were
                    // looking (A2).
                    t.Focus(field);
                    // FINISHING THE FORM IS NOT PART OF THE STEP. Its own
                    // transaction, so undoing the add does not put the
                    // draft back beside a todo that is gone — and Clear
                    // inside a group would be refused anyway. The field
                    // empties on screen and reports its change through
                    // the normal edit path, so the fold above empties the
                    // draft.
                    app.Post(after => after.Clear(field));
                });
                // A group at its smallest: one signal write, which is the
                // undoable set's whole vocabulary on the reactive side.
                tx.Button("star", onClick: t =>                    // button#1
                {
                    t.Undoable("star");
                    t.Write(status, "starred");
                });
                // THE SCENE'S WAY BACK TO THE FIELD. `star` does not move
                // the cursor on its own — an app that reaches for focus
                // after every action is deciding where the user is
                // looking — so the scene says so itself, and the routing
                // question ("what is focused?") stays visible in the
                // script rather than hidden in a handler.
                tx.Button("focus", onClick: t => t.Focus(field));  // button#2
                // THE STEP WHOSE INVERSE IS AN IDENTITY, not a content.
                // The core captured the entry and the instance's order
                // before the removal, so undoing this puts the entry back
                // under the key it already had, where it already was —
                // neither of which this app has to remember.
                tx.Button("remove", onClick: t =>                  // button#3
                {
                    // The collection's FIRST entry, taken from the app's
                    // own model and never from a widget, so the entry
                    // that comes back has to come back BEFORE the one
                    // that stayed.
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
                // THE ROW'S OWN FIELD, and the reason this scene grew: a
                // copy's text edits are the same occurrence a live
                // field's are, one identity deeper, and the ledger banks
                // them the same way now that the payload can name them.
                //
                // The tracing tier, as todos.cs and reorder.cs spell it.
                // This scene used to open the For by hand and reach for
                // t.Widget(KayaWire.KindEntry) instead, because the
                // template zone had no entry to call and the generated
                // row surface keeps its Tpl private — so the floor, the
                // C guests' tier, was the only way a row could hold a
                // text field. Both halves of that are gone.
                //
                // Entry() TAKES NOTHING, and that is the constructor
                // rather than a shortcoming: an entry is uncontrolled,
                // so the stamped copy owns its text and there is nothing
                // to seed it from. Entry(row.Title) is the overload that
                // seeds one, and this row wants a blank note beside the
                // title, not a second copy of it.
                foreach (var row in todos.Rows())
                {
                    row.Row(() =>
                    {
                        row.Label(row.Title);
                        var note = row.Entry();
                        // The row's edit, folded exactly as the payload's
                        // restore of the same field will be — one rule,
                        // two arrival paths, so the script's assertion
                        // cannot pass through a second spelling of "what
                        // a note is". The handler already holds a
                        // transaction and names no group, so this write
                        // is not a step of its own.
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
            // THE SCENE TYPES WITH REAL KEYSTROKES, so something has to
            // be holding focus when it does — and focus is the routing
            // question's other half.
            tx.Focus(field);
            tx.Mount(root);
        });

        System.Environment.Exit(app.Run());
    }
}
