// The hidden-rows scene, C# port — guests/rust/hiderows.rs, tools/scenes/hiderows.steps
// (docs/hidden-plan.md).

using System;

[KayaGen]
record HiderowsNote(string Title, bool Unmatched);

[KayaGen]
record HiderowsFile(string Name, string Size, bool Unmatched);

static class HiderowsScene
{
    static readonly string[] Notes = { "alpha", "beta", "gamma" };

    static string FileName(int i) => $"file {i:D3}";

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "hiderows", width: 480, height: 760);
            var notes = HiderowsNoteKaya.Collection(tx);
            var files = HiderowsFileKaya.Collection(tx);
            var two = tx.Signal(false);
            var pane = tx.Signal(false);

            tx.Mount(tx.Column(root =>
            {
                var findNotes = tx.Search(onChange: (t, query) =>
                {
                    foreach (var title in Notes)
                        HiderowsNoteKaya.Patch(t, notes, title).Unmatched(!title.Contains(query));
                });
                tx.SetPlaceholder(findNotes, "Find notes");
                tx.SetA11yId(findNotes, "find_notes");
                var list = tx.Each(notes.Collection, r =>
                {
                    var line = r.Row(() =>
                    {
                        r.Label(HiderowsNoteKaya.Title);
                        r.SetA11yId(r.Entry(), "note");
                    });
                    r.SetHidden(line, HiderowsNoteKaya.Unmatched);
                });
                tx.SetA11yId(list, "notes");
                var tiles = tx.Grid(2, tiles =>
                {
                    tx.Label("one");
                    tx.SetHidden(tx.Label("two"), two);
                    tx.Label("three");
                    return tiles;
                });
                tx.SetA11yId(tiles, "tiles");
                var draft = tx.Column(hideable =>
                {
                    tx.SetHidden(hideable, pane);
                    tx.Scroll(strip =>
                    {
                        tx.SetA11yId(strip, "strip");
                        tx.Row(_ =>
                        {
                            for (int i = 1; i <= 20; i++)
                                tx.Label(bind: tx.Signal($"card {i}"));
                        });
                    }, axis: Axis.Horizontal);
                    var editor = tx.Textarea();
                    tx.SetA11yId(editor, "draft");
                    tx.SetA11yLabel(editor, "Draft");
                    return editor;
                });
                tx.Row(_ =>
                {
                    tx.SetA11yId(tx.Checkbox("Hide two", onToggle: (t, on) => t.Write(two, on)), "hide_two");
                    tx.SetA11yId(tx.Checkbox("Hide pane", onToggle: (t, on) => t.Write(pane, on)), "hide_pane");
                });
                tx.SetA11yId(tx.Button("select first", onClick: t =>
                {
                    t.Focus(draft);
                    t.SelectRange(draft, TextRange.Bytes(0, 5));
                }), "select_first");
                var findFiles = tx.Search(onChange: (t, query) =>
                {
                    for (var i = 0; i < 300; i++)
                        HiderowsFileKaya.Patch(t, files, FileName(i)).Unmatched(!FileName(i).Contains(query));
                });
                tx.SetPlaceholder(findFiles, "Find files");
                tx.SetA11yId(findFiles, "find_files");
                var table = tx.Each(files.Collection, r =>
                {
                    var line = r.Row(() =>
                    {
                        r.Label(HiderowsFileKaya.Name);
                        r.Label(HiderowsFileKaya.Size);
                    });
                    r.SetHidden(line, HiderowsFileKaya.Unmatched);
                });
                tx.SetA11yId(table, "files");
                tx.SetGrow(table, 1);
                tx.Columns(table, new[] { "Name", "Size" }, Sort.None);
                return root;
            }));
            foreach (var title in Notes)
                notes.Insert(tx, title, new HiderowsNote(title, false));
            for (var i = 0; i < 300; i++)
                files.Insert(tx, FileName(i), new HiderowsFile(FileName(i), $"{i} KB", false));
        });

        Environment.Exit(app.Run());
    }
}
