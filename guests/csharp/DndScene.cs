// The drag-and-drop scene, C# port — guests/rust/dnd.rs,
// tools/scenes/dnd.steps. THE ROOT IS A ROW so column#0 is the
// reorderable For's container.

using System.Collections.Generic;
using System.IO;
using System.Text;

[KayaGen]
record DndItem(string Title);

static class DndScene
{
    const string NoteId = "dev.kaya/note";

    static string Word(Op? op) => op switch
    {
        Op.Copy => "copy",
        Op.Move => "move",
        _ => "none",
    };

    static string KeyWord(List<object> keys) =>
        keys.Count == 0 ? "" : keys[0]?.ToString() ?? "";

    // The file the scene drops as a FOREIGN source (D6), written by the
    // guest at $TMP/kaya-dnd-$PID/dropped.txt — the picker and clipboard
    // scenes' convention.
    static void WriteDroppedFile()
    {
        var dir = Path.Combine(
            Path.GetTempPath(),
            $"kaya-dnd-{System.Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "dropped.txt"), "dropped bytes");
    }

    static string ReadBack(PickedFile file)
    {
        try
        {
            var (stream, _) = file.Open(KayaWire.FileModeRead);
            using (stream)
            using (var reader = new StreamReader(stream))
                return reader.ReadToEnd();
        }
        catch (IOException e)
        {
            return $"open failed: {e.Message}";
        }
    }

    public static void Run()
    {
        WriteDroppedFile();
        var app = new KayaApp();

        app.Build(tx =>
        {
            var items = DndItemKaya.Collection(tx);
            var items2 = DndItemKaya.Collection(tx);
            var dropStatus = tx.Signal("no drop yet");
            var dragStatus = tx.Signal("no drag yet");
            var sourceText = tx.Signal("hello");
            var textTarget = tx.Signal("text target");
            var noteTarget = tx.Signal("note target");
            var filesTarget = tx.Signal("files target");

            Widget source = default, textId = default, noteId = default,
                filesId = default, list = default;
            Node rowLabel = default, itemLabel = default;
            tx.Window(title: "dnd");
            tx.Mount(tx.Row(() =>
            {
                list = tx.Each(items.Collection, t =>
                {
                    var row = new DndItemRow(t);
                    rowLabel = row.Label(row.Title);
                    row.SetA11yId(rowLabel, "row");
                });
                tx.SetA11yId(list, "rows");
                tx.Column(() =>
                {
                    source = tx.Label(bind: sourceText);  // label#0
                    textId = tx.Label(bind: textTarget);  // label#1
                    tx.SetAccepts(textId, Tx.AcceptText);
                    tx.SetDropTarget(textId, Op.Copy);
                    noteId = tx.Label(bind: noteTarget);  // label#2
                    tx.SetAccepts(noteId, NoteId);
                    tx.SetDropTarget(noteId, Op.Copy, Op.Move);
                    filesId = tx.Label(bind: filesTarget);  // label#3
                    tx.SetAccepts(filesId, Tx.AcceptFiles);
                    tx.SetDropTarget(filesId, Op.Copy);
                    tx.Label(bind: dropStatus);  // label#4
                    tx.Label(bind: dragStatus);  // label#5
                });
                // THE TEMPLATE ZONE (docs/dnd-plan.md §4): every stamped
                // item is a text destination, and its payload IS the
                // row's own field — resolved per copy, re-declared when
                // the field changes — column#2.
                var itemList = tx.Each(items2.Collection, t =>
                {
                    var row = new DndItemRow(t);
                    itemLabel = row.Label(row.Title);
                    row.SetA11yId(itemLabel, "item");
                    row.SetAccepts(itemLabel, Tx.AcceptText);
                    row.SetDropTarget(itemLabel, Op.Copy);
                    row.Draggable(itemLabel).Text(row.Title).Allow(Op.Copy).Declare();
                });
                tx.SetA11yId(itemList, "items");
                tx.Button("rename y", onClick: t =>                 // button#0
                    items2.Update(t, "y", new DndItem("yy")));
            }));
            tx.Draggable(source)
                .Text("hello")
                .Custom(NoteId, Encoding.UTF8.GetBytes("note!"))
                .Allow(Op.Copy)
                .Allow(Op.Move)
                .Declare();
            tx.SetReorderable(list, true);

            System.Action<Tx, Dropped> Dropped(string name, Signal target) =>
                (t, d) =>
                {
                    var op = Word(d.Operation);
                    switch (d.Clip)
                    {
                        case Representation.Text text:
                            t.Write(dropStatus, $"{name} got text {text.Value} ({op})");
                            t.Write(target, text.Value);
                            break;
                        case Representation.Custom custom:
                            t.Write(dropStatus,
                                $"{name} got {custom.Id} {custom.Bytes.Length} bytes ({op})");
                            break;
                        case Representation.Files files:
                            // A dropped file IS a picked file (D6): read it
                            // back through the same table the picker fills.
                            var said = new List<string>();
                            foreach (var f in files.Value)
                                said.Add($"{f.Name} {ReadBack(f)}");
                            t.Write(dropStatus,
                                $"{name} got {string.Join(", ", said)} ({op})");
                            break;
                        default:
                            t.Write(dropStatus, $"{name} got other ({op})");
                            break;
                    }
                    // A same-app MOVE removes its original in the same batch (D2).
                    if (d.Operation == Op.Move)
                    {
                        t.Write(sourceText, "moved out");
                        t.Draggable(source).Declare();
                    }
                };
            tx.OnDrop(textId, Dropped("text target", textTarget));
            tx.OnDrop(noteId, Dropped("note target", noteTarget));
            tx.OnDrop(filesId, Dropped("files target", filesTarget));
            tx.OnDragEnded(source, (t, op) =>
                t.Write(dragStatus, $"drag ended {Word(op)}"));
            tx.OnDrop(itemLabel, (t, keys, d) =>
            {
                var op = Word(d.Operation);
                if (d.Clip is Representation.Text text)
                    t.Write(dropStatus, $"item {KeyWord(keys)} got text {text.Value} ({op})");
                else
                    t.Write(dropStatus, $"item {KeyWord(keys)} got other ({op})");
            });
            System.Action<Tx, List<object>, Op?> NodeEnded(string what) =>
                (t, keys, op) =>
                    t.Write(dragStatus, $"{what} {KeyWord(keys)} drag ended {Word(op)}");
            tx.OnDragEnded(itemLabel, NodeEnded("item"));
            tx.OnDragEnded(rowLabel, NodeEnded("row"));
            // The moved row's key rides as the kaya-private custom
            // representation; the anchor is the row it landed on (D8).
            tx.OnDrop(list, (t, d) =>
            {
                if (d.Clip is not Representation.Custom moved || d.Anchor.Count == 0
                    || d.Anchor[0] is not string anchor)
                    return;
                var key = Encoding.UTF8.GetString(moved.Bytes);
                if (d.Before)
                    items.MoveBefore(t, key, anchor);
                else
                    items.MoveAfter(t, key, anchor);
            });

            foreach (var key in new[] { "a", "b", "c" })
                items.Insert(tx, key, new DndItem(key));
            foreach (var key in new[] { "x", "y" })
                items2.Insert(tx, key, new DndItem(key));
        });

        System.Environment.Exit(app.Run());
    }
}
