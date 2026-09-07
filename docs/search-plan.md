# The search field: the design pass (2026-09-06)

Status: RULED 2026-09-06 (the maintainer: "im fine with this", with one
amendment on S4: the Return key is ledgered for a milestone that needs a
submit event, a chat app being the named example). Stage S1 of the task manager (docs/tasks-plan.md §6:
"a search entry filtering the open list"), and rank 1 of the table stakes
the 2026-09-05 surveys put first (docs/deferred.md, "Next milestones";
docs/probes/roadmap-app-needs-2026-09-05.md: must-have in 11 of 15
archetypes, present in all four vendor catalogues). The plan's own words
name the spelling "a role on entry" and leave it UNRULED (tasks-plan R3);
this pass is the evidence for the ruling. The pickers, sliders and
tooltips passes are the precedents for the shape. Two surveys stand
behind it, both dated 2026-09-06: the platforms' own documentation (§0)
and kaya's entry, role and harness plumbing read file by file (§1).

## §0 — What the platforms do

Read from the vendors' documentation; nothing here was measured yet.
The measurements the design needs before it is frozen are listed in §7.

| | the control | where its HIG puts a LIST filter | filters | clear affordance | Return | reports to a11y as |
|---|---|---|---|---|---|---|
| macOS | AppKit `NSSearchField` (magnifier, text, cancel button, a recents menu). SwiftUI has no search field view and no search text-field style; `.searchable` is a MODIFIER that asks the enclosing NavigationStack or NavigationSplitView to grow a field in the toolbar, wherever the platform decides | "Put a search field at the trailing side of the toolbar" for app-wide search; "include search at the top of the sidebar when filtering content there" | every keystroke (`sendsWholeSearchString` defaults false) | built in | sends the action | `AXTextField` with subrole `AXSearchField`; SwiftUI `.isSearchField` trait |
| iOS | `.searchable` in the navigation bar, or `UISearchTextField` (a `UITextField` subclass) inline | "Place search as an inline field when its position alongside the content it searches strengthens that relationship … when you need to filter or search within a single view"; "position an inline search field above the list it searches" | every keystroke | built in | the keyboard shows the Search key | `searchField` trait |
| Android, Material 3 | `SearchBar` / `DockedSearchBar`: a floating field that EXPANDS to a results view, full screen by design ("tries to occupy the entirety of its allowed size"); both are `@ExperimentalMaterial3Api` at the pinned material3 1.3.1 and already deprecated on androidx main. A list filter in place is a `TextField` with a leading Search icon and a trailing clear button | the M3 search bar is an app-navigation construct; nothing in Material puts a search bar in the top app bar | every keystroke | NOT built in; the app draws the trailing icon | the IME action is forced to Search | no search role in Compose semantics; Material sets the content description "Search" |
| GTK 4 | `GtkSearchEntry` (an ordinary widget: find icon when empty, clear icon when not, click empties it); `GtkSearchBar` is the revealer that slides down under the header bar | the sliding search bar, but "if search is particularly important to your app, the search entry can be located elsewhere and made to be permanently visible"; "search should be live wherever possible" | `search-changed`, DEBOUNCED 150 ms by default (`search-delay`, GTK 4.8+) | built in | `activate` | `GTK_ACCESSIBLE_ROLE_SEARCH_BOX` (the bar is the `SEARCH` landmark, a different thing) |
| WinUI 3 | `AutoSuggestBox` with `QueryIcon="Find"` ("you should also use an AutoSuggestBox control to implement a search box"); no SearchBox control, no search style for TextBox | the NavigationView pane slot is for app-wide search; a box above the list it filters is the idiom for one list | `TextChanged` every edit, with a `Reason` (UserInput / ProgrammaticChange / SuggestionChosen) the arm must read | "a clear all button appears" | `QuerySubmitted` | UIA has NO search control type; only a Search landmark on a container |

Three facts decide the design and are worth stating before the rulings:

1. **Every HIG puts a list filter above the list it filters.** Apple's
   inline field, GNOME's "permanently visible" carve-out, Windows' box
   above the content, Material's docked field. Toolbar and navigation-bar
   search is for search across the app, and docs/chrome-plan.md already
   refused free-form toolbar widgets naming search fields first.
