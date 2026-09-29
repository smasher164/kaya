// The number field scene (tools/scenes/numberfield.steps;
// docs/number-field-plan.md §5).
//     KAYA_SELFTEST=numberfield node guests/js/numberfield.ts

import * as kaya from "kaya-gui";

const Line = kaya.record({ name: String, qty: Number }, "Line");

const app = new kaya.App();

// The harness's own value spelling (crates/kaya/src/harness.rs).
function spelled(v: number): string {
  return v.toFixed(6).replace(/0+$/, "").replace(/\.$/, "");
}

let commits = 0;

function onCommitted(_value: number): void {
  commits += 1;
  commitText.set(`commits: ${commits}`);
}

function onRowQty(row: kaya.RowHandle<kaya.Fields<typeof Line.schema>>, value: number): void {
  rowText.set(`row ${String(row.key)}: ${spelled(value)}`);
}

function onForty(): void {
  // Must NOT come back as a commit.
  amountValue.set(40);
}

const { commitText, rowText, amountValue } = app.window({}, () => {
  const commitText = kaya.signal("commits: 0");
  const rowText = kaya.signal("row: none");
  const amountValue = kaya.signal(0);
  const lines = kaya.collection(Line);
  kaya.column(() => {
    kaya.label({ bind: commitText }).a11yId("commits");
    kaya.label({ bind: rowText }).a11yId("row");
    kaya
      .numberField({ value: amountValue, min: 0, max: 100, step: 0.5, onCommit: onCommitted })
      .a11yId("amount")
      .a11yLabel("Amount");
    kaya.entry().a11yId("note");
    kaya.button("forty", { onClick: onForty }).a11yId("forty");
    for (const line of lines) {
      kaya.label({ bind: line.name });
      kaya.numberField({ value: line.qty, min: 0, onCommit: onRowQty }).a11yId("qty");
    }
  });
  lines.insert("a", Line({ name: "a", qty: 1 }));
  lines.insert("b", Line({ name: "b", qty: 2 }));
  return { commitText, rowText, amountValue };
});

app.run();
