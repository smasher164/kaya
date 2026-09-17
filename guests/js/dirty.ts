// The dirty-state scene (tools/scenes/dirty.steps). TWO DECLARATIONS, on
// purpose: kaya does not watch your signals and guess.

import * as kaya from "kaya-gui";

const app = new kaya.App();

function edit(): void {
  doc.set("notes and a line");
  status.set("unsaved");
  app.window({ dirty: true });
}

function save(): void {
  status.set("saved");
  // The mark comes DOWN as well as up: only this assertion sees it.
  app.window({ dirty: false });
}

function answered(choice: kaya.AlertChoice): void {
  if (choice === "cancel") {
    // Answering a dialog is not saving: the mark stays up.
    status.set("kept editing");
  } else {
    // ABORTS if it runs — docs/traps.md, "An app can VETO a close but
    // cannot AGREE to one".
    kaya.destroyWindow(0);
  }
}

async function closeAsked(): Promise<void> {
  // Nothing has closed yet; the handler rides this window's declaration.
  answered(
    await kaya.showAlert({
      title: "unsaved changes",
      message: "the document has unsaved changes",
      actions: ["Discard"],
      cancel: "Keep Editing",
    }),
  );
}

// Dirty is NOT declared here: the script reads the clean window first.
const { doc, status } = app.window({ title: "dirty", vetoClose: true, onCloseRequested: closeAsked }, () => {
  const doc = kaya.signal("notes");
  const status = kaya.signal("saved");
  kaya.column(() => {
    kaya.label({ bind: doc }); // label#0
    kaya.label({ bind: status }); // label#1
    kaya.button("edit", { onClick: edit }); // button#0
    kaya.button("save", { onClick: save }); // button#1
  });
  return { doc, status };
});

app.run();
