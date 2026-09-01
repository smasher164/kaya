// The canvas SIZE-POLICY scene, JS port — see guests/rust/sizepolicy.rs
// for the full rationale and tools/scenes/sizepolicy.steps for the frozen
// contract. Four grown canvases say the four things a drawing can say
// about its own size: nothing (scale), fixed, onDraw, onTick.
//
// EVERY FIGURE IS DRAWN IN FRACTIONS OF THE BOX IT IS HANDED, which is why
// one frozen expectation serves four tracks that differ per platform.

import * as kaya from "kaya-gui";

// The declared box of the two CONSTANT-mode canvases: the one number
// `scale` and `fixed` disagree about.
const BOX: kaya.Size = [300, 120];

/** An axis-aligned rectangle at left..right and top..bottom as
 * FRACTIONS of the box, filled with one paint role. */
function panel(d: kaya.Draw, box: kaya.Size, left: number, top: number, right: number, bottom: number, paint: kaya.Paint): void {
  const [w, h] = box;
  d.moveTo(left * w, top * h)
    .lineTo(right * w, top * h)
    .lineTo(right * w, bottom * h)
    .lineTo(left * w, bottom * h)
    .close()
    .fill(paint);
}

/** The figure the three drawing canvases share: a ground panel inset
 * a twentieth of the width with a translucent series panel over its
 * middle half. */
function figure(d: kaya.Draw, box: kaya.Size): void {
  panel(d, box, 0.05, 0.0, 0.95, 1.0, "ground");
  panel(d, box, 0.25, 0.0, 0.75, 1.0, "series_fill");
}

/** The animating canvas's bar, whose RIGHT EDGE is the frame number:
 * 35 hundredths plus ten per frame. */
function bar(d: kaya.Draw, box: kaya.Size, frame: number): void {
  panel(d, box, 0.25, 0.0, 0.35 + 0.1 * frame, 1.0, "axis");
}

/** Seconds back to the frame the harness drove. The guest reads the
 * time it was HANDED and never a clock of its own (§15.4). */
function frameOf(time: number): number {
  return Math.max(0, Math.round(time * 60.0));
}

const app = new kaya.App();

app.window({ title: "sizepolicy", width: 480, height: 420 }, () => {
  kaya.column(() => {
    // SCALE, the default: nothing is declared, and the core
    // re-rasterizes this same display list at whatever track the
    // column hands over, fitted uniformly and centred.
    const fit = kaya.canvas(BOX, { grow: 1 });
    fit.a11yId("fit").a11yLabel("Scaled panel");
    fit.draw((d) => {
      figure(d, BOX);
    });

    // FIXED: the one true property. This one draws at BOX whatever
    // the column does with it, and the backend blits it 1:1.
    const mark = kaya.canvas(BOX, { grow: 1, fixed: true });
    mark.a11yId("mark").a11yLabel("Fixed mark");
    mark.draw((d) => {
      figure(d, BOX);
    });

    // REDRAW: the drawing IS a function of size, and saying so is
    // providing the function. The viewbox declared here is only the
    // size before the first answer.
    const live = kaya.canvas(BOX, { grow: 1, onDraw: figure });
    live.a11yId("live").a11yLabel("Redrawn panel");

    // TICK: the same, once a frame, at the time the platform
    // supplied. Under the harness that clock is the core's own step
    // and a verb advances it.
    const clock = kaya.canvas(BOX, { grow: 1, onTick: (d, size, time) => bar(d, size, frameOf(time)) });
    clock.a11yId("clock").a11yLabel("Animated bar");
  });
});

app.run();
