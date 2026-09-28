// The fullscreen scene (tools/scenes/fullscreen.steps,
// docs/fullscreen-plan.md §5). The app keeps its own copy of the state: a
// toggle writes !on, and the user's door moves the copy through
// onFullscreenChanged.

import * as kaya from "kaya-gui";

const app = new kaya.App();
let on = false;
let pinged = 0;

function toggle(): void {
  on = !on;
  app.window({ fullscreen: on });
  asked.set(on ? "asked for fullscreen" : "asked for a window");
}

function ping(): void {
  pinged += 1;
  pings.set(`pings ${pinged}`);
}

function changed(now: boolean): void {
  on = now;
  user.set(now ? "the user turned fullscreen on" : "the user turned fullscreen off");
}

const { asked, user, pings } = app.window({ title: "fullscreen", onFullscreenChanged: changed }, () => {
  const asked = kaya.signal("windowed");
  const user = kaya.signal("no change from the user");
  const pings = kaya.signal("pings 0");
  kaya.column(() => {
    kaya.label({ bind: asked }); // label#0
    kaya.label({ bind: user }); // label#1
    kaya.label({ bind: pings }); // label#2
    kaya.button("toggle fullscreen", { onClick: toggle }); // button#0
    kaya.button("ping", { onClick: ping }); // button#1
  });
  return { asked, user, pings };
});

app.run();
