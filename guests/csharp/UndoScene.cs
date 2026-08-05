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

    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default, history = default, keys = default;
        Widget field = default;
        RecordCollection<Todo> todos = null;

        // The fold: widget-owned state arrives as occurrences; the app's
        // copy is this variable, not a widget read.
        string draft = "";

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
            tx.Window(title: "undo", menus: new[] { edit },
                onUndone: (t, label, delta) =>
                {
                    if (delta.Texts.Count > 0)
                        draft = delta.Texts[^1].Text;
                    t.Write(history,
                        $"undid {What(label)}, {t.Count(todos.Collection)} total");
                    // ONE TRANSACTION WITH THE LABEL ABOVE, deliberately:
                    // the script reads that label first, so by the time it
                    // reads this one the app's own answer is what is on
                    // screen — not the value the core restored on its way
                    // past.
                    t.Write(keys, KeyList(t, todos));
                },
                onRedone: (t, label, delta) =>
                {
                    if (delta.Texts.Count > 0)
                        draft = delta.Texts[^1].Text;
                    t.Write(history,
                        $"redid {What(label)}, {t.Count(todos.Collection)} total");
                    t.Write(keys, KeyList(t, todos));
                });

            var root = tx.Column(() =>
            {
                tx.SetA11yId(tx.Label(bind: status), "status");    // label#0
                tx.SetA11yId(tx.Label(bind: history), "history");  // label#1
                tx.SetA11yId(tx.Label(bind: keys), "keys");        // label#2
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
                foreach (var row in todos.Rows())
                    row.Row(() => row.Label(row.Title));
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
