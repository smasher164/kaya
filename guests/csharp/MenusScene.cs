// The menus scene, C# port — guests/rust/menus.rs, tools/scenes/menus.steps.

using System;
using System.Collections.Generic;

static class MenusScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Collection groups = default;
        Collection items = default;

        app.Build(tx =>
        {
            var status = tx.Signal("ready");
            var canExport = tx.Signal(false);
            var details = tx.Signal(false);
            var sort = tx.Signal(0.0);

            Action<Tx> onShare = t => t.Write(status, "shared");

            var share = tx.Item("Share", primary: true, onActivate: onShare);
            var file = tx.Menu("File", enabled: canExport, items: new[]
            {
                // No `save` in the symbol vocabulary; Done is the checkmark
                // idiom (docs/styling-plan.md D6).
                tx.Item("Save", shortcut: "primary+s", symbol: Symbol.Done,
                    onActivate: t => t.Write(status, "saved")),
                tx.Item("Export", enabled: canExport, symbol: Symbol.Forward),
                share,
            });
            var view = tx.Menu("View", items: new[]
            {
                tx.Toggle("Details", isChecked: details, symbol: Symbol.Info,
                    onToggle: (t, on) => t.Write(status, on ? "details on" : "details off")),
            });
            // Option order IS the index vocabulary: Name = 0, Date = 1.
            var sortGroup = tx.RadioGroup("Sort",
                options: new[] { tx.Option("Name"), tx.Option("Date") },
                value: sort,
                onSelect: (t, index) =>
                    t.Write(status, index == 1 ? "sorted date" : "sorted name"));
            tx.Window(title: "menus", menus: new[] { file, view, sortGroup });

            groups = tx.Collection();
            var catalog = tx.ContextCatalog(
                tx.Item("Remove", symbol: Symbol.Delete, onActivate: (t, keys) =>
                {
                    string group = (string)keys[0];
                    string item = (string)keys[1];
                    t.Remove(items.At(group), item);
                    t.Write(status, $"removed {group}/{item}");
                }));

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: status); // label#0
                tx.Button("enable export", t => // button#0
                    t.Write(canExport, true));
                tx.Button("reset menu state", t => // button#1
                {
                    t.Write(details, false);
                    t.Write(sort, 0.0);
                    t.Write(status, "ready");
                });
                tx.Button("extend menus", t => // button#2
                {
                    t.Menu(share, primary: false);
                    t.Menu(file, label: "Document", items: new[]
                    {
                        t.Item("Publish", symbol: Symbol.Copy, primary: true,
                            onActivate: onShare),
                    });
                    t.Window(menus: new[]
                    {
                        t.Menu("Tools", items: new[]
                        {
                            t.Item("Inspect", symbol: Symbol.Search),
                        }),
                    });
                });

                var targetText = tx.Signal("rename target");
                var target = tx.Label(bind: targetText); // label#1
                tx.ContextMenu(target,
                    tx.Item("Rename", symbol: Symbol.Edit,
                        onActivate: t => t.Write(status, "renamed")));

                tx.Each(groups, g => g.Column(() =>
                {
                    items = g.Collection();
                    g.Each(items, r =>
                    {
                        // The For stays open: the generated row façade forwards no
                        // ContextMenu (docs/deferred.md, the three-façades entry).
                        var row = r.Label(Field<string>.Element); // label#2 once g2/a stamps
                        r.ContextMenu(row, catalog);
                    });
                }));
            }));
        });

        // Seeded after the mount, so the copy stamps from a closed template.
        app.Build(tx =>
        {
            tx.Insert(groups, "g2", "Home");
            tx.Insert(items.At("g2"), "a", "water plants");
        });

        Environment.Exit(app.Run());
    }
}
