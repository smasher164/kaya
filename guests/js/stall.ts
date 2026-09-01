// The stall conformance scene, JS port — an app thread that stops taking
// its occurrences is REPORTED (DESIGN.md, Threading model and protocol).
//
// THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE, in every language:
// `block` sleeps on the app thread and the scene asserts that kaya
// NOTICES. The class is not hypothetical — see docs/deferred.md on the
// Haskell release that used a blocking `putMVar`.
//
// WHY THE SECOND CLICK MATTERS: the consumer cursor advances BEFORE a
// record reaches the guest, so a handler blocking on an empty queue is
// indistinguishable from an idle app. `ping` is what makes work PENDING
// while the app thread is gone, and that is what the watchdog sees.
//
// `wedge` never returns, which is the shape a real deadlock has — every
// assertion above would also pass for a merely SLOW handler. The leg
// still reports its verdict, because the harness runs on its own thread
// and asks the MAIN thread to exit.
//
// See guests/rust/stall.rs and tools/scenes/stall.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

// Comfortably past the watchdog's one-second threshold, and short enough
// that the leg is not paying for it.
const BLOCK_SECONDS = 2.5;

// A day, never a literal park (docs/traps.md, "The stall scene wedges
// for a DAY").
const WEDGE_SECONDS = 86400;

// JS has no sleep: Atomics.wait on a word nobody ever notifies is the
// blocking one, and blocking is the whole point here.
const PARK = new Int32Array(new SharedArrayBuffer(4));

function sleep(seconds: number): void {
  Atomics.wait(PARK, 0, 0, seconds * 1000);
}

function block(): void {
  // DELIBERATELY WRONG, and the only place in this repo that is. Real
  // work goes on its own thread with the result posted through
  // app.post.
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
