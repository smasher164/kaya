// The toolbar scene, C# port — guests/rust/toolbar.rs,
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
            // Written against the MENU ITEM: the promoted button IS that item.
            var canSave = tx.Signal(true);

            // CATALOG PREORDER DECIDES PROMOTION — menubar-append order, then
            // children depth-first, so every host promotes [Save, Find].
            var file = tx.Menu("File", items: new[]
            {
                // No save-specific glyph; Done is the checkmark idiom
                // (docs/styling-plan.md D6).
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
