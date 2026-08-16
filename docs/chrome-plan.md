# The window chrome pass — design brief (Phase C, NOT YET RATIFIED)

Status: DRAFT for the maintainer's ratification. No spec change, no
code, no scene rides on this document yet. Claims are marked the way
the styling research reports mark them: **[DOC]** = platform
documentation, **[MEASURED]** = observed in this repo's own probes or
captures, **[INFER]** = inference a depth slice must confirm before
anything is built on it.

## 0. What this pass is for, in one paragraph

The styling pass gave kaya apps a brand, roles, and the inset; the
sidebar-coverage slice gave sectioned windows the modern shell. What
still separates a kaya window from the native-feeling mac apps the
maintainer pointed at (2026-08-16) is the WINDOW CHROME: those apps
run their content (or a material) under a transparent title bar, and
their primary actions sit as symbol buttons in a tall unified toolbar.
kaya windows today are standard titled windows — the thin opaque band
— and kaya has NO toolbar vocabulary at all, so the tall-bar geometry
is not merely unstyled, it is unreachable **[MEASURED: every mac
capture in the styling artifact]**. This pass admits exactly two
constructs: a window chrome KNOB (C1) and a toolbar as a PROMOTION of
the window's existing command catalog (C2). Everything else stays
refused.

## C1 — the chrome knob: `chrome: standard | extended`

**DEFERRED before ratification (maintainer, 2026-08-16)** — ledgered
in docs/deferred.md with the breakage analysis (top-band overlap, drag
regions, the silent geometry flip). Kept here as the design record;
nothing below is being built. C2 remains a live draft awaiting its own
ratification.

One window prop, enum, default `standard` (today's look, unchanged for
every existing app). `extended` asks the platform to run the window's
content region under the title area — the "modern editor" shape: the
buffer to the top edge, traffic lights floating over it.

ADVISORY per the width/height/inset precedent: honored where the
platform has the idiom, resolved to the nearest thing otherwise,
ignored where physics decides.

Per-platform lowering:

| platform | `extended` resolves to | confidence |
|---|---|---|
| macOS | `titlebarAppearsTransparent = true` + `styleMask.insert(.fullSizeContentView)`; the title TEXT stays (identity lives in the title bar — the editor-plan rule) unless C1b below is also ratified | **[DOC]**, the standard AppKit pair; **[INFER]** that SwiftUI's window scene exposes it cleanly on the interpreter's window — the depth probe's first question |
| iOS / Android | no-op — phones have no title bar; the system's own chrome is not kaya's to extend | **[DOC]** by construction |
| GTK | the flat header treatment: `AdwToolbarView` with `top-bar-style = flat` over the content, headerbar background matching the window (libadwaita 1.4+, already the floor) | **[DOC]** for the API; **[INFER]** for visual parity with the mac arm — the container probe decides |
| WinUI | `AppWindow.TitleBar.ExtendsContentIntoTitleBar = true` + `SetTitleBar(dragRegion)` | **[DOC]**, the documented pair; the drag region is the part the depth slice must get right (a window nobody can drag is the failure mode) |

C1b (OPTIONAL, separate ratification): `title_hidden` — the title text
suppressed while the window keeps its identity in the app switcher.
Zed-shaped editors want it; it is a SECOND knob because hiding the
document's name contradicts the editor plan's "the title bar says
which document this is" unless the app carries the name elsewhere.
Default: not offered until an app asks.

Observation: `expect_chrome "standard" | "extended"` reading THE ARM
THAT RENDERED — the render body stamps it (the
expect_split/sections_presentation discipline, third use of the same
shape). The mac stamp is the styleMask read back off the REAL
NSWindow, not the model **[INFER: confirm the styleMask read is not
another controlAccentColor-style poisoned read before trusting it]**.

Refused, stated now so nobody re-litigates piecemeal: chrome colors,
traffic-light/caption-button positions, title fonts, per-window
translucency knobs. The material comes WITH the platform's own
surfaces (sidebar, toolbar) or not at all.

## C2 — the toolbar: a PROMOTION LIST over the command catalog

**The design's one idea: kaya already has the action vocabulary.** The
menu/command catalog carries every action with its label, icon slot,
enabled signal and handler. A toolbar is NOT a second action system —
it is the window saying WHICH of its catalog items are promoted to
chrome. The iOS interpreter already does exactly this internally (the
trailing More menu + promoted bar actions) **[MEASURED: the
KayaMenuChrome arm]**; C2 makes the promotion an app-declared,
uniform surface instead of a per-platform improvisation.

Grammar sketch (names for ratification, not final):

    tx.window(0).toolbar(&[save_item, find_item])   // ids of DECLARED menu items

- Promotion list is per-window, ordered, append-only in v1 (the
  sections precedent — no destruction grammar until something needs
  it).
- An item promoted but absent from the catalog is a declare-time root
  wall ("promote what exists").
- Enablement, label, icon, handler: THE ITEM'S OWN, one source of
  truth. Disabling the menu item disables its toolbar button — for
  free, on every platform, or the lowering is wrong.

Per-platform materialization:

| platform | lowering | the tall-bar side effect |
|---|---|---|
| macOS | NSToolbar items in `.unified` style | YES — this is where the genre apps' tall title bar comes from **[DOC]**; landing C2 changes mac window geometry for toolbar-carrying windows |
| iOS | the existing promoted-bar-actions arm, now driven by the app's list instead of the interpreter's heuristic | already shipped, becomes deterministic |
| Android | M3 TopAppBar actions + overflow | **[DOC]**; the phones' one real chrome bar |
| GTK | headerbar buttons (start/end packing) | **[DOC]**; merges visually with C1's flat header |
| WinUI | CommandBar primary commands | **[DOC]**; secondary commands = the overflow, matching the catalog's remainder |

Observations: `expect_toolbar N` (count from the REAL bar),
`expect_toolbar_item i "label"` (the platform's own accessibility name
for the button), and the enablement round-trip (disable the menu item
via its signal, observe the BUTTON disabled — the one assertion that
proves one-source-of-truth). Every platform's read is the real
tree, never the promotion list echoed back.

Refused in v1: free-form widgets in toolbars (search fields, pickers —
mac and GTK allow them, iOS effectively does not; not the 4/4
intersection), per-item placement control beyond order, toolbar-only
actions (everything promotable lives in the catalog first, which is
also what keeps every action reachable by menu/keyboard — the
accessibility argument, not just a purity one).

## Dependencies and sequencing

1. **D6's icons come FIRST** (Phase B, already designed): a toolbar of
   text-only buttons is not the platform's real thing on any desktop,
   and SECTION_PROPS/menu items already carry the icon slot the
   toolbar button will render.
2. C1 depth on mac (probe styleMask/fullSizeContent under the
   interpreter's SwiftUI window scene — the winui-research pattern:
   measure before the arm), then C1 breadth.
3. C2 depth on mac (NSToolbar + the tall bar + the enablement
   round-trip), then breadth; the iOS arm is a rewiring of shipped
   machinery, not new chrome.
4. The editor adopts C1 `extended` (its brief's full-bleed logic
   extends naturally to the title region — maintainer's call at
   ratification time); the library/sections demo adopts C2.

## What ratification is being asked for

- C1 as a window prop (`chrome`, enum, advisory), C1b deferred.
- C2 as a promotion list over the catalog (no second action system).
- The refusals in both sections, so future asks land against a
  written line rather than an absence.
- The sequencing: B (icons) → C1 → C2.
