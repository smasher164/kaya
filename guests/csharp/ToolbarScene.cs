// The toolbar conformance scene, C# port: the `primary` bit as real
// window chrome (docs/chrome-plan.md C2). The app declares ONE catalog
// and marks two actions primary; every host promotes the same first two
// in catalog preorder — the desktop's toolbar, the phones' top bar —
// and the rest of the catalog stays reachable where that host keeps it.
//
// There is no toolbar vocabulary to spell here, and that is the point:
// this guest is the menus guest with a promotion bit and no new call.
// Canonical semantics in guests/rust/toolbar.rs; the byte-frozen
// contract in tools/scenes/toolbar.steps.

using System;

static class ToolbarScene
{
    public static void Run()
    {
        var app = new KayaApp();

        // The guest's own copy of the enablement, flipped by the button.
        // The signal is the model; this is only what "the other one"
        // means.
        bool saveEnabled = true;

        app.Build(tx =>
        {
            var status = tx.Signal("ready");
            // The one signal the enablement round-trip turns on. The app
            // writes it against the MENU ITEM and says nothing about any
            // button: the promoted button is that same item, so it
            // follows or the lowering kept a copy.
            var canSave = tx.Signal(true);

            // CATALOG PREORDER DECIDES PROMOTION — top-level groupings
            // in menubar-append order, then each node's children in
            // append order, depth-first. Save is the first primary and
            // Find the second, so every host's promoted set is
            // [Save, Find] however large its own k is.
            var file = tx.Menu("File", items: new[]
            {
                // Done is the checkmark idiom: the vocabulary has no
                // save-specific glyph, and neither does Apple's own
                // catalog (docs/styling-plan.md D6).
                tx.Item("Save", shortcut: "primary+s", enabled: canSave,
                    symbol: Symbol.Done, primary: true,
                    onActivate: t => t.Write(status, "saved")),
                tx.Item("Export", symbol: Symbol.Forward,
                    onActivate: t => t.Write(status, "exported")),
            });
            var edit = tx.Menu("Edit", items: new[]
            {
                tx.Item("Find", symbol: Symbol.Search, primary: true,
                    onActivate: t => t.Write(status, "found")),
                // The remainder: everything below is catalog, not chrome,
                // on every platform — which is what makes the bare
                // expect_toolbar's second half a real question.
                tx.Item("Replace", symbol: Symbol.Edit),
            });
            var view = tx.Menu("View", items: new[]
            {
                tx.Item("Refresh", symbol: Symbol.Refresh),
                tx.Item("Info", symbol: Symbol.Info),
            });
            tx.Window(title: "toolbar", menus: new[] { file, edit, view });

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: status); // label#0
                tx.Button("toggle save", t => // button#0
                {
                    saveEnabled = !saveEnabled;
                    t.Write(canSave, saveEnabled);
                });
            }));
        });

        Environment.Exit(app.Run());
    }
}
