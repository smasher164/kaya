// The filedialog scene, C# port — guests/rust/filedialog.rs,
// tools/scenes/filedialog.steps.

using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

static class FileDialogScene
{
    public static void Run()
    {
        var app = new KayaApp();

        string dir = Path.Combine(
            Path.GetTempPath(),
            $"kaya-picked-{System.Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        // The decoy must sort BEFORE picked.txt (docs/traps.md, "Pressing
        // Open with nothing selected still returns a file").
        File.WriteAllText(Path.Combine(dir, "picked.txt"), "picked bytes");
        File.WriteAllText(Path.Combine(dir, "decoy.txt"), "decoy");

        var released = new ManualResetEventSlim(false);

        var status = app.Build(tx =>
        {
            tx.Window(title: "filedialog");
            var status = tx.Signal("no file");

            void Picked(Tx tx, List<PickedFile> files)
            {
                if (files.Count == 0)
                {
                    tx.Write(status, "cancelled");
                    return;
                }
                var thread = new Thread(() =>
                {
                    string text;
                    try
                    {
                        var (file, _) = files[0].Open(FileAccess.Read);
                        using (file)
                        using (var reader = new StreamReader(file))
                            text = reader.ReadToEnd();
                    }
                    catch (Exception e)
                    {
                        text = "open failed: " + e.Message;
                    }
                    released.Wait();
                    int count = files.Count;
                    app.Post(inner => inner.Write(status, $"{count} {text}"));
                })
                { Name = "filedialog-reader", IsBackground = true };
                thread.Start();
                // The handler RETURNED without reading.
                tx.Write(status, "reading");
            }

            tx.Mount(tx.Column(root =>
            {
                var label = tx.Label(bind: status); // label#0
                tx.SetA11yId(label, "status");
                tx.Button("open", onClick: async _ =>
                {
                    var files = await app.PickFilesAsync(filters: new[] { ("Text", "txt") });
                    app.Build(tx => Picked(tx, files));
                });
                tx.Button("open one", onClick: async _ =>
                {
                    var files = await app.PickFileAsync(filters: new[] { ("Text", "txt") });
                    app.Build(tx => Picked(tx, files));
                });
                tx.Button("release", onClick: _ => released.Set());
                return root;
            }));
            return status;
        });

        System.Environment.Exit(app.Run());
    }
}
