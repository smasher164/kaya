// The drag-and-drop scene, C# port — guests/rust/dnd.rs,
// tools/scenes/dnd.steps. THE ROOT IS A ROW so column#0 is the
// reorderable For's container.

using System.Collections.Generic;
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

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var items = DndItemKaya.Collection(tx);
            var dropStatus = tx.Signal("no drop yet");
            var dragStatus = tx.Signal("no drag yet");
            var sourceText = tx.Signal("hello");
            var textTarget = tx.Signal("text target");
            var noteTarget = tx.Signal("note target");
            var filesTarget = tx.Signal("files target");

            Widget source = default, textId = default, noteId = default, list = default;
            tx.Window(title: "dnd");
            tx.Mount(tx.Row(() =>
            {
                list = tx.Each(items.Collection, t =>
                {
                    var row = new DndItemRow(t);
                    row.SetA11yId(row.Label(row.Title), "row");
                });
                tx.Column(() =>
                {
                    source = tx.Label(bind: sourceText);  // label#0
                    textId = tx.Label(bind: textTarget);  // label#1
                    tx.SetAccepts(textId, Tx.AcceptText);
                    tx.SetDropTarget(textId, Op.Copy);
                    noteId = tx.Label(bind: noteTarget);  // label#2
                    tx.SetAccepts(noteId, NoteId);
                    tx.SetDropTarget(noteId, Op.Copy, Op.Move);
                    var filesId = tx.Label(bind: filesTarget);  // label#3
                    tx.SetAccepts(filesId, Tx.AcceptFiles);
                    tx.SetDropTarget(filesId, Op.Copy);
                    tx.Label(bind: dropStatus);  // label#4
                    tx.Label(bind: dragStatus);  // label#5
                });
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
            tx.OnDragEnded(source, (t, op) =>
                t.Write(dragStatus, $"drag ended {Word(op)}"));
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
        });

        System.Environment.Exit(app.Run());
    }
}
