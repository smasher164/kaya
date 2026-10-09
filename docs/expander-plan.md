# The expander: the design pass (2026-10-09)

Status: RULED 2026-10-09 (the maintainer: "im cool with your rulings"), K1-K19 as
recommended; AMENDED 2026-10-09 (the maintainer: "i like both rulings"): a column
of only expanders drawing as a grouped card (K11) is accepted, and the summary line is spoken by
the screen reader on every platform, as part of the header's accessible description; nothing built yet. He picked the expander next on the 2026-10-09 shortlist. Its
roadmap card (docs/roadmap/features.toml, `expander`) gives the shape as "prop
on column (collapsible, titled)"; this pass is the evidence for how that shape
is spelled, and K1 recommends a kind instead. The segmented control's and the
toast's plans (docs/segmented-plan.md, docs/toast-plan.md) are the shape of
this one; the labelled row and the derived form (docs/forms-plan.md) and the
grouped screen (docs/adaptive-layout-plan.md D7.5) are what it sits inside.

An EXPANDER, in this file, is a header the user can always see and a body
below it that the user shows and hides by activating the header. Apple calls
it a disclosure group, GTK and WinUI an expander, libadwaita an expander row,
Material has no component for it. It is not a section (DESIGN.md, Sections),
which switches between whole retained roots, and not a `when`, which the APP
mounts and unmounts.

## §0 — What the platforms offer

Rows marked MEASURED were measured for this pass (§7). The rest comes from
the vendors' documentation and source, cited at the end of the section; "to
measure" is the depth's or the breadth's.

