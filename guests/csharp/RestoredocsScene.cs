// The restored shape, C# port — guests/rust/restoredocs.rs,
// tools/scenes/restoredocs.steps (docs/restoration-plan.md SR9).

using System.Collections.Generic;
using System.Linq;

static class RestoredocsScene
{
    public static void Run()
    {
        var app = new KayaApp();
        var primary = KayaApp.RestoredWindows().Where(w => w.Id == 0).ToList();
        IReadOnlyList<ulong> documents;
        ulong active = 0;
        if (primary.Count == 0)
        {
            documents = [10, 11, 12];
            foreach (var (id, title) in documents.Zip(new[] { "a", "b", "c" }))
                KayaApp.DocumentSession(id).SetString("title", title);
        }
        else
        {
            documents = primary[0].Documents;
            active = primary[0].ActiveDocument;
        }

        app.Build(tx =>
        {
            tx.Window(title: "restoredocs", width: 640, height: 420);
            foreach (var id in documents)
            {
                var scope = KayaApp.DocumentSession(id);
                var title = scope.GetString("title", "untitled");
                tx.AddDocument(id, title: title, restore: id);
                var caption = tx.Signal($"{title} body");
                tx.MountIn(id, tx.Column(root =>
                {
                    tx.SetA11yId(tx.Label(bind: caption), $"caption-{title}");
                    var field = tx.Entry(onChange: (_, text) =>
                        KayaApp.DocumentSession(id).SetString("body", text));
                    tx.SetA11yId(field, $"body-{title}");
                    tx.SetText(field, scope.GetString("body", ""));
                    tx.SetA11yId(tx.Button("recall", onClick: t =>
                        t.Write(caption, KayaApp.DocumentSession(id).GetString("title", "untitled") + " body")),
                        $"recall-{title}");
                    return root;
                }));
            }
            if (active != 0) tx.SelectDocument(active);
        });

        System.Environment.Exit(app.Run());
    }
}
