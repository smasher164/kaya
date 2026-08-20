# Multi-column adaptive layout — the design pass


Status: **RATIFIED 2026-08-19 (maintainer), all five questions ruled.**
Q1: PANES is the milestone; container re-flow stays its own ledger
entry. Q2: the third pane is ADMITTED (Windows composes, stated as the
weak leg). Q3: OPTION A — kaya's compact/collapse behavior is UNIFORM,
macOS included; the maintainer finds the platform's native crush
undesirable ("compacting/collapsing panes is better"). The carve-out
therefore runs the other way from the draft's proposal: platforms with
native adaptive judgment (iPadOS size classes, Android's window size
classes) decide capacity K natively, and macOS — which has no compact
mode to defer to — takes KAYA-SUPPLIED thresholds. The threshold must
be PRINCIPLED, not another invented 600: collapse when the window
cannot fit the visible columns' MINIMUM WIDTHS (research pass on the
mechanics in flight; its findings amend this section). Q4: the
material3-adaptive bump is taken as a deliberate, watched change to the
tablet leg. Q5: `panes` REPLACES list_detail's Bool at window-prop
slot 6 — one spec-hash move, full regeneration, both scenes and four
backends rewritten, DESIGN.md's ratified section reopened with this
ruling as its authority.

MECHANICS AMENDMENTS (measured 2026-08-19, scratch probes on macOS
26.5.2; the raw logs and probe sources are recoverable from the session
transcripts — the findings below are the durable record):
1. MINIMUMS ARE KAYA'S MODEL'S ALONE, DECLARED TO NOBODY. Declaring
   navigationSplitViewColumnWidth(min:) sets the WINDOW's minimum to
   the columns' sum — the window then refuses every smaller size, the
   collapse rule can never fire (flips=0 measured), and resize_window
   (setContentSize) becomes a SILENT NO-OP with every later assertion
   made against a window that never shrank. SwiftUI receives ideal
   widths only; the collapse arithmetic (window width vs the sum of
   kaya's own minimums for the visible columns) runs in kaya's model.
2. THE NAVIGATIONSTACK SWAP IS DELETED. Measured cost of a container
   swap: total view-identity loss on every crossing (every @State,
   focus, in-flight edits), a toolbar rebuild, and the window title
   changing source. The one-container ladder replaces it: the entry
   stack lives INSIDE the detail column (which also yields a real
   back item that survives collapse), .doubleColumn sheds the sidebar
   — shallowest first, kaya's own order, a smooth ~250ms ramp — and
   the 1-pane rung comes from zeroing the CONTENT column's width,
   never from .detailOnly, which the three-column form refuses in two
   silent shapes (a no-op leaving the binding lying, or SwiftUI
   writing .all back).
3. THE PANE READER COUNTS BY WIDTH AND HIDDENNESS BOTH: the zero-width
   column stays isHidden == false, so "non-hidden" alone would count a
   pane no eye can see — zero width IS invisible, the stronger rule.
   Two [INFER] checks the depth slice owes: the zero-width column's
   content renders conditionally (an empty view at zero) so focus
   order and AX gain no phantom stop, and the sidebar-toggle button
   writes into the same visibility binding, so kaya's rule is
   EDGE-triggered on width crossings, never level-triggered — a
   level rule undoes the user's toggle, and a refused state must
   never be commanded (it re-issues forever, measured).

DEPTH-SLICE RESOLUTIONS (2026-08-20, the macOS slice landing these
amendments; swift/KayaSwiftUI.swift KayaSplitRoot3 and
tools/check-pane-ladder.sh are the code):
- THE ONE-PANE RUNG IS UNREACHABLE ON MACOS, BY ARITHMETIC, AND THE
  BARE INVARIANT IS WHAT FORCES THAT. D4's bare form promises a regular
  window never stacks — so kaya's minimums are chosen with
  content+detail (270+320=590) UNDER 600, the compact threshold: at
  every regular width two panes fit, and one pane only ever happens
  below 600, where the window leaves the split arm for the stack arm —
  the SAME crossing panes=2 already ships, kaya's uniform collapse.
  The ladder inside the split arm therefore has exactly two rungs
  (.all above sidebar+content+detail = 790, .doubleColumn below), the
  zero-width-content mechanism stays UNBUILT (amendment 2 records how
  to build it if a platform ever needs it; shipping it dormant would be
  an unexercised branch), and amendment 3's first [INFER] dissolves
  with it — there is no zero-width column to render conditionally.
  check-pane-ladder pins the ordering (content+detail < 600) so a
  constants edit cannot silently reopen the gap.
- EDGE-TRIGGERING IS CONFIRMED AND GATED: kayaPaneLadderCommand
  returns a command only on a rung CROSSING (first measurement counts
  as an edge from nothing), and check-pane-ladder's no-command-on-the-
  level clauses are the sidebar toggle's protection, watched red.
- D4's OTHER [INFER] — dropping the `entries >= 1` conjunct from the
  bare form — is resolved the other way: the conjunct is KEPT, and not
  provisionally. Under the positions vocabulary an empty-stack regular
  window reads "regular/0" (one position, two empty slots) BY DESIGN,
  so the bare form stays the ARM-STAMP invariant expect_split carries
  (regular + stacked + entries >= 1 fails), and a one-position reading
  beside empty slots is not a violation.
- D5's sketch ends "regular/0,1,2" after popping the stack to zero; the
  shipped scene ends "regular/0" — with only the root on the stack, the
  wide window shows the root pane and two EMPTY slots (D1). The sketch
  line was a draft slip, not a design change.
- THE MIDDLE RUNG'S LIVE OBSERVATION lives in tools/check-pane-ladder.sh
  (the real NSSplitView walked 1400 -> 700 -> 1400 in a real NSWindow),
  because no shared scene may sample any width inside the panes band —
  the platforms legitimately disagree across all of 400..1400 for three
  panes, so panes.steps samples the extremes only, per D5.

~~Status: DRAFT, 2026-08-19. NOTHING RATIFIED.~~ (superseded the same
day by the RATIFIED block above — this was the draft's own status line,
left standing when the ruling landed.) Five research briefs feed
this (`mac-ios.md`, `windows.md`, `gtk.md`, `android.md`,
`prior-art.md`, all in this directory) plus the read-only scout
(`ground.md`). The maintainer ranked this milestone first, ahead of
tables.

Claims carry their source, the chrome-plan convention:
**[DOC]** platform documentation, cited in the briefs;
**[MEASURED]** observed by a probe this pass ran (the mac/iOS probes in
`probe/`, environment macOS 26.5.2 / Xcode 26.6.0 / iOS 26.5 runtime);
**[REPO]** read from this tree at `99470c5`;
**[INFER]** a depth slice or a probe must confirm before it is believed.
Every [INFER] in here is a place the plan is guessing on purpose, and
each one names what would settle it.

---

## §0 — what the research settled (the facts the design rests on)

### 0a. The ledger sentence names one thing and its evidence names another

`docs/deferred.md:840-852` punts "a regular window wanting several
columns where a compact one wants one" **[REPO]**. Read literally that
is a CONTAINER's own children re-flowing by width, the feed layout: one
column of cards on a phone, four on a desktop. Read against the same
paragraph's own evidence list — `NavigationSplitView`,
`ListDetailPaneScaffold`, `AdwNavigationSplitView`, `TwoPaneView` — it
is a THIRD PANE beside the existing two.

They share no machinery. The pane question is about a window's entry
stack and its adaptive container; the grid question is about one
widget's layout and a minimum item width. The research pass went after
the panes, so this plan is about panes, and the grid is deferred in §3
with its own trigger. **Q1 asks the maintainer to rule which one the
milestone is**, because the answer changes everything below it.

### 0b. Three panes is not the 4/4 that two panes was

The ledger predicted this ("it wants its own admission pass ... the 4/4
test list-detail passed is not automatic for a column grammar"
**[REPO]**). The honest tier table, in DESIGN.md's own vocabulary
(Lowering tiers, DESIGN.md:46-65):

| platform | third pane | tier |
|---|---|---|
| macOS / iOS | `NavigationSplitView(sidebar:content:detail:)`, a real three-column form **[DOC]**, and on iPadOS genuinely UIKit's `tripleColumn` **[MEASURED, M4]** | 1, wrap |
| Android | `ListDetailPaneScaffold`'s `extraPane`, a real third role **[DOC]** | 1, wrap — but see 0e, unreachable at the pinned version |
| Linux | NOTHING three-paned exists. libadwaita ships two strictly two-child containers and one sentence: "Both split views can be used for creating triple pane layouts, via nesting two of the views within one another" **[DOC]** | 1 by the platform's OWN documented composition |
| Windows | NOTHING three-paned exists, and no Microsoft doc composes two `TwoPaneView`s. Their sentence is "you'll often use it inside a `NavigationView`" **[DOC]**, which is a NAVIGATION rail whose pane degrades (label to icon to hamburger) rather than disappearing — different semantics from a content pane | 1 by a composition the RESEARCH recommends, not one Microsoft blesses |

So: 2/4 native, 1/4 by the platform's own recipe, 1/4 by kaya's own
reading of the platform. No drawn imitation anywhere, which is the part
that matters — but this is a weaker admission than list-detail's, and
Windows is the leg that is weak. **Q2.**

### 0c. Four independent designs converged on CAPACITY, and the one that did not was discontinued

`prior-art.md` §4. Compose names it `maxHorizontalPartitions`; Flutter
computed the same thing as `recommendedPanes`/`maxPanes` and then never
read it; Kirigami derives it as `viewport / columnWidth`. MAUI baked the
count into the type (`Pane1`, `Pane2`) and is stuck at two forever.
Flutter's `AdaptiveLayout` — the one toolkit that let the app write the
collapse rule as a `Map<Breakpoint, Widget>` per slot — was discontinued
2025-02-10 with no replacement named **[DOC]**.

That is evidence FOR kaya's ratified rule, not against it: "Each
platform decides where one pane becomes two, and kaya does not draw
that line" (DESIGN.md:1696) **[REPO]**.

### 0d. Roles and priorities are the same thing, and kaya already owns the order

The sharpest finding in the survey. Compose DEFINES its role names as
aliases of a priority: `ListDetailPaneScaffoldRole.Detail` **is**
`ThreePaneScaffoldRole.Primary` **[DOC]**. The names are for the reader;
the machinery is a total order. MAUI spells the same thing as one bit
(`PanePriority`). Kirigami spells it as stack order.

kaya has that order already, with no vocabulary spent: **entry stack
depth**. `list_detail` today is "base root leading, top of stack
trailing", which is positions 0 and 1 of exactly this order.

And "keep the DEEPEST" is what every platform does when it runs out of
room: Apple's visibility ladder sheds leading columns (`.all` ->
`.doubleColumn` -> `.detailOnly`) **[DOC]**; Apple's collapsed stack
holds the column prefix and puts you at the deepest resolved one
**[MEASURED, M4]**; Compose's `forEachPaneByPriority` promotes the
newest destination **[DOC]**; kaya's own WinUI arm already sets
`PanePriority = Pane2` once the stack has an entry **[REPO]**; and
GNOME's nesting gives whichever order you nest for **[DOC]**.

