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
    readonly Dictionary<ulong, Action<Tx, List<object>, bool>> nodeToggles = new();

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

    public Widget Checkbox(string text = null, bool? isChecked = null,
        Action<Tx, bool> onToggle = null)
    {
        var w = Widget(KayaWire.KindCheckbox);
        if (text != null) SetText(w, text);
        if (isChecked is bool c) SetChecked(w, c);
        if (onToggle != null) App.OnToggle(w, onToggle);
        return w;
    }

    public Widget Column(params Widget[] children) =>
        ContainerOf(KayaWire.KindColumn, children);

    public Widget Row(params Widget[] children) =>
        ContainerOf(KayaWire.KindRow, children);

    Widget ContainerOf(uint kind, Widget[] children)
    {
        var parent = Widget(kind);
        foreach (var child in children)
            AddChild(parent, child);
        return parent;
    }

    /// A For as a child: ForEach whose body keeps no handles — the
    /// common case once handlers co-locate at their constructors.
    public Widget Each(Collection c, Action<Tpl> body) => ForEach(c, body);

    public Collection Collection()
    {
        var c = App.NextCollection();
        App.RegisterCollection(c.Id);
        Records.Add(KayaWire.TxCreateCollection(c.Id, new uint[] { KayaWire.ValueStr }));
        return c;
    }

    /// A For over `c`: the body declares the template; the For itself
    /// (a live container) is returned.
    public Widget ForEach(Collection c, Action<Tpl> body)
    {
        c.AssertRoot();
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

    public void Insert(Collection c, object key, object value)
    {
        ModelSet(c.Id, c.Path, key, value);
        Records.Add(KayaWire.TxCollectionInsert(c.Id, c.Path, key, new[] { value }));
        RecomputeDerived(c);
    }

    public void Update(Collection c, object key, object value)
    {
        ModelSet(c.Id, c.Path, key, value);
        Records.Add(KayaWire.TxCollectionUpdate(c.Id, c.Path, key, new[] { value }));
        RecomputeDerived(c);
    }

    public void Remove(Collection c, object key)
    {
        ModelRemove(c.Id, c.Path, key);
        Records.Add(KayaWire.TxCollectionRemove(c.Id, c.Path, key));
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
        var c = App.NextCollection();
        App.RegisterCollection(c.Id);
        Records.Add(KayaWire.TxCreateCollection(c.Id, schema));
        return c;
    }

    internal void InsertRecordRaw(Collection c, object key, object model, object[] fields)
    {
        ModelSet(c.Id, c.Path, key, model);
        Records.Add(KayaWire.TxCollectionInsert(c.Id, c.Path, key, fields));
        RecomputeDerived(c);
    }

    internal void UpdateRecordRaw(Collection c, object key, object model, object[] fields)
    {
        ModelSet(c.Id, c.Path, key, model);
        Records.Add(KayaWire.TxCollectionUpdate(c.Id, c.Path, key, fields));
        RecomputeDerived(c);
    }

    internal void UpdateFieldRaw(Collection c, object key, object model, uint field, object value)
    {
        ModelSet(c.Id, c.Path, key, model);
        Records.Add(KayaWire.TxCollectionUpdateField(c.Id, c.Path, key, field, value));
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

    public Node Column(params Node[] children) => ContainerOf(KayaWire.KindColumn, children);

    public Node Row(params Node[] children) => ContainerOf(KayaWire.KindRow, children);

    Node ContainerOf(uint kind, Node[] children)
    {
        var parent = Widget(kind);
        foreach (var child in children)
            AddChild(parent, child);
        return parent;
    }

    public void AddChild(Node parent, Node child) =>
        tx.Records.Add(KayaWire.TxAddChild(parent.Id, child.Id));

    public Collection Collection() => tx.Collection();

    public Node ForEach(Collection c, Action<Tpl> body)
    {
        c.AssertRoot();
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
