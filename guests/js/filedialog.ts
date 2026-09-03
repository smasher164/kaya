// The filedialog scene (tools/scenes/filedialog.steps). THE ANSWER IS HELD
// UNTIL A CLICK RELEASES IT: this worker has no second thread to park on.

import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as kaya from "kaya-gui";

const app = new kaya.App();

// `os.tmpdir()` and NEVER `TMPDIR` — docs/traps.md, the POSIX-spelling
// trap that aimed the guest at the root of a Windows drive.
const pickedDir = join(tmpdir(), `kaya-picked-${process.pid}`);
mkdirSync(pickedDir, { recursive: true });
// The decoy MUST sort before picked.txt: Open with nothing selected still
// returns a file (docs/traps.md).
writeFileSync(join(pickedDir, "picked.txt"), "picked bytes", { encoding: "utf-8" });
writeFileSync(join(pickedDir, "decoy.txt"), "decoy", { encoding: "utf-8" });

// The click sets it and must NOT wait for anything.
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

  const count = files.length;
  const file = files[0]!;
  let text: string;
  try {
    // The addon reads over the platform handle (docs/js-plan.md §6).
    text = new TextDecoder().decode(file.read());
  } catch (e) {
    text = `open failed: ${e instanceof Error ? e.message : String(e)}`;
  }
  // Held: delivering here would leave the release click nothing to prove.
  held = `${count} ${text}`;
  deliver();
  // The handler RETURNED without delivering; the scene asserts this text.
  status.set("reading");
}

function release(): void {
  released = true;
  deliver();
}

// The continuation after an await is its own transaction (js-plan §4).
async function ask(): Promise<void> {
  // Filters are ADVISORY: the guest still validates what it got.
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
