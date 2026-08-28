// The canvas SIZE-POLICY scene, C# port — see guests/rust/sizepolicy.rs;
// tools/scenes/sizepolicy.steps is the byte-frozen contract.
//
// ALL FOUR CANVASES GROW, which is the only reason the scene can see
// anything: an ungrown canvas is its natural size — content is the floor
// — so its track IS its viewbox and every policy agrees.
//
// EVERY FIGURE IS DRAWN IN FRACTIONS OF THE BOX IT IS HANDED, so the
// normalized ink bounds are one frozen string though the four tracks
// differ on every platform.

using System;

static class SizepolicyScene
{
    // The declared box of the two CONSTANT-mode canvases. A `scale`
    // canvas keeps drawing in it at any size and a `fixed` one refuses to
    // leave it, so it is the one number the two of them disagree about.
    static readonly Viewbox Box = new Viewbox(300.0, 120.0);

    /// An axis-aligned rectangle at l..r and t..b as FRACTIONS of the
    /// box, filled with one paint role.
    static void Panel(
        Draw d, Viewbox box, double l, double t, double r, double b, Paint paint)
    {
        double w = box.W, h = box.H;
        d.MoveTo(l * w, t * h)
            .LineTo(r * w, t * h)
            .LineTo(r * w, b * h)
            .LineTo(l * w, b * h)
            .Close()
            .Fill(paint, FillRule.Nonzero);
    }

    /// The figure the three drawing canvases share: a ground panel inset a
    /// twentieth of the WIDTH with a translucent series panel over its
    /// middle half. The centre probe point is opaque, which is what
    /// expect_ink rests on.
    static void Figure(Draw d, Viewbox box)
    {
        Panel(d, box, 0.05, 0.0, 0.95, 1.0, Paint.Ground);
        Panel(d, box, 0.25, 0.0, 0.75, 1.0, Paint.SeriesFill);
    }

    /// The animating canvas's bar, whose RIGHT EDGE is the frame number:
    /// 35 hundredths plus ten per frame. The scene asserts exact frames.
    static void Bar(Draw d, Viewbox box, long frame)
    {
        double right = 0.35 + 0.10 * frame;
        Panel(d, box, 0.25, 0.0, right, 1.0, Paint.Axis);
    }

    /// Seconds back to the frame the harness drove. The clock is the
    /// core's HARNESS_FRAME_HZ; the guest reads the time it was HANDED and
    /// never one of its own.
    ///
    /// AWAY FROM ZERO, not .NET's default: Math.Round is banker's
    /// rounding, and the shared scene compares this against Rust's
    /// f64::round, which is half-away-from-zero.
    static long FrameOf(double time) =>
        (long)Math.Round(Math.Max(time * 60.0, 0.0), MidpointRounding.AwayFromZero);

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            tx.Window(title: "sizepolicy", width: 480, height: 420);

            tx.Mount(tx.Column(() =>
            {
                // SCALE, the default: nothing is declared, and the core
                // re-rasterizes this same display list at whatever track
                // the column hands over, fitted uniformly and centred.
                var fit = tx.Canvas(Box, grow: 1.0);
                tx.SetA11yId(fit, "fit");
                tx.SetA11yLabel(fit, "Scaled panel");
                tx.Draw(fit, d => Figure(d, Box));

                // FIXED: the one true property. This one draws at Box
                // whatever the column does with it, and the backend blits
                // it 1:1 with the leftover as margin.
                var mark = tx.Canvas(Box, grow: 1.0).Fixed();
                tx.SetA11yId(mark, "mark");
                tx.SetA11yLabel(mark, "Fixed mark");
                tx.Draw(mark, d => Figure(d, Box));

                // REDRAW: the drawing IS a function of size, and saying so
                // is providing the function. The viewbox declared here is
                // only the size before the first answer.
                var live = tx.Canvas(Box, grow: 1.0)
                    .OnDraw((d, size) => Figure(d, size));
                tx.SetA11yId(live, "live");
                tx.SetA11yLabel(live, "Redrawn panel");

                // TICK: the same, once a frame, at the time the platform
                // supplied. Under the harness that clock is the core's own
                // step and a verb advances it.
                var clock = tx.Canvas(Box, grow: 1.0)
                    .OnTick((d, size, time) => Bar(d, size, FrameOf(time)));
                tx.SetA11yId(clock, "clock");
                tx.SetA11yLabel(clock, "Animated bar");
            }));
        });

        // Every occurrence this scene has is a canvas ask, and the binding
        // answers those in its dispatch loop — running is what keeps the
        // app thread alive to hold the scene up.
        Environment.Exit(app.Run());
    }
}
