// The grid conformance scene, C# port. See
// guests/rust/grid.rs and tools/scenes/grid.steps.

static class GridScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "grid");
            tx.Mount(tx.Column(() =>
            {
                tx.Grid(2, () =>
                {
                    tx.Label("Name:"); // label#0
                    tx.Label("Ada Lovelace"); // label#1
                    tx.Label("Role:"); // label#2
                    tx.Label("Engine programmer"); // label#3
                });
                tx.Row(() =>
                {
                    tx.Button("left"); // button#0
                    tx.Spacer();
                    tx.Button("right"); // button#1
                }, grow: 1.0);
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
