// The colour picker scene (tools/scenes/colorpicker.steps;
// docs/color-picker-plan.md §5).
//     KAYA_SELFTEST=colorpicker node guests/js/colorpicker.ts

import * as kaya from "kaya-gui";

const Swatch = kaya.record({ name: String, fill: kaya.Color }, "Swatch");

const app = new kaya.App();

function onTitle(picked: kaya.Color): void {
  titleText.set(`color: ${picked}`);
}

function onGlaze(picked: kaya.Color): void {
  glazeText.set(`alpha: ${picked}`);
}

function onRowFill(row: kaya.RowHandle<kaya.Fields<typeof Swatch.schema>>, picked: kaya.Color): void {
  rowText.set(`row ${String(row.key)}: ${picked}`);
}

function onReset(): void {
  // Must NOT come back as a title occurrence.
  titleValue.set(kaya.Color.fromHex(0x3584e4ff));
}

const { titleText, glazeText, rowText, titleValue } = app.window({}, () => {
  const titleText = kaya.signal("color: none");
  const glazeText = kaya.signal("alpha: none");
  const rowText = kaya.signal("row: none");
  const titleValue = kaya.signal(kaya.Color.fromHex(0x336699ff));
  const swatches = kaya.collection(Swatch);
  kaya.column(() => {
    kaya.label({ bind: titleText });
    kaya.label({ bind: glazeText });
    kaya.label({ bind: rowText });
    kaya.colorPicker({ color: titleValue, onColor: onTitle }).a11yLabel("Title colour").a11yId("title");
    kaya.colorPicker({ color: kaya.Color.fromHex(0x26a269ff), alpha: true, onColor: onGlaze }).a11yLabel("Glaze");
    kaya.button("reset", { onClick: onReset });
    for (const swatch of swatches) {
      kaya.label({ bind: swatch.name });
      kaya.colorPicker({ color: swatch.fill, onColor: onRowFill }).a11yId("fill");
    }
  });
  swatches.insert("a", Swatch({ name: "a", fill: kaya.Color.fromHex(0xe66100ff) }));
  swatches.insert("b", Swatch({ name: "b", fill: kaya.Color.fromHex(0xf6d32dff) }));
  return { titleText, glazeText, rowText, titleValue };
});

app.run();
