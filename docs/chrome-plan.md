# The window chrome pass — design brief (Phase C)

Status: DIRECTION RATIFIED 2026-08-16 (maintainer): the toolbar is the
existing `primary` bit growing desktop lowerings — no new construct, no
styling knob. Depth is NOT started; the DESIGN.md sentence flips when
the slice lands, not before. C1 remains DEFERRED. Claims are marked
[DOC] (platform documentation, cited in the research reports), [MEASURED]
(observed by this repo's probes — the five reports under
scratchpad/chrome/toolbar-{mac,android,gtk,winui,repo}.md, 2026-08-16),
[REPO] (read from this tree), [INFER] (a depth slice must confirm).

## 0. What this pass is for, in one paragraph

The styling pass gave kaya apps a brand, roles, the inset, symbols and
the typeface; the sidebar slice gave sectioned windows the modern shell.
What still separates a kaya window from the native-feeling mac apps the
maintainer pointed at (2026-08-16) is the toolbar: primary actions as
symbol buttons in the chrome. The 2026-08-16 research pass asked whether
that look needs any styling vocabulary and the answer is NO on every
platform: the modern geometry is the DEFAULT RESULT of having the bar
(mac, GTK, WinUI) or the bar is the platform's one chrome and already
kaya's (iOS, Android). The pass therefore admits ZERO new constructs:
it makes the promotion bit kaya already ships mean what it says on the
three desktops that currently ignore it.

## C1 — the chrome knob: `chrome: standard | extended`

**DEFERRED before ratification (maintainer, 2026-08-16)** — ledgered in
docs/deferred.md with the breakage analysis. Kept as the design record;
nothing here is being built.

The research pass made C1 smaller than the draft thought, on evidence:

