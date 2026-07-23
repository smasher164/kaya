// kaya's idiomatic surface for C#: the structural core.
//
// Three jobs, layered over the runtime (Kaya.cs) and the generated wire
// vocabulary (KayaWire.cs):
//
//   - id allocation: signals, widgets, collections, and template nodes
//     come from per-space counters behind distinct types, so no app
//     hand-numbers the id spaces — and the compiler keeps blueprint
//     nodes (Node) from being used where live widgets (Widget) belong;
//   - template scoping: ForEach and When take an Action<Tpl> whose body
//     declares the blueprint, bracketing the records;
//   - occurrence dispatch: handlers register per button; the app loop
//     routes each click, handing template-node handlers the stamped
//     copy's key path. Handlers receive their transaction explicitly
//     (Action<Tx>); it submits when the handler returns. The core never
//     calls into the guest — dispatch runs on the app thread after it
//     pulls from the ring.

using System;
using System.Collections.Generic;
using System.Threading;

readonly struct Signal
{
    /// Mint a derived signal: recomputed when the source is written,
    /// the write batched into the same transaction; the core sees an
    /// ordinary signal. Reaches the open transaction ambiently — the
    /// operators below are static, and a Signal is only an id.
    public Signal Derive(Func<object, object> compute)
    {
        var app = KayaApp.Ambient;
        var tx = app?.CurrentTx ?? throw new InvalidOperationException(
            "kaya: a derived signal is minted inside a transaction (build or handler)");
        var source = this;
        var d = tx.Signal(compute(app.SignalMirrors[source.Id]));
        tx.RegisterSignalDep(source.Id, t =>
        {
            object v = compute(app.SignalMirrors[source.Id]);
            if (!Equals(v, app.SignalMirrors[d.Id]))
                t.Write(d, v);
        });
        return d;
    }

    /// The derive vocabulary (the cross-language canon: eq, ne, lt,
    /// fmt, …); the comparison operators below are these methods in
    /// operator clothes.
    public Signal Eq(object other) => Derive(v => ValuesEqual(v, other));

    public Signal Ne(object other) => Derive(v => !ValuesEqual(v, other));

    public Signal Lt(object other) => Derive(v => CompareValues(v, other) < 0);

    public Signal Gt(object other) => Derive(v => CompareValues(v, other) > 0);

    public Signal Le(object other) => Derive(v => CompareValues(v, other) <= 0);

    public Signal Ge(object other) => Derive(v => CompareValues(v, other) >= 0);

    public Signal Fmt(string template) => Derive(v => string.Format(template, v));

    // Wire scalars compare across numeric representations: a guest
    // that wrote an int and compares to a long must not get a silent
    // false.
    static bool IsNumber(object v) =>
        v is sbyte or byte or short or ushort or int or uint or long or ulong
            or float or double or decimal;

    static bool ValuesEqual(object a, object b) =>
        IsNumber(a) && IsNumber(b)
            ? Convert.ToDouble(a) == Convert.ToDouble(b)
            : Equals(a, b);

    static int CompareValues(object a, object b) =>
        IsNumber(a) && IsNumber(b)
            ? Convert.ToDouble(a).CompareTo(Convert.ToDouble(b))
            : Comparer<object>.Default.Compare(a, b);

    // The documented sharp edge (the SQLAlchemy/pandas trade-off):
    // == no longer answers identity, so `signal == null` mints a
    // derived — reference checks use `is null`, which bypasses user
    // operators.
    public static Signal operator ==(Signal s, object v) => s.Eq(v);

    public static Signal operator !=(Signal s, object v) => s.Ne(v);

    public static Signal operator <(Signal s, object v) => s.Lt(v);

    public static Signal operator >(Signal s, object v) => s.Gt(v);

    public static Signal operator <=(Signal s, object v) => s.Le(v);

    public static Signal operator >=(Signal s, object v) => s.Ge(v);

    public override bool Equals(object obj) => obj is Signal other && Id == other.Id;

    public override int GetHashCode() => Id.GetHashCode();

    internal readonly ulong Id;

    internal Signal(ulong id) => Id = id;
}

/// A live widget: exactly one thing on screen.
readonly struct Widget
{
    internal readonly ulong Id;

    internal Widget(ulong id) => Id = id;
}

/// A template node: a blueprint entry, stamped per collection entry.
/// Never on screen by itself; clicks on its copies arrive with the
/// copy's key path.
readonly struct Node
{
    internal readonly ulong Id;

    internal Node(ulong id) => Id = id;
}

/// A collection instance handle: the collection plus the key path
/// selecting one stamped copy's table. Tx.Collection() returns the
/// root (empty-path, live-zone) handle; At steps into a copy, one key
/// per enclosing For. Mutations and reads take the handle, so the
/// target is spelled once.
readonly struct Collection
{
    internal readonly ulong Id;
    internal readonly object[] Path;

    internal Collection(ulong id, object[] path)
    {
        Id = id;
        Path = path;
    }

    /// The instance of this collection inside the copy keyed by
    /// `key` of the next enclosing For; chain for deeper nesting.
    public Collection At(object key)
    {
        var path = new object[Path.Length + 1];
        Path.CopyTo(path, 0);
        path[Path.Length] = key;
        return new Collection(Id, path);
    }

    /// A For binds the collection itself — its template stamps per
    /// entry of every instance — so handing it an At(...) handle is a
    /// bug. (A default-constructed handle has a null Path; both are
    /// rejected here.)
    internal void AssertRoot()
    {
        if (Path == null || Path.Length > 0)
            throw new InvalidOperationException(
                "kaya: ForEach binds the collection itself, not an instance — drop the At(...)");
    }
}

/// One instance of a collection: the table inside the stamped copy
/// selected by Path (the empty path for a live-zone collection).
/// Entries keep insertion order, matching the core's rendering.
/// A container's cross-axis child placement (the align spec enum;
/// wire values pinned by the generated KayaWire constants). Baseline
/// is rows-only — the scene rejects it on columns at the root.
enum Align : long
{
    Start = 0,
    Center = 1,
    End = 2,
    Stretch = 3,
    Baseline = 4,
}

sealed class KayaInstance
{
    internal readonly List<object> Path;
    internal List<KeyValuePair<object, object>> Entries = new();

    internal KayaInstance(IEnumerable<object> path) => Path = new List<object>(path);

    internal KayaInstance Clone() =>
        new(Path) { Entries = new List<KeyValuePair<object, object>>(Entries) };
}

sealed class KayaApp
{
    // Signals recomputed from a collection after each of its
    // mutations, written into the same transaction.
    internal readonly Dictionary<ulong, List<Action<Tx>>> Derived = new();

