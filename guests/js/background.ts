// The background conformance scene, JS port — work off the app thread,
// posted back (docs/background-work-plan.md).
//
// THE SHAPE IS DELIBERATE: a wrong implementation must DEADLOCK rather
// than disagree. The worker parks until a CLICK releases it, and only a
// live app thread can process a click, so a binding that let background
// work occupy the app thread cannot even deliver its own release.
//
// THE PARK IS AN AWAIT HERE: the worker has no second thread, so the
// background is the app thread's own event loop and `released` is a
// promise the release click settles. Awaiting it hands the thread back —
// a guest that parked by blocking would starve that same click.
//
// The accumulators need no lock: everything that touches them runs on the
// app thread, inside a posted transaction.

import * as kaya from "kaya-gui";

const app = new kaya.App();

let releaseWorker!: () => void;
const released = new Promise<void>((resolve) => {
  releaseWorker = resolve;
});
const posted: string[] = [];
const nested: string[] = [];

function start(): void {
  async function worker(): Promise<void> {
    // Parks until the scene clicks release; work on the app thread
    // would leave that click unprocessed and deadlock the scene.
    await released;
    // Three transactions, in order: the accumulator makes this a test
    // of ORDER, not of which one ran last. The continuation's writes
    // are the implicit transaction and app.commit() ends each before
    // the next (docs/js-plan.md §4) — three batches, as three posts
    // would be.
    for (const step of ["1", "2", "3"]) {
      posted.push(step);
      status.set(posted.join(""));
      await app.commit();
    }
  }

  void worker();
  status.set("working");
}

function ping(): void {
  alive.set("alive");
}

function release(): void {
  releaseWorker();
}

function nest(): void {
  // A post from INSIDE a handler QUEUES for after; it never nests. The
  // handler appends a, posts a closure appending b, appends c — so it
  // commits "ac" and the posted closure then commits "acb". Nesting
  // can only ever produce "abc".
  nested.push("a");

  function land(): void {
    nested.push("b");
    detail.set(nested.join(""));
  }

  app.post(land);
  nested.push("c");
  detail.set(nested.join(""));
}

let status!: kaya.Signal<string>;
let alive!: kaya.Signal<string>;
let detail!: kaya.Signal<string>;

app.window({ title: "background" }, () => {
  status = kaya.signal("idle");
  alive = kaya.signal("-");
  detail = kaya.signal("-");
  kaya.column(() => {
    kaya.label({ bind: status }).a11yId("status"); // label#0
    kaya.label({ bind: alive }).a11yId("alive"); // label#1
    // Authored so the closing AX read can address it by identifier;
    // an index read passes for an arm that ran and drew nothing.
    kaya.label({ bind: detail }).a11yId("nested"); // label#2
    kaya.button("start", { onClick: start }); // button#0
    kaya.button("ping", { onClick: ping }); // button#1
    kaya.button("release", { onClick: release }); // button#2
    kaya.button("nest", { onClick: nest }); // button#3
  });
});

app.run();
