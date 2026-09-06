// The gallery scene, a bool and a float (tools/scenes/gallery.steps).
//     KAYA_SELFTEST=gallery node guests/js/gallery.ts

import * as kaya from "kaya-gui";

const app = new kaya.App();

// A 2x2 RGB PNG, 75 bytes, embedded as source.
const TEST_PNG = new Uint8Array([
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99,
  248, 207, 192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
]);

function onToggle(checked: boolean): void {
  // A kaya.fmt signal over this one: the text follows the fact.
  urgent.set(checked);
}

function onVolume(value: number): void {
  // Integer percent, so every language's formatting agrees byte for byte.
  volume.set(`volume: ${Math.round(value * 100)}%`);
}

function onQuarter(): void {
  // A programmatic write must NOT echo an onVolume occurrence.
  pos.set(0.25);
}

let urgent!: kaya.Signal<boolean>;
let status!: kaya.Signal<string>;
let volume!: kaya.Signal<string>;
let pos!: kaya.Signal<number>;

app.window(() => {
  urgent = kaya.signal(false);
  status = kaya.fmt`urgent: ${urgent}`;
  volume = kaya.signal("volume: 50%");
  pos = kaya.signal(0.5);

  kaya.column(() => {
    kaya.row(() => {
      kaya.checkbox("urgent", { onToggle });
      kaya.label({ bind: status });
    });
    kaya.row(() => {
      kaya.slider({ value: pos, min: 0, max: 1, onChange: onVolume });
      kaya.label({ bind: volume });
      kaya.button("quarter", { onClick: onQuarter });
    });
    kaya.row(() => {
      // A decode failure is the placeholder class, never a crash.
      kaya.image(TEST_PNG);
      kaya.image(new TextEncoder().encode("not an image"));
    });
    // The labelled row: the control's accessibility name IS the label's
    // text, with no a11yLabel of its own.
    kaya.labeled("Level", () => {
      kaya.slider({ value: 0.5, min: 0, max: 1 }).a11yId("level");
    });
  });
});

app.run();