    ulong signals, widgets, collections, nodes;
    readonly Dictionary<ulong, Action<Tx>> widgetHandlers = new();
    readonly Dictionary<ulong, Action<Tx, List<object>>> nodeHandlers = new();
    readonly Dictionary<ulong, Action<Tx, string>> widgetChanges = new();
    readonly Dictionary<ulong, Action<Tx, List<object>, string>> nodeChanges = new();
    readonly Dictionary<ulong, Action<Tx, bool>> widgetToggles = new();
    readonly Dictionary<ulong, Action<Tx, double>> widgetValues = new();
    readonly Dictionary<ulong, Action<Tx, List<object>, bool>> nodeToggles = new();
    // Window lifecycle: one handler each, receiving the window id.
    internal readonly Dictionary<ulong, Action<Tx>> closeRequested = new();
    internal readonly Dictionary<ulong, Action<Tx>> entryPopped = new();
    internal readonly Dictionary<ulong, Action<Tx>> backRequested = new();
    internal readonly Dictionary<ulong, Action<Tx>> sectionSelected = new();
    internal readonly Dictionary<ulong, Action<Tx>> windowClosed = new();
    internal readonly Dictionary<ulong, Action<Tx, uint>> alerts = new();
    internal ulong nextAlert;

    // The collection is the model — the only copy: every mutation op
    // edits it and queues the wire delta in the same call, so reads
    // (Items, Count) are exactly the writes. Children records the
    // declared-inside-a-For edges the model purges along when a parent
    // entry's copy is torn down.
    internal readonly Dictionary<ulong, List<KayaInstance>> Model = new();
    // Signal mirrors and dependents, for binding-maintained derived
    // signals; the ambient app/tx pair exists because the comparison
    // operators are static and a Signal is only an id (one app per
    // guest process, the Python binding's own assumption).
    internal static KayaApp Ambient;
    internal Tx CurrentTx;
    internal readonly Dictionary<ulong, object> SignalMirrors = new();
    internal readonly Dictionary<ulong, List<Action<Tx>>> SignalDeps = new();
    // The ambient parent stack: containers push their id around their
    // body, constructors parent to the top, and 0 is the template-root
    // sentinel (template bodies root themselves; a cross-zone AddChild
    // is structurally impossible).
    internal readonly List<ulong> Parents = new();
    internal readonly Dictionary<ulong, List<ulong>> Children = new();
    internal readonly List<ulong> OpenFors = new();
    // >0 while a template body is being declared (a For body, a When
    // body, or an open row trace). OpenFors tracks Fors only — When
    // pushes nothing there — so template-scope detection needs its own
    // counter. The template records once and replays: a model read
    // inside its body would bake one snapshot into every stamp as
    // silently dead data, so mirror reads throw while this is armed;
    // live-zone, handler, and build reads stay legal.
    internal int TplDepth;

    public KayaApp()
    {
        Ambient = this;
        Kaya.Init();
    }

    internal Signal NextSignal() => new(++signals);

    internal Widget NextWidget() => new(++widgets);

    internal Node NextNode() => new(++nodes);

    internal Collection NextCollection() => new(++collections, Array.Empty<object>());

    /// A collection declared inside a For's template is torn down with
    /// its copies: record the edge so the model purges along it.
    internal void RegisterCollection(ulong id)
    {
        if (OpenFors.Count == 0)
            return;
        ulong parent = OpenFors[^1];
        if (!Children.TryGetValue(parent, out var kids))
            Children[parent] = kids = new List<ulong>();
        kids.Add(id);
    }

    internal static bool PathEq(IReadOnlyList<object> a, IReadOnlyList<object> b, int len)
    {
        if (a.Count < len || b.Count < len)
            return false;
        for (int i = 0; i < len; i++)
            if (!Equals(a[i], b[i]))
                return false;
        return true;
    }

    internal KayaInstance InstanceOf(ulong coll, IReadOnlyList<object> path)
    {
        if (!Model.TryGetValue(coll, out var instances))
            return null;
        foreach (var instance in instances)
            if (instance.Path.Count == path.Count && PathEq(instance.Path, path, path.Count))
                return instance;
        return null;
    }

    /// Run `build` with a fresh transaction and submit it atomically. A
    /// handler that throws abandons its records, and the model abandons
    /// the same writes before the exception continues.
    public void Build(Action<Tx> build)
    {
        var tx = new Tx(this);
        CurrentTx = tx;
        try
        {
            build(tx);
        }
        catch
        {
            tx.Rollback();
            throw;
        }
        finally
        {
            CurrentTx = null;
        }
        tx.SubmitIfAny();
    }

    /// Register a click handler for a live widget.
    public void OnClick(Widget w, Action<Tx> handler) => widgetHandlers[w.Id] = handler;

    /// Register a click handler for a template node; it also receives
    /// the stamped copy's keys, outermost first.
    public void OnClick(Node n, Action<Tx, List<object>> handler) => nodeHandlers[n.Id] = handler;

    /// Register a change handler for a live entry: the widget owns its
    /// text and reports each edit here; the app folds the text into its
    /// own state — there is no read-back, by doctrine.
    public void OnChange(Widget w, Action<Tx, string> handler) => widgetChanges[w.Id] = handler;

    /// Register a change handler for a template entry; it also receives
    /// the stamped copy's keys, outermost first.
    public void OnChange(Node n, Action<Tx, List<object>, string> handler) =>
        nodeChanges[n.Id] = handler;

    /// Register a toggle handler for a live checkbox: the box owns its
    /// checked bit and reports each flip here; the app folds it into
    /// its own state.
    public void OnToggle(Widget w, Action<Tx, bool> handler) => widgetToggles[w.Id] = handler;

    /// A live slider's change handler: the bar owns its position and
    /// reports each move with the new value — the entry's uncontrolled
    /// contract, with a double.
    public void OnValueChanged(Widget w, Action<Tx, double> handler) =>
        widgetValues[w.Id] = handler;

    /// Register a toggle handler for a template checkbox; it also
    /// receives the stamped copy's keys, outermost first.
    public void OnToggle(Node n, Action<Tx, List<object>, bool> handler) =>
        nodeToggles[n.Id] = handler;

    /// One handler dispatch: an exception crosses the Build boundary
    /// (which rolled the mirrors back and dropped the records), is
    /// logged, and the loop moves to the next occurrence — the uniform
    /// dispatch discipline across every binding. Fatal runtime errors
    /// (stack overflow, access violation) still die.
    void Dispatch(Action<Tx> fn)
    {
        try
        {
            Build(fn);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(
                $"kaya: handler threw (transaction rolled back): {e}");
        }
    }

