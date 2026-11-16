// The layers scene, C# port — guests/rust/layers.rs, tools/scenes/layers.steps.

static class LayersScene
{
    public static void Run()
    {
        var app = new KayaApp();
        var log = new System.Collections.Generic.List<string> { "taps:" };
        app.Build(tx =>
        {
            tx.Window(title: "layers", width: 480, height: 860);
            byte[] cover, small;
            using (var asset = tx.Asset("covers/cover-600.jpg")) cover = asset.Bytes();
            using (var asset = tx.Asset("covers/cover-320.jpg")) small = asset.Bytes();
            var answered = tx.Signal("taps:");
            var veiled = tx.Signal(false);
            System.Action<Tx> Answer(string word) => t =>
            {
                log.Add(word);
                t.Write(answered, string.Join(" ", log));
                if (word == "hide") t.Write(veiled, true);
            };
            tx.Mount(tx.Column(root =>
            {
                tx.Layers(stack =>
                {
                    var photo = tx.Image(cover);
                    tx.SetMaxWidth(photo, 320);
                    tx.SetA11yLabel(photo, "Kind of Blue cover");
                    tx.SetA11yId(photo, "photo");
                    tx.Row(badge =>
                    {
                        tx.SetA11yId(tx.Label("3"), "badge_text");
                        tx.SetPlace(badge, Place.TopTrailing);
                        tx.SetA11yId(badge, "badge");
                    }, filled: Tint.Accent);
                    tx.Row(caption =>
                    {
                        var text = tx.Label("Kind of Blue");
                        tx.SetGrow(text, 1);
                        tx.SetA11yId(text, "caption_text");
                        tx.SetA11yId(tx.Button("Share", onClick: Answer("share")), "share");
                        tx.SetPlace(caption, Place.Bottom);
                        tx.SetA11yId(caption, "caption");
                    }, filled: Tint.OverlayFade);
                    tx.SetA11yId(stack, "photostack");
                }, inset: 8);
                tx.Layers(stack =>
                {
                    tx.SetA11yId(tx.Button("Press the base button here", onClick: Answer("base")), "base");
                    tx.Column(veil =>
                    {
                        tx.Row(_ => tx.Label("Busy"), filled: Tint.Overlay);
                        tx.SetFill(veil, true);
                        tx.SetHidden(veil, veiled);
                        tx.SetA11yId(veil, "busy");
                    }, align: Align.Center);
                    tx.SetA11yId(stack, "veilstack");
                });
                tx.Layers(stack =>
                {
                    tx.SetA11yId(tx.Button("Open the inbox", onClick: Answer("side")), "side");
                    tx.Row(badge =>
                    {
                        tx.Label("5");
                        tx.SetPlace(badge, Place.Trailing);
                        tx.SetA11yId(badge, "sidebadge");
                    }, filled: Tint.Accent);
                    tx.SetA11yId(stack, "sidestack");
                });
                tx.Layers(stack =>
                {
                    var photo = tx.Image(small);
                    tx.SetMaxWidth(photo, 200);
                    tx.SetA11yLabel(photo, "Small cover");
                    tx.SetA11yId(photo, "smallphoto");
                    tx.Row(flat =>
                    {
                        tx.SetA11yId(tx.Label("Flat panel"), "flat_text");
                        tx.SetPlace(flat, Place.TopLeading);
                        tx.SetA11yId(flat, "flat");
                    }, filled: Tint.Overlay);
                    tx.SetA11yId(stack, "flatstack");
                }, inset: 8);
                tx.SetA11yId(tx.Label(bind: answered), "answered");
                tx.SetA11yId(tx.Button("Hide the veil", onClick: Answer("hide")), "hideveil");
                return root;
            }, spacing: 16));
        });
        System.Environment.Exit(app.Run());
    }
}
