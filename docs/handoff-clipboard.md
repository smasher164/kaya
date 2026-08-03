# Clipboard handoff — the fan-out

The depth slice is green on mac. This is the map for the breadth work,
written while the context that produced it is still warm.

Read first: DESIGN.md's Clipboard section (the shape and the reasons),
then docs/clipboard-plan.md §0 (the argument, and for each decision the
answer it REPLACED), §0e and §1b (what the probes measured), §1-§3
(what each landed slice decided).

## What is done

- The protocol, both channels. tx `copy`/`read_clipboard`, apply twins,
  occurrences `clipboard_result` and `pasted`, the occurrence blob
  table, `Representation` (the sum) and `Clip`/`ClipOut` (the records).
- The Rust surface: `tx.copy()…send()`, `tx.read_clipboard()…send()`,
  `tx.accepts` / `WidgetRef::accepts(&[Accepts::…])`,
  `Messages::on_clipboard`, `Messages::on_paste`, `MenuRole::{Cut,
  Copy, Paste}`.
- SwiftUI on macOS: the copy and read arms, the role commands, the
  paste split, enablement refresh.
- The harness: `clipboard_seed` and `expect_clipboard`, in harness.rs
  and both interpreters (Compose refuses with `depthStub`).
- tools/scenes/clipboard.steps + guests/rust/clipboard.rs, run as
  `clipboard-rust-swiftui` (DEPTH_SCENES in validate-mac.sh).
- Probes: tools/mac/clipprobe, tools/linux/clipprobe, tools/ios/clipprobe.

## What remains, in the order to do it

### 1. The seven other bindings

Every one needs the same five things. Sweep with an explicit
do/can't/defer verdict per language (CLAUDE.md invariant 2):

- the copy chain (a record builder ending in a send)
- the read chain (an accept list ending in a send, returning the id)
- `accepts` on a widget, taking the kinds as VALUES, joined to the
  space-separated string the wire carries
- `on_paste`, keyed by widget, delivering the sum
- the `Representation` sum, spelled the language's way (an enum with
  payloads where the language has one; a tagged record where it does
  not)

The occurrence decoder is the fiddly part: `pasted` is a click tag,
then u32 clip + u32 reserved, then a Values block. A BLOB VALUE IN AN
OCCURRENCE IS A TABLE HANDLE, not a batch index — redeem it with
`kaya_occurrence_blob` and RELEASE it with
`kaya_occurrence_blob_release` while decoding, so the app never sees a
handle. Nothing else on the occurrence channel has ever carried bytes,
so every binding's decoder meets this for the first time.

Then guests/<lang>/clipboard.* for each, and the scene moves from
DEPTH_SCENES into SCENES on every runner.

### 2. The backends

Each needs: the copy arm, the read arm answering exactly once, the
`accepts` prop, the paste split, and the three roles.

- **GTK/wayland.** The compositor is sway (Weston has NO clipboard at
  all — §0e finding 1). The foreign reader/writer for the harness verbs
  is wl-copy/wl-paste, already in the container. `check-gtk.sh` needs
  docker and is the only gate that compiles gtk.rs.
- **WinUI.** `CF_HTML` needs its offset header — bytes tagged
  `text/html` paste as garbage. Files are a `DROPFILES` struct with
  double-NUL-terminated wide strings.
- **Compose.** Images cannot be bytes: `ClipData` carries a
  `content://` URI, so the backend stands up a provider. Reads return
  nothing without focus, which is why the foreign side has to be a real
  app — see below.
- **iOS.** `UIPasteboard`, and the read PROMPTS for another app's
  content (§0e finding 2). The leg has to drive the prompt, the way
  the picker leg drives the panel (tools/ios/simdrive). Seeding is
  `simctl pbcopy`, which counts as another app.

### 3. The Android helper APK

Decided to be part of this work, not a later phase (§0e, "THE ANDROID
HELPER IS PART OF THIS WORK"): an unfocused Android app gets nothing
back from `ClipboardManager`, and no shell command can write the
clipboard, so the outside process must be a real app. Without it the
Android legs would verify kaya against kaya — a check that cannot fail
for the reason the design exists.

## Traps, all of which failed silently first

- **Enablement is not a build-time fact.** It is the intersection of
  what the clipboard offers and what the FOCUSED widget accepts. Menus
  that set `autoenablesItems = false` recompute nothing, and a disabled
  item is inert without complaint. Refresh at menu-open and before a
  harness activation.
- **A responder-chain send starts at the KEY window.** A leg running
  eight wide is rarely frontmost. Start at the focused window's own
  first responder; do not make the app key, which steals focus from
  every sibling leg.
- **A seed that does not verify makes everything after it race.**
  `osascript` writes the clipboard through AppleEvents and its exit
  does not mean the pasteboard settled — one run in three failed on
  whatever the guest asserted next. Every platform's seed must wait
  until the content is really there.
- **`writeObjects(NSImage)` declares TIFF alone** and would silently
  re-encode a guest's PNG. Raw bytes under the type round-trip
  byte-identical, and the system synthesizes every other image type on
  demand.
- **The image assertion is a decoded size, never bytes.** Hosts
  re-encode freely; a byte count is a different number on every lane
  for one picture.
- **A custom format cannot be seeded from outside** on any platform —
  no stock tool writes an app-defined type, and a helper kaya wrote
  would be foreign in name only. Copy it and read it back, with the
  foreign reader confirming the bytes are there under that id.
