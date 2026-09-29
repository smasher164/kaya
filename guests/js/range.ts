// The range scene (tools/scenes/range.steps; docs/range-plan.md §5).
//     KAYA_SELFTEST=range node guests/js/range.ts

import * as kaya from "kaya-gui";

const Clip = kaya.record({ name: String, trimIn: Number, trimOut: Number }, "Clip");

const app = new kaya.App();

// The harness's own slider spelling (crates/kaya/src/harness.rs).
function spelled(v: number): string {
  return v.toFixed(6).replace(/0+$/, "").replace(/\.$/, "");
}

let commits = 0;

function onMoved(low: number, high: number): void {
  liveText.set(`live: ${spelled(low)} ${spelled(high)}`);
}

function onCommitted(low: number, high: number): void {
  commits += 1;
  commitText.set(`commits: ${commits} at ${spelled(low)} ${spelled(high)}`);
}

function onVolume(value: number): void {
  volumeText.set(`volume: ${spelled(value)}`);
}

function onClipTrim(clip: kaya.RowHandle<kaya.Fields<typeof Clip.schema>>, low: number, high: number): void {
  clipText.set(`clip ${String(clip.key)}: ${spelled(low)} ${spelled(high)}`);
}

function onReset(): void {
  // Must NOT come back as a move or a commit.
  lowSig.set(1);
}

function onLate(): void {
  // Crosses a high thumb the user moved; the core clamps it (docs/range-plan.md §3).
  lowSig.set(6);
}

const { liveText, commitText, volumeText, clipText, lowSig } = app.window({}, () => {
  const liveText = kaya.signal("live: 2 8");
  const commitText = kaya.signal("commits: 0");
  const volumeText = kaya.signal("volume: 0.25");
  const clipText = kaya.signal("clip: none");
  const lowSig = kaya.signal(2);
  const highSig = kaya.signal(8);
  const clips = kaya.collection(Clip);
  kaya.column(() => {
    kaya.label({ bind: liveText }); // label#0
    kaya.label({ bind: commitText }); // label#1
    kaya.label({ bind: volumeText }); // label#2
    kaya.label({ bind: clipText }); // label#3
    kaya
      .range({
        low: lowSig, high: highSig, min: 0, max: 10, step: 0.5, tickSpacing: 1, minGap: 1,
        lowLabel: "In", highLabel: "Out", onChange: onMoved, onCommit: onCommitted,
      })
      .a11yId("trim")
      .a11yLabel("Trim"); // range#0
    kaya.range({ low: 4, high: 6, min: 0, max: 10, step: 0.5, tickSpacing: 1, minGap: 0 }).a11yLabel("Tie"); // range#1
    kaya.slider({ value: 5, min: 0, max: 10 }).a11yLabel("Playhead"); // slider#0
    kaya
      .slider({ value: 0.25, min: 0, max: 1, step: 0.25, axis: kaya.Axis.VERTICAL, onChange: onVolume })
      .a11yId("volume")
      .a11yLabel("Volume"); // slider#1
    kaya.button("reset", { onClick: onReset }); // button#0
    kaya.button("late", { onClick: onLate }); // button#1
    for (const clip of clips) {
      kaya.label({ bind: clip.name });
      kaya.range({ low: clip.trimIn, high: clip.trimOut, min: 0, max: 10, step: 0.5, minGap: 1, onCommit: onClipTrim }).a11yId("clip");
    }
  });
  clips.insert("a", Clip({ name: "a", trimIn: 1, trimOut: 4 }));
  clips.insert("b", Clip({ name: "b", trimIn: 3, trimOut: 7 }));
  return { liveText, commitText, volumeText, clipText, lowSig };
});

app.run();