| | the control | header | expand and collapse | keyboard | a11y identity and state | body while collapsed | nesting, lists |
|---|---|---|---|---|---|---|---|
| macOS | SwiftUI `DisclosureGroup` (macOS 11), drawn with AppKit's disclosure triangle beside the label; `Section(isExpanded:)` for a collapsible list or sidebar section is macOS 14, above kaya's floor of 13 | `init(_:isExpanded:content:)` takes a string; `init(isExpanded:content:label:)` takes any view | the platform's own animation; `isExpanded` is a `Binding<Bool>`, so the app writes it and the user's click sets it | the triangle is a key view under the system's Keyboard navigation setting only, like every mac control but a text field (docs/segmented-plan.md G6); Space toggles (to measure) | to measure: the triangle's AX role (AXDisclosureTriangle is AppKit's for the triangle button) and how its AXValue reports the state | to measure whether SwiftUI keeps the body's views while collapsed | DisclosureGroup nests (Apple's own example nests one); inside a `List` it draws as an outline row |
| iOS | the same `DisclosureGroup` (iOS 14); `Section(isExpanded:)` is iOS 17, above the floor of 16 | as macOS | as macOS; the label row is tappable and a chevron turns | none from a hardware keyboard without Full Keyboard Access (the reveal plan's V10 finding, one control over) | a button that VoiceOver reads as expanded or collapsed (the CVS Health iOS techniques); an `accessibilityLabel` on the DisclosureGroup itself REPLACES everything the body would have spoken, so a name belongs on the label only | to measure, as macOS | as macOS; inside a `Form` or `List` it is a grouped row |
| GTK 4 | `GtkExpander`: a triangle and a label, one child | `label` (text, markup, mnemonic) or `label-widget`, any widget | `expanded` with `notify::expanded`; NO ANIMATION in gtkexpander.c | the title is focusable, `activate` toggles, so Space and Enter (to measure) | `GTK_ACCESSIBLE_ROLE_BUTTON`, and `GTK_ACCESSIBLE_STATE_EXPANDED` kept current (gtkexpander.c) | the child is UNPARENTED when collapsed and kept by reference: "we only add the child to the box if the expander is expanded; otherwise we just claim ownership of the child" | a GtkExpander can hold anything, another one included |
| GTK 4 / libadwaita | `AdwExpanderRow` (since 1.0; prefixes and suffixes since 1.4; the lane image ships 1.9.2, docs/segmented-plan.md §7): a row of a boxed list whose body is a nested list of rows | the header IS an `AdwActionRow`: `title`, `subtitle`, prefixes, suffixes; an arrow at the end | `expanded`; a `GtkRevealer` with `slide-up` bound to it (adw-expander-row.ui); optional `show-enable-switch` puts a switch in the header that disables the body | the row is activatable, `activate` toggles; Up and Down leave the row for its neighbours (`keynav_failed_cb`) | `GTK_ACCESSIBLE_STATE_EXPANDED` on the header action row (adw-expander-row.c) | the revealer keeps its child and unmaps it | the body is a `GtkListBox` with the `nested` style; children are rows; built for preference pages |
| WinUI 3 | `Expander`. MEASURED in the pinned WinUI 2.2.1 metadata: `Expander`, `ExpandDirection`, `ExpanderAutomationPeer`, `ExpanderExpandingEventArgs`, `ExpanderCollapsedEventArgs`, `ExpanderTemplateSettings`; crates/kaya/src/winui/bindings.rs names none of them yet | `Header`, any content: "Both the Header and Content areas can contain any content"; Microsoft's own sample puts a summary of the body's choices in the collapsed header | `IsExpanded`; `Expanding` and `Collapsed` events; `ExpandDirection` Down or Up; MEASURED from generic.xaml: the expand storyboard runs 333 ms and the collapse 167 ms | MEASURED from generic.xaml: the header is a `ToggleButton` (`x:Name="ExpanderHeader"`, AutomationId `ExpanderToggleButton`), so Tab reaches it and Space or Enter toggles | `ExpanderAutomationPeer` implements `IExpandCollapseProvider` (ExpandCollapseState, Expand, Collapse) | MEASURED from generic.xaml: the body sits in `ExpanderContent` with `Visibility="Collapsed"`, so it stays in the tree, collapsed | Microsoft's guide shows four expanders nested in one; "it does not overlay other UI"; no light dismiss |
| Android, Compose | NO expander in Material 3 (material3 1.3.1 from the pinned BOM 2024.10.01), nor in Material's guidance; Material 1's expansion panels were never brought forward. What Google's Compose docs show is a clickable header over `AnimatedVisibility` | whatever the app composes; the common shape is a `ListItem` with a trailing chevron | `AnimatedVisibility`: "By default, the content appears by fading in and expanding, and it disappears by fading out and shrinking" | the clickable header is a focus stop; Enter or Space clicks it (to measure) | the app's own semantics: `stateDescription` "Expanded"/"Collapsed" and an `onClickLabel`, or the `expand`/`collapse` semantics actions; `AccessibilityNodeInfo.setExpandedState` is API 36, above the lane's API 35 image | "Animated visibility will eventually remove the item from the composition once the animation has finished": the body's composables and their remembered state are gone | whatever the app composes |

Five facts decide the design:

1. **Every platform but Android has the control, and they agree on its parts.**
   A header always visible, one body below, a Bool the app may write and the
   user's activation flips, collapsed by default. Only WinUI expands upward,
   and only libadwaita offers an enable switch in the header.
2. **Every platform presents the header as a BUTTON with an expanded state.**
   GTK says button plus EXPANDED, WinUI a toggle button inside an
   ExpandCollapse peer, iOS a button VoiceOver calls expanded or collapsed,
   Compose a clickable with a state description. None has a role named
   "disclosure" that all five share.
3. **Whether the body survives collapse disagrees.** GTK keeps it by
   reference, libadwaita and WinUI keep it hidden, Compose throws it away.
   So kaya's own model, not the platform's widgets, is what can keep the
   body's state.
4. **The headers differ in what they can hold.** GTK's plain expander,
   SwiftUI and WinUI take any view; libadwaita's header is a title, a
   subtitle and prefix or suffix widgets; Compose has none of its own. Text
   with an optional second line and an optional glyph is what all five draw
   natively.
5. **The settings look is the expander's home on three platforms.**
   libadwaita's row lives in preference pages, WinUI's Expander is the
   Windows Settings card's expandable form, and SwiftUI's DisclosureGroup in
   a Form is a grouped row. That ties the expander to kaya's derived form.

Sources: Apple, DisclosureGroup
(developer.apple.com/documentation/swiftui/disclosuregroup) and
Section.init(isExpanded:content:header:)
(developer.apple.com/documentation/swiftui/section/init(isexpanded:content:header:));
CVS Health, iOS SwiftUI accessibility techniques, Accordions
(github.com/cvs-health/ios-swiftui-accessibility-techniques,
Documentation/Accordions.md); GTK, GtkExpander
(docs.gtk.org/gtk4/class.Expander.html) and gtk/gtkexpander.c;
libadwaita, AdwExpanderRow
(gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.ExpanderRow.html),
src/adw-expander-row.c and src/adw-expander-row.ui; Microsoft Learn, Expander
(learn.microsoft.com/windows/apps/design/controls/expander) and
ExpanderAutomationPeer
(learn.microsoft.com/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.automation.peers.expanderautomationpeer);
Android Developers, Animation modifiers and composables
(developer.android.com/develop/ui/compose/animation/composables-modifiers),
Semantics (developer.android.com/develop/ui/compose/accessibility/semantics),
AccessibilityNodeInfo
(developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo).

## §1 — What kaya has

- **Containers.** `column`, `row`, `grid`, `scroll` and `labeled` (kind 18)
  hold children; `labeled` is the precedent for a container whose children
  the root validates when the transaction ends (docs/forms-plan.md §2).
  `segmented` is kind 25, the last.
- **The derived form.** A column whose children are all labelled rows (two or
  more) IS a form: SwiftUI's `Form`, an `AdwPreferencesGroup` of
  `AdwActionRow`s, one shared-column Grid on WinUI, Material's grouped
  container on Compose (docs/forms-plan.md §2, §3). On iOS a form carries the
  grouped screen (docs/adaptive-layout-plan.md D7.5).
- **The checkbox's contract.** `checked` (prop 2) is a Bool the app writes as
  configuration; the user's flip reaches the app as `toggled` (record 3) and
  the app's write never echoes. The reveal toggle reused that record for its
  own Bool (docs/reveal-plan.md V2). The harness drives it with `toggle
  <target> on|off`, an action verb with both waits.
- **`when`.** `create_when` (record 12) mounts a template while a Bool signal
  is true and TEARS IT DOWN when false. It is the app's own show and hide,
  with no header and no user gesture.
- **Symbols.** `symbol` (prop 41), the closed glyph vocabulary, legal on a
  button and on a segmented control's option labels.
- **Windowing.** A stamped copy exists only while its row is in the realized
  band; re-stamping reads the row's current data (docs/virtualization-plan.md
  §1). A copy's widget state the app never wrote back does not survive
  scrolling away.
- **The closed AX word set.** harness.rs's ROLES: button, label, field,
  checkbox, slider, image, progress, combobox, group, heading, datetime,
  unknown, switch, link (DESIGN.md, Accessibility).
- **No disabled state** on any widget (docs/deferred.md, the `enabled` prop
  entry), and **no disclosure anywhere** in the four backends today.
- **The model-read defect class.** The segmented pass found the interpreters
  answering `expect` from the model (docs/segmented-plan.md G10). An expander
  read off `node.expanded` would repeat it.

## §2 — The rulings (RULED 2026-10-09, as recommended)

### K1 — A container kind, `expander`, not a prop on `column`

RECOMMEND a new container kind, `expander` (kind 26). Its children are the
body, laid out as a column (spacing, inset, align, grow and fill as a column
takes them); its header is its own props (K2, K3).

The roadmap card's shape, a `collapsible` prop on a column with a title, is
refused for three reasons:

- Every platform makes the header a node of its own with its own focus stop,
  its own accessibility element and its own state (§0 fact 2). A prop that
  silently grows a button on top of a column makes one node into two, and
  the harness's `column#0` would address which?
- A column already means something to the derivations: a column of labelled
  rows IS a form (docs/forms-plan.md §2), and a table-bearing column is a
  grouped screen's primary flow. A collapsible column of labelled rows would
  be both a form and an expander, and every backend would have to agree on
  which wins. A kind is one or the other by construction (K11 says how the
  two meet).
- A kind has the walls a prop lacks, the segmented control's G1 argument:
  `expander#0` resolves or it does not, the kind joins the sugar and
  template censuses in all nine bindings, and check-stubs holds its legs
  wired if and only if each backend has the arm.

### K2 — The header is the expander's `text`, with an optional `symbol`; no header children

RECOMMEND the header be text, set by the existing `text` prop (prop 1) made
legal on the expander, with an optional leading glyph from the existing
`symbol` prop (prop 41) made legal on it. The text is also the header's
accessible name. No widgets in the header.

Arbitrary header content is reachable on three platforms (SwiftUI, GTK's
plain expander, WinUI) and not on libadwaita's row, whose header is a title
row, or on Compose, which has no header of its own (§0 fact 4). A checkbox or
a radio button in a header (Microsoft's toppings sample) makes one row with
two activations, and on iOS the whole label row is the tap target, so a
control inside it competes with the disclosure. Text and a glyph are what all
five draw as the platform's own header. An app that wants a control beside
the header puts it in the body's first line. The admission trigger for header
widgets, recorded as a DEFERRED entry, is an app whose collapsed state must
show a live control.

### K3 — A second line, `summary`, under the header text

RECOMMEND a new Str prop, `summary`, drawn as the header's secondary line:
libadwaita's `subtitle`, Compose's `ListItem` supporting text, a caption-style
second TextBlock in WinUI's header (the pattern Microsoft's own Expander guide
uses to summarize the body's choices while collapsed), and a secondary-styled
second Text in SwiftUI's label. Empty or unset draws no second line. Bindable
to a row field in the template zone.

It is offered because a collapsed expander otherwise hides what is inside it,
and the platforms that have the slot use it for exactly that ("Badge, keep
completed"). If the maintainer prefers the smaller surface, K3 comes out and
the header is K2's one line.

### K4 — `expanded` is the app's Bool; the user's toggle reaches the app as `toggled`

RECOMMEND a new Bool prop, `expanded`, default false (collapsed, every
platform's default). The app writes it as configuration and a write never
echoes. The user's activation of the header flips it and reaches the app as
`toggled` (record 3) with the new value, the checkbox's and the reveal
toggle's record, so every binding's existing toggle handler on the expander's
handle is the API (`on_toggle`, `on_toggle_node` for a stamped copy). An app
that keeps its own model writes `expanded` back, which is idempotent.

A new prop rather than `checked`: the reveal toggle's V1 chose the state's
own adjective (`revealed`) over borrowing another kind's word, and a reader
of a guest should see `expanded(true)`, not `checked(true)` on a container.

### K5 — The body stays alive in kaya while collapsed; it is out of reach to the user and the harness

RECOMMEND that collapsing hides the body and destroys nothing in kaya: every
widget id under it stays valid, app writes to it apply, and a text field's
text, a slider's value and a nested collection's rows are all there when the
body shows again. That holds on every platform because kaya's model, not the
platform's widgets, owns those values (§0 fact 3): Compose's
`AnimatedVisibility` drops the composables, and the interpreter recomposes
them from the model when the body returns. An app that wants the body built
only while shown already has `when`, and the plan says so in the docs rather
than adding a mode.

Two rules follow, both because the user cannot reach a hidden body:

- **Focus.** Collapsing while focus is inside the body moves focus to the
  header, on every platform. Where the platform does it (GTK's focus sites,
  WinUI's collapsed Visibility) kaya adds nothing; where it does not, the
  arm moves it. To measure on each arm; held by `expect_focused` in the
  scene.
- **The harness.** An action verb or an observation aimed at a node inside
  a collapsed expander refuses, naming the expander, in one sentence on all
  three harnesses. GTK and WinUI could still read a hidden body, SwiftUI and
  Compose cannot, and a scene that reads through a collapsed expander would
  pass on two lanes and fail on three. The scene expands first.

### K6 — Down only, no enable switch, no accordion

RECOMMEND no `ExpandDirection` (WinUI alone can expand upward), no header
switch that disables the body (libadwaita alone has it, and kaya has no
disabled state, docs/deferred.md's `enabled` entry), and no
one-open-at-a-time group. Microsoft's guide warns that auto-collapsing
"takes control away from the user", and an app that wants it writes
`expanded = false` on the others from its own `toggled` handler. Each is
recorded as a DEFERRED line in one entry with its admission trigger.

### K7 — The animation is the platform's own

RECOMMEND each backend use its control's own motion and kaya add none: the
SwiftUI disclosure's, libadwaita's revealer (slide), WinUI's 333 ms and
167 ms storyboards, and on Compose `AnimatedVisibility`'s defaults (fade with
expand and shrink). GtkExpander has no animation; K12 decides when it is
used. No duration prop. The harness's `expect_expanded` retries, so a scene
never waits on a fixed clock for the motion to finish.

### K8 — The AX verdict is `button`; the state is read by `expect_expanded`

RECOMMEND `expect_ax expander#0 "button/<text>"`: the header is a button on
every platform that publishes one (§0 fact 2), and DESIGN.md's rule
normalizes a role down to what all publish. No new word joins the closed set.
`disclosure` was considered and refused: it would earn its place only the way
`combobox` did, by every platform having the role, and here only AppKit's
triangle has one (to measure).

The state is a new observation, `expect_expanded expander#0 on|off`, which
reads TWO things off the platform and requires them to agree: the header's
published expanded state (the triangle's AXValue or AXExpanded on macOS,
VoiceOver's expanded state on iOS, AT-SPI's EXPANDED on GTK,
ExpandCollapseState through UIA on WinUI, the header node's state
description or expand/collapse action on Compose), and whether the body is
on screen (its first child present and visible in the platform's own tree).
A header that says expanded over a body that is not shown is a finding naming
both readings.

`a11y_label`, if the app sets one, goes on the header element only, never on
the container: on iOS a label on the DisclosureGroup replaces everything the
body would have spoken (CVS Health). `help` and `a11y_hint` ride the header
too.

### K9 — The keyboard is the platform's own; kaya adds no keys

RECOMMEND each backend keep its control's own keys: Tab reaches the header,
Space or Enter toggles it (WinUI's ToggleButton, GTK's `activate`, Compose's
clickable; to measure on each), and on macOS the triangle is reachable under
the system's Keyboard navigation setting only, like the radio group and the
segmented control (docs/segmented-plan.md G6). No arrow keys: the outline
view's Left-collapses and Right-expands belong to a tree, and kaya has no
tree. Inside libadwaita's boxed list, Up and Down move between rows as the
row already does.

The scene drives the keyboard with the verbs it has, `tab` to the header and
`press space`, then `expect_expanded`; the mac and iOS lanes cut at that
block for the segmented control's reasons (the mac setting cannot be turned
on per process, and iOS needs Full Keyboard Access).

### K10 — Both construction zones; a stamped expander's `expanded` is bound to a row field

RECOMMEND the expander in both zones, a stamped copy per row with its `text`,
`summary` and `expanded` bindable to row fields and its handler receiving its
row (DESIGN.md, A stamped handler receives its row).

Windowing makes one rule necessary: a stamped copy is torn down when its row
leaves the realized band and re-stamped from the row's data when it returns
(§1). A user's expand on an unbound copy would be forgotten the moment the
row scrolled away, and on a short list it would never be noticed. So the
root refuses, at `template_end`, a template expander whose `expanded` is not
bound to a Bool field, naming the fix ("bind expanded to a Bool field of the
row, and write the toggled value back"). The app writes the user's toggle
back into the row, exactly as a stamped checkbox's app does.

A row that expands changes height. The windowing contract already measures
realized rows and corrects the presumed heights (docs/virtualization-plan.md
§2); whether a height reported mid-animation makes the band jump is to
measure at the breadth on each backend, with a feed of expanders in the
scene.

### K11 — An expander is a row of a derived form

RECOMMEND widening the form derivation (docs/forms-plan.md §2): a column
whose children are all labelled rows or expanders, at least two of them, is
a form, and an expander inside one draws as the form's expandable row. Its
body, when it holds labelled rows, shares the form's label column.

This is the settings shape on three platforms (§0 fact 5): libadwaita's
`AdwPreferencesGroup` takes `AdwExpanderRow`s beside `AdwActionRow`s, SwiftUI's
`Form` draws a DisclosureGroup as a grouped row, and the Windows Settings
card's expandable form is the Expander. Without the widening, adding an
"Advanced" expander to a form would turn the whole form back into a plain
column on every platform. On iOS the widened form still carries the grouped
screen, unchanged.

### K12 — GTK draws `AdwExpanderRow` inside a form and `GtkExpander` elsewhere

RECOMMEND the forms plan's split, one platform over. Inside a form (K11) the
expander is an `AdwExpanderRow` in the form's preferences group: `title` the
text, `subtitle` the summary, the symbol as a prefix image, and each body
child added with `add_row` (a labelled row as its `AdwActionRow`, anything
else wrapped in a plain row). Elsewhere it is a `GtkExpander` whose child is
the body's box, the summary a dimmed second label in a `label-widget`, the
symbol beside the label. An `AdwExpanderRow` outside a boxed list draws a
card edge with nothing around it, and GtkExpander inside a preferences group
breaks the boxed-list rhythm, so each widget goes where its platform puts it.
GtkExpander has no animation (K7); that is GNOME's own look for a free
expander.

### K13 — Compose draws a Material list item with a turning chevron

RECOMMEND, since Material has no expander: the header is a `ListItem`
(`headlineContent` the text, `supportingContent` the summary,
`leadingContent` the symbol's Material icon, `trailingContent` the
`ExpandMore` icon turned 180 degrees when expanded, animated with the
expansion), the whole item clickable with `Role.Button`, an `onClickLabel`
of the platform's own "expand"/"collapse" words through the semantics
actions, and a `stateDescription` of expanded or collapsed. The body is an
`AnimatedVisibility` with its defaults below it. Inside a form (K11) the
header is a segment of the grouped container the form already draws
(docs/tables-plan.md, check-table-card) and the body's rows follow as
segments; elsewhere the header is a bare list item with no card.

This is the treatment Google's Compose samples and the Android Settings app
use (a row with a trailing chevron), drawn with Material's own components
and tokens, so it reads as Material without kaya inventing a component. The
`ExpandMore` icon is in material-icons-core, which the build already pins.

### K14 — WinUI draws the platform's `Expander`

RECOMMEND `Microsoft.UI.Xaml.Controls.Expander` everywhere, `ExpandDirection`
left at Down, the header a small Grid of the symbol's Segoe glyph, the text
and the summary in the caption style, the body a StackPanel in `Content`,
`HorizontalAlignment` and `HorizontalContentAlignment` Stretch so a stack of
expanders shares one width (Microsoft's own sizing advice). `Expander`,
`ExpanderAutomationPeer` and the two event-args types join
tools/winui-bindgen's filter and the bindings are regenerated. Inside a form
(K11) the expander spans the form Grid's three columns and its body's
labelled rows take the shared label column.

### K15 — The harness reads the platform's state and drives the platform's header

RECOMMEND `toggle expander#0 on|off`, the existing action verb with both
waits, pressing the header through the platform's own activation: AXPress on
the disclosure triangle on macOS, the header element's activation on iOS,
`activate` on the GtkExpander's title or the AdwExpanderRow's header row,
the header ToggleButton peer's Toggle or the Expander peer's
Expand/Collapse on WinUI (whichever the measurement shows a user's click
takes), the header node's click action on Compose. `expect expander#0
"<text>"` reads the header's text off the platform. `expect_expanded` is K8's.

The class this guards is "a backend that toggles the model and not the
screen": a DisclosureGroup bound to a constant, an app write that never
reaches `IsExpanded`, a header that emits `toggled` while the body stays
hidden, an `AnimatedVisibility` keyed on the wrong state. Three walls, the
segmented control's G10:

1. The scene writes `expanded` from the app and reads it back through the
   platform (`expect_expanded` reads the header's state AND the body's
   presence), and toggles from the header and reads the app's answer, so an
   arm that ignores either direction is red on its lane.
2. A new `expander_routes.py` beside tools/lib/segmented_routes.py, a
   check-verbs clause in its shape: each backend's read names the platform's
   own API and never `node.expanded` or the model; each press goes through
   the header's own door; each arm's `toggled` emit sits inside the
   platform's user-change door (`Expanding`/`Collapsed` on WinUI,
   `notify::expanded` on GTK, the binding's set on SwiftUI, the click on
   Compose) and outside the quiet guard; the K5 refusal is one sentence in
   all three harnesses, compared flattened; and a backend whose
   `depth_stub("expander")` goes owes a row. Watched negatives per clause,
   counts printed.
3. A watched leg negative per backend at the depth and the breadth: the
   arm's expanded binding cut (one substitution, tools/mac/scene-negative.py
   on the mac) and the leg seen red, restored from a saved copy with its
   sha256 compared.

### K16 — Nested expanders are legal, at any depth

RECOMMEND no limit. WinUI's guide nests four, Apple's sample nests one, GTK's
expander takes any child; libadwaita's expander row inside another's nested
list is to measure for its look at the breadth. A nested expander inside a
form's expander follows K11 one level down.

### K17 — No new styling capability

RECOMMEND that the expander take no tint, `filled` or colour of its own in
this slice: each platform's own header and chevron, in its own tokens. The
maintainer asked that kaya's styling move toward app-skinned looks where it
can and that each new styling capability be his ruling; a skinned expander
(a branded chevron, a filled header) is therefore a separate question for
him, recorded as a DEFERRED line, and nothing in this slice forecloses it.

### K18 — All nine bindings and the C floor, both zones

Per invariant 2, RECOMMEND every binding spell the expander as it spells
`labeled`, a container with its header first and its body after: Rust
`tx.expander("Advanced", |tx| ...)` with `.summary(..)`, `.symbol(..)`,
`.expanded(..)` and `.on_toggle(..)` chained, and `tpl.expander(...)`;
Python `with kaya.expander("Advanced", summary=..., expanded=...,
on_toggle=...):`; JS `kaya.expander("Advanced", { ... }, () => { ... })`; Go
`tx.ExpanderText("Advanced", func() {...})` with `ExpanderBound` in the
template zone and the handler chained on the handle; C#, Java and Swift
overloads taking a string, a signal or a field; OCaml `expander ?summary
?expanded ~on_toggle children ()`; Haskell `expander src attrs children` and
`expanderOf` in the template zone. The value-returning body rule (DESIGN.md,
A body receives its container and returns its value) applies, since the
expander is a live-zone container with a body. The C floor declares the kind
and its children explicitly, an `expander` C guest as the floor's
documentation. No language has a reason to defer or refuse.

### K19 — Its first home: the task manager's Settings screen

RECOMMEND an "Advanced" expander on the task manager's Settings screen
(guests/rust/tasks.rs, `OpenSettings`), holding the two switches that are
not everyday choices, "Hide badge" and "Keep completed tasks", with a
summary saying which are on, collapsed by default and its state kept in the
preferences store beside the others (docs/tasks-s4-plan.md P7). That screen
is ONE stamped row, so the demo exercises K10's bound field and write-back,
and with its two selects as labelled rows it exercises K11's widened form on
all five platforms. The media player's library sections, the other
candidate on the shortlist, do not exist yet: no guest in the tree has a
library to section.

## §3 — The lowering, per backend

| backend | the control | the user's toggle | the app's write | the reads and the press |
|---|---|---|---|---|
| SwiftUI, macOS | `DisclosureGroup(isExpanded:content:label:)`, the label an HStack of `Image(systemName:)` and a VStack of the text and the secondary-styled summary; inside a form (K11) the same view in the `Form`, which draws it as a row | the binding's set, through `kayaUserWrite`, emitting `toggled` | the binding's get | the triangle's AX element (role and value to measure), the body's first child present in the AX tree; `toggle` performs AXPress on the triangle |
| SwiftUI, iOS | the same view; in a form a grouped row of the grouped screen | as macOS | as macOS | the header element's expanded state as VoiceOver reads it (to measure where it lives: trait, value or a private key) and the body's elements; `toggle` activates the header |
| GTK 4 | in a form an `AdwExpanderRow` in the form's `AdwPreferencesGroup` (title, subtitle, prefix image, `add_row` per child); elsewhere a `GtkExpander` whose `label-widget` holds the symbol, the text and the dimmed summary | `notify::expanded` outside the quiet guard | `set_expanded` under the quiet guard | AT-SPI: the header's EXPANDED state and the body's first child mapped (`showing`); `toggle` emits the header's `activate` |
| WinUI 3 | `Expander`, Header a Grid (glyph, text, caption summary), Content a StackPanel, Stretch alignments; bindgen filter grows | `Expanding` and `Collapsed` outside the quiet guard (both fire on a programmatic write too) | `IsExpanded` under the quiet guard | UIA: the Expander peer's ExpandCollapseState and the body's first child not offscreen; `toggle` takes the measured door (the header ToggleButton's Toggle, or the peer's Expand/Collapse) |
| Compose | a `ListItem` header (K13) with a rotating `ExpandMore`, `Role.Button`, state description and expand/collapse semantics actions; the body in `AnimatedVisibility`; the expanded state a `mutableStateOf` (check-compose-state) | the header's click, emitting `toggled` | the model's expanded state | the merged header node's state and the body's first node present in the merged tree; `toggle` invokes the header's click action |

## §4 — The wire

- A new kind, `expander`, after `segmented` (26, the number is the build's).
  A container: its children are any kind a column takes.
- Props: `text` (1) and `symbol` (41) become legal on the expander; two new
  props, `summary` (Str) and `expanded` (Bool), legal on the expander alone,
  their numbers the build's (59 and 60 today). Spacing, inset, align, grow
  and fill as on a column. All of them in both zones.
- At `template_end`, the root refuses a template expander whose `expanded`
  is not bound to a Bool field (K10). An empty `text` is refused when the
  transaction ends, since a header with no text has no name.
- No new record: `toggled` (record 3) carries the expander's new `expanded`
  state; its spec doc names the third user.
- The spec hash moves, and the nine wire files, kaya.h and the two
  interpreters' hand-copied hashes move with it.
- The form derivation (K11) is a backend rule, read at AddChild and at
  TemplateEnd as today; nothing on the wire.
- Harness (not on the wire): `toggle` and `expect` accept the new target;
  `expect_expanded` (an observation); the K5 refusal for any verb aimed
  inside a collapsed expander.

## §5 — The scene and the sweep

A new scene, `expander.steps` in tools/scenes, one guest with a free-standing
expander, a form holding an expander, and a stamped list of expanders:

1. The free one: `expect_ax expander#0 "button/Details"`, `expect_expanded
   expander#0 off`; a step aimed at an entry inside it refuses (the K5
   sentence, as an expected failure the harness supports, or read through
   the app's label if not); `toggle expander#0 on`, the app's label
   `details: open`, `expect_expanded expander#0 on`; type into the entry,
   collapse, expand, and `expect` the text still there (K5).
2. Focus: focus the entry, the app collapses the expander, `expect_focused`
   names the header (K5).
3. The app's write: a Show button writes `expanded = true`, `expect_expanded`
   reads on, and the app's heard-count is unmoved, since a write never
   echoes.
4. The form: `expect_ax` of a labelled row inside the form's expander reads
   its label (K11), with the expander toggled open first.
5. The stamped list: each row's expander starts from its row's field; a
   toggle names its row; the app writes it back; on a list long enough to
   window, scroll the row away and back and `expect_expanded` still reads on
   (K10).
6. The keyboard block: `tab` to the header, `press space`,
   `expect_expanded`; the mac and iOS lanes cut at it (K9).

Gates that grow: check-verbs (expander_routes.py, K15; the kind constant in
both interpreters), check-sugar-surface (the kind in both zones in all nine,
`summary`, `expanded`, the toggle handler, fake-name and rename-in-a-copy
negatives), tpl-surfaces (`expander` in DEFAULT_KINDS), check-stubs
(`depth_stub("expander")` on GTK, WinUI and Compose until the breadth),
check-universal-props (the a11y props applied to the header on every
backend, and never to the SwiftUI container, K8), check-compose-state (the
expanded state is composition state), check-table-card (the form's grouped
container with an expander segment on Compose and iOS), check-winui-bindings
(the regenerated filter), check-steps, scene-features (`expect_expanded`
keys the feature), check-c-ids (the C guest). check-sugar-surface is red by
design between the depth and the breadth.

## §6 — Build order

1. The measurements §7 lists as the depth's, on the mac, before any arm: the
   triangle's AX role and value, whether SwiftUI keeps the body's views, the
   focus on collapse.
2. The depth: spec (the kind, the props, the template refusal), core and its
   unit tests (each refusal watched), the harness verbs and the K5 refusal,
   the SwiftUI arm on both Apple platforms (iOS compiled, not run) with its
   AX reads and press, K11's widened form in the SwiftUI arm, the Rust
   binding in both zones, the Rust guest, and expander.steps green on the
   mac. GTK, WinUI and Compose depth stubs; the BUILD and DEFERRED ledger
   entries (K2, K6, K17) with KEY lines.
3. The breadth: GTK, WinUI and Compose per §3, each replacing its stub and
   taking its expander_routes row; the iOS legs; the eight other bindings
   and the C floor, an `expander` guest each.
4. The task manager's Advanced expander (K19).
5. The matrix once, then the review page with every lane's capture of the
   free expander, the form with its expander open and closed, and the
   Settings screen.

## §7 — Measured, and to be measured

- MEASURED 2026-10-09 (Windows App SDK WinUI 2.2.1 under third_party):
  Microsoft.UI.Xaml.winmd carries `Expander`, `ExpandDirection`,
  `ExpanderAutomationPeer`, `ExpanderAutomationPeerFactory`,
  `ExpanderCollapsedEventArgs`, `ExpanderExpandingEventArgs`,
  `ExpanderFactory`, `ExpanderStatics` and `ExpanderTemplateSettings`. The
  native generic.xaml's Expander template makes the header a ToggleButton
  named `ExpanderHeader` with AutomationId `ExpanderToggleButton`, puts the
  body in a Border named `ExpanderContent` with `Visibility="Collapsed"`,
  animates with key times of 0.333 s and 0.167 s, and sets
  `ExpanderMinHeight` 48 and the chevron glyph U+E70D.
  crates/kaya/src/winui/bindings.rs names none of these types.
- MEASURED 2026-10-09 (the tree): the pinned Compose BOM is 2024.10.01
  (android/kaya/build.gradle.kts), so material3 1.3.1 and compose-ui 1.7,
  with no expander component; kaya's floors are macOS 13 and iOS 16, so
  `Section(isExpanded:)` (macOS 14, iOS 17) is out of reach and
  `DisclosureGroup` (macOS 11, iOS 14) is in.
- Read from source 2026-10-09: gtkexpander.c keeps the collapsed child by
  reference outside the box, sets role BUTTON and STATE_EXPANDED, and
  animates nothing; adw-expander-row.c sets STATE_EXPANDED on its header
  action row and adw-expander-row.ui binds a `slide-up` GtkRevealer to
  `expanded`.
- To measure at the depth (macOS 26.5, a SwiftUI probe built with
  `kaya_swiftc`): the DisclosureGroup triangle's AX role, subrole and value
  in both states; whether AXPress on it runs the binding's set; whether the
  body's views (and a TextField's editor) survive a collapse; where focus
  goes when the body holding it collapses; DisclosureGroup's look inside a
  `Form` with `.formStyle(.grouped)`.
- MEASURED 2026-10-09 (the iOS 26.5 simulator): SwiftUI's DisclosureGroup
  publishes NO expanded state on iOS. The one element over the header is
  SwiftUI's AccessibilityNode with the text as its label, the button trait
  only, `accessibilityExpandedStatus` unsupported, no value, hint or custom
  action, and the same with kaya's own label element removed; SwiftUI has no
  modifier that sets `UIAccessibility.ExpandedStatus`. But UIKit's own
  property (iOS 18) set on that node sticks, read back across later reads
  and toggles, while `accessibilityExpandedStatusBlock` is ignored once a
  value is set. So the iOS arm sets the status itself from the header's
  anchor, and VoiceOver speaks "expanded" or "collapsed" in the user's
  language (tasksrtl, Arabic, green). SwiftUI builds the node only once an
  assistive client is attached and builds a rebuilt row's node after the
  anchor reaches its window, so the arm sets it again for two seconds after
  every change and when VoiceOver, Switch Control or the harness's
  automation starts. Below iOS 18 UIKit has no expanded status, and the
  header publishes none. The summary is the header's value, as iOS Settings
  speaks a row's detail text, never the hint, which Apple reserves for what
  activating does; the app's hint keeps the hint.
- MEASURED 2026-10-09 (the API 35 emulator, Compose 1.7): Tab from nothing
  focused reaches the header and Space toggles it once; Enter toggles it once
  the header holds focus. The Tab then Enter that twice pressed Show was the
  platform's own initial focus: with the display out of touch mode (the
  previous adb key left it so, and the mode is global), the window's first
  focus went to the header at launch, 55 ms after the composition, on some
  launches and not others, so the Tab moved on to Show; the header's own
  focus log showed it focused before any key. The body leaves the semantics
  tree after AnimatedVisibility's exit, and comes back recomposed from kaya's
  model (the typed name is kept). With the body's entry focused, a collapse
  moved focus to the header (its focus log, 0.4 s later). TalkBack's node
  info for the header carries no content description of its own and two
  non-focusable text children, "Details" and "One field", so TalkBack reads
  the summary as part of the header; the click label was the summary
  ("double-tap to One field") and is now the framework's own word,
  `expand_button_content_description_collapsed` / `_expanded` ("Expand",
  "Collapse", in the app's locale), or the app's hint when it sets one; the
  state description stays Material's "Collapsed" / "Expanded". A column of
  only expanders draws as the form's grouped container. A column taller than
  its window gives its last children no height (Compose's Column hands each
  the space left): with the free and the form's expanders open, the stamped
  row's body measured 89x0 and its header 32 high, off the bottom of the
  screen, so the scene folds both before it reads the list, and the body read
  wants a height, not presence alone.
- MEASURED 2026-10-09 (GTK 4.24, libadwaita 1.9.2, the lane image, a
  PyGObject probe over the AT-SPI bus): the GtkExpander itself is a `push
  button` with expandable/expanded and one action, `activate`; its computed
  name is every label inside it, the body's too once open ("Details One
  field Inside"), and its description is empty, so the arm names it with its
  text and speaks the summary as its description. AdwExpanderRow's header is
  an inner AdwActionRow published as a `list item` named by the title, with
  expandable/expanded, NO bus action, and the subtitle NOT in its
  description, so the arm sets the description there too; collapsed, its body
  rows leave the bus. A column of only expanders draws as one boxed-list card
  of expander rows, each open body in libadwaita's shaded nested list.
- MEASURED 2026-10-09 (the WinUI 2.2.1 VM): the Expander's own peer is
  control type Button with the ExpandCollapse pattern, NOT keyboard
  focusable, its name the AutomationProperties name kaya sets; the template's
  `ExpanderHeader` ToggleButton (AutomationId `ExpanderToggleButton`) is the
  focusable element, in the content view with the Toggle pattern and an empty
  name over a header that is not a string, so the arm copies the name and the
  summary (as HelpText) onto it once the template exists. A column of only
  expanders draws as separate Expander cards, each at its natural width; the
  form's shared label track reaches the labelled rows in its expander's body.
  Narrator's speech itself was not heard (no audio route on the VM); the
  harness reads the HelpText off the header the template made.
- To measure at the breadth: where iOS publishes the expanded state;
  GtkExpander's and AdwExpanderRow's keys and the AT-SPI names on the bus;
  AdwExpanderRow nested in another's list; which door WinUI's header click
  takes and whether focus leaves a collapsing body; Compose's Enter and
  Space on the header and how TalkBack reads the state description with
  the expand/collapse actions on API 35; how each backend's windowing
  reacts to a row whose height animates (K10).