    void DispatchLoop()
    {
        while (Kaya.NextOccurrence(
            out ushort kind, out ulong id, out List<object> keys, out object payload))
        {
            string text = payload as string;
            bool isChecked = payload is bool b && b;
            if (kind == KayaWire.OccKindButtonClicked && keys.Count == 0)
            {
                if (widgetHandlers.TryGetValue(id, out var fn))
                    Dispatch(fn);
            }
            else if (kind == KayaWire.OccKindButtonClicked)
            {
                if (nodeHandlers.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys));
            }
            else if (kind == KayaWire.OccKindTextChanged && keys.Count == 0)
            {
                if (widgetChanges.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, text));
            }
            else if (kind == KayaWire.OccKindTextChanged)
            {
                if (nodeChanges.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys, text));
            }
            else if (kind == KayaWire.OccKindToggled && keys.Count == 0)
            {
                if (widgetToggles.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, isChecked));
            }
            else if (kind == KayaWire.OccKindToggled)
            {
                if (nodeToggles.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys, isChecked));
            }
            else if (kind == KayaWire.OccKindValueChanged && keys.Count == 0)
            {
                if (widgetValues.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, payload is double d ? d : 0.0));
            }
            else if (kind == KayaWire.OccKindCloseRequested)
            {
                if (closeRequested.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx));
            }
            else if (kind == KayaWire.OccKindWindowClosed)
            {
                // One-shot: the window is gone; both registrations
                // retire with it.
                closeRequested.Remove(id);
                if (windowClosed.Remove(id, out var fn))
                    Dispatch(tx => fn(tx));
            }
            else if (kind == KayaWire.OccKindSectionSelected)
            {
                // NOT one-shot: sections never die, and the user can
                // return any number of times (id is the section; the
                // window rides as the payload). A programmatic
                // SelectSection never lands here (the echo doctrine).
                if (sectionSelected.TryGetValue(id, out var fn))
                    Dispatch(fn);
            }
            else if (kind == KayaWire.OccKindEntryPopped)
            {
                // One-shot: the entry is gone; both registrations
                // retire with it.
                backRequested.Remove(id);
                if (entryPopped.Remove(id, out var fn))
                    Dispatch(tx => fn(tx));
            }
            else if (kind == KayaWire.OccKindBackRequested)
            {
                if (backRequested.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx));
            }
            else if (kind == KayaWire.OccKindAlertResult)
            {
                // One-shot: the registration retires with the result;
                // payload is the parsed u32 choice.
                if (alerts.Remove(id, out var fn))
                    Dispatch(tx => fn(tx, payload is uint c ? c : 0));
            }
        }
    }



    /// Enter the core on the calling thread (must be the process main
    /// thread), dispatching occurrences on the app thread; returns the
    /// exit code.
    public int Run()
    {
        var appThread = new Thread(DispatchLoop);
        appThread.Start();
        int code = Kaya.Run();
        appThread.Join();
        return code;
    }
}

/// One transaction: everything queued inside Build (or a handler)
/// applies atomically when it returns.
sealed class Tx
{
    internal readonly KayaApp App;
    internal readonly List<byte[]> Records = new();

    // How to undo this transaction's model edits: a snapshot per
    // touched collection, taken on first touch.
    readonly Dictionary<ulong, List<KayaInstance>> journal = new();

    // Deriveds registered in this transaction: promoted to the app
    // registry on submit, abandoned with a rolled-back Tx (their
    // signals were never created).
    readonly List<(ulong Coll, Action<Tx> Recompute)> pendingDerived = new();

    // Signal-derived twins of the above, keyed by the source signal,
    // plus the mirror journal (what to restore on rollback; absent =
    // the mirror was created this transaction).
    readonly List<(ulong Source, Action<Tx> Recompute)> pendingSignalDeps = new();
    readonly Dictionary<ulong, (bool Existed, object Old)> signalJournal = new();

    internal Tx(KayaApp app) => App = app;

    internal void SubmitIfAny()
    {
        foreach (var (coll, recompute) in pendingDerived)
        {
            if (!App.Derived.TryGetValue(coll, out var list))
                App.Derived[coll] = list = new List<Action<Tx>>();
            list.Add(recompute);
        }
        pendingDerived.Clear();
        foreach (var (source, recompute) in pendingSignalDeps)
        {
            if (!App.SignalDeps.TryGetValue(source, out var list))
                App.SignalDeps[source] = list = new List<Action<Tx>>();
            list.Add(recompute);
        }
        pendingSignalDeps.Clear();
        if (Records.Count > 0)
            Kaya.Submit(Records.ToArray());
    }

    internal void Rollback()
    {
        // The template-scope counter is app state, not tx state: an
        // aborted build is abandoned but the app continues, and a
        // stuck counter would poison every later mirror read.
        App.TplDepth = 0;
        foreach (var (id, snapshot) in journal)
            App.Model[id] = snapshot;
        foreach (var (id, (existed, old)) in signalJournal)
        {
            if (existed)
                App.SignalMirrors[id] = old;
            else
                App.SignalMirrors.Remove(id);
        }
    }

    internal void RegisterSignalDep(ulong source, Action<Tx> recompute) =>
        pendingSignalDeps.Add((source, recompute));

    void TouchSignal(ulong id)
    {
        if (!signalJournal.ContainsKey(id))
            signalJournal[id] = App.SignalMirrors.TryGetValue(id, out var old)
                ? (true, old)
                : (false, null);
    }

    void Touch(ulong coll)
    {
        if (journal.ContainsKey(coll))
            return;
        var snapshot = new List<KayaInstance>();
        if (App.Model.TryGetValue(coll, out var instances))
            foreach (var instance in instances)
                snapshot.Add(instance.Clone());
        journal[coll] = snapshot;
    }

    void ModelSet(ulong coll, IReadOnlyList<object> path, object key, object value)
    {
        Touch(coll);
        var instance = App.InstanceOf(coll, path);
        if (instance == null)
        {
            instance = new KayaInstance(path);
            if (!App.Model.TryGetValue(coll, out var instances))
                App.Model[coll] = instances = new List<KayaInstance>();
            instances.Add(instance);
        }
        for (int i = 0; i < instance.Entries.Count; i++)
        {
            if (Equals(instance.Entries[i].Key, key))
            {
                instance.Entries[i] = new KeyValuePair<object, object>(key, value);
                return;
            }
        }
        instance.Entries.Add(new KeyValuePair<object, object>(key, value));
    }

    void ModelRemove(ulong coll, IReadOnlyList<object> path, object key)
    {
        Touch(coll);
        var instance = App.InstanceOf(coll, path);
        instance?.Entries.RemoveAll(e => Equals(e.Key, key));
        // The core tears down the copy, taking descendant collection
        // instances with it; the model follows.
        var prefix = new List<object>(path) { key };
        PurgeChildren(coll, prefix);
    }

    void ModelMove(ulong coll, IReadOnlyList<object> path, object key, object[] before)
    {
        Touch(coll);
        var instance = App.InstanceOf(coll, path);
        // The same checks the scene makes, made where the guest can
        // see the stack: a missing key or anchor is a guest bug, never
        // a fallback. Both validated before anything mutates.
        int pos = instance == null ? -1 : instance.Entries.FindIndex(e => Equals(e.Key, key));
        if (pos < 0)
            throw new InvalidOperationException($"kaya: move of missing key {key}");
        if (before.Length > 0 && !instance.Entries.Exists(e => Equals(e.Key, before[0])))
            throw new InvalidOperationException($"kaya: move before missing key {before[0]}");
        var entry = instance.Entries[pos];
        instance.Entries.RemoveAt(pos);
        int at = before.Length > 0
            ? instance.Entries.FindIndex(e => Equals(e.Key, before[0]))
            : instance.Entries.Count;
        instance.Entries.Insert(at, entry);
    }

