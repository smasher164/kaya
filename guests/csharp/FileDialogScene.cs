// The filedialog conformance scene, C# port — the picker's
// request/result grammar and the capability it hands back (DESIGN.md,
// File dialogs). The assertion goes all the way to the bytes.
//
// Open BLOCKS, so the read runs on a thread of the guest's own, and it
// PARKS between reading and posting: a guest that read inline is caught
// by `expect label#0 "reading"`, and one that read on the app thread
// wedges everything after.
//
// See guests/rust/filedialog.rs and tools/scenes/filedialog.steps.

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
        // The decoy must sort BEFORE picked.txt (docs/traps.md,
        // "Pressing Open with nothing selected still returns a file").
        File.WriteAllText(Path.Combine(dir, "picked.txt"), "picked bytes");
        File.WriteAllText(Path.Combine(dir, "decoy.txt"), "decoy");

        // The release gate: the app thread sets, the worker waits.
        var released = new ManualResetEventSlim(false);

        Signal status = default;
        app.Build(tx =>
        {
            tx.Window(title: "filedialog");
            status = tx.Signal("no file");

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
                        var (file, _) = files[0].Open(KayaWire.FileModeRead);
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

            tx.Mount(tx.Column(() =>
            {
                var label = tx.Label(bind: status); // label#0
                tx.SetA11yId(label, "status");
                tx.Button("open", onClick: inner =>
                    // Filters are ADVISORY on every platform, never a
                    // guarantee: a guest still validates what it got.
                    inner.PickFiles(
                        filters: new[] { ("Text", "txt") },
                        onResult: Picked));
                tx.Button("open one", onClick: inner =>
                    inner.PickFile(
                        filters: new[] { ("Text", "txt") },
                        onResult: Picked));
                tx.Button("release", onClick: _ => released.Set());
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
