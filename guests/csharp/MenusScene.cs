// The menus conformance scene, C# port: the command vocabulary (a
// File/View/Sort menu bar, context menus on a live label and on stamped
// rows), the uncontrolled-menu echo doctrine, and a late
// rename/append/promotion rework. Canonical semantics in
// guests/rust/menus.rs; the byte-frozen contract in tools/scenes/menus.steps.

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

            // File and its Export leaf share one enablement signal: one
            // write moves both.
            var share = tx.Item("Share", primary: true, onActivate: onShare);
            var file = tx.Menu("File", enabled: canExport, items: new[]
            {
                tx.Item("Save", shortcut: "primary+s",
                    onActivate: t => t.Write(status, "saved")),
                tx.Item("Export", enabled: canExport),
                share,
            });
            var view = tx.Menu("View", items: new[]
            {
                tx.Toggle("Details", isChecked: details,
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
            // Catalog built live: items are shared across stamped copies; the
            // template only attaches, and each activation carries its key path.
            var catalog = tx.ContextCatalog(
                tx.Item("Remove", onActivate: (t, keys) =>
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
                    // The folds never echo the user's pick, so details/sort
                    // still hold false/0; these two prop writes are real
                    // checked/value records (never coalesced) that reset the
                    // backend's user-state mirror.
                    t.Write(details, false);
                    t.Write(sort, 0.0);
                    t.Write(status, "ready");
                });
                tx.Button("extend menus", t => // button#2
                {
                    // Append-only: rename the retained File, move the promotion
                    // hint from Share to Publish, grow the bar by Tools.
                    t.Menu(share, primary: false);
                    t.Menu(file, label: "Document", items: new[]
                    {
                        t.Item("Publish", primary: true, onActivate: onShare),
                    });
                    t.Window(menus: new[]
                    {
                        t.Menu("Tools", items: new[] { t.Item("Inspect") }),
                    });
                });

                var targetText = tx.Signal("rename target");
                var target = tx.Label(bind: targetText); // label#1
                tx.ContextMenu(target,
                    tx.Item("Rename", onActivate: t => t.Write(status, "renamed")));

                // Remove's activation names BOTH keys (group, then item).
                tx.ForEach(groups, g => g.Column(() =>
                {
                    items = g.Collection();
                    g.ForEach(items, r =>
                    {
                        var row = r.Label(KayaRecords.FieldAt<string>(0)); // label#2 once g2/a stamps
                        r.ContextMenu(row, catalog);
                    });
                }));
            }));
        });

        // Seed after mount: the stamp path attaches the shared catalog and keys.
        app.Build(tx =>
        {
            tx.Insert(groups, "g2", "Home");
            tx.Insert(items.At("g2"), "a", "water plants");
        });

        Environment.Exit(app.Run());
    }
}
