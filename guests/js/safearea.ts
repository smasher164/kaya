// The safe-area scene (tools/scenes/safearea.steps; docs/safe-area-plan.md
// A3, A8).

import * as kaya from "kaya-gui";

const GROUND: kaya.Size = [300, 200];

function ground(d: kaya.Draw, size: kaya.Size): void {
  const [w, h] = size;
  d.moveTo(0, 0).lineTo(w, 0).lineTo(w, h).lineTo(0, h).close().fill("series_fill");
}

const app = new kaya.App();

function noInset(): void {
  app.window({ inset: 0 });
  caption.set("inset 0");
}

function fullscreen(): void {
  app.window({ fullscreen: true });
  caption.set("fullscreen");
}

const caption = app.window({ title: "safearea", width: 420, height: 640 }, () => {
  const caption = kaya.signal("inset 16");
  kaya.column(() => {
    const photo = kaya.asset("images/photo.jpg");
    kaya.image(photo, { bleed: true }).maxHeight(160).a11yId("picture").a11yLabel("Photo");
    photo.close();
    kaya.label({ bind: caption }).a11yId("caption");
    kaya.button("No inset", { onClick: noInset }).a11yId("inset");
    kaya.button("Fullscreen", { onClick: fullscreen }).a11yId("full");
    kaya.canvas(GROUND, { grow: 1, onDraw: ground, bleed: true }).a11yId("ground").a11yLabel("Ground");
  });
  return caption;
});

app.run();