    List<object> KeysOf(Collection c)
    {
        var keys = new List<object>();
        var instance = App.InstanceOf(c.Id, c.Path);
        if (instance != null)
            foreach (var entry in instance.Entries)
                keys.Add(entry.Key);
        return keys;
    }

    void PurgeChildren(ulong coll, IReadOnlyList<object> prefix)
    {
        if (!App.Children.TryGetValue(coll, out var kids))
            return;
        foreach (ulong kid in kids)
        {
            Touch(kid);
            if (App.Model.TryGetValue(kid, out var instances))
                instances.RemoveAll(i => KayaApp.PathEq(i.Path, prefix, prefix.Count));
            PurgeChildren(kid, prefix);
        }
    }

    public Signal Signal(object initial)
    {
        var s = App.NextSignal();
        Records.Add(KayaWire.TxCreateSignal(s.Id, initial));
        TouchSignal(s.Id);
        App.SignalMirrors[s.Id] = initial;
        return s;
    }

    public void Write(Signal s, object value)
    {
        TouchSignal(s.Id);
        Records.Add(KayaWire.TxWriteSignal(s.Id, value));
        App.SignalMirrors[s.Id] = value;
        // The dependents recompute now, batched into this transaction
        // (a derived write chains through here again for its own
        // dependents).
        if (App.SignalDeps.TryGetValue(s.Id, out var deps))
            foreach (var recompute in deps)
                recompute(this);
        foreach (var (source, recompute) in pendingSignalDeps)
            if (source == s.Id)
                recompute(this);
    }

    public Widget Widget(uint kind)
    {
        var w = App.NextWidget();
        Records.Add(KayaWire.TxCreateWidget(w.Id, kind));
        AutoParent(w.Id);
        return w;
    }

    // The current ambient parent (0 when the scope roots itself:
    // template bodies, or no open container).
    internal ulong CurrentParent() =>
        App.Parents.Count > 0 ? App.Parents[App.Parents.Count - 1] : 0;

    internal void AutoParent(ulong id)
    {
        ulong p = CurrentParent();
        if (p != 0)
            Records.Add(KayaWire.TxAddChild(p, id));
    }

    public void SetText(Widget w, string text) => Records.Add(KayaWire.TxSetText(w.Id, text));

    public void BindText(Widget w, Signal s) => Records.Add(KayaWire.TxBindText(w.Id, s.Id));

    public void SetChecked(Widget w, bool isChecked) =>
        Records.Add(KayaWire.TxSetChecked(w.Id, isChecked));

    /// Set a widget's flex weight within its row/column: 0 is natural
    /// size, positive weights divide the container's leftover main-axis
    /// space in proportion (see Prop::Grow in the core). The
    /// declarative spelling is the `grow:` argument at construction;
    /// this is the dynamic path.
    public void SetGrow(Widget w, double weight) =>
        Records.Add(KayaWire.TxSetGrow(w.Id, weight));

    /// A container's inter-child gap (main axis, DIP; the normalized
    /// default is 8). Containers only — the scene rejects it anywhere
    /// else. The declarative spelling is the `spacing:` argument at
    /// construction; this is the dynamic path.
    public void SetSpacing(Widget w, double gap) =>
        Records.Add(KayaWire.TxSetSpacing(w.Id, gap));

    /// A container's cross-axis child placement (the align spec enum;
    /// the normalized default is Align.Start). Containers only;
    /// baseline is rows-only — the scene rejects misuse at the root.
    /// The declarative spelling is the `align:` argument at
    /// construction; this is the dynamic path.
    public void SetAlign(Widget w, Align align) =>
        Records.Add(KayaWire.TxSetAlign(w.Id, (long)align));

    public void BindChecked(Widget w, Signal s) =>
        Records.Add(KayaWire.TxBindChecked(w.Id, s.Id));

    /// Point the widget at encoded image bytes: one registration copy
    /// into core-owned memory — the handle is consumed by the next
    /// submit from this guest, referenced or not, so the caller's
    /// array is free to drop the moment this returns.
    public void SetSource(Widget w, byte[] source) =>
        Records.Add(KayaWire.TxSetSource(w.Id, Kaya.RegisterBlob(source)));

    public void BindSource(Widget w, Signal s) =>
        Records.Add(KayaWire.TxBindSource(w.Id, s.Id));

    public void AddChild(Widget parent, Widget child) =>
        Records.Add(KayaWire.TxAddChild(parent.Id, child.Id));

    /// Drop the widget's owned content — a one-shot command: momentary
    /// verbs into widget-owned state, riding this transaction like any
    /// write, so the insert and the clear beside it commit together or
    /// not at all. Fire-and-forget: no state at rest, nothing to
    /// journal, and the widget answers through its normal occurrence
    /// path (a clear arrives back as a text change with empty text, so
    /// the app's draft fold empties itself — never a side assignment).
    public void Clear(Widget w) =>
        Records.Add(KayaWire.TxWidgetCommand(w.Id, KayaWire.CommandClear));

    /// Give the widget keyboard focus (the post-submit refocus every
    /// real form wants) — a one-shot command riding the transaction
    /// like Clear.
    public void Focus(Widget w) =>
        Records.Add(KayaWire.TxWidgetCommand(w.Id, KayaWire.CommandFocus));

    // --- Construction sugar: the tree reads as a tree ----------------
    //
    // Co-located constructors (props and handlers at the declaration
    // site) and params-array containers. Everything lowers eagerly to
    // the same records — children first, then the container, then the
    // AddChilds; never a scene value interpreted later.

