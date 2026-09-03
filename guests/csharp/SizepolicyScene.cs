// The sizepolicy scene, C# port — guests/rust/sizepolicy.rs,
// tools/scenes/sizepolicy.steps.

using System;

static class SizepolicyScene
{
    // The declared box of the two CONSTANT-mode canvases: the one number
    // `scale` and `fixed` disagree about.
    static readonly Viewbox Box = new Viewbox(300.0, 120.0);

    /// A rectangle at l..r and t..b as FRACTIONS of the box.
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

    /// The figure the three drawing canvases share. The centre probe point is
    /// opaque, which is what expect_ink rests on.
    static void Figure(Draw d, Viewbox box)
    {
        Panel(d, box, 0.05, 0.0, 0.95, 1.0, Paint.Ground);
        Panel(d, box, 0.25, 0.0, 0.75, 1.0, Paint.SeriesFill);
    }

    /// The bar whose RIGHT EDGE is the frame number; the scene asserts exact
    /// frames.
    static void Bar(Draw d, Viewbox box, long frame)
    {
        double right = 0.35 + 0.10 * frame;
        Panel(d, box, 0.25, 0.0, right, 1.0, Paint.Axis);
    }

    /// AWAY FROM ZERO, not .NET's default: Math.Round is banker's rounding and
    /// the shared scene compares this against Rust's f64::round.
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
                // SCALE, the default: nothing is declared.
                var fit = tx.Canvas(Box, grow: 1.0);
                tx.SetA11yId(fit, "fit");
                tx.SetA11yLabel(fit, "Scaled panel");
                tx.Draw(fit, d => Figure(d, Box));

                // FIXED
                var mark = tx.Canvas(Box, grow: 1.0).Fixed();
                tx.SetA11yId(mark, "mark");
                tx.SetA11yLabel(mark, "Fixed mark");
                tx.Draw(mark, d => Figure(d, Box));

                // REDRAW
                var live = tx.Canvas(Box, grow: 1.0)
                    .OnDraw((d, size) => Figure(d, size));
                tx.SetA11yId(live, "live");
                tx.SetA11yLabel(live, "Redrawn panel");

                // TICK: under the harness the clock is the core's own step.
                var clock = tx.Canvas(Box, grow: 1.0)
                    .OnTick((d, size, time) => Bar(d, size, FrameOf(time)));
                tx.SetA11yId(clock, "clock");
                tx.SetA11yLabel(clock, "Animated bar");
            }));
        });

        Environment.Exit(app.Run());
    }
}
