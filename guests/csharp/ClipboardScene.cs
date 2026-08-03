// The clipboard conformance scene, C# port — one clip in several
// representations, and the privileged read that takes one back
// (DESIGN.md, Clipboard; docs/clipboard-plan.md).
//
// EVERY ASSERTION CROSSES A PROCESS BOUNDARY, which is the whole design
// of this scene. kaya's representation set is closed because the
// LOWERINGS are the hard part — CF_HTML's mandatory offset header,
// Android's content:// URI for an image, CF_HDROP's double-NUL struct —
// and a check where kaya reads what kaya wrote parses its own malformed
// header perfectly happily. That is not merely less coverage: it is a
// check that cannot fail for the reason the design exists.
//
// THE ONE EXCEPTION IS THE CUSTOM FORMAT, deliberately. No stock tool
// on any platform writes an app-defined type, so the guest copies one
// and reads it back, with the foreign reader confirming from outside
// that the bytes really are there under that id.
//
// THE IMAGE IS ASSERTED AS A DECODED SIZE, never as bytes: every host
// re-encodes freely between image types, so a byte count would be a
// different number on every lane for one picture.
//
// Canonical semantics in guests/rust/clipboard.rs; the byte-frozen
// contract in tools/scenes/clipboard.steps.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

static class ClipboardScene
{
    // A 4x4 PNG, spelled out rather than generated: the scene asserts
    // "4x4" through a foreign decoder, so the picture has to be a real
    // encoded image whose size is knowable from the script. Written to
    // disk for the seeding tool AND handed to Copy as bytes — the same
    // picture both ways.
    static readonly byte[] PixelPng =
    {
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, // 4 x 4
        0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09, // 8-bit rgb + crc
        0x29, 0x00, 0x00, 0x00, 0x1C, 0x49, 0x44, 0x41, // IDAT length + type
        0x54, 0x18, 0x57, 0x63, 0xFC, 0xCF, 0xC0, 0xF0,
        0x9F, 0x81, 0xE1, 0x3F, 0x03, 0xC3, 0x7F, 0x06,
        0x86, 0xFF, 0x0C, 0x0C, 0xFF, 0x19, 0x18, 0xFE,
        0x33, 0x30, 0x00, 0x00, 0x3D, 0x94, 0x07, 0xF9,
        0x8A, 0x2C, 0xEA, 0x84, 0x00, 0x00, 0x00, 0x00, // IEND length
        0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, // IEND + crc
    };

    // The app-defined format's id: reverse-DNS and space-free, because
    // it reaches every platform's own registry VERBATIM — a UTI on
    // Apple, RegisterClipboardFormat on Windows, a target atom on X11
    // and Wayland, a MIME type on Android.
    const string NoteId = "dev.kaya.note";

    // NO QUOTES IN THE PAYLOAD, and the reason is the script rather
    // than the clipboard: the step grammar's escapes are \n, \r and \\
    // in all three interpreters, with no \" — so a quoted byte could
    // not be spelled in the expectation.
    static readonly byte[] NoteBytes = Encoding.UTF8.GetBytes("note=1");