    public Widget Button(string text = null, Action<Tx> onClick = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindButton);
        if (text != null) SetText(w, text);
        if (onClick != null) App.OnClick(w, onClick);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    public Widget Entry(Action<Tx, string> onChange = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindEntry);
        if (onChange != null) App.OnChange(w, onChange);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// A multi-line text editor: the entry's uncontrolled contract
    /// over the platform's real multi-line editor.
    public Widget Textarea(Action<Tx, string> onChange = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindTextarea);
        if (onChange != null) App.OnChange(w, onChange);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    public Widget Label(string text = null, Signal? bind = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindLabel);
        if (text != null) SetText(w, text);
        if (bind is Signal s) BindText(w, s);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// A progress bar: display-only, like Label and Image. value is
    /// the determinate fraction (0..=1); indeterminate: true switches
    /// to the platform's activity mode.
    public Widget Progress(double value = 0.0, bool? indeterminate = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindProgress);
        Records.Add(KayaWire.TxSetValue(w.Id, value));
        if (indeterminate is { } i) Records.Add(KayaWire.TxSetIndeterminate(w.Id, i));
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// A slider over min..max at value, with its change handler
    /// co-located.
    /// `bind` takes a float Signal for the position instead of a
    /// constant — the programmatic write path (Write fans out to the
    /// control; property writes never echo an occurrence, so a
    /// handler's own writes cannot loop back at it).
    public Widget Slider(double min = 0.0, double max = 1.0, double value = 0.0,
        Action<Tx, double> onChange = null, double? grow = null, Signal? bind = null)
    {
        var w = Widget(KayaWire.KindSlider);
        Records.Add(KayaWire.TxSetMin(w.Id, min));
        Records.Add(KayaWire.TxSetMax(w.Id, max));
        if (bind is Signal s) Records.Add(KayaWire.TxBindValue(w.Id, s.Id));
        else Records.Add(KayaWire.TxSetValue(w.Id, value));
        if (onChange != null) App.OnValueChanged(w, onChange);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// A dropdown select over fixed options — each option becomes a
    /// label child (labels only, scene-checked) — at selected, the
    /// initial 0-based index (domain-checked at the root against the
    /// option count), with its pick handler co-located: onSelect
    /// receives each USER pick's new 0-based index (programmatic
    /// writes never echo) — the slider's uncontrolled contract.
    public Widget Select(string[] options, int selected = 0,
        Action<Tx, int> onSelect = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindSelect);
        App.Parents.Add(w.Id);
        foreach (var option in options)
        {
            var o = Widget(KayaWire.KindLabel);
            SetText(o, option);
        }
        App.Parents.RemoveAt(App.Parents.Count - 1);
        Records.Add(KayaWire.TxSetValue(w.Id, selected));
        if (onSelect != null)
            App.OnValueChanged(w, (tx, v) => onSelect(tx, (int)v));
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// A radio group over fixed options — the choice contract
    /// (see Select) in its inline presentation: same option
    /// children, same 0-based selected index, same pick handler.
    public Widget Radio(string[] options, int selected = 0,
        Action<Tx, int> onSelect = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindRadio);
        App.Parents.Add(w.Id);
        foreach (var option in options)
        {
            var o = Widget(KayaWire.KindLabel);
            SetText(o, option);
        }
        App.Parents.RemoveAt(App.Parents.Count - 1);
        Records.Add(KayaWire.TxSetValue(w.Id, selected));
        if (onSelect != null)
            App.OnValueChanged(w, (tx, v) => onSelect(tx, (int)v));
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    public Widget Checkbox(string text = null, bool? isChecked = null,
        Action<Tx, bool> onToggle = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindCheckbox);
        if (text != null) SetText(w, text);
        if (isChecked is bool c) SetChecked(w, c);
        if (onToggle != null) App.OnToggle(w, onToggle);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// An image displaying encoded bytes (PNG, JPEG, ...): the toolkit
    /// decodes natively, and decode failure renders the placeholder,
    /// never a crash. `source` is the encoded bytes — one registration
    /// copy into core memory, consumed by the next submit, so the
    /// caller's array is free to drop the moment this returns; `bind`
    /// a Signal carrying the image bytes.
    public Widget Image(byte[] source = null, Signal? bind = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindImage);
        if (source != null) SetSource(w, source);
        if (bind is Signal s) BindSource(w, s);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// A container parents everything declared inside its body (the
    /// ambient stack). Statement position is the point: a foreach over
    /// a generated row trace stands between siblings.
    public Widget Column(
        Action body, double? grow = null, double? spacing = null, Align? align = null) =>
        ContainerOf(KayaWire.KindColumn, body, grow, spacing, align);

    public Widget Row(
        Action body, double? grow = null, double? spacing = null, Align? align = null) =>
        ContainerOf(KayaWire.KindRow, body, grow, spacing, align);

    /// A vertical scroll viewport over EXACTLY ONE child (declare it
    /// in the body; the scene rejects a second). Pass grow: so the
    /// enclosing track CONSTRAINS it — an unconstrained viewport hugs
    /// its content and nothing overflows.
    public Widget Scroll(Action body, double? grow = null) =>
        ContainerOf(KayaWire.KindScroll, body, grow, null, null);

    /// A grid laying its children out row-major into `columns`
    /// columns — each column takes its NATURAL width, aligned across
    /// rows (the thing nested rows cannot express); `spacing` is the
    /// inter-cell gap on both axes.
    public Widget Grid(int columns, Action body, double? spacing = null, double? grow = null)
    {
        var parent = Widget(KayaWire.KindGrid);
        Records.Add(KayaWire.TxSetColumns(parent.Id, columns));
        if (spacing is double gap) SetSpacing(parent, gap);
        if (grow is double g) SetGrow(parent, g);
        App.Parents.Add(parent.Id);
        body?.Invoke();
        App.Parents.RemoveAt(App.Parents.Count - 1);
        return parent;
    }

    /// A spacer: PURE SUGAR for an empty grown column — it consumes
    /// the leftover main-axis space between its siblings.
    public Widget Spacer()
    {
        var w = Widget(KayaWire.KindColumn);
        SetGrow(w, 1.0);
        return w;
    }

    Widget ContainerOf(
        uint kind, Action body, double? grow = null, double? spacing = null, Align? align = null)
    {
        var parent = Widget(kind);
        if (grow is double g) SetGrow(parent, g);
        if (spacing is double gap) SetSpacing(parent, gap);
        if (align is Align a) SetAlign(parent, a);
        App.Parents.Add(parent.Id);
        body?.Invoke();
        App.Parents.RemoveAt(App.Parents.Count - 1);
        return parent;
    }

    /// A For as a child: ForEach whose body keeps no handles — the
    /// common case once handlers co-locate at their constructors.
    public Widget Each(Collection c, Action<Tpl> body) => ForEach(c, body);

    public Collection Collection()
    {
        var c = App.NextCollection();
        App.RegisterCollection(c.Id);
        Records.Add(KayaWire.TxCreateCollection(c.Id, new[] { new uint[] { KayaWire.ValueStr } }));
        return c;
    }

    /// A For over `c`: the body declares the template; the For itself
    /// (a live container) is returned.
    public Widget ForEach(Collection c, Action<Tpl> body)
    {
        c.AssertRoot();
        var w = App.NextWidget();
        // The For parents into the enclosing scope, but the record
        // must land after template_end — an AddChild inside the
        // blueprint would cross zones.
        ulong parent = CurrentParent();
        Records.Add(KayaWire.TxCreateFor(w.Id, c.Id));
        App.OpenFors.Add(c.Id);
        App.Parents.Add(0);
        // try/finally: a throwing body abandons the tx but the app
        // survives, and a stuck counter would poison later reads.
        App.TplDepth++;
        try
        {
            body(new Tpl(this));
        }
        finally
        {
            App.TplDepth--;
        }
        App.Parents.RemoveAt(App.Parents.Count - 1);
        App.OpenFors.RemoveAt(App.OpenFors.Count - 1);
        Records.Add(KayaWire.TxTemplateEnd());
        if (parent != 0)
            Records.Add(KayaWire.TxAddChild(parent, w.Id));
        return w;
    }

    /// Open a For template for a generated row trace (`foreach (var
    /// row in todos.Rows())`): the enumerator runs the loop body once
    /// with the returned Tpl, then the close action ends the template
    /// and parents the For into the enclosing scope. The enumerator's
    /// Dispose calls close, so foreach makes the close structural —
    /// even on break.
    public (Tpl, Action) BeginRowTrace(Collection c)
    {
        c.AssertRoot();
        var w = App.NextWidget();
        ulong parent = CurrentParent();
        Records.Add(KayaWire.TxCreateFor(w.Id, c.Id));
        App.OpenFors.Add(c.Id);
        App.Parents.Add(0);
        // The counter drops in the close action: foreach's Dispose
        // calls it structurally, even on break or a throwing body.
        App.TplDepth++;
        return (new Tpl(this), () =>
        {
            App.TplDepth--;
            App.Parents.RemoveAt(App.Parents.Count - 1);
            App.OpenFors.RemoveAt(App.OpenFors.Count - 1);
            Records.Add(KayaWire.TxTemplateEnd());
            if (parent != 0)
                Records.Add(KayaWire.TxAddChild(parent, w.Id));
        });
    }

    /// A When over a Bool signal: stamps on true, unstamps on false.
    public Widget When(Signal s, Action<Tpl> body)
    {
        var w = App.NextWidget();
        ulong parent = CurrentParent();
        Records.Add(KayaWire.TxCreateWhen(w.Id, s.Id));
        App.Parents.Add(0);
        App.TplDepth++;
        try
        {
            body(new Tpl(this));
        }
        finally
        {
            App.TplDepth--;
        }
        App.Parents.RemoveAt(App.Parents.Count - 1);
        Records.Add(KayaWire.TxTemplateEnd());
        if (parent != 0)
            Records.Add(KayaWire.TxAddChild(parent, w.Id));
        return w;
    }

    public void Insert(Collection c, object key, object value)
    {
        ModelSet(c.Id, c.Path, key, value);
        Records.Add(KayaWire.TxCollectionInsert(c.Id, c.Path, key, 0, new[] { value }));
        RecomputeDerived(c);
    }

    public void Update(Collection c, object key, object value)
    {
        ModelSet(c.Id, c.Path, key, value);
        Records.Add(KayaWire.TxCollectionUpdate(c.Id, c.Path, key, 0, new[] { value }));
        RecomputeDerived(c);
    }

    public void Remove(Collection c, object key)
    {
        ModelRemove(c.Id, c.Path, key);
        Records.Add(KayaWire.TxCollectionRemove(c.Id, c.Path, key));
        RecomputeDerived(c);
    }

    /// MoveBefore repositions an entry before another's: order is
    /// collection data, so the model reorders and the wire carries the
    /// same keys-only delta. Keys, never indices. A missing key or
    /// anchor throws here, at the call site — the same check the scene
    /// makes; moving an entry before itself is a no-op, and nothing
    /// travels.
    public void MoveBefore(Collection c, object key, object anchor) =>
        MoveEntry(c, key, new[] { anchor });

    /// MoveToEnd repositions an entry at the end of its collection.
    public void MoveToEnd(Collection c, object key) =>
        MoveEntry(c, key, System.Array.Empty<object>());

    /// MoveToFront repositions an entry at the front: sugar for
    /// MoveBefore the current first key, lowering to the same wire op.
    public void MoveToFront(Collection c, object key)
    {
        var keys = KeysOf(c);
        if (keys.Count == 0)
            throw new InvalidOperationException($"kaya: move of missing key {key}");
        MoveEntry(c, key, new[] { keys[0] });
    }

    /// MoveAfter repositions an entry directly after another's: sugar
    /// for MoveBefore the anchor's successor (MoveToEnd when the
    /// anchor is last), lowering to the same wire op.
    public void MoveAfter(Collection c, object key, object anchor)
    {
        var keys = KeysOf(c);
        if (!keys.Exists(k => Equals(k, key)))
            throw new InvalidOperationException($"kaya: move of missing key {key}");
        int at = keys.FindIndex(k => Equals(k, anchor));
        if (at < 0)
            throw new InvalidOperationException($"kaya: move after missing key {anchor}");
        if (Equals(key, anchor))
            return;
        if (at + 1 == keys.Count)
        {
            MoveEntry(c, key, System.Array.Empty<object>());
            return;
        }
        if (Equals(keys[at + 1], key))
            return; // already directly after the anchor
        MoveEntry(c, key, new[] { keys[at + 1] });
    }

    void MoveEntry(Collection c, object key, object[] before)
    {
        if (before.Length > 0 && Equals(before[0], key))
        {
            // Moving before itself: order unchanged and nothing
            // travels — but the key must exist, the check the scene
            // would make.
            if (!KeysOf(c).Exists(k => Equals(k, key)))
                throw new InvalidOperationException($"kaya: move of missing key {key}");
            return;
        }
        ModelMove(c.Id, c.Path, key, before);
        Records.Add(KayaWire.TxCollectionMove(c.Id, c.Path, key, before));
        RecomputeDerived(c);
    }

    internal void RegisterDerived(ulong coll, Action<Tx> recompute) =>
        pendingDerived.Add((coll, recompute));

    // Every derived signal rooted at this collection, recomputed and
    // written into this transaction. Deriveds hang off root handles,
    // so nested-instance mutations cannot change their input.
    void RecomputeDerived(Collection c)
    {
        if (c.Path.Length != 0)
            return;
        if (App.Derived.TryGetValue(c.Id, out var list))
            foreach (var recompute in list)
                recompute(this);
        foreach (var (coll, recompute) in pendingDerived)
            if (coll == c.Id)
                recompute(this);
    }

    // The raw record paths KayaRecords builds on: the model keeps the
    // record object itself; only the wire fields travel.
    internal Collection CollectionWithSchema(uint[] schema)
    {
        return CollectionWithVariants(new[] { schema });
    }

    internal Collection CollectionWithVariants(uint[][] variants)
    {
        var c = App.NextCollection();
        App.RegisterCollection(c.Id);
        Records.Add(KayaWire.TxCreateCollection(c.Id, variants));
        return c;
    }

    internal void EmitVariantCase(uint variant) =>
        Records.Add(KayaWire.TxVariantCase(variant));

    internal void InsertRecordRaw(Collection c, object key, object model, uint variant, object[] fields)
    {
        ModelSet(c.Id, c.Path, key, model);
        Records.Add(KayaWire.TxCollectionInsert(c.Id, c.Path, key, variant, fields));
        RecomputeDerived(c);
    }

    internal void UpdateRecordRaw(Collection c, object key, object model, uint variant, object[] fields)
    {
        ModelSet(c.Id, c.Path, key, model);
        Records.Add(KayaWire.TxCollectionUpdate(c.Id, c.Path, key, variant, fields));
        RecomputeDerived(c);
    }

    internal void UpdateFieldRaw(Collection c, object key, object model, uint variant, uint field, object value)
    {
        ModelSet(c.Id, c.Path, key, model);
        Records.Add(KayaWire.TxCollectionUpdateField(c.Id, c.Path, key, field, variant, value));
        RecomputeDerived(c);
    }

    // The record-time mirror-read guard: the template records once
    // and replays, so a read inside a template body is one snapshot
    // baked into every stamp — silently dead data. The typed surfaces
    // (RecordCollection, SumCollection) route through Items, so this
    // is the single choke point.
    void GuardMirrorRead()
    {
        if (App.TplDepth > 0)
            throw new InvalidOperationException(
                "kaya: model read inside a template body — the template records once and "
                + "replays; bind a signal, use the element's field, or Derive() for "
                + "computed values");
    }

    /// The model: what this guest wrote, exactly — the fold of every
    /// patch so far (this transaction's included), in insertion order.
    public List<KeyValuePair<object, object>> Items(Collection c)
    {
        GuardMirrorRead();
        var instance = App.InstanceOf(c.Id, c.Path);
        return instance == null
            ? new List<KeyValuePair<object, object>>()
            : new List<KeyValuePair<object, object>>(instance.Entries);
    }

    public int Count(Collection c)
    {
        GuardMirrorRead();
        return App.InstanceOf(c.Id, c.Path)?.Entries.Count ?? 0;
    }

    /// Mount into the default window; per-window targets arrive with
    /// the window vocabulary.
    /// Set the primary surface's title (the title bar on the
    /// desktops, the switcher label on iOS, the task label on
    /// Android).
    public void WindowTitle(string title) =>
        Records.Add(KayaWire.TxSetWindowTitle(0, title));

    /// Request the primary surface's content size in DIP — ADVISORY
    /// on every platform: honored where the window manager permits,
    /// recorded only where the system owns geometry.
    public void WindowSize(double width, double height)
    {
        Records.Add(KayaWire.TxSetWindowWidth(0, width));
        Records.Add(KayaWire.TxSetWindowHeight(0, height));
    }

    /// Create an auxiliary window (capability-gated: phone hosts
    /// reject at the root). Materializes hidden; MountIn presents it.
    /// Named arguments are the C# spelling:
    /// tx.CreateWindow(1, title: "inspector", width: 480, height: 320, vetoClose: true).
    /// The handlers ride the declaration (per-window — handlers
    /// scope to the thing that creates them): onCloseRequested fires
    /// per chrome close while vetoClose is armed — nothing has
    /// closed; answer with tx.DestroyWindow to agree. onClosed fires
    /// when the non-veto auxiliary is chrome-closed (informational;
    /// DestroyWindow reconciles) and retires with it.
    public void CreateWindow(
        ulong id, string? title = null, double? width = null, double? height = null,
        bool? vetoClose = null, Action<Tx>? onCloseRequested = null,
        Action<Tx>? onClosed = null)
    {
        Records.Add(KayaWire.TxCreateWindow(id));
        if (title is { } t) Records.Add(KayaWire.TxSetWindowTitle(id, t));
        if (width is { } w) Records.Add(KayaWire.TxSetWindowWidth(id, w));
        if (height is { } h) Records.Add(KayaWire.TxSetWindowHeight(id, h));
        if (vetoClose is { } v) Records.Add(KayaWire.TxSetWindowVetoClose(id, v));
        if (onCloseRequested is { } r) App.closeRequested[id] = r;
        if (onClosed is { } c) App.windowClosed[id] = c;
    }

    /// Request a modal alert (the request/result grammar), named
    /// arguments as the C# spelling:
    /// tx.ShowAlert(title: "delete item?", message: "…",
    ///     action0: "Delete", action1: "Archive", cancel: "Keep",
    ///     onResult: (tx, choice) => { … }).
    /// The result handler rides the REQUEST (the widget-handler
    /// precedent) and retires with its one answer — choice is an
    /// action index (0 or 1) or KayaWire.AlertChoiceCancel, every
    /// platform-native dismissal. Ids are binding-allocated; the
    /// call returns the id for the floor-minded. Up to two actions
    /// (the platform floor); the cancel label is required (no
    /// binding invents a default). One alert may be live per
    /// process; show the next from the handler.
    public ulong ShowAlert(
        string title = "", string message = "",
        string? action0 = null, string? action1 = null,
        string? cancel = null, Action<Tx, uint>? onResult = null,
        ulong window = 0)
    {
        if (action1 != null && action0 == null)
            throw new ArgumentException(
                "kaya: action1 without action0 — actions fill in order");
        if (string.IsNullOrEmpty(cancel))
            throw new ArgumentException(
                "kaya: the cancel slot always exists and needs a name — pass cancel:");
        uint actions = action0 == null ? 0u : (action1 == null ? 1u : 2u);
        ulong id = ++App.nextAlert;
        if (onResult != null)
            App.alerts[id] = onResult;
        Records.Add(KayaWire.TxShowAlert(
            window, id, actions, title, message,
            action0 ?? "", action1 ?? "", cancel));
        return id;
    }

    /// Close and forget an auxiliary window — also the veto grammar's
    /// confirmation and the reconciliation after a chrome close.
    public void DestroyWindow(ulong id) => Records.Add(KayaWire.TxDestroyWindow(id));

    /// Push a navigation entry onto the primary surface's stack
    /// (entry ids are guest-allocated in the shared surface
    /// namespace, the CreateWindow discipline). Materializes covered;
    /// MountIn presents it. Named arguments are the C# spelling:
    /// tx.PushEntry(7, title: "detail", interceptBack: true).
    /// The handlers ride the push (per-entry, the ShowAlert onResult
    /// precedent — no id inspection anywhere): onPopped fires when
    /// the user's back affordance pops THIS entry natively
    /// (post-fact; a programmatic PopEntry does not fire it — its
    /// caller already knows) and retires with the one pop;
    /// onBackRequested fires per back request while interceptBack is
    /// armed — nothing has popped; answer with tx.PopEntry to agree.
    public void PushEntry(
        ulong id, string? title = null, bool? interceptBack = null,
        Action<Tx>? onPopped = null, Action<Tx>? onBackRequested = null,
        ulong window = 0)
    {
        Records.Add(KayaWire.TxPushEntry(window, id));
        if (title is { } t) Records.Add(KayaWire.TxSetEntryTitle(id, t));
        if (interceptBack is { } i) Records.Add(KayaWire.TxSetEntryInterceptBack(id, i));
        if (onPopped is { } p) App.entryPopped[id] = p;
        if (onBackRequested is { } b) App.backRequested[id] = b;
    }

    /// Pop the window's top navigation entry and forget its tree —
    /// also the back-veto grammar's confirmation after
    /// OnBackRequested. Popping an empty stack is a scene error.
    public void PopEntry(ulong window = 0) => Records.Add(KayaWire.TxPopEntry(window));

    /// Append a section to the window's section set (section ids are
    /// guest-allocated in the shared surface namespace); the set is
    /// append-only — sections have no destruction grammar, and every
    /// section's root is retained while covered (switching is
    /// SELECTION, not lifecycle). MountIn fills its pane. Named
    /// arguments are the C# spelling:
    /// tx.AddSection(7, title: "Feed", onSelected: tx => …).
    /// onSelected rides the add (per-section): fires each time the
    /// USER switches to it — post-fact and NOT one-shot; a
    /// programmatic SelectSection does not fire it (the echo
    /// doctrine).
    public void AddSection(
        ulong id, string? title = null, Action<Tx>? onSelected = null,
        ulong window = 0)
    {
        Records.Add(KayaWire.TxAddSection(window, id));
        if (title is { } t) Records.Add(KayaWire.TxSetSectionTitle(id, t));
        if (onSelected is { } fn) App.sectionSelected[id] = fn;
    }

    /// Select a section programmatically: configuration, never echoes
    /// onSelected (the echo doctrine).
    public void SelectSection(ulong id, ulong window = 0) =>
        Records.Add(KayaWire.TxSelectSection(window, id));

    /// The window's ADVISORY presentation hint
    /// (KayaWire.SectionsPresentationAuto/Bar/Sidebar — the
    /// width/height precedent; the phones ignore it by physics).
    public void SectionsPresentation(long hint, ulong window = 0) =>
        Records.Add(KayaWire.TxSetWindowSectionsPresentation(window, hint));

    /// Mount a root into a specific window; mounting presents an
    /// auxiliary.
    public void MountIn(ulong window, Widget root) =>
        Records.Add(KayaWire.TxMount(window, root.Id));

    public void Mount(Widget root) => Records.Add(KayaWire.TxMount(0, root.Id));
}

/// A template body: the same declaration vocabulary with template-node
/// ids, plus element bindings.
sealed class Tpl
{
    readonly Tx tx;

