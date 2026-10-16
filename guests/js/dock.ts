// The dock scene (tools/scenes/dock.steps; docs/styling-pass-plan.md Y8): a
// window with a now-playing bar docked under its content, gone while nothing
// plays because the dock's root then holds no widget. See guests/rust/dock.rs.

import * as kaya from "kaya-gui";

const app = new kaya.App();
const art = kaya.asset("covers/cover-600.jpg").bytes();

app.window({ title: "dock", width: 720, height: 480 }, () => {
  const playing = kaya.signal(true);
  app.dock(40, () => {
    kaya.column(() => {
      kaya.when(playing, () => {
        kaya.row((bar) => {
          bar.a11yId("bar");
          kaya.image(art, { fit: "cover", shape: "rounded" }).maxWidth(40).maxHeight(40);
          kaya.column(() => {
            kaya.label("Blue in Green");
            kaya.caption("Miles Davis");
          });
          kaya.slider({ value: 0.4, min: 0, max: 1 }).a11yId("progress");
          kaya.button("Pause").a11yId("pause");
        });
      });
    });
  });
  kaya.column(() => {
    kaya.label("Library");
    kaya.button("stop", { onClick: () => playing.set(false) }).a11yId("stop");
    kaya.button("play", { onClick: () => playing.set(true) }).a11yId("play");
  });
});

app.run();
