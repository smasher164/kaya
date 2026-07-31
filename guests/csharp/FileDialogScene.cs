// The filedialog conformance scene, C# port — the picker's
// request/result grammar and the capability it hands back (DESIGN.md,
// File dialogs).
//
// WHAT THIS PROVES, and why it goes all the way to the bytes: the
// design's whole claim is that kaya hands over a CAPABILITY and never
// moves the data. So the guest does not assert that a dialog closed —
// it opens the handle it was given, reads the file with an ORDINARY
// FileStream, and writes what it read into a signal. `expect label#0
// "1 picked bytes"` therefore fails unless a real descriptor came back
// carrying the real file.
//
// THE FILE IS THE GUEST'S OWN, written before anything is shown, so
// guest and interpreter agree on a path with no runner involvement —
// they are the same process. Path.GetTempPath() is .NET's own answer to
// "where is temp", which is what makes the two halves agree without
// either consulting the other.
//
// THE READ RUNS OFF THE APP THREAD, which is what Open tells every
// caller to do: it blocks, and a cloud provider may download the whole
// file before it returns.
//
// The parking is a plain ManualResetEventSlim and the worker a plain
// background thread. kaya supplies no waiting primitive and should not:
// the point is that a guest uses its own language's concurrency and
// hands back only the result. The worker PARKS between reading and posting,
// and only a click releases it, so a guest that read inline is caught
// by `expect label#0 "reading"` and one that did the work on the app
// thread wedges everything after.
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
        // THE DECOY IS LOAD-BEARING: with one file in the directory,
        // pressing Open with nothing selected returns that file, so
        // `file_choose picked.txt` would pass on a backend that ignored
        // the name entirely. Measured on GTK. "decoy" sorts before
        // "picked", so a backend that skips selection gets the WRONG
        // file, and its five bytes fail the byte assertion too.
        File.WriteAllText(Path.Combine(dir, "picked.txt"), "picked bytes");
        File.WriteAllText(Path.Combine(dir, "decoy.txt"), "decoy");

        // The release gate: the app thread sets, the worker waits. A
        // handler that blocked handing this over would fail the very
        // claim being tested, so Set does not wait for the receiver.
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
                    // The empty list IS cancel. Nothing to read, so no
                    // worker and no release.
                    tx.Write(status, "cancelled");
                    return;
                }
                var thread = new Thread(() =>
                {
                    // THE CLAIM, and it is made HERE rather than in the
                    // handler on purpose: the handle crossed a thread
                    // boundary, and it is redeemed and read with .NET's
                    // own file API on the thread that received it. kaya
                    // is not in this data path, and Open blocks.
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
                    // Parks holding the result, standing in for the
                    // tail of a slow transfer. Were this work running
                    // on the app thread, the release click could never
                    // be processed and the whole scene would deadlock.
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
                    // ADVISORY on every platform: a default view, never
                    // a guarantee, so a guest still validates what it
                    // got — which is what the read above does.
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