The one exception is macOS squeezed below its content's minimums, where
the DETAIL is crushed to zero and the two leading columns hold 148 and
348 **[MEASURED, M3]**. That is not a collapse, it is macOS running out
of room with all three columns still present, and kaya does not ride it.

### 0e. Four traps that are already live, or arrive the moment a third pane does

1. **WinUI has a third arrangement kaya cannot name, it is reachable
   today, and nothing catches it.** `TwoPaneView.Mode` is
   `Wide|Tall|SinglePane`; `MinTallModeHeight` defaults to 641 and
   `crates/kaya/src/winui/mod.rs:2049-2069` never sets it **[REPO+DOC]**.
   `split.steps`'s narrow leg is `360x600`, so the Windows lane is green
   on a 41-DIP coincidence. At `360x700`: 360 <= 641 and 700 > 641, so
   `Tall` — the list renders ABOVE the detail with both visible, the back
   bar computes `Collapsed`, `back` becomes a no-op, and
   `split_presentation` reports `compact/split`. `Pane1Length`, computed
   from WIDTH by `protocol::leading_pane_width`, is applied as a HEIGHT
   **[DOC]**. `check-steps`'s band lint polices widths only; there is no
   height clause, and the bare `expect_split` cannot see it either
   (`compact/split` satisfies the asymmetric invariant).
