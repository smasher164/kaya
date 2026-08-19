// The clipboard conformance scene, C# port — one clip in several
// representations, and the privileged read that takes one back
// (DESIGN.md, Clipboard; docs/clipboard-plan.md). Canonical semantics in
// guests/rust/clipboard.rs; the byte-frozen contract in
// tools/scenes/clipboard.steps.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

static class ClipboardScene
{
    // A real 4x4 PNG: a foreign decoder asserts its size, so this must
    // stay a valid encoded image.
    static readonly byte[] PixelPng =
    {
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, // 4 x 4
        0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09, // 8-bit rgb + crc
        0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41, // IDAT length + type
        0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x47, 0x48, 0x4C, 0x74, 0xDE, 0x7F, 0x24, 0x00,
        0x00, 0xD2, 0x6F, 0x17, 0xE9, 0x51, 0xBB, 0x23,
        0x2D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82, // IEND + crc
};

    // Reverse-DNS and space-free: this id reaches every platform's own
    // registry VERBATIM (UTI, RegisterClipboardFormat, X11 target atom,
    // Android MIME type).
    const string NoteId = "dev.kaya/note";

    // No quotes in the payload: the step grammar escapes \n, \r and \\
    // only, so a quoted byte could not be spelled in the expectation.
    static readonly byte[] NoteBytes = Encoding.UTF8.GetBytes("note=1");

    public static void Run()
    {
        var app = new KayaApp();

        // Guest and interpreter are one process and compute this path
        // identically; the pid keeps parallel legs from colliding.
        string dir = Path.Combine(
            Path.GetTempPath(),
            "kaya-clip-" + Process.GetCurrentProcess().Id);
        Directory.CreateDirectory(dir);
        File.WriteAllBytes(Path.Combine(dir, "pixel.png"), PixelPng);
        File.WriteAllText(Path.Combine(dir, "pasted.txt"), "pasted bytes");

        Signal status = default;
        Signal rowStatus = default;
        Widget rich = default;
        Widget plain = default;

        app.Build(tx =>
        {
            var edit = tx.Menu("Edit", items: new[]
            {
                tx.Item("Cut", role: Tx.RoleCut),
                tx.Item("Copy", role: Tx.RoleCopy),
                tx.Item("Paste", role: Tx.RolePaste),
            });
            tx.Window(title: "clipboard", menus: new[] { edit });

            status = tx.Signal("ready");
            rowStatus = tx.Signal("");

            void Answered(Tx tx, Representation? clip)
            {
                switch (clip)
                {
                    // Empty is the universal no: denied, unfocused,
                    // absent or unaccepted, and no platform says which.
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
                            // Open BLOCKS, so never on the app thread.
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
                    // One clip, four representations: kaya derives none
                    // of them from any other, so the app spells each.
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

                rich = tx.Entry(); // entry#0
                tx.SetAccepts(rich, Tx.AcceptText);
                tx.SetA11yId(rich, "rich");
                tx.OnPaste(rich, (inner, clip) =>
                {
                    if (clip is Representation.Text t)
                    {
                        inner.Write(status, "pasted " + t.Value);
                        return;
                    }
                    inner.Write(status, "pasted " + clip);
                });

                plain = tx.Entry(); // entry#1
                tx.SetA11yId(plain, "plain");

                // A stamped paste target: the accept list comes from the
                // TEMPLATE, and the paste arrives as an instance
                // occurrence carrying the copy's key.
                tx.SetA11yId(tx.Label(bind: rowStatus), "row-status"); // label#1
                var rows = tx.Collection();
                tx.Each(rows, t =>
                {
                    var field = t.Entry(); // entry#2 once r1 stamps
                    t.SetAccepts(field, Tx.AcceptText);
                    tx.OnPaste(field, (inner, keys, clip) =>
                    {
                        // The key path rides the payload, outermost first.
                        string key = (string)keys[0];
                        if (clip is Representation.Text t2)
                        {
                            inner.Write(rowStatus, $"row {key} pasted {t2.Value}");
                            return;
                        }
                        inner.Write(rowStatus, $"row {key} pasted {clip}");
                    });
                });
                tx.Insert(rows, "r1", "");
            }));
        });

        Environment.Exit(app.Run());
    }
}
