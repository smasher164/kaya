// The uniform-abort guard, plus every C# surface fact a SCENE cannot
// see (menu record emission, the undo group's head-of-batch rule, the
// mirror fold an undone/redone payload drives). Run by
// tools/check-abort.sh.
//
// Runs headless: the library loads (KAYA_LIB) and records submit, but
// Run() is never entered. The bindings compile into this assembly, so
// the internal mirrors are in reach.

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

    // A record frame is u32 length then u16 kind at offset 4, little-endian.
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

        // Abort mid-transaction after mutating: rollback, then rethrow.
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

        Check(!app.SignalDeps.TryGetValue(counter.Id, out var deps) || deps.Count == 0,
            "aborted tx leaked derived-signal registrations");

        app.Build(tx => tx.Insert(todos, "c", "three"));
        app.Build(tx => Check(
            KeysEqual(EntryKeys(tx, todos), "a", "b", "c"), "post-abort commit broken"));

        // The record-time mirror-read guard (DESIGN.md, "record-time
        // mirror-read guard"): no model read inside a template body.
        app.Build(tx =>
        {
            tx.Each(todos, t =>
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
            // Pinned separately because OpenFors tracks Fors only — a
            // When pushes nothing there.
            var visible = tx.Signal(true);
            tx.When(visible, t =>
            {
                bool threw = false;
                try { tx.Items(todos); }
                catch (InvalidOperationException e) { threw = e.Message.Contains("template body"); }
                Check(threw, "Items inside a When body did not throw");
            });
            Check(KeysEqual(EntryKeys(tx, todos), "a", "b", "c"),
                "read after the template scope closed broken");
        });
        // Redundant on purpose: the guard is template-scope only, never
        // build-wide.
        app.Build(tx => Check(
            KeysEqual(EntryKeys(tx, todos), "a", "b", "c"), "build-tx read after the guard broken"));

        // The menu constructors must REACH the record stream: one that
        // emits nothing passes every surface gate until a scene fails
        // live.
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

            bool threw = false;
            try { tx.Item("Bad", shortcut: "ctrl+s"); }
            catch (ArgumentException) { threw = true; }
            Check(threw, "an alias shortcut must die in the binding's one parser");
        });

        // Append-at-any-time: a retained handle reopens in a later
        // transaction, under the same parent and with no new bar anchor.
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

        // The undo surface (docs/undo-plan.md D2, D5).
        app.Build(tx =>
        {
            int before = tx.Records.Count;
            var s = tx.Signal("a");
            tx.Write(s, "b");
            // Called after the work it names, but the marker must still
            // LEAD the batch: the wire reads it head-of-batch.
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

        // The mirror fold an undone/redone payload drives — the one
        // direction the wire travels fields-to-object.
        RecordCollection<Todo> notes = default;
        app.Build(tx =>
        {
            notes = tx.CollectionOf<Todo>();
            notes.Insert(tx, "a", new Todo("milk", false));
            notes.Insert(tx, "b", new Todo("tea", false));
        });
        var undone = new UndoDelta();
        // "a" gone (an undone insert), "b" restored with the core's
        // fields, "c" back from nothing (an undone remove).
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

        // An aborted append drops its menu records with everything else.
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
