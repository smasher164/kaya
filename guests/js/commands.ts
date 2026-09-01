// The standard-commands scene, JS port: a chord on every leaf kind (a
// checkable command, one option of a group, a plain command), the
// punctuation keys those chords need, and the `settings` role — which
// macOS shows in the application menu while the item stays addressable
// where it was declared. Canonical semantics in guests/rust/commands.rs;
// the byte-frozen contract in tools/scenes/commands.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

let settingsCount = 0;

function onDetails(on: boolean): void {
  status.set(on ? "details on" : "details off");
}

function onSorted(index: number): void {
  status.set(index === 1 ? "sorted date" : "sorted name");
}

function onSettings(): void {
  // Fires twice on purpose: once by the chord, once by activating the
  // item at its DECLARED path — which on macOS lives in the
  // application menu by then.
  settingsCount += 1;
  status.set(`settings ${settingsCount}`);
}

let status!: kaya.Signal<string>;

app.window({ title: "commands" }, () => {
  status = kaya.signal("ready");
  const details = kaya.signal(false);
  const sort = kaya.signal(0);

  app.menu("File", () => {
    kaya.item("Reload");
    kaya.item("Settings…", { shortcut: "primary+comma", role: kaya.ROLE_SETTINGS, onActivate: onSettings });
  });

  // Option order IS the index vocabulary: Name = 0, Date = 1.
  app.menu("View", () => {
    kaya.toggle("Details", { checked: details, shortcut: "primary+backslash", onToggle: onDetails });
    kaya.radioGroup("Sort", { value: sort, onSelect: onSorted }, () => {
      kaya.option("Name", { shortcut: "primary+1" });
      kaya.option("Date", { shortcut: "primary+2" });
    });
  });

  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
  });
});

app.run();