- macOS: the tall unified bar needs no flag — attaching a toolbar gives
  it by default (see C2's mac row) **[MEASURED]**. C1's mac residue is
  only the title-hidden/Zed shape (C1b), still deferred.
- Android: `extended` would be a no-op whose `standard` is unreachable —
  targetSdk 35 forces edge-to-edge **[DOC]**. Medium/LargeTopAppBar are
  title-prominence composables, dead without an app-wired
  scrollBehavior; they are refused, not deferred **[MEASURED: 1.3.1
  token bytecode]**.
- GTK: no height variant exists — the bar is 46px in every
  configuration **[MEASURED: libadwaita 1.7.6, lane image]**.
- WinUI: the tall Files-app bar is `ExtendsContentIntoTitleBar` +
  `AppWindowTitleBar.PreferredHeightOption = Tall`, and the second
  THROWS without the first **[DOC]** — a window flag, C1 exactly, and
  the one platform where "extended" is real chrome surgery. Deferred
  with the rest of C1.

The ledger's derivation rule stands (docs/deferred.md): **"extended is
DERIVED (toolbar or sidebar present)"** — a window that carries a
toolbar or a sidebar gets whatever tall/flat/merged treatment its
platform's construct produces, and no prop ever says so.

## C2 — the toolbar: the `primary` bit grows its desktop lowerings

**The finding that reshaped this section [REPO]:** kaya already ships
the promotion list. `primary` (MENU_PROPS id 6) carries C2's entire
semantics today — promotion in catalog preorder, platform-owned
capacity k, remainder to overflow, recompute on every catalog mutation,
advisory status (DESIGN.md, Menus). It is honored by both phone arms
(iOS promoted bar actions; Android TopAppBar actions) and stored-inert
on macOS, GTK and WinUI behind one DESIGN.md sentence: "no toolbar
materialization is planned … not the seed of a toolbar grammar"
(DESIGN.md:1878-1880), whose own admission trigger reads "admitted only
if an artifact demands semantics that adaptive menu promotion cannot
express" (DESIGN.md:1938-1940).

**The ratified answer to that trigger: desktop presence.** Nothing
else. The slice deletes that sentence and grows three lowerings for the
bit the desktops already store. No spec movement, no generator run, no
binding gains a spelling, no new vocabulary — and the tree's one
existing 3-of-5 no-op prop becomes honored 5-of-5.

**Deliberately NOT taken: app-declared order.** Promotion order stays
catalog preorder, k stays the platform's number. If an artifact ever
demands a toolbar order divergent from its catalog order, that is a new
trigger answered then (the `add_section`-shaped record
`toolbar_append { window, item }` is the known shape, toolbar-repo.md
§6 Option 2); it is not paid for now.

Per-platform materialization, all rows evidence-backed:

| platform | lowering | what the research measured |
|---|---|---|
| macOS | NSToolbar from the primary items, NO style set | **[MEASURED]** chrome 28pt → 52pt tall unified bar with `.toolbarStyle` left `.automatic` (probe read back `.automatic`; explicit `.unified` measured identical at 52pt; negative control `.expanded` = 56pt proves the modifier reaches the window). Title stays, moves centre → leading. Overflow free (14 items @ 420pt = 3 visible + system chevron). SF Symbols render from the catalog's symbol names. Sidebar windows are at 52pt already; the toolbar completes the genre look. |
| iOS | the shipped promoted-bar arm, unchanged | **[REPO]** `kayaPromotedActions` → `ToolbarItemGroup(.primaryAction)`; k=2, More menu synthesized. See the PRECONDITION below — its symbol rendering is the gap. |
| Android | the shipped TopAppBar actions arm, unchanged | **[REPO]** k=2 + synthesized ⋮; M3 1.3.1 has no native overflow (AppBarRow is 1.4-alpha) **[MEASURED]**. Enablement rides IconButton state. |
| GTK | AdwHeaderBar buttons (pack order = catalog preorder) inside AdwToolbarView | **[MEASURED: 1.7.6]** flat is AdwToolbarView's DEFAULT (`top-bar-style` = ADW_TOOLBAR_FLAT); enablement is free via `win.kmi-N` actions; the scroll-only undershoot shadow is free. OWED by the arm: overflow (GTK has none — 24 buttons drove min-width to 1155px and the window refused to shrink; the remainder goes into a synthesized GtkMenuButton) and the accessible name (an icon-only button publishes name='' on AT-SPI). |
| WinUI | CommandBar of the primaries, mounted in the `RightHeader` of a `Microsoft.UI.Xaml.Controls.TitleBar` that IS the window's caption (`ExtendsContentIntoTitleBar`); MenuBar keeps its own row below; remainder stays in that MenuBar | **[MEASURED: pinned winmd + the VM]** dynamic overflow automatic (width breakpoints, the "…" button, overflow rows re-laid icon+label); 20→16px icon rescaling; labels hidden while closed; IsEnabled follows the one button object. **Revision ratified 2026-08-17:** the bar no longer hangs in a strip under the caption — the Win11 shell (Files/Terminal/Settings) merges it INTO the caption row, which is a MOUNT-POINT change and no new knob. Caption height 32→48px is DERIVED by the control from its slot being occupied (`TitleBar::UpdateHeight`), never set by kaya. Drag proved by dragging (dx=120 dy=60, size unchanged) and the in-caption commands proved clickable by a synthesized click the scene then asserted; caption buttons still close the window (UIA rect 46x32 — the standard band, upstream #9863, not chased). `AppWindowTitleBar.PreferredHeightOption = Tall` deliberately NOT taken. |

### The two preconditions, named

1. **The iOS symbol gap [MEASURED].** The promoted bar buttons on iOS
   render NO symbol while `expect_menu_symbol` passes off the MODEL —
   a stamped-observation violation already in the tree, and the icons
   pass is hollow on precisely the platform whose promoted bar ships.
   Fix first (or with the depth), and move the read to the real tree.
   Probe: scratchpad/chrome/symprobe.py reports every `.symbol`
   read/write in KayaSwiftUI.swift with its `#if` nesting — a rendering
   read must exist outside `#if os(macOS)`.
2. **The GTK look flip (RATIFIED 2026-08-16, visual shown).** Adopting
   AdwToolbarView moves every kaya window on Linux from the raised
   chrome (opaque band, permanent hairline — what
   GtkHeaderBar-in-titlebar renders) to the platform-default flat
   header (bar and content one surface; hairline+shadow only while
   content is scrolled beneath). Same 46px, same drag, same buttons
   **[MEASURED: side-by-side in the lane image,
   scratchpad/chrome/gtk-sidebyside.png]**. Migration note from probe
   9: AdwApplicationWindow IS a GtkApplicationWindow and a GActionMap,
   so the `win.*` action route survives; a plain GtkApplicationWindow
   can also host an AdwToolbarView **[MEASURED]**.

### Observations

- `expect_toolbar` takes the BARE invariant form
  (`expect_menu_presentation`'s shape): capacity k is the platform's
  number ("never computed by kaya", both mobile arms' words), and the
  scene is byte-frozen across lanes, so the step asserts the invariant
  — promoted items present in chrome, remainder reachable via overflow
  — never a literal count.
- The enablement round-trip: disable the menu item via its signal,
  observe the BUTTON disabled — the one assertion that proves
  one-source-of-truth, on every platform.
- Every read is the REAL tree: NSToolbar's items on mac, the AT-SPI
  names on GTK (which is also what forces the a11y-name fix), the
  CommandBar tree on WinUI, and — precondition 1 — the iOS read moves
  OFF the model, where the symbol gap hid.

### The macOS 26 material, for the record

The glass material is gated by the MAIN EXECUTABLE's linked SDK, not by
anything a process can request **[MEASURED: a 14.4-linked bundle
renders the compatibility generation on this macOS 26 host]**. No
toolbar knob could buy it; no toolbar knob is therefore missing it.
The maintainer approved the flake SDK bump 2026-08-16 (screenshots in
artifacts will reflect the modern look; acknowledged) — that is its own
slice under the ledger's standing constraint (a compat-generation leg
must survive the bump; vendor-stamped hosts keep the hosted-language
legs in the compatibility generation regardless).

### Refused, stated once

Free-form widgets in toolbars (search fields, pickers — not the 5-way
intersection); per-item placement beyond catalog order; toolbar-only
actions (everything promotable lives in the catalog first — the
accessibility argument: every action stays reachable by menu and
keyboard); Medium/LargeTopAppBar on Android (title-prominence
constructs, not toolbars); the WinUI tall title bar (a C1 window flag,
deferred with C1); any `chrome`/`extended`/toolbar-style prop (a no-op
on at least one platform in every variant surveyed — the promotion bit
is the only construct that is a no-op nowhere).

## Dependencies and sequencing

1. The iOS symbol gap (precondition 1) — a defect fix on shipped
   machinery, schedulable immediately.
2. Depth on mac: NSToolbar from `primary` + the tall bar + the
   enablement round-trip + `expect_toolbar`, on the real tree.
3. Breadth: GTK (the AdwToolbarView flip + synthesized overflow + a11y
   names) and WinUI (CommandBar) in parallel; the phone arms need no
   change beyond precondition 1.
4. DESIGN.md's sentence flips in the landing commit (the Menus section
   rewrites `primary`'s meaning: "promote this action into whatever
   chrome this window has").
5. The editor and the sections demo adopt it (the editor's Save/Find
   are the canonical primaries).

## Ratification record

- 2026-08-16, direction: the `primary` lowering shape, no new
  vocabulary, preorder order, platform k — RATIFIED.
- 2026-08-16, the GTK flat flip — RATIFIED after the side-by-side.
- 2026-08-16, the macOS SDK bump — APPROVED (separate slice, standing
  constraint applies).
- Still open at depth time: none named; the trigger sentence's flip
  lands with the slice.
