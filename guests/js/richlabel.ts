// The rich label scene (tools/scenes/richlabel.steps; docs/rich-text-plan.md
// R8, §15): a label carries the inline vocabulary read-only — the app writes
// its document and edits it, and the widget draws the runs over the role's
// own font. THE OFFSETS ARE UTF-8 BYTES (docs/ranges-units.md).

import * as kaya from "kaya-gui";

const app = new kaya.App();

// BYTE-IDENTICAL to guests/rust/richlabel.rs's DOC.
const DOC = "Héllo world, code";

/** The core's spelling of runs (`expect_runs`), so the binding's document
 * and the core's mirror are compared as one string. */
function spell(runs: readonly kaya.Run[]): string {
  return runs
    .map((run) => (run.value === "true" ? `${run.start}:${run.end} ${run.name}` : `${run.start}:${run.end} ${run.name}=${run.value}`))
    .join("|");
}

function onSeed(): void {
  const doc = new kaya.Document(DOC).bold([0, 6]).link([7, 12], "https://kaya.dev").mark([14, 18], "code", "true");
  const title = new kaya.Document("Heading with italic").mark([13, 19], "italic", "true");
  body.setDocument(doc);
  heading.setDocument(title);
  runs.set(spell(doc.runs));
}

function onInsert(): void {
  body.applyEdit(kaya.Edit.insert(6, ", big").mark([2, 5], "italic", "true"));
  runs.set(spell(body.document().runs));
}

function onMark(): void {
  body.formatRange([1, 4], "italic", "true");
  body.unformatRange([0, 3], "bold"); // "Hé": byte 2 is inside the é
  runs.set(spell(body.document().runs));
}

let runs!: kaya.Signal<string>;
let body!: kaya.Widget;
let heading!: kaya.Widget;

app.window({ title: "richlabel" }, () => {
  runs = kaya.signal("");
  kaya.column(() => {
    const bodyText = kaya.signal("");
    const headingText = kaya.signal("Heading with italic");
    body = kaya.label({ bind: bodyText, rich: true }).a11yId("body"); // label#0
    heading = kaya.label({ bind: headingText, rich: true }).role("heading").a11yId("heading"); // label#1
    kaya.label({ bind: runs }).a11yId("runs"); // label#2
    kaya.row(() => {
      kaya.button("seed", { onClick: onSeed }); // button#0
      kaya.button("insert", { onClick: onInsert }); // button#1
      kaya.button("mark", { onClick: onMark }); // button#2
    });
  });
});

app.run();
