# Forms: the labelled row, and the form derived from it

Design pass, written overnight 2026-09-06 under the maintainer's grant
("yeah all three of those things in order honestly. just work on it now").
The rulings here are PROPOSED-overnight: taken so the slice could be built,
marked for his morning, and churn is free if he wants any of them changed.

## §0 — what the captures said

The task manager's Details screen (docs/tasks-plan.md §5, 2026-09-05) is a
notes field, three dated values each with a caption and a Clear, a project
select and a Delete. Three shapes were tried for the three values:

- caption above a row of picker and Clear: the Clear buttons drifted;
- one three-column grid of caption, picker, Clear: aligned on the
  desktops and the iPhone, off both edges of a phone;
- the grid folded to one column under compact: fits, and the maintainer's
  verdict was "kinda worse now ... clearly there's a lot of whitespace on
  the right".

Every platform already has the right control for this: a row whose label
names its value, laid out side by side when the two fit and stacked when
they do not, with the labels of neighbouring rows sharing one column.
SwiftUI's `Form` with `LabeledContent`, Material's list item with its
value trailing, Adwaita's action and entry rows, WinUI's settings card.
kaya could not ask for it, because a row of a caption and a picker says
nothing about the caption naming the picker.

## §1 — the design in one paragraph

ONE NEW ROW SHAPE, ONE DERIVED RULE, NO NEW WIDGET FAMILY. A `labeled`
container holds a label, the control it names and, optionally, one
trailing action. That pairing is a semantic fact rather than a layout
hint: assistive technology gets the label-for relation no bare row can
carry, and the backends get the signal to lower the pair to their native
labelled control. A vertical container whose children are all labelled
rows is a FORM, derived the way a For with column headers is a table and
a screen with a table is a grouped screen on iOS: the backend lowers the
column to its form surface with the label column shared, and the platform
control decides side by side against stacked from its own rules on its
own widths. kaya declares the pairs and rides the native engine
(DESIGN.md, Layout: normalize semantics, not metrics).

## §2 — the spec

- Kind `labeled` (18), a container. Props: the universal ones (a11y,
  help), `spacing`, `inset`; no `align` (the platform control owns the
  cross axis) and no `axis`. Grow rides as on any container.
- Children, validated at the root when the transaction ends (the slider's
  relations are the precedent): TWO or THREE. The first is a `label`
  (any role; a caption reads as a hint under the value on platforms that
  have that seat). The second is the control: any leaf that is not a
  label — entry, textarea, checkbox, slider, select, radio, date_picker,
  time_picker, progress, image, canvas, button. The optional third is a
  BUTTON, the trailing action (the Clear). Anything else, or a nested
  container, dies at the root by name. A `labeled` row inside a template
  is the settings-record case and is allowed in both zones.
- The FORM is not declared. A `column` whose laid-out children are all
  `labeled` rows (two or more) IS one; the backends read that shape at
  AddChild and at TemplateEnd, the grouped-screen rule's mechanism. A
  column mixing labelled rows with other children is a plain column, and
  its labelled rows still lower to the platform's labelled control one at
  a time — only the shared label column and the group surface need the
  whole column to qualify.

## §3 — lowerings (each platform's own labelled control)

- SwiftUI, macOS and iOS: `LabeledContent(label) { control }` for a row;
  a qualifying column renders as `Form { ... }` (grouped on iOS, the
  settings look on macOS), the trailing button as the content's trailing
  sibling in an HStack. Form/LabeledContent decide side-by-side against
  stacked themselves; the mac keeps them side by side.
- GTK: `AdwActionRow` with the label as title and the control as a
  suffix, the trailing button a second suffix; a qualifying column is an
  `AdwPreferencesGroup` holding the rows (the boxed-list look). An entry
  control uses `AdwEntryRow` only if the sizing contract survives —
  measure first; the plain ActionRow with an entry suffix is the fallback.
- WinUI: a labelled row is a two-column Grid (label Auto, control Star,
  action Auto); a qualifying column becomes ONE Grid with three columns
  and a row per labelled child, so the label column is shared — WinUI has
  no SharedSizeGroup and the Community Toolkit's SettingsCard is not in
  the tree. No fold on Windows: desktop widths.
