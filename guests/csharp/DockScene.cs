// The dock scene, C# port — guests/rust/dock.rs, tools/scenes/dock.steps.

static class DockScene
{
    public static void Run()
    {
        var app = new KayaApp();
        app.Build(tx =>
        {
            byte[] art;
            using (var asset = tx.Asset("covers/cover-600.jpg")) art = asset.Bytes();
            var playing = tx.Signal(true);
            tx.Window(title: "dock", width: 720, height: 480);
            var player = tx.Player(muted: true);
            tx.Dock(40, player: player, body: () => tx.Column(root =>
            {
                tx.When(playing, t =>
                {
                    var bar = t.Row(() =>
                    {
                        var image = t.Image(art);
                        t.SetFit(image, Fit.Cover);
                        t.SetMaxWidth(image, 40);
                        t.SetMaxHeight(image, 40);
                        t.SetShape(image, Shape.Rounded);
                        t.Column(() =>
                        {
                            t.Label("Blue in Green");
                            t.Caption("Miles Davis");
                        });
                        t.SetA11yId(t.Slider(0, 1, 0.4), "progress");
                        t.SetA11yId(t.Button("Pause"), "pause");
                    });
                    t.SetA11yId(bar, "bar");
                });
                return root;
            }));
            var library = tx.Signal("Library");
            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: library);
                tx.SetA11yId(tx.Button("stop", t => t.Write(playing, false)), "stop");
                tx.SetA11yId(tx.Button("play", t => t.Write(playing, true)), "play");
                return root;
            }));
        });
        System.Environment.Exit(app.Run());
    }
}
