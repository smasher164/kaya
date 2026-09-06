# The task manager — the design pass

Status: RULED 2026-09-05 (maintainer: "let's build a task manager"), the
THIRD forcing artifact, in RUST. S0 IS BUILT AND GREEN ON ALL FIVE LANES
(d9346958, fixed forward in 4e3f74fa): guests/rust/tasks.rs and
tools/scenes/tasks.steps, the second matrix ALL PASS on mac, linux,
windows and iOS and the tasks leg green on android beside one recorded
drag WATCH red on dnd-go; §5 holds what the first runs taught. §6 is the
sequencing; S1 (the search field) is next.
The editor (docs/editor-plan.md) and the portfolio
(docs/portfolio-plan.md) are the precedents this file follows; the
prioritization it serves is docs/probes/roadmap-app-needs-2026-09-05.md
and docs/probes/roadmap-framework-parity-2026-09-05.md, read together on
2026-09-05 (docs/deferred.md, "Next milestones").

## §0 — what is already ratified

- **Why this app.** The needs survey found the task manager the
  archetype kaya is nearest to shipping — three must-have gaps (local
  notifications, a search field, badges) against a surface that already
  has keyed collections with reorder, checkboxes, date and time pickers,
  navigation, sidebar sections, drag and drop, undo, menus and adaptive
  list-detail. Grown in the order §6 gives, it forces ten of the twelve
  items the evidence ranked first, including every one of the mobile
  table stakes the video editor (desktop by nature) would never have
  reached: the sheet, the notification permission, dynamic type under
  store review, the splash slot. The video editor becomes the FOURTH
  forcing artifact; its features (the `video` kind, gestures, the
  horizontal scroll axis, the number field, the colour picker, window
  styles) keep their ledger entries with the editor as their trigger.
- **Written in RUST.** The three languages that run on all five lanes
  today are Rust, Go and Python; Go has the editor, Python the
  portfolio, and Rust was already the maintainer's choice for the
  editor. JS is desktop-only by the 2026-09-03 ruling.
- **Synthetic, deterministic data**, the editor's and the portfolio's
  discipline: a fixed seed, a fixed "today", every string in the scene
  computable from them.
- **One identity for now.** guests/assets/identity.toml declares the
  one app identity every guest carries and tools/check-app-identity.py
  holds them to it; a name and mark of this app's own is the packaging
  stage's business (§6 S11), not v0's.

## §1 — the surface (v0, on today's kaya)

