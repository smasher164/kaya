// The toolbar scene (tools/scenes/toolbar.steps): the `primary` bit as
// window chrome, with no toolbar vocabulary to spell.

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
  // Written against the MENU ITEM: the promoted button IS that item.
  canSave = kaya.signal(true);

  // CATALOG PREORDER DECIDES PROMOTION.
  app.menu("File", () => {
    // The vocabulary has no save glyph, so `done` is the spelling.
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
