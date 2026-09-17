// The app-owned undo scene (tools/scenes/ownundo.steps;
// docs/rich-text-plan.md R6, §14): two rich textareas, one on the
// platform's own undo tier and one whose app keeps its own history of
// Documents. Edit>Undo reaches the app through the role item's own
// activation while the owned textarea is focused, and the platform's tier
// while the other one is.

import * as kaya from "kaya-gui";

const app = new kaya.App();

// THE APP'S OWN HISTORY: the document before each user edit, and the
// documents an undo took away. The binding's mirror is the document AFTER
// the edit it just delivered.
const undo: kaya.Document[] = [];
const redo: kaya.Document[] = [];
let current = new kaya.Document("");

function publish(): void {
  status.set(`undo ${undo.length} redo ${redo.length}`);
  owned.canUndo(undo.length > 0);
  owned.canRedo(redo.length > 0);
}

function onEdit(): void {
  undo.push(current);
  current = owned.document();
  redo.length = 0;
  publish();
}

function onUndo(): void {
  const before = undo.pop();
  if (before === undefined) return;
  redo.push(current);
  current = before;
  owned.setDocument(before);
  publish();
}

function onRedo(): void {
  const after = redo.pop();
  if (after === undefined) return;
  undo.push(current);
  current = after;
  owned.setDocument(after);
  publish();
}

const { status, native, owned } = app.window({ title: "ownundo" }, () => {
  app.menu("Edit", () => {
    kaya.item("Undo", { role: "undo", onActivate: onUndo });
    kaya.item("Redo", { role: "redo", onActivate: onRedo });
  });

  const status = kaya.signal("undo 0 redo 0");
  const { native, owned } = kaya.column(() => {
    kaya.label({ bind: status }).a11yId("status"); // label#0
    const native = kaya.textarea({ rich: true }); // textarea#0
    native.a11yId("native").a11yLabel("Native");
    const owned = kaya.textarea({ rich: true, ownUndo: true, onEdit }); // textarea#1
    owned.a11yId("owned").a11yLabel("Owned");
    kaya.row(() => {
      kaya.button("focus native", { onClick: () => native.focus() }); // button#0
      kaya.button("focus owned", { onClick: () => owned.focus() }); // button#1
    });
    return { native, owned };
  });
  return { status, native, owned };
});

app.run();
