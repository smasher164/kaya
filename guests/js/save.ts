// The save round trip (tools/scenes/save.steps). EVERY STATUS IS A READ-BACK
// OFF THE DISK, through the HANDLE, and no name carries an extension.

import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as kaya from "kaya-gui";

const app = new kaya.App();

// `os.tmpdir()` and NEVER `TMPDIR` — docs/traps.md.
const saveDir = join(tmpdir(), `kaya-save-${process.pid}`);
mkdirSync(saveDir, { recursive: true });
// The decoy MUST sort before "draft" (guests/js/filedialog.ts says why).
writeFileSync(join(saveDir, "draft"), "first draft", { encoding: "utf-8" });
writeFileSync(join(saveDir, "decoy"), "decoy", { encoding: "utf-8" });

// HANDLES and never paths: the phones have no re-openable path.
let source: kaya.PickedFile | null = null;
let destination: kaya.PickedFile | null = null;

/** What a failed file operation says about itself. */
function reason(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** Read a handle back through kaya, with the guest's own file API. */
function readBack(picked: kaya.PickedFile): string {
  // The addon reads over the platform handle (docs/js-plan.md §6).
  try {
    return new TextDecoder().decode(picked.read());
  } catch (e) {
    return `read failed: ${reason(e)}`;
  }
}

function writeBack(picked: kaya.PickedFile, text: string): string {
  // What the dialog handed back opens EMPTY (docs/save-plan.md D1).
  try {
    picked.write(text);
  } catch (e) {
    return `write failed: ${reason(e)}`;
  }
  return readBack(picked);
}

/** One file operation, with the ANSWER posted: this worker has no second
 * thread to hand the job to. */
function work(job: () => string): void {
  const text = job();
  app.post(() => status.set(text));
}

function picked(files: kaya.PickedFile[]): void {
  if (files.length === 0) {
    status.set("open cancelled");
    return;
  }
  const file = files[0]!;
  source = file;
  work(() => `opened ${readBack(file)}`);
}

function saved(file: kaya.PickedFile | null): void {
  if (file === null) {
    status.set("save cancelled");
    return;
  }
  destination = file;
  work(() => `saved ${writeBack(file, "third draft")}`);
}

async function openFile(): Promise<void> {
  picked(await kaya.pickFile());
}

function saveBack(): void {
  // No dialog: the chosen handle is writable. A missing one gets its OWN
  // sentence, never a crash (docs/deferred.md, save-jvm WATCH).
  const file = source;
  if (file === null) {
    status.set("nothing open to save");
    return;
  }
  work(() => `saved ${writeBack(file, "second draft")}`);
}

async function saveAs(): Promise<void> {
  // The name the dialog OPENS with. NO FILTER either: with types set,
  // NSSavePanel appends an extension (docs/deferred.md).
  saved(await kaya.saveFile("copy"));
}

function reopen(): void {
  // A save through the wrong handle fails only here.
  const first = source;
  const second = destination;
  if (first === null || second === null) {
    status.set("nothing to reopen");
    return;
  }
  work(() => `reopened ${readBack(first)} ${readBack(second)}`);
}

let status!: kaya.Signal<string>;

app.window({ title: "save" }, () => {
  status = kaya.signal("no file");
  kaya.column(() => {
    kaya.label({ bind: status }).a11yId("status"); // label#0
    kaya.button("open", { onClick: openFile }); // button#0
    kaya.button("save", { onClick: saveBack }); // button#1
    kaya.button("save as", { onClick: saveAs }); // button#2
    kaya.button("reopen", { onClick: reopen }); // button#3
  });
});

app.run();
