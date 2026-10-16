// The shapes scene, C# port — guests/rust/shapes.rs, tools/scenes/shapes.steps.

[KayaGen]
record AvatarPerson(string Name, byte[] Face, ImagePhase Phase);

static class ShapesScene
{
    public static void Run()
    {
        var app = new KayaApp();
        app.Build(tx =>
        {
            tx.Window(title: "shapes", width: 420, height: 360);
            byte[] art, photo;
            using (var asset = tx.Asset("covers/cover-600.jpg")) art = asset.Bytes();
            using (var asset = tx.Asset("images/photo.jpg")) photo = asset.Bytes();
            var people = AvatarPersonKaya.Collection(tx);
            tx.Mount(tx.Column(root =>
            {
                tx.Row(_ =>
                {
                    foreach (var (id, shape) in new[] { ("rect", Shape.Rect), ("rounded", Shape.Rounded), ("circle", Shape.Circle) })
                    {
                        var bytes = tx.Signal(art);
                        tx.SetA11yId(tx.Image(bind: bytes, maxWidth: 48, maxHeight: 48, fit: Fit.Cover, shape: shape), id);
                    }
                    var wide = tx.Signal(photo);
                    tx.SetA11yId(tx.Image(bind: wide, maxWidth: 48, maxHeight: 48, shape: Shape.Circle), "wide");
                }, spacing: 16);
                AvatarPersonKaya.Each(tx, people, row =>
                {
                    row.Row(() =>
                    {
                        var face = row.Image(row.Face);
                        row.SetFit(face, Fit.Cover);
                        row.SetMaxWidth(face, 48);
                        row.SetMaxHeight(face, 48);
                        row.SetPhase(face, row.Phase);
                        row.SetShape(face, Shape.Circle);
                        row.SetA11yId(face, "avatar");
                        row.Label(row.Name);
                    });
                });
                return root;
            }, spacing: 16));
            people.Insert(tx, "a1", new AvatarPerson("Ada", System.Array.Empty<byte>(), ImagePhase.Loading));
        });
        System.Environment.Exit(app.Run());
    }
}
