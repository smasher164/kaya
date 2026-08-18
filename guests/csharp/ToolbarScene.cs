// The toolbar conformance scene, C# port: the `primary` bit as real
// window chrome (docs/chrome-plan.md C2). One catalog, two primaries,
// and no toolbar vocabulary of its own. Canonical semantics in
// guests/rust/toolbar.rs; the byte-frozen contract in
// tools/scenes/toolbar.steps.

using System;

static class ToolbarScene
{
    public static void Run()
    {
        var app = new KayaApp();

        bool saveEnabled = true;

        app.Build(tx =>
        {
            var status = tx.Signal("ready");
            // Written against the MENU ITEM and nothing else: the
            // promoted button is that same item, so it follows or the
            // lowering kept a copy.
            var canSave = tx.Signal(true);

            // CATALOG PREORDER DECIDES PROMOTION — menubar-append order,
            // then each node's children depth-first. Save is the first
            // primary and Find the second, so every host's promoted set
            // is [Save, Find] however large its own k is.
            var file = tx.Menu("File", items: new[]
            {
                // The symbol vocabulary has no save-specific glyph; Done
                // is the checkmark idiom (docs/styling-plan.md D6).
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
                // Everything below is catalog, not chrome, on every host.
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
