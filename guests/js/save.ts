// The save conformance scene, JS port — the ROUND TRIP an editor
// actually walks (docs/save-plan.md D5): open a file, edit it, save it
// back, save it AS somewhere new, then reopen both and prove the bytes
// are where they belong. The four claims it drives are docs/save-plan.md
// D1's numbered list.
//
// EVERY STATUS IS A READ-BACK OFF THE DISK, never what the guest hoped it
// wrote: a write that returned success and landed nowhere is exactly the
// failure "save" has, and only reopening sees it.
//
// THE FILE IS READ THROUGH THE HANDLE, NEVER THROUGH `localPath` — that
// name is empty on both phones, so a port that reached for it would pass
// on the desktops and be unportable by construction.
//
// NO EXTENSIONS ON THE NAMES: a hidden-extension Finder preference would
// make `expect_save_dialog` read the stem on one machine and the whole
// name on another (docs/deferred.md).
//
// See guests/rust/save.rs and tools/scenes/save.steps.

import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as kaya from "kaya-gui";

const app = new kaya.App();

// Both halves compute this identically, each in its own language's way.
// `os.tmpdir()` and NEVER `TMPDIR` — see docs/traps.md.
const saveDir = join(tmpdir(), `kaya-save-${process.pid}`);
mkdirSync(saveDir, { recursive: true });
// The file the scene opens, plus the decoy the picker needs (see
// guests/js/filedialog.ts). "decoy" MUST sort before "draft".
writeFileSync(join(saveDir, "draft"), "first draft", { encoding: "utf-8" });
writeFileSync(join(saveDir, "decoy"), "decoy", { encoding: "utf-8" });

// Held as handles, never as paths: the phones have no re-openable path,
// and the desktops must not be allowed to pass with one.
let source: kaya.PickedFile | null = null;
let destination: kaya.PickedFile | null = null;

/** What a failed file operation says about itself. */
function reason(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** Read a handle back through kaya, with the guest's own file API. */
function readBack(picked: kaya.PickedFile): string {
  // The addon reads over the platform handle — the same spelling on
  // every desktop, Windows included (docs/js-plan.md §6).
  try {
    return new TextDecoder().decode(picked.read());
  } catch (e) {
    return `read failed: ${reason(e)}`;
  }
}

function writeBack(picked: kaya.PickedFile, text: string): string {
  // What the save dialog handed back opens EMPTY (docs/save-plan.md D1):
  // the addon writes the bytes, then the read-back is the proof.
  try {
    picked.write(text);
  } catch (e) {
    return `write failed: ${reason(e)}`;
  }
  return readBack(picked);
}

/** Run one file operation and post the answer back. The python version
 * hands `job` to a thread of its own; the app-thread worker has no
 * thread, so the job runs here and the ANSWER is still posted, which is
 * the half the scene can see. */
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
  // Save-back needs no dialog — the user already chose this file, and
  // the handle they chose it with is writable. A missing handle is an
  // open that never landed (cancelled, or the dialog swallowed under
  // load) — its OWN sentence, never a crash: a crashed guest takes the
  // process and masks the real failure (docs/deferred.md, save-jvm
  // WATCH).
  const file = source;
  if (file === null) {
    status.set("nothing open to save");
    return;
  }
  work(() => `saved ${writeBack(file, "second draft")}`);
}

async function saveAs(): Promise<void> {
  // The suggested name the dialog OPENS with; the harness types over it.
  // NO FILTER here either, and that one matters: with allowed content
  // types set, NSSavePanel appends the first allowed extension to an
  // extension-less name (docs/deferred.md).
  saved(await kaya.saveFile("copy"));
}

function reopen(): void {
  // BOTH, in order: a save that went to the wrong handle passes every
  // earlier step and fails here. The missing-handle guard, same reason
  // as saveBack's.
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
