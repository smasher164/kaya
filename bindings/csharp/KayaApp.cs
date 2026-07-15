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

readonly struct Collection
{
    internal readonly ulong Id;

    internal Collection(ulong id) => Id = id;
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
    ulong signals, widgets, collections, nodes;
    readonly Dictionary<ulong, Action<Tx>> widgetHandlers = new();
    readonly Dictionary<ulong, Action<Tx, List<object>>> nodeHandlers = new();

    // The collection is the model — the only copy: every mutation op
    // edits it and queues the wire delta in the same call, so reads
    // (Items, Count) are exactly the writes. Children records the
    // declared-inside-a-For edges the model purges along when a parent
    // entry's copy is torn down.
    internal readonly Dictionary<ulong, List<KayaInstance>> Model = new();
    internal readonly Dictionary<ulong, List<ulong>> Children = new();
    internal readonly List<ulong> OpenFors = new();

    public KayaApp() => Kaya.Init();

    internal Signal NextSignal() => new(++signals);

    internal Widget NextWidget() => new(++widgets);

    internal Node NextNode() => new(++nodes);

    internal Collection NextCollection() => new(++collections);

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
        try
        {
            build(tx);
        }
        catch
        {
            tx.Rollback();
            throw;
        }
        tx.SubmitIfAny();
    }

    /// Register a click handler for a live widget.
    public void OnClick(Widget w, Action<Tx> handler) => widgetHandlers[w.Id] = handler;

    /// Register a click handler for a template node; it also receives
    /// the stamped copy's keys, outermost first.
    public void OnClick(Node n, Action<Tx, List<object>> handler) => nodeHandlers[n.Id] = handler;

    void DispatchLoop()
    {
        while (Kaya.NextClick(out ulong id, out List<object> keys))
        {
            if (keys.Count == 0)
            {
                if (widgetHandlers.TryGetValue(id, out var fn))
                    Build(fn);
            }
            else if (nodeHandlers.TryGetValue(id, out var fn))
            {
                Build(tx => fn(tx, keys));
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

    internal Tx(KayaApp app) => App = app;

    internal void SubmitIfAny()
    {
        if (Records.Count > 0)
            Kaya.Submit(Records.ToArray());
    }

    internal void Rollback()
    {
        foreach (var (id, snapshot) in journal)
            App.Model[id] = snapshot;
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
        return s;
    }

    public void Write(Signal s, object value) => Records.Add(KayaWire.TxWriteSignal(s.Id, value));

    public Widget Widget(uint kind)
    {
        var w = App.NextWidget();
        Records.Add(KayaWire.TxCreateWidget(w.Id, kind));
        return w;
    }

    public void SetText(Widget w, string text) => Records.Add(KayaWire.TxSetText(w.Id, text));

    public void BindText(Widget w, Signal s) => Records.Add(KayaWire.TxBindText(w.Id, s.Id));

    public void AddChild(Widget parent, Widget child) =>
        Records.Add(KayaWire.TxAddChild(parent.Id, child.Id));

    public Collection Collection()
    {
        var c = App.NextCollection();
        App.RegisterCollection(c.Id);
        Records.Add(KayaWire.TxCreateCollection(c.Id));
        return c;
    }

    /// A For over `c`: the body declares the template; the For itself
    /// (a live container) is returned.
    public Widget ForEach(Collection c, Action<Tpl> body)
    {
        var w = App.NextWidget();
        Records.Add(KayaWire.TxCreateFor(w.Id, c.Id));
        App.OpenFors.Add(c.Id);
        body(new Tpl(this));
        App.OpenFors.RemoveAt(App.OpenFors.Count - 1);
        Records.Add(KayaWire.TxTemplateEnd());
        return w;
    }

    /// A When over a Bool signal: stamps on true, unstamps on false.
    public Widget When(Signal s, Action<Tpl> body)
    {
        var w = App.NextWidget();
        Records.Add(KayaWire.TxCreateWhen(w.Id, s.Id));
        body(new Tpl(this));
        Records.Add(KayaWire.TxTemplateEnd());
        return w;
    }

    // A null path means the live-zone instance, matching the wire
    // packers' convention.
    static object[] NoPath(object[] path) => path ?? Array.Empty<object>();

    public void Insert(Collection c, object[] path, object key, object value)
    {
        ModelSet(c.Id, NoPath(path), key, value);
        Records.Add(KayaWire.TxCollectionInsert(c.Id, path, key, value));
    }

    public void Update(Collection c, object[] path, object key, object value)
    {
        ModelSet(c.Id, NoPath(path), key, value);
        Records.Add(KayaWire.TxCollectionUpdate(c.Id, path, key, value));
    }

    public void Remove(Collection c, object[] path, object key)
    {
        ModelRemove(c.Id, NoPath(path), key);
        Records.Add(KayaWire.TxCollectionRemove(c.Id, path, key));
    }

    /// The model: what this guest wrote, exactly — the fold of every
    /// patch so far (this transaction's included), in insertion order.
    public List<KeyValuePair<object, object>> Items(Collection c, object[] path)
    {
        var instance = App.InstanceOf(c.Id, NoPath(path));
        return instance == null
            ? new List<KeyValuePair<object, object>>()
            : new List<KeyValuePair<object, object>>(instance.Entries);
    }

    public int Count(Collection c, object[] path) =>
        App.InstanceOf(c.Id, NoPath(path))?.Entries.Count ?? 0;

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
        return n;
    }

    public void SetText(Node n, string text) => tx.Records.Add(KayaWire.TxSetText(n.Id, text));

    /// Bind text to the element of the enclosing For, `level` Fors up
    /// (0 = nearest).
    public void BindTextElement(Node n, uint level = 0) =>
        tx.Records.Add(KayaWire.TxBindTextElement(n.Id, level));

    public void AddChild(Node parent, Node child) =>
        tx.Records.Add(KayaWire.TxAddChild(parent.Id, child.Id));

    public Collection Collection() => tx.Collection();

    public Node ForEach(Collection c, Action<Tpl> body)
    {
        var n = tx.App.NextNode();
        tx.Records.Add(KayaWire.TxCreateFor(n.Id, c.Id));
        tx.App.OpenFors.Add(c.Id);
        body(new Tpl(tx));
        tx.App.OpenFors.RemoveAt(tx.App.OpenFors.Count - 1);
        tx.Records.Add(KayaWire.TxTemplateEnd());
        return n;
    }

    public Node When(Signal s, Action<Tpl> body)
    {
        var n = tx.App.NextNode();
        tx.Records.Add(KayaWire.TxCreateWhen(n.Id, s.Id));
        body(new Tpl(tx));
        tx.Records.Add(KayaWire.TxTemplateEnd());
        return n;
    }
}
