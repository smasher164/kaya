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