2. **Two of the four backends have no leaf widget for it.** GTK's and
   WinUI's search controls are ordinary widgets. SwiftUI's is a modifier
   that hoists the field into the chrome, and Material's is a container
   that expands to a results screen. A field the app places in its column
   is therefore a styled `TextField` on both Apple platforms and on
   Compose: the platform's own text field wearing the platform's own
   search glyph, clear button, trait and keyboard. That is what the
   inline filter fields in Apple's and Google's own apps are.
3. **GTK is the one platform with a timer.** Its `search-changed` fires
   150 ms after the last keystroke; every other platform reports each
   edit as it happens. A shared scene that types and then reads the list
   would race on Linux alone unless the rule is stated (S6).

The repo's own probe already drew the line that matters here
(docs/probes/find-frameworks.md): Compose's Search symbols, WinUI's
AutoSuggestBox and GTK's search bar are APP SEARCH, not document find,
and "any survey done by keyword will read these as find bars and conclude
the opposite of the truth". S1 is app search, a field that filters the
app's own list, which is exactly what those controls are for. The
editor's find bar is document find, stays an ordinary entry in a row, and
its ratified boundary (docs/editor-plan.md) is untouched by this pass.

## §1 — What kaya has, and what a search field needs

Read directly from the tree at 75e86103 (file:line in the survey at
docs/measurements/search-survey-2026-09-06.md; the platform table in §0
is docs/measurements/search-platforms-2026-09-06.md).

**The entry.** `entry` (kind 4) emits exactly one occurrence,
`text_changed`, on user edits and on the `clear` command, never on a
property write. There is no submit or activate occurrence anywhere in
the spec: Return in a kaya entry emits nothing. There is no placeholder
or prompt prop on any kind: a kaya app cannot author grey "Search" text
in an empty field today. `clear` and `focus` are commands the APP issues;
no platform-drawn clear affordance reaches the user. The a11y read
(`expect_ax`) normalizes every platform's text control to `field`.

**Roles.** The styling roles (destructive, prominent, heading, caption,
plain) are one integer on the wire with no payload, no per-role prop and
no per-role occurrence, legal on Button and Label only. DESIGN.md
defines the tier as SEMANTIC EMPHASIS: how loud a control is, or where a
label sits in a text hierarchy. No role changes what control a backend
instantiates, what it emits or what keys it handles. A role is invisible
to every harness observable except `heading`: a `plain` button and a
default button read identically in `expect_ax`, and the mac read takes
the role attribute alone, never the subrole. A correction to the plan's
premise: the role vocabulary IS in the spec hash (spec.rs eats every
enum's variants), so a role and a kind cost the same on that axis.

**Cost, measured.** The `plain` role (6f997756): +172/-37 to +248/-36
over 31 to 38 files, a third of it one-time gate construction. The
`labeled` kind (847de659): about +1,550 over about 50 files net of its
bundled work, 79% of it per-binding sugar in both construction zones and
per-backend arms. `textarea`, the tree's own "entry plus a flag", cost
+1,393 over 75 files in a smaller tree and shares no backend lines with
the entry. But cost tracks NEW SURFACES, not the kind-or-role axis: the
slider's two props on an existing kind cost 87 file touches and +3,735.
A search field brings the surfaces §2 names whichever carrier it rides.

**The filter.** kaya has no filtered view over a collection: the
primitives are insert, update, update_field, remove and move; `when`
binds one app-wide Bool and rebuilds rather than hides; there is no
`visible` prop. Sorting is the app's ("the platform never sorts the
model", sort_requested's own doc). The only reconciler in the tree is
the portfolio's hand-written diff of a keyed collection. No guest filters
a collection from a text field yet; S1 would be the first.

**The harness.** `set_text` and `type` drive an entry and both wait for
the app's answer; `expect entry@x` reads its text; `expect_window` and
`expect_order` read a list's rows. No verb can send Escape (`type`
refuses non-printables and the root refuses `escape` as a shortcut), no
verb reads a placeholder, and no scene can assert that a button is gone.

## §2 — The rulings (RULED 2026-09-06, as recommended; S4 amended as noted)

### S1 — The field sits in the content, where the app puts it (RECOMMEND: content)

A kaya search field is a widget the app declares in its tree, at the top
of the list it filters on every platform. The alternative, a
screen-level "this surface is searchable" declaration that each platform
places (SwiftUI's `.searchable`, Material's expanding bar), is the only
shape under which two backends could use their platform's chrome-owned
construct, and it is refused: every HIG surveyed puts a LIST filter above
the list (§0 fact 1), a field the app cannot place is unspellable in a
form or in the portfolio's filter row, and docs/chrome-plan.md refused
chrome-placed widgets on the record. The lowering per platform is §3.