    internal Tpl(Tx enclosing) => tx = enclosing;

    public Node Widget(uint kind)
    {
        var n = tx.App.NextNode();
        tx.Records.Add(KayaWire.TxCreateWidget(n.Id, kind));
        tx.AutoParent(n.Id);
        return n;
    }

    public void SetText(Node n, string text) => tx.Records.Add(KayaWire.TxSetText(n.Id, text));

    /// Bind text to the element of the enclosing For, `level` Fors up
    /// (0 = nearest).
    public void BindTextElement(Node n, uint level = 0) =>
        tx.Records.Add(KayaWire.TxBindTextElement(n.Id, level));

    /// Bind a label's text to one field of the element; Field<string>
    /// only — the token pins the type at compile time.
    public void BindTextField(Node n, uint level, Field<string> f) =>
        tx.Records.Add(KayaWire.TxBindTextElement(n.Id, level, f.Index));

    /// Bind a checkbox's state to one field of the element;
    /// Field<bool> only.
    public void BindCheckedField(Node n, uint level, Field<bool> f) =>
        tx.Records.Add(KayaWire.TxBindCheckedElement(n.Id, level, f.Index));

    /// Bind an image's source to one field of the element;
    /// Field<byte[]> only — the token pins the type at compile time.
    public void BindSourceField(Node n, uint level, Field<byte[]> f) =>
        tx.Records.Add(KayaWire.TxBindSourceElement(n.Id, level, f.Index));

