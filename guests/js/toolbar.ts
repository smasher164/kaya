// The toolbar conformance scene, JS port: the `primary` bit as real
// window chrome (docs/chrome-plan.md C2). The app declares ONE catalog and
// marks two actions primary; every host promotes the same first two in
// catalog preorder, and the rest of the catalog stays reachable where that
// host keeps it. There is no toolbar vocabulary to spell.
//
// Canonical semantics in guests/rust/toolbar.rs; the byte-frozen contract
// in tools/scenes/toolbar.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

let saveEnabled = true;

let status!: kaya.Signal<string>;
let canSave!: kaya.Signal<boolean>;

function onToggleSave(): void {
  saveEnabled = !saveEnabled;
  canSave.set(saveEnabled);
}

function onSave(): void {
  status.set("saved");
}

function onFind(): void {
  status.set("found");
}

function onExport(): void {
  status.set("exported");
}

app.window({ title: "toolbar" }, () => {
  status = kaya.signal("ready");
  // The app writes this against the MENU ITEM and says nothing about
  // any button: the promoted button IS that item, so it follows or the
  // lowering kept a copy.
  canSave = kaya.signal(true);

  // CATALOG PREORDER DECIDES PROMOTION — top-level groupings in
  // menubar-append order, then each node's children in append order,
  // depth-first. Save is the first primary and Find the second, so
  // every host's promoted set is [Save, Find] whatever its own k is.
  app.menu("File", () => {
    // The vocabulary has no save-specific glyph, so `done` — the
    // checkmark idiom — is the spelling (docs/styling-plan.md D6).
    kaya.item("Save", { symbol: kaya.Symbol.DONE, primary: true, enabled: canSave, shortcut: "primary+s", onActivate: onSave });
    kaya.item("Export", { symbol: kaya.Symbol.FORWARD, onActivate: onExport });
  });

  app.menu("Edit", () => {
    kaya.item("Find", { symbol: kaya.Symbol.SEARCH, primary: true, onActivate: onFind });
    kaya.item("Replace", { symbol: kaya.Symbol.EDIT });
  });

  app.menu("View", () => {
    kaya.item("Refresh", { symbol: kaya.Symbol.REFRESH });
    kaya.item("Info", { symbol: kaya.Symbol.INFO });
  });

  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
    kaya.button("toggle save", { onClick: onToggleSave }); // button#0
  });
});

app.run();
