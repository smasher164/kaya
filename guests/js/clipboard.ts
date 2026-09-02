// The clipboard conformance scene, JS port — one clip in several
// representations, and the privileged read that takes one back
// (DESIGN.md, Clipboard; docs/clipboard-plan.md).
//
// Assertions cross a process boundary: a FOREIGN tool seeds and reads the
// clipboard, because a check where kaya reads what kaya wrote parses its
// own malformed header happily. The custom format is the one exception (no
// stock tool writes an app-defined type), and the image is asserted as a
// DECODED SIZE, never bytes — every host re-encodes freely.
//
// Canonical semantics in guests/rust/clipboard.rs; the byte-frozen
// contract in tools/scenes/clipboard.steps.

import { closeSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as kaya from "kaya-gui";

const app = new kaya.App();

// Guest and interpreter compute this identically, with no runner
// involvement; the pid keeps parallel legs from colliding. `os.tmpdir()`
// and NEVER `TMPDIR` — see docs/traps.md, the POSIX-spelling trap that
// wrote a guest's files to the root of the current drive on Windows.
const sceneDir = join(tmpdir(), `kaya-clip-${process.pid}`);
mkdirSync(sceneDir, { recursive: true });

// A real encoded 4x4 PNG, spelled out rather than generated: the scene
// asserts "4x4" through a foreign decoder. Written to disk for the
// seeding tool AND handed to copy() as bytes.
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

// Reverse-DNS and space-free: this id reaches every platform's own
// registry VERBATIM (a UTI, RegisterClipboardFormat, an X11 target atom,
// an Android MIME type).
const NOTE_ID = "dev.kaya/note";
// NO QUOTES IN THE PAYLOAD: the step grammar's escapes are \n, \r and \\
// with no \" (crates/kaya/src/harness.rs), so a quoted byte could not be
// spelled in the expectation.
const NOTE_BYTES = new TextEncoder().encode("note=1");

writeFileSync(join(sceneDir, "pixel.png"), PIXEL_PNG);
writeFileSync(join(sceneDir, "pasted.txt"), "pasted bytes", { encoding: "utf-8" });

function copyRich(): void {
  // One clip, four representations; kaya derives none from any other.
  // Wire order is kaya's.
  kaya.copy({ text: "kaya clip", html: "<b>kaya</b> clip", image: PIXEL_PNG, custom: { [NOTE_ID]: NOTE_BYTES } });
  status.set("copied");
}

function answered(clip: kaya.Clip | null): void {
  // Empty is the universal no; its four causes (denied, unfocused,
  // absent, nothing accepted) are not distinguishable — the platforms
  // decline to say, so the guest does not guess.
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
    // Straight back out: the assertion that matters is a foreign
    // decoder's size, not a byte count.
    kaya.copy({ image: clip.bytes });
    status.set("image");
    return;
  }
  const files = clip.files;
  if (files.length === 0) {
    status.set("files none");
    return;
  }
  // A pasted file is a picked file arriving through a second door, so it
  // is redeemed the same way (guests/js/filedialog.ts): the read happens
  // here and the ANSWER is posted, which is what the python version's
  // thread posts.
  const file = files[0]!;
  const name = file.name;
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
  app.post(() => status.set(`files ${name} ${text}`));
  status.set("reading");
}

// Each read is a promise of the clip; the continuation after the await
// is its own transaction (docs/js-plan.md §4).
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
  // The copy's own row rides in front of the payload, as a handle;
  // printing its key is what proves the paste dispatched as an INSTANCE
  // occurrence.
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
    // Declares nothing, so the platform inserts and the field's ordinary
    // change path reports it.
    plain = kaya.entry().a11yId("plain"); // entry#1

    // A STAMPED paste target: the accept list comes from the TEMPLATE
    // (docs/tpl-props-plan.md P1) and the paste arrives as an INSTANCE
    // occurrence carrying the copy's key.
    kaya.label({ bind: rowStatus }).a11yId("row-status"); // label#1
    const rows = kaya.collection();
    for (const _row of rows) {
      kaya.entry().accepts(kaya.ACCEPT_TEXT).onPaste(rowPasted);
    }
    rows.insert("r1", ""); // entry#2
  });
});

app.run();
