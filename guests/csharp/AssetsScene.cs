// The assets conformance scene, C# port (docs/assets-plan.md, ratified
// 2026-08-18). The byte-frozen contract is tools/scenes/assets.steps.
//
// THIS ONE PROVES THE BYTES. tx.Asset(name) has two redemptions and the
// typeface scene already covers the other — a font whose bytes go from
// the core's read straight to the platform and never enter the CLR's
// heap. Here the guest IS the consumer: it copies the mark out with
// Bytes() and hands the array to an Image, and the platform's own
// decoder answers 64x64 off the real view.
//
// THE MISS IS A QUESTION, NOT A catch. AssetMissSentence answers the
// same sentence tx.Asset would throw with, without throwing, and that is
// the only shape all nine share — the C floor catches nothing at all
// (docs/deferred.md, the assets entry).
//
// LINE 1 ONLY. Line 2 of that sentence names the place the core resolved
// and the route that chose it, which a bundle, a device directory and a
// repo checkout spell three different ways; line 1 is the same
// everywhere, so it is the line a scene can freeze.

using System;
using System.Globalization;

static class AssetsScene
{
    // The asset that is deliberately not there. A LEGAL name —
    // relative, /-spelled, one component deep — so what comes back is
    // the census sentence and not a name-fault one.
    const string Missing = "icons/nope.png";

    // The one the mark is under, and the one the census must list.
    const string Mark = "icons/kaya-mark.png";

    // The large asset: 111400 bytes, so a reader that truncated into a
    // fixed buffer shows up here rather than passing quietly.
    const string Font = "fonts/sora-wght.ttf";

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "assets", width: 480, height: 360);

            using var mark = tx.Asset(Mark);
            using var font = tx.Asset(Font);

            string census = FirstLine(tx.AssetMissSentence(Missing));
            string complaint = tx.AssetMissSentence(Font);
            // Never "no complaint" on a healthy lane's other arm, and it
            // shows the sentence rather than a word about it.
            string verdict = complaint.Length == 0 ? "no complaint" : FirstLine(complaint);

            var title = tx.Signal("assets");
            var found = tx.Signal(census);
            // InvariantCulture on purpose: the scene compares this
            // string byte-for-byte against seven other languages, and
            // the machine's culture is not part of that contract.
            var sizes = tx.Signal(
                Font + ": " + font.Length.ToString(CultureInfo.InvariantCulture)
                + " bytes, " + verdict);

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: title);  // label#0
                // THE BYTES, not the blob handle: this scene is the
                // consumer.
                tx.Image(mark.Bytes()); // image#0
                tx.Label(bind: found);  // label#1
                tx.Label(bind: sizes);  // label#2
            }));
        });

        Environment.Exit(app.Run());
    }

    // The census half of the sentence. Empty in, empty out.
    static string FirstLine(string sentence)
    {
        int at = sentence.IndexOf('\n');
        return at < 0 ? sentence : sentence.Substring(0, at);
    }
}
