// The confirm conformance scene, JS port — the modal-alert grammar: TWO
// dialogs from two buttons (delete has two actions, eject one), each
// bound to its OWN handler at show time. The result handler rides the
// REQUEST and retires with its one answer; ids are binding-allocated, so
// the guest carries no correlation plumbing.
// See guests/rust/confirm.rs and tools/scenes/confirm.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

// The alert is a promise of the choice; the write after the await is
// its own transaction (docs/js-plan.md §4).
async function askDelete(): Promise<void> {
  const choice = await kaya.showAlert({
    title: "delete item?",
    message: "this cannot be undone",
    actions: ["Delete", "Archive"],
    cancel: "Keep",
  });
  if (choice === kaya.CANCEL) status.set("kept");
  else if (choice === 1) status.set("archived");
  else status.set("deleted");
}

async function askEject(): Promise<void> {
  const choice = await kaya.showAlert({
    title: "eject disk?",
    message: "it is still mounted",
    actions: ["Eject"],
    cancel: "Hold",
  });
  status.set(choice === kaya.CANCEL ? "held" : "ejected");
}

let status!: kaya.Signal<string>;

app.window({ title: "confirm" }, () => {
  status = kaya.signal("no decision");
  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
    kaya.button("delete", { onClick: askDelete });
    kaya.button("eject", { onClick: askEject });
  });
});

app.run();
