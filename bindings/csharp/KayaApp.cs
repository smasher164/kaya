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
                    Build(fn);
            }
            else if (kind == KayaWire.OccKindButtonClicked)
            {
                if (nodeHandlers.TryGetValue(id, out var fn))
                    Build(tx => fn(tx, keys));
            }
            else if (kind == KayaWire.OccKindTextChanged && keys.Count == 0)
            {
                if (widgetChanges.TryGetValue(id, out var fn))
                    Build(tx => fn(tx, text));
            }
            else if (kind == KayaWire.OccKindTextChanged)
            {
                if (nodeChanges.TryGetValue(id, out var fn))
                    Build(tx => fn(tx, keys, text));
            }
            else if (kind == KayaWire.OccKindToggled && keys.Count == 0)
            {
                if (widgetToggles.TryGetValue(id, out var fn))
                    Build(tx => fn(tx, isChecked));
            }
            else if (kind == KayaWire.OccKindToggled)
            {
                if (nodeToggles.TryGetValue(id, out var fn))
                    Build(tx => fn(tx, keys, isChecked));
            }
            else if (kind == KayaWire.OccKindValueChanged && keys.Count == 0)
            {
                if (widgetValues.TryGetValue(id, out var fn))
                    Build(tx => fn(tx, payload is double d ? d : 0.0));
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

    public void BindChecked(Widget w, Signal s) =>
        Records.Add(KayaWire.TxBindChecked(w.Id, s.Id));

    public void AddChild(Widget parent, Widget child) =>
        Records.Add(KayaWire.TxAddChild(parent.Id, child.Id));

    // --- Construction sugar: the tree reads as a tree ----------------
    //
    // Co-located constructors (props and handlers at the declaration
    // site) and params-array containers. Everything lowers eagerly to
    // the same records — children first, then the container, then the
    // AddChilds; never a scene value interpreted later.

    public Widget Button(string text = null, Action<Tx> onClick = null)
    {
        var w = Widget(KayaWire.KindButton);
        if (text != null) SetText(w, text);
        if (onClick != null) App.OnClick(w, onClick);
        return w;
    }

    public Widget Entry(Action<Tx, string> onChange = null)
    {
        var w = Widget(KayaWire.KindEntry);
        if (onChange != null) App.OnChange(w, onChange);
        return w;
    }

    public Widget Label(string text = null, Signal? bind = null)
    {
        var w = Widget(KayaWire.KindLabel);
        if (text != null) SetText(w, text);
        if (bind is Signal s) BindText(w, s);
        return w;
    }

    /// A slider over min..max at value, with its change handler
    /// co-located.
    public Widget Slider(double min = 0.0, double max = 1.0, double value = 0.0,
        Action<Tx, double> onChange = null)
    {
        var w = Widget(KayaWire.KindSlider);
        Records.Add(KayaWire.TxSetMin(w.Id, min));
        Records.Add(KayaWire.TxSetMax(w.Id, max));
        Records.Add(KayaWire.TxSetValue(w.Id, value));
        if (onChange != null) App.OnValueChanged(w, onChange);
        return w;
    }

    public Widget Checkbox(string text = null, bool? isChecked = null,
        Action<Tx, bool> onToggle = null)
    {
        var w = Widget(KayaWire.KindCheckbox);
        if (text != null) SetText(w, text);
        if (isChecked is bool c) SetChecked(w, c);
        if (onToggle != null) App.OnToggle(w, onToggle);
        return w;
    }

    /// A container parents everything declared inside its body (the
    /// ambient stack). Statement position is the point: a foreach over
    /// a generated row trace stands between siblings.
    public Widget Column(Action body) => ContainerOf(KayaWire.KindColumn, body);

    public Widget Row(Action body) => ContainerOf(KayaWire.KindRow, body);

    Widget ContainerOf(uint kind, Action body)
    {
        var parent = Widget(kind);
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
        body(new Tpl(this));
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
        return (new Tpl(this), () =>
        {
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
        body(new Tpl(this));
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

    /// The model: what this guest wrote, exactly — the fold of every
    /// patch so far (this transaction's included), in insertion order.
    public List<KeyValuePair<object, object>> Items(Collection c)
    {
        var instance = App.InstanceOf(c.Id, c.Path);
        return instance == null
            ? new List<KeyValuePair<object, object>>()
            : new List<KeyValuePair<object, object>>(instance.Entries);
    }

    public int Count(Collection c) => App.InstanceOf(c.Id, c.Path)?.Entries.Count ?? 0;

    /// Mount into the default window; per-window targets arrive with
    /// the window vocabulary.
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
        body(new Tpl(tx));
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
        body(new Tpl(tx));
        tx.App.Parents.RemoveAt(tx.App.Parents.Count - 1);
        tx.Records.Add(KayaWire.TxTemplateEnd());
        if (parent != 0)
            tx.Records.Add(KayaWire.TxAddChild(parent, n.Id));
        return n;
    }
}
