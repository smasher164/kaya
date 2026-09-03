// The app-identity scene (tools/scenes/identity.steps): the mark's four
// flat quadrants, and a second window whose blank title the NAME fills.

import * as kaya from "kaya-gui";

const app = new kaya.App();

const UNTITLED = 1;

let draft = "";

let status!: kaya.Signal<string>;

function onChange(text: string): void {
  draft = text;
}

function onGo(): void {
  status.set(`clicked ${draft}`);
}

app.window({ title: "identity", width: 480, height: 360 }, () => {
  // BEFORE THE FIRST MOUNT: the scope mounts on exit.
  const icon = kaya.asset("icons/kaya-mark.png");
  kaya.appIdentity("Aurora Notes", { icon });
  icon.close();

  // ONE PROMOTED COMMAND, AND NOT ABOUT COMMANDS: Windows mints its custom
  // caption from it, replacing the system-drawn icon.
  app.menu("File", () => {
    kaya.item("Save", { symbol: kaya.Symbol.DONE, primary: true });
  });

  const heading = kaya.signal("identity");
  status = kaya.signal("ready");
  kaya.column(() => {
    kaya.label({ bind: heading }); // label#0
    kaya.label({ bind: status }); // label#1
    kaya.entry({ onChange }); // entry#0
    kaya.button("Go", { onClick: onGo }); // button#0
  });
});

// No title at all: an empty string is a title an app WROTE. The host is
// asked in every port, even where the answer is never no.
if (kaya.capabilities().auxWindows) {
  app.createWindow(UNTITLED, { width: 360, height: 240 }, () => {
    const caption = kaya.signal("no title of its own");
    kaya.column(() => {
      kaya.label({ bind: caption }); // label#2
    });
  });
}

app.run();
