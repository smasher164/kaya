// The references scene, C# port — guests/rust/references.rs,
// tools/scenes/references.steps (docs/restoration-plan.md SR11, SR12).

using System;
using System.IO;
using System.Threading;

static class ReferencesScene
{
    public static void Run()
    {
        var app = new KayaApp();
        string dir = Path.Combine(Path.GetTempPath(), $"kaya-refs-{System.Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "picked.txt"), "picked bytes");
        File.WriteAllText(Path.Combine(dir, "decoy.txt"), "decoy");
        string saved = KayaApp.Session().GetString("doc", "");
        Signal status = default;

        // The bytes a token redeems for, or the refusal's branch; the sentence
        // goes to stderr, where the leg log keeps it.
        string ReadBack(string token)
        {
            try
            {
                var (file, _) = KayaApp.Redeem(token).File.Open(FileAccess.Read);
                using (file)
                using (var reader = new StreamReader(file))
                    return "redeemed: " + reader.ReadToEnd();
            }
            catch (ReferenceException e)
            {
                Console.Error.WriteLine($"references: {e.Message}");
                return e.Refusal;
            }
        }

        void Reader(string token) =>
            new Thread(() =>
            {
                var said = ReadBack(token);
                app.Post(t => t.Write(status, said));
            })
            { Name = "references-reader", IsBackground = true }.Start();

        app.Build(tx =>
        {
            tx.Window(title: "references");
            status = tx.Signal(saved == "" ? "no reference" : "redeeming");
            tx.Mount(tx.Column(root =>
            {
                tx.SetA11yId(tx.Label(bind: status), "status");
                tx.SetA11yId(tx.Button("pick", onClick: async _ =>
                {
                    var files = await app.PickFileAsync(filters: new[] { ("Text", "txt") });
                    app.Build(t =>
                    {
                        if (files.Count == 0)
                        {
                            t.Write(status, "cancelled");
                            return;
                        }
                        try
                        {
                            KayaApp.Session().SetString("doc", files[0].Reference());
                            KayaApp.Session().SetString("dir", dir);
                            t.Write(status, "minted");
                        }
                        catch (ReferenceException e)
                        {
                            Console.Error.WriteLine($"references: {e.Message}");
                            t.Write(status, e.Refusal);
                        }
                    });
                }), "pick");
                tx.SetA11yId(tx.Button("foreign", onClick: _ => Reader("kaya-ref1:beos:AAAA:00000000")),
                    "foreign");
                tx.SetA11yId(tx.Button("delete", onClick: _ =>
                {
                    File.Delete(Path.Combine(KayaApp.Session().GetString("dir", ""), "picked.txt"));
                    Reader(saved);
                }), "delete");
                return root;
            }));
        });
        if (saved != "") Reader(saved);

        System.Environment.Exit(app.Run());
    }
}
