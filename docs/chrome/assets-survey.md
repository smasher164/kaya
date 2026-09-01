# The assets survey (2026-08-18) — working notes

Marks: [REPO] read from this tree, [MEASURED] run by this pass, [INFER].
The brief distilled from this file is docs/assets-plan.md.

## 1. Inline image bytes in guests — MEASURED byte-identical

Extraction script: parsed every guest's literal in its own spelling (hex,
decimal, signed decimal for Java, `\ddd` escapes for OCaml, `BS.pack`
lists for Haskell, `byteArrayOf(...toByte())` for Kotlin), stripped
comments, hashed the reconstructed bytes.

| image | bytes | sha256[:12] | sites | where |
|---|---|---|---|---|
| 2x2 RGB PNG | 75 | `e6d668891312` | **18** | a11y + gallery, 9 languages each |
| 2x64 PNG | 75 | `546bc373c85c` | **8** | align, 8 languages (no C guest) |
| 4x4 RGB PNG | 77 | `97720159d21d` | **13** | clipboard, 8 languages + 5 in tools/ |
| corrupt PNG (bad IDAT CRC) | 88 | `759ad58259a5` | 1 | tools/win/clipprobe/clipprobe.ps1, a decoder-strictness negative |

**Every copy of each image is byte-identical today [MEASURED].** Three
distinct valid images, one deliberate corrupt one, 39 valid-image literal
sites + 1.

The 5 non-guest copies of the 4x4: tools/win/clipprobe/src/main.rs,
tools/linux/gdkclipprobe/probe.rs, tools/ios/clipprobe/main2.swift,
tools/android/clipprobe/.../SeedReceiver.kt (gone), and
tools/android/cliphelper/run3.sh (base64 — the only base64 of it).

