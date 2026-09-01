// The nav conformance scene, JS port — the north-star spelling
// for the serial navigation grammar: each pushed screen is one
// `pushEntry` scope (nesting inside the click handler's ambient
// transaction), the veto class one handler. The covered root is
// RETAINED (status keeps taking writes while covered); a programmatic
// kaya.popEntry does not echo entry_popped, so the settings round's
// final status stays "back requested". See guests/rust/nav.rs and
// tools/scenes/nav.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

const DETAIL = 7;
const SETTINGS = 8;

function poppedDetail(): void {
  status.set("popped detail");
}

function backAskedSettings(): void {
  // The veto class: nothing has popped yet. No entry_popped will fire,
  // so this write is the round's final status.
  status.set("back requested");
  kaya.popEntry();
}

function openDetail(): void {
  // The push scope NESTS inside the handler's ambient transaction, so
  // the status write rides the same commit.
  app.pushEntry(DETAIL, { title: "detail", onPopped: poppedDetail }, () => {
    const caption = kaya.signal("detail pane");
    kaya.column(() => {
      kaya.label({ bind: caption });
    });
  });
  status.set("pushed detail");
}

function openSettings(): void {
  app.pushEntry(SETTINGS, { title: "settings", interceptBack: true, onBack: backAskedSettings }, () => {
    const caption = kaya.signal("settings pane");
    kaya.column(() => {
      kaya.label({ bind: caption });
    });
  });
  status.set("pushed settings");
}

let status!: kaya.Signal<string>;

app.window({ title: "nav" }, () => {
  status = kaya.signal("at root");
  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
    kaya.button("open detail", { onClick: openDetail }); // button#0
    kaya.button("open settings", { onClick: openSettings }); // button#1
  });
});

app.run();
