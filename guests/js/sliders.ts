// The sliders scene (tools/scenes/sliders.steps; docs/slider-plan.md).
//     KAYA_SELFTEST=sliders node guests/js/sliders.ts

import * as kaya from "kaya-gui";

const Track = kaya.record({ name: String, level: Number }, "Track");

const app = new kaya.App();

// The harness's own slider spelling (crates/kaya/src/harness.rs).
function spelled(v: number): string {
  return v.toFixed(6).replace(/0+$/, "").replace(/\.$/, "");
}

let levelText!: kaya.Signal<string>;
let commitText!: kaya.Signal<string>;
let volumeText!: kaya.Signal<string>;
let rowText!: kaya.Signal<string>;
let pos!: kaya.Signal<number>;
let commits = 0;

function onLevel(value: number): void {
  levelText.set(`value: ${spelled(value)}`);
}

function onCommitted(_value: number): void {
  commits += 1;
  commitText.set(`commits: ${commits}`);
}

function onVolume(value: number): void {
  volumeText.set(`volume: ${spelled(value)}`);
}

function onRowLevel(row: kaya.RowHandle<kaya.Fields<typeof Track.schema>>, value: number): void {
  rowText.set(`row ${String(row.key)}: ${spelled(value)}`);
}

function onReset(): void {
  // Must NOT come back as a value or a commit occurrence.
  pos.set(25);
}

app.window({}, () => {
  levelText = kaya.signal("value: 50");
  commitText = kaya.signal("commits: 0");
  volumeText = kaya.signal("volume: 0.5");
  rowText = kaya.signal("row: none");
  pos = kaya.signal(50);
  const tracks = kaya.collection(Track);
  kaya.column(() => {
    kaya.label({ bind: levelText }); // label#0
    kaya.label({ bind: commitText }); // label#1
    kaya.label({ bind: volumeText }); // label#2
    kaya.label({ bind: rowText }); // label#3
    kaya
      .slider({ value: pos, min: 0, max: 100, step: 5, tickSpacing: 25, onChange: onLevel, onCommit: onCommitted })
      .a11yId("master")
      .a11yLabel("Level"); // slider#0
    kaya.slider({ value: 0.5, min: 0, max: 1, tickSpacing: 0.25, onChange: onVolume }).a11yLabel("Volume"); // slider#1
    kaya.button("reset", { onClick: onReset }); // button#0
    for (const track of tracks) {
      kaya.label({ bind: track.name });
      kaya.slider({ value: track.level, min: 0, max: 100, step: 10, onCommit: onRowLevel }).a11yId("level");
    }
  });
  tracks.insert("a", Track({ name: "a", level: 70 }));
  tracks.insert("b", Track({ name: "b", level: 20 }));
});

app.run();
