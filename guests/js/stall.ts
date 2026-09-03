// THE ONE GUEST THAT MISUSES KAYA ON PURPOSE (tools/scenes/stall.steps):
// `block` sleeps on the app thread and `ping` makes work PENDING.

import * as kaya from "kaya-gui";

const app = new kaya.App();

// Past the watchdog's one-second threshold, and no longer.
const BLOCK_SECONDS = 2.5;

// A day, never a literal park (docs/traps.md, "The stall scene wedges for
// a DAY").
const WEDGE_SECONDS = 86400;

// JS has no sleep: Atomics.wait on a word nobody notifies is the blocking
// one, and blocking is the point here.
const PARK = new Int32Array(new SharedArrayBuffer(4));

function sleep(seconds: number): void {
  Atomics.wait(PARK, 0, 0, seconds * 1000);
}

function block(): void {
  // DELIBERATELY WRONG, and the only place in this repo that is.
  sleep(BLOCK_SECONDS);
}

function wedge(): void {
  sleep(WEDGE_SECONDS);
}

function ping(): void {
  status.set("pinged");
}

let status!: kaya.Signal<string>;

app.window({ title: "stall" }, () => {
  status = kaya.signal("ready");
  kaya.column(() => {
    kaya.label({ bind: status }).a11yId("status"); // label#0
    kaya.button("block", { onClick: block }); // button#0
    kaya.button("ping", { onClick: ping }); // button#1
    kaya.button("wedge", { onClick: wedge }); // button#2
  });
});

app.run();