    // Construction sugar, template flavor: one name per widget, the
    // argument's type picks the addressable source (constant, signal,
    // or element field); handlers receive the stamped copy's keys
    // first.
    public Node Label(string text)
    {
        var n = Widget(KayaWire.KindLabel);
        tx.Records.Add(KayaWire.TxSetText(n.Id, text));
        return n;
    }

    public Node Label(Signal s)
    {
        var n = Widget(KayaWire.KindLabel);
        tx.Records.Add(KayaWire.TxBindText(n.Id, s.Id));
        return n;
    }

    public Node Label(Field<string> f)
    {
        var n = Widget(KayaWire.KindLabel);
        BindTextField(n, 0, f);
        return n;
    }

    /// An image over constant encoded bytes: one registration copy
    /// into core memory at record time — the handle is consumed by
    /// the next submit, and every stamped copy shows the same asset.
    public Node Image(byte[] source)
    {
        var n = Widget(KayaWire.KindImage);
        tx.Records.Add(KayaWire.TxSetSource(n.Id, Kaya.RegisterBlob(source)));
        return n;
    }

    public Node Image(Signal s)
    {
        var n = Widget(KayaWire.KindImage);
        tx.Records.Add(KayaWire.TxBindSource(n.Id, s.Id));
        return n;
    }