2. **On macOS the window title comes from the SECOND column, so a third
   column silently steals it** **[MEASURED, M1]**. At two columns the
   detail titles the window; at three the CONTENT column does and the
   detail's `navigationTitle` never reaches `NSWindow` at all. The
   comment standing at `swift/KayaSwiftUI.swift:11734` — "THE WINDOW'S
   TITLE HANGS OFF THE DETAIL COLUMN" **[REPO]** — is true of the form
   kaya ships and false of the one this milestone adds. The failure
   degrades to the process name, which is the bug that once reported
   "python3.14".
3. **On macOS a declared column visibility can be a complete no-op with
   no write-back** **[MEASURED, M2]**. `.detailOnly` on three columns
   leaves all three columns on screen, byte-identical to `.all`
   (148/348/1051), and the binding still reads `.detailOnly` afterwards.
   No error, no callback, no correction. macOS's reachable set for three
   columns is `{all, doubleColumn}`; iPadOS's is all four. Any
   observation derived from kaya's own declaration reports a lie on
   macOS, forever green, on every lane.
4. **On Android the visible pane SET is a function of (partitions,
   destination history), never of position** **[DOC]**. With two
   partitions and a user who has navigated to Extra, Material shows
   Extra + Detail and HIDES the List. kaya synthesizes a one-item
   history today (`List` or `Detail`) **[REPO]**, which is exactly right
   for two roles and silently wrong for three: a history that can never
   name Extra falls through to Primary/Secondary/Tertiary and expands
   List + Detail while the user is standing on Extra.

And the version cliff underneath (4): three partitions are UNREACHABLE
at the pinned `1.0.0` **[DOC]**. It needs `1.2.x` plus
`currentWindowAdaptiveInfoV2()` for the Large width class to exist at
all. That bump also changes the EXISTING tablet leg — the
`medium_tablet` AVD at 1280dp is past `WIDTH_DP_LARGE_LOWER_BOUND`
(1200), so it goes from two partitions to three the day the pin moves,
with nobody editing a scene **[DOC+REPO]**. **Q4.**

### 0f. The intermediate rung is the feature, and it is where nobody agrees

At one pane and at all-D-panes the four platforms agree in shape. At
"two of three" they disagree about the threshold AND about which two:

- macOS: `{all, doubleColumn}` only, and `doubleColumn` hides the
  SIDEBAR **[MEASURED, M2]**.
- iPadOS: four states, the full `.tile` ladder
  `secondaryOnly / oneBesideSecondary / twoBesideSecondary` **[DOC]**.
- GTK: whichever the NESTING SHAPE chose. Nav-in-nav's *sidebar* keeps
  sidebar+middle and pushes the detail away; nav-in-overlay's *content*
  keeps middle+detail and overlays the sidebar **[DOC]**. Same three
  panes wide, same one pane narrow, opposite middles.
- Compose: whichever two the destination history promotes **[DOC]**.
- WinUI: emergent arithmetic. The rail measures the window, the inner
  view measures the leftover, and nothing in the markup states an order
  **[DOC]**.

**Consequence for the scenes: no shared scene may ever name the middle
rung.** It may name the extremes, and it may assert invariants that hold
at every rung.

