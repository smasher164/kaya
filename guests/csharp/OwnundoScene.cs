// The app-owned undo scene, C# port — guests/rust/ownundo.rs,
// tools/scenes/ownundo.steps (docs/rich-text-plan.md R6, §14).

using System;
using System.Collections.Generic;

static class OwnundoScene
{
    public static void Run()
    {
        var app = new KayaApp();

        // `Publish` and the menu items both name these, and the menu is
        // built before the textarea its handlers write: a forward
        // reference, not a container body smuggling its result out.
        Signal status = default;
        Widget native = default, owned = default;

        // The app's own history: the document before each user edit, and
        // the documents an undo took away. The binding's mirror is the
        // document AFTER the edit it just delivered.
        var undo = new List<Document>();
        var redo = new List<Document>();
        var current = new Document("");

        void Publish(Tx t)
        {
            t.Write(status, $"undo {undo.Count} redo {redo.Count}");
            t.CanUndo(owned, undo.Count > 0);
            t.CanRedo(owned, redo.Count > 0);
        }

        void Undo(Tx t)
        {
            if (undo.Count == 0) return;
            Document before = undo[undo.Count - 1];
            undo.RemoveAt(undo.Count - 1);
            redo.Add(current);
            current = before;
            t.SetDocument(owned, before);
            Publish(t);
        }

        void Redo(Tx t)
        {
            if (redo.Count == 0) return;
            Document after = redo[redo.Count - 1];
            redo.RemoveAt(redo.Count - 1);
            undo.Add(current);
            current = after;
            t.SetDocument(owned, after);
            Publish(t);
        }

        app.Build(tx =>
        {
            var edit = tx.Menu("Edit", items: new[]
            {
                tx.Item("Undo", role: MenuRole.Undo, onActivate: Undo),
                tx.Item("Redo", role: MenuRole.Redo, onActivate: Redo),
            });
            tx.Window(title: "ownundo", menus: new[] { edit });
            status = tx.Signal("undo 0 redo 0");

            tx.Mount(tx.Column(root =>
            {
                tx.SetA11yId(tx.Label(bind: status), "status");       // label#0
                native = tx.Textarea(rich: true);                     // textarea#0
                tx.SetA11yId(native, "native");
                tx.SetA11yLabel(native, "Native");
                owned = tx.Textarea(rich: true, ownUndo: true);       // textarea#1
                tx.SetA11yId(owned, "owned");
                tx.SetA11yLabel(owned, "Owned");
                app.OnEdit(owned, (t, _) =>
                {
                    undo.Add(current);
                    current = app.Document(owned);
                    redo.Clear();
                    Publish(t);
                });

                tx.Row(_ =>
                {
                    tx.Button("focus native", onClick: t => t.Focus(native)); // button#0
                    tx.Button("focus owned", onClick: t => t.Focus(owned));   // button#1
                });
                return root;
            }));
        });

        Environment.Exit(app.Run());
    }
}
