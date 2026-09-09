// The assets scene, C# port — guests/rust/assets.rs,
// tools/scenes/assets.steps.

using System;
using System.Globalization;

static class AssetsScene
{
    // Deliberately absent, and a LEGAL name: the answer is the census sentence.
    const string Missing = "icons/nope.png";

    const string Mark = "icons/kaya-mark.png";

    // SCENERY, and deliberately tiny: an image widget's intrinsic size drives
    // layout and the DECLARED mark is a user-supplied source of any size
    // (the images/ family's README). The mark is still opened.
    const string Picture = "images/a11y-logo.png";

    // 111400 bytes, so a reader that truncated into a fixed buffer shows here.
    const string Font = "fonts/sora-wght.ttf";

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "assets", width: 480, height: 360);

            using var mark = tx.Asset(Mark);
            using var picture = tx.Asset(Picture);
            using var font = tx.Asset(Font);

            string census = FirstLine(tx.AssetMissSentence(Missing));
            string complaint = tx.AssetMissSentence(Font);
            string verdict = complaint.Length == 0 ? "no complaint" : FirstLine(complaint);

            var title = tx.Signal("assets");
            var found = tx.Signal(census);
            // InvariantCulture: compared byte-for-byte against eight languages.
            var sizes = tx.Signal(
                Mark + (mark.Length > 0 ? " present, " : " missing, ")
                + Font + ": " + font.Length.ToString(CultureInfo.InvariantCulture)
                + " bytes, " + verdict);

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: title);  // label#0
                tx.Image(picture.Bytes()); // image#0
                tx.Label(bind: found);  // label#1
                tx.Label(bind: sizes);  // label#2
            }));
        });

        Environment.Exit(app.Run());
    }

    static string FirstLine(string sentence)
    {
        int at = sentence.IndexOf('\n');
        return at < 0 ? sentence : sentence.Substring(0, at);
    }
}
