# The segmented control: the design pass (2026-10-08)

Status: DESIGN PASS 2026-10-08, nothing built. Every ruling (G1-G13) is
RECOMMENDED and awaits the maintainer. The maintainer picked the control
next on 2026-10-08. Its roadmap card (docs/roadmap/features.toml,
`segmented`) gives the shape as "presentation on radio group", and this pass
is the evidence for how that shape is spelled. The search field's and the
reveal toggle's plans (docs/search-plan.md, docs/reveal-plan.md) are the
precedents for the layout of this one.

## §0 — What the platforms offer

The rows marked MEASURED were measured for this pass (§7). Everything else
comes from the vendors' documentation, cited at the end of the section, and
the depth or the breadth measures what is marked "to measure".

| | the control | selection | segment content | a11y identity | keyboard | disabled segment | width and overflow |
|---|---|---|---|---|---|---|---|
| macOS | SwiftUI `Picker` with `.pickerStyle(.segmented)` over AppKit's `NSSegmentedControl` (that SwiftUI builds one is to measure at depth) | single (`.selectOne`) or several (`.selectAny`); the HIG: "a single choice from among a set of options, or in macOS, either a single choice or multiple choices" | a label, an image, or both per segment; the HIG: "Prefer using either text or images — not a mix of both" | MEASURED: the control is AXUnknown around its cell; `.selectOne`'s cell is AXRadioGroup holding one AXRadioButton per segment, subrole AXSegment, AXValue 1 on the selected one; `.selectAny`'s cell is AXGroup holding AXCheckBox segments; an image segment's name is its image's accessibility description | a key view only under the system's Keyboard navigation setting, as every mac control but a text field is; arrows move between segments, Space selects (to measure) | `setEnabled(_:forSegment:)`; MEASURED: a disabled segment reads AXEnabled false | `segmentDistribution` (fit, fill, fillEqually, fillProportionally); no overflow |
| iOS | the same `Picker` style over `UISegmentedControl` | single only: one `selectedSegmentIndex`, or `noSegment` | a title or an image per segment (`setTitle`/`setImage`; whether both draw is to measure) | each segment a button with the selected trait; kaya's radio group already lowers to this control on iOS and reads `group/Size` (a11y.steps, every lane) | none from a hardware keyboard without Full Keyboard Access (the reveal plan's V10 measurement, one control over) | `setEnabled(_:forSegmentAt:)` | equal widths by default, `apportionsSegmentWidthsByContent` otherwise; HIG: "no more than about five segments on iPhone" |
| GTK 4 | no segmented widget in GTK; libadwaita's `AdwToggleGroup` (since 1.7) of `AdwToggle`s, or the older idiom of grouped `GtkToggleButton`s in a box with the `linked` style class | single: "a group of exclusive toggles" | "an icon, a label, an icon and a label, or a custom child" | the group is `GTK_ACCESSIBLE_ROLE_RADIO_GROUP`, each toggle `GTK_ACCESSIBLE_ROLE_RADIO`; `AdwToggle:description` (1.9) is the accessible description | not documented; to measure | `AdwToggle:enabled` | `homogeneous` gives every toggle the same width; `can-shrink` lets them ellipsize below their natural size; orientable |
| WinUI 3 | no segmented control in the Windows App SDK. MEASURED in the pinned WinUI 2.2.1: the metadata has `SelectorBar`, `SelectorBarItem` and `SelectorBarItemAutomationPeer` and nothing named Segmented. The Community Toolkit's `Segmented` (a ListViewBase, Single or Multiple) is a MANAGED .NET assembly, out of reach of kaya's native Rust backend. Microsoft's other answer is `RadioButtons` | SelectorBar: single, "One item at a time can be selected"; the selection can be null | `Text` and `Icon` per item, "we recommend that you set the `Text` property" | the items are ItemContainers with a SelectionItem peer (to measure); kaya's radio group reads `group` | MEASURED from generic.xaml: the bar is `IsTabStop=False`, `TabNavigation=Once`, so Tab enters it once; the docs: left and right move the selection, and Tab focus selects an item | `IsEnabled` on the item (an ItemContainer is a Control) | items take their natural width, and the bar "does not rearrange items to adapt to different window sizes" |
| Android, Compose | Material 3 `SingleChoiceSegmentedButtonRow` of `SegmentedButton`s, and `MultiChoiceSegmentedButtonRow`. MEASURED: neither carries the experimental opt-in in the pinned material3 1.3.1 | single or several ("Lets users choose between two and five items") | an `icon` slot (by default a check mark on the selected segment) and a `label` slot, either of which takes an icon | MEASURED from the 1.3.1 bytecode: the single-choice segment is a selectable Surface with `Role.RadioButton`, the row a `selectableGroup()` | each segment is its own focus stop; Enter or Space selects (to measure) | `enabled` on each SegmentedButton | the row shares its width equally between segments; no overflow |

