// The clipboard conformance scene (tools/scenes/clipboard.steps): a FOREIGN
// tool seeds and reads, because kaya reading its own bytes proves nothing.

import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as kaya from "kaya-gui";

const app = new kaya.App();

// `os.tmpdir()` and NEVER `TMPDIR` — docs/traps.md, the POSIX-spelling
// trap that wrote to the root of a Windows drive.
const sceneDir = join(tmpdir(), `kaya-clip-${process.pid}`);
mkdirSync(sceneDir, { recursive: true });

// A real 4x4 PNG: the scene asserts "4x4" through a FOREIGN decoder.
const PIXEL_PNG = new Uint8Array([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // signature
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
  0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, // 4 x 4
  0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09, // 8-bit rgb + crc
  0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41, // IDAT length + type
  0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
  0x47, 0x48, 0x4c, 0x74, 0xde, 0x7f, 0x24, 0x00,
  0x00, 0xd2, 0x6f, 0x17, 0xe9, 0x51, 0xbb, 0x23,
  0x2d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
  0x44, 0xae, 0x42, 0x60, 0x82, // IEND + crc
]);

// Reverse-DNS and space-free: it reaches every registry VERBATIM.
const NOTE_ID = "dev.kaya/note";
// NO QUOTES IN THE PAYLOAD: the step grammar has no \" escape.
const NOTE_BYTES = new TextEncoder().encode("note=1");

writeFileSync(join(sceneDir, "pixel.png"), PIXEL_PNG);
writeFileSync(join(sceneDir, "pasted.txt"), "pasted bytes", { encoding: "utf-8" });

function copyRich(): void {
  // One clip, four representations; kaya derives none from any other.
  kaya.copy({ text: "kaya clip", html: "<b>kaya</b> clip", image: PIXEL_PNG, custom: { [NOTE_ID]: NOTE_BYTES } });
  status.set("copied");
}

function answered(clip: kaya.Clip | null): void {
  // EMPTY IS THE UNIVERSAL NO; no platform says which cause.
  if (clip === null) {
    status.set("empty");
    return;
  }
  if (clip instanceof kaya.Representation.Text) {
    status.set(`text ${clip.text}`);
    return;
  }
  if (clip instanceof kaya.Representation.Html) {
    status.set(`html ${clip.html}`);
    return;
  }
  if (clip instanceof kaya.Representation.Custom) {
    status.set(`custom ${clip.id} ${new TextDecoder().decode(clip.bytes)}`);
    return;
  }
  if (clip instanceof kaya.Representation.Image) {
    // A foreign DECODER's size: byte counts differ per host.
    kaya.copy({ image: clip.bytes });
    status.set("image");
    return;
  }
  const files = clip.files;
  if (files.length === 0) {
    status.set("files none");
    return;
  }
  // A pasted file is redeemed like a picked one (guests/js/filedialog.ts).
  const file = files[0]!;
  const name = file.name;
  let text: string;
  try {
    // The addon reads over the platform handle (docs/js-plan.md §6).
    text = new TextDecoder().decode(file.read());
  } catch (e) {
    text = `open failed: ${e instanceof Error ? e.message : String(e)}`;
  }
  app.post(() => status.set(`files ${name} ${text}`));
  status.set("reading");
}

// The continuation after an await is its own transaction (js-plan §4).
async function readCustom(): Promise<void> {
  answered(await kaya.readClipboard([NOTE_ID]));
}

async function readText(): Promise<void> {
  answered(await kaya.readClipboard([kaya.ACCEPT_TEXT]));
}

async function readImage(): Promise<void> {
  answered(await kaya.readClipboard([kaya.ACCEPT_IMAGE]));
}

async function readFiles(): Promise<void> {
  answered(await kaya.readClipboard([kaya.ACCEPT_FILES]));
}

function pasted(clip: kaya.Clip | null): void {
  if (clip instanceof kaya.Representation.Text) status.set(`pasted ${clip.text}`);
  else status.set(`pasted ${String(clip)}`);
}

function rowPasted(row: kaya.RowHandle<string>, clip: kaya.Clip | null): void {
  // Printing the key proves this dispatched as an INSTANCE occurrence.
  if (clip instanceof kaya.Representation.Text) rowStatus.set(`row ${row.key} pasted ${clip.text}`);
  else rowStatus.set(`row ${row.key} pasted ${String(clip)}`);
}

let status!: kaya.Signal<string>;
let rowStatus!: kaya.Signal<string>;
let rich!: kaya.Widget;
let plain!: kaya.Widget;

app.window({ title: "clipboard" }, () => {
  app.menu("Edit", () => {
    kaya.item("Cut", { role: kaya.ROLE_CUT });
    kaya.item("Copy", { role: kaya.ROLE_COPY });
    kaya.item("Paste", { role: kaya.ROLE_PASTE });
  });

  status = kaya.signal("ready");
  rowStatus = kaya.signal("");
  kaya.column(() => {
    kaya.label({ bind: status }).a11yId("status"); // label#0
    kaya.button("copy", { onClick: copyRich }); // button#0
    kaya.button("read custom", { onClick: readCustom }); // button#1
    kaya.button("read text", { onClick: readText }); // button#2
    kaya.button("read image", { onClick: readImage }); // button#3
    kaya.button("read files", { onClick: readFiles }); // button#4
    kaya.button("focus rich", { onClick: () => rich.focus() }); // button#5
    kaya.button("focus plain", { onClick: () => plain.focus() }); // button#6

    // Declares what it takes, so a paste lands in the hook.
    rich = kaya.entry().accepts(kaya.ACCEPT_TEXT).onPaste(pasted);
    rich.a11yId("rich"); // entry#0
    // Declares nothing, so the platform inserts and onChange reports.
    plain = kaya.entry().a11yId("plain"); // entry#1

    // On a STAMPED copy the accept list rides the TEMPLATE.
    kaya.label({ bind: rowStatus }).a11yId("row-status"); // label#1
    const rows = kaya.collection();
    for (const _row of rows) {
      kaya.entry().accepts(kaya.ACCEPT_TEXT).onPaste(rowPasted);
    }
    rows.insert("r1", ""); // entry#2
  });
});

app.run();