A Things-class subset. ONE WINDOW with FIVE SIDEBAR SECTIONS — Inbox,
Today, Upcoming, Anytime and Projects (R4: a phone's tab bar takes five;
the Logbook and Settings are View-menu screens pushed onto the active
section's stack, Settings promoted into the chrome as a gear). Each
smart list is a column: a quick-add row at the top (an
entry and an "Add" button, the todos scene's shape) and a For of task
rows under it. A task row is a checkbox bound to `done`, the title, a
caption label with the when-date or deadline, and a "Details" button;
rows have no click of their own in kaya, so the button is how a row
opens. Details PUSHES an entry (the navigation stack): a textarea for
the notes, a date picker for `when`, a date picker for the deadline, a
time picker for the reminder, a select for the project, a destructive
"Delete" button, and "Back" pops. The Projects section is a For of
project rows, each with its own "Open" button whose click arrives with
the row's key and pushes that project's screen: the project's tasks
with the same quick-add row and, being reorderable, drag to reorder.

THE MODEL:

    Task    { title, notes, when, deadline, reminder, project, done }
    Project { name }

`when`, `deadline` and `reminder` are optional in the app's own struct;
the pickers are always-valued (docs/datetime-plan.md D5), so the detail
screen shows "When: none" beside a picker and a "Clear" button, and a
cleared date is the absence. Dates and times ride kaya's `Date`/`Time`.

WHICH LIST A TASK IS IN is a function of the task: done -> Logbook;
no project and no when -> Inbox; when == today or deadline <= today ->
Today; when > today -> Upcoming; otherwise Anytime. kaya has no
filtered view of a collection (the collection-pipelines gap the parity
survey named), so v0 keeps ONE COLLECTION PER LIST and the app moves a
task between them when its fields change, inside one undoable
transaction — which is exactly the app-side work a filtered view would
remove, recorded here so the gap has a consumer.

"TODAY" IS FIXED UNDER THE HARNESS: with `KAYA_SELFTEST` set the app
reads its clock as 2026-09-07 (a Monday), so the scene's Today and
Upcoming are byte-frozen; a real run reads the system clock. The seed:
three projects (Kitchen, Thesis, Trip), nine tasks spread over Inbox,
Today, Upcoming and Anytime, one already done.

Deliberate v0 stops, each a recorded stop short of a forced feature:

- **No search.** S1 adds a search entry at the top of each list.
- **Counts are labels.** "3 today" is a label in Today's column; S2
  moves it onto the Today section as a badge.
- **Settings is a plain column** behind View>Settings: a select for the
  first day of the week and two checkboxes that S2 turns into switches.
  Nothing persists (S4).
- **Reminders are stored, not fired.** The time picker writes the
  field; S3 turns a reminder into a notification.
- **Quick-add is inline.** S6 moves it into a sheet on the phones.
- **Notes are plain text.** S7 renders links and emphasis.
- **Projects are flat.** No areas, no headings; S8 brings the tree.
- **Nothing survives a relaunch.** S4.

## §2 — the scene (tools/scenes/tasks.steps)

Byte-frozen on all five lanes, one scene for every screen. It reads the
seed (each list's rows by authored id and key, the count labels), adds a
task through the quick-add row and reads it in Inbox, checks a Today
task off and reads it in Logbook with Today's count moved, opens a
task's details, sets its when-date to tomorrow and reads it in Upcoming
after `back`, moves a task to a project through the select and reads
the project's screen through its keyed "Open" button, reorders two rows
in a project by `drag`, deletes a task and undoes it through Edit>Undo,
and reads the settings section. Stamped copies are addressed by
authored id and key (`button@open[trip]`, the portfolio's spelling).
Every mutation is undoable, so the scene's undo steps read the model
the way todos.steps does.

## §3 — the app owns, kaya owns

The app owns the model, the list routing, the seed and the clock; kaya
owns everything the user sees and every occurrence. Persistence (S4) is
the one place the line has to be drawn again: the recommendation there
is a floor call answering the platform's per-app writable directory
(Application Support, the iOS Documents directory, the Android files
directory through the Kotlin side, XDG data home, LocalAppData) so the
guest writes its own document, with kaya's preferences store as a
separate, typed record for the small settings. That is S4's own design
pass, not this one's.

## §4 — rulings (the maintainer's, taken in plain words)

- **R1 — this app, in Rust, third; the editor fourth.** TAKEN
  2026-09-05.
- **R2 — the v0 shape above** (smart lists as sections, one collection
  per list, a Details button per row, inline quick-add, a fixed
  harness clock). PROPOSED; the maintainer may amend any of it and
  churn is free.
- **R4 — five sections, and the phone rule** (TAKEN 2026-09-05, off the
  iPhone and Android captures of seven sections: UIKit folded two under
  More, Material squeezed all seven with wrapped labels). The app
  declares five sections and reaches the Logbook and Settings through
  the View menu; kaya's rule is that a phone above five sections falls
  back to its own overflow idiom (DESIGN.md, Sections), with the
  Android drawer arm and a root-list presentation ledgered.
- **R3 — each later stage takes its own rulings at its own time**, as
  the pickers, sliders and tooltips did: the search field's spelling
  (a role on entry), the switch's (a role on checkbox, or a kind), the
  storage shape (§3), the sheet's grammar, the rich-text subset, the
  tree's model. None blocks S0.
- **R5 — a row centres its children on the cross axis by default**
  (TAKEN 2026-09-05, off the Android capture where "Buy milk" sat flush
  against the row's top beside a taller checkbox; the maintainer: "we
  can make the defaults for how things are laid out a lot more
  aesthetically pleasing than how the platform does it"). Mechanism: the
  CORE emits `align = center` right after every new Row, live and
  template, unless the app sets `align` itself, so all four backends see
  an explicit prop and none carries a default of its own. Columns keep
  `start`. A GRID'S CELLS FOLLOW THE SAME RULE — each centres in its
  row — and a grid's cells are separated by default (GTK's and WinUI's
  bare grids packed them edge to edge, the Linux and Windows captures
  showed four buttons' corners meeting), so GTK and WinUI grids take
  their platform's container gap unless the app sets `spacing`;
  Compose's grid already carried 8dp and NSGridView its own. The scene
  byte on every lane is align.steps' `expect_aligned row@plain
  "center"`: a row declaring no align, holding one label beside the
  scene's tall no-baseline image, built so centre is the only reading.
  It is NOT held on the task row itself — see §5, the classifier
  finding.
- **R6 — a `plain` button role** (TAKEN 2026-09-05, same captures: the
  Details button was the platform's full bordered button against small
  text). Wire 5, buttons only, the LOW emphasis for a row's accessory —
  a Material TextButton, borderless on Apple (an NSButton with
  `isBordered = false` in the accent tint on the mac, `.borderless` on
  iOS), Adwaita `.flat`, WinUI's subtle text button. All nine bindings
  name it; tools/check-sugar-surface.py's role-vocabulary census holds
  every role's NAME in all nine, since the sugar sweep saw only the two
  roles that have constructors. The task rows' Details and the project
  rows' Open wear it.
- **R7 — a stamped row spans its host column** (TAKEN 2026-09-05, the
  §5 finding of the same day): a For's stamped root Row takes the
  column's width on GTK, WinUI and Compose as it already did on SwiftUI
  — DESIGN's nested-container rule applied to stamped copies. THE
  MECHANISM WAS NOT THE ROW: a For is a real Column widget (the core's
  CreateFor), a Column inside a Column does not cross, and under the
  start default it hugged while its stamped rows dutifully filled IT —
  so `expect_fills row@task[t1]` passes with the defect intact (the GTK
  agent's reading, confirmed by the readers). GTK and Compose mark a
  vertical host that holds stamped Row copies and give it fill; WinUI
  marks the same host (its reindex reads the mark as a crossing child)
  AND had a second hug one layer up, NavigationView's content presenter
  templatebound to Left/Top, now stamped Stretch — the first Windows
  capture after the pane fix alone still showed Details beside the
  title, which is how the For column's own hug was told apart. Held by
  `expect_breadth column@inbox_list` on every lane, for which
  expect_breadth accepts a nested container (it refused one before,
  and no other verb reads a container's own extent in its parent). The
  list is NOT grown for it: a first draft grew it so `expect_fills`
  could read tracks, and on the iPhone a grown column of two rows
  spread them into equal bands down the screen — the maintainer caught
  it on the capture; breadth reads a plain column's geometry as it is.
- **R8 — `expect_order` keeps its bare-label reading** (REFUSED
  2026-09-05, after being built on three harnesses and run on one). The
  proposal was that a container child that is not itself a label report
  the first label inside it, so a row carrying a checkbox and a button
  could still be ordered by its title. The iOS lane refused it on
  tools/scenes/feed.steps, whose first line documents the rule it leans
  on: the order is the notes ALONE because a promoted note becomes a row
  and LEAVES the order — that is how the scene observes a variant
  switch, and a deeper reading would have kept the promoted note in
  place and blinded the scene. A container of mixed rows wants a verb of
  its own if a scene ever needs one; none does today, and the project
  screen's rows stay bare labels.
- **R9 — a pushed screen on Compose shows a back arrow** in its top bar
  (TAKEN 2026-09-05, off the Android Details capture that offered no way
  back but the system gesture), taking the route the gesture takes.
- **The Details screen is one grid**, three rows of caption, picker and
  Clear, so the Clear buttons share a column edge — the maintainer's
  first ask on the captures ("The Clear buttons should be aligned with
  themselves").

## §5 — findings ledger

Filled as the stages land: every measured surprise with its date and
the gate or trap it became.

- **2026-09-05, S0 on the mac — a keyed target resolved only in the first
  list.** Five lists' templates share the ids `title`, `caption`, `done`
  and `details`, and every harness read the template node off the FIRST
  copy carrying the id, then matched keys among that template's copies
  alone: `label@title[t3]` in Today was "no such target" with no
  diagnostic, since the guard that prints one had passed. All four
  backends now match each copy under its own tag's node
  (`harness::table_tag_keys_match`; two copies answering is refused by
  name), tools/check-verbs.py forbids the first-copy read coming back
  in any of the four, and this scene is the runtime proof.
- **2026-09-05 — pushes inside a sectioned window.** A sectioned window
  presents each section's own stack and no window stack on macOS, so
  `push_entry` on the window rendered nothing (the model had the entry;
  pickers and drag surfaces never materialized). The app pushes onto the
  section the row came from, and the three harnesses' implicit
  `expect_entries` and `back` follow the ACTIVE surface (DESIGN.md,
  Sections).
- **2026-09-05 — a control read racing its materialization.** `set_date`
  and `drag` read an AppKit control or surface once, immediately after a
  model-level expect passed on the freshly pushed screen, and said "no
  such target" for a node that existed. The SwiftUI verbs wait for the
  control (`kayaAwaitOnMain`, the step's own ceiling below it) and the
  two misses are two sentences. GTK and WinUI materialize synchronously
  on their UI thread; Compose's verbs already await.
- **2026-09-05, the first matrix — GTK and WinUI could not go back out of a
  section's pushed entry.** Both lanes read `entries 1, wanted 0` after
  `back`, then died pushing the same entry id again. GTK's window back
  button showed only over the WINDOW's stack, so a section's pushed entry
  had no back affordance at all — a real backend gap, not a harness one —
  and the WinUI harness verb looked for the top entry on the window's
  stack. GTK's button now follows the active section's stack
  (`refresh_section_back`, on every section reconcile and select) and the
  WinUI verb routes as its own user back does. Both legs green alone
  the same hour.
- **2026-09-05 — a popped screen's rows stay alive for keyed targets.**
  The core emits no `Destroy` for a popped entry's subtree (the ledger's
  "core never prunes `self.widgets`" leak), so the Logbook screen's
  stamped copies stayed in the registries after `back` and a keyed read
  of `caption[t9]` found two copies — the new diagnostic said so by
  name. The app gives its pushed screens their own ids (`lb_title`)
  until the core tears a popped entry down; the ledger entry now
  carries the consumer and the fix.
- **2026-09-05 — a live checkbox has no sugar for an initial state.** The
  Settings screen's first draft set `Prop::Checked` at the floor and
  tools/guest-floor.py refused it (invariant 5). Rust's live zone spells
  `checkbox(text)` unchecked and nothing else; the template zone binds a
  field. The screen became a one-row stamped record, which is the sugar
  kaya has; whether the live zone wants `checked(bool)` in nine bindings
  is a small sweep, ledgered.
- **2026-09-05, the Windows capture — WinUI's checkbox is wide too.** The
  task rows on Windows show a hundred-pixel gap between the box and the
  title: WinUI's CheckBox carries a default MinWidth of 120, so a
  text-less checkbox claims that width where the mac's and GTK's hug the
  box. The iPhone's greedy switch one platform over; the same rule
  applies (a text-less checkbox hugs its box) and the WinUI arm now sets
  MinWidth 0 on creation, a captioned box still sized by its content. The
  same missing layout assertion would have caught both. The same review
  found the rows' trailing Details buttons drifting with the title's
  width; a template `spacer()` takes the free width so they share one
  edge, which is the list-row idiom on every platform.
- **2026-09-05, the review before republishing — a grown entry stopped
  short on SwiftUI.** The quick-add field filled its row on GTK and WinUI
  and stopped at 200 points on the mac and the iPhone: `KayaEntry` capped
  every entry at 200 regardless of `grow`, the shape the slider arm had
  already been corrected for. The cap now yields to a grower's track. No
  layout scene puts a grown entry in a row, so the capture was again the
  first witness; the three findings of this kind (the iPhone switch, the
  WinUI checkbox, the SwiftUI entry) argue for a layout scene of the
  common list-row shapes, ledgered.
- **2026-09-05, the captures after the spacer — a stamped row spans on
  SwiftUI and hugs on the other three.** With the spacer in place the
  Details buttons share one edge on every platform, but that edge is the
  window's on the mac and the iPhone and the content's on GTK, WinUI and
  Compose: the For's stamped rows take the column's width on SwiftUI and
  hug their content elsewhere, so the spacer has nothing to take. DESIGN's
  layout rule says a nested container maximizes its own main axis; the
  three widget backends did not apply it to a stamped row. FIXED
  2026-09-05 under R7 on all three (R7 records the true mechanism, which
  was the For's own column and, on WinUI, the section pane), held by
  `expect_breadth column@inbox_list` in tasks.steps on every lane; the
  ledgered list-row layout scene keeps its other shapes.
- **2026-09-05, the same captures — the platform's row defaults are not
  the app's.** A row aligned its children to the top (Compose drew "Buy
  milk" flush against the row's top edge beside a taller checkbox; the
  mac and WinUI happened to look centred only because their controls
  were of a height), and the trailing Details was the platform's default
  bordered button, on Material a large rounded rectangle beside small
  text. Both were kaya's defaults, not bugs in any backend, and the
  maintainer rejected them on sight. R5 (rows centre) and R6 (the plain
  role) are the answer; the row default is emitted by the core so no
  backend's own default can drift from it.
- **2026-09-05 — a row of same-size text reads centre AND baseline.**
  `expect_aligned row@task[t1] "center"` passed on the mac, the iPhone
  and GTK and failed on Compose with `aligns "ambiguous
  (center|baseline)"`: the classifier answers from geometry alone, and
  a centred row whose text children share a font size has coinciding
  baselines too, within its 2px tolerance, on the one toolkit where the
  label and the text button happened to agree. The classifier is right
  to refuse a guess; the guard moved to align.steps' `row@plain`, whose
  tall no-baseline image beside one label leaves centre the only fit.
  The lesson for any future `expect_aligned` line: pick geometry that
  separates the modes, never a row of look-alike text.
- **2026-09-05 — the Details grid overflows a 320dp Android phone.**
  Three columns of caption, picker and Clear fit the desktops and the
  iPhone (whose pickers are compact buttons), and overflow on Compose,
  whose date and time pickers are 280dp text fields: the grid centres
  in the screen and clips both the captions and the Clear buttons. Two
  remedies, both rulings: widen the breakpoint setters from axis-only to
  `columns` (adaptive-layout D6's open slot — compact -> one column),
  or lower Compose's pickers as content-sized buttons that open the M3
  dialogs, the shape iOS and the three desktops already have. BOTH TAKEN
  2026-09-05 ("okay sounds good"): the Compose field is as wide as its
  value (Material's 280dp text-field minimum dropped; measured by
  rememberTextMeasurer, a grower still takes its track), which alone
  still overflowed a 320dp phone by some 30dp a side, and the grid
  folds to ONE column under compact through `columns_when(compact, 1)`
  — the breakpoint setters widened from axis-only to a grid's columns
  (adaptive-layout D6.2, all nine bindings, adaptive.steps' grid@sheet
  asserting 1 and 3 on every lane). And the Details column scrolls
  now: folded to one column the form is taller than a phone, and the
  first Android capture of the fold showed its tail under the tab bar
  and its first caption drawn over the notes field — a column squeezed
  past its content on Compose; a form's platform idiom is a scrolling
  one on every platform, and on the desktops the scroll is invisible.
- **2026-09-05, the folded iPhone form — mechanical, not idiomatic.**
  Under compact the Details grid folds to caption, value and Clear
  stacked three deep per field, which fits and scrolls but reads heavy
  against the platform's own form idiom (one row per field, the value
  trailing, clearing inside the value's own control). The fold is what
  `columns` alone can say; a phone-shaped form is a layout question for
  a later slice, not a defect of the breakpoint.
- **2026-09-05, seen on the folded Android form — a section's scroll runs
  under the bottom bar.** The Details form's last field is cut at the
  NavigationBar's top edge and continues behind it: on Compose a
  section's content extends to the window's bottom and the opaque bar
  covers it, where Material's own Scaffold ends content above the bar
  (iOS's translucent tab bar is the one platform where content under
  the bar is the idiom). Recorded, not fixed here: a Compose sections
  layout question for its own slice.
- **2026-09-05, the Windows captures — a boxed hamburger, and a back
  arrow inside the content.** Both were kaya's WinUI arm, not the
  platform: the window gave no control initial focus, so XAML seated it
  on the first tab stop (the pane toggle) and drew its keyboard focus
  visual there on a launch no pointer had touched; and a pushed entry's
  back button was the backend's own row above the content, a shape from
  before sections. The maintainer's ruling on the layout ("dont
  vertically stack the back arrow above the hamburger icon"): the
  Windows 11 Settings shape — NavigationView's own back button alone at
  the pane's top left, the pane toggle hidden while the pane is
  expanded and shown only in the collapsed modes, and initial focus
  seated in the section's content (its first focusable control, on the
  pane's Loaded). The harness `back` drives the pane's button through
  the same user_back route and stops where the button is disabled.
- **2026-09-05 — GTK's picture shrinks under pressure, the other three
  do not.** align.steps' `row@plain` read "stretch" on the linux lane
  alone: GtkPicture's default can_shrink reports a 0x0 minimum, so a
  root column short of room squeezed the plain row to its label's
  height and the 2x64 image to 40px, and the label then spanned the row.
  Measured with the classifier's new `KAYA_ALIGN_TRACE` instrument
  (docs/HACKING.md); GTK images hold their intrinsic size now.
- **2026-09-05 — there is no checkbox-state observation.** `expect
  checkbox@done[t3] checked` reads a LABEL on every harness; no scene had
  ever asserted a checkbox's state. The scene proves completion through
  the counts and the row's list instead; a `checked` read is a harness
  slice of its own if a stage needs it.
- **2026-09-05, the phone captures — seven sections, and a greedy
  switch.** UIKit folded Projects and Settings under More; Material
  squeezed all seven with the labels wrapping mid-word. Ruled R4. The
  same captures showed the iPhone's task rows pushed to the right: the
  SwiftUI arm's checkbox is a UIKit switch with no fixed size, so it
  took the row's free width where every other platform's checkbox hugs.
  Fixed (`fixedSize` on iOS, a grower keeping its track); no layout
  scene asserts a checkbox's hug inside a row, which is why the capture
  was the first witness.

## §6 — sequencing (the evidence's order, one forced feature per stage)

| stage | builds | forces | order rank |
|---|---|---|---|
| S0 | the app on today's surface: guest, scene, five lanes | nothing new; the consumer for everything below | — |
| S1 | a search entry filtering the open list | the search field (a role on entry) | 1 |
| S2 | switches in Settings, the Today badge, a link in notes, the launch slot | toggle switch, badge, hyperlink label, splash | 2 |
| S3 | a reminder fires as a notification; activating it opens the task | local notifications | 3 |
| S4 | tasks survive a relaunch; settings persist | app data directory, the preferences store, window memory | 4 |
| S5 | the app under the largest text size, an RTL locale, a non-US locale, on every lane | the compliance pass | 5 |
| S6 | quick-add as a sheet on the phones | the modal sheet | 6 |
| S7 | notes with links and emphasis; two-line row captions | rich text, text layout props | 7 |
| S8 | areas, projects and headings in one sidebar | the tree view | 8 |
| S9 | reminders fire with the app closed | OS-scheduled background work | 9 |
| S10 | check-off, insert and remove animate | implicit animation | 11 |
| S11 | the app in five stores under its own name and mark | packaging, per-app identity | 12 |

The `video` kind (rank 10) is the editor's and does not appear here.
S0 lands depth-first on the mac, then the other four lanes wire the one
Rust guest; every later stage is a feature slice in its own right —
design pass, depth on the mac, breadth across backends and the eight
other bindings, the matrix — with this app as its scene.