---

## §1 — the decisions

### D1 — a pane is a SURFACE from this window's stack, and its priority is its depth

Two numbers, and the whole design is keeping them apart.

- **D, the declared depth.** How many pane positions this window's
  hierarchy has. The APP says it, once, and never re-decides. 1 = serial
  navigation (today's default), 2 = today's list-detail, 3 = sidebar /
  content / detail.
- **K, the capacity.** How many of those D fit right now. THE PLATFORM
  says it, on every layout pass. kaya never computes K, never names a
  width, and never reads one back to decide anything.

The pane contents, generalising the ratified rule at DESIGN.md:1668
("Deeper entries replace the trailing pane") one position outward:

> Pane 0 is the window's base root. Pane *j* holds entry *j-1*. The LAST
> pane always holds the TOP of the stack. Anything between the prefix
> and the top is retained and covered, exactly as navigation already
> does.

D=2 with a stack of 3 gives root + top, middle covered — today's
behavior, unchanged. D=3 with a stack of 2 gives root + e0 + e1. D=3
with a stack of 4 gives root + e0 + top, with e1 and e2 covered.

This is the shape Apple measured out of its own collapsed stack: the
stack holds the whole column PREFIX up to the last resolved column, back
pops one column at a time, depth 0 = sidebar, 1 = content, 2 = detail
**[MEASURED, M4]**. On a phone kaya's entry stack already IS that
object, so collapse costs no new machinery at three panes for the same
reason it cost none at two.

**When K < D, the visible panes are the last K of the D** (0d). kaya
tells each platform's container the ORDER and nothing else; every one of
the four can express it (a `PanePriority` chain, the nesting shape, the
destination history, `columnVisibility`).

**A pane slot with no content still exists.** DESIGN.md:1673 already
ruled it at two ("An empty stack on a regular window shows the leading
pane and the platform's own empty trailing state"), and the alternative
is worse: building only the slots that have content means swapping a
two-column `NavigationSplitView` for a three-column one on every push,
which loses state, animation and focus. This kills the tidiest invariant
the survey offered — Kirigami's "visible panes never exceed stack depth"
(`prior-art.md` §6) does not hold for kaya, and it must not be imported
unexamined. What survives is §D4's asymmetric pair.

**Rejected, and why:**

- **Roles (`sidebar` / `content` / `detail` as named slots).** Compose
  proves roles and priorities are one thing (0d), kaya already has the
  order, and named slots would need a second lifecycle grammar to fill
  them. Flutter is the toolkit that shipped named slots; it is also the
  one that was discontinued.
- **A `split` widget KIND holding children.** Already rejected once on
  the never-mix-the-three-lifecycle-grammars rule (DESIGN.md:1644-1650),
  and nothing in the research reopens it. A container that collapses must
  either push its detail (a widget performing navigation) or grow its own
  back affordance (push/pop/intercept_back one layer down).
- **Columns as declared SURFACES** (`add_column(window, surface)`, the
  sections shape). It duplicates the stack it would sit beside, and
  Apple's own chaining ("the selection in the first column affects the
  second" **[DOC]**) is what a stack already is.

### D2 — the wire surface: `panes`, an integer, replacing `list_detail`

`WINDOW_PROPS` today runs 1..8 with `list_detail` at 6 **[REPO]**. The
proposal is to REPLACE slot 6 rather than add slot 9:

```
("panes", 6, <integral>)   // 1 = serial (default), 2 = list-detail, 3 = three panes
                           // domain-checked at the root, the `columns` precedent
```

Arguments:

- **A Bool that means "2" cannot grow to mean "3".** Adding a second
  prop makes `list_detail = false, three_panes = true` a state the wire
  admits and nothing means. One integer has no unrepresentable-state
  problem and no cross-prop check to forget.
- **Churn is free.** No users; a rename costs one spec-hash move and one
  regeneration, and invariant 7 makes that mechanical.
- **The binding cost is generation, not code.** A window prop reaches
  all eight guest languages through the generated window-prop surface,
  and `tools/check-sugar-surface.sh`'s window-prop clause already
  requires a sugar spelling in all eight **[REPO]**. This is the
  strongest practical argument against every container-shaped
  alternative: a new KIND would need constructors in eight languages in
  BOTH construction zones, and a new SURFACE kind would need its own
  lifecycle in eight.
- **An integer is a CAP, and a cap is safe.** `panes: 2` on a
  1600-DIP display is a real thing to say and must be honored. It can
  only reduce, never force a pane onto a window too small for it, so it
  can never make a scene assert something a platform disagrees with.
  This is Flutter's `recommendedPanes` vs `maxPanes` distinction, which
  is the one piece of that API worth taking (`prior-art.md` §7).

**Not spelled, deliberately:** any threshold, in any unit. MAUI shows the
failure (`641d / Density` means four different physical widths from one
declaration **[DOC]**); Kirigami shows the subtler one (`20 * gridUnit`
moves with the user's font); Flutter shows the worst (a `BuildContext`
predicate that mixes size, platform and orientation). kaya's existing
ruling covers all three and extends unchanged.

**Not spelled either: any guest-observable width or size class.**
`ground.md` §2f is the load-bearing negative — there is no width event,
no size-class query, and the only capability bit is `aux_windows`
**[REPO]**. Adaptivity stays entirely a lowering decision: the guest
declares D and the platform re-decides K forever after. Opening a query
here would be a genuinely new protocol surface, an eight-binding
invariant-1 sweep, and an invitation for guests to re-decide what the
platform just decided. Deferred with a trigger (§3).

**Q5** asks whether the replacement is taken or a second prop joins,
because it rewrites a ratified DESIGN.md section and both scenes.

### D3 — the lowering table: one construct, one trap, each row evidenced

| platform | construct | how D is spelled | how the ORDER is spelled | the ONE trap |
|---|---|---|---|---|
| macOS | `NavigationSplitView`, three-column form | the INITIALIZER ARITY — `(sidebar:detail:)` vs `(sidebar:content:detail:)` are different generic types, so the interpreter needs a second view type, not a parameter **[DOC]** | `columnVisibility`, advisory | **A declared visibility can be a silent no-op.** `.detailOnly` on three columns is byte-identical to `.all` and the binding still reads `.detailOnly` afterwards **[MEASURED, M2]**. Plus the title moving to the second column **[MEASURED, M1]**. Both are invisible to any observation derived from the declaration. |
| iOS / iPadOS | the same file, and really `tripleColumn` underneath **[MEASURED, M4]** | same | `preferredCompactColumn` names the TOP of the collapsed stack — a DEPTH, not a jump target **[MEASURED]** | **A Plus/Max iPhone in landscape is horizontally REGULAR** **[DOC]**, so no scene may ever assert "a phone shows one pane". `listdetail.steps` is already careful; the successor must be too. |
| Android | `ListDetailPaneScaffold` with `extraPane` non-null | `extraPane` presence | `ThreePaneScaffoldDestinationItem` history, which kaya must now DERIVE FROM THE ENTRY STACK rather than synthesize one item **[DOC+REPO]** | **The pane set follows history, not position** (0e.4), and three partitions do not exist at the pinned 1.0.0 (0e). Also: pin `AdaptStrategy.Hide` explicitly. `SupportingPaneScaffoldDefaults` defaults to `Reflow`, which keeps both roots on screen stacked — a state kaya's model has no word for **[DOC]**. |
| Linux | two nested `AdwNavigationSplitView`s, the inner one in the OUTER'S CONTENT slot | the nesting | THE NESTING SHAPE IS THE PRIORITY. libadwaita has no priority property anywhere **[DOC]** | **Breakpoints are not cumulative.** "If multiple breakpoints can be used for the current size, the last one is always picked", and an unapplied setter RESETS its target **[DOC]**. A naive `860sp -> outer.collapsed`, `500sp -> inner.collapsed` list shows TWO panes at phone width, silently, in a state that is legal at some other width. Also `sp` scales with text: `860sp` is 1075px at large text **[DOC]**. |
| Windows | two nested `TwoPaneView`s, the inner one in the star-sized `Pane2` | the nesting | a CHAIN of `PanePriority` bits, which composes into a three-pane order **[DOC]** | **`Tall` mode** (0e.1), live today. Then: `release_split` must walk the nest depth-first, because a `UIElement` in two `Children` collections takes a non-unwinding panic through XAML and ABORTS the process **[REPO]**; and the collapse order is emergent arithmetic across two independently-configured thresholds, so kaya must not try to compute compensating numbers. |

Three rows deserve their consequence stated rather than left in the
table:

- **GTK's shape is a semantics choice, not a GTK choice.** Nav-in-nav's
  *sidebar* keeps the two leading panes together; nav-in-*overlay*'s
  content keeps the two trailing ones and turns the base root into a
  drawer. D1's order (keep the deepest) picks neither of the guide's two
  worked examples: it wants the inner view in the OUTER'S CONTENT SLOT,
  so that collapsing the outer puts the base root and the inner split
  into an `AdwNavigationView` and BACK reaches the root — which is what
  iPadOS's collapsed prefix-stack does **[MEASURED, M4]**. The guide
  sanctions that slot in words ("The inner view can be placed as the
  sidebar or content widget in the outer view") but only works the other
  two shapes **[DOC]**. **[INFER] — a GTK probe owes: does a nested
  `AdwNavigationSplitView` inside an `AdwNavigationPage` behave when the
  outer collapses, and does the kaya-owned back button still target the
  right navigation view when there are two of them?**
- **The GTK breakpoint list wants a structural guard**, per invariant 3:
  build it from one ordered table of rungs, widest first, where each
  rung's setter set is GENERATED as the union of itself and every wider
  rung. Then a non-cumulative list is not expressible rather than merely
  discouraged.
- **The composite GTK stamp must be recomputed from all four booleans on
  one idle after allocation** (`outer.collapsed`, `inner.collapsed`, and
  the two show-content values). They settle on separate `notify`
  callbacks; a stamp written from one of them names a state that is
  legal at some other width — the same defect as the breakpoint bug,
  arriving at the observation layer **[DOC]**.

### D4 — the observable: `expect_panes`, and it names POSITIONS, not a count

`expect_split` is a bool over a two-pane world. Its successor reports
`<size class>/<visible positions>`, positions being D1's indices:

```
regular/0,1,2      three panes, all showing
regular/1,2        the middle rung: sidebar shed, content+detail showing
compact/2          collapsed, standing on the detail
compact/0          collapsed, standing on the root
```

**Why positions and not a count.** A count cannot distinguish
"List+Detail" from "Detail+Extra", and on Android those are genuinely
different outcomes at the same width from the same declaration
(0e.4) **[DOC]**. The defect this feature exists to prevent is a lowering
that shows the WRONG panes, and a count cannot see it. Positions also
make the platforms' disagreement about the middle rung VISIBLE
(`regular/1,2` on macOS against `regular/0,1` for a GTK shape-A nesting)
rather than hiding it inside an equal number.

**Every backend reads its wrapper's own arrangement, never the
declaration** — the existing rule at `harness.rs:1012-1019` **[REPO]**,
and M2 is its vindication by measurement: on macOS a declaration-derived
answer is a lie no lane could ever catch. Per platform:

- macOS: count the real `NSSplitView`'s non-hidden arranged subviews and
  map by index. Ten lines; the probe already does it **[MEASURED]**.
- iOS: `UISplitViewController.isCollapsed`, `displayMode`, and the
  `.compact` column's stack depth **[MEASURED]**.
- Android: `ThreePaneScaffoldValue[role]`, per role, both outcomes
  **[REPO — the two-pane arm already does exactly this]**.
- GTK: the four booleans, folded, on one idle after allocation.
- WinUI: `Mode()` folded over the nest, each level the control's own
  answer.

**The two forms, policed the way `check-steps` already polices
`expect_split`:**

- **BARE — the invariant a shared scene can carry at any width.** The
  existing asymmetric claim, generalised: *a regular window declaring D
  >= 2 must not be showing exactly one pane.* Still one-directional, for
  the reason it always was — how many of D fit is the platform's call,
  and a compact window is never asked to show two.
  **[INFER] — today's clause also requires `entries >= 1`
  (`split_presentation_fits`, `harness.rs:1924-1932`). With empty pane
  slots real (D1) that conjunct looks droppable and the invariant gets
  stronger. The depth slice must confirm all four backends report a
  regular window with an empty stack as two panes before it is dropped;
  until then keep it.**
- **LITERAL — legal only outside a band, and THE BAND MUST BE
  MEASURED.** The current band is `400..840` **[REPO]**. The three-pane
  floor is higher and each platform's number is different: Android
  1200dp **[DOC]**, GNOME 860sp which is 1075px at large text
  **[DOC]**, Apple publishes none and three columns were measured live
  at 1032pt on an iPad Pro in portrait **[MEASURED, M4]**, and WinUI's
  nest needs the outer above 641 AND the leftover above 641, so roughly
  1300 plus the leading pane **[INFER]**. **The depth slice owes a
  measured floor on the Windows VM and on the GTK lane before any
  literal three-pane assertion is written.** Guessing it is how a lane
  goes red at the width nobody sampled.

Two lane consequences fall straight out:

- **The GTK lane must pin its text scaling factor**, or a `860sp`
  breakpoint is a different pixel width per run and no byte-frozen
  literal is reproducible **[DOC]**. A gate clause, not a habit.
- **The Android tablet AVD is probably too small.** `medium_tablet` is
  1280dp, only 80dp above Material's 1200 **[REPO+DOC]**, and inside
  whatever floor the other three force. A larger AVD or a
  desktop-windowing profile is likely, and
  `run-emulator.sh`'s `assert_outside_band` needs the new band.

### D5 — the scenes: the same two-scene shape, and the collapse observable is the POP

The existing pair is the template and its reasoning transfers whole:
`split.steps` resizes and names literals on three desktop lanes;
`listdetail.steps` never resizes, never names a presentation, carries
only the bare invariant, and runs on all five with a regular-width
DEVICE on the two lanes that cannot resize **[REPO]**.

**`panes.steps`** (desktop-only), sampling only the extremes:

```
expect_entries 0
expect_panes                       # bare; also the scene-ready wait
resize_window <WIDE>x800           # WIDE from the measured floor, not guessed
expect_panes "regular/0"           # D=3 declared, empty stack: slots 1 and 2
                                   #   carry the platform's empty state
click button#0                     # push the content entry
expect_entries 1
expect_panes "regular/0,1"
click button#1                     # push the detail FROM the content pane
expect_entries 2
expect_panes "regular/0,1,2"
expect_ax label#0   "label/root pane"
expect_ax label#1   "label/content pane"
expect_ax label#last "label/detail pane"
back                               # fully expanded: back reveals nothing
expect_entries 2                   #   so it does not pop (DESIGN.md:1706)
expect_panes "regular/0,1,2"
resize_window 360x600
expect_panes "compact/2"
back
expect_entries 1
expect_panes "compact/1"           # THE COLLAPSE OBSERVABLE
back
expect_entries 0
expect_panes "compact/0"
resize_window <WIDE>x800
expect_panes "regular/0,1,2"
```

**THE COLLAPSE OBSERVABLE, named.** The three `back` steps in the narrow
leg are the assertion this milestone exists to make. A collapsed
three-pane window pops ONE COLUMN AT A TIME, and the position reported
after each pop equals the stack depth. That claim:

- is threshold-free once the window is narrow, so it needs no band;
- is the same on all four platforms, because Apple's collapsed stack was
  MEASURED to be exactly the column prefix with one-at-a-time back
  **[MEASURED, M4]**, and the other three collapse into kaya's own
  stack, which has always behaved this way;
- fails for exactly the defect the feature risks — a wrapper that owns
  its own navigation history, which is why
  `androidx...adaptive-navigation` is not a dependency and why the
  Community Toolkit `ListDetailsView` (which owns `BackButtonBehavior`)
  is refused **[DOC]**;
- cannot be faked by an arm that stamped itself, because `expect_entries`
  reads kaya's core and `expect_panes` reads the wrapper, and the two
  have to agree three times running.

The three `expect_ax` reads at full width are the other half: a stamp and
a model read both pass for an arm that ran and drew nothing, so exactly
one assertion per pane must come from the platform's real tree. This is
the same lesson `split.steps` records in its own comment **[REPO]**.

**`panes-invariant.steps`** (all five lanes), the phone-safe sibling: no
resize, no literal, bare `expect_panes` before and after the two pushes,
plus one `expect_ax` on the deepest pane. Same guest binary; a scene
selects a script, never an app.

**No `expect_title` in the sibling**, same as today, so one guest per
language serves both. And `panes.steps` MUST assert the title at three
columns, because M1 is a silent degradation to the process name and the
title assertion is the only thing that sees it.

### D6 — three preconditions, named

The chrome-plan shape: things that must be true before the milestone
starts, each independently valuable.

1. **The WinUI `Tall` fix, now, before any three-pane work.** One line
   in the `wants_split` arm — `view.SetMinTallModeHeight(f64::INFINITY)?`
   — makes `Mode()` a pure function of width, which is the two-valued
   semantics kaya already declares and every other backend already
   implements **[DOC]**. Do NOT use `0`; the doc says that prevents
   `SinglePane`, the opposite. Then the guard, per invariant 3: a static
   clause that fails any `TwoPaneView` constructed without it (put it
   where someone walks into it, not in a list to remember), and the
   watched negative — delete the line, run the narrow leg at `360x700`,
   watch `expect_split "compact/stacked"` go red. It has never been seen
   failing, which is the whole reason to watch it.
2. **The macOS caption moves to the content column at D=3** **[MEASURED,
   M1]**, and the comment at `KayaSwiftUI.swift:11734` is corrected to
   say which form it describes. Watched negative: build a three-column
   window with the caption on the detail and confirm the title comes out
   as the process name.
3. **The macOS carve-out gets stated, or gets removed.** kaya
   manufactures a collapse macOS does not have: a kaya-invented 600pt
   line in `KayaFormFactorRecorder` and a CONTAINER SWAP to
   `NavigationStack` below it **[REPO+MEASURED, M3]**. At two panes that
   was invisible, because the scene asserts only the asymmetric
   invariant. At three it becomes observable in two ways — the reachable
   state set differs (macOS `{all, doubleColumn}` against iPadOS's four),
   and kaya would be inventing the SHED ORDER on a platform that sheds
   the opposite way on its own. Per the standing rule, an invariant
   exception is the maintainer's to declare, not the lowering's to
   assume. **Q3.**

---

## §2 — sequencing (depth then breadth, per doctrine)

0. **Preconditions** (D6.1 and D6.2). Both are defect fixes on shipped
   machinery, schedulable immediately and independent of every ruling
   below.
1. **The rulings.** Q1 and Q2 gate everything; Q3, Q4, Q5 gate the depth
   slice's shape.
2. **The probes the plan is short of**, before code: the GTK
   nav-in-nav-content shape (D3), the WinUI nest's real three-pane floor
   and the GTK lane's at pinned text scale (D4). Each is a small
   standalone program, and each answers a question the plan currently
   marks [INFER].
3. **Depth: spec + Rust binding + SwiftUI on macOS + `panes.steps`.**
   The spec moves first (invariant 7), the observable's grammar and the
   band lint move with it, and macOS is the platform whose traps are
   already measured. `check-verbs` and `check-sugar-surface` go red here
   and stay red, by design, holding the rest of the work open.
4. **Breadth, in parallel:** Compose (with the pin bump and the derived
   destination history), GTK (the nesting, the generated cumulative
   breakpoint table, the four-boolean stamp), WinUI (the nest,
   depth-first `release_split`, the priority chain). The remaining seven
   bindings come from generation.
5. **Lanes:** the tablet AVD decision, the GTK text-scale pin, the new
   band in `check-steps` with its four-direction self-test, and
   `assert_outside_band`'s new number.
6. **DESIGN.md's "Adaptive list-detail" section rewrites in the landing
   commit** — the title, the vocabulary, the "No three-pane form in v1"
   sentence at :1671, and the ledger entry at :840-852 struck WITH its
   resolution and swept for its key nouns (invariant 9).

---

## §3 — deferred, with named triggers

- **The adaptive CONTENT grid** (0a's other reading): `columns` derived
  from a declared minimum item width rather than fixed by the app, the
  feed canonical layout. Every platform has it (`GridCells.Adaptive(minSize)`,
  `GridItem(.adaptive(minimum:))`, and GTK/WinUI equivalents **[INFER —
  unresearched this pass]**), it needs no size class and no threshold,
  and its count-derived-from-one-content-number is Kirigami's rule.
  TRIGGER: Q1 ruling for it, or the tables milestone needing it.
- **A guest-observable size class or width** (query or event). TRIGGER:
  an artifact that must change its DATA, not its layout, by width.
  Until then adaptivity stays a lowering decision, which is the rule that
  keeps eight bindings from each re-deciding it.
- **The inspector / trailing utility pane.** "Three panes" is ambiguous
  on Apple platforms and the two shapes shed in OPPOSITE directions:
  a navigation third column becomes the deepest position in the collapsed
  stack, while an inspector becomes a SHEET **[DOC]**. GNOME says the
  same from the other side — `AdwOverlaySplitView` is the utility pane
  and the HIG assigns the two widgets by ROLE, not by taste **[DOC]**.
  WinUI has no adaptive equivalent. TRIGGER: an artifact wanting a
  properties panel.
- **`supporting_pane` as a second declared pattern.** Compose has it
  natively; its DEFAULT collapse is `Reflow`, which keeps both roots on
  screen stacked vertically **[DOC]** — a state kaya's model cannot spell.
  TRIGGER: an artifact. Until then Android's strategy is pinned to
  `Hide` explicitly (D3), because taking the default silently is the
  failure mode.
- **Per-pane width intent.** All four platforms have it and all four
  call it advisory ("SwiftUI may use a different width for your column"
  **[DOC]**). Note that `protocol::leading_pane_width` has exactly ONE
  production caller today, WinUI at `mod.rs:2055` **[REPO]**, and a nest
  would need a second number. TRIGGER: a scene where a platform default
  is unusable.
- **Reflow and levitate** as declared collapse outcomes: 1/4, Compose
  only **[DOC]**.
- **A draggable splitter:** already ledgered at 2/4, and easily confused
  with this milestone. Unchanged.
- **Four or more panes.** Nothing in the roster has a fourth: Compose
  stops at three roles, Apple at three columns, and the nested shapes
  would need three levels. The cap belongs in the root's domain check so
  the refusal is a guest-visible error rather than a layout surprise.

---

## §4 — open questions for the maintainer, numbered for ruling

**Q1. Which surface is this milestone?** The ledger's sentence ("a
regular window wanting several columns where a compact one wants one")
reads like a CONTAINER's children re-flowing by width — the feed layout,
a grid whose column count is derived rather than declared. The same
paragraph's evidence list is entirely about PANES: `NavigationSplitView`,
`ListDetailPaneScaffold`, `AdwNavigationSplitView`, `TwoPaneView`. This
pass researched the panes and this plan designs the panes. They share no
machinery and the grid is arguably the cleaner 4/4. Which one is the
milestone, and does the other stay deferred?

**Q2. Is the third pane admitted at all?** It is not the 4/4 that
list-detail was: 2/4 native (SwiftUI's three-column form, Compose's
`extraPane`), 1/4 by the platform's own documented composition
(libadwaita's nesting), and 1/4 by a composition this research
recommends but Microsoft does not (nested `TwoPaneView`s — Microsoft's
own answer is a `NavigationView` rail, whose pane degrades rather than
disappearing, which is a different semantics). No drawn imitation is
involved anywhere, so it is admissible, but Windows is the weak leg. The
alternative is to ship D2's capacity vocabulary with D capped at 2
everywhere, which keeps one declared semantics honest and leaves the
third pane as a capacity increase later — at the cost of a milestone with
no observable change.

**Q3. The macOS carve-out: state it, or remove it?** macOS has no compact
horizontal size class, never collapses a `NavigationSplitView`, and when
squeezed crushes the DETAIL to zero while the leading columns hold their
minimums (measured: 148 / 348 / 0 at a 320pt window). kaya manufactures a
collapse it does not have — a kaya-invented 600pt line plus a container
swap to `NavigationStack`. That was invisible at two panes. At three,
kaya would also be inventing the SHED ORDER, in the opposite direction
from what macOS does on its own, and the reachable state sets differ from
iPadOS's (`{all, doubleColumn}` against four). Does this become a stated
carve-out under DESIGN.md's Binding conventions, or does the macOS
lowering change to stop swapping containers?

**Q4. The Android dependency bump, and a shipped lane's behavior
changing under it.** Three partitions are unreachable at the pinned
`androidx.compose.material3.adaptive:1.0.0`; the milestone needs `1.2.x`
plus `currentWindowAdaptiveInfoV2()` so the Large width class exists at
all. That bump also changes the EXISTING `listdetail` tablet leg: the
`medium_tablet` AVD is 1280dp, past Material's 1200, so it goes from two
partitions to three the day the pin moves, with no scene edited. Take the
bump as a deliberate, watched change to a green lane? The only
alternative is hand-building a `PaneScaffoldDirective` with
`maxHorizontalPartitions = 3`, which is kaya drawing the adaptive line
that DESIGN.md:1696 forbids.

**Q5. Does `panes` REPLACE `list_detail`, or join it?** Replacing slot 6
with an integer means one spec-hash move, a full regeneration, a rewrite
of both scenes and all four backend arms, and a rewrite of the ratified
"Adaptive list-detail" section of DESIGN.md. Churn is free and a Bool
cannot grow to mean three, so the plan proposes the replacement — but it
touches a ratified section and eight binding surfaces, so it is a
ruling rather than an implementation detail.
