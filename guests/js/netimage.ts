// The network images affordance scene (tools/scenes/netimage.steps;
// docs/network-images-plan.md §5). No HTTP: each "download" is a job a
// worker holds until a click releases it, background.steps' principle. THE
// PARK IS AN AWAIT: this worker has one thread. See guests/rust/netimage.rs.

import * as kaya from "kaya-gui";

const Track = kaya.record({ title: String, artUrl: String, art: Uint8Array, phase: kaya.ImagePhase }, "Track");

const ROWS = 300;

// A "download" the worker holds: the live image's when `key` is null, and
// `data` null when it fails.
type Job = { key: string | null; url: string; data: Uint8Array | null };

const app = new kaya.App();
const covers = ["covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"].map((name) => kaya.asset(name).bytes());

const batches: Job[][] = [];
let wake: (() => void) | null = null;

function send(batch: Job[]): void {
  batches.push(batch);
  wake?.();
}

async function worker(): Promise<void> {
  for (;;) {
    while (batches.length === 0) await new Promise<void>((resolve) => (wake = resolve));
    for (const job of batches.shift()!) {
      if (job.key !== null) tracks.patch(job.key, { art: job.data!, phase: kaya.ImagePhase.SHOWN }, { when: { artUrl: job.url } });
      else if (job.data === null) phase.set(kaya.ImagePhase.FAILED);
      else {
        art.set(job.data);
        phase.set(kaya.ImagePhase.SHOWN);
      }
      await app.commit();
    }
  }
}

let live: Job | null = { key: null, url: "", data: covers[0]! };
let pending: Job[] = [];
const needed = new Set<string>();
const ever = new Set<string>();
let twice: string | null = null;

function onRelease(): void {
  if (live !== null) {
    send([live]);
    live = null;
  }
}

function onRefresh(): void {
  live = { key: null, url: "", data: covers[1]! };
  phase.set(kaya.ImagePhase.LOADING);
}

function onJunk(): void {
  art.set(new TextEncoder().encode("not an image"));
  phase.set(kaya.ImagePhase.SHOWN);
}

function onFail(): void {
  live = { key: null, url: "", data: null };
  art.set(new Uint8Array());
  phase.set(kaya.ImagePhase.LOADING);
}

function onNeeded(row: kaya.RowHandle<ReturnType<typeof Track>>): void {
  const key = String(row.key);
  if (needed.has(key) && twice === null) twice = key;
  needed.add(key);
  ever.add(key);
  const i = Number(key.slice(1));
  pending.push({ key, url: `u/${i}`, data: covers[i % 3]! });
  band.set(ever.size < ROWS ? "band: partial" : `band: ${ever.size}`);
  again.set(`again: ${twice ?? "none"}`);
}

function onReleased(row: kaya.RowHandle<ReturnType<typeof Track>>): void {
  const key = String(row.key);
  needed.delete(key);
  pending = pending.filter((job) => job.key !== key);
  released.set("released: some");
}

function onRows(): void {
  needed.clear();
  send(pending);
  pending = [];
}

function onDelete(): void {
  tracks.remove("t299");
}

function onRetarget(): void {
  pending.unshift({ key: "t298", url: "u/298b", data: covers[2]! });
  tracks.patch("t298", { artUrl: "u/298b" });
}

const { art, phase, band, released, again, tracks } = app.window({ title: "netimage", width: 820, height: 640 }, () => {
  const art = kaya.signal(new Uint8Array());
  const phase = kaya.signal(kaya.ImagePhase.LOADING);
  const band = kaya.signal("band: -");
  const released = kaya.signal("released: none");
  const again = kaya.signal("again: none");
  const tracks = kaya.collection(Track);
  kaya.column(() => {
    kaya.column(() => {
      kaya.image(art, { fit: "cover", phase }).maxWidth(96).maxHeight(96).a11yId("cover").a11yLabel("Cover");
      for (const pair of [[["release", onRelease], ["refresh", onRefresh]], [["junk", onJunk], ["fail", onFail]]] as const) {
        kaya.row(() => {
          for (const [name, fn] of pair) {
            kaya.button(name, { onClick: fn }).a11yId(name);
          }
        });
      }
      kaya.row(() => {
        for (const [name, fn] of [["rows", onRows], ["delete", onDelete], ["retarget", onRetarget]] as const) {
          kaya.button(name, { onClick: fn }).a11yId(name);
        }
      });
      kaya.label({ bind: band }).a11yId("band");
      kaya.label({ bind: released }).a11yId("released");
      kaya.label({ bind: again }).a11yId("again");
    });
    for (const track of tracks.columns(["Art", "Title"], { grow: 1, a11yId: "tracks" })) {
      kaya.row(() => {
        kaya.image(track.art, { fit: "cover", phase: track.phase, onNeeded, onReleased }).maxWidth(20).maxHeight(20).a11yId("art");
        kaya.label({ bind: track.title });
      });
    }
  });
  for (let i = 0; i < ROWS; i++) {
    const key = `t${String(i).padStart(3, "0")}`;
    tracks.insert(key, Track({ title: `Track ${i}`, artUrl: `u/${i}`, art: new Uint8Array(), phase: kaya.ImagePhase.LOADING }));
  }
  return { art, phase, band, released, again, tracks };
});

void worker();
app.run();
