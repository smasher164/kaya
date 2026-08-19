// The layout scene, C# port — the native-default observation vehicle;
// see guests/rust/layout.rs for the axes it stresses. The two label
// expects only prove the tree built; the scene asserts no geometry —
// container targets index by creation order, which legitimately differs
// per language.

static class LayoutScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var probe = tx.Signal("Layout probe");
            var tail = tx.Signal("tail");
            var mixed = tx.Signal("mixed");
            var nested = tx.Signal("nested");
            var deep = tx.Signal("deep");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: probe); // label#0

                tx.Row(() =>
                {
                    tx.Button("A");
                    tx.Button("longer");
                    tx.Label(bind: tail); // label#1
                });

                tx.Row(() =>
                {
                    tx.Checkbox("check");
                    tx.Label(bind: mixed); // label#2
                    tx.Slider(0.0, 1.0, 0.5, grow: 1);
                });

                tx.Row(() =>
                {
                    tx.Slider(0.0, 1.0, 0.25, grow: 1);
                    tx.Slider(0.0, 1.0, 0.75, grow: 3);
                });

                tx.Column(() =>
                {
                    tx.Label(bind: nested); // label#3
                    tx.Row(() =>
                    {
                        tx.Label(bind: deep); // label#4
                        tx.Button("x");
                    });
                });
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
