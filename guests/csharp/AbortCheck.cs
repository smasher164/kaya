// The uniform-abort guard, plus every C# surface fact a SCENE cannot
// see (menu record emission, the undo group's head-of-batch rule, the
// mirror fold an undone/redone payload drives, the nested table's three
// spellings and the generated row façade's two routes to them). Run by
// tools/check-abort.sh.
//
// Runs headless: the library loads (KAYA_LIB) and records submit, but
// Run() is never entered. The bindings compile into this assembly, so
// the internal mirrors are in reach.

using System;
using System.Collections.Generic;
using System.Threading;

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

    // A set_column_headers record, field by field: u32 length, u16 kind,
    // u16 pad, then u64 target, u32 sorted, u32 direction, u32 count,
    // u32 path_len, then the Values run (u32 count, u32 reserved, then
    // {u32 tag, u32 len, bytes} each).
    static ulong HeaderTarget(byte[] rec) => BitConverter.ToUInt64(rec, 8);

    static uint HeaderCount(byte[] rec) => BitConverter.ToUInt32(rec, 24);

    static uint HeaderPathLen(byte[] rec) => BitConverter.ToUInt32(rec, 28);

    static uint HeaderValueCount(byte[] rec) => BitConverter.ToUInt32(rec, 32);

    static string HeaderFirstValue(byte[] rec) =>
        BitConverter.ToUInt32(rec, 40) == KayaWire.ValueStr
            ? System.Text.Encoding.UTF8.GetString(rec, 48, (int)BitConverter.ToUInt32(rec, 44))
            : null;

    static byte[] LastHeaderRecord(List<byte[]> records, int from)
    {
        byte[] found = null;
        for (int i = from; i < records.Count; i++)
            if (RecKind(records[i]) == KayaWire.TxKindSetColumnHeaders)
                found = records[i];
        return found;
    }

    // A set_property record: u64 widget, u32 prop, u32 source, and for an
    // ELEMENT source u32 level then u32 field — the exact-index token a
    // typed row surface writes, which a literal caption never carries.
    static List<uint> BoundFields(List<byte[]> records, int from, int to)
    {
        var fields = new List<uint>();
        for (int i = from; i < to; i++)
        {
            byte[] rec = records[i];
            if (RecKind(rec) == KayaWire.TxKindSetProperty
                && BitConverter.ToUInt32(rec, 20) == KayaWire.SourceElement)
                fields.Add(BitConverter.ToUInt32(rec, 28));
        }
        return fields;
    }

    // The record window one template occupies: everything between the
    // create_for that opens `node` and its own template_end, nested Fors
    // and Whens counted so an inner end never closes the outer one. WHICH
    // ZONE A CELL RECORDED INTO is not visible any other way — the record
    // reads the same wherever it was queued.
    static (int Open, int Close) TemplateWindow(List<byte[]> records, int from, ulong node)
    {
        int open = -1;
        for (int i = from; i < records.Count && open < 0; i++)
            if (RecKind(records[i]) == KayaWire.TxKindCreateFor
                && BitConverter.ToUInt64(records[i], 8) == node)
                open = i;
        if (open < 0)
            return (-1, -1);
        int depth = 0;
        for (int i = open + 1; i < records.Count; i++)
        {
            ushort kind = RecKind(records[i]);
            if (kind == KayaWire.TxKindCreateFor || kind == KayaWire.TxKindCreateWhen)
                depth++;
            else if (kind == KayaWire.TxKindTemplateEnd && depth-- == 0)
                return (open + 1, i);
        }
        return (open + 1, records.Count);
    }

    // THE NESTED TABLE, which no C# scene reaches: the dashboard shape
    // is "for every account, a positions table", so the header bar is
    // declared on a template NODE and each stamped copy sorts on its own
    // (docs/tables-plan.md, dynamic tables). Rust pins the same two
    // records in crates/kaya/src/app.rs's unit tests.
    static void NestedTable(KayaApp app)
    {
        string[] titles = { "Ticker", "Qty" };
        Node table = default;
        app.Build(tx =>
        {
            var accounts = tx.Collection();
            int before = tx.Records.Count;
            tx.Each(accounts, account =>
            {
                // The nested collection is declared INSIDE the template
                // scope — the core's own-scope wall.
                var holdings = account.Collection();
                table = account.Each(holdings, row => row.Row(() =>
                {
                    row.Label("ticker");
                    row.Label("qty");
                }));
                // After the For closes and still inside the parent's
                // template body, which is where the record finds it.
                account.Columns(table, titles, Sort.None);
            });
            var bar = LastHeaderRecord(tx.Records, before);
            Check(bar != null, "the template-zone Columns queued no set_column_headers");
            Check(HeaderTarget(bar) == table.Id,
                "the template bar must target the nested For's TEMPLATE NODE");
            Check(HeaderPathLen(bar) == 0 && HeaderCount(bar) == 2,
                "the template bar is path_len 0 with one value per column");
            Check(HeaderValueCount(bar) == 2 && HeaderFirstValue(bar) == "Ticker",
                "with no key path the values are the titles alone");
            // The handler scopes to the For that owns the bar, and a
            // copy answers for itself: keys in, keys back out.
            app.OnSort(table, (t, keys, column) =>
                t.Columns(table, keys, titles, Sort.Asc(column)));
        });

        // The per-copy re-declaration a sort request answers with: the
        // same template node, plus that copy's keys outermost first.
        app.Build(tx =>
        {
            int before = tx.Records.Count;
            tx.Columns(table, new List<object> { "brokerage" }, titles, Sort.Desc(1));
            var bar = LastHeaderRecord(tx.Records, before);
            Check(bar != null, "the keyed Columns queued no set_column_headers");
            Check(HeaderTarget(bar) == table.Id,
                "a keyed re-declaration still targets the template node");
            Check(HeaderPathLen(bar) == 1 && HeaderCount(bar) == 2,
                "path_len counts the copy's keys, count the columns");
            Check(HeaderValueCount(bar) == 3 && HeaderFirstValue(bar) == "brokerage",
                "the copy's KEYS come first, then the titles");
        });
    }

    // THE SAME TABLE THROUGH THE GENERATED ROW FAÇADE, which could not
    // name one at all before 2026-08-24: `<Rec>Row` had no Each/ForEach/
    // Collection and a private Tpl, and `<Rec>Kaya.Each` opened the LIVE
    // zone only (docs/deferred.md, the closed C# façade entry). Both
    // routes below are compile-time claims first — they do not build
    // without the forwards and the twin — and decode what they queue.
    static void FacadeNestedTable(KayaApp app)
    {
        string[] titles = { "Ticker", "Qty" };
        app.Build(tx =>
        {
            var accounts = TableItemKaya.Collection(tx);

            // ROUTE ONE: the outer body holds a TableItemRow, and every
            // call in it is one of the façade's new forwards.
            int before = tx.Records.Count;
            Node table = default;
            TableItemKaya.Each(tx, accounts, account =>
            {
                var holdings = account.Collection();
                table = account.Each(holdings, row => row.Row(() =>
                {
                    row.Label("ticker");
                    row.Label("qty");
                }));
                account.Columns(table, titles, Sort.None);
            });
            var bar = LastHeaderRecord(tx.Records, before);
            Check(bar != null, "the façade's Columns queued no set_column_headers");
            Check(HeaderTarget(bar) == table.Id,
                "the façade's bar must target the Node its own Each handed back");
            Check(HeaderPathLen(bar) == 0 && HeaderCount(bar) == 2,
                "the façade's bar is path_len 0 with one value per column");
            Check(HeaderValueCount(bar) == 2 && HeaderFirstValue(bar) == "Ticker",
                "with no key path the values are the titles alone");

            // ROUTE TWO: the Tpl twin. The NESTED For's body holds the
            // row façade too, so its cells are `row.Label(row.Name)` —
            // the exact-index tokens — and not the raw zone's literals.
            before = tx.Records.Count;
            Node typed = default;
            tx.Each(accounts.Collection, account =>
            {
                var holdings = TableItemKaya.Collection(tx);
                typed = TableItemKaya.Each(account, holdings, row => row.Row(() =>
                {
                    row.Label(row.Name);
                    row.Label(row.Size);
                }));
                account.Columns(typed, titles, Sort.None);
            });
            var twin = LastHeaderRecord(tx.Records, before);
            Check(twin != null, "the twin's nested For queued no set_column_headers");
            Check(HeaderTarget(twin) == typed.Id,
                "the twin hands back the nested For's TEMPLATE NODE, which the bar names");
            var (open, close) = TemplateWindow(tx.Records, before, typed.Id);
            Check(open > 0, "the twin queued no create_for for the nested collection");
            var bound = BoundFields(tx.Records, open, close);
            Check(bound.Count == 2 && bound[0] == 0 && bound[1] == 1,
                "the twin's cells bind the row's own tokens, in wire-index order, "
                    + "INSIDE the nested template");
        });
    }

    // OPEN IS NOT ENOUGH: a transaction is the app thread's. `closed`
    // cannot see a Task continuation writing through a transaction that
    // is still open, nor a background Build opening one of its own —
    // both race the app thread's model, silently (docs/deferred.md).
    // The refusal's Go twin is bindings/go/app_test.go's
    // TestATransactionRefusesAnotherGoroutine.
    static void WrongThread(KayaApp app)
    {
        // DispatchLoop makes this claim in production; the check is
        // headless, so it claims its own thread here.
        KayaApp.ClaimAppThread();
        Signal probe = default;
        app.Build(tx => probe = tx.Signal("before"));

        string Elsewhere(Action body)
        {
            string message = null;
            var t = new Thread(() =>
            {
                try
                {
                    body();
                }
                catch (Exception e)
                {
                    message = e.Message;
                }
            });
            t.Start();
            t.Join();
            return message ?? "";
        }

        // A live transaction, written from a thread the handler spawned:
        // still OPEN, so only the thread rule can refuse it.
        string live = "";
        app.Build(tx => live = Elsewhere(() => tx.Write(probe, "from elsewhere")));
        Check(live.Contains("belongs to the app thread"),
            "a write through an OPEN transaction from another thread was answered "
                + "with \"" + live + "\" — it must name the thread rule");
        Check(live.Contains("App.Post"),
            "the wrong-thread refusal must name the way out: \"" + live + "\"");

        // And a background Build, which reaches no chokepoint at all
        // when its body writes nothing.
        string empty = Elsewhere(() => app.Build(tx => { }));
        Check(empty.Contains("belongs to the app thread"),
            "Build from another thread was answered with \"" + empty + "\" — an "
                + "empty body writes no record, so only Build's own check sees it");

        // The way out the message names actually works, and the app
        // thread still builds.
        bool ran = false;
        Elsewhere(() => app.Post(tx => { ran = true; tx.Write(probe, "after"); }));
        app.DrainPosted();
        Check(ran, "Post from another thread did not reach the app thread");
        app.Build(tx => tx.Write(probe, "after all"));
    }

    public static void Run()
    {
        var app = new KayaApp();

        // ONE ID SPACE: a template node draws from the WIDGET counter, so
        // an app hands out one number sequence and the core's two "already
        // exists" walls can never fire on an id this binding minted
        // (DESIGN.md, Binding conventions). The CONTIGUOUS RUN is the
        // assertion, not inequality — a private node counter restarted at 1
        // sits under the live ids an app has already spent and passes a !=
        // while being exactly the defect. First thing this check does, so
        // the run starts at 1.
        ulong live = 0, site = 0, node = 0, after = 0;
        app.Build(tx =>
        {
            live = tx.Label("live").Id;
            var rows = tx.Collection();
            // The For's own container is a live widget; the node is inside.
            site = tx.Each(rows, t => node = t.Label("row").Id).Id;
            after = tx.Label("live").Id;
        });
        Check(live == 1 && site == 2 && node == 3 && after == 4,
            $"widget/node ids {live},{site},{node},{after} — want 1,2,3,4 from one counter");

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

        NestedTable(app);

        FacadeNestedTable(app);

        WrongThread(app);

        Console.WriteLine("csharp abort check: OK");
    }
}