    public Node Image(Field<byte[]> f)
    {
        var n = Widget(KayaWire.KindImage);
        BindSourceField(n, 0, f);
        return n;
    }

    public Node Checkbox(Field<bool> f, Action<Tx, List<object>, bool> onToggle = null)
    {
        var n = Widget(KayaWire.KindCheckbox);
        BindCheckedField(n, 0, f);
        if (onToggle != null) tx.App.OnToggle(n, onToggle);
        return n;
    }

    public Node Column(Action body) => ContainerOf(KayaWire.KindColumn, body);

    public Node Row(Action body) => ContainerOf(KayaWire.KindRow, body);

    Node ContainerOf(uint kind, Action body)
    {
        var parent = Widget(kind);
        tx.App.Parents.Add(parent.Id);
        body?.Invoke();
        tx.App.Parents.RemoveAt(tx.App.Parents.Count - 1);
        return parent;
    }

    public void AddChild(Node parent, Node child) =>
        tx.Records.Add(KayaWire.TxAddChild(parent.Id, child.Id));

    public Collection Collection() => tx.Collection();

    public Node ForEach(Collection c, Action<Tpl> body)
    {
        c.AssertRoot();
        var n = tx.App.NextNode();
        ulong parent = tx.CurrentParent();
        tx.Records.Add(KayaWire.TxCreateFor(n.Id, c.Id));
        tx.App.OpenFors.Add(c.Id);
        tx.App.Parents.Add(0);
        tx.App.TplDepth++;
        try
        {
            body(new Tpl(tx));
        }
        finally
        {
            tx.App.TplDepth--;
        }
        tx.App.Parents.RemoveAt(tx.App.Parents.Count - 1);
        tx.App.OpenFors.RemoveAt(tx.App.OpenFors.Count - 1);
        tx.Records.Add(KayaWire.TxTemplateEnd());
        if (parent != 0)
            tx.Records.Add(KayaWire.TxAddChild(parent, n.Id));
        return n;
    }

    public Node When(Signal s, Action<Tpl> body)
    {
        var n = tx.App.NextNode();
        ulong parent = tx.CurrentParent();
        tx.Records.Add(KayaWire.TxCreateWhen(n.Id, s.Id));
        tx.App.Parents.Add(0);
        tx.App.TplDepth++;
        try
        {
            body(new Tpl(tx));
        }
        finally
        {
            tx.App.TplDepth--;
        }
        tx.App.Parents.RemoveAt(tx.App.Parents.Count - 1);
        tx.Records.Add(KayaWire.TxTemplateEnd());
        if (parent != 0)
            tx.Records.Add(KayaWire.TxAddChild(parent, n.Id));
        return n;
    }
}
