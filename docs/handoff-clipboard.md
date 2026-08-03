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

### 0. DONE SINCE THIS MAP WAS WRITTEN

- The occurrence floor no longer caps a record (it aborted the process
  above 208 bytes of payload; docs/traps.md).
- ALL EIGHT BINDINGS and their guests: copy, read, `accepts`,
  `on_paste`, the sum. validate-mac ALL PASS, 232 legs.
- The scene is in SCENES on all three runners; the mac legs are
  SERIALISED, one drain each (see the warning below).
- The accept vocabulary is named in every binding (`ACCEPT_TEXT` and
  friends, spelled the way that binding spells `ROLE_*`).
- Two gates added, both watched failing: check-steps now demands a leg
  per language that has a guest, and demands the java/csharp selector
  dispatch each scene.
- The GDK probe exists and runs: tools/linux/gdkclipprobe.
- 2026-08-02/03, the GTK slice: §5b finding 3 RESOLVED — the headless
  seat delivers no input serial, and the serial charge is PER COPY,
  not per leg (wlroots rejects a set_selection older than the current
  selection's serial, every wl-copy seed advances that watermark, and
  one dropped copy leaves a GDK client permanently deaf — §5b has the
  whole chain). The lane's recipe: a freshening F24 tap before every
  click/menu_activate/shortcut in armed scenes (gtk.rs,
  freshen_wayland_serial) — and deliberately NO session keyboard
  holder, which was tried and broke three unrelated pooled legs'
  expect_focused (exclusive keyboard focus; §5b has the finding).
  Resolving it surfaced finding 4 — GDK
  never serves a slashless custom id — and the id grammar was
  RATIFIED mime-shaped: the scene id is `dev.kaya/note`, validated at
  the apply chokepoint with five negative tests watched failing. The
  respell flushed out a macOS charge the snippet probe missed:
  NSPasteboardItem validates types as UTIs and DROPS a slashed one,
  so the mac arm now writes item 0 at pasteboard level (§5b finding 4
  has both mechanisms). The first full lane run also caught finding
  5: the guests' shared 4x4 PNG had a broken IDAT CRC that every
  earlier decoder tolerated — regenerated in all eight guests, and
  the GTK image verdict now names a decode failure instead of
  answering "". THE GTK ARM IS WRITTEN: copy (union provider), read
  (formats-driven, answered exactly once), accepts on the hub, the
  paste split, the three roles with intersection enablement, the
  AT-SPI field-name fallback to the Text interface (the macOS AXValue
  chain, spelled AT-SPI), and the two harness verbs over
  wl-copy/wl-paste and xclip. The linux legs are wired SERIALISED
  (one drain each, both protocols, pinned by a new check-steps
  barrier clause with self-tests) through a11y-leg.sh; the image
  gained wl-clipboard, xclip, wtype and wayland-utils; probe-env
  warns when a cached image predates that layer.

### 1. The seven other bindings — DONE

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
  is wl-copy/wl-paste. `check-gtk.sh` needs docker and is the only gate
  that compiles gtk.rs.
  START AT docs/clipboard-plan.md §5b: the probe settled the copy arm's
  structure (a union provider advertises all four representations), the
  read arm's grammar (an unsatisfiable read fails fast, no timeout),
  and — 2026-08-02, findings 3 and 4 — the blocker: the headless seat
  has no input devices, so no client could ever hold the serial
  Wayland charges for taking the selection. The lane's fix is one
  `wtype -P F24 -s 800 -p F24` primer per clipboard leg after its
  window is up. Resolving it surfaced a GDK grammar rule: a custom id
  needs a slash or it is advertised and never served, which forces an
  id-grammar decision at the root (finding 4; maintainer's call).
- **WinUI — ARM WRITTEN 2026-08-03, measured first (docs/
  clipboard-plan.md §6).** Classic Win32, not WinRT (SetContent
  demands foreground; the custom-format write bridge is undocumented;
  no persistence without Flush). The probe (tools/win/clipprobe)
  proved all five representations both directions through stock
  PowerShell 5.1, including the slashed custom atom VERBATIM and
  persistence past process exit. The traps that would have burned:
  every ssh connection is its OWN clipboard (window station per
  logon — everything clipboard runs in session 1, the harness verbs
  as guest children); `Get-Clipboard -TextFormatType Html` corrupts
  non-ASCII (ANSI decode — use PresentationCore); `SetData` with a
  string rides WPF's serialized-object path (MemoryStream for exact
  bytes); Microsoft's own CF_HTML example is arithmetically wrong
  (construct with 10-digit fixed-width offsets, parse with
  digits-then-stop); PNG-only clips are invisible to DIB consumers
  (deliberate cut, §6). The legs run serialised in deploy-win's
  serial tail, pinned by check-steps' barrier clause in deploy-win's
  own vocabulary.
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

## WHEN YOU WRITE A BACKEND'S LEGS, SERIALISE THEM

There is one system clipboard per session, so clipboard legs cannot run
concurrently with each other on ANY lane — they would be eight
processes writing one variable. validate-mac gives each leg its own
`drain`; the linux and windows runners need the same when their legs
land (docs/clipboard-plan.md §0d, the 2026-08-02 correction, has the
measurement: six of eight failed concurrently, 8/8 serially).

check-stubs keeps you honest in the meantime: `clipboard` is already in
every runner's SCENES, and the legs may only be wired once that
runner's backend stops depth-stubbing the feature.

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