Five facts decide the design:

1. **Single selection is the only selection all five offer.** iOS,
   AdwToggleGroup and SelectorBar are single-choice controls. Several
   selections are first-party only in AppKit and Material.
2. **Every platform presents a single-choice segmented control as a radio
   group to its assistive reader.** macOS says radio group and radio button
   (MEASURED), GTK radio group and radio, Compose radio button inside a
   selectable group (MEASURED). That is the choice contract kaya's `select`
   and `radio` already carry (`is_choice` in scene.rs: "SAME semantics,
   different chrome").
3. **The platforms agree on text OR an image in a segment, and the Apple
   HIG asks for one or the other across a whole control.** iOS has no
   documented way to draw both in one segment.
4. **No platform scrolls, wraps or folds a segmented control.** The
   guidance is two to five segments everywhere (Apple, Material, the
   Toolkit's docs).
5. **WinUI has no segmented look in its own package.** SelectorBar is the
   platform's one-of-N bar, framed by Microsoft for switching views of
   data; it draws text with a selection pill, not an outlined strip.

Sources: Apple HIG, Segmented controls
(developer.apple.com/design/human-interface-guidelines/segmented-controls);
UIKit, UISegmentedControl (developer.apple.com/documentation/uikit/uisegmentedcontrol);
libadwaita, AdwToggleGroup and AdwToggle
(gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.ToggleGroup.html,
class.Toggle.html); Microsoft Learn, SelectorBar
(learn.microsoft.com/windows/apps/design/controls/selector-bar); Community
Toolkit, Segmented (learn.microsoft.com/dotnet/communitytoolkit/windows/segmented/,
nuget.org/packages/CommunityToolkit.WinUI.Controls.Segmented); Android
Developers, Segmented button
(developer.android.com/develop/ui/compose/components/segmented-button).

## §1 — What kaya has

- **The choice contract, in two kinds.** `select` (kind 11, a dropdown)
  and `radio` (kind 12, the inline group) share it: the options are the
  kind's LABEL children in order, the `value` prop is the selected 0-based
  index (the root refuses one past the options added so far, so "add
  options, then select" is the transaction's shape), the user's pick
  reaches the app as `value_changed` (record 4) with the index, and the
  app's write never echoes. Both kinds exist in both construction zones;
  a stamped copy binds its index to a row field and every copy shares the
  options (crates/kaya/src/app.rs `Tpl::choice`).
- **Its harness.** `choose <target> <index>` (an action verb, both waits)
  and `expect <target> "<option>"` reading the selected option's text.
  tools/scenes/select.steps and radio.steps are the two scenes; a11y.steps
  reads `combobox/Color` and `group/Size`.
- **The radio arms.** SwiftUI: `.radioGroup` on macOS and `.segmented` on
  iOS ("iOS has no radio idiom, and its native spelling of one-of-N inline
  is the segmented control"). GTK: grouped CheckButtons in a Box. WinUI:
  `RadioButtons`. Compose: a selectable group of RadioButton rows.
- **A defect this pass found.** Both interpreters answer `expect radio` and
  `expect select` from the MODEL (`node.value`, KayaSwiftUI.swift's and
  KayaCompose.kt's expect arms), and their `choose` writes the model and
  emits by hand. GTK's and WinUI's read the real control. So on the mac,
  iOS and Android a Picker that drew the wrong segment selected, or ignored
  the app's write, passes both scenes (G10).
- **Symbols.** `symbol` (prop 41) is the closed glyph vocabulary, legal on
  a button alone; a symbol button draws the glyph and its title stays its
  accessible name (docs/composer-plan.md §2). Sections read theirs back
  with `expect_section_symbol`.
- **No disabled state.** No kind has an `enabled` prop; only menu items do.
- **Sections** (DESIGN.md, Sections) are a window's peer surfaces with a
  `bar` presentation. They are navigation between retained roots, not a
  value in the content.

## §2 — The rulings (RECOMMENDED 2026-10-08, awaiting the maintainer)

### G1 — A third choice kind, `segmented` (RECOMMEND: kind)

The segmented control is the choice contract in a third presentation, and
kaya already spells a choice's presentation as its KIND: `select` is the
dropdown, `radio` the inline group, both admitted by `is_choice`. A third
member, `segmented`, joins them with no new semantics: same option
children, same `value`, same `value_changed`, same `choose` and `expect`.

The alternative is a presentation prop on `radio` (`list` or `segmented`,
the way a window's sections take `bar` or `sidebar`). It is refused for
three reasons:

- It would make the family inconsistent: `select` and `radio` would be two
  kinds while the third presentation hid inside one of them.
- A kind has walls a prop lacks: `segmented#0` resolves or it does not,
  the kind joins every census in all nine bindings and both zones
  (check-sugar-surface, tpl-surfaces), and check-stubs holds its legs wired
  if and only if each backend has the arm. A prop no kind census reads is
  the search plan's S2 argument against a role, one surface over.
- Symbol segments (G3) are new surface the radio group does not have.

A segmented control is not sections: it chooses a value inside the
content and mounts nothing. An app that switches whole screens uses
sections (the HIG: "For switching between completely separate sections of
an app, use a tab bar instead").

### G2 — Single selection only (RECOMMEND: single; several selections ledgered)

Exactly one segment is selected, the choice contract's rule. Several
selections are reachable on two platforms of five (§0 fact 1): AdwToggleGroup
and SelectorBar cannot hold two, and iOS cannot. The use the HIG names for
several (Keynote's bold, italic, underline) is a set of independent Bools,
which kaya spells today as checkboxes and, in a toolbar, as toggle items.
A DEFERRED entry records several selections with its admission trigger:
an app that needs a format bar outside the command catalog.

### G3 — A segment shows its text, or a symbol named by its text; one control is all one or all the other (RECOMMEND)

Each option keeps its text. An option may also carry `symbol` (the
existing vocabulary, made legal on a segmented control's option labels
alone): it then draws the platform's glyph INSTEAD of the text, and the
text stays its accessible name, which is the symbol button's rule
(docs/composer-plan.md §2). The root refuses a control that mixes text
segments and symbol segments, at the end of the transaction that added
them: the HIG asks for it, iOS cannot draw both in one segment, and a
rule all five can keep is better than a per-platform look. Text and a
glyph together in one segment is not offered, for the same iOS reason.

A symbol segment also shows its name as a tooltip where the platform shows
tooltips (macOS's `setToolTip(_:forSegment:)`, AdwToggle's `tooltip`,
SelectorBarItem's ToolTip; the phones none), because an icon-only control
has no other visible name and the HIG asks for one per segment. This is
new against the symbol button, which shows none; if the maintainer prefers
the button's rule, the tooltip comes out and the app sets `help` on the
control.

### G4 — The value is the index; the app hears `value_changed` (RECOMMEND: the choice contract unchanged)

The selected segment is `value`, a 0-based index, written as configuration
and never echoed; the user's pick reaches the app as `value_changed`
(record 4) and every binding's existing `on_select` is the handler. No key
or name is introduced: the select and the radio group answer with an index,
and a third member that answered otherwise would split the contract.

Two rules are added at the root, both because every platform's guidance
assumes them: a segmented control holds at least two segments (refused at
the end of the transaction), and there is always a selected segment (the
contract already has no "none"; SelectorBar's null and iOS's `noSegment`
are never used).

### G5 — The a11y verdict is `group`, the radio group's (RECOMMEND)

`expect_ax segmented#0 "group/<label>"`. Each platform's identity is its
radio group: macOS AXRadioGroup (MEASURED), iOS the segmented control
already read as `group` for radio, GTK RADIO_GROUP, WinUI the bar's list
peer (to measure; UIA List already normalizes to `group`), Compose the
selectable group. No new word joins the closed set: a radio group and a
segmented control are the same thing to an assistive reader on every
platform (§0 fact 2), and DESIGN.md's rule normalizes a role down to what
all publish.

The segments themselves are read by a new observation, `expect_segments
segmented#0 "Day|[Week]|Month"`: each segment's accessible name in order,
the selected one bracketed, read off the platform's own children (the
AXRadioButtons and their AXValue on macOS, the toggles on GTK, the items'
peers on WinUI, the merged semantics nodes on Compose, the segment elements
on iOS). A symbol segment's glyph is read by `expect_segment_symbol
segmented#0 1 "grid"`, the sections' symbol read one control over.

### G6 — The keyboard is the platform's own; the harness drives it through the system (RECOMMEND)

Each backend uses its control's own keys: Tab once then the arrows on
WinUI (MEASURED from the template) and, under Keyboard navigation, on
macOS; Tab per segment on Compose; GTK's to measure. kaya adds no key
handling of its own. A new action verb, `choose_by_keys <target> <index>`,
moves focus into the control and picks the segment with that platform's
own key sequence, sent through the system's input (the reveal plan's V10
lesson on Android), and returns once the app answered; the scene asserts
the same result on every lane that runs it.

Two lanes cut the keyboard block. On iOS a hardware keyboard reaches no
segmented control without Full Keyboard Access, as the reveal toggle
found. On macOS the control is a key view only under the system's Keyboard
navigation setting, which the lane cannot turn on per process (MEASURED in
V10). RECOMMEND following the mac setting, as kaya's radio group and every
button already do: V10 made the reveal eye always reachable because it sits
on the text field's own Tab path, while a segmented control is a standalone
control. The other choice is an AppKit subclass that is always a key view,
as V10's eye is; that would make the one mac control reachable when its
neighbours are not.

### G7 — No disabled segments in this slice (RECOMMEND: out, ledgered with a disabled state for every control)

All five platforms can disable a single segment, but kaya has no disabled
state on any widget (§1): no button, checkbox or radio option can be greyed
out today. A disabled segment alone would be the first and only one. The
DEFERRED entry for a cross-kind `enabled` prop records segments (and radio
options) as one of its parts.

### G8 — Equal widths, the control hugging its content, no overflow (RECOMMEND)

Every segment is as wide as the widest, the platforms' default (iOS, macOS
`fillEqually`, AdwToggleGroup `homogeneous`, Compose's row); WinUI's items
are given that width by the arm, since SelectorBar sizes items naturally.
The control hugs that width; `fill` stretches it with equal shares, as for
any other control. It never scrolls, wraps or folds (§0 fact 4). A text too
long for its share is the platform's to truncate. The two-to-five guidance
is the docs', not a refusal.

### G9 — Both construction zones (RECOMMEND)

A segmented control in a stamped row works as the select and the radio
group do there: the options are the prototype's children and shared by
every copy, the index is bound to a row field, and the stamped handler
receives its row (DESIGN.md, A stamped handler receives its row).

### G10 — The harness reads the platform's selection and drives the platform's segment (RECOMMEND, with the radio and select reads fixed in the same slice)

`expect segmented#0 "<name>"` reads the selected segment's name off the
platform's own control, never `node.value`; `choose` presses the segment
through the platform's own activation (the segment's accessibility press
on macOS and iOS, the toggle's activation on GTK, the item peer's
SelectionItem.Select on WinUI, the segment's semantics click on Compose).

The class this guards is "a backend that draws the control and ignores the
selection": a Picker bound to a constant, an app write that never reaches
the control, a pick that emits with the wrong index. Three walls:

1. The scene writes the value from the app and reads it back through the
   platform (`expect`, `expect_segments`), so an arm that ignores the
   write is red on its lane.
2. A new `segmented_routes.py` beside tools/lib/reveal_routes.py, a
   check-verbs clause in its shape: each backend's read and press name the platform's own API, the
   read never names the model, each arm's emit sits inside the platform's
   user-change door and outside the quiet guard, and a backend whose
   `depth_stub("segmented")` goes owes a row. Watched negatives per
   clause, counts printed.
3. A watched leg negative per backend at the depth and the breadth: the
   arm's selection binding cut (1 substitution, tools/mac/scene-negative.py
   on the mac) and the leg seen red, restored from a saved copy with its
   sha256 compared.

The interpreters' `radio` and `select` reads carry the same defect today
(§1). RECOMMEND fixing them in this slice: the mac radio group is the same
AXRadioGroup reader, the Compose radio group the same selectable group,
and the select needs only its popup's value; a DEFECT entry is filed at the
depth so the fix is recorded before it is built.

### G11 — iOS's radio group stays a segmented control (RECOMMEND: unchanged)

With G1, an iOS radio group and an iOS segmented control draw the same
control. iOS has no radio button, and its other one-of-N idiom, a list of
rows with a check mark (`.pickerStyle(.inline)`), belongs inside a grouped
list or form, which a kaya radio group is not required to sit in. The
radio group's iOS look does not change.

### G12 — All nine bindings and the C floor, both zones (RECOMMEND: do in every language)

Per invariant 2: Rust, Python, Go, C#, Java, Swift, OCaml, Haskell and JS
each get the constructor in both zones, spelled as that binding spells
`radio` today, plus the option's symbol in the binding's own idiom; the C
floor declares the kind and its label children explicitly, a `segmented`
C guest as the floor's documentation. No language has a reason to defer or
refuse.

### G13 — Its first demo app home: the portfolio chart's period (RECOMMEND)

The portfolio draws a 90-day value chart (guests/python/portfolio.py,
`CHART_DAYS`). A segmented control above it choosing "1M", "3M" and "1Y"
is the idiom Apple's Stocks and Google Finance use, and it is a value in
the content, not navigation (G1). The account filter stays a `select`: four
options with long names are a dropdown's job.

## §3 — The lowering, per backend

| backend | the control | the user's pick | the app's write | the reads |
|---|---|---|---|---|
| SwiftUI, macOS | `Picker` `.segmented` with `.labelsHidden()`; a symbol segment `Image(systemName:)` labelled with the option's text; the tooltip per segment (if SwiftUI's Picker offers no per-segment tooltip, an `NSViewRepresentable` over NSSegmentedControl, to measure at depth) | the selection binding's set, through `kayaUserWrite`, emitting `value_changed` | the binding's get | AX: the cell's AXRadioGroup, its AXRadioButton children's AXValue and name; `choose` performs AXPress on the segment |
| SwiftUI, iOS | the same Picker over UISegmentedControl | as macOS | as macOS | the segment elements' selected trait and label; `choose` activates the segment |
| GTK 4 | `AdwToggleGroup`, `homogeneous` on, one `AdwToggle` per option (`label`, or `icon-name` from the Adwaita symbol table with `tooltip` the name); the adw crate's feature moves v1_5 to v1_7 (the image ships 1.9.2, MEASURED) | `notify::active` outside the quiet guard | `set_active` under the quiet guard | the toggle group's `active` and each toggle's label; `choose` activates the toggle's own button |
| WinUI 3 | `SelectorBar` with one `SelectorBarItem` per option (`Text`, or `Icon` from the Segoe table with ToolTip the name), each item's MinWidth the widest; SelectorBar and its item and args types added to tools/winui-bindgen's filter and the bindings regenerated | `SelectionChanged` outside the quiet guard (it also fires on a programmatic write) | `SelectedItem` under the quiet guard | the selected item's peer and each item's name through UIA; `choose` takes the item peer's SelectionItem.Select |
| Compose | `SingleChoiceSegmentedButtonRow`, a `SegmentedButton` per option; a symbol segment's label slot the Material icon with the name as content description; whether the default check mark replaces the icon is decided at the breadth review | the segment's `onClick`, emitting `value_changed` | the row's selected index | the merged semantics nodes' `selected` and names; `choose` invokes the segment's click action |

## §4 — The wire

- A new kind, `segmented`, in `kind` after `secure_field` (the number is
  the build's). `is_choice` admits it, so `value`, the index check, the
  label-only children and both zones follow with no new code there.
- `symbol` becomes legal on a label whose parent is a segmented control
  (checked where the child is added, since the parent is known there),
  and the root refuses a segmented control with fewer than two segments
  or a mix of symbol and text segments at the end of the transaction.
- No new record: `value_changed` (record 4) carries the index; its spec doc
  names the third presentation.
- The spec hash moves, and the nine wire files, kaya.h and the two
  interpreters' hand-copied hashes move with it.
- Harness (not on the wire): `choose` and `expect` accept the new target;
  `expect_segments`, `expect_segment_symbol` (observations) and
  `choose_by_keys` (an action verb, both waits).

## §5 — The scene and the sweep

A new scene, `segmented.steps` in tools/scenes, one guest with two
controls and a stamped list:

1. The text control: `expect segmented#0 "Day"`, `expect_ax segmented#0
   "group/Period"`, `expect_segments segmented#0 "[Day]|Week|Month"`;
   `choose segmented#0 2` and the app's label `period: Month`; the app's
   own Reset button writes index 0, `expect` and `expect_segments` read
   Day back and the app's heard-count is unmoved, since a write never
   echoes.
2. The symbol control: `expect_segment_symbol segmented#1 0 "list"` and
   `1 "grid"`, `expect_segments segmented#1 "[List]|Grid"`, a `choose`.
3. A stamped row's control starting from its row's field, its pick naming
   its row.
4. The keyboard block, `choose_by_keys segmented#0 1` then `expect`; the
   mac and iOS lanes cut at it (G6).

Gates that grow: check-verbs (segmented_routes.py, G10; the kind constant
in both interpreters), check-sugar-surface (the kind in both zones in all
nine, the option symbol, fake-name and rename-in-a-copy negatives),
tpl-surfaces (`segmented` in DEFAULT_KINDS), check-stubs
(`depth_stub("segmented")` on GTK, WinUI and Compose until the breadth),
check-universal-props (the a11y props applied to the new kind on every
backend), check-steps, scene-features (`expect_segments` keys the feature),
check-symbol-parity (the symbol tables already shared, nothing new unless
the demo adds a glyph), check-winui-bindings (the regenerated filter),
check-targets and check-gtk (the adw feature bump), check-c-ids (the C
guest). check-sugar-surface is red by design between the depth and the
breadth.

## §6 — Build order

1. The depth: spec (the kind, the symbol's new legality, the two root
   refusals), core and its unit tests (each refusal watched), the harness
   verbs, the SwiftUI arm on both Apple platforms (iOS compiled, not run)
   with the AX reads and presses, the mac radio and select reads moved off
   the model (G10), the Rust binding in both zones, the Rust guest, and
   segmented.steps green on the mac. GTK, WinUI and Compose depth stubs;
   the DEFECT, BUILD and DEFERRED ledger entries (G2, G7, G10) with KEY
   lines.
2. The breadth: GTK, WinUI and Compose per §3, each replacing its stub and
   taking its segmented_routes row; Compose's radio and select reads off
   the model; the iOS legs; the eight other bindings and the C floor, a
   `segmented` guest each.
3. The portfolio's period control (G13).
4. The matrix once, then the review page with every lane's capture of both
   controls and the portfolio.

## §7 — Measured, and to be measured

- MEASURED 2026-10-08 (macOS 26.5, an AppKit probe compiled with
  `kaya_swiftc`): NSSegmentedControl's own element is AXUnknown; its cell
  is AXRadioGroup with `.selectOne` and AXGroup with `.selectAny`; segments
  are AXRadioButton or AXCheckBox, subrole AXSegment, AXValue 1 when
  selected, AXEnabled false when disabled; an image segment is named by its
  image's accessibility description.
- MEASURED 2026-10-08 (kaya-linux:latest, the forky image): libadwaita
  1.9.2 and GTK 4.24.0, with adw-toggle-group.h installed. The adw crate's
  pin comment (crates/kaya/Cargo.toml) still cites the trixie image's 1.7.6
  and is corrected with the feature bump.
- MEASURED 2026-10-08 (material3 1.3.1 from the BOM, bytecode):
  SegmentedButton and both rows carry no ExperimentalMaterial3Api marker;
  the single-choice segment sets `Role.RadioButton` and the row
  `selectableGroup()`.
- MEASURED 2026-10-08 (Windows App SDK WinUI 2.2.1 under third_party):
  SelectorBar, SelectorBarItem and SelectorBarItemAutomationPeer are in
  Microsoft.UI.Xaml.winmd, no Segmented type exists, and the template sets
  `IsTabStop=False` and `TabNavigation=Once`; crates/kaya/src/winui/bindings.rs
  names none of them yet.
- MEASURED 2026-10-08 (the tree): the SwiftUI and Compose `expect` and
  `choose` arms for `radio` and `select` read and write `node.value` (G10).
- To measure at the depth: that SwiftUI's segmented Picker is an
  NSSegmentedControl on macOS, per-segment tooltips through it, a symbol
  segment's AX name, and the iOS segment elements' traits.
- To measure at the breadth: AdwToggleGroup's keyboard and AT-SPI role
  names, SelectorBar's UIA tree and whether its selection follows Tab
  focus as the docs say, Compose's key handling between segments, and
  whether UISegmentedControl draws a title and an image together.
