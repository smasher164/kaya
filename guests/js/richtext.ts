// The rich text scene (tools/scenes/richtext.steps): the app declares a
// document, applies an edit, formats the widget's selection through its own
// act, and reads every delta back into its own Document. THE OFFSETS ARE
// UTF-8 BYTES; the é in the first word is what makes a UTF-16 reader fail
// (docs/ranges-units.md).

import * as kaya from "kaya-gui";

const app = new kaya.App();

// BYTE-IDENTICAL to guests/rust/richtext.rs's DOC.
const DOC = "Héllo world\nSecond line";

/** The core's spelling of runs (`expect_runs`), so the binding's document
 * and the core's mirror are compared as one string. */
function spell(runs: readonly kaya.Run[]): string {
  return runs
    .map((run) => (run.value === "true" ? `${run.start}:${run.end} ${run.name}` : `${run.start}:${run.end} ${run.name}=${run.value}`))
    .join("|");
}

function onEdit(edit: kaya.Edit): void {
  last.set(`edit ${edit.start}:${edit.end} <${edit.inserted}> [${spell(edit.runs)}]`);
  runs.set(spell(editor.document().runs));
}

function onFormat(act: kaya.Format): void {
  last.set(`format ${act.start}:${act.end} ${act.name}=${act.value ?? "off"}`);
  runs.set(spell(editor.document().runs));
}

function onSeed(): void {
  const doc = new kaya.Document(DOC).bold([0, 6]).link([7, 12], "https://kaya.dev").block([13, 24], kaya.Block.HEADING2);
  editor.setDocument(doc);
  runs.set(spell(doc.runs));
}

function onInsert(): void {
  editor.applyEdit(kaya.Edit.insert(6, ", big").mark([2, 5], "italic", "true"));
  runs.set(spell(editor.document().runs));
}

function onSelectWord(): void {
  editor.selectRange([0, 6]);
}

function onUnbold(): void {
  editor.unformat("bold");
}

function onHeading(): void {
  editor.setBlock(kaya.Block.HEADING1);
}

function onFocus(): void {
  editor.focus();
}

function onPrefix(): void {
  editor.applyEdit(kaya.Edit.insert(0, "> "));
  runs.set(spell(editor.document().runs));
}

let last!: kaya.Signal<string>;
let runs!: kaya.Signal<string>;
let editor!: kaya.Widget;

app.window({ title: "richtext" }, () => {
  last = kaya.signal("");
  runs = kaya.signal("");
  kaya.column(() => {
    editor = kaya.textarea({ rich: true, onEdit, onFormat }); // textarea#0
    editor.a11yId("doc").a11yLabel("Document");
    kaya.label({ bind: last }); // label#0
    kaya.label({ bind: runs }); // label#1
    kaya.row(() => {
      kaya.button("seed", { onClick: onSeed }); // button#0
      kaya.button("insert", { onClick: onInsert }); // button#1
      kaya.button("select word", { onClick: onSelectWord }); // button#2
      kaya.button("unbold", { onClick: onUnbold }); // button#3
      kaya.button("heading", { onClick: onHeading }); // button#4
      kaya.button("focus", { onClick: onFocus }); // button#5
      kaya.button("prefix", { onClick: onPrefix }); // button#6
    });
  });
});

app.run();
