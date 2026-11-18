// The references scene (tools/scenes/references.steps,
// docs/restoration-plan.md SR11, SR12): a picked file's durable reference
// rides the session store across a relaunch and redeems for its bytes; a
// foreign token and a deleted file are refused by name.

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as kaya from "kaya-gui";

const app = new kaya.App();

const dir = join(tmpdir(), `kaya-refs-${process.pid}`);
mkdirSync(dir, { recursive: true });
writeFileSync(join(dir, "picked.txt"), "picked bytes", { encoding: "utf-8" });
writeFileSync(join(dir, "decoy.txt"), "decoy", { encoding: "utf-8" });

const store = kaya.appSession();
const saved = store.getString("doc", "");

// The bytes a token redeems for, or the refusal's branch; the sentence goes
// to stderr, where the leg log keeps it.
function readBack(token: string): string {
  try {
    return `redeemed: ${new TextDecoder().decode(kaya.redeem(token).file.read())}`;
  } catch (e) {
    if (e instanceof kaya.KayaReferenceError) {
      process.stderr.write(`references: ${e.message}\n`);
      return e.refusal;
    }
    return `open failed: ${String(e)}`;
  }
}

function reader(token: string): void {
  setImmediate(() => {
    const said = readBack(token);
    app.post(() => status.set(said));
  });
}

async function pick(): Promise<void> {
  const file = await kaya.pickFile({ filters: [["Text", "txt"]] });
  if (file === null) {
    status.set("cancelled");
    return;
  }
  try {
    store.setString("doc", file.reference());
    status.set("minted");
  } catch (e) {
    if (!(e instanceof kaya.KayaReferenceError)) throw e;
    process.stderr.write(`references: ${e.message}\n`);
    status.set(e.refusal);
  }
}

function remove(): void {
  try {
    const path = kaya.redeem(saved).file.localPath;
    if (path !== null) rmSync(path, { force: true });
  } catch {
    // The read below names what is left.
  }
  reader(saved);
}

const { status } = app.window({ title: "references" }, () => {
  const status = kaya.signal(saved === "" ? "no reference" : "redeeming");
  kaya.column(() => {
    kaya.label({ bind: status }).a11yId("status");
    kaya.button("pick", { onClick: pick }).a11yId("pick");
    kaya.button("foreign", { onClick: () => reader("kaya-ref1:beos:AAAA:00000000") }).a11yId("foreign");
    kaya.button("delete", { onClick: remove }).a11yId("delete");
  });
  return { status };
});

if (saved !== "") reader(saved);

app.run();