### S2 — A KIND, `search` (RECOMMEND: kind, wire 19), not a role on entry

The role tier is semantic emphasis with no payload (§1). A search field
changes what the control IS: its glyph, its clear affordance, its
keyboard, its accessibility identity, and the prompt it shows when
empty. Two of those are new surfaces a role cannot carry (a prop is
scoped by kind, so a placeholder on the entry kind would be legal on
every entry whether or not it wore the role; an occurrence is keyed on
kind, never role). And a role has no wall a lane can fail: nothing in
five harnesses can see it, which is invariant 3's own test. A kind is
addressable (`search@find` resolves or it does not), joins every kind
census in all nine bindings and both zones, and check-stubs holds its
legs wired if and only if each backend has the arm.

The kind takes the entry's text contract whole: the `text` prop
(uncontrolled, the widget owns its text), `text_changed`, the `clear` and
`focus` commands, the `set_text`, `type` and `expect` verbs, the a11y
props, `grow`, `fill`, the R10 fill-the-column rule, `help`. It is
`select`/`radio`'s shape: one contract, two presentations. The ruling
sets the precedent for the entry variants the parity survey found
missing, `secure` (unanimous across all fifteen toolkits, absent from
kaya) and `number`: they are kinds too, when they come.

Cost, honestly: the `labeled` figure, about +1,500 over about 50 files,
plus S4's prop and S5's verb, plus the ten gallery guests every kind
joins. About six times the role. The reason to pay it is the wall and
the payload, not the look.

### S3 — The placeholder is a prop on every text kind (RECOMMEND: yes, `placeholder`, PROPS 30)