- Compose: `ListItem(headlineContent = label, trailingContent = control
  [+ action])` for a row; a qualifying column wraps the rows in the M3
  grouped container the table card already draws (docs/tables-plan.md,
  check-table-card). Material puts the value trailing; a wide control
  (a text field) goes under the label as supportingContent, which is
  Material's own fold.

## §3.1 — the nine spellings (built 2026-09-06)

Each binding's own container idiom, the label first and the body after,
in BOTH zones; a signal-bound label where the binding binds text:

- Rust: `tx.labeled(label, |tx| ...)` / `tpl.labeled(...)`, and on the
  `Row` façade.
- Python: `with kaya.labeled("When"): ...` (a context manager, like
  `row`/`column`).
- JS: `kaya.labeled(label, () => { ... })`, a string or a signal.
- Go: `tx.LabeledText("When", func() {...})` / `tx.Labeled(sig, ...)`, and
  `LabeledBound` in the template zone — two names because Go cannot
  overload and the sugar census reads `Labeled[A-Za-z]*(`.
- C#: `tx.Labeled("When", () => {...})` with `Signal` and `Field<string>`
  overloads; the generated `<Rec>Row` façade forwards it.
- Java: `tx.labeled("When", () -> {...})` with `Signal<String>` and
  `Field<String>` overloads, on `RowSurface` too.
- Swift: `tx.labeled("When") { ... }` with a `KayaSignal` overload.
- OCaml: `labeled ?label ?label_bind children ()` (+ `?label_field` in
  `Tpl`) — the binding's own constant-or-signal pair of optionals.
- Haskell: `labeled src children` / `labeledOf` in the template zone,
  after `rowOf`/`columnOf`.

## §4 — observables

- The relation: `expect_ax <control> "<kind>/<label text>"` — the labelled
  control's accessibility name IS the row's label text on every platform
  (AX label from LabeledContent, the ActionRow's title as accessible
  label of its suffix, WinUI's `AutomationProperties.LabeledBy`, Compose
  `semantics { contentDescription }` merged from the headline). The
  spelling already exists (check-verbs pins it QUOTED); a labelled control
  whose AX name is not the label fails on that lane by name.
