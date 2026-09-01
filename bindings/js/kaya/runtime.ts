// kaya runtime for JS guests: loading, the function floor, and the two
// threads. Hand-written; wire.ts beside it is generated.
//
// THE MAIN THREAD IS SURRENDERED AT IMPORT (docs/js-plan.md §3): the
// process main thread enters kaya_run and becomes the core's UI thread,
// and the guest's own module runs again in a worker_thread, which IS the
// kaya-app thread. Importing this module on the main thread therefore
// never returns; the guest's top-level code only ever runs in the worker.

import { existsSync, writeSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Worker, isMainThread, workerData } from "node:worker_threads";

import * as wire from "./wire.ts";

type Floor = {
  specHash(): bigint;
  capabilities(): number;
  run(): number;
  submit(records: Uint8Array): void;
  blobRegister(bytes: Uint8Array): number;
  occurrenceBlob(handle: number): Uint8Array;
  assetOpen(name: string): number;
  assetBytes(handle: number): Uint8Array;
  assetLen(handle: number): number;
  assetBlob(handle: number): number;
  assetRelease(handle: number): void;
  assetWhyNot(name: string): string;
  openPicked(handle: number, mode: number): { raw: number; seekable: boolean };
  startPump(cb: (record: Uint8Array | null) => void): void;
  exit(code: number): never;
};

function findLibrary(): string {
  const fromEnv = process.env["KAYA_LIB"];
  if (fromEnv) return fromEnv;
  const name = { darwin: "libkaya.dylib", win32: "kaya.dll" }[process.platform as string] ?? "libkaya.so";
  let here = dirname(fileURLToPath(import.meta.url));
  for (;;) {
    for (const candidate of [join(here, name), join(here, "target", "debug", name)]) {
      if (existsSync(candidate)) return candidate;
    }
    const up = dirname(here);
    if (up === here) break;
    here = up;
  }
  throw new Error(`${name} not found; build with cargo or set KAYA_LIB`);
}

function loadLibrary(): Floor {
  // libkaya is the addon (crates/kaya/src/node.rs): process.dlopen
  // finds napi_register_module_v1 in it, whatever the file is called.
  const holder = { exports: {} as Floor };
  process.dlopen(holder, resolve(findLibrary()));
  return holder.exports;
}

const lib = loadLibrary();

// The stale-artifact guard: this binding was generated from one spec
// revision and the loaded core must speak the same one.
if (lib.specHash() !== wire.SPEC_HASH) {
  throw new Error(
    `kaya: library speaks spec 0x${lib.specHash().toString(16)}, this binding was ` +
      `generated from 0x${wire.SPEC_HASH.toString(16)} — rebuild the library or regenerate bindings`,
  );
}

// THE HOST CAPABILITY WORD (kaya.capabilities() is the sugar over it).
// CAP_AUX_WINDOWS IS THE CORE'S NUMBER WRITTEN AGAIN — there is no header
// to read it out of. tools/check-sugar-surface.sh holds this line to
// crates/kaya/src/scene.rs.
export const CAP_AUX_WINDOWS = 1;

/** The raw capability word. The binding's floor: guests read named
 * booleans off kaya.capabilities() and never see this. */
export function capabilityBits(): number {
  return lib.capabilities();
}

// Copy then release, in that order: the addon does both inside
// occurrenceBlob, and the generated decoder calls this while decoding so
// no handle ever reaches an app.
wire.install_occurrence_blob((handle) => lib.occurrenceBlob(handle));

/** The one test seam: bindings/js/kaya_app_checks.ts routes submits into
 * a list so the binding's bookkeeping can be checked without entering
 * the core (the python checks reassign kaya.runtime.submit the same way;
 * an ES module's exports are frozen, so the seam is a property). */
export const hooks: { submit: ((records: readonly Uint8Array[]) => void) | null } = { submit: null };

/** Submit one transaction: the concatenation of packed records (tx_*
 * results from wire.ts), applied atomically. */
export function submit(records: readonly Uint8Array[]): void {
  if (hooks.submit !== null) {
    hooks.submit(records);
    return;
  }
  let n = 0;
  for (const r of records) n += r.length;
  const tx = new Uint8Array(n);
  let at = 0;
  for (const r of records) {
    tx.set(r, at);
    at += r.length;
  }
  lib.submit(tx);
}

/** Register bulk payload bytes with the core: one copy into core-owned
 * memory, returning the u64 handle the next submit consumes whether
 * referenced or not. The caller's bytes may be dropped. */
export function registerBlob(data: Uint8Array): number {
  if (!(data instanceof Uint8Array)) {
    throw new TypeError(`kaya: blob data must be a Uint8Array, not ${describe(data)}`);
  }
  return lib.blobRegister(data);
}

/** The runtime name of a value, for error sentences. */
export function describe(v: unknown): string {
  if (v === null) return "null";
  if (v === undefined) return "undefined";
  if (typeof v === "object" || typeof v === "function") {
    const name = (v as { constructor?: { name?: string } }).constructor?.name;
    return name && name !== "Object" ? name : typeof v;
  }
  return typeof v;
}

