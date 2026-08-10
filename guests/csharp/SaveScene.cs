// The save conformance scene, C# port — the ROUND TRIP an editor
// actually walks (docs/save-plan.md D5), which is open, edit, save,
// save-as, reopen.
//
// WHAT THIS PROVES, and why none of it is about a dialog closing:
//
// 1. **Save-back works.** Writing through the handle the OPEN picker
//    handed over — the thing DESIGN.md has claimed since the picker
//    landed and that no scene, leg or test drove until this one. In C#
//    the claim is sharper than elsewhere: Java's binding returned a
//    read-only stream in every mode for months because nobody wrote
//    through a picked handle, and this file is what would have caught
//    the same defect here.
// 2. **A save destination is openable at all.** A save dialog on this
//    platform answers with a name for a file NOBODY HAS MADE (measured:
//    exists=false after a clean Save), so opening it would fail with
//    "No such file or directory" for a file the user just named. The
//    core's save destination creates; docs/save-plan.md D1 is the
//    decision and step 5 is where it shows.
// 3. **The two files stay different.** The last step reopens BOTH
//    handles and reports both contents, so a save-as that quietly wrote
//    back into the ORIGINAL — the plausible bug, since the guest holds
//    two handles that look alike — fails there and nowhere else.
// 4. **Cancel is nothing, and the dialog id retires.** The scene shows a
//    save dialog, cancels it, and shows another. A cancel that leaked
//    the live slot would fail the second show.
//
// THE STRINGS ARE BYTE-FROZEN and compared identically on every lane, so
// they carry the CONTENT rather than a verdict: "saved second draft" is
// what came back off the disk, not what the guest hoped it wrote. Every
// status here is a read-back — write, reopen, read, report.
//
// THE WORK RUNS OFF THE APP THREAD, which is what Open tells every
// caller to do: it blocks, and a cloud provider may download the whole
// file first. The parking dance that PROVES the thread hop belongs to
// the filedialog scene and is not repeated here — this one owns the
// round trip.
//
// NO EXTENSIONS ON THE NAMES, deliberately. A save panel publishes its
// name field with a known extension HIDDEN when the user's Finder
// preference says so, which would make expect_save_dialog read the stem
// on one machine and the whole name on another. A name with no extension
// has no stem to differ from, on any platform.
//
// THE DESTINATION IS READ BACK THROUGH THE HANDLE, never through
// LocalPath: that is empty on both phones, where a picked document has
// no re-openable name at all.
//
// See guests/rust/save.rs and tools/scenes/save.steps.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;

static class SaveScene
{
    /// Read a handle back through kaya, with .NET's own file API. THE
    /// READ-BACK IS THE ASSERTION in every step of this scene: a write
    /// that returned without throwing and landed nowhere is exactly the
    /// failure "save" has, and only reopening can see it.
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
    /// afterwards. FileModeWrite truncates, on a picked file and on a
    /// save destination alike — the destination only adds the create.
    static string WriteBack(PickedFile file, string text)
    {
        FileStream stream;
        try
        {
            (stream, _) = file.Open(KayaWire.FileModeWrite);
        }
        catch (Exception e)
        {
            // THE FAILURE D1 EXISTS TO PREVENT reaches the label
            // verbatim: without the create, a save destination answers
            // here and the scene says so instead of saying "saved".
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

        // The file the scene opens, written before anything is shown,
        // plus the decoy the picker needs: with ONE file in the
        // directory a dialog completes with it when nothing is selected,
        // so `file_choose draft` would pass on a backend that never
        // selected anything. "decoy" sorts first, so that backend gets
        // the WRONG file and its five bytes fail the byte assertion too.
        //
        // Path.GetTempPath() is .NET's own answer to "where is temp",
        // which is what makes guest and interpreter agree on the
        // directory with no runner involvement — they are the same
        // process — and the pid keeps parallel legs from colliding.
        string dir = Path.Combine(
            Path.GetTempPath(),
            $"kaya-save-{System.Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "draft"), "first draft");
        File.WriteAllText(Path.Combine(dir, "decoy"), "decoy");

        // The two capabilities the scene carries: the file the user
        // OPENED, and the destination the user later NAMED. Held as
        // handles, never as paths — the phones have no re-openable path.
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
                    // The empty list IS cancel: nothing was chosen, so
                    // nothing is read and nothing is remembered.
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
                    // Cancel is null. Nothing was named, so nothing is
                    // written and NO DESTINATION IS REMEMBERED.
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

                // NO FILTER ON EITHER REQUEST, and on the save side that
                // is load-bearing rather than tidy: with allowed content
                // types set, a save panel APPENDS the first allowed
                // extension to an extension-less name, and the name this
                // scene types would come back changed.
                tx.Button("open", onClick: inner =>       // button#0
                    inner.PickFile(onResult: Picked));

                // SAVE-BACK NEEDS NO DIALOG. The user already chose this
                // file, and the handle they chose it with is writable —
                // the claim this button exists to drive.
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

                // BOTH, in order: the file that was opened must still
                // hold the save-back, and the destination must hold the
                // save-as. A save that went to the wrong handle passes
                // every earlier step and fails here.
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