- The geometry: `expect_form_columns column@<id>` — a qualifying column's
  controls share one leading edge; the grid's column reader
  (`grid_columns`) already clusters leading edges and is the model. Held
  on the desktops; a phone that stacks reports one cluster, which the
  phone cuts assert as their own truth (the adaptive scene's pattern).
  NOT BUILT in the overnight slice: the relation is the guard that
  shipped; the geometry verb is ledgered.
- A `labeled` with the wrong children fails the unit tests at the root;
  the sugar census demands the constructor in all nine bindings in both
  zones (check-sugar-surface's KIND clause, once `labeled` is in the
  generated wire tables); check-steps' TARGET_KINDS and tpl-surfaces'
  DEFAULT_KINDS grow by the name (docs/traps.md, "Two kind lists").

## §5 — the scene and the app

tasks.steps' Details screen: the three values become labelled rows
("When", picker, Clear; "Deadline"; "Reminder") and the project select a
fourth ("Project", select) — the column then qualifies as a form on every
platform and the grid goes. The caption texts ("When: Mon 7 Sep") move to
the label's own text with the date spelled in it, or stay as the value's
hint; decided at build time by what reads well on the mac. Existing
asserts keep their ids (`date_picker@when`, `button@clear_when`,
`label@when_text`). New: `expect_ax date_picker@when` on every lane,
`expect_form_columns column@details` on the desktops.

## §5.1 — what the mac build found (2026-09-06)

- `LabeledContent` gives a HOSTED control (the NSDatePicker) no accessible
  name of its own, so the relation is stated on the control:
  `.accessibilityLabel(label.text)` unless the app named it. With it the
  picker reads `id=when desc=When: none` in KAYA_AX_TRACE and
  `expect_ax date_picker@when "datetime/When: none"` holds.
- A labelled row must NOT carry an a11y_id of its own on macOS today: the
  container's identifier overrides its children's in the AX tree
  (docs/traps.md), and the picker vanished from `expect_ax`'s walk. The
  task manager addresses the pickers and buttons, never the rows.
- The mac's grouped Form insets its card from the column's edges, so the
  notes field above and the Delete button below sit wider than the form:
  the platform's own settings look, kept as is; a column that is ALL form
  would show no seam, and the task manager's is not.
- WinUI shares the label column by PINNING each row's first column to the
  widest label, measured (an unbounded Measure on every sibling's label,
  re-run when a bound label's text changes or the typeface moves), not by
  one big Grid: reparenting the rows' children into one grid takes each
  row's own Grid out of the visual tree, and the readers and the row's
  spacing and inset need it there. The relation is
  `AutomationProperties.LabeledBy`, which UIA answers only when the
  control has no name of its own, so an app's a11y_label still wins.
- Compose folds every control but a checkbox UNDER its label
  (supportingContent), the settings-screen shape; trailing content
  starved the headline on a 360dp phone ("Project" one letter per line
  beside a 280dp select). The select's field is sized to its value too.
- iOS draws the form as the inset-grouped card the table and the fold
  already draw: a List-backed Form inside a scroll collapses to nothing
  (measured 2026-09-06, the whole form gone from the phone). macOS keeps
  the grouped Form.
- A FORM IS A GROUPED-SCREEN CARRIER on iOS (docs/adaptive-layout-plan.md
  D7.5, widened): the card was invisible on the Details screen's white
  ground (captured 2026-09-06), because only a table made a screen
  grouped. A screen holding a form takes the grouped ground, the form is
  a section body of its own, and its neighbours card as runs — the
  Settings shape the form was drawn to match. Three things the first
  grouped build taught (captured and measured 2026-09-06): the form
  branch of the column arm must precede the flex branch, since the
  section stream renders the form stretched and the flex branch took it
  first (card and dividers gone); a grouped flow's CONTENT BOX is its
  cards' interior, so KayaBoxReader records the cross less the card
  inset and kayaCarded gives each child a cell reader — `expect_breadth
  textarea@notes` had read "no cross box recorded"; and a text area
  inside a card draws no border of its own (`kayaInGroupedCard`), the
  card being the boundary, as Reminders' notes field has none.
- iOS folds a labelled row through one `Layout` (`KayaLabeledFold`): side
  by side when the three fit the width, the value and its action under the
  label when they do not. LabeledContent alone crushed a Clear beside a
  date to one letter per line on the iPhone (measured 2026-09-06). The
  first fold was a `ViewThatFits`, which measures a second copy of the
  picker; the copy's dismantle emptied the harness registry and `set_date`
  found no control (docs/traps.md). A Layout holds one control, so the
  fit test is kaya's own arithmetic over the platform's measured sizes —
  the one place F5 yields, and only because the platform's fit test
  duplicates the subtree.
- The scene's caption reads (`label@when_text "When: none"`) became the
  relation reads: the label is the row's own child now and the picker's
  accessible name is the observation that matters.

## §6 — sequencing

Depth first: spec + protocol/wire/capi + scene.rs validation and tests +
Rust sugar (both zones) + SwiftUI (LabeledContent/Form) + tasks.rs +
tasks.steps, green on the mac by hand. Then breadth in parallel: GTK,
WinUI, Compose as three agents with their compile gates; the other eight
bindings' sugar in both zones as one agent, verified by the gallery scene
guests (§7); then the phone and desktop lanes by hand for captures, all
twenty screens reviewed, ONE matrix, commit.

## §7 — rulings, all PROPOSED-overnight

- F1 a KIND, not a prop on row: the shape is validated at the root and
  the constructors are censused; a prop would let a bare row carry a
  flag nothing checks.
- F2 the trailing action slot: one button, the Clear's seat, so the value
  and its clearing stay in the platform control's own suffix position.
- F3 the form is DERIVED from a column of labelled rows; no `form` kind.
- F4 the label is a label node, roles allowed; the control is any
  non-label leaf; nothing nested.
- F5 the phone's side-by-side against stacked is the platform control's
  decision, never kaya's arithmetic (DESIGN.md Layout).
- F6 the gallery scene gains one labelled row so every binding's
  constructor is exercised by a compiled guest, the adaptive scene's
  reasoning (docs/adaptive-layout-plan.md §2).

- The phone fold is PER ROW (KayaLabeledFold folds the one row whose
  label, control and action do not fit): on the iPhone the When row
  folds while Deadline, Reminder and Project sit side by side. A form
  could instead fold every row once any row folds, the shared-label
  column's phone analogue. Taken per row overnight because it is the
  platform's own ViewThatFits behaviour one Layout over; the per-form
  alternative is one line in the Layout if you prefer it.
