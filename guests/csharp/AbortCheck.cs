// The uniform-abort guard: a handler abort rolls the model mirror
// back, ships nothing, and the app continues — the same observable
// semantics as every other binding (the negative test each language
// carries). Runs headless: the library loads (KAYA_LIB) and records
// submit, but Run() is never entered — the Python checks'
// arrangement. The bindings compile into this assembly (the csproj
// globs bindings/csharp), so the internal mirrors (SignalMirrors,
// SignalDeps) are in reach; Dispatch is private, so the boundary test
// covers the rollback and the dispatch wrapper stays compile-visible
// only.
//
// It has since become the place for every C# surface fact a SCENE
// cannot see — the menu constructors' record emission, and now the undo
// group's head-of-batch rule and the mirror fold an undone/redone
// payload drives. A scene asserts what the user sees; a marker in the
// wrong place or a payload folded into the wrong mirror can still leave
// one platform's scene passing.

using System;
using System.Collections.Generic;

static class AbortCheck
{
    sealed class CheckException : Exception
    {
        public CheckException() : base("handler bug") { }
    }

    static void Check(bool ok, string message)
    {
        if (!ok)
            throw new InvalidOperationException("abort check: " + message);
    }

    static List<object> EntryKeys(Tx tx, Collection c)
    {
        var keys = new List<object>();
        foreach (var entry in tx.Items(c))
            keys.Add(entry.Key);
        return keys;
    }

    static bool KeysEqual(List<object> got, params object[] want)
    {
        if (got.Count != want.Length)
            return false;
        for (int i = 0; i < want.Length; i++)
            if (!Equals(got[i], want[i]))
                return false;
        return true;
    }

    // Record-frame helpers for the menu emission section: each frame
    // is u32 length then u16 kind at offset 4, little-endian.
    static ushort RecKind(byte[] rec) => (ushort)(rec[4] | (rec[5] << 8));

    static int CountKind(List<byte[]> records, int from, ushort kind)
    {
        int n = 0;
        for (int i = from; i < records.Count; i++)
            if (RecKind(records[i]) == kind)
                n++;
        return n;
    }

    static bool ContainsAscii(byte[] rec, string needle)
    {
        for (int at = 0; at + needle.Length <= rec.Length; at++)
        {
            int i = 0;
            while (i < needle.Length && rec[at + i] == (byte)needle[i])
                i++;
            if (i == needle.Length)
                return true;
        }
        return false;
    }

