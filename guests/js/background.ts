// The background scene (tools/scenes/background.steps). THE PARK IS AN
// AWAIT: this worker has one thread, and blocking starves its own release.

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
    // Parks: work on the app thread would starve the release click.
    await released;
    // app.commit() ends each implicit transaction (docs/js-plan.md §4).
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
  // A post from INSIDE a handler QUEUES for after; it never nests.
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
    // Addressed by id: an index read passes for an empty arm.
    kaya.label({ bind: detail }).a11yId("nested"); // label#2
    kaya.button("start", { onClick: start }); // button#0
    kaya.button("ping", { onClick: ping }); // button#1
    kaya.button("release", { onClick: release }); // button#2
    kaya.button("nest", { onClick: nest }); // button#3
  });
});

app.run();