/** Open an asset by name; 0 is the MISS, and assetMissSentence says why.
 * ZERO RATHER THAN A THROW FROM THE CORE: a panic inside an extern "C"
 * frame is an uncatchable process abort, so the core answers a value and
 * the BINDING throws. */
export function assetOpen(name: string): number {
  return lib.assetOpen(name);
}

/** An open asset's bytes, copied out of core memory. */
export function assetBytes(handle: number): Uint8Array {
  return lib.assetBytes(handle);
}

/** An open asset's byte count. 0 means the HANDLE is dead, never the
 * file: the core refuses a zero-byte asset at the open. */
export function assetLen(handle: number): number {
  return lib.assetLen(handle);
}

/** THE BLOB REDEMPTION: register this asset's bytes into the pending
 * table and get the handle the next submit consumes. The bytes never
 * enter JS — the core clones one refcount. */
export function assetBlob(handle: number): number {
  return lib.assetBlob(handle);
}

/** Drop an open asset. Idempotent. */
export function assetRelease(handle: number): void {
  lib.assetRelease(handle);
}

// NAMED FOR THE CARRYING, not for the answering, and deliberately not
// `assetWhyNot`: tools/check-diagnostics.sh reads any *why_not/*WhyNot by
// that name and holds it to the measured-branch rule, which the function
// that EARNED the name satisfies (crates/kaya/src/assets.rs). This copies
// that sentence's bytes and observes nothing.
export function assetMissSentence(name: string): string {
  return lib.assetWhyNot(name);
}

/** Redeem a picked handle: `{fd, seekable}` — a descriptor `node:fs`
 * takes, and whether it supports random access.
 *
 * BLOCKS, possibly for a long time — a cloud provider may download the
 * file first (DESIGN.md, File dialogs).
 *
 * THE DESCRIPTOR BECOMES NODE'S: close it with fs.closeSync. On Windows
 * the core hands back a HANDLE rather than a CRT descriptor, and Node
 * links its own CRT, so the redemption there is docs/js-plan.md §6's
 * open item and refused here by name. */
export function openPicked(handle: number, mode: number): { fd: number; seekable: boolean } {
  if (process.platform === "win32") {
    throw new Error(
      "kaya: opening a picked file is not wired on Windows for the JS binding yet " +
        "(docs/js-plan.md §6) — read it by its local_path where the picker supplied one",
    );
  }
  const { raw, seekable } = lib.openPicked(handle, mode);
  return { fd: raw, seekable };
}

/** From the worker, end the PROCESS with a code: process.exit there ends
 * only the worker thread while the main thread sits in kaya_run. */
export function exitProcess(code: number): never {
  return lib.exit(code);
}

/** Start the occurrence pump: cb(record) per occurrence, cb(null) at
 * shutdown, each call waited for before the next record is taken
 * (crates/kaya/src/node.rs). Worker only. */
export function startPump(cb: (record: wire.Occurrence | null) => void): void {
  lib.startPump((bytes) => {
    if (bytes === null) {
      cb(null);
      return;
    }
    const occ = wire.parse_occurrence(bytes);
    if (occ.id !== null) cb(occ);
  });
}

/** The entry module in the worker: the same file the process was
 * started with, so the guest's own code runs there. */
export const IS_APP_THREAD = !isMainThread;

// The worker's stdio is a stream posted to the parent, whose event loop
// is blocked inside kaya_run for the life of the process, so console
// output would never surface. Written straight to the descriptors here.
if (!isMainThread) {
  const direct = (fd: number) => (chunk: unknown, encoding?: unknown, cb?: unknown) => {
    const text = typeof chunk === "string" ? chunk : String(chunk);
    writeSync(fd, text);
    const done = typeof encoding === "function" ? encoding : cb;
    if (typeof done === "function") (done as () => void)();
    return true;
  };
  (process.stdout as { write: unknown }).write = direct(1);
  (process.stderr as { write: unknown }).write = direct(2);
  process.on("uncaughtException", (err: unknown) => {
    const text = err instanceof Error ? err.stack ?? err.message : String(err);
    writeSync(2, `${text}\n`);
    lib.exit(1);
  });
}

/** Enter the core on the main thread after spawning the app worker on
 * the entry module. Never returns: the process exits with kaya_run's
 * code when the app ends. Called at import by index.ts on the main
 * thread, so a guest's module body only ever runs in the worker. */
export function surrenderMainThread(): never {
  const entry = process.argv[1];
  if (!entry) {
    writeSync(2, "kaya: no entry module — run the app as `node app.ts`\n");
    process.exit(2);
  }
  // execArgv rides along (type stripping flags, inspector); argv past
  // the entry is the app's own. workerData marks the spawn so a guest
  // that reads it can tell the two threads apart.
  new Worker(resolve(entry), {
    argv: process.argv.slice(2),
    execArgv: process.execArgv,
    workerData: { kayaAppThread: true },
  });
  // The addon's own exit, not process.exit: the verdict is out and the
  // pump has been waited for inside run(); Node's teardown of a live
  // worker is the exit-path crash this avoids (docs/js-plan.md §3).
  return lib.exit(lib.run());
}

export const spawnedByKaya: boolean = (workerData as { kayaAppThread?: boolean } | null)?.kayaAppThread === true;
