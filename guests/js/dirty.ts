// The dirty-state conformance scene, JS port — unsaved work as window
// chrome (docs/dirty-plan.md). The app declares STATE, and each backend
// spells its own platform's affordance.
//
// TWO DECLARATIONS, ON PURPOSE: an edit writes the document AND says
// `dirty: true`. kaya does not watch your signals and guess.
//
// See guests/rust/dirty.rs and tools/scenes/dirty.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

function edit(): void {
  doc.set("notes and a line");
  status.set("unsaved");
  app.window({ dirty: true });
}

function save(): void {
  status.set("saved");
  // The mark comes DOWN as well as up — a lowering that only ever sets
  // the flag would pass every assertion before this one.
  app.window({ dirty: false });
}

function answered(choice: number): void {
  if (choice === kaya.CANCEL) {
    // Answering a dialog is not saving: the mark stays up.
    status.set("kept editing");
  } else {
    // UNREACHED BY THE SCENE, AND IT ABORTS IF IT EVER RUNS: there is
    // no verb for agreeing to a close (docs/traps.md, "An app can
    // VETO a close but cannot AGREE to one"). The scene answers
    // cancel; this arm is the honest spelling, not a step.
    kaya.destroyWindow(0);
  }
}

function closeAsked(): void {
  // Nothing has closed yet: the veto class says so. The handler rides
  // the window construct at its declaration, so it can only ever mean
  // this surface's close.
  kaya.showAlert({
    title: "unsaved changes",
    message: "the document has unsaved changes",
    actions: ["Discard"],
    cancel: "Keep Editing",
    onResult: answered,
  });
}

let doc!: kaya.Signal<string>;
let status!: kaya.Signal<string>;

// `dirty` and `vetoClose` are orthogonal. This window does NOT declare
// dirty here: the default false is the scene's first assertion.
app.window({ title: "dirty", vetoClose: true, onCloseRequested: closeAsked }, () => {
  doc = kaya.signal("notes");
  status = kaya.signal("saved");
  kaya.column(() => {
    kaya.label({ bind: doc }); // label#0
    kaya.label({ bind: status }); // label#1
    kaya.button("edit", { onClick: edit }); // button#0
    kaya.button("save", { onClick: save }); // button#1
  });
});

app.run();