    public static void Run()
    {
        var app = new KayaApp();
        Collection todos = default;
        Signal counter = default;
        app.Build(tx =>
        {
            todos = tx.Collection();
            tx.Insert(todos, "a", "one");
            tx.Insert(todos, "b", "two");
            counter = tx.Signal("x");
        });
        app.Build(tx => Check(
            KeysEqual(EntryKeys(tx, todos), "a", "b"), "commit did not reach the mirror"));

        // Abort mid-transaction after mutating: the boundary must
        // restore the mirrors and rethrow (rollback + propagate is the
        // tx boundary's contract; surviving is the dispatch loop's).
        bool propagated = false;
        try
        {
            app.Build(tx =>
            {
                tx.Insert(todos, "c", "three");
                tx.Remove(todos, "a");
                tx.Write(counter, "y");
                counter.Derive(v => v);
                throw new CheckException();
            });
        }
        catch (CheckException)
        {
            propagated = true;
        }
        Check(propagated, "Build swallowed the exception — the tx boundary must propagate");
        app.Build(tx => Check(
            KeysEqual(EntryKeys(tx, todos), "a", "b"), "abort did not restore the mirror"));
        Check(Equals(app.SignalMirrors[counter.Id], "x"),
            "abort did not restore the signal mirror");

        // An aborted transaction abandons its derived-signal
        // registrations with its records: the pending list promotes
        // only on commit.
        Check(!app.SignalDeps.TryGetValue(counter.Id, out var deps) || deps.Count == 0,
            "aborted tx leaked derived-signal registrations");

        // A post-abort commit works and sees the restored model.
        app.Build(tx => tx.Insert(todos, "c", "three"));
        app.Build(tx => Check(
            KeysEqual(EntryKeys(tx, todos), "a", "b", "c"), "post-abort commit broken"));

        // The record-time mirror-read guard: while a template body is
        // being declared (a For body, a When body), the model mirror is
        // off-limits — the template records once and replays, so a read
        // baked into it is silently dead data. Live-zone and build
        // reads stay legal, pinned below.
        app.Build(tx =>
        {
            tx.ForEach(todos, t =>
            {
                bool threw = false;
                try { tx.Items(todos); }
                catch (InvalidOperationException e) { threw = e.Message.Contains("template body"); }
                Check(threw, "Items inside a For body did not throw");
                threw = false;
                try { tx.Count(todos); }
                catch (InvalidOperationException e) { threw = e.Message.Contains("template body"); }
                Check(threw, "Count inside a For body did not throw");
            });
            // The When arm: OpenFors tracks Fors only — When pushes
            // nothing there — so this pins the counter's When arm.
            var visible = tx.Signal(true);
            tx.When(visible, t =>
            {
                bool threw = false;
                try { tx.Items(todos); }
                catch (InvalidOperationException e) { threw = e.Message.Contains("template body"); }
                Check(threw, "Items inside a When body did not throw");
            });
            // After the scope closes, the same transaction reads again.
            Check(KeysEqual(EntryKeys(tx, todos), "a", "b", "c"),
                "read after the template scope closed broken");
        });
        // A later build-tx read stays legal — explicit, even though the
        // reads above already exercised it: the guard is template-scope
        // only, never build-wide.
        app.Build(tx => Check(
            KeysEqual(EntryKeys(tx, todos), "a", "b", "c"), "build-tx read after the guard broken"));

        // The menu construction surface must REACH the record stream —
        // the wire-dropped-write class: a constructor that emits
        // nothing passes every surface gate until a scene fails live
        // (the dropped-spacing lesson; Python's kaya_app_checks.py is
        // the pattern). The bindings compile into this assembly, so
        // the open transaction's Records list is in reach.
        MenuItem file = default;
        app.Build(tx =>
        {
            int before = tx.Records.Count;
            var save = tx.Item("Save", shortcut: "PRIMARY+S");
            file = tx.Menu("File", items: new[] { save });
            var sort = tx.RadioGroup(
                "Sort", new[] { tx.Option("Name"), tx.Option("Date") }, value: 1);
            tx.Window(menus: new[] { file, sort });
            var noun = tx.Label("noun");
            tx.ContextMenu(noun, tx.Item("Rename"));
            // Save, File, Name, Date, Sort, Rename.
            Check(CountKind(tx.Records, before, KayaWire.TxKindMenuItemCreate) == 6,
                "menu constructors queued the wrong create count");
            Check(CountKind(tx.Records, before, KayaWire.TxKindMenubarAppend) == 2,
                "bar anchors queued the wrong menubar-append count");
            Check(CountKind(tx.Records, before, KayaWire.TxKindMenuItemAppend) == 3,
                "children queued the wrong item-append count");
            Check(CountKind(tx.Records, before, KayaWire.TxKindContextAttach) == 1,
                "context anchor queued the wrong attach count");
            bool canonical = false;
            for (int i = before; i < tx.Records.Count; i++)
                if (RecKind(tx.Records[i]) == KayaWire.TxKindSetMenuProp
                    && ContainsAscii(tx.Records[i], "primary+s"))
                    canonical = true;
            Check(canonical, "shortcut did not reach the records canonicalized");

            // The binding's one shortcut parser rejects aliases at
            // record time — no call site can bypass it.
            bool threw = false;
            try { tx.Item("Bad", shortcut: "ctrl+s"); }
            catch (ArgumentException) { threw = true; }
            Check(threw, "an alias shortcut must die in the binding's one parser");
        });

        // Append-at-any-time: the retained handle reopens in a later
        // transaction — one create plus one append under the RETAINED
        // parent, and never a new bar anchor.
        app.Build(tx =>
        {
            int before = tx.Records.Count;
            tx.Menu(file, items: new[] { tx.Item("Publish") });
            Check(CountKind(tx.Records, before, KayaWire.TxKindMenuItemCreate) == 1,
                "reopen queued the wrong create count");
            byte[] append = null;
            for (int i = before; i < tx.Records.Count; i++)
                if (RecKind(tx.Records[i]) == KayaWire.TxKindMenuItemAppend)
                    append = tx.Records[i];
            Check(append != null, "reopen queued no append");
            Check(BitConverter.ToUInt64(append, 8) == file.Id,
                "reopen did not seat under the retained parent");
            Check(CountKind(tx.Records, before, KayaWire.TxKindMenubarAppend) == 0,
                "reopen re-anchored the bar");
        });

        // THE UNDO SURFACE (docs/undo-plan.md D2, D5). Three facts no
        // scene can see, for the same reason the menu section above
        // exists: the scene asserts what the USER sees, and a group
        // marker in the wrong place or a payload folded into the wrong
        // mirror can still produce a passing scene on one platform.
        app.Build(tx =>
        {
            int before = tx.Records.Count;
            var s = tx.Signal("a");
            tx.Write(s, "b");
            // NAMED AFTER THE WORK, which is how a handler is written —
            // it builds first and knows what the step was afterwards —
            // and the marker must still LEAD the batch, because the wire
            // reads it head-of-batch.
            tx.Undoable("step");
            Check(RecKind(tx.Records[before]) == KayaWire.TxKindUndoGroup,
                "Undoable did not put the group marker at the head of the batch");
            Check(CountKind(tx.Records, before, KayaWire.TxKindUndoGroup) == 1,
                "Undoable queued the wrong undo_group count");
            bool threw = false;
            try { tx.Undoable("again"); }
            catch (InvalidOperationException) { threw = true; }
            Check(threw, "a second Undoable must refuse — one name per step");
        });

        // The fold an undone/redone payload drives, on the mirror side:
        // the core already moved, so a mirror that does not follow makes
        // every read-back stale. This is the ONE direction the wire
        // travels wire-fields-to-object, so it is the one the record
        // type's schema is used in reverse.
        RecordCollection<Todo> notes = default;
        app.Build(tx =>
        {
            notes = tx.CollectionOf<Todo>();
            notes.Insert(tx, "a", new Todo("milk", false));
            notes.Insert(tx, "b", new Todo("tea", false));
        });
        var undone = new UndoDelta();
        // "a" is gone (an undone insert), "b" is restored with the
        // fields the core states, and a third entry the mirror never had
        // comes back from nothing (an undone remove).
        undone.Entries.Add(new UndoEntry
        {
            Collection = notes.Collection.Id,
            Key = "a",
            State = null,
        });
        undone.Entries.Add(new UndoEntry
        {
            Collection = notes.Collection.Id,
            Key = "b",
            State = (0u, new List<object> { "tea", true }),
        });
        undone.Entries.Add(new UndoEntry
        {
            Collection = notes.Collection.Id,
            Key = "c",
            State = (0u, new List<object> { "cocoa", false }),
        });
        undone.Orders.Add(new UndoOrder
        {
            Collection = notes.Collection.Id,
            Keys = new List<object> { "c", "b" },
        });
        undone.Signals.Add(new UndoSignal(counter.Id, "restored"));
        app.AbsorbUndo(undone);
        app.Build(tx =>
        {
            var items = notes.Items(tx);
            Check(!items.Exists(e => Equals(e.Key, "a")),
                "the undo fold did not drop the entry the payload says is gone");
            Check(items.Exists(e => Equals(e.Key, "c")),
                "the undo fold did not add the entry the payload says is back");
            Check(items.Count == 2, "the undo fold left the wrong entry count");
            Check(Equals(items[0].Key, "c") && Equals(items[1].Key, "b"),
                "the undo fold did not reorder by the payload's key order");
            Check(items[1].Value == new Todo("tea", true),
                "the undo fold did not rebuild the record from the wire fields");
            Check(items[0].Value == new Todo("cocoa", false),
                "the undo fold did not restore an entry the mirror had dropped");
        });
        Check(Equals(app.SignalMirrors[counter.Id], "restored"),
            "the undo fold did not follow the signal mirror");

        // An aborted append drops its menu records with everything
        // else (records die with the tx; nothing ships) and the app
        // continues.
        propagated = false;
        try
        {
            app.Build(tx =>
            {
                tx.Menu(file, items: new[] { tx.Item("Doomed") });
                throw new CheckException();
            });
        }
        catch (CheckException)
        {
            propagated = true;
        }
        Check(propagated, "menu abort: Build must propagate");
        app.Build(tx => tx.Menu(file, items: new[] { tx.Item("Recovered") }));

        Console.WriteLine("csharp abort check: OK");
    }
}
