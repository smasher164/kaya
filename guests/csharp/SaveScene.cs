// The save scene, C# port — guests/rust/save.rs, tools/scenes/save.steps.

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

    /// Write text through a handle and report what the FILE says afterwards.
    /// FileModeWrite truncates; a save destination only adds the create.
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
            // Bytes, not a StreamWriter: no encoder preamble may put a BOM in
            // front of a byte-frozen string.
            byte[] bytes = Encoding.UTF8.GetBytes(text);
            using (stream)
                stream.Write(bytes, 0, bytes.Length);
            // Disposed before the reopen, so the bytes are the FILE's.
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

        // The pid keeps parallel legs from colliding, and the decoy must sort
        // BEFORE "draft" (docs/traps.md, Open with nothing selected).
        string dir = Path.Combine(
            Path.GetTempPath(),
            $"kaya-save-{System.Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "draft"), "first draft");
        File.WriteAllText(Path.Combine(dir, "decoy"), "decoy");

        // Handles, never paths — the phones have no re-openable path.
        PickedFile? source = null;
        PickedFile? destination = null;

        Signal status = default;

        // Open blocks; Post is the one method safe from another thread.
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

                tx.Button("save", onClick: inner =>       // button#1
                {
                    // A missing handle gets its OWN sentence, never a throw: a
                    // crashed guest masks the real failure (docs/deferred.md,
                    // save-jvm WATCH).
                    if (source is not PickedFile file)
                    {
                        inner.Write(status, "nothing open to save");
                        return;
                    }
                    Work(() => "saved " + WriteBack(file, "second draft"));
                });

                // "copy" is the name the dialog OPENS with; the harness types over it.
                tx.Button("save as", onClick: inner =>    // button#2
                    inner.SaveFile("copy", onResult: Saved));

                tx.Button("reopen", onClick: inner =>     // button#3
                {
                    if (source is not PickedFile first
                        || destination is not PickedFile second)
                    {
                        inner.Write(status, "nothing to reopen");
                        return;
                    }
                    Work(() => $"reopened {ReadBack(first)} {ReadBack(second)}");
                });
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