A Str prop legal on `entry`, `textarea` and `search`: the platform's own
prompt (`TextField`'s prompt, `placeholder-text`, `PlaceholderText`, the
decoration box's placeholder slot), shown while the text is empty, never
part of the text and never emitted. The root refuses an empty one, as it
refuses an empty `help`. Sugar: the entry's own spelling in each binding
(`.placeholder("…")` chained where `help` chains, a labelled argument on
OCaml, a keyword on Python's constructors beside `text=`), in both
zones; a SOURCED prop in the template zone like the a11y label.
Read-back: `expect_placeholder search@find "Search"` reads the node's
own property in each harness, and one measured platform surface per
desktop (macOS `AXPlaceholderValue`, AT-SPI's placeholder-text, UIA's
HelpText or the box's own property) confirms the platform received it,
the tooltips pass's T5 shape. The default is none: the tasks app sets
"Search". Orthogonal to S2 and worth its own commit inside the slice.

### S4 — No submit occurrence in S1 (RULED: refuse for S1; ledgered for the milestone that needs a submit event, the maintainer naming a chat app)

S1 filters on every keystroke, so Return has nothing to publish. The
phones show the Search key regardless (Compose forces the IME action;
iOS takes `.submitLabel(.search)`), and pressing it dismisses the
keyboard and nothing else, on both. The shape for the day a consumer
arrives is `submitted`, occurrence 27 with `value_committed`'s layout and
check-slider-commit's gate shape. The maintainer's amendment names the
consumer: a chat app, whose compose field sends on Return, is the
milestone that pays for it; the ledger entry carries that trigger (and a
search that asks a server, and a form whose Return submits, beside it).

### S5 — Clearing is one act on every platform, and Escape is that act on the desktops (RECOMMEND: yes)

The rule, one sentence: a search field with text shows a clear
affordance; using it, or pressing Escape while the field has focus on a
desktop, empties the text, keeps the focus, and reaches the app as
`text_changed("")`, indistinguishable from the user deleting every
character. An empty field does nothing on Escape. The affordance is the
platform's own where the platform draws one (NSSearchField's cancel
button, GTK's clear icon, AutoSuggestBox's clear-all) and kaya's own
trailing button where it does not (the styled `TextField` on both Apple
platforms, the Compose field), a divergence in spelling only.

The harness drives it with ONE new verb, `clear_search <target>`, which
operates the platform's clear affordance (the button where there is one,
the keyboard's Escape on the desktops where the button is kaya's own
so both paths are exercised across the lanes) and waits for the app's
answer like every action verb. Escape itself cannot be driven from a
shared scene today (no key verb; `escape` refused as a shortcut), so the
desktop Escape arms are held STATICALLY, check-slider-commit's shape: a
gate clause reads each desktop arm's Escape handler out of its own block
and demands it call the same clear path the button does, with a watched
negative per backend. GtkSearchEntry's `stop-search` signal is that
handler on GTK; it does not clear by itself.

### S6 — No debounce anywhere; the app decides (RECOMMEND: yes)

`text_changed` reports every keystroke on every platform, exactly as the
entry does. The GTK arm sets `search-delay` to 0 or wires `changed`
rather than `search-changed`, stated at the site with the 150 ms default
named, so a shared scene reads the same list on Linux as everywhere
else. An app that wants to coalesce keystrokes does it in its handler.
The WinUI arm reads `TextChanged`'s `Reason` and publishes `UserInput`
alone, through the same `banked_text` door the entry uses, since a
filter rebuilding its list on every keystroke is the busiest consumer
that echo path has had.

### S7 — The a11y verdict stays `field`; the platform identity is held per backend (RECOMMEND: yes)

`expect_ax search@find` reads `field/…` on all five lanes, by
DESIGN.md's normalize-down rule: UIA has no search control type and
Compose has no search role, so `search` cannot join the closed set
without lying on two platforms. Each backend still gives the platform's
assistive reader what it has: the `AXSearchField` subrole and the
`.isSearchField` trait on the Apple platforms, `SEARCH_BOX` on GTK
(GtkSearchEntry's own role), the field's placeholder as its Compose
content description, nothing extra on WinUI. A gate clause holds each
arm to its platform's identity, check-universal-props' shape, because no
shared scene can see it.

### S8 — Phone keyboards: capitalization off, the Search key on (RECOMMEND: yes)

A filter query is not prose. iOS: `.textInputAutocapitalization(.never)`,
`.submitLabel(.search)`; Compose: `KeyboardCapitalization.None` and the
Search IME action. Autocorrection stays the platform's default. Desktops
unchanged.

### S9 — The filter is the app's (RECOMMEND: app-owned, and open the gap on the ledger)

kaya ships no filtered view in S1. The task manager keeps a mirror of
each list's visible set and, on every `text_changed`, removes the keys
that stopped matching and inserts the ones that started, in one
transaction, NOT undoable (a search must not un-type under ⌘Z; the
precedent is the app's own KeepDone re-placement). At nine seeded tasks
the diff is trivial; the pattern is the portfolio's reconciler with a
predicate. What this costs the app, `place()` composing with the live
predicate so an edited task that stops matching is not inserted, is the
work a framework filtered view would remove, and that gap (the parity
survey's "collection pipelines as reusable objects", cited by
docs/tasks-plan.md with no ledger entry behind it) opens on the ledger
in this pass with the portfolio's scale as its trigger. S1 stays on the
row-membership side of the ranges line: it decorates nothing, so the
"text ranges deferred on the entry widget" entry keeps its own trigger.

### S10 — Where it goes in the task manager

Each list column takes a `search` field as its FIRST child, above the
count caption, placeholder "Search", filling the column (R10). In the
Inbox the quick-add row follows it. It filters that list alone, by
case-insensitive substring over title and notes; while a filter is
active the count caption reads "1 of 2 match" and returns to "2 in
inbox" when the field clears. The maintainer may amend any of this;
churn is free.

## §3 — The lowering, per backend

| backend | control | glyph | clear | Escape | identity |
|---|---|---|---|---|---|
| SwiftUI, macOS | `TextField` in a rounded search style: a leading `magnifyingglass` Image and a trailing clear Button drawn by the arm, `.frame` and fill as the entry | SF Symbol | kaya's button | `.onExitCommand` clears | `.accessibilityAddTraits(.isSearchField)`; the AX read on the harness thread stays the role attribute |
| SwiftUI, iOS | the same view; `.textInputAutocapitalization(.never)`, `.submitLabel(.search)`, `.onSubmit` dismisses the keyboard | SF Symbol | kaya's button | (hardware keyboard only) the same handler | `.isSearchField` |
| Compose | `BasicTextField` through `KayaTextField` with `leadingIcon = Icons.Default.Search`, a trailing clear `IconButton` while text is non-empty, `ImeAction.Search`, `KeyboardCapitalization.None` | Material icon | kaya's button | `onPreviewKeyEvent` Escape clears (hardware keyboards) | placeholder as content description |
| GTK 4 | `gtk4::SearchEntry`, `search-delay` 0 or `changed` | built in | built in | `stop-search` → clear | `SEARCH_BOX`, built in |
| WinUI 3 | `AutoSuggestBox` with `QueryIcon=Find` and no `ItemsSource`, measured first for an empty flyout (§7); fallback a `TextBox` with a find glyph in the leading slot and kaya's clear button | Segoe Fluent icon | built in (fallback: kaya's) | `KeyDown` Escape → clear | none available |

Reaching `AutoSuggestBox` means adding the class to
tools/winui-bindgen's filter and regenerating the 11 MB bindings file;
it is not generated today. The interpreters carry private copies of the
kind constant (check-verbs holds them), the target tables grow a row
each, and tools/tpl-surfaces.py's census grows the kind in both zones.

## §4 — The wire

- `kind` 19 `search`, beside entry (4) and textarea (14). The spec hash
  moves; every generated surface regenerates; the two hand-copied
  hashes move with it.
- PROPS 30 `placeholder`, Str, legal on entry, textarea and search; the
  root refuses an empty one.
- No new occurrence; `text_changed` serves. No new command; `clear` and
  `focus` serve.
- Harness: `clear_search` (action verb, in ACTION_VERBS with its two
  waits) and `expect_placeholder` (observation, byte-compared, in the
  AX-style census of the three harnesses' spellings).

## §5 — The scene and the sweep

`tools/scenes/search.steps`, the kind's own contract, wired on all five
lanes: the placeholder read, `type` into the field with the row count
falling at each step, `clear_search` restoring the list and reading
`""`, `expect_focused` after the clear, `expect_ax` reading `field`.
`tasks.steps` grows the consumer's steps (S10). `gallery.steps` and the
ten gallery guests take the kind, as every kind does.

The nine bindings: constructor in both zones (`search()` beside
`entry()` in each idiom), `placeholder` in both zones on all three text
kinds, one line per binding in check-sugar-surface's tables. The C floor
spells the kind number and the prop number. JS follows the desktop lanes
by the 2026-09-03 ruling.

Gates that grow: check-sugar-surface (kind census, the placeholder as a
prop row), check-verbs (the two verbs' arms in both interpreters, the
kind constant, `clear_search` in ACTION_VERBS), check-steps
(TARGET_KINDS, the census), check-stubs (the legs wired iff the arm
exists), tpl-surfaces (both zones), a new clause for S5's Escape arms
and S7's identity per backend, check-universal-props (the a11y props
reach the kind). check-gates holds the census.

## §6 — Build order, if ruled

Depth then breadth, the pickers' and sliders' shape:

1. spec.rs: kind 19, prop 30; regenerate; the root's checks and their
   unit tests; the Rust sugar in both zones; `clear_search` and
   `expect_placeholder` in harness.rs.
2. The SwiftUI arm on the mac, search.steps, the tasks guest's fields
   (S10) and its steps; validate-mac green.
3. Breadth: GTK, WinUI (AutoSuggestBox measured, then chosen), Compose,
   iOS; the eight other bindings' sugar in both zones; the ten gallery
   guests; the placeholder on entry and textarea everywhere; the gate
   clauses; check-verbs and check-sugar-surface green again.
4. The matrix, once.

## §7 — To be measured before the design is frozen

Six facts the documentation does not settle, each a probe on the lane
that owns it:

- Whether `.searchable` on macOS renders anything in a plain VStack
  with no navigation container above it (Apple states the requirement,
  not the failure mode). Not needed if S1 is ruled content, but it
  closes the question the plan's "role on entry" wording left open.
- Whether an `AutoSuggestBox` with an empty `ItemsSource` ever opens an
  empty flyout on WinUI 3, and what `AutomationControlType` its peer
  reports.
- Whether dismissing search on iOS clears the text binding (moot under
  S1's styled TextField, which has no dismiss).
- The literal subrole string macOS publishes for the styled field once
  `.isSearchField` is added, read off the live tree.
- What AT-SPI reports for GtkSearchEntry's placeholder and role from the
  lane's container.
- The keystroke-to-list latency of the app-side diff on the android and
  wayland lanes under a matrix, since S1 is the first text-driven filter
  and the action-wait rule is what makes the scene observable.
