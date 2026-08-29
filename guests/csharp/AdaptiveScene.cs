// The adaptive conformance scene, C# port — see guests/rust/adaptive.rs
// for the full rationale. row@dash flips by a HANDLER (D2's user-driven
// toggle); row@narrow carries the one-keyword breakpoint (D3), which the
// core evaluates and reverts crossing back. The subject stays addressed
// as row#0 through both states: identity is the creation kind,
// presentation is the prop. tools/scenes/adaptive.steps is the
// byte-frozen contract.
//
// The two labels' naturals DIFFER on purpose: the flip then always moves
// the container's box, so the geometry reader re-records on every
// crossing.

static class AdaptiveScene
{
    public static void Run()
    {
        var app = new KayaApp();

        bool vertical = false;
        app.Build(tx =>
        {
            // Explicit size: the desktop start must sit ABOVE the
            // breakpoint's threshold so the scene's resize half crosses
            // it both ways deterministically.
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
                // column#1: the control group — its axis answers the
                // creation kind's own and never moves.
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
                // row#1: the BREAKPOINT subject (D3) — declared data,
                // core-evaluated. The handler never touches it.
                var narrow = tx.Row(() =>
                {
                    var one = tx.Signal("one");
                    var two = tx.Signal("a wider two");
                    tx.Label(bind: one); // label#3
                    tx.Label(bind: two); // label#4
                }, stackBelow: 520);
                tx.SetA11yId(narrow, "narrow");
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
