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

        Console.WriteLine("csharp abort check: OK");
    }
}
