# Dirty-state window chrome — the design pass

The working record for the dirty-state milestone, in the undo-plan's
shape: probes first, decisions stated with what they replaced, nothing
ratified until the maintainer says so. The probe reports (2026-08-06,
five arms) are scratchpad/dirty-probe-{mac,windows,linux,mobile}.md and
scratchpad/dirty-prior-art.md; every measured claim below cites its arm.

## §0 — what the probes found (the facts the design rests on)

- **macOS has the one real API.** `NSWindow.isDocumentEdited` via the
  existing NSWindow bridge (SwiftUI itself offers nothing); the chrome
  is the close-button dot. Observability MEASURED: the AX attribute is
  `AXEdited` and it lives on the CLOSE BUTTON element, not the window
  (the window's 29 AX attributes contain no edited state). [mac arm]
- **Windows has no API at any layer** — no WinUI/App SDK modified
  affordance (checked including the generated bindings, the
  IsUndoEnabled method). The caption is the whole surface. The living
  convention, measured on current Notepad: leading asterisk, no space
  (`*doc - App`). Note Notepad's *visible* chrome is a dot in its
  custom tab strip; the caption asterisk survives for the taskbar and
  accessibility. Observability: `expect_title` already reads the real
  OS caption on this lane. [windows arm]
- **GTK4 has no API at any layer** (GtkWindow's 25 properties: none),
  and the GNOME-2-era title-asterisk rule is DEAD — the current HIG
  says nothing, and the living convention (GNOME Text Editor, read
  from its source) is a bullet LABEL in the client-side header bar
  with the title string untouched. kaya's GTK backend draws its own
  header bar, so it can do exactly that. [linux arm]
- **Mobile has no chrome to lower to.** iOS's dirty bit
  (`UIDocument.hasUnsavedChanges`) is autosave plumbing, not chrome;
  the platform affordances for unsaved state are FLOW affordances
  (pull-down-dismiss confirmation on edited sheets; Android's
  predictive-back unsaved-changes dialog), which in kaya-land belong
  to veto_close/navigation, not to window chrome. [mobile arm]
- **Prior art splits three ways; only Qt answers every platform.** Qt:
  one boolean + a `[*]` placeholder INSIDE the app's title string
  (mac lowers to the dot, elsewhere the placeholder becomes `*`).
  Electron: mac-only `setDocumentEdited`, everything else app-rolled.
  NSDocument: chrome plus a built-in save sheet. [prior-art arm]

## §1 — the decisions (RATIFIED by the maintainer, 2026-08-06, as a set)

### D1 — `dirty` is a window-construct attribute; chrome is the
### backend's business (replaces: apps composing markers into titles)

One boolean beside `title` and `veto_close` in the ratified attribute
set. The app declares state; it never spells chrome. Qt's `[*]`
template is the named rejection: a placeholder inside the app's title
string leaks the mechanism into app-facing text — and kaya's scene
titles are byte-compared across platforms, so the declared string must
stay identical everywhere while the chrome diverges.

### D2 — the lowering table (each row from a measurement)

| backend | lowering | the app's title string |
|---|---|---|
| SwiftUI (mac) | `isDocumentEdited` through the existing NSWindow bridge; the close-button dot | untouched |
| WinUI | leading `*` composed into the RENDERED caption (the measured Notepad convention) | untouched (composition is render-side) |
| GTK4 | a bullet label in the header bar beside the title (the living GNOME convention, read from GNOME Text Editor's source) | untouched |
| SwiftUI (iOS) | none — see D4 | untouched |
| Compose | none — see D4 | untouched |

### D3 — chrome only; the confirm flow stays composed (replaces:
### NSDocument-style built-in save sheet)

`dirty=true` arms nothing. The "unsaved changes, close anyway?" flow
is already expressible from `veto_close` + the dialog machinery, and
apps legitimately differ on what it should do. One attribute, one
meaning: show the platform's unsaved-work affordance.

### D4 — the mobile carve-out, stated (RATIFIED 2026-08-06 — the
### one invariant exception in this design, decided by the maintainer)

On iOS and Compose the prop applies (it round-trips, it is readable
back, D5's verb asserts it) and lowers to NO chrome, because the
platforms have none: their unsaved-state affordances are flow
(dismiss/back confirmation), which kaya already spells through
veto_close and navigation. The carve-out is stated here and in
DESIGN.md's Binding conventions if ratified. The rejected alternative
— synthesizing chrome the platform never shows (a title marker on a
device with no visible title) — fails the "carve-out only where the
platform cannot express it" test in reverse: it would express what no
native app expresses.

### D5 — one harness verb, `expect_dirty <bool>`, read per backend
### (replaces: per-platform expect_title steps, which a shared
### byte-compared script cannot spell)

The scene stays identical everywhere; the verb's READ is per-backend,
each one measured before its arm ships:
- mac: the close button's `AXEdited` via the existing out-of-process
  AX read (measured present exactly there);
- WinUI: the real OS caption via the existing title read (leading
  asterisk present/absent);
- GTK: the header-bar marker via the existing AT-SPI read;
- iOS/Compose: the applied window prop read back through the
  interpreter (state, not chrome — the honest observable where no
  chrome exists; NOT vacuous: it fails if the prop never applied).

### D6 — spec-first, one prop (replaces: nothing; this is invariant 7)

`window` gains a `dirty` bool in crates/kaya/src/spec.rs; the hash
moves; the eight bindings gain the sugar spelling on the window
construct (check-sugar-surface's window-prop sweep holds the fan-out
open by itself); both interpreters gain the apply arm and the verb
(check-verbs holds that open); check-universal-props is not implicated
(dirty is a window prop, not a widget prop).

## §2 — sequencing

Depth: spec + Rust surface + SwiftUI mac arm (bridge call + AX-read
verb) + a `dirty` scene (toggle it, assert with expect_dirty, close
with veto to show D3's composition) green on mac. Breadth: GTK and
WinUI arms with their reads; iOS/Compose applying the prop + the
state-read; the seven bindings' sugar; the matrix. The scene's guests
follow the sugar tier; the C floor spells the prop explicitly.

### Depth progress (2026-08-06)

DEPTH IS GREEN. Spec + Rust surface + the SwiftUI mac arm + the scene,
`dirty-rust-swiftui` passing twice consecutively under the GUI lock in
~680ms. What landed, and the three things it settled:

- **The prop.** `("dirty", 7, PropKind::Bool)` in WINDOW_PROPS; the spec
  hash moved `0x69c07d5216db7eb8` -> `0x5b3d760b52e59d91` and every
  generated surface plus both interpreter mirrors moved with it. Rust's
  spelling is `tx.window(0).dirty(true)`, beside `veto_close`.
- **The mac lowering** is `NSWindow.isDocumentEdited` through the
  existing bridge, applied from the prop arm AND re-applied from
  `register()`. That second call is not defensive tidiness: WATCHED —
  with it deleted, an aux window marked before it materialized comes up
  clean and the leg fails `window#1 dirty false, wanted true`. (The
  PRIMARY survives without it, because the lowering falls back to
  `NSApp.windows.first`; only an aux surface exposes the hazard.)
- **The verb reads the chrome, not the model.** WATCHED, twice: delete
  the apply arm's lowering and all three `expect_dirty true` steps fail
  while every label assertion still passes (the model is right, the
  window is not); make the lowering set-but-never-clear and
  `expect_dirty false` fails after the save. The read is `AXEdited` on
  the CLOSE BUTTON, exactly where the probe measured it, and it reports
  UNREADABLE as its own failure rather than as `false` — a clean-window
  assertion must not pass because the read broke.
- **D5's read table is now a contract comment** on
  `harness::Stage::window_dirty`, so each breadth arm implements
  against one written statement rather than against this document.

Two things the depth arm could not settle, both handed to breadth:

1. **The mobile lanes have nothing to run yet.** `dirty.steps` drives a
   chrome CLOSE (that is D3's demonstration), and no phone has one, so
   the scene as written is desktop-only on the window/panels precedent.
   D4 still wants iOS and Compose to apply the prop and read it back;
   that needs either an explicit carve-out or a mobile-safe sibling
   script. Both mobile interpreters currently declare
   `depthStub("dirty")` and docs/deferred.md holds them open.
2. **`expect_title` and `dirty` must never appear in the same stretch
   of a shared script.** The WinUI arm composes its asterisk into the
   RENDERED caption, which is what `expect_title` reads there, so a
   title assertion while dirty could not hold byte-for-byte on five
   lanes at once. dirty.steps asserts the title once, while clean, and
   says why.

## §3 — what was deliberately not designed

- No title templates, no app-visible markers (D1's rejection).
- No auto-armed dialogs anywhere (D3).
- No synthetic mobile chrome (D4).
- Documents/save infrastructure (NSDocument-class machinery) is the
  text editor's business later, not this prop's.
