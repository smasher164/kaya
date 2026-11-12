// The rich document scene (tools/scenes/richdoc.steps,
// docs/rich-document-plan.md §9 step 2): a heading, a body paragraph with a
// preset colour, a bullet list with a nested item, a numbered list and a
// checklist, then the paragraph acts from buttons, the platform's colour
// picker and a `.kdoc` round trip, then a file carrying keys this kaya does
// not know (RD17). label#1 is the binding's own Document, folded from the
// same deltas, so it must spell what the core holds.

import * as kaya from "kaya-gui";

const app = new kaya.App();

// BYTE-IDENTICAL to guests/rust/richdoc.rs's DOC.
const DOC = "Groceries\nFresh from the market.\nApples\nGreen ones\nBread\nWash\nSlice\nMilk\nEggs";

// BYTE-IDENTICAL to guests/rust/richdoc.rs's UNKNOWN.
const UNKNOWN =
  '{"kaya": "document", "version": 1, "com.example.theme": {"page": "sepia"}, "paragraphs": [{"embed": "e1", "spans": [["Loose"]]}, {"com.example.pinned": true, "spans": [["Pinned"]]}]}';

function spell(runs: readonly kaya.Run[]): string {
  return runs
    .map((run) => (run.isFlag ? `${run.range[0]}:${run.range[1]} ${run.name}` : `${run.range[0]}:${run.range[1]} ${run.name}=${run.value}`))
    .join("|");
}


const SEEDED = new kaya.Document(DOC)
  .block([0, 9], kaya.Block.HEADING1)
  .color([25, 31], "#016FEF")
  .list([33, 56], kaya.ListKind.BULLET)
  .indent([40, 50], 1)
  .list([57, 67], kaya.ListKind.NUMBERED)
  .checked([68, 72])
  .list([68, 77], kaya.ListKind.CHECK);

function onEdit(edit: kaya.Edit): void {
  last.set(`edit ${edit.range[0]}:${edit.range[1]} <${edit.inserted.replaceAll("\n", "\\n")}> ${edit.source ?? "?"} [${spell(edit.runs)}]`);
  runs.set(spell(editor.document().runs));
}

function onFormat(act: kaya.Format): void {
  last.set(`format ${act.range[0]}:${act.range[1]} ${act.name}=${act.value ?? "off"}`);
  runs.set(spell(editor.document().runs));
}

function onKdoc(): void {
  const now = editor.document();
  const bytes = now.toKdoc();
  const back = kaya.Document.fromKdoc(bytes);
  const extra = back.document.extra.replaceAll('"', "'") || "none";
  editor.setDocument(back.document);
  kdoc.set(`kdoc ${bytes.length} bytes, read_only ${back.readOnly ?? "none"}, same ${back.document.equals(now)}, extra ${extra}`);
  runs.set(spell(back.document.runs));
}

function onUnknown(): void {
  const file = kaya.Document.fromKdoc(new TextEncoder().encode(UNKNOWN));
  editor.setDocument(file.document);
  kdoc.set(`opened read_only ${file.readOnly ?? "none"}, extra ${file.document.extra.replaceAll('"', "'")}`);
  runs.set(spell(file.document.runs));
}

const { last, runs, kdoc, editor } = app.window({ title: "richdoc", width: 560, height: 620 }, () => {
  app.menu("Edit", () => {
    kaya.item("Cut", { role: "cut" });
    kaya.item("Copy", { role: "copy" });
    kaya.item("Paste", { role: "paste" });
  });
  const last = kaya.signal("");
  const runs = kaya.signal(spell(SEEDED.runs));
  const kdoc = kaya.signal("");
  const editor = kaya.column(() => {
    const editor = kaya.textarea({ rich: true, grow: 1, onEdit, onFormat }); // textarea#0
    editor.a11yId("doc").a11yLabel("Document");
    editor.setDocument(SEEDED);
    kaya.label({ bind: last }); // label#0
    kaya.label({ bind: runs }); // label#1
    kaya.label({ bind: kdoc }); // label#2
    kaya.row(() => {
      kaya.button("numbered", { onClick: () => editor.setList(kaya.ListKind.NUMBERED) }); // button#0
      kaya.button("indent", { onClick: () => editor.indent() }); // button#1
      kaya.button("red", { onClick: () => editor.color("#DD1F24") }); // button#2
      kaya.button("colour", { onClick: () => editor.pickTextColor() }); // button#3
      kaya.button("kdoc", { onClick: onKdoc }); // button#4
      kaya.button("unknown", { onClick: onUnknown }); // button#5
    });
    return editor;
  });
  return { last, runs, kdoc, editor };
});

app.run();
