// The save conformance scene, C# port — the round trip an editor walks:
// open, edit, save, save-as, reopen. What it proves and why is
// docs/save-plan.md §0 and D1/D3/D5.
//
// Every status is a READ-BACK off the disk, and every file operation
// runs off the app thread because Open blocks. A destination is read
// back through the HANDLE, never LocalPath — that is empty on both
// phones. The names carry no extension and neither request sends a
// filter (docs/deferred.md: NSSavePanel appends the first allowed
// extension, and a Finder preference can hide a known one).
//
// See guests/rust/save.rs and tools/scenes/save.steps.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;

static class SaveScene
{
    /// Read a handle back through kaya, with .NET's own file API.
    static string ReadBack(PickedFile file)
    {
        FileStream stream;
        try
        {
            (stream, _) = file.Open(KayaWire.FileModeRead);
        }
        catch (Exception e)
        {
            return "open failed: " + e.Message;
        }
        try
        {
            using (stream)
            using (var reader = new StreamReader(stream, Encoding.UTF8))
                return reader.ReadToEnd();
        }
        catch (Exception e)
        {
            return "read failed: " + e.Message;
        }
    }

    /// Write text through a handle and report what the FILE says
    /// afterwards. FileModeWrite truncates on a picked file and on a
    /// save destination alike; the destination only adds the create.
    static string WriteBack(PickedFile file, string text)
    {
        FileStream stream;
        try
        {
            (stream, _) = file.Open(KayaWire.FileModeWrite);
        }
        catch (Exception e)
        {
            return "save failed: " + e.Message;
        }
        try
        {
            // Bytes rather than a StreamWriter, so no encoder preamble
            // can put a BOM in front of a byte-frozen string.
            byte[] bytes = Encoding.UTF8.GetBytes(text);
            using (stream)
                stream.Write(bytes, 0, bytes.Length);
            // Disposed before the reopen, so what comes back is the
            // FILE's bytes and not a buffer's.
        }
        catch (Exception e)
        {
            return "write failed: " + e.Message;
        }
        return ReadBack(file);
    }

    public static void Run()
    {
        var app = new KayaApp();

        // Guest and interpreter are one process and compute this path
        // identically; the pid keeps parallel legs from colliding. The
        // decoy must sort BEFORE "draft" (docs/traps.md, "Pressing Open
        // with nothing selected still returns a file").
        string dir = Path.Combine(
            Path.GetTempPath(),
            $"kaya-save-{System.Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "draft"), "first draft");
        File.WriteAllText(Path.Combine(dir, "decoy"), "decoy");

        // Held as handles, never as paths — the phones have no
        // re-openable path.
        PickedFile? source = null;
        PickedFile? destination = null;

        Signal status = default;

        // Every file operation runs on a thread of the guest's own,
        // because Open blocks; the answer comes back through Post, the
        // one method safe to call from another thread.
        void Work(Func<string> job)
        {
            var thread = new Thread(() =>
            {
                string text = job();
                app.Post(inner => inner.Write(status, text));
            })
            { Name = "save-worker", IsBackground = true };
            thread.Start();
        }

        app.Build(tx =>
        {
            tx.Window(title: "save");
            status = tx.Signal("no file");

            void Picked(Tx inner, List<PickedFile> files)
            {
                if (files.Count == 0)
                {
                    // The empty list IS cancel.
                    inner.Write(status, "open cancelled");
                    return;
                }
                var file = files[0];
                source = file;
                Work(() => "opened " + ReadBack(file));
            }

            void Saved(Tx inner, PickedFile? file)
            {
                if (file == null)
                {
                    // Cancel is null, and no destination is remembered.
                    inner.Write(status, "save cancelled");
                    return;
                }
                var dest = file.Value;
                destination = dest;
                Work(() => "saved " + WriteBack(dest, "third draft"));
            }

            tx.Mount(tx.Column(() =>
            {
                var label = tx.Label(bind: status); // label#0
                tx.SetA11yId(label, "status");

                tx.Button("open", onClick: inner =>       // button#0
                    inner.PickFile(onResult: Picked));

                tx.Button("save", onClick: _ =>           // button#1
                {
                    var file = source ?? throw new InvalidOperationException(
                        "kaya: the scene opens a file before saving");
                    Work(() => "saved " + WriteBack(file, "second draft"));
                });

                // "copy" is the name the dialog OPENS with; the harness
                // types over it, which is what a save dialog is for.
                tx.Button("save as", onClick: inner =>    // button#2
                    inner.SaveFile("copy", onResult: Saved));

                // Both handles, in order: source first, destination second.
                tx.Button("reopen", onClick: _ =>         // button#3
                {
                    var first = source ?? throw new InvalidOperationException(
                        "kaya: the scene opens a file");
                    var second = destination ?? throw new InvalidOperationException(
                        "kaya: the scene saves as");
                    Work(() => $"reopened {ReadBack(first)} {ReadBack(second)}");
                });
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
