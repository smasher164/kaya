// The document-tabs scene, C# port — guests/rust/doctabs.rs,
// tools/scenes/doctabs.steps (docs/doctabs-plan.md §5).

using System.Collections.Generic;
using System.Linq;

static class DoctabsScene
{
    const ulong A = 10, B = 11, C = 12, Notes = 30;
    static readonly Dictionary<ulong, string> Names = new() { [A] = "a", [B] = "b", [C] = "c" };

    public static void Run()
    {
        var app = new KayaApp();
        ulong untitled = 0, regions = 0;
        Signal status = default;

        // THE ONE BUILDER every window's shared region comes from, the first
        // window's and a torn-out one's alike (docs/doctabs-plan.md §1.2).
        void Region(Tx tx, ulong window, ulong id)
        {
            tx.AddRegion(id, RegionEdge.Leading, window);
            tx.MountIn(id, tx.Column(root =>
            {
                tx.SetA11yId(tx.Label(bind: status), "status");
                tx.SetA11yId(tx.Entry(), "note");
                tx.SetA11yId(tx.Button("to a", onClick: t => t.SelectDocument(A)), "first");
                return root;
            }));
        }

        app.Build(tx =>
        {
            status = tx.Signal("ready");
            tx.Window(title: "doctabs", width: 640, height: 420, newDocument: true,
                onNewDocument: t =>
                {
                    untitled++;
                    var name = $"untitled {untitled}";
                    var id = 100 + untitled;
                    t.AddDocument(id, title: name);
                    t.SelectDocument(id);
                    var caption = t.Signal($"{name} body");
                    t.MountIn(id, t.Column(root => { t.Label(bind: caption); return root; }));
                    t.Write(status, $"new {name}");
                },
                onDocumentsCloseRequested: (t, documents) => t.Write(status, $"asked about {documents.Count}"),
                onDocumentsDetached: (t, window, documents) =>
                {
                    regions++;
                    Region(t, window, 300 + regions);
                    var moved = documents.Select(d => Names.TryGetValue(d, out var n) ? n : "untitled");
                    t.Write(status, "detached " + string.Join(" ", moved));
                });

            foreach (var (id, name) in Names)
            {
                tx.AddDocument(id, title: name, tooltip: $"/documents/{name}",
                    interceptClose: id == B ? true : null,
                    onSelected: t => t.Write(status, $"selected {name}"),
                    onClosed: t => t.Write(status, $"closed {name}"),
                    onCloseRequested: id == B ? AskClose : null,
                    onMoved: (t, _, index) => t.Write(status, $"moved {name} to {index}"));
                var caption = tx.Signal($"{name} body");
                tx.MountIn(id, tx.Column(root =>
                {
                    tx.SetA11yId(tx.Label(bind: caption), $"body-{name}");
                    tx.SetA11yId(tx.Entry(), $"field-{name}");
                    if (id == B)
                        tx.SetA11yId(tx.Button("mark b", onClick: t =>
                        {
                            t.UpdateDocument(B, dirty: true);
                            t.Write(status, "marked b");
                        }), "mark");
                    return root;
                }));
            }
            Region(tx, 0, Notes);
            return status;
        });

        void AskClose(Tx tx) =>
            tx.ShowAlert(
                title: "unsaved changes", message: "b has unsaved changes",
                action0: "Discard", cancel: "Keep Editing",
                onResult: (inner, choice) =>
                {
                    if (choice == AlertChoice.Cancel)
                    {
                        inner.Write(status, "kept b");
                        return;
                    }
                    inner.CloseDocument(B);
                    inner.Write(status, "discarded b");
                });

        System.Environment.Exit(app.Run());
    }
}
