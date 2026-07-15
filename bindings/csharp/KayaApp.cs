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

sealed class KayaApp
{
    ulong signals, widgets, collections, nodes;
    readonly Dictionary<ulong, Action<Tx>> widgetHandlers = new();
    readonly Dictionary<ulong, Action<Tx, List<object>>> nodeHandlers = new();

    public KayaApp() => Kaya.Init();

    internal Signal NextSignal() => new(++signals);

    internal Widget NextWidget() => new(++widgets);

    internal Node NextNode() => new(++nodes);

    internal Collection NextCollection() => new(++collections);

    /// Run `build` with a fresh transaction and submit it atomically.
    public void Build(Action<Tx> build)
    {
        var tx = new Tx(this);
        build(tx);
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

    internal Tx(KayaApp app) => App = app;

    internal void SubmitIfAny()
    {
        if (Records.Count > 0)
            Kaya.Submit(Records.ToArray());
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
        Records.Add(KayaWire.TxCreateCollection(c.Id));
        return c;
    }

    /// A For over `c`: the body declares the template; the For itself
    /// (a live container) is returned.
    public Widget ForEach(Collection c, Action<Tpl> body)
    {
        var w = App.NextWidget();
        Records.Add(KayaWire.TxCreateFor(w.Id, c.Id));
        body(new Tpl(this));
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

    public void Insert(Collection c, object[] path, object key, object value) =>
        Records.Add(KayaWire.TxCollectionInsert(c.Id, path, key, value));

    public void Update(Collection c, object[] path, object key, object value) =>
        Records.Add(KayaWire.TxCollectionUpdate(c.Id, path, key, value));

    public void Remove(Collection c, object[] path, object key) =>
        Records.Add(KayaWire.TxCollectionRemove(c.Id, path, key));

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
        body(new Tpl(tx));
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
