# The task manager — the design pass

Status: RULED 2026-09-05 (maintainer: "let's build a task manager"), the
THIRD forcing artifact, in RUST. Nothing built yet; §6 is the sequencing.
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

A Things-class subset. ONE WINDOW with SIDEBAR SECTIONS for the smart
lists — Inbox, Today, Upcoming, Anytime, Logbook — and a sixth section,
Projects. Each smart list is a column: a quick-add row at the top (an
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
screen shows "No date" beside a picker and a "Clear" button, and a
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
- **Settings is a plain column** under a seventh section: a select for
  the first day of the week and two checkboxes that S2 turns into
  switches. Nothing persists (S4).
- **Reminders are stored, not fired.** The time picker writes the
  field; S3 turns a reminder into a notification.
- **Quick-add is inline.** S6 moves it into a sheet on the phones.
- **Notes are plain text.** S7 renders links and emphasis.
- **Projects are flat.** No areas, no headings; S8 brings the tree.
- **Nothing survives a relaunch.** S4.

## §2 — the scene (tools/scenes/tasks.steps)

Byte-frozen on all five lanes, one scene for every screen. It reads the
seed (each list's rows through `expect_rows`, the count labels), adds a
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
- **R3 — each later stage takes its own rulings at its own time**, as
  the pickers, sliders and tooltips did: the search field's spelling
  (a role on entry), the switch's (a role on checkbox, or a kind), the
  storage shape (§3), the sheet's grammar, the rich-text subset, the
  tree's model. None blocks S0.

## §5 — findings ledger

Filled as the stages land: every measured surprise with its date and
the gate or trap it became.

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
