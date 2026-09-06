// The adaptive scene, C# port — guests/rust/adaptive.rs,
// tools/scenes/adaptive.steps.

static class AdaptiveScene
{
    public static void Run()
    {
        var app = new KayaApp();

        bool vertical = false;
        app.Build(tx =>
        {
            // Above the breakpoint, so the resize half crosses it both ways.
            tx.Window(title: "adaptive", width: 900, height: 600);
            var alpha = tx.Signal("alpha");
            var longer = tx.Signal("a longer label");
            var steady = tx.Signal("steady");

            tx.Mount(tx.Column(() =>
            {
                var dash = tx.Row(() => // row#0: the flip subject.
                {
                    tx.Label(bind: alpha);  // label#0
                    tx.Label(bind: longer); // label#1
                });
                tx.SetA11yId(dash, "dash");
                // column#1: the control group, whose axis never moves.
                var steadyCol = tx.Column(() =>
                {
                    tx.Label(bind: steady); // label#2
                });
                tx.SetA11yId(steadyCol, "steady");
                tx.Button("flip", onClick: t => // button#0
                {
                    vertical = !vertical;
                    t.SetAxis(dash, vertical ? Axis.Vertical : Axis.Horizontal);
                });
                // row#1: the breakpoint subject, which no handler touches.
                var narrow = tx.Row(() =>
                {
                    var one = tx.Signal("one");
                    var two = tx.Signal("a wider two");
                    tx.Label(bind: one); // label#3
                    tx.Label(bind: two); // label#4
                }, stackWhen: SizeClass.Compact);
                tx.SetA11yId(narrow, "narrow");
                // grid@sheet: three columns regular, one compact (D6.2).
                var sheet = tx.Grid(3, () =>
                {
                    foreach (var text in new[] { "c1", "c2", "c3", "c4", "c5", "c6" })
                    {
                        tx.Label(bind: tx.Signal(text)); // label#5..#10
                    }
                }, columnsWhen: (SizeClass.Compact, 1));
                tx.SetA11yId(sheet, "sheet");
                // grid@fit: no count, a 240-point floor, the WIDTH
                // decides (docs/layout-knobs-plan.md §3). Buttons, so
                // the label ordinals above stay put.
                var fit = tx.Grid(3, () =>
                {
                    tx.Button("f1"); // button#1
                    tx.Button("f2");
                    tx.Button("f3");
                });
                tx.SetColumnsAuto(fit, 240);
                tx.SetA11yId(fit, "fit");
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