    public static void Run()
    {
        var app = new KayaApp();

        // Both halves compute this identically, the filedialog rule:
        // guest and interpreter are the same process, so they agree on
        // a path with no runner involvement, and the pid keeps parallel
        // legs from colliding. Path.GetTempPath() is .NET's OWN answer
        // to "where is temp", which is what makes the two halves agree
        // without either consulting the other.
        string dir = Path.Combine(
            Path.GetTempPath(),
            "kaya-clip-" + Process.GetCurrentProcess().Id);
        Directory.CreateDirectory(dir);
        File.WriteAllBytes(Path.Combine(dir, "pixel.png"), PixelPng);
        File.WriteAllText(Path.Combine(dir, "pasted.txt"), "pasted bytes");

        Signal status = default;
        Widget rich = default;
        Widget plain = default;

        app.Build(tx =>
        {
            // THE GESTURE LAYER'S DECLARATION, and an app writes nothing
            // else for it: the Paste command lowers to the platform's
            // own, acts on whatever is focused, and works out its own
            // enablement. kaya has no selection API, which is exactly
            // why copy of a selection has to be a command rather than
            // something an app assembles out of the data layer.
            var edit = tx.Menu("Edit", items: new[]
            {
                tx.Item("Cut", role: Tx.RoleCut),
                tx.Item("Copy", role: Tx.RoleCopy),
                tx.Item("Paste", role: Tx.RolePaste),
            });
            tx.Window(title: "clipboard", menus: new[] { edit });

            status = tx.Signal("ready");

            void Answered(Tx tx, Representation? clip)
            {
                switch (clip)
                {
                    // EMPTY IS THE UNIVERSAL NO, and the guest does not
                    // try to tell its four causes apart — denied,
                    // unfocused, absent, or nothing this read accepted.
                    // The platforms deliberately decline to say.
                    case null:
                        tx.Write(status, "empty");
                        break;
                    case Representation.Text t:
                        tx.Write(status, "text " + t.Value);
                        break;
                    case Representation.Html h:
                        tx.Write(status, "html " + h.Value);
                        break;
                    case Representation.Custom c:
                        tx.Write(status,
                            $"custom {c.Id} {Encoding.UTF8.GetString(c.Bytes)}");
                        break;
                    case Representation.Image img:
                        // STRAIGHT BACK OUT, because the assertion that
                        // matters is a foreign DECODER's: the byte count
                        // differs per host for one picture, and the
                        // decoded size does not.
                        tx.Copy().Image(img.Bytes).Send();
                        tx.Write(status, "image");
                        break;
                    case Representation.Files f:
                        if (f.Value.Count == 0)
                        {
                            tx.Write(status, "files none");
                            break;
                        }
                        var picked = f.Value[0];
                        var thread = new Thread(() =>
                        {
                            // OFF THE APP THREAD, which is what Open
                            // documents: it blocks, and a pasted file is
                            // no different from a picked one — it IS a
                            // picked one, the same capability arriving
                            // through a second door.
                            string text;
                            try
                            {
                                var (file, _) = picked.Open(KayaWire.FileModeRead);
                                using (file)
                                using (var reader = new StreamReader(file))
                                    text = reader.ReadToEnd();
                            }
                            catch (Exception e)
                            {
                                text = "open failed: " + e.Message;
                            }
                            app.Post(inner =>
                                inner.Write(status, $"files {picked.Name} {text}"));
                        })
                        { Name = "clipboard-reader", IsBackground = true };
                        thread.Start();
                        tx.Write(status, "reading");
                        break;
                }
            }

            tx.Mount(tx.Column(() =>
            {
                var label = tx.Label(bind: status); // label#0
                tx.SetA11yId(label, "status");
                tx.Button("copy", onClick: inner =>
                {
                    // ONE CLIP, FOUR REPRESENTATIONS. kaya derives none
                    // of them from any other: whether list bullets
                    // survive html-to-text is this app's decision, so it
                    // spells out both. The order they go on the wire is
                    // kaya's, not this chain's — descending richness,
                    // which is preference order on every host that has
                    // one.
                    inner.Copy()
                        .Text("kaya clip")
                        .Html("<b>kaya</b> clip")
                        .Image(PixelPng)
                        .Custom(NoteId, NoteBytes)
                        .Send();
                    inner.Write(status, "copied");
                }); // button#0
                tx.Button("read custom", onClick: inner =>
                    inner.ReadClipboard().Custom(NoteId).OnResult(Answered).Send());
                tx.Button("read text", onClick: inner =>
                    inner.ReadClipboard().Text().OnResult(Answered).Send());
                tx.Button("read image", onClick: inner =>
                    inner.ReadClipboard().Image().OnResult(Answered).Send());
                tx.Button("read files", onClick: inner =>
                    inner.ReadClipboard().Files().OnResult(Answered).Send());
                tx.Button("focus rich", onClick: inner => inner.Focus(rich));
                tx.Button("focus plain", onClick: inner => inner.Focus(plain));

                // DECLARES WHAT IT TAKES, so a paste lands in the hook
                // and this app decides what to do with it.
                rich = tx.Entry(); // entry#0
                tx.SetAccepts(rich, "text");
                tx.SetA11yId(rich, "rich");
                tx.OnPaste(rich, (inner, clip) =>
                {
                    // THE SAME SHAPE THE READ ANSWERS WITH, and free
                    // where the read is not: a gesture is its own
                    // authorisation, so no platform charges a prompt.
                    if (clip is Representation.Text t)
                    {
                        inner.Write(status, "pasted " + t.Value);
                        return;
                    }
                    inner.Write(status, "pasted " + clip);
                });

                // DECLARES NOTHING, so the platform's own insertion
                // happens and the field's ordinary change path reports
                // it — which is what a plain text editor gets for free.
                plain = tx.Entry(); // entry#1
                tx.SetA11yId(plain, "plain");
            }));
        });

        Environment.Exit(app.Run());
    }
}
