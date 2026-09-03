// The canvas size-policy scene (tools/scenes/sizepolicy.steps). ALL FOUR
// CANVASES GROW, or an ungrown track IS its viewbox and nothing differs.

import * as kaya from "kaya-gui";

// The declared box of the two CONSTANT-mode canvases.
const BOX: kaya.Size = [300, 120];

/** A rectangle at left..right and top..bottom as FRACTIONS of the box. */
function panel(d: kaya.Draw, box: kaya.Size, left: number, top: number, right: number, bottom: number, paint: kaya.Paint): void {
  const [w, h] = box;
  d.moveTo(left * w, top * h)
    .lineTo(right * w, top * h)
    .lineTo(right * w, bottom * h)
    .lineTo(left * w, bottom * h)
    .close()
    .fill(paint);
}

/** The figure the three drawing canvases share. */
function figure(d: kaya.Draw, box: kaya.Size): void {
  panel(d, box, 0.05, 0.0, 0.95, 1.0, "ground");
  panel(d, box, 0.25, 0.0, 0.75, 1.0, "series_fill");
}

/** The bar's RIGHT EDGE is the frame number. */
function bar(d: kaya.Draw, box: kaya.Size, frame: number): void {
  panel(d, box, 0.25, 0.0, 0.35 + 0.1 * frame, 1.0, "axis");
}

/** The guest reads the time it was HANDED, never a clock of its own. */
function frameOf(time: number): number {
  return Math.max(0, Math.round(time * 60.0));
}

const app = new kaya.App();

app.window({ title: "sizepolicy", width: 480, height: 420 }, () => {
  kaya.column(() => {
    // SCALE, the default: declared by writing nothing.
    const fit = kaya.canvas(BOX, { grow: 1 });
    fit.a11yId("fit").a11yLabel("Scaled panel");
    fit.draw((d) => {
      figure(d, BOX);
    });

    // FIXED: drawn at BOX and blitted 1:1.
    const mark = kaya.canvas(BOX, { grow: 1, fixed: true });
    mark.a11yId("mark").a11yLabel("Fixed mark");
    mark.draw((d) => {
      figure(d, BOX);
    });

    // REDRAW: this viewbox is only the size before the first answer.
    const live = kaya.canvas(BOX, { grow: 1, onDraw: figure });
    live.a11yId("live").a11yLabel("Redrawn panel");

    // TICK: once a frame, at the time the platform supplied.
    const clock = kaya.canvas(BOX, { grow: 1, onTick: (d, size, time) => bar(d, size, frameOf(time)) });
    clock.a11yId("clock").a11yLabel("Animated bar");
  });
});

app.run();
