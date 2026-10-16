// The grounds scene, C# port — guests/rust/grounds.rs, tools/scenes/grounds.steps.

static class GroundsScene
{
    public static void Run()
    {
        var app = new KayaApp();
        app.Build(tx =>
        {
            tx.Window(title: "grounds", width: 480, height: 560);
            byte[] art;
            using (var asset = tx.Asset("covers/cover-600.jpg")) art = asset.Bytes();
            var colour = Kaya.ImageDominant(art)
                ?? throw new System.InvalidOperationException("the cover decodes");
            var title = tx.Signal("Kind of Blue");
            var artist = tx.Signal("Miles Davis · 1959");
            var name = tx.Signal("Miles Davis");
            var plain = tx.Signal("Plain");
            tx.Mount(tx.Column(root =>
            {
                tx.Column(header =>
                {
                    tx.SetA11yId(tx.Heading(bind: title), "title");
                    tx.Caption(bind: artist);
                    tx.SetA11yId(header, "header");
                }, inset: 24, groundGradient: colour);
                tx.Column(hero =>
                {
                    tx.Row(scrim =>
                    {
                        tx.Label(bind: name);
                        tx.SetA11yId(scrim, "scrim");
                    }, filled: Tint.Overlay);
                    tx.SetA11yId(hero, "hero");
                }, inset: 24, groundImage: art);
                tx.Column(column =>
                {
                    tx.Label(bind: plain);
                    tx.SetA11yId(column, "plain");
                }, inset: 24);
                return root;
            }, spacing: 12));
        });
        System.Environment.Exit(app.Run());
    }
}