**No base64 anywhere in guests [MEASURED].** **No pixel synthesis in
guests [MEASURED]** — every image is a pre-encoded PNG spelled byte by
byte, and the comments say so ("embedded as source: scenes carry their
inputs, no runtime file I/O"). Runtime synthesis exists only in two
probes: tools/ios/clipprobe/run2.sh (python struct+zlib) and
tools/mac/clipprobe/main.swift (NSImage → tiff → PNG).

## 2. What the scenes actually assert about those bytes [REPO]

- `tools/scenes/gallery.steps:12-13` — `expect image#0 "2x2"`,
  `expect image#1 "0x0"`. DECODED DIMENSIONS.
- `tools/scenes/clipboard.steps:36` — `expect_clipboard image "4x4"`.
  docs/clipboard-plan.md:688 titles the reason: "The image is a decoded
  size, never bytes" — macOS synthesizes six other formats from one PNG,
  so a byte count differs per lane.
- `tools/scenes/a11y.steps:33` — `expect_ax image#0 "image/Logo"`. The
  a11y name, not the pixels.
- `tools/scenes/align.steps` — baseline geometry off the tall image.

So a byte typo that breaks the decode turns that language's leg red on
five lanes. **A typo that changes only the pixel colors is invisible
everywhere** — no assertion in the tree reads a color. That is the exact
extent of the existing guard, and it is dimension-level, not byte-level.

## 3. Inline text blobs in guests

- `ranges` document: 813 bytes / 40 lines, all 9 languages, opening with
  CJK so UTF-8 offsets differ from UTF-16. The scene's assertions are
  OFFSETS INTO it, so any drift shifts an offset and reddens the lane —
  a stronger end-to-end guard than the images have.
  `guests/csharp/RangesScene.cs` also validates the length at runtime.
- `editor` seed document, Go only, `guests/go/editor/editor.go` — written
  to disk as the scene's seed file.
- `NOTE_BYTES = "note=1"` (6 B) and `"not an image"` (12 B), 8-9 sites each.

## 4. The three things the repo ALREADY treats as assets [REPO]

1. **The vendored font.** `guests/assets/fonts/sora-wght.ttf` (111400 B)
   with `OFL.txt` and `README.md` beside it. Read by 8 guests via
   `KAYA_FONT_FILE` with the repo-relative default
   `guests/assets/fonts/sora-wght.ttf`, then handed to the wire's blob
   channel. Also compiled into the core's harness build by the single
   `include_bytes!` in the tree (crates/kaya/src/winui/mod.rs) — the core
   reaching across into `guests/`.
2. **The scene corpus.** `tools/scenes/*.steps`, 38 files, 188 KB,
   resolved by `crates/kaya/src/harness.rs:94` from `KAYA_SCENES_DIR`
   with a compile-time-relative default. **TWO transports**, because the
   phones have no shared filesystem with the runner: the path, and
   `KAYA_SELFTEST_SCRIPT` carrying the CONTENT itself over an iOS bundle
   arg or an Android intent extra (harness.rs:62-72).
3. **`tools/guest/minimal-resources.pri (gone)`** (1040 B) — an opaque Windows
   MRT package resource index, committed as a blob, not regenerable from
   anything in-tree, no provenance file, mode `-rw----r-x`. Shipped by
   tools/deploy-win.sh and hashed into the deploy stamp.

Only #1 has ever been called an asset. #2 and #3 have every property of one.

## 5. Staging: how a data file reaches each lane today [REPO]

| lane | mechanism | verified? |
|---|---|---|
| Android | `adb push` + `chmod 644` + **size check** (`adb shell stat -c %s` vs `wc -c`), then `am start --es KAYA_FONT_FILE` (tools/android/run-emulator.py:712-729, the hash-verified successor) | yes, size |
| Windows | `scp` every run, deliberately OUTSIDE the deploy stamp, into a repo-mirror path (tools/deploy-win.py:466-486) | no |
| Linux | nothing — repo bind-mounted at `/work` | n/a |
| macOS | nothing — runs from the repo root | n/a |
| **iOS** | **no file-push route for assets exists.** The only host→guest binary channel is a base64-over-container-file bridge in tools/ios/run-sim.sh, which is the clipboard/dialog protocol, not an asset installer | — |

[MEASURED] `grep -c typeface`: validate-mac 5, linux/run-suites 19,
deploy-win 15, android/run-emulator (gone) 21, **ios/run-sim 0**. The iOS scene
lists (tools/lib/lanes/ios.py:26, :40) do not contain `typeface`. The
one asset the tree ships never reaches iOS.

## 6. The four per-platform icon tables — NOT assets

swift/KayaSwiftUI.swift (SF Symbols), crates/kaya/src/gtk.rs:78 (Adwaita
names), crates/kaya/src/winui/mod.rs (Fluent: 17 enum members + 3 raw
code points), android/.../KayaCompose.kt (gone) (Material). 20 entries each,
hand-written from untracked research files under `styling/`.

DESIGN.md:2360 already ruled this: "Icons want names, not bytes … The
Blob stays for genuinely app-specific art."

Measured gap, out of scope for this brief but worth a ledger line: no
gate pins the four tables to one another. Only two Rust `const _: () =
assert!` length/order pins exist (gtk.rs, winui/mod.rs). **[MEASURED]
`tools/check-symbols.sh` does not exist** — the SwiftUI table's own
comment names it as the intended gate.

## 7. The wire's existing blob channel [REPO]

`crates/kaya/src/capi.rs:1003-1012` — bulk payloads live once in
core-owned memory; `kaya_blob_register` copies bytes in and returns a
handle valid for exactly one submit; records carry 8-byte handles. Two
directions, two small id spaces. The C floor's guests call
`kaya_blob_register` directly (guests/c/a11y.c).

So the wire already carries BYTES from wherever the guest got them. An
asset NAME on the wire would be a different mechanism: the core (or a
backend) resolving a name to bytes.

Precedents for the core touching the filesystem, against the "keep the
core out of the filesystem" objection: harness.rs:94 already resolves a
data root from an env var with a compile-time-relative default;
`kaya_open_picked` hands out real descriptors; and all three desktop
backends WRITE a registered font blob to a temp file because the
platform font API needs a path.

## 8. The prior refusal of variants [REPO]

docs/styling-plan.md:270 and docs/deferred.md:2928 — "an asset pipeline
offers fonts nothing the blob channel lacks — **density variants and OS
packaging are raster-art concerns**; a font is one vector file". The
identity brief answers that sentence for the icon in
docs/app-identity-plan.md:615-622 (one PNG in, conversion in the
lowering) and re-refuses per-platform icon ART "for now"
(docs/app-identity-plan.md:661-664: reopen when packaging lands).

## 9. Verdicts

| site | verdict |
|---|---|
| the three test PNGs, 39 sites | **KEEP INLINE.** They are inputs to assertions about decoding; a staged file adds a failure mode to the scene that tests decoding. 75-77 bytes each. The uncaught drift (pixel content) is worth ONE census gate, not a staging dependency on four scenes across five lanes. |
| the `ranges` document, 9 sites | **KEEP INLINE.** The scene's assertions are offsets into it, so drift already reddens a lane. |
| the 5 tools/ copies of the 4x4 | **KEEP INLINE, join the census.** Separately-compiled programs on four toolchains; staging costs more than the census. |
| the corrupt 88-byte PNG | **KEEP INLINE, deliberately.** A file invites someone to "fix" it. |
| `"not an image"`, `NOTE_BYTES` | keep; trivial. |
| the vendored font | correct as an asset; the one gap is that nothing holds its provenance or the core's `include_bytes!` path. |
| `tools/guest/minimal-resources.pri (gone)` | **SHOULD BECOME AN ASSET.** The survey's one genuine mis-filing outside the identity icon. |
| the scene corpus | already an asset; not to be moved. Its two-transport shape is the design input for reaching phones. |
| the four icon tables | not assets; refuse. |
