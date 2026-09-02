// The filedialog conformance scene, JS port — the picker's
// request/result grammar and the capability it hands back (DESIGN.md,
// File dialogs).
//
// The guest does not assert that a dialog closed: it opens the handle it
// was given, reads the file with ORDINARY node:fs, and writes what it
// read into a signal, so `expect label#0 "1 picked bytes"` fails unless a
// real descriptor came back carrying the real file.
//
// THE FILE IS THE GUEST'S OWN, written before anything is shown, so guest
// and interpreter agree on a path with no runner involvement. The pid
// keeps parallel legs from colliding, and the scene names only the
// BASENAME so one script serves every lane.
//
// THE ANSWER IS HELD UNTIL A CLICK RELEASES IT. Python hands the blocking
// read to a thread that parks on an Event; the app-thread worker has no
// thread to hand it to, so the read happens in the handler and the
// ANSWER waits in a variable that only the release click delivers. That
// keeps the property the scene is here for: a guest that delivered
// inline is caught by `expect label#0 "reading"`, and the click below it
// is what proves the app thread still served input in between.
//
// See guests/rust/filedialog.rs and tools/scenes/filedialog.steps.

import { closeSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as kaya from "kaya-gui";

const app = new kaya.App();

// Both halves compute this identically, each in its own language's way.
// `os.tmpdir()` and NEVER `TMPDIR` — see docs/traps.md, the POSIX-spelling
// trap that aimed the guest at the root of the current drive on Windows
// while the picker opened on the real temp directory.
const pickedDir = join(tmpdir(), `kaya-picked-${process.pid}`);
mkdirSync(pickedDir, { recursive: true });
// The decoy MUST sort before picked.txt: pressing Open with nothing
// selected still returns a file (docs/traps.md), so a backend that skips
// selection has to get the WRONG one.
writeFileSync(join(pickedDir, "picked.txt"), "picked bytes", { encoding: "utf-8" });
writeFileSync(join(pickedDir, "decoy.txt"), "decoy", { encoding: "utf-8" });

// The release gate: the click sets it, the held answer reads it. The
// click must NOT wait for anything.
let released = false;
let held: string | null = null;

function deliver(): void {
  if (!released || held === null) return;
  const text = held;
  held = null;
  app.post(() => status.set(text));
}

function picked(files: kaya.PickedFile[]): void {
  if (files.length === 0) {
    // The empty list IS cancel.
    status.set("cancelled");
    return;
  }

  // Redeemed and read with the guest's own file API, which is the claim:
  // kaya is not in this data path.
  const count = files.length;
  const file = files[0]!;
  let text: string;
  try {
    const { fd } = file.open(kaya.wire.FILE_MODE_READ);
    try {
      text = readFileSync(fd).toString("utf-8");
    } finally {
      closeSync(fd);
    }
  } catch (e) {
    text = `open failed: ${e instanceof Error ? e.message : String(e)}`;
  }
  // Parks holding the result: delivering it here would leave the release
  // click with nothing to prove.
  held = `${count} ${text}`;
  deliver();
  // The handler RETURNED without delivering; the scene asserts this text.
  status.set("reading");
}

function release(): void {
  released = true;
  deliver();
}

// The dialog is a promise of the files; `picked` runs in the
// continuation, which is its own transaction (docs/js-plan.md §4).
async function ask(): Promise<void> {
  // Filters are ADVISORY on every platform — a default view, never a
  // guarantee — so the guest still validates what it got.
  picked(await kaya.pickFiles({ filters: [["Text", "txt"]] }));
}

async function askOne(): Promise<void> {
  picked(await kaya.pickFile({ filters: [["Text", "txt"]] }));
}

let status!: kaya.Signal<string>;

app.window({ title: "filedialog" }, () => {
  status = kaya.signal("no file");
  kaya.column(() => {
    kaya.label({ bind: status }).a11yId("status"); // label#0
    kaya.button("open", { onClick: ask }); // button#0
    kaya.button("open one", { onClick: askOne }); // button#1
    kaya.button("release", { onClick: release }); // button#2
  });
});

app.run();
