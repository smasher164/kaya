// The row menu scene, C# port — guests/rust/rowmenu.rs, tools/scenes/rowmenu.steps
// (docs/media-player-plan.md M26).

using System;
using System.Collections.Generic;

[KayaGen]
record RowmenuEntry(string Title, string Mark, bool Plain);

static class RowmenuScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "rowmenu");
            var status = tx.Signal("ready");
            var hide = tx.Signal(true);
            var notes = RowmenuEntryKaya.Collection(tx);
            var files = RowmenuEntryKaya.Collection(tx);
            Action<Tx, List<object>> Toggle(RecordCollection<RowmenuEntry> c,
                string on, string off, string did, string undid) => (t, keys) =>
            {
                var key = (string)keys[0];
                bool set = c.TryGet(t, key, out var entry) && entry.Mark == on;
                RowmenuEntryKaya.Patch(t, c, key).Mark(set ? off : on).Plain(!set);
                t.Write(status, $"{(set ? did : undid)} {key}");
            };
            Action<Tx, List<object>> open = (t, keys) => t.Write(status, $"opened {keys[0]}");
            var star = tx.Item("Star", Toggle(notes, "Star", "Unstar", "starred", "unstarred"));
            var noteMenu = tx.ContextCatalog(star, tx.Separator(), tx.Item("Open", open));
            var pin = tx.Item("Pin", Toggle(files, "Pin", "Unpin", "pinned", "unpinned"));
            var fileMenu = tx.ContextCatalog(pin, tx.Separator(), tx.Item("Open", open));

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: status);
                tx.Row(pair =>
                {
                    tx.Column(trio =>
                    {
                        tx.SetA11yId(tx.Label("A"), "va");
                        var b = tx.Label("B");
                        tx.SetA11yId(b, "vb");
                        tx.SetHidden(b, hide);
                        tx.SetA11yId(tx.Label("C"), "vc");
                        return trio;
                    });
                    tx.SetA11yId(tx.Button("Show B", onClick: t => t.Write(hide, false)), "show");
                    return pair;
                });
                tx.Each(notes.Collection, r =>
                {
                    var line = r.Row(() => r.Column(() =>
                    {
                        r.SetA11yId(r.Label(RowmenuEntryKaya.Title), "title");
                        var flag = r.Caption(RowmenuEntryKaya.Mark);
                        r.SetA11yId(flag, "flag");
                        r.SetHidden(flag, RowmenuEntryKaya.Plain);
                        r.SetA11yId(r.Caption(RowmenuEntryKaya.Title), "foot");
                    }));
                    r.SetA11yId(line, "note");
                    r.ContextMenu(line, noteMenu);
                    r.ContextLabel(line, star, RowmenuEntryKaya.Mark);
                });
                var table = tx.Each(files.Collection, r =>
                {
                    var line = r.Row(() => r.Label(RowmenuEntryKaya.Title));
                    r.SetA11yId(line, "file");
                    r.ContextMenu(line, fileMenu);
                    r.ContextLabel(line, pin, RowmenuEntryKaya.Mark);
                });
                tx.SetGrow(table, 1);
                tx.Columns(table, new[] { "Name" }, Sort.None);
                return root;
            }));
            foreach (var (key, title, mark) in new[] { ("a", "apples", "Star"), ("b", "bread", "Unstar") })
                notes.Insert(tx, key, new RowmenuEntry(title, mark, mark == "Star"));
            foreach (var (key, title, mark) in new[] { ("x", "x.txt", "Pin"), ("y", "y.txt", "Unpin") })
                files.Insert(tx, key, new RowmenuEntry(title, mark, mark == "Pin"));
        });

        Environment.Exit(app.Run());
    }
}
